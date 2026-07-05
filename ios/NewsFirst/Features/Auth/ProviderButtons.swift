import AuthenticationServices
import SwiftUI

/// The Apple + Google pair, shared by the onboarding gate (inline) and the Settings
/// sign-in sheet — one implementation, one look: matched heights, the app's 16pt
/// radius, Apple's system button + Google's official G on white.
struct ProviderSignInButtons: View {
    @Environment(FeedStore.self) private var store
    @State private var auth = AuthClient.shared
    @State private var busy = false
    @State private var error: String?
    var onSignedIn: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
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
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Button {
                finishProvider { try await auth.signInWithGoogle() }
            } label: {
                HStack(spacing: 8) {
                    Image("GoogleLogo")
                        .resizable().scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("Continue with Google")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.black.opacity(0.87))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .trailing) {
                    if busy { ProgressView().controlSize(.small).padding(.trailing, 16).tint(.black) }
                }
            }
            .buttonStyle(PressableStyle())

            if let error {
                Text(error)
                    .font(Theme.Text.meta).foregroundStyle(Theme.tierHigh)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Shared tail for provider sign-ins: run the flow, sync topics, hand back.
    private func finishProvider(_ flow: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do {
                try await flow()
                await auth.syncTopics(preset: store.enabledTopics, custom: store.customTopics)
                onSignedIn()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
