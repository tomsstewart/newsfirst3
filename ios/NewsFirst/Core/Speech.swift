import AVFoundation
import Observation

/// On-device TTS for the session briefing — "play the news" with zero API cost,
/// works offline, no quota. One utterance at a time; tapping again stops.
@Observable @MainActor
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()
    private(set) var isSpeaking = false

    override private init() {
        super.init()
        synth.delegate = self
    }

    /// Best installed voice: the API silently defaults to the robotic COMPACT voice;
    /// the neural premium/enhanced voices ship on-device but must be selected
    /// explicitly. (Real devices can add more: Settings → Accessibility → Spoken
    /// Content → Voices.) Novelty voices (Bahh, Bells…) are rank-0 by quality.
    private static let voice: AVSpeechSynthesisVoice? = {
        let preferred = Locale.preferredLanguages.first ?? "en-GB"
        let base = String(preferred.prefix(2))
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var r = 0
            switch v.quality {
            case .premium: r += 100
            case .enhanced: r += 50
            default: break
            }
            if v.language == preferred { r += 20 }                        // exact locale (en-GB for Tom)
            if v.identifier.contains("com.apple.voice") { r += 5 }       // modern voice bundles
            return r
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(base) }
            .max { rank($0) < rank($1) }
    }()

    private var remaining = 0

    // Kokoro playback path
    private var kokoroTask: Task<Void, Never>?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var engineWired = false

    func stop() {
        guard isSpeaking else { return }
        remaining = 0
        kokoroTask?.cancel()
        kokoroTask = nil
        playerNode.stop()
        if audioEngine.isRunning { audioEngine.stop() }
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func toggle(_ parts: [String]) {
        if isSpeaking { stop(); return }
        guard !parts.isEmpty else { return }
        #if os(iOS)
        // .playback so the briefing is audible even with the mute switch on — it's
        // an explicit "read it to me", not incidental sound.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if KokoroEngine.shared.state == .ready || KokoroEngine.shared.state == .preparing {
            speakKokoro(parts)
        } else {
            speakApple(parts)
        }
    }

    // MARK: - Kokoro (studio voice): synth each story off-main, pipeline into the player

    private func speakKokoro(_ parts: [String]) {
        isSpeaking = true
        Analytics.capture("briefing_play", ["engine": "kokoro"])
        kokoroTask = Task { [self] in
            do {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else { return }
                if !engineWired {
                    audioEngine.attach(playerNode)
                    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
                    engineWired = true
                }
                if !audioEngine.isRunning { try audioEngine.start() }
                // Buffer AHEAD: playback starts only once the first TWO segments are
                // queued. Starting on segment one left a dead-air gap after the greeting
                // while the (long) first story was still synthesizing.
                let startAfter = min(1, parts.count - 1)
                for (i, part) in parts.enumerated() {
                    try Task.checkCancellation()
                    var samples = try await KokoroEngine.shared.synthesize(part)
                    try Task.checkCancellation()
                    guard !samples.isEmpty else { continue }
                    if i < parts.count - 1 { samples.append(contentsOf: [Float](repeating: 0, count: 8_400)) }  // 0.35s beat
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { src in
                        buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
                    }
                    playerNode.scheduleBuffer(buffer, completionHandler: nil)
                    if i >= startAfter, !playerNode.isPlaying { playerNode.play() }
                }
                if !playerNode.isPlaying { playerNode.play() }   // single-segment briefings
                try Task.checkCancellation()
                // Drain: resume when the queue finishes playing.
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240) else { c.resume(); return }
                    tail.frameLength = 240
                    playerNode.scheduleBuffer(tail) { c.resume() }
                }
                finishKokoro()
            } catch {
                // Synth failure mid-run (or cancellation): fall back silently for cancel,
                // Apple voice for genuine errors on a fresh play.
                if !(error is CancellationError) {
                    finishKokoro()
                    speakApple(parts)
                    return
                }
                finishKokoro()
            }
        }
    }

    private func finishKokoro() {
        playerNode.stop()
        if audioEngine.isRunning { audioEngine.stop() }
        if kokoroTask != nil { isSpeaking = false; kokoroTask = nil }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Apple TTS fallback

    /// One utterance PER STORY with a newsreader beat between them — a single blob
    /// utterance is where the flat, breathless delivery came from.
    private func speakApple(_ parts: [String]) {
        remaining = parts.count
        for (i, part) in parts.enumerated() {
            let utterance = AVSpeechUtterance(string: part)
            utterance.voice = Self.voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92   // newsreader, not auctioneer
            utterance.pitchMultiplier = 1.02
            utterance.postUtteranceDelay = i == parts.count - 1 ? 0 : 0.35   // the beat between stories
            synth.speak(utterance)   // AVSpeechSynthesizer queues natively
        }
        isSpeaking = true
        Analytics.capture("briefing_play", ["engine": "apple"])
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let s = Speech.shared
            s.remaining = max(0, s.remaining - 1)
            guard s.remaining == 0 else { return }
            s.isSpeaking = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let s = Speech.shared
            s.remaining = 0
            s.isSpeaking = false
        }
    }
}
