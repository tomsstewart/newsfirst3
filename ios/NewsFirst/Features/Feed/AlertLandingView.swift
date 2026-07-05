import SwiftUI

/// Notification tap lands HERE — the story front-and-centre with an explicit choice
/// (hear it or read it) instead of being dropped straight into the web reader.
struct AlertLandingView: View {
    let article: Article
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var speech = Speech.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ArticleImage(article: article, width: 800)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 8) {
                if article.tier == .high { TierBadge(tier: .high, loud: true) }
                Text(article.sourceName).font(Theme.Text.badge).foregroundStyle(Theme.accent)
                if let t = article.topics.first {
                    Text(FeedStore.displayName(t).uppercased())
                        .font(Theme.Text.badge)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(article.publishedAt, format: .relative(presentation: .named))
                    .font(Theme.Text.meta).foregroundStyle(.secondary)
            }
            Text(article.title)
                .font(Theme.Text.headline)
                .multilineTextAlignment(.leading)
            if let excerpt = article.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(Theme.Text.excerpt).foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button {
                    speech.toggle(speechParts)
                    Analytics.capture("alert_landing_listen")
                } label: {
                    Label(speech.isSpeaking ? "Stop" : "Listen",
                          systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                        .font(Theme.Text.cardTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressableStyle())
                Button {
                    dismiss()
                    // Let the sheet finish dismissing before the reader presents.
                    Task {
                        try? await Task.sleep(for: .milliseconds(380))
                        store.reading = article
                    }
                } label: {
                    Label("Read article", systemImage: "doc.text")
                        .font(Theme.Text.cardTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.selectionGradient, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(20)
        .background(Theme.canvas)
        .onAppear { Analytics.capture("alert_landing_open") }
    }

    private var speechParts: [String] {
        var parts = ["From \(article.sourceName): \(article.title)."]
        if let excerpt = article.excerpt, !excerpt.isEmpty { parts.append(excerpt) }
        return parts
    }
}
