import Foundation
import Observation

#if canImport(onnxruntime) || canImport(OnnxRuntimeBindings)
import MisakiSwift
#if canImport(onnxruntime)
import onnxruntime
#else
import OnnxRuntimeBindings   // the SPM target's actual module name
#endif

/// Kokoro-82M studio voice: on-device neural TTS (int8 ONNX, ~86MB one-time download,
/// CPU inference — works on simulator and device, offline, zero API cost).
/// Assets live in Application Support; Apple TTS remains the fallback until ready.
@Observable @MainActor
final class KokoroEngine {
    static let shared = KokoroEngine()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)   // 0...1
        case preparing             // first model load / G2P dictionaries
        case ready
        case failed(String)
    }
    private(set) var state: State = .notInstalled

    var voice: String { didSet { UserDefaults.standard.set(voice, forKey: "kokoroVoice") } }
    nonisolated static let voices: [(id: String, label: String)] = [
        ("af_heart", "Heart · American"),
        ("bf_emma", "Emma · British"),
        ("bm_george", "George · British"),
    ]

    private init() {
        voice = UserDefaults.standard.string(forKey: "kokoroVoice") ?? "af_heart"
        if Self.assetsPresent { state = .ready }
    }

    // MARK: - Assets

    nonisolated private static let dir = URL.applicationSupportDirectory.appending(path: "Kokoro")
    /// Individually fetchable files — no archives (iOS has no built-in tar/zip).
    nonisolated private static let assets: [(file: String, url: String, weight: Double)] = [
        ("model.onnx", "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model_q8f16.onnx", 0.94),
        ("config.json", "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/config.json", 0.01),
        ("af_heart.bin", "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/voices/af_heart.bin", 0.02),
        ("bf_emma.bin", "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/voices/bf_emma.bin", 0.02),
        ("bm_george.bin", "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/voices/bm_george.bin", 0.01),
    ]
    private static var assetsPresent: Bool {
        assets.allSatisfy { FileManager.default.fileExists(atPath: dir.appending(path: $0.file).path) }
    }

    func download() {
        switch state {
        case .downloading, .preparing, .ready: return
        default: break
        }
        Task { await downloadAll() }
    }

    private func downloadAll() async {
        state = .downloading(0)
        do {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            var base = 0.0
            for asset in Self.assets {
                let dest = Self.dir.appending(path: asset.file)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    let tmp = try await fetch(URL(string: asset.url)!, weight: asset.weight, base: base)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                }
                base += asset.weight
                state = .downloading(base)
            }
            state = .ready
            Analytics.capture("studio_voice_installed")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Streamed download with live progress (86MB deserves a real progress bar).
    private func fetch(_ url: URL, weight: Double, base: Double) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let expected = max(response.expectedContentLength, 1)
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }
        var buffer = Data(capacity: 1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                state = .downloading(min(0.999, base + weight * Double(written) / Double(expected)))
            }
        }
        try handle.write(contentsOf: buffer)
        return tmp
    }

    // MARK: - Synthesis

    nonisolated(unsafe) private var worker: Worker?

    /// 24kHz mono float samples for one briefing segment. Heavy work runs detached.
    func synthesize(_ text: String) async throws -> [Float] {
        if worker == nil {
            state = .preparing
            worker = try await Task.detached(priority: .userInitiated) { try Worker(dir: Self.dir) }.value
            state = .ready
        }
        guard let worker else { throw KokoroError.notReady }
        let selected = voice
        return try await Task.detached(priority: .userInitiated) {
            try worker.synth(text, voice: selected)
        }.value
    }

    enum KokoroError: Error { case notReady, badModel }
}

/// Off-main inference bundle: ORT session + vocab + G2P + style vectors.
/// ORTSession is safe for concurrent run; we only ever call it serially anyway.
private final class Worker: @unchecked Sendable {
    private let session: ORTSession
    private let env: ORTEnv
    private let vocab: [Character: Int64]
    private let styles: [String: Data]
    private let g2pUS = EnglishG2P(british: false)
    private let g2pGB = EnglishG2P(british: true)
    private let inputIDsName: String

