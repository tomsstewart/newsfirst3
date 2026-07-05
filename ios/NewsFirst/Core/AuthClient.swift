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
    private var refreshToken: String? = UserDefaults.standard.string(forKey: "authRefreshToken")
    private var expiresAt: Double = UserDefaults.standard.double(forKey: "authExpiresAt")
    var isSignedIn: Bool { accessToken != nil }

    private var base: URL { SupabaseAPI.projectURL.appending(path: "auth/v1") }

    /// The token every authed call must use. Access tokens die after ~1h; without this
    /// the session expired silently and topic sync / device registration just stopped.
    func validToken() async -> String? {
        guard let token = accessToken else { return nil }
        if Date.now.timeIntervalSince1970 < expiresAt - 60 { return token }
        guard let refresh = refreshToken else { return token }   // pre-refresh session: try our luck
        var req = URLRequest(url: URL(string: base.appending(path: "token").absoluteString + "?grant_type=refresh_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return token }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            // Refresh token revoked/expired: the session is truly dead. Sign out cleanly
            // rather than let every authed call 401 forever.
            if (resp as? HTTPURLResponse)?.statusCode == 400 { signOut() }
            return nil
        }
        storeSession(json, fallbackEmail: email)
        return newToken
    }

    private func storeSession(_ json: [String: Any], fallbackEmail: String?) {
        accessToken = json["access_token"] as? String
        refreshToken = json["refresh_token"] as? String ?? refreshToken
        if let exp = json["expires_at"] as? Double { expiresAt = exp }
        else if let ttl = json["expires_in"] as? Double { expiresAt = Date.now.timeIntervalSince1970 + ttl }
        let user = json["user"] as? [String: Any]
        if let uid = user?["id"] as? String { userID = uid }
        email = user?["email"] as? String ?? fallbackEmail
        UserDefaults.standard.set(accessToken, forKey: "authToken")
        UserDefaults.standard.set(refreshToken, forKey: "authRefreshToken")
        UserDefaults.standard.set(expiresAt, forKey: "authExpiresAt")
        UserDefaults.standard.set(userID, forKey: "authUserID")
        UserDefaults.standard.set(email, forKey: "authEmail")
    }

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
              json["access_token"] is String,
              let user = json["user"] as? [String: Any],
              let uid = user["id"] as? String else {
            throw NSError(domain: "auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wrong or expired code"])
        }
        storeSession(json, fallbackEmail: email)
        Analytics.alias(userID: uid)
        Analytics.capture("login_success", ["method": "email_otp"])
        PushManager.shared.afterSignIn()
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
              json["access_token"] is String,
              let user = json["user"] as? [String: Any],
              let uid = user["id"] as? String else {
            throw NSError(domain: "auth", code: 3, userInfo: [NSLocalizedDescriptionKey: Self.supabaseError(data) ?? "Apple sign-in failed"])
        }
        storeSession(json, fallbackEmail: nil)
        Analytics.alias(userID: uid)
        Analytics.capture("login_success", ["method": "apple"])
        PushManager.shared.afterSignIn()
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
            // Always show Google's account chooser: the web session cookie was
            // silently auto-selecting whichever account was last signed in (Tom's
            // work account). GoTrue forwards this to Google's authorize URL.
            .init(name: "prompt", value: "select_account"),
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
        storeSession([
            "access_token": token,
            "refresh_token": kv["refresh_token"] as Any,
            "expires_in": Double(kv["expires_in"] ?? "") as Any,
            "user": user,
        ], fallbackEmail: nil)
        Analytics.alias(userID: uid)
        Analytics.capture("login_success", ["method": "google"])
        PushManager.shared.afterSignIn()
    }

    private static func supabaseError(_ data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["error_description"] ?? json?["msg"] ?? json?["message"]) as? String
    }

    func signOut() {
        let hadSession = accessToken != nil
        if hadSession { Task { await PushManager.shared.retireDevice() } }
        email = nil; accessToken = nil; userID = nil; refreshToken = nil; expiresAt = 0
        for k in ["authToken", "authUserID", "authEmail", "authRefreshToken", "authExpiresAt"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        Analytics.capture("sign_out")
    }

    /// Push local topic prefs to topic_subscriptions (RLS: user's own rows).
    /// notify_level: bell-toggled presets get 'high' (breaking only — high IS the push
    /// tier since 0021), customs get 'all' (radar semantics: any match is the product).
    func syncTopics(preset: [String], custom: [String]) async {
        guard let token = await validToken(), let uid = userID else { return }
        let bells = Set(UserDefaults.standard.stringArray(forKey: "notifyTopics") ?? [])
        let customLevels = UserDefaults.standard.dictionary(forKey: "customNotifyLevels") as? [String: String] ?? [:]
        let rows = preset.map { ["user_id": uid, "topic": $0, "kind": "preset",
                                 "notify_level": bells.contains($0) ? "high" : "none"] }
                 + custom.map { ["user_id": uid, "topic": $0, "kind": "custom",
                                 "notify_level": customLevels[$0] ?? "all"] }
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
