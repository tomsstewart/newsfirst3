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
                    Rectangle().fill(.white.opacity(0.05)).shimmer()
                }
            }
        } else {
            TopicPlaceholder(topic: article.topics.first ?? "news")
        }
    }
}

// MARK: - LIST: priority bands + dense rows; tap = morph-expand in place, tap again = shrink back

struct ListFeedView: View {
    @Environment(FeedStore.self) private var store
    @State private var expandedID: UUID?
    @State private var lowHidden = false

    private var bands: [(tier: Article.Tier, items: [Article])] {
        let v = store.visible
        return [Article.Tier.high, .medium, .low].compactMap { tier in
            let items = v.filter { $0.tier == tier }
            return items.isEmpty ? nil : (tier, items)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(bands.enumerated()), id: \.element.tier) { bandIndex, band in
                    PriorityBand(tier: band.tier, trailing: band.tier == .low ? AnyView(hideButton) : nil)
                        .kineticEntrance(bandIndex * 3)
                    if !(band.tier == .low && lowHidden) {
                        ForEach(Array(band.items.enumerated()), id: \.element.id) { i, article in
                            articleCell(article)
                                .kineticEntrance(bandIndex * 3 + i + 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .background(Theme.canvas)
    }

    private var hideButton: some View {
        Button {
            withAnimation(Theme.Motion.card) { lowHidden.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: lowHidden ? "eye" : "eye.slash").font(.caption2)
                Text(lowHidden ? "Show" : "Hide")
            }
            .font(Theme.Text.meta)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassChip()
        }
        .buttonStyle(PressableStyle())
    }

    /// One article cell: collapsed row ⇄ expanded card as a pure vertical unfold.
    private func articleCell(_ article: Article) -> some View {
        ArticleExpandableCell(article: article, expanded: expandedID == article.id) {
            withAnimation(Theme.Motion.card) {
                expandedID = expandedID == article.id ? nil : article.id
            }
        }
    }
}

/// Accordion cell: the hero image unfolds down from the top edge; text reflows beneath.
/// Same identity collapsed/expanded, so the animation is strictly up/down.
struct ArticleExpandableCell: View {
    @Environment(FeedStore.self) private var store
    let article: Article
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                ArticleImage(article: article, width: 800)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TierBadge(tier: article.tier, loud: true)
                        Text(article.publishedAt, format: .relative(presentation: .named))
                            .font(Theme.Text.meta).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(article.title)
                        .font(Theme.Text.hero)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let excerpt = article.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(Theme.Text.excerpt)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    HStack {
                        Text(article.sourceName)
                            .font(Theme.Text.meta).foregroundStyle(Theme.link).underline()
                        Spacer()
                        Button { store.reading = article } label: {
                            Text("Read article")
                                .font(Theme.Text.rowTitle)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .glassChip(prominent: true)
                        }
                        .buttonStyle(PressableStyle())
                    }
                    .padding(.top, 2)
                }
                .padding(14)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                ListRow(article: article)
                    .transition(.opacity)
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 18 : 14))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 18 : 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: expanded ? 14 : 0, y: expanded ? 6 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

/// v2-style row: thumbnail left, 2-line title, 2-line excerpt, source link + date.
struct ListRow: View {
    let article: Article

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArticleImage(article: article, width: 220)
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let excerpt = article.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.Text.excerpt)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                SourceLine(article: article).padding(.top, 4)
            }
        }
        .padding(10)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
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
                    .kineticEntrance(index)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .background(Theme.canvas)
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
                HStack(spacing: 8) {
                    TierBadge(tier: article.tier)
                    Text(article.publishedAt, format: .relative(presentation: .named))
                        .font(Theme.Text.meta).foregroundStyle(.secondary)
                }
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
                Text(article.sourceName)
                    .font(Theme.Text.meta).foregroundStyle(Theme.link).underline()
            }
            .padding(14)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
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
                        .glassChip()
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

// MARK: - Skeletons (glassy animated placeholders)

struct FeedSkeleton: View {
    let mode: ViewMode
    var body: some View {
        switch mode {
        case .list:
            VStack(spacing: 10) {
                SkeletonBlock(height: 36, radius: 10)
                ForEach(0..<5, id: \.self) { i in
                    HStack(alignment: .top, spacing: 12) {
                        SkeletonBlock(height: 92, radius: 10).frame(width: 92)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(height: 13)
                            SkeletonBlock(height: 13).frame(width: 190)
                            SkeletonBlock(height: 10).frame(width: 220)
                            SkeletonBlock(height: 10).frame(width: 120)
                        }
                    }
                    .padding(10)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .kineticEntrance(i)
                }
            }
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
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .kineticEntrance(i)
                }
            }
            .padding(.horizontal, 14).padding(.top, 6)
            Spacer(minLength: 0)
        case .full:
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.white.opacity(0.05)).shimmer()
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