    init(dir: URL) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        session = try ORTSession(env: env, modelPath: dir.appending(path: "model.onnx").path, sessionOptions: options)
        let names = try session.inputNames()
        inputIDsName = names.contains("input_ids") ? "input_ids" : "tokens"

        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "config.json"))) as? [String: Any]
        guard let rawVocab = config?["vocab"] as? [String: Int] else { throw KokoroEngine.KokoroError.badModel }
        var v: [Character: Int64] = [:]
        for (k, id) in rawVocab where k.count == 1 { v[Character(k)] = Int64(id) }
        vocab = v

        var s: [String: Data] = [:]
        for voice in KokoroEngine.voices.map(\.id) {
            s[voice] = try Data(contentsOf: dir.appending(path: "\(voice).bin"))
        }
        styles = s
    }

    func synth(_ text: String, voice: String) throws -> [Float] {
        let g2p = voice.hasPrefix("a") ? g2pUS : g2pGB   // a* = American, b* = British
        let (phonemes, _) = g2p.phonemize(text: text)
        var ids: [Int64] = [0]
        for ch in phonemes { if let id = vocab[ch] { ids.append(id) } }
        ids.append(0)
        guard ids.count > 2, ids.count <= 510 else {
            if ids.count > 510 { ids = Array(ids.prefix(509)) + [0] } else { return [] }
            return try run(ids: ids, voice: voice)
        }
        return try run(ids: ids, voice: voice)
    }

    private func run(ids: [Int64], voice: String) throws -> [Float] {
        guard let styleData = styles[voice] else { throw KokoroEngine.KokoroError.badModel }
        // Style vector row indexed by phoneme count (Kokoro convention: voices[len(tokens)]).
        let row = min(ids.count - 2, 509)
        let styleFloats: [Float] = styleData.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            let start = row * 256
            guard f.count >= start + 256 else { return [] }
            return Array(f[start..<(start + 256)])
        }
        guard styleFloats.count == 256 else { throw KokoroEngine.KokoroError.badModel }

        var mutableIDs = ids
        let idsValue = try ORTValue(
            tensorData: NSMutableData(bytes: &mutableIDs, length: ids.count * MemoryLayout<Int64>.size),
            elementType: .int64, shape: [1, NSNumber(value: ids.count)])
        var mutableStyle = styleFloats
        let styleValue = try ORTValue(
            tensorData: NSMutableData(bytes: &mutableStyle, length: 256 * MemoryLayout<Float>.size),
            elementType: .float, shape: [1, 256])
        var speed: Float = 1.2   // +20% — default pacing read slow (Tom)
        let speedValue = try ORTValue(
            tensorData: NSMutableData(bytes: &speed, length: MemoryLayout<Float>.size),
            elementType: .float, shape: [1])

        let outputs = try session.run(
            withInputs: [inputIDsName: idsValue, "style": styleValue, "speed": speedValue],
            outputNames: Set(try session.outputNames()),
            runOptions: nil)
        guard let waveform = outputs.values.first else { throw KokoroEngine.KokoroError.badModel }
        let data = try waveform.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

#else

/// Platform stub (e.g. the Mac demo's plain swiftc build) — Apple TTS handles speech.
@Observable @MainActor
final class KokoroEngine {
    static let shared = KokoroEngine()
    enum State: Equatable { case notInstalled, downloading(Double), preparing, ready, failed(String) }
    private(set) var state: State = .notInstalled
    var voice = "bf_emma"
    static let voices: [(id: String, label: String)] = []
    func download() {}
    func synthesize(_ text: String) async throws -> [Float] { throw KokoroError.notReady }
    enum KokoroError: Error { case notReady }
}

#endif
