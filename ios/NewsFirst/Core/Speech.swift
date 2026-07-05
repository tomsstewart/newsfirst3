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

    func toggle(_ text: String) {
        if isSpeaking {
            synth.stopSpeaking(at: .immediate)
            isSpeaking = false
            return
        }
        #if os(iOS)
        // .playback so the briefing is audible even with the mute switch on — it's
        // an explicit "read it to me", not incidental sound.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
        isSpeaking = true
        Analytics.capture("briefing_play")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            Speech.shared.isSpeaking = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in Speech.shared.isSpeaking = false }
    }
}
