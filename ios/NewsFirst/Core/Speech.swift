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

    // MARK: - Kokoro (studio voice): sentence-level pipeline into the player

    /// Sentence-sized utterances are the anti-lag mechanism: a sentence synthesizes in
    /// ~1s and plays for ~4s, so the queue permanently outruns playback — story-sized
    /// chunks (multi-second synths) kept draining the buffer and stalling mid-briefing.
    private static func sentenceChunks(_ parts: [String]) -> [(text: String, storyEnd: Bool)] {
        var out: [(String, Bool)] = []
        for part in parts {
            var sentences: [String] = []
            var current = ""
            for ch in part {
                current.append(ch)
                if ".!?".contains(ch), current.count >= 24 {
                    sentences.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            let tail = current.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { sentences.append(tail) }
            for (i, s) in sentences.enumerated() {
                out.append((s, i == sentences.count - 1))   // the story beat lands after a part's last sentence
            }
        }
        return out
    }

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
                let chunks = Self.sentenceChunks(parts)
                for (i, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    var samples = try await KokoroEngine.shared.synthesize(chunk.text)
                    try Task.checkCancellation()
                    guard !samples.isEmpty else { continue }
                    if chunk.storyEnd, i < chunks.count - 1 {
                        samples.append(contentsOf: [Float](repeating: 0, count: 8_400))   // 0.35s beat between stories
                    }
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { src in
                        buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
                    }
                    playerNode.scheduleBuffer(buffer, completionHandler: nil)
                    if !playerNode.isPlaying { playerNode.play() }   // speak from the very first sentence
                }
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
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.01   // +10% over the old newsreader pace
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

/// Best-effort readable-text extraction for "read this article to me": fetch the page,
/// scope to <article> when present, keep substantial <p> blocks. Paywalled/JS-only
/// pages fall back to the title + excerpt the feed already carries.
enum ArticleText {
    static func paragraphs(from url: URL) async -> [String] {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let scope = firstMatch(in: html, pattern: "<article[\\s\\S]*?</article>") ?? html
        let blocks = allMatches(in: scope, pattern: "<p[^>]*>([\\s\\S]*?)</p>")
        return blocks
            .map(plainText)
            .filter { $0.count > 60 }                    // skip captions/bylines/cookie shrapnel
            .prefix(40)                                   // ~5 minutes of listening, bounded
            .map { $0 }
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range, in: s) else { return nil }
        return String(s[range])
    }

    private static func allMatches(in s: String, pattern: String) -> [String] {
        guard let r = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return r.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[range])
        }
    }

    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
