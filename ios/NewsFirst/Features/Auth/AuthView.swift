import SwiftUI

/// Sign-in: email code works end-to-end today; Apple/Google activate once the
/// app's signing capabilities exist (Apple Developer portal — needs the account owner).
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

            disabledProviderButton("Continue with Apple", system: "applelogo")
            disabledProviderButton("Continue with Google", system: "globe")
            Text("Apple & Google sign-in activate with the next TestFlight build.")
                .font(Theme.Text.meta).foregroundStyle(.tertiary)

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

    private func disabledProviderButton(_ title: String, system: String) -> some View {
        HStack {
            Image(systemName: system)
            Text(title).font(Theme.Text.cardTitle)
            Spacer()
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
        .opacity(0.45)
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
