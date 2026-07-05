import AuthenticationServices
import SwiftUI

/// Sign-in: email code + native Apple + Google (web flow). Apple works on the
/// simulator now; device builds need the portal capability. Google lights up once
/// its OAuth client is configured in Supabase.
struct AuthView: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthClient.shared
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
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

            Text("Your topics and alerts sync to your account — and keyword notifications need one.")
                .font(Theme.Text.excerpt).foregroundStyle(.secondary)

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
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Button {
                finishProvider { try await auth.signInWithGoogle() }
            } label: {
                HStack {
                    Image(systemName: "globe")
                    Text("Continue with Google").font(Theme.Text.cardTitle)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(14)
                .foregroundStyle(.primary)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())

            Divider().padding(.vertical, 4)

            Text(codeSent ? "Enter the 6-digit code we emailed you" : "Or use your email")
                .font(Theme.Text.rowTitle)
            if !codeSent {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(12)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            } else {
                TextField("123456", text: $code)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .font(.system(.title3, design: .monospaced))
                    .padding(12)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            if let error {
                Text(error).font(Theme.Text.meta).foregroundStyle(Theme.tierHigh)
            }
            Button(action: submit) {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(codeSent ? "Verify" : "Email me a code")
                        .font(Theme.Text.cardTitle).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.selectionGradient, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressableStyle())
            .disabled(busy || (codeSent ? code.count < 6 : !email.contains("@")))
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

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                if codeSent {
                    try await auth.verify(email: email, code: code)
                    await auth.syncTopics(preset: store.enabledTopics, custom: store.customTopics)
                    dismiss()
                } else {
                    try await auth.requestCode(email: email)
                    withAnimation(Theme.Motion.snappy) { codeSent = true }
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
