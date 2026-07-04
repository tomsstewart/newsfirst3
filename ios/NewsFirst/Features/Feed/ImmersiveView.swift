import SwiftUI
import Inject

/// Immersive view — full-bleed vertical paging, TikTok-feel.
/// v2 data: immersive sessions ran 2.4× longer with 2.3× the reading depth — this is the
/// engagement surface, and the hardest 120Hz surface in the app. Keep it dumb: paging +
/// pre-warmed images, zero work during scroll.
struct ImmersiveView: View {
    @Environment(FeedStore.self) private var store
    @ObserveInjection var inject

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(store.visible) { article in
                    ImmersivePage(article: article)
                        .containerRelativeFrame(.vertical)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .ignoresSafeArea()
        .background(.black)
        .enableInjection()
    }
}

struct ImmersivePage: View {
    let article: Article

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            imageView
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(article.tier.rawValue.uppercased())
                        .font(Theme.Type.meta)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.tierColor(article.tier), in: Capsule())
                    Text(article.sourceName).font(Theme.Type.meta)
                }
                .foregroundStyle(.white)
                Text(article.title)
                    .font(Theme.Type.headline)
                    .foregroundStyle(.white)
                if let excerpt = article.excerpt {
                    Text(excerpt)
                        .font(Theme.Type.excerpt)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                }
                Link("Read article", destination: article.url)
                    .font(Theme.Type.cardTitle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white.opacity(0.2), in: Capsule())
            }
            .padding(24)
            .padding(.bottom, 40)
        }
    }

    @ViewBuilder private var imageView: some View {
        GeometryReader { geo in
            if let url = article.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    default:
                        TopicPlaceholder(topic: article.topics.first ?? "news")
                    }
                }
            } else {
                TopicPlaceholder(topic: article.topics.first ?? "news")
            }
        }
    }
}
