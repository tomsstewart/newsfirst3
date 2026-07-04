import Foundation

/// Minimal PostHog capture over REST — no SDK dependency, fire-and-forget.
/// Every install is identified from first launch (strategy §7.7): the same distinct_id
/// persists across guest → signed-in via alias, so nobody becomes a ghost user again.
enum Analytics {
    private static let host = URL(string: "https://eu.i.posthog.com/capture/")!
    private static let apiKey = "phc_rnbXCjglPQRSn1EV4j7o9i0dy0rodeFtT0vUH10G5Xn"

    static var distinctID: String {
        if let id = UserDefaults.standard.string(forKey: "installUUID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installUUID")
        return id
    }

    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        var props: [String: Any] = properties
        props["$app_version"] = "3.0"
        props["platform"] = "ios-v3"
        let body: [String: Any] = [
            "api_key": apiKey,
            "event": event,
            "distinct_id": distinctID,
            "properties": props,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: host)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Link the install id to the signed-in user id.
    static func alias(userID: String) {
        capture("$create_alias", ["alias": userID, "distinct_id": distinctID])
    }
}
