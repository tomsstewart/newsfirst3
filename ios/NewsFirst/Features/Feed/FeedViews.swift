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
            CachedImage(url: url, topicFallback: article.topics.first ?? "news")
        } else {
            TopicPlaceholder(topic: article.topics.first ?? "news")
        }
    }
}


/// Briefing card: on Top Stories it's the personalized custom-topics-first digest; on
/// every other topic pane it's that topic's daily server overview (generated ONCE per
/// day for all users) + the pane's top headlines. Listen = on-device TTS. Zero
/// marginal AI cost per user, per session, per play.
struct BriefCard: View {
    let topic: String
    @Environment(FeedStore.self) private var store
    @State private var speech = Speech.shared
    @State private var expandedBrief = false

    private var isTop: Bool { topic == FeedStore.topStories }

    var body: some View {
        if store.showBriefings, store.browse == .topics, !store.dismissedBriefs.contains(topic) {
            let parts = store.topicBriefingParts(topic)
            let text = parts.joined(separator: " ")
            if !text.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.accent)
                        Text(isTop ? "DAILY BRIEFING" : "\(FeedStore.displayName(topic).uppercased()) · TODAY")
                            .font(Theme.Text.badge)
                            .foregroundStyle(.secondary)
                            .kerning(0.8)
                        Spacer()
                        Button {
                            speech.toggle(parts)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                                    .font(.caption2.bold())
                                Text(speech.isSpeaking ? "Stop" : "Listen")
                                    .font(Theme.Text.badge)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .glassChip(prominent: speech.isSpeaking)
                            .foregroundStyle(speech.isSpeaking ? .white : Theme.accent)
                        }
                        .buttonStyle(PressableStyle())
                        Button {
                            speech.stop()   // dismissing also stops playback
                            withAnimation(Theme.Motion.card) { store.dismissBrief(topic) }
                            Analytics.capture("briefing_dismiss", ["topic": topic])
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .padding(5)
                                .background(.primary.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                    // Collapsed, the card is EXACTLY one list-tile tall (118pt) — it's a
                    // peer of the tiles, not a billboard. Three script lines fit via the
                    // tighter header/padding. Tap to unfold the full script.
                    Text(text)
                        .font(Theme.Text.excerpt)
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(expandedBrief ? nil : 3)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Theme.Motion.expand) { expandedBrief.toggle() }
                        }
                    HStack(spacing: 4) {
                        Text(expandedBrief ? "Show less" : "Read it all")
                        Image(systemName: expandedBrief ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(Theme.Text.badge)
                    .foregroundStyle(Theme.accent.opacity(0.8))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.Motion.expand) { expandedBrief.toggle() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(height: expandedBrief ? nil : 110)
                .background(Theme.accent.opacity(0.10))
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
            }
        }
    }
}

// MARK: - LIST: priority bands + dense rows; tap = morph-expand in place, tap again = shrink back

struct ListFeedView: View {
    @Environment(FeedStore.self) private var store
    let topic: String
    let items: [Article]
    @State private var expandedID: UUID?
    @State private var lowHidden = false

