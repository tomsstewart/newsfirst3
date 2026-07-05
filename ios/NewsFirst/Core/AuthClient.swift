import AuthenticationServices
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

    /// Native Sign in with Apple: exchange the identity token for a Supabase session.
    /// (Supabase's Apple provider is configured with the app bundle id as client.)
    func signInWithApple(idToken: String) async throws {
        var req = URLRequest(url: URL(string: base.appending(path: "token").absoluteString + "?grant_type=id_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["provider": "apple", "id_token": idToken])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let user = json["user"] as? [String: Any],
              let uid = user["id"] as? String else {
            throw NSError(domain: "auth", code: 3, userInfo: [NSLocalizedDescriptionKey: Self.supabaseError(data) ?? "Apple sign-in failed"])
        }
        adopt(token: token, uid: uid, email: user["email"] as? String, method: "apple")
    }

    /// OAuth web flow (Google): Supabase-hosted round trip in an
    /// ASWebAuthenticationSession; tokens come back in the callback URL fragment.
    /// Needs the provider enabled in Supabase (Google OAuth client) — fails with a
    /// readable message until then.
    func signInWithGoogle() async throws {
        var comps = URLComponents(url: base.appending(path: "authorize"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "provider", value: "google"),
            .init(name: "redirect_to", value: "newsfirst://auth-callback"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: "newsfirst") { url, err in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: err ?? URLError(.userCancelledAuthentication)) }
            }
            session.presentationContextProvider = WebAuthPresenter.shared
            session.start()
        }
        var kv: [String: String] = [:]
        for pair in (URLComponents(url: callback, resolvingAgainstBaseURL: false)?.fragment ?? "").components(separatedBy: "&") {
            let p = pair.components(separatedBy: "=")
            if p.count == 2 { kv[p[0]] = p[1].removingPercentEncoding ?? p[1] }
        }
        guard let token = kv["access_token"] else {
            throw NSError(domain: "auth", code: 4, userInfo: [NSLocalizedDescriptionKey: kv["error_description"] ?? "Google sign-in isn't configured yet"])
        }
        // Resolve the user behind the token.
        var req = URLRequest(url: base.appending(path: "user"))
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = user["id"] as? String else {
            throw NSError(domain: "auth", code: 5, userInfo: [NSLocalizedDescriptionKey: "Couldn't load the signed-in profile"])
        }
        adopt(token: token, uid: uid, email: user["email"] as? String, method: "google")
    }

    private func adopt(token: String, uid: String, email: String?, method: String) {
        accessToken = token
        userID = uid
        self.email = email
        UserDefaults.standard.set(token, forKey: "authToken")
        UserDefaults.standard.set(uid, forKey: "authUserID")
        UserDefaults.standard.set(email, forKey: "authEmail")
        Analytics.alias(userID: uid)
        Analytics.capture("login_success", ["method": method])
    }

    private static func supabaseError(_ data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["error_description"] ?? json?["msg"] ?? json?["message"]) as? String
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

/// Anchors the OAuth web sheet to the key window.
final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresenter()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
