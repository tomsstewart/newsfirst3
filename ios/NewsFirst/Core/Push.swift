import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Push registration + device sync + open-from-alert routing.
///
/// Permission is requested at the moment of intent (first bell toggle, or sign-in with
/// bells already on) — never at launch; push adoption is the activation metric and a
/// cold prompt is how it gets burned. The APNs token lands in `devices` (RLS: own rows),
/// so registration is only possible signed-in; a token that arrives signed-out is parked
/// and flushed by `afterSignIn()`.
@MainActor
final class PushManager: NSObject {
    static let shared = PushManager()

    /// Set by RootView: routes a notification tap to the reader (article_id, alert_id).
    var openArticle: ((String, String?) -> Void)?
    /// Set by RootView: a daily-brief notification tap starts the spoken briefing.
    var playBrief: (() -> Void)?
    /// A tap that arrived before RootView mounted (cold start from a notification).
    private var pendingOpen: (article: String, alert: String?)?
    private var pendingBrief = false
    private var parkedToken: String?
    private let defaults = UserDefaults.standard

    #if DEBUG
    private let environment = "sandbox"   // Xcode/sim builds use the APNs sandbox
    #else
    private let environment = "prod"      // TestFlight/App Store
    #endif

    // MARK: permission & registration

    /// First bell toggle / sign-in with bells on. Safe to call repeatedly.
    func enablePush() {
        Task { await requestPermission() }
    }

