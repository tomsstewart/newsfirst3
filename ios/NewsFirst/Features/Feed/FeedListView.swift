import SwiftUI
#if canImport(Inject)
import Inject
#endif

/// The List view — the fast catch-up surface.
struct FeedListView: View {
    @Environment(FeedStore.self) private var store
    #if canImport(Inject)
    @ObserveInjection var inject   // hot reload via InjectionIII
    #endif

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.visible) { article in
                    ArticleCard(article: article)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 16)
        }
        .refreshable { await store.refresh() }
        .background(Theme.groupedBackground)
        #if canImport(Inject)
        .enableInjection()
        #endif
    }
}

struct ArticleCard: View {
    let article: Article

    var body: some View {
        Link(destination: article.url) {
            VStack(alignment: .leading, spacing: 8) {
                imageView
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 6) {
                    Capsule()
                        .fill(Theme.tierColor(article.tier))
                        .frame(width: 6, height: 6)
                    Text(article.sourceName)
                    Text("·")
                    Text(article.publishedAt, format: .relative(presentation: .named))
                }
                .font(Theme.Text.meta)
                .foregroundStyle(.secondary)
                Text(article.title)
                    .font(Theme.Text.cardTitle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .padding(12)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var imageView: some View {
        if let url = article.imageURL, let cg = ImagePipeline.preloaded[url] {
            Image(decorative: cg, scale: 2).resizable().aspectRatio(contentMode: .fill)
        } else if let url = article.imageURL {
            // Phase 3: route through the image proxy (resize + cache + hotlink immunity)
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default: TopicPlaceholder(topic: article.topics.first ?? "news")
                }
            }
        } else {
            TopicPlaceholder(topic: article.topics.first ?? "news")
        }
    }
}

#if canImport(Inject)
#Preview {
    FeedListView().environment(FeedStore())
}
#endif
