import SwiftUI
#if canImport(Inject)
import Inject
#endif

// MARK: - Article image (proxied, cached, honest fallback)

struct ArticleImage: View {
    let article: Article
    let width: Int
    var body: some View {
        if let orig = article.imageURL, let cg = ImagePipeline.preloaded[orig] {
            Image(decorative: cg, scale: 2).resizable().aspectRatio(contentMode: .fill)
        } else if let url = ImageProxy.url(article.imageURL, width: width) {
            AsyncImage(url: url, transaction: Transaction(animation: Theme.Motion.card)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                case .failure:
                    TopicPlaceholder(topic: article.topics.first ?? "news")
                default:
                    Rectangle().fill(.quaternary).shimmer()
                }
            }
        } else {
            TopicPlaceholder(topic: article.topics.first ?? "news")
        }
    }
}

// MARK: - LIST: dense, fast-scan rows (thumbnail right, like a real list)

struct ListFeedView: View {
    @Environment(FeedStore.self) private var store
    @State private var expandedID: UUID?
    @Namespace private var expand

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(store.visible.enumerated()), id: \.element.id) { index, article in
                    row(article)
                    if index < store.visible.count - 1 {
                        Divider().padding(.leading, 16)
                            .opacity(expandedID == article.id ? 0 : 1)
                    }
                }
            }
            .background(Theme.rowBackground, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .refreshable { await store.refresh() }
        .background(Theme.groupedBackground)
    }

    /// Tap a row → just that article morphs into the immersive-style card, in place.
    @ViewBuilder private func row(_ article: Article) -> some View {
        if expandedID == article.id {
            ExpandedListCard(article: article) {
                withAnimation(Theme.Motion.card) { expandedID = nil }
            }
            .matchedGeometryEffect(id: article.id, in: expand)
            .padding(.vertical, 8).padding(.horizontal, 8)
        } else {
            ListRow(article: article)
                .matchedGeometryEffect(id: article.id, in: expand)
                .onTapGesture {
                    withAnimation(Theme.Motion.card) { expandedID = article.id }
                }
        }
    }
}

/// The in-place expansion: immersive card + reader affordance + collapse chevron.
struct ExpandedListCard: View {
    @Environment(FeedStore.self) private var store
    let article: Article
    let collapse: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { store.reading = article } label: {
                ImmersiveCard(article: article, hero: true)
            }
            .buttonStyle(PressableStyle())
            Button(action: collapse) {
                Image(systemName: "chevron.up")
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(PressableStyle())
            .padding(10)
        }
    }
}

struct ListRow: View {
    let article: Article
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(article.title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                SourceLine(article: article)
            }
            Spacer(minLength: 0)
            ArticleImage(article: article, width: 160)
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - IMMERSIVE: rich card feed (hero + cards with excerpts)

struct ImmersiveFeedView: View {
    @Environment(FeedStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(Array(store.visible.enumerated()), id: \.element.id) { index, article in
                    Button { store.reading = article } label: {
                        ImmersiveCard(article: article, hero: index == 0)
                    }
                    .buttonStyle(PressableStyle())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
        .refreshable { await store.refresh() }
        .background(Theme.groupedBackground)
    }
}

struct ImmersiveCard: View {
    let article: Article
    var hero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArticleImage(article: article, width: hero ? 800 : 640)
                .frame(height: hero ? 230 : 178)
                .clipped()
            VStack(alignment: .leading, spacing: 7) {
                SourceLine(article: article)
                Text(article.title)
                    .font(hero ? Theme.Text.hero : Theme.Text.cardTitle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if hero, let excerpt = article.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.Text.excerpt)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(14)
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        .contentShape(Rectangle())
    }
}

// MARK: - FULL: full-bleed vertical pager (TikTok feel)

struct FullFeedView: View {
    @Environment(FeedStore.self) private var store

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(store.visible) { article in
                        FullPage(article: article)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
        }
        .ignoresSafeArea(edges: .bottom)
        .background(.black)
    }
}

struct FullPage: View {
    let article: Article
    @Environment(FeedStore.self) private var store

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArticleImage(article: article, width: 900)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.9)],
                           startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TierBadge(tier: article.tier, loud: true)
                    Text(article.sourceName).font(Theme.Text.meta)
                    Text(article.publishedAt, format: .relative(presentation: .named)).font(Theme.Text.meta).opacity(0.75)
                }
                .foregroundStyle(.white)
                Text(article.title)
                    .font(Theme.Text.hero)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let excerpt = article.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.Text.excerpt)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(3)
                }
                Button { store.reading = article } label: {
                    Text("Read article")
                        .font(Theme.Text.cardTitle)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(.white.opacity(0.22), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(22)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { store.reading = article }
    }
}

// MARK: - Skeletons (animated placeholders while the very first load happens)

struct FeedSkeleton: View {
    let mode: ViewMode
    var body: some View {
        switch mode {
        case .list:
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(height: 14)
                            SkeletonBlock(height: 14).frame(width: 190)
                            SkeletonBlock(height: 10).frame(width: 120)
                        }
                        Spacer()
                        SkeletonBlock(height: 74, radius: 10).frame(width: 74)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    if i < 7 { Divider().padding(.leading, 16) }
                }
            }
            .background(Theme.rowBackground, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12).padding(.top, 6)
            Spacer(minLength: 0)
        case .immersive:
            VStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBlock(height: i == 0 ? 230 : 178, radius: 0)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(height: 10).frame(width: 130)
                            SkeletonBlock(height: 18)
                            SkeletonBlock(height: 18).frame(width: 220)
                        }
                        .padding(14)
                    }
                    .background(Theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding(.horizontal, 14).padding(.top, 6)
            Spacer(minLength: 0)
        case .full:
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.quaternary).shimmer()
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(height: 20).frame(width: 90)
                    SkeletonBlock(height: 26)
                    SkeletonBlock(height: 26).frame(width: 240)
                }
                .padding(22).padding(.bottom, 34)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Empty state for topics with no matches yet (e.g. a fresh custom topic).
struct EmptyTopicView: View {
    let topic: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Nothing on “\(topic.capitalized)” yet")
                .font(Theme.Text.cardTitle)
            Text("Your radar is on. New matches appear here the moment they're published.")
                .font(Theme.Text.excerpt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