    /// The awaited core: onboarding's notifications page needs to know when the
    /// system dialog resolved so it can advance. Returns whether push is enabled.
    @discardableResult
    func requestPermission() async -> Bool {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            Analytics.capture("push_permission", ["granted": granted])
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            return granted
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
            return true
        default:
            return false   // denied: Settings.app is the only way back; don't nag
        }
        #else
        return false
        #endif
    }

    /// Launch path: refresh the token silently if permission already exists (APNs
    /// tokens rotate; a stale row means dead alerts with no error anywhere).
    func registerIfAuthorized() async {
        #if os(iOS)
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        // Breadcrumb every launch: permission state × auth state — the registration
        // funnel was failing invisibly on-device with zero server-side traces.
        Analytics.capture("push_status", [
            "authorization": String(status.rawValue),
            "signed_in": AuthClient.shared.isSignedIn,
            "registered": UIApplication.shared.isRegisteredForRemoteNotifications,
        ])
        guard AuthClient.shared.isSignedIn else { return }
        if status == .authorized || status == .provisional || status == .ephemeral {
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
    }

    func tokenReceived(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Analytics.capture("push_token_received", ["environment": environment])
        Task { await upsertDevice(token) }
    }

    func afterSignIn() {
        if let parked = parkedToken { Task { await upsertDevice(parked) } }
        if !(defaults.stringArray(forKey: "notifyTopics") ?? []).isEmpty { enablePush() }
        Task { await AuthClient.shared.syncTopics(
            preset: defaults.stringArray(forKey: "enabledTopics") ?? [],
            custom: defaults.stringArray(forKey: "customTopics") ?? []) }
    }

    private func upsertDevice(_ token: String) async {
        guard let jwt = await AuthClient.shared.validToken(), let uid = AuthClient.shared.userID else {
            parkedToken = token
            Analytics.capture("device_upsert_parked", ["reason": "no-valid-session"])
            return
        }
        parkedToken = nil
        var req = URLRequest(url: URL(string: SupabaseAPI.projectURL.absoluteString
            + "/rest/v1/devices?on_conflict=apns_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [[
            "user_id": uid, "apns_token": token, "environment": environment,
            "is_valid": true, "last_seen_at": ISO8601DateFormatter().string(from: .now),
        ]])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            Analytics.capture("device_upsert", ["status": (resp as? HTTPURLResponse)?.statusCode ?? -1])
        } catch {
            Analytics.capture("device_upsert", ["status": -1, "error": error.localizedDescription])
        }
        defaults.set(token, forKey: "apnsToken")

        // Keep the user's timezone fresh: the daily brief fires at 10:00 in THIS tz.
        var tzReq = URLRequest(url: URL(string: SupabaseAPI.projectURL.absoluteString
            + "/rest/v1/notification_settings?on_conflict=user_id")!)
        tzReq.httpMethod = "POST"
        tzReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tzReq.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        tzReq.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        tzReq.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        tzReq.httpBody = try? JSONSerialization.data(withJSONObject: [[
            "user_id": uid, "tz": TimeZone.current.identifier,
        ]])
        _ = try? await URLSession.shared.data(for: tzReq)
    }

    /// Daily-brief opt-in/out — server-side so brief_push can filter before sending.
    func setDailyBrief(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: "dailyBriefOptIn")
        guard let jwt = await AuthClient.shared.validToken(), let uid = AuthClient.shared.userID else { return }
        var req = URLRequest(url: URL(string: SupabaseAPI.projectURL.absoluteString
            + "/rest/v1/notification_settings?on_conflict=user_id")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [["user_id": uid, "daily_brief": on]])
        _ = try? await URLSession.shared.data(for: req)
        Analytics.capture("daily_brief_toggle", ["on": on])
    }

    /// Sign-out: retire this device's row (best effort) so a shared phone can't keep
    /// receiving the previous account's alerts.
    func retireDevice() async {
        guard let token = defaults.string(forKey: "apnsToken"),
              let jwt = await AuthClient.shared.validToken() else { return }
        var req = URLRequest(url: URL(string: SupabaseAPI.projectURL.absoluteString
            + "/rest/v1/devices?apns_token=eq.\(token)")!)
        req.httpMethod = "DELETE"
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        defaults.removeObject(forKey: "apnsToken")
    }

    // MARK: open-from-alert

    func handleTap(article articleID: String?, alert alertID: String?, topic: String?, brief: Bool = false) {
        if let alertID { Task { await markOpened(alertID) } }
        if brief {
            Analytics.capture("notif_open", ["topic": "brief"])
            if let playBrief { playBrief() } else { pendingBrief = true }
            return
        }
        guard let articleID else { return }
        Analytics.capture("notif_open", ["topic": topic ?? "?"])
        if let openArticle { openArticle(articleID, alertID) }
        else { pendingOpen = (articleID, alertID) }
    }

    /// RootView calls this once its handlers are installed (cold-start tap ordering).
    func flushPendingOpen() {
        if let p = pendingOpen, let openArticle { pendingOpen = nil; openArticle(p.article, p.alert) }
        if pendingBrief, let playBrief { pendingBrief = false; playBrief() }
    }

    /// alerts.opened_at closes the funnel: sent → delivered → opened, finally measurable.
    private func markOpened(_ alertID: String) async {
        guard let jwt = await AuthClient.shared.validToken() else { return }
        var req = URLRequest(url: URL(string: SupabaseAPI.projectURL.absoluteString
            + "/rest/v1/alerts?id=eq.\(alertID)")!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseAPI.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["opened_at": ISO8601DateFormatter().string(from: .now)])
        _ = try? await URLSession.shared.data(for: req)
    }
}

#if os(iOS)
/// UIKit bridge: token callbacks + notification delegate.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.tokenReceived(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let message = error.localizedDescription
        print("push: registration failed — \(message)")
        Task { @MainActor in Analytics.capture("push_register_failed", ["error": message]) }
    }

    /// Alerts stay visible in the foreground — a breaking story is exactly when
    /// the user is most likely to already be in the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        // Pull the Sendable bits out before hopping actors ([AnyHashable: Any] can't cross).
        let userInfo = response.notification.request.content.userInfo
        let article = userInfo["article_id"] as? String
        let alert = userInfo["alert_id"] as? String
        let topic = userInfo["topic"] as? String
        let brief = userInfo["brief"] as? String == "1"
        await MainActor.run { PushManager.shared.handleTap(article: article, alert: alert, topic: topic, brief: brief) }
    }
}
#endif
