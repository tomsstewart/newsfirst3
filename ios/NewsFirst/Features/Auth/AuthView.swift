import SwiftUI

/// Settings-path sign-in sheet, composed like an onboarding page: pulsing brand,
/// headline, excerpt copy, providers where the CTA lives. (The onboarding gate
/// itself embeds ProviderSignInButtons inline — no sheet-on-page double layer.)
struct AuthView: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.footnote.bold())
                        .padding(9).background(.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.top, 18)

            Spacer()
            Text("NewsFirst")
                .font(.system(size: 42, weight: .heavy))
                .foregroundStyle(Theme.accent)
                .scaleEffect(pulse ? 1.05 : 0.97)
                .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
            Text("Sign in")
                .font(Theme.Text.headline)
            Text("Your topics, alerts and daily briefing\nsync to your account.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()

            ProviderSignInButtons(onSignedIn: { dismiss() })
                .padding(.bottom, 40)
        }
        .padding(.horizontal, 24)
        .background(Theme.canvas)
        #if os(macOS)
        .frame(width: 393, height: 620)
        #endif
    }
}