    private var bands: [(tier: Article.Tier, items: [Article])] {
        let v = items
        return [Article.Tier.high, .medium, .low].compactMap { tier in
            let items = v.filter { $0.tier == tier }
            return items.isEmpty ? nil : (tier, items)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 13) {
                TopicHeaderRow(topic: topic).kineticEntrance(0)
                BriefCard(topic: topic).kineticEntrance(0)
                // Headers when tiers mix — EXCEPT custom topics, which always show their
                // band so the tier of your keyword's news is visible at a glance.
                let showHeaders = bands.count > 1 || store.customTopics.contains(topic)
                ForEach(Array(bands.enumerated()), id: \.element.tier) { bandIndex, band in
                    if showHeaders {
                        PriorityBand(tier: band.tier, trailing: band.tier == .low ? AnyView(hideButton) : nil)
                            .kineticEntrance(bandIndex * 3)
                    }
                    if !(band.tier == .low && lowHidden && showHeaders) {
                        ForEach(Array(band.items.enumerated()), id: \.element.id) { i, article in
                            articleCell(article)
                                .kineticEntrance(bandIndex * 3 + i + 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            LoadMoreButton()
            Spacer().frame(height: 24)
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
            withAnimation(Theme.Motion.expand) {
                expandedID = expandedID == article.id ? nil : article.id
            }
        }
    }
}


/// v2-style article card: full-bleed image with text overlaid on a bottom darkening fade.
struct OverlayCard: View {
    @Environment(FeedStore.self) private var store
    let article: Article
    var height: CGFloat = 540
    var showRead = true
    var showTier = true   // immersive bands already say the tier — no per-card tag there

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { g in
                ArticleImage(article: article, width: 800)
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)],
                           startPoint: .init(x: 0.5, y: 0.30), endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if showTier { TierBadge(tier: article.tier, loud: true) }
                    ScoreDebugBadge(article: article)
                }
                Text(article.title)
                    .font(Theme.Text.hero)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let excerpt = article.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.Text.excerpt)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                }
                HStack {
                    SourceLink(article: article).font(Theme.Text.meta)
                    Spacer()
                    Text(article.publishedAt, format: .relative(presentation: .named))
                        .font(Theme.Text.meta).foregroundStyle(.white.opacity(0.7))
                }
                if showRead {
                    CardActionRow(article: article)
                }
            }
            .padding(16)
            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.panelBorder, lineWidth: 1))
        .contentShape(Rectangle())
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
        // ZStack, not VStack: during the crossfade BOTH views exist; stacked they sum to
        // row+card height, so the cell overshot and snapped back on every expand/collapse.
        // Overlapped, the container animates cleanly between the two heights.
        ZStack(alignment: .top) {
            if expanded {
                // Immersive HERO footprint (480): the expanded article gets the flagship
                // treatment — 330 (secondary-card size) read too small, 560 dwarfed the feed.
                OverlayCard(article: article, height: 480, showTier: false)
                    .transition(.opacity)      // crossfade; the container's height change is the animation
            } else {
                ListRow(article: article)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.expand, value: expanded)
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
        // ZStack, not HStack: the text column defines the row height, and the image is
        // then PROPOSED exactly that height — deterministic full-bleed thumbnail
        // (HStack+fixedSize left the image at its own ideal, hence the dead space).
        // v2.5's tile model: FIXED row height, so every image is the identical
        // edge-to-edge portrait — text-driven heights made each thumbnail a different
        // rectangle. Text clamps guarantee fit (2-line title, 2-line excerpt, meta).
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 3) {
                Text(article.title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let excerpt = article.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 14))     // footnote +1 (Tom, two bumps)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)   // never fewer than 2 preview lines
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    CoverageChip(article: article, compact: true)
                    SourceLine(article: article)
                }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 10)
            .padding(.leading, 112)   // 100pt flush image + 12pt gutter
            .frame(maxWidth: .infinity, alignment: .leading)
            ArticleImage(article: article, width: 220)
                .frame(width: 100)
                .frame(maxHeight: .infinity)
                .clipped()   // aspect-fill must not spill over the text; corners come from the tile's own clip
                .overlay(alignment: .topLeading) { ScoreDebugBadge(article: article).padding(3) }
        }
        .frame(height: 110)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder, lineWidth: 1))
        .contentShape(Rectangle())
    }

}

// MARK: - IMMERSIVE: rich card feed (hero + cards with excerpts)

struct ImmersiveFeedView: View {
    @Environment(FeedStore.self) private var store
    let topic: String
    let items: [Article]
    @State private var lowHidden = false

