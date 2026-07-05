import AuthenticationServices
import SwiftUI

/// Sign-in: Apple + Google only (Tom's call — email OTP removed 2026-07-05; the
/// AuthClient flow survives server-side if it's ever wanted back). Apple uses the
/// system button, Google the official G logo — v2.5's treatment.
struct AuthView: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthClient.shared
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sign in").font(Theme.Text.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.footnote.bold())
                        .padding(9).background(.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.top, 18)

            Text("Your topics, alerts and daily briefing sync to your account.")
                .font(Theme.Text.excerpt).foregroundStyle(.secondary)

            Spacer()

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let tokenData = credential.identityToken,
                          let idToken = String(data: tokenData, encoding: .utf8) else {
                        error = "Apple didn't return an identity token"
                        return
                    }
                    finishProvider { try await auth.signInWithApple(idToken: idToken) }
                case .failure(let e):
                    if (e as? ASAuthorizationError)?.code != .canceled { error = e.localizedDescription }
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Button {
                finishProvider { try await auth.signInWithGoogle() }
            } label: {
                HStack(spacing: 10) {
                    Spacer()
                    Image("GoogleLogo")
                        .resizable().scaledToFit()
                        .frame(width: 19, height: 19)
                    Text("Continue with Google")
                        .font(.system(size: 19, weight: .medium))
                    Spacer()
                }
                .padding(.vertical, 13)
                .foregroundStyle(.primary)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
                .overlay(alignment: .trailing) {
                    if busy { ProgressView().controlSize(.small).padding(.trailing, 16) }
                }
            }
            .buttonStyle(PressableStyle())

            if let error {
                Text(error).font(Theme.Text.meta).foregroundStyle(Theme.tierHigh)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .background(Theme.canvas)
        #if os(macOS)
        .frame(width: 393, height: 620)
        #endif
    }

    /// Shared tail for provider sign-ins: run the flow, sync topics, close.
    private func finishProvider(_ flow: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do {
                try await flow()
                await auth.syncTopics(preset: store.enabledTopics, custom: store.customTopics)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
