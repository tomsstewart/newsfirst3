import SwiftUI

/// The header bell's inbox: current breaking stories (High = notification-grade),
/// one per cluster. Becomes the push-notification history once APNs lands.
struct BreakingInboxView: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var reading: Article?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "bell.badge.fill").font(.subheadline).foregroundStyle(Theme.accent)
                    Text("Notifications").font(Theme.Text.headline)
                }
                Spacer()
                // Clear all: hides everything sent so far (local watermark; history stays server-side).
                if !store.inbox.isEmpty {
                    Button { store.clearInbox() } label: {
                        Text("Clear all").font(Theme.Text.meta).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(PressableStyle())
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.footnote.bold()).foregroundStyle(.primary)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.inbox.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bell.slash").font(.system(size: 30)).foregroundStyle(.tertiary)
                            Text("No notifications yet")
                                .font(Theme.Text.cardTitle)
                            Text("Stories you've been alerted about land here. Turn on the bell for a topic or Top Stories to start.")
                                .font(Theme.Text.excerpt).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    } else {
                        ForEach(store.inbox) { item in
                            let a = item.article
                            Button {
                                // Same landing card as a real push tap (hear it / read it).
                                // It presents from the root, so the inbox steps aside first.
                                dismiss()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(380))
                                    store.alertLanding = a
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(a.sourceName).font(Theme.Text.badge).foregroundStyle(Theme.accent)
                                        if let t = a.topics.first {
                                            Text(FeedStore.displayName(t).uppercased())
                                                .font(Theme.Text.badge)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(.primary.opacity(0.08), in: Capsule())
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        // When it notified you (not when published).
                                        Text(item.sentAt, format: .relative(presentation: .named))
                                            .font(Theme.Text.meta).foregroundStyle(.secondary)
                                    }
                                    Text(a.title)
                                        .font(Theme.Text.rowTitle).foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading).lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Theme.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
        }
        .task { await store.loadInbox() }
        .background(Theme.canvas)
        .preferredColorScheme(store.appearance.scheme)
        #if os(iOS)
        .fullScreenCover(item: $reading) { ReaderSheet(article: $0) }
        #else
        .sheet(item: $reading) { ReaderSheet(article: $0) }
        #endif
    }
}

/// Full Coverage: one story, every telling — the industry pattern (Google News):
/// dedupe the feed to one representative per cluster, then give the cluster its own
/// page listing all sources chronologically, each opening in the reader.
struct StoryView: View {
    let seed: Article
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var coverage: [Article] = []
    @State private var reading: Article?
    private let api = SupabaseAPI()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ArticleImage(article: seed, width: 800)
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    Text(seed.title)
                        .font(Theme.Text.hero)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TierBadge(tier: seed.tier, loud: true)
                        Text("\(max(coverage.count, seed.clusterSources ?? 1)) sources")
                            .font(Theme.Text.meta).foregroundStyle(.secondary)
                        if let first = coverage.first {
                            Text("· first reported \(first.publishedAt, format: .relative(presentation: .named))")
                                .font(Theme.Text.meta).foregroundStyle(.secondary)
                        }
                    }
                    Text("COVERAGE TIMELINE")
                        .font(Theme.Text.badge).foregroundStyle(.secondary).kerning(0.8)
                        .padding(.top, 6)
                    if coverage.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 20)
                    } else {
                        ForEach(coverage) { a in coverageRow(a) }
                    }
                }
                .padding(16)
                .padding(.bottom, 30)
            }
        }
        .background(Theme.canvas)
        .task {
            guard let cid = seed.clusterID else { coverage = [seed]; return }
            coverage = (try? await api.fetchCluster(cid)) ?? [seed]
        }
        #if os(iOS)
        .fullScreenCover(item: $reading) { ReaderSheet(article: $0) }
        #else
        .sheet(item: $reading) { ReaderSheet(article: $0) }
        #endif
    }

    private var header: some View {
        HStack {
            Text("Full Coverage").font(Theme.Text.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.bold())
                    .foregroundStyle(.primary)
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.canvas)
    }

    private func coverageRow(_ a: Article) -> some View {
        Button { reading = a } label: {
            HStack(alignment: .center, spacing: 0) {
                // A mixture: imaged tellings get a tile-sized picture (edge-to-edge,
                // like the list feed), text-only ones stay lean.
                if a.imageURL != nil {
                    ArticleImage(article: a, width: 400)
                        .frame(width: 100)
                        .frame(maxHeight: .infinity)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(a.sourceName)
                            .font(Theme.Text.badge)
                            .foregroundStyle(Theme.accent)
                            .kerning(0.4)
                        Spacer()
                        Text(a.publishedAt, format: .relative(presentation: .named))
                            .font(Theme.Text.meta).foregroundStyle(.secondary)
                    }
                    Text(a.title)
                        .font(Theme.Text.rowTitle)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: a.imageURL != nil ? 96 : nil)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }
}
