import Foundation
#if os(iOS)
import UIKit
#endif

/// PostHog product analytics over REST — no SDK dependency.
///
/// Design (v3 "comprehensive" pass):
/// - Every install is identified from first launch; the same distinct_id persists
///   across guest → signed-in via alias, so nobody becomes a ghost user.
/// - Every event carries the full context envelope (version, build, device, OS,
///   session) so any insight can slice without joins.
/// - Events BATCH: buffered in memory, flushed every 5s / 20 events / on background,
///   and unsent events persist across launches — the fire-and-forget one-request-
///   per-event version silently dropped events (a lost push_permission event cost
///   an hour of debugging on 2026-07-05).
enum Analytics {
    private static let batchHost = URL(string: "https://eu.i.posthog.com/batch/")!
    private static let apiKey = "phc_xhoSbWSkg8gukVaNquCm9w977sPsv73qtMtxvzjFeJU8"
    private static let queue = AnalyticsQueue()

    /// One id per cold launch: lets PostHog stitch session-level funnels.
    static let sessionID = UUID().uuidString

    /// Identity model (Tom's spec): track at the EMAIL level whenever a user is
    /// signed in — events carry the Supabase user id (one person across devices and
    /// reinstalls, email attached as a person property). Signed out (or a future
    /// anonymous tier), the install UUID keeps the trail unbroken; $identify merges
    /// that pre-login history into the person the moment they sign in.
    static var distinctID: String { userID ?? installID }

    private static var userID: String? = UserDefaults.standard.string(forKey: "authUserID")

    static var installID: String {
        if let id = UserDefaults.standard.string(forKey: "installUUID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installUUID")
        return id
    }

    /// Sign-in: merge the anonymous install trail into the canonical person and
    /// attach person-level properties (email = the tracking key Tom wants).
    static func identify(userID uid: String, email: String?, method: String) {
        userID = uid
        var set: [String: Any] = ["auth_method": method]
        if let email { set["email"] = email }
        set["is_anonymous_account"] = (email == nil)
        capture("$identify", ["$anon_distinct_id": installID, "$set": set])
        capture("login_success", ["method": method])
        flush()
    }

    /// Sign-out: back to the device trail (a new person is NOT created — the next
    /// sign-in re-merges via $identify).
    static func reset() {
        userID = nil
    }

    // Immutable after first access (value types only) — safe to share; built with
    // nonisolated APIs (utsname/ProcessInfo, not MainActor-bound UIDevice).
    nonisolated(unsafe) private static let envelope: [String: Any] = {
        let info = Bundle.main.infoDictionary
        var sysinfo = utsname(); uname(&sysinfo)
        let model = withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "$app_version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "$app_build": info?["CFBundleVersion"] as? String ?? "?",
            "platform": "ios-v3",
            "$os_version": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "$device_model": model,
            "$device_type": model.hasPrefix("iPad") ? "Tablet" : "Mobile",
        ]
    }()

    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        var props = envelope
        for (k, v) in properties { props[k] = v }
        props["$session_id"] = sessionID
        queue.enqueue([
            "event": event,
            "distinct_id": distinctID,
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "properties": props,
        ])
    }


    /// Force a send now (sign-in, app background).
    static func flush() { queue.flush() }

    fileprivate static func send(_ batch: [[String: Any]], done: @escaping (Bool) -> Void) {
        let body: [String: Any] = ["api_key": apiKey, "batch": batch]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { done(true); return }
        var req = URLRequest(url: batchHost)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, resp, error in
            let ok = error == nil && ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 400
            done(ok)
        }.resume()
    }
}

/// Thread-safe buffer with periodic flush + disk persistence for unsent events.
private final class AnalyticsQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [[String: Any]] = []
    private var timer: Timer?
    private var inFlight = false
    private let store = URL.cachesDirectory.appending(path: "analytics-pending.json")

    init() {
        // Recover events a previous session couldn't send.
        if let data = try? Data(contentsOf: store),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            buffer = saved
            try? FileManager.default.removeItem(at: store)
        }
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self?.flush() }
            #if os(iOS)
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                   object: nil, queue: .main) { _ in
                self?.flush()
                self?.persist()
            }
            #endif
        }
    }

    func enqueue(_ event: [String: Any]) {
        lock.lock()
        buffer.append(event)
        let full = buffer.count >= 20
        lock.unlock()
        if full { flush() }
    }

    func flush() {
        lock.lock()
        guard !inFlight, !buffer.isEmpty else { lock.unlock(); return }
        inFlight = true
        let batch = buffer
        buffer.removeAll()
        lock.unlock()
        Analytics.send(batch) { [weak self] ok in
            guard let self else { return }
            self.lock.lock()
            if !ok { self.buffer.insert(contentsOf: batch.suffix(100), at: 0) }   // retry later, capped
            self.inFlight = false
            self.lock.unlock()
        }
    }

    /// Best-effort save of whatever is still unsent (called entering background).
    func persist() {
        lock.lock()
        let pending = buffer
        lock.unlock()
        guard !pending.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: pending) else { return }
        try? data.write(to: store, options: .atomic)
    }
}
