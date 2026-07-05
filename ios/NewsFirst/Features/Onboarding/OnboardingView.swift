import SwiftUI

/// First launch: welcome → pick topics → sign in → in. Topics BEFORE the sign-in ask
/// (v2's funnel died at topic selection — 38.5% — so value comes before the account).
struct OnboardingView: View {
    /// Tom's call (2026-07-05): the app requires an account. ⚠️ App Review rejected
    /// v2 (1.0.2, guideline 5.1.1(v)) for exactly this — flip to false to restore
    /// guest browsing if the 2.0.0 review pushes back.
    static let requiresAuth = true

    @Environment(FeedStore.self) private var store
    @Binding var done: Bool
    @State private var page = 0
    // No "world" preselect: Top Stories IS the front page — defaulting World on made
    // the first two chips read as the same thing twice. It stays available to pick.
    @State private var picked: Set<String> = ["tech", "business", "ai"]
    @State private var customsPicked: [String] = []
    @State private var customDraft = ""
    @FocusState private var draftFocused: Bool
    @State private var pulse = false
    @State private var auth = AuthClient.shared

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case 0: welcome
            case 1: topicPicker
            case 2: notificationsAsk
            default: signInGate
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .onAppear { Analytics.capture("onboarding_start") }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn, page == 3 {
                Analytics.capture("onboarding_complete", ["signed_in": true])
                withAnimation(Theme.Motion.feed) { done = true }
            }
        }
    }

    /// Notifications ask, right after topic investment — the highest-intent moment.
    /// The permission lands BEFORE sign-in: the device token parks in PushManager
    /// and flushes to the server the instant the account exists.
    private var notificationsAsk: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bolt.badge.clock.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Be first to know")
                .font(Theme.Text.hero)
            Text("Breaking stories on your topics, every match on your keywords, and a spoken briefing each morning at 10.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task {
                        await PushManager.shared.requestPermission()
                        advanceFromNotifications()
                    }
                } label: {
                    Text("Turn on notifications")
                        .font(Theme.Text.cardTitle)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.selectionGradient, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(PressableStyle())
                Button("Not now") { advanceFromNotifications() }
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .onAppear { Analytics.capture("onboarding_notif_ask") }
        }
    }

    private func advanceFromNotifications() {
        if Self.requiresAuth, !auth.isSignedIn {
            withAnimation(Theme.Motion.feed) { page = 3 }
        } else {
            withAnimation(Theme.Motion.feed) { done = true }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("NewsFirst")
                .font(.system(size: 42, weight: .heavy))
                .foregroundStyle(Theme.accent)
                .scaleEffect(pulse ? 1.05 : 0.97)
                .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
            Text("Be first to know")
                .font(Theme.Text.headline)
            Text("Follow the topics and keywords that matter to you.\nRuthlessly prioritised. Never a doomscroll.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                withAnimation(Theme.Motion.feed) { page = 1 }
            } label: {
                Text("Choose your topics")
                    .font(Theme.Text.cardTitle)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.selectionGradient, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PressableStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private var topicPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What do you care about?")
                .font(Theme.Text.hero)
                .padding(.top, 60)
            Text("Pick at least three — and add your own keywords below. They're the good part.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
            ScrollView {
                FlowChips(items: FeedStore.presetTopics, isOn: { picked.contains($0) }) { topic, on in
                    withAnimation(Theme.Motion.snappy) {
                        if on { picked.insert(topic) } else { picked.remove(topic) }
                    }
                }
                .padding(.top, 8)

                // The good part, delivered here: any keyword becomes a column with alerts.
                Text("YOUR OWN KEYWORDS")
                    .font(Theme.Text.badge).foregroundStyle(.secondary).kerning(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
                if !customsPicked.isEmpty {
                    FlowChips(items: customsPicked, isOn: { _ in true }) { topic, _ in
                        withAnimation(Theme.Motion.snappy) { customsPicked.removeAll { $0 == topic } }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                    TextField("Anything — a team, a stock, a person…", text: $customDraft)
                        .font(Theme.Text.meta)
                        .textFieldStyle(.plain)
                        .focused($draftFocused)
                        .submitLabel(.done)
                        .onSubmit { addCustomDraft() }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(draftFocused ? Theme.accent.opacity(0.6) : Theme.panelBorder, lineWidth: 1))
                .padding(.top, customsPicked.isEmpty ? 2 : 6)
                .padding(.bottom, 12)
            }
            Button {
                addCustomDraft()   // an un-submitted keyword still counts
                store.enabledTopics = FeedStore.presetTopics.filter { picked.contains($0) }
                customsPicked.forEach { store.addCustomTopic($0) }
                store.selectedTopic = FeedStore.topStories   // the front page, not the last-added column
                Analytics.capture("topics_selected", ["topics": Array(picked) + customsPicked,
                                                      "count": picked.count + customsPicked.count,
                                                      "customs": customsPicked.count,
                                                      "is_initial_setup": true])
                withAnimation(Theme.Motion.feed) { page = 2 }   // → notifications ask
            } label: {
                Text("Start reading")
                    .font(Theme.Text.cardTitle)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(picked.count >= 3 ? AnyShapeStyle(Theme.selectionGradient) : AnyShapeStyle(Color.gray.opacity(0.4)), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PressableStyle())
            .disabled(picked.count < 3)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 24)
    }

    private func addCustomDraft() {
        let t = customDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        customDraft = ""
        guard t.count >= 2, !customsPicked.contains(t), !FeedStore.presetTopics.contains(t) else { return }
        withAnimation(Theme.Motion.snappy) { customsPicked.append(t) }
    }

    /// Final gate: alerts, briefings and synced topics all hang off the account.
    private var signInGate: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("One last thing")
                .font(Theme.Text.hero)
            Text("NewsFirst is a notifications app — your alerts, topics and daily briefing need an account to live on.\nApple or Google is fine. Ten seconds.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Spacer()
            // Providers inline — the sheet-over-onboarding double layer read as rough.
            ProviderSignInButtons()
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .onAppear { Analytics.capture("onboarding_auth_gate") }
        }
    }
}
