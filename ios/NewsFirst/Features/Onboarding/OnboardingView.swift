import SwiftUI

/// First launch: welcome → pick topics → in. Topics BEFORE any sign-in ask
/// (v2's funnel died at topic selection — 38.5% — so this flow is two taps minimum).
struct OnboardingView: View {
    @Environment(FeedStore.self) private var store
    @Binding var done: Bool
    @State private var page = 0
    @State private var picked: Set<String> = ["world", "tech", "business"]
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            if page == 0 { welcome } else { topicPicker }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .onAppear { Analytics.capture("onboarding_start") }
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
                withAnimation(Theme.Motion.feed) { done = true }
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
}
