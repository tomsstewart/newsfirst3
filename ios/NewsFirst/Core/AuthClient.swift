import Foundation
import Observation

/// Supabase email-OTP auth over REST. Apple/Google land once the app has its
/// signing capabilities (blocked on Apple Developer portal access).
@Observable @MainActor
final class AuthClient {
    static let shared = AuthClient()

    private(set) var email: String? = UserDefaults.standard.string(forKey: "authEmail")
    private(set) var accessToken: String? = UserDefaults.standard.string(forKey: "authToken")
    private(set) var userID: String? = UserDefaults.standard.string(forKey: "authUserID")
    var isSignedIn: Bool { accessToken != nil }

    private var base: URL { SupabaseAPI.projectURL.appending(path: "auth/v1") }

    /// Step 1: send a 6-digit code to the email.
    func requestCode(email: String) async throws {
        var req = URLRequest(url: base.appending(path: "otp"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "create_user": true])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "auth", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "OTP request failed"])
        }
    }

    /// Step 2: verify the code → session.
    func verify(email: String, code: String) async throws {
        var req = URLRequest(url: base.appending(path: "verify"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "token": code, "type": "email"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let user = json["user"] as? [String: Any],
              let uid = user["id"] as? String else {
            throw NSError(domain: "auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wrong or expired code"])
        }
        accessToken = token
        userID = uid
        self.email = email
        UserDefaults.standard.set(token, forKey: "authToken")
        UserDefaults.standard.set(uid, forKey: "authUserID")
        UserDefaults.standard.set(email, forKey: "authEmail")
        Analytics.alias(userID: uid)
        Analytics.capture("login_success", ["method": "email_otp"])
    }

    func signOut() {
        email = nil; accessToken = nil; userID = nil
        for k in ["authToken", "authUserID", "authEmail"] { UserDefaults.standard.removeObject(forKey: k) }
        Analytics.capture("sign_out")
    }

    /// Push local topic prefs to topic_subscriptions (RLS: user's own rows).
    func syncTopics(preset: [String], custom: [String]) async {
        guard let token = accessToken, let uid = userID else { return }
        let rows = preset.map { ["user_id": uid, "topic": $0, "kind": "preset", "notify_level": "none"] }
                 + custom.map { ["user_id": uid, "topic": $0, "kind": "custom", "notify_level": "all"] }
        var req = URLRequest(url: SupabaseAPI.projectURL.appending(path: "rest/v1/topic_subscriptions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.url = URL(string: req.url!.absoluteString + "?on_conflict=user_id,topic")
        req.httpBody = try? JSONSerialization.data(withJSONObject: rows)
        _ = try? await URLSession.shared.data(for: req)
    }
}
