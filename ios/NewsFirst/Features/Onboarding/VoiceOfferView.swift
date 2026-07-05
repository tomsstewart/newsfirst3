import SwiftUI

/// One-time offer after first sign-in: the Kokoro studio voice (~86 MB, on-device).
/// Live progress from KokoroEngine; declining is always available — Apple's premium
/// voice remains the fallback narrator.
struct VoiceOfferView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine = KokoroEngine.shared

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative, isActive: isDownloading)
            Text("Add the HD voice")
                .font(Theme.Text.headline)
            Text("A studio-quality voice reads your briefings — one-time 86 MB download, then it works offline.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            switch engine.state {
            case .downloading(let p):
                VStack(spacing: 8) {
                    ProgressView(value: p)
                        .tint(Theme.accent)
                    Text("\(Int(p * 100))%")
                        .font(Theme.Text.meta).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 24)
            case .preparing:
                ProgressView("Preparing the voice…")
                    .font(Theme.Text.meta)
            case .ready:
                Label("Installed — briefings now use the HD voice", systemImage: "checkmark.circle.fill")
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.accent)
                    .task {
                        try? await Task.sleep(for: .seconds(1.2))
                        dismiss()
                    }
            case .failed(let message):
                Text(message)
                    .font(Theme.Text.meta).foregroundStyle(Theme.tierHigh)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                actionButton("Try again")
            case .notInstalled:
                actionButton("Download HD voice")
            }

            Spacer()
            if !isDone {
                Button(isDownloading ? "Continue in background" : "Not now") { dismiss() }
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.bottom, 30)
            }
        }
        .padding(.horizontal, 24)
        .background(Theme.canvas)
        .onAppear { Analytics.capture("hd_voice_offer") }
    }

    private var isDownloading: Bool {
        if case .downloading = engine.state { return true }
        return engine.state == .preparing
    }
    private var isDone: Bool { engine.state == .ready }

    private func actionButton(_ title: String) -> some View {
        Button {
            engine.download()
            Analytics.capture("hd_voice_download_start")
        } label: {
            Text(title)
                .font(Theme.Text.cardTitle)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.selectionGradient, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressableStyle())
    }
}
