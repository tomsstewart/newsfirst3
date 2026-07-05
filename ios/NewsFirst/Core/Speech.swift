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

    func stop() {
        guard isSpeaking else { return }
        remaining = 0
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// One utterance PER STORY with a newsreader beat between them — a single blob
    /// utterance is where the flat, breathless delivery came from. Same voice,
    /// far better rhythm.
    func toggle(_ parts: [String]) {
        if isSpeaking { stop(); return }
        guard !parts.isEmpty else { return }
        #if os(iOS)
        // .playback so the briefing is audible even with the mute switch on — it's
        // an explicit "read it to me", not incidental sound.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
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
        Analytics.capture("briefing_play")
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