    private var bands: [(tier: Article.Tier, items: [Article])] {
        [Article.Tier.high, .medium, .low].compactMap { tier in
            let tierItems = items.filter { $0.tier == tier }
            return tierItems.isEmpty ? nil : (tier, tierItems)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 13) {
                TopicHeaderRow(topic: topic).kineticEntrance(0)
                BriefCard(topic: topic).kineticEntrance(0)
                let showHeaders = bands.count > 1 || store.customTopics.contains(topic)
                ForEach(Array(bands.enumerated()), id: \.element.tier) { bandIndex, band in
                    if showHeaders {
                        PriorityBand(tier: band.tier)
                            .kineticEntrance(bandIndex * 3)
                    }
                    if !(band.tier == .low && lowHidden && showHeaders) {
                        ForEach(Array(band.items.enumerated()), id: \.element.id) { i, article in
                            // Card body is inert — only the explicit Read article button
                            // opens the reader (accidental scroll-taps were opening pages).
                            ImmersiveCard(article: article)
                                .kineticEntrance(bandIndex * 3 + i + 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            LoadMoreButton()
            Spacer().frame(height: 24)
        }
        .refreshable { await store.refresh() }
        .background(Theme.canvas)
    }
}

/// Every card gets the full hero treatment — mixed 480/330 sizing read as inconsistent,
/// and only the first card having a Read button made the rest feel inert.
struct ImmersiveCard: View {
    let article: Article
    var body: some View {
        OverlayCard(article: article, height: 480, showTier: false)
    }
}

// MARK: - FULL: full-bleed vertical pager (TikTok feel)

struct FullFeedView: View {
    @Environment(FeedStore.self) private var store
    let items: [Article]

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(items) { article in
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
            // Image is hard-bounded to the page: aspect-fill must never widen the stack
            // (that pushed the text block outside the clip — "text completely failing").
            GeometryReader { g in
                // 800 matches OverlayCard and the prefetcher — 900 meant Full mode never
                // hit the warmed cache and re-downloaded every image at a near-twin size.
                ArticleImage(article: article, width: 800)
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.45), .black.opacity(0.94)],
                           startPoint: .init(x: 0.5, y: 0.28), endPoint: .bottom)
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
                CardActionRow(article: article)
                    .padding(.top, 10)   // separated from the excerpt, sitting near the page's bottom edge
            }
            .padding(22)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
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

/// Pages the feed: raises the render cap and fetches deeper server pages as needed.
struct LoadMoreButton: View {
    @Environment(FeedStore.self) private var store
    @State private var loading = false
    var body: some View {
        if store.canLoadMore { button }
    }
    private var button: some View {
        Button {
            guard !loading else { return }
            loading = true
            Task { await store.loadMore(); loading = false }
        } label: {
            HStack(spacing: 7) {
                if loading { ProgressView().controlSize(.small) }
                Text(loading ? "Loading…" : "Load more")
                    .font(Theme.Text.rowTitle)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .glassChip()
        }
        .buttonStyle(PressableStyle())
        .padding(.top, 12)
    }
}

/// v2.5's topic header row: big title + per-topic subscribe bell + on-page custom
/// topic field. The bell state feeds topic_subscriptions once the alert matcher lands.
struct TopicHeaderRow: View {
    let topic: String
    @Environment(FeedStore.self) private var store
    @State private var draft = ""
    @State private var modeToast: String?
    @State private var toastGen = 0

    private func showToast(_ text: String) {
        withAnimation(Theme.Motion.snappy) { modeToast = text }
        toastGen += 1
        let gen = toastGen
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if gen == toastGen { withAnimation(Theme.Motion.card) { modeToast = nil } }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(FeedStore.displayName(topic))
                .font(.system(size: 28, weight: .heavy))
                .lineLimit(1)
            if store.browse == .topics, topic != FeedStore.topStories {
                if store.customTopics.contains(topic) {
                    // Custom topics: tri-state bell — all (blue, default) → high-only → off.
                    let level = store.customLevel(topic)
                    Button {
                        store.cycleCustomNotify(topic)
                        switch store.customLevel(topic) {
                        case .all: showToast("All notifications")
                        case .high: showToast("High priority only")
                        case .none: showToast("Notifications off")
                        }
                    } label: {
                        Image(systemName: level == .all ? "bell.badge.fill"
                                        : level == .high ? "bell.fill" : "bell.slash")
                            .font(.footnote)
                            // blue = all · white = high only · greyed = off
                            .foregroundStyle(level == .all ? AnyShapeStyle(Theme.accent)
                                           : level == .high ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .padding(8)
                            .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
                            .accessibilityLabel(level == .all ? "Alerts: every match"
                                              : level == .high ? "Alerts: breaking only" : "Alerts off")
                    }
                    .buttonStyle(PressableStyle())
                } else {
                    Button {
                        store.toggleNotify(topic)
                        showToast(store.notifyTopics.contains(topic) ? "High priority only" : "Notifications off")
                    } label: {
                        // Preset topics cap at high-only by design ("all" on Business = spam):
                        // white = high only · greyed = off.
                        Image(systemName: store.notifyTopics.contains(topic) ? "bell.fill" : "bell.slash")
                            .font(.footnote)
                            .foregroundStyle(store.notifyTopics.contains(topic) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .padding(8)
                            .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            Spacer(minLength: 8)
            if store.browse == .topics {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("Custom topic", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.Text.meta)
                        .onSubmit {
                            store.addCustomTopic(draft)
                            draft = ""
                        }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.primary.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.panelBorder, lineWidth: 1))
                .frame(width: 150)
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .bottomLeading) {
            if let modeToast {
                Text(modeToast)
                    .font(Theme.Text.badge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.95), in: Capsule())
                    .offset(y: 30)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(1)   // the toast floats over the briefing card below
    }
}

/// The card action row, verbatim spec: Full coverage (📰, left) · Read (📖, middle) ·
/// Listen (🔊, right). Shared by expanded list cards, Immersive cards, and Full pages.
struct CardActionRow: View {
    let article: Article
    @Environment(FeedStore.self) private var store

    var body: some View {
        HStack {
            Group {
                if let n = article.clusterSources, n >= 2 {
                    Button { store.story = article } label: {
                        pill("newspaper.fill", "Full coverage")
                    }
                    .buttonStyle(PressableStyle())
                } else {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { store.reading = article } label: {
                pill("book.fill", "Read")
            }
            .buttonStyle(PressableStyle())
            .frame(maxWidth: .infinity)
            CardListenButton(article: article)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func pill(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.bold())
            Text(label)
        }
        .font(Theme.Text.rowTitle)
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassChip()
    }
}

/// Compact listen-to-article for cards: same reader-engine extraction as the reader's
/// floating pill, sitting beside Read article.
struct CardListenButton: View {
    let article: Article
    @State private var speech = Speech.shared
    @State private var preparing = false

    var body: some View {
        Button {
            if speech.isSpeaking { speech.stop(); return }
            guard !preparing else { return }
            preparing = true
            Task {
                await Speech.shared.listenToArticle(article)
                preparing = false
            }
        } label: {
            HStack(spacing: 5) {
                if preparing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                        .font(.caption.bold())
                }
                Text(preparing ? "…" : (speech.isSpeaking ? "Stop" : "Listen"))
                    .font(Theme.Text.rowTitle)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassChip()
        }
        .buttonStyle(PressableStyle())
    }
}

/// Google News-style Full Coverage affordance: shows when a story is corroborated by
/// 2+ independent sources; taps into the cluster's dedicated story page.
struct CoverageChip: View {
    @Environment(FeedStore.self) private var store
    let article: Article
    var compact = false

    var body: some View {
        if let n = article.clusterSources, n >= 2 {
            Button {
                store.story = article
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 8, weight: .bold))
                    Text(compact ? "\(n) sources" : "Full coverage · \(n)")
                }
                .font(Theme.Text.badge)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(PressableStyle())
        }
    }
}

/// Developer overlay: raw priority score on every row/card (Settings → Developer).
struct ScoreDebugBadge: View {
    @Environment(FeedStore.self) private var store
    let article: Article
    var body: some View {
        if store.showPriorityDebug {
            Text("\(Int(article.score)) · \(article.tier.rawValue)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.tierColor(article.tier).opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
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
