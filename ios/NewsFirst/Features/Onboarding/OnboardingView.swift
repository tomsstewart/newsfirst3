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
    @State private var picked: Set<String> = ["world", "tech", "business"]
    @State private var pulse = false
    @State private var showAuthSheet = false
    @State private var auth = AuthClient.shared

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case 0: welcome
            case 1: topicPicker
            default: signInGate
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .onAppear { Analytics.capture("onboarding_start") }
        .sheet(isPresented: $showAuthSheet) { AuthView().preferredColorScheme(store.appearance.scheme) }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn, page == 2 {
                showAuthSheet = false
                Analytics.capture("onboarding_complete", ["signed_in": true])
                withAnimation(Theme.Motion.feed) { done = true }
            }
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
            Text("Pick at least three. Custom keyword topics come next — they're the good part.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
            ScrollView {
                FlowChips(items: FeedStore.presetTopics, isOn: { picked.contains($0) }) { topic, on in
                    withAnimation(Theme.Motion.snappy) {
                        if on { picked.insert(topic) } else { picked.remove(topic) }
                    }
                }
                .padding(.top, 8)
            }
            Button {
                store.enabledTopics = FeedStore.presetTopics.filter { picked.contains($0) }
                store.selectedTopic = store.enabledTopics.first ?? "world"
                Analytics.capture("topics_selected", ["topics": Array(picked), "count": picked.count, "is_initial_setup": true])
                if Self.requiresAuth, !auth.isSignedIn {
                    withAnimation(Theme.Motion.feed) { page = 2 }
                } else {
                    withAnimation(Theme.Motion.feed) { done = true }
                }
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

    /// Final gate: alerts, briefings and synced topics all hang off the account.
    private var signInGate: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("One last thing")
                .font(Theme.Text.hero)
            Text("Your topics, breaking-news alerts and the daily spoken briefing live on your account.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Spacer()
            Button {
                showAuthSheet = true
            } label: {
                Text("Sign in to start reading")
                    .font(Theme.Text.cardTitle)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.selectionGradient, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PressableStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .onAppear { Analytics.capture("onboarding_auth_gate") }
        }
    }
}
