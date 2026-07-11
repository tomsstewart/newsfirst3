import Foundation
import Observation
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case immersive = "Immersive"
    case full = "Full"
    var id: String { rawValue }
}

enum BrowseMode: String, CaseIterable {
    case topics = "Topics"
    case sources = "Sources"
}

enum Appearance: String, CaseIterable, Identifiable {
    case auto = "Auto", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self { case .auto: nil; case .light: .light; case .dark: .dark }
    }
}

/// Cache-first article store — the cold-start budget (<400ms to first feed frame) lives here.
/// One network fetch serves every preset topic (client-side filter), so topic switching is
/// instant; custom topics search server-side and cache per keyword.
/// Home-market bucket for locale weighting (auto-detected, overridable in Settings).
enum RegionBucket: String, CaseIterable, Identifiable {
    case auto = "Auto", us = "US", uk = "UK", anz = "Australasia"
    var id: String { rawValue }

    var countryCodes: Set<String> {
        switch self {
        case .us: ["US"]
        case .uk: ["GB", "IE"]
        case .anz: ["AU", "NZ"]
        case .auto: []
        }
    }
    static var detected: RegionBucket {
        switch Locale.current.region?.identifier {
        case "US", "CA": .us
        case "AU", "NZ": .anz
        default: .uk   // GB/IE and the sensible default for this app's audience
        }
    }
}

@Observable @MainActor
final class FeedStore {
    static let presetTopics = ["world", "business", "economics", "tech", "ai", "science", "sports", "crypto", "gaming", "entertainment", "space", "climate", "health", "travel"]

    /// The pinned first pane: the whole ranked feed, locale-weighted. Not a server
    /// topic — everything already ingested serves it.
    static let topStories = "top"

    private(set) var articles: [Article] = [] { didSet { rankedCache.removeAll() } }   // whole ranked feed
    private(set) var customResults: [String: [Article]] = [:] { didSet { rankedCache.removeAll() } }  // custom topic -> results
    private(set) var topicExtra: [String: [Article]] = [:] { didSet { rankedCache.removeAll() } }     // sparse preset topic -> targeted fetch
    private(set) var sourceResults: [String: [Article]] = [:] { didSet { rankedCache.removeAll() } }  // source name -> targeted fetch

    /// Rank/dedupe/diversify over 350 articles is too heavy to re-run per drag frame at
    /// 120Hz (3 panes × O(n²) work) — memoized until any underlying pool changes.
    @ObservationIgnored private var rankedCache: [String: [Article]] = [:]
    private(set) var briefs: [String: String] = [:]             // topic -> latest AI overview
    private(set) var loadingCustom: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var hasLoadedOnce = false
    private var retriedInitialLoad = false

    var selectedTopic: String = FeedStore.topStories   // first launch lands on Top Stories, never a single topic
    var swipeProgress: CGFloat = 0   // live drag: -1..1 toward prev/next bar item
    /// Visual bar selection during a swipe-commit settle: set the moment the commit
    /// animation starts (so the target chip's ✕ grows WITH the pane glide), cleared
    /// when the pane identity actually swaps at completion. Nil outside that window.
    var barSelection: String?
    var browse: BrowseMode = .topics
    var selectedSource: String = ""
    private(set) var sources: [FeedSource] = []
    var mode: ViewMode = .list
    var reading: Article? {
        didSet { if let a = reading { Analytics.capture("article_open", ["source": a.sourceName, "tier": a.tier.rawValue]) } }
    }

    // Persisted preferences (UserDefaults now; syncs to topic_subscriptions post-auth)
    var customTopics: [String] { didSet { defaults.set(customTopics, forKey: "customTopics"); syncOrder(); validateSelection() } }
    var enabledTopics: [String] { didSet { defaults.set(enabledTopics, forKey: "enabledTopics"); syncOrder(); validateSelection() } }
    /// One ordered bar for presets AND customs — drag-reorder is free-form across both.
    var topicOrder: [String] { didSet { defaults.set(topicOrder, forKey: "topicOrder") } }
    var showBriefings: Bool { didSet { defaults.set(showBriefings, forKey: "showBriefings"); Analytics.capture("settings_change", ["setting": "briefings", "value": showBriefings]) } }
    var disabledSources: Set<String> { didSet { defaults.set(Array(disabledSources), forKey: "disabledSources"); rankedCache.removeAll() } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); Analytics.capture("settings_change", ["setting": "appearance", "value": appearance.rawValue]) } }
    var regionPref: RegionBucket { didSet { defaults.set(regionPref.rawValue, forKey: "regionPref"); rankedCache.removeAll(); Analytics.capture("settings_change", ["setting": "region", "value": regionPref.rawValue]) } }
    var showPriorityDebug: Bool { didSet { defaults.set(showPriorityDebug, forKey: "priorityDebug") } }
    /// Custom-column engine. HYBRID is the default: our corpus's High-priority
    /// matches lead (the exact stories the push matcher alerts on), Google News
    /// breadth fills underneath. Long-term the lists merge for real — Google's
    /// sources become our sources — and this setting retires.
    enum CustomEngine: String, CaseIterable, Identifiable {
        case hybrid, corpus, google
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hybrid: "Hybrid"
            case .corpus: "NewsFirst only"
            case .google: "Google News only"
            }
        }
    }
    var customEngine: CustomEngine {
        didSet {
            defaults.set(customEngine.rawValue, forKey: "customEngine")
            Analytics.capture("settings_change", ["setting": "custom_engine", "value": customEngine.rawValue])
            customEpoch += 1            // orphan in-flight fetches from the other engine
            enrichQueued.removeAll()
            gnNoImage.removeAll()
            customFetchedAt.removeAll()
            loadingCustom.removeAll()   // …and unblock an immediate re-search
            customResults = [:]         // drop the other engine's results
            // Refresh EVERY custom column right away — waiting for a visit made the
            // toggle feel like it hadn't taken.
            for t in customTopics { Task { await loadCustom(t) } }
        }
    }
    /// True whenever google rows can be present (google or hybrid).
    var googleNewsCustoms: Bool { customEngine != .corpus }
    /// Bumped whenever the custom-search engine flips: stale fetches check it before
    /// writing, so a toggle mid-flight can't land the old engine's rows afterwards.
    @ObservationIgnored private var customEpoch = 0
    /// Rows already sent to (or through) enrichment this engine-epoch — one attempt each.
    @ObservationIgnored private var enrichQueued: Set<UUID> = []
    /// Census dedupe: topics whose google fetch was counted this session, and
    /// source names whose publisher domain was already reported.
    @ObservationIgnored private var gnCountedTopics: Set<String> = []
    @ObservationIgnored private var gnDomainLogged: Set<String> = []
    @ObservationIgnored private var customFetchedAt: [String: Date] = [:]
    /// Ids whose enrichment finished WITHOUT an image (og missing/unreachable) —
    /// observable, so shimmering rows settle into the branded placeholder.
    private(set) var gnNoImage: Set<UUID> = []

    /// True while a google row's picture may still arrive — rows shimmer instead of
    /// flashing placeholder → photo.
    func awaitingImage(_ a: Article) -> Bool {
        a.isExternal && a.imageURL == nil && googleNewsCustoms && !gnNoImage.contains(a.id)
    }
    var readerMode: Bool { didSet { defaults.set(readerMode, forKey: "readerMode"); Analytics.capture("settings_change", ["setting": "reader_mode", "value": readerMode]) } }
    var defaultMode: ViewMode { didSet { defaults.set(defaultMode.rawValue, forKey: "defaultMode"); Analytics.capture("settings_change", ["setting": "default_view", "value": defaultMode.rawValue]) } }

    private let api = SupabaseAPI()
    private let defaults = UserDefaults.standard
    private let cacheURL = URL.cachesDirectory.appending(path: "feed-cache.json")

    init() {
        customTopics = defaults.stringArray(forKey: "customTopics") ?? []
        enabledTopics = defaults.stringArray(forKey: "enabledTopics") ?? Array(Self.presetTopics.dropFirst().prefix(7))
        disabledSources = Set(defaults.stringArray(forKey: "disabledSources") ?? [])
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .auto
        regionPref = RegionBucket(rawValue: defaults.string(forKey: "regionPref") ?? "") ?? .auto
        showPriorityDebug = defaults.bool(forKey: "priorityDebug")
        // Hybrid is the default for everyone — including migrations from the old
        // Bool toggle (hybrid supersedes what that toggle was reaching for).
        customEngine = defaults.string(forKey: "customEngine").flatMap(CustomEngine.init) ?? .hybrid
        readerMode = defaults.object(forKey: "readerMode") as? Bool ?? false   // opt-in: reader swallowed consent screens
        defaultMode = ViewMode(rawValue: defaults.string(forKey: "defaultMode") ?? "") ?? .list
        // Unified per-topic notify level (presets, customs, and Top Stories alike).
        // Migrate the old split model: notifyTopics Set (preset='high') + customNotifyLevels.
        if let saved = defaults.dictionary(forKey: "notifyLevels") as? [String: String] {
            notifyLevels = saved
        } else {
            var m = defaults.dictionary(forKey: "customNotifyLevels") as? [String: String] ?? [:]
            for t in defaults.stringArray(forKey: "notifyTopics") ?? [] where m[t] == nil { m[t] = "high" }
            notifyLevels = m
            defaults.set(m, forKey: "notifyLevels")
        }
        showBriefings = defaults.object(forKey: "showBriefings") as? Bool ?? true
        topicOrder = defaults.stringArray(forKey: "topicOrder") ?? []
        mode = defaultMode
        syncOrder()
        // One-time: Top Stories supersedes World as the home pane (world stays available
        // in Settings for anyone who re-adds it).
        if !defaults.bool(forKey: "migratedTopStories") {
            enabledTopics.removeAll { $0 == "world" }
            defaults.set(true, forKey: "migratedTopStories")
            selectedTopic = Self.topStories
        }
        validateSelection()
    }

    /// User's home-market country codes (auto = locale-detected).
    var homeCodes: Set<String> {
        (regionPref == .auto ? RegionBucket.detected : regionPref).countryCodes
    }

    /// Countries that clearly belong to SOME home market — stories exclusively about a
    /// different one get demoted (Brisbane bail laws matter less in Birmingham).
    private static let marketCodes: Set<String> = ["US", "CA", "GB", "IE", "AU", "NZ"]

    /// Hard-news categories that deserve the front page vs. soft ones that own their
    /// topic pages but shouldn't flood Top Stories (retiring the keyword boosts removed
    /// the old importance signal — this reinstates it in a principled form).
    private static let hardTopics: Set<String> = ["world", "business", "economics", "climate", "health", "science"]
    private static let softTopics: Set<String> = ["sports", "entertainment", "gaming", "travel"]

    private func rankAdjust(_ a: Article, home: Set<String>, frontPage: Bool) -> Double {
        // Imageless tellings rank slightly down — the region boost was surfacing
        // picture-free live blogs into an image-starved first page.
        var adj: Double = a.imageURL == nil ? -4 : 0
        if let regions = a.regions, !regions.isEmpty {
            let r = Set(regions)
            if !r.isDisjoint(with: home) {
                // Tom: region must be PRONOUNCED — +12 was imperceptible. Home-market
                // stories (now including the local papers, whose rows carry their
                // country from ingest) jump roughly a tier.
                adj += 26
            } else if r.isSubset(of: Self.marketCodes), a.tier != .high {
                // Foreign-market domestic news (mostly politics) barely travels…
                // with two exceptions: US stories interest everyone somewhat (-8,
                // not -18), and BREAKING transcends borders entirely (no demotion).
                adj -= r.isSubset(of: ["US", "CA"]) ? 8 : 18
            }
        }
        // Corroboration: a story multiple independent outlets chose to cover matters
        // more than a single-source feature, even below the breaking threshold.
        if let n = a.clusterSources, n > 1 { adj += Double(min(n - 1, 4)) * 3 }
        if frontPage {
            // Front page leans hard news; sports/entertainment keep their own panes.
            if !Set(a.topics).isDisjoint(with: Self.hardTopics) { adj += 6 }
            else if Set(a.topics).isSubset(of: Self.softTopics) { adj -= 6 }
        }
        return adj
    }

    /// The selected topic must always exist in the bar — otherwise no chip highlights,
    /// the pill vanishes and swipes dead-end (e.g. after disabling the selected topic).
    private func validateSelection() {
        if browse == .topics, !topicBar.contains(selectedTopic) {
            selectedTopic = topicBar.first ?? Self.topStories
        }
    }

    var topicBar: [String] {
        [Self.topStories] + topicOrder.filter { enabledTopics.contains($0) || customTopics.contains($0) }
    }
    var sourceBar: [String] { sources.map(\.name) }

    /// topicOrder tracks membership changes: new topics append, gone ones prune.
    private func syncOrder() {
        let live = enabledTopics + customTopics
        var order = topicOrder.filter { live.contains($0) }
        for t in live where !order.contains(t) { order.append(t) }
        if order != topicOrder { topicOrder = order }
    }

    /// Chip / card display name.
    static func displayName(_ topic: String) -> String {
        topic == topStories ? "Top Stories" : topic.capitalized
    }

    /// Called when a preset topic or source shows empty — targeted server fetch fills it.
    func backfillIfSparse() async {
        // Failures/cancellations must stay nil: caching `[]` here made one flaky request
        // (or a fast swipe-past, which cancels the .task) an empty topic for the session.
        if browse == .sources {
            let s = selectedSource
            guard !s.isEmpty, articles.filter({ $0.sourceName == s }).isEmpty, sourceResults[s] == nil else { return }
            if let fetched = try? await api.fetchSource(s) {
                withAnimation(Theme.Motion.feed) { sourceResults[s] = fetched }
                serverOffsets["s:\(s)"] = fetched.count   // Load More pages from here, not row 0
                if fetched.count < 60 { exhaustedKeys.insert("s:\(s)") }
            }
        } else if !isCustomSelected {
            let t = selectedTopic
            guard t != Self.topStories else { return }   // the whole feed can't be sparse
            // Backfill thin topics too, not just empty ones — every section deserves a full page.
            guard articles.filter({ $0.topics.contains(t) }).count < 8, topicExtra[t] == nil else { return }
            if let fetched = try? await api.fetchTopic(t) {
                withAnimation(Theme.Motion.feed) { topicExtra[t] = fetched }
                serverOffsets["t:\(t)"] = fetched.count   // Load More pages from here, not row 0
                if fetched.count < 60 { exhaustedKeys.insert("t:\(t)") }
            }
        }
    }

    /// Warm the image cache for the current and neighbouring columns so entrances
    /// and swipes render complete panes — pictures move with the pane, never pop in after.
    func prefetchImages() {
        let targets = [visibleAt(offset: 0).prefix(10), visibleAt(offset: 1).prefix(8), visibleAt(offset: -1).prefix(8)]
            .flatMap { $0 }
        Task.detached(priority: .utility) {
            for a in targets {
                for w in [220, 800] {
                    if let u = ImageProxy.url(a.imageURL, width: w) { _ = await ImagePipeline.load(u) }
                }
            }
        }
    }

    func loadSources() async {
        guard sources.isEmpty else { return }
        sources = (try? await api.fetchSources()) ?? []
        if selectedSource.isEmpty { selectedSource = sources.first?.name ?? "" }
    }

    var isCustomSelected: Bool { customTopics.contains(selectedTopic) }

    /// True while a custom topic has no results YET (unloaded or in flight) — panes show
    /// a skeleton then, and the empty state only after a search truly returned nothing.
    func isCustomPending(_ topic: String) -> Bool {
        customTopics.contains(topic) && (customResults[topic] == nil || loadingCustom.contains(topic))
    }

    /// Sensible initial page; "Load more" raises the cap and pulls further pages server-side.
    static let pageSize = 30
    private(set) var renderCaps: [String: Int] = [:]

    private var capKey: String { browse == .topics ? "t:\(selectedTopic)" : "s:\(selectedSource)" }
    var renderCap: Int { renderCaps[capKey] ?? Self.pageSize }

    /// Raw rows already pulled from the server per key — client-side dedupe/diversity
    /// counts don't correspond to server offsets, so page from this instead.
    @ObservationIgnored private var serverOffsets: [String: Int] = [:]
    private(set) var exhaustedKeys: Set<String> = []

    /// Hide "Load more" once the pool is on screen and the server has nothing further —
    /// otherwise every tap is a Supabase query that returns only discards.
    var canLoadMore: Bool {
        visibleUncapped.count > renderCap || !exhaustedKeys.contains(capKey)
    }

    func loadMore() async {
        let key = capKey
        let newCap = (renderCaps[key] ?? Self.pageSize) + Self.pageSize
        // Animated: new rows must arrive, not pop — every mutation below is a transaction.
        withAnimation(Theme.Motion.feed) { renderCaps[key] = newCap }
        // If the local pool can't fill the new cap, page more from the server.
        guard visibleUncapped.count < newCap, !exhaustedKeys.contains(key) else { return }
        let offset = serverOffsets[key] ?? 0
        if browse == .sources {
            guard let extra = try? await api.fetchSource(selectedSource, limit: Self.pageSize, offset: offset) else { return }
            serverOffsets[key] = offset + extra.count
            if extra.count < Self.pageSize { exhaustedKeys.insert(key) }
            withAnimation(Theme.Motion.feed) {
                sourceResults[selectedSource, default: []].append(contentsOf: extra.filter { a in !visibleUncapped.contains(where: { $0.id == a.id }) })
            }
        } else if selectedTopic == Self.topStories {
            // Top Stories pages the whole feed; refresh() already pulled the first 350.
            let effectiveOffset = max(offset, articles.count)
            guard let extra = try? await api.fetchFeed(limit: Self.pageSize, offset: effectiveOffset) else { return }
            serverOffsets[key] = effectiveOffset + extra.count
            if extra.count < Self.pageSize { exhaustedKeys.insert(key) }
            withAnimation(Theme.Motion.feed) {
                topicExtra[Self.topStories, default: []].append(contentsOf: extra.filter { a in !visibleUncapped.contains(where: { $0.id == a.id }) })
            }
        } else if !isCustomSelected {
            guard let extra = try? await api.fetchTopic(selectedTopic, limit: Self.pageSize, offset: offset) else { return }
            serverOffsets[key] = offset + extra.count
            if extra.count < Self.pageSize { exhaustedKeys.insert(key) }
            withAnimation(Theme.Motion.feed) {
                topicExtra[selectedTopic, default: []].append(contentsOf: extra.filter { a in !visibleUncapped.contains(where: { $0.id == a.id }) })
            }
        } else {
            exhaustedKeys.insert(key)   // custom topics load in one 80-row search; no server paging yet
        }
    }

    /// Articles for the selected topic/source, source-diversity capped.
    var visibleUncapped: [Article] { visibleItems(topic: selectedTopic, source: selectedSource) }
    var visible: [Article] { Array(visibleUncapped.prefix(renderCap)) }

    /// Bar-relative lookup (wraps) so neighbouring columns can render during a swipe.
    func visibleAt(offset: Int) -> [Article] {
        let bar = browse == .topics ? topicBar : sourceBar
        guard !bar.isEmpty else { return [] }
        let current = browse == .topics ? selectedTopic : selectedSource
        guard let idx = bar.firstIndex(of: current) else { return visible }
        let item = bar[(idx + offset + bar.count) % bar.count]
        let key = browse == .topics ? "t:\(item)" : "s:\(item)"
        let cap = renderCaps[key] ?? Self.pageSize
        let items = browse == .topics ? visibleItems(topic: item, source: "") : visibleItems(topic: "", source: item)
        return Array(items.prefix(cap))   // page cap applies to EVERY render path, not just `visible`
    }

    func barItem(offset: Int) -> String {
        let bar = browse == .topics ? topicBar : sourceBar
        let current = browse == .topics ? selectedTopic : selectedSource
        guard !bar.isEmpty, let idx = bar.firstIndex(of: current) else { return current }
        return bar[(idx + offset + bar.count) % bar.count]
    }

    /// Front page only: cap purely-soft-topic breaking at Medium (display tier).
    private func frontPageSoftCap(_ a: Article) -> Article {
        guard a.tier == .high, !a.topics.isEmpty,
              Set(a.topics).isSubset(of: Self.softTopics) else { return a }
        return Article(id: a.id, url: a.url, title: a.title, excerpt: a.excerpt,
                       imageURL: a.imageURL, publishedAt: a.publishedAt, topics: a.topics,
                       regions: a.regions, sourceName: a.sourceName, score: a.score,
                       tier: .medium, clusterID: a.clusterID, clusterSources: a.clusterSources,
                       clusterLabel: a.clusterLabel, isExternal: a.isExternal)
    }

    /// The one preset pane an article belongs to: its first ENABLED topic tag
    /// (ingest orders tags source-category first, so this is the article's home desk).
    /// Falls back to the first tag so a story never vanishes when its home is disabled.
    private func primaryTopic(of a: Article) -> String {
        a.topics.first(where: { enabledTopics.contains($0) }) ?? a.topics.first ?? ""
    }

    private func visibleItems(topic: String, source: String) -> [Article] {
        let cacheKey = browse == .sources ? "s:\(source)" : "t:\(topic)"
        if let hit = rankedCache[cacheKey] { return hit }
        let result = rankItems(topic: topic, source: source)
        rankedCache[cacheKey] = result
        return result
    }

    private func rankItems(topic: String, source: String) -> [Article] {
        if browse == .sources {
            let local = articles.filter { $0.sourceName == source }
            let base = (sourceResults[source] ?? []).isEmpty ? local : sourceResults[source]!
            return base.sorted { ($0.score, $0.publishedAt) > ($1.score, $1.publishedAt) }
        }
        let base: [Article]
        if customTopics.contains(topic) {
            base = customResults[topic] ?? []
        } else if topic == Self.topStories {
            // Everything, locale-weighted — the whole ranked feed IS the home pane.
            // Soft-topic "breaking" (a 15-source celebrity wedding is real corroboration
            // but not front-page High — Tom's call) displays as Medium HERE ONLY; the
            // sports/entertainment panes keep the honest tier.
            let extra = (topicExtra[topic] ?? []).filter { e in !articles.contains(where: { $0.id == e.id }) }
            base = (articles + extra).map(frontPageSoftCap)
        } else {
            // Cross-pane dedup (presets only; customs keep every match): an article
            // tagged [tech, ai] shows ONLY in its primary enabled topic, so adjacent
            // panes stop repeating each other.
            let local = articles.filter { primaryTopic(of: $0) == topic }
            base = local.isEmpty ? (topicExtra[topic] ?? []).filter { primaryTopic(of: $0) == topic }
                 : local + (topicExtra[topic] ?? []).filter { e in primaryTopic(of: e) == topic && !local.contains(where: { $0.id == e.id }) }
        }
        // Cross-surface dedup (Tom, 2026-07-10): the big breaking (High) stories are the
        // FRONT PAGE — they live on Top Stories. A preset topic column shows that topic's
        // ongoing feed WITHOUT repeating the front-page High items, so the same story
        // never appears in both Top Stories and its column. (Customs keep every match.)
        let isPresetPane = topic != Self.topStories && !customTopics.contains(topic)
        let filtered = base.filter {
            !disabledSources.contains($0.sourceName) && !(isPresetPane && $0.tier == .high)
        }
        let home = homeCodes
        let frontPage = topic == Self.topStories
        let ranked = filtered.sorted {
            // locale/corroboration/hardness-adjusted score first; among peers prefer
            // image-bearing, then freshness
            let l = $0.score + rankAdjust($0, home: home, frontPage: frontPage)
            let r = $1.score + rankAdjust($1, home: home, frontPage: frontPage)
            if l != r { return l > r }
            if ($0.imageURL != nil) != ($1.imageURL != nil) { return $0.imageURL != nil }
            return $0.publishedAt > $1.publishedAt
        }
        return diversify(collapseDuplicates(ranked))
    }

    /// Same story from many feeds: keep ONE telling per cluster (title-prefix fallback),
    /// preferring a telling WITH a picture — live blogs often rank highest but ship
    /// imageless, which starved the page of photography.
    private func collapseDuplicates(_ input: [Article]) -> [Article] {
        var out: [Article] = []
        var clusterPos: [UUID: Int] = [:]
        var titlePos: [String: Int] = [:]
        for a in input {
            if let c = a.clusterID {
                if let pos = clusterPos[c] {
                    if out[pos].imageURL == nil, a.imageURL != nil { out[pos] = a }
                    continue
                }
                clusterPos[c] = out.count
            }
            let key = String(a.title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(56))
            if !key.isEmpty {
                if let pos = titlePos[key] {
                    if out[pos].imageURL == nil, a.imageURL != nil { out[pos] = a }
                    continue
                }
                titlePos[key] = out.count
            }
            out.append(a)
        }
        return out
    }

    var isLoadingSelected: Bool {
        if isCustomSelected { return loadingCustom.contains(selectedTopic) && (customResults[selectedTopic] ?? []).isEmpty }
        return !hasLoadedOnce && articles.isEmpty
    }

    // (Tier selectivity now lives server-side in article_tier — importance-driven High/
    // Medium — so the old client-side High-band cap was removed. Criteria, not a cap.)

    /// Full Coverage sheet: the seed article whose story cluster is open.
    var story: Article? {
        didSet { if story != nil { Analytics.capture("full_coverage_open") } }
    }

    /// Briefing cards dismissed this session (per topic; fresh launch restores them).
    private(set) var dismissedBriefs: Set<String> = []
    func dismissBrief(_ topic: String) { dismissedBriefs.insert(topic) }

    /// Unified per-topic notify level for presets, custom topics AND Top Stories
    /// ("top"). Maps to server `topic_subscriptions.notify_level`. The bell cycles
    /// off → high-only → all → off. Custom topics default to 'all' (radar semantics —
    /// they start loud); presets and Top Stories default to off.
    var notifyLevels: [String: String] {
        didSet { defaults.set(notifyLevels, forKey: "notifyLevels") }
    }
    /// Topics with any alerting on — used for the Settings summary count.
    var notifyTopics: Set<String> { Set(notifyLevels.filter { $0.value != "none" }.keys) }

    func notifyLevel(_ topic: String) -> NotifyLevel {
        if let raw = notifyLevels[topic], let lvl = NotifyLevel(rawValue: raw) { return lvl }
        return customTopics.contains(topic) ? .all : .none
    }
    /// Back-compat alias (chip rendering calls this).
    func customLevel(_ topic: String) -> NotifyLevel { notifyLevel(topic) }

    func cycleNotify(_ topic: String) {
        // Top Stories maps server-side to breaking-only, so it's a plain off↔on toggle
        // (no separate 'all' state). Everything else cycles off → high → all → off.
        let isTop = topic == Self.topStories
        let next: NotifyLevel = switch notifyLevel(topic) {
        case .none: .high
        case .high: isTop ? .none : .all
        case .all:  .none
        }
        notifyLevels[topic] = next.rawValue
        Analytics.capture("topic_notify_toggle", ["topic": topic, "level": next.rawValue])
        // The bell IS the moment of intent: ask for permission here, never at launch.
        if next != .none { PushManager.shared.enablePush() }
        Task { await AuthClient.shared.syncTopics(preset: enabledTopics, custom: customTopics) }
    }
    /// Back-compat alias.
    func cycleCustomNotify(_ topic: String) { cycleNotify(topic) }

    /// Daily-brief notification tap: wait for the feed (briefing is composed from it),
    /// then speak. Audio session is .playback — keeps reading when the app backgrounds.
    func playDailyBrief() {
        Task {
            for _ in 0..<40 where !hasLoadedOnce {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Speech.shared.isSpeaking else { return }
            Speech.shared.toggle(personalBriefingParts)
            Analytics.capture("brief_autoplay")
        }
    }

    /// Notification tap → the alert landing card (hear it / read it), never straight
    /// into the web reader. Pools first (instant), server fallback for an article
    /// that scrolled out of the cached window.
    var alertLanding: Article?
    func openArticle(id: String) async {
        let target = id.lowercased()
        let pools = articles + topicExtra.values.flatMap { $0 } + sourceResults.values.flatMap { $0 }
        if let hit = pools.first(where: { $0.id.uuidString.lowercased() == target }) {
            alertLanding = hit
            return
        }
        if let fetched = try? await api.fetchArticle(id: target) { alertLanding = fetched }
    }

    /// The bell inbox: current breaking stories (high tier = notification-grade), one per
    /// cluster. Used by the spoken briefing; the on-screen drawer uses `inbox` below.
    var breakingStories: [Article] {
        collapseDuplicates(articles.filter { $0.tier == .high }
            .sorted { $0.publishedAt > $1.publishedAt })
    }

    /// Notification drawer: ONLY articles that actually pushed to this user (their alert
    /// history), fetched from `alert_inbox`. "Clear all" hides everything sent so far via
    /// a local watermark — the alert rows stay server-side (they power the open funnel).
    private(set) var inboxItems: [InboxItem] = []
    var inboxClearedAt: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "inboxClearedAt")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "inboxClearedAt") }
    }
    /// Visible drawer contents (everything notified since the last "Clear all").
    var inbox: [InboxItem] { inboxItems.filter { $0.sentAt > inboxClearedAt } }
    var unreadInboxCount: Int { inbox.count }

    func loadInbox() async {
        guard let token = await AuthClient.shared.validToken() else { inboxItems = []; return }
        if let items = try? await api.fetchAlertInbox(token: token) { inboxItems = items }
    }
    func clearInbox() {
        withAnimation(Theme.Motion.card) { inboxClearedAt = .now }
    }

    /// Remove a topic from the bar via the chip's ✕ (preset = disable, custom = delete).
    func removeFromBar(_ topic: String) {
        guard topic != Self.topStories else { return }
        withAnimation(Theme.Motion.snappy) {
            if customTopics.contains(topic) {
                removeCustomTopic(topic)
            } else {
                enabledTopics.removeAll { $0 == topic }
            }
        }
    }

    /// Chip drag-reorder over ONE unified order — customs and presets mix freely;
    /// Top Stories is pinned.
    func moveChip(_ dragged: String, before item: String) {
        guard dragged != Self.topStories, item != Self.topStories, dragged != item,
              let from = topicOrder.firstIndex(of: dragged),
              let to = topicOrder.firstIndex(of: item) else { return }
        withAnimation(Theme.Motion.snappy) {
            topicOrder.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func start() async {
        loadCache()          // synchronous-fast: feed on screen before any network
        Task { await loadInbox() }   // populate the notification-drawer badge
        await refresh()
    }

    /// Top Stories briefing in the assistant "tell me the news" register: greeting, the
    /// user's CUSTOM topics with real depth (two stories each, summary sentence on the
    /// lead), then attributed top stories from their chosen topics. Spoken in full;
    /// the card truncates visually.
    var personalBriefing: String { personalBriefingParts.joined(separator: " ") }

    /// Per-topic listen: the server's daily AI overview for the topic (generated ONCE
    /// per day for all users — zero marginal model cost) + that pane's top headlines.
    func topicBriefingParts(_ topic: String) -> [String] {
        if topic == Self.topStories { return personalBriefingParts }
        var parts: [String] = []
        if let brief = briefs[topic] { parts.append(brief) }
        let top = visibleItems(topic: topic, source: "").prefix(3)
        let intros = ["From", "Next, from", "Finally, from"]
        for (i, a) in top.enumerated() {
            var line = "\(intros[min(i, intros.count - 1)]) \(a.sourceName): \(Self.sentence(a.title))"
            if i == 0, let s = Self.firstSentence(a.excerpt) { line += " \(s)" }
            parts.append(line)
        }
        guard !parts.isEmpty else { return [] }
        // A natural lead-in, not the bare topic name — "Bitcoin. Bitcoin ETFs log…"
        // stuttered whenever the first headline opened with the topic word.
        return ["Here's the latest on \(Self.displayName(topic))."] + parts
    }

    func topicBriefing(_ topic: String) -> String { topicBriefingParts(topic).joined(separator: " ") }

    /// Segments, not one blob: the speech engine gives each story its own utterance
    /// with a newsreader beat between them — same text, dramatically better delivery.
    var personalBriefingParts: [String] {
        var parts: [String] = []
        let hour = Calendar.current.component(.hour, from: .now)
        let greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"

        // Order of the briefing: breaking first (if anything is live), then YOUR
        // topics, then the rest of the front page. Every story change is flagged
        // verbally ("Next…", "In other news…") so transitions never blur in the ear.
        var mentionedIDs: Set<UUID> = []
        var mentionedClusters: Set<UUID> = []
        let breaking = Array(breakingStories.prefix(2))
        if !breaking.isEmpty {
            parts.append("Breaking news.")
            for (i, a) in breaking.enumerated() {
                var line = "From \(a.sourceName): \(Self.sentence(a.title))"
                if i == 0, let s = Self.firstSentence(a.excerpt) { line += " \(s)" }
                parts.append(line)
                mentionedIDs.insert(a.id)
                if let c = a.clusterID { mentionedClusters.insert(c) }
            }
        }

        var customParts: [String] = []
        var customIndex = 0
        for t in customTopics.prefix(3) {
            let items = customResults[t] ?? []
            guard let lead = items.first else { continue }
            let intro = customIndex == 0 ? "On \(t.capitalized)" : "Next, on \(t.capitalized)"
            var line = "\(intro) — from \(lead.sourceName): \(Self.sentence(lead.title))"
            if let s = Self.firstSentence(lead.excerpt) { line += " \(s)" }
            customParts.append(line)
            if let second = items.dropFirst().first(where: { $0.sourceName != lead.sourceName || $0.title != lead.title }) {
                customParts.append("Also on \(t.capitalized): \(Self.sentence(second.title))")
            }
            customIndex += 1
        }
        if !customParts.isEmpty {
            parts.append("Your topics.")
            parts.append(contentsOf: customParts)
        }

        // Then the rest of the front page (skipping anything already covered above).
        let top = visibleItems(topic: Self.topStories, source: "")
            .filter { a in !mentionedIDs.contains(a.id) && (a.clusterID.map { !mentionedClusters.contains($0) } ?? true) }
            .prefix(3)
        if !top.isEmpty {
            parts.append("Top stories.")
            let intros = ["From", "Next, from", "Finally, from"]
            for (i, a) in top.enumerated() {
                var line = "\(intros[min(i, intros.count - 1)]) \(a.sourceName): \(Self.sentence(a.title))"
                if i < 2, let s = Self.firstSentence(a.excerpt) { line += " \(s)" }
                parts.append(line)
            }
        }

        // Thin day and no customs: any server topic overview still beats silence.
        if parts.isEmpty, let brief = briefs.values.first {
            parts.append(brief)
        }
        guard !parts.isEmpty else { return [] }
        return ["\(greeting)."] + parts
    }

    private static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?") ? t : t + "."
    }

    /// First sentence of an excerpt, cleaned for speech — skips fragments and runaways.
    private static func firstSentence(_ excerpt: String?) -> String? {
        guard let e = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else { return nil }
        let first = e.components(separatedBy: ". ").first ?? e
        guard first.count >= 30 else { return nil }
        return sentence(String(first.prefix(180)))
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await api.fetchFeed(limit: 350)
            withAnimation(Theme.Motion.feed) { articles = fresh; hasLoadedOnce = true }
            saveCache(fresh)
            prefetchImages()
            // Custom topics re-search on EVERY refresh (not just first load): the daily
            // briefing leads with them, so stale custom results made pull-to-refresh
            // look like it ignored the briefing.
            for t in customTopics {
                Task { await loadCustom(t, force: true) }
            }
            dismissedBriefs.removeAll()   // a manual refresh brings dismissed briefings back
            if let fetched = try? await api.fetchBriefs() {
                // Animated: the brief card lands above an on-screen feed — a hard
                // insert shoved every row down in a single frame.
                withAnimation(Theme.Motion.feed) { briefs = fetched }
            }
        } catch {
            // Have cached articles → keep them on screen (offline-friendly). No cache yet
            // (a common cold start from a notification tap that beats the network) → don't
            // strand the user on a blank Top Stories: stay in the loading state and retry
            // once before falling back to the empty-state message.
            if !articles.isEmpty || retriedInitialLoad {
                hasLoadedOnce = true
            } else {
                retriedInitialLoad = true
                Task { try? await Task.sleep(for: .seconds(2)); await refresh() }
            }
        }
    }

    // MARK: - Custom topics

    /// Presented when the free custom-topic ceiling is hit (RootView owns the sheet).
    var paywall = false

    func addCustomTopic(_ raw: String) {
        let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !topic.isEmpty, !customTopics.contains(topic), !Self.presetTopics.contains(topic) else { return }
        // THE monetisation gate: 3 keywords free, unlimited on Premium. Existing
        // topics are never taken away — the ceiling only stops new additions.
        guard customTopics.count < Entitlements.freeCustomTopics || Entitlements.shared.isPremium else {
            if defaults.bool(forKey: "hasOnboarded") {   // mid-onboarding: cap silently, pitch later
                paywall = true
                Analytics.capture("paywall_shown", ["trigger": "custom_topic_limit"])
            }
            return
        }
        withAnimation(Theme.Motion.snappy) {
            customTopics.append(topic)
            selectedTopic = topic
        }
        Analytics.capture("custom_topic_add", ["topic": topic])
        Task { await loadCustom(topic) }
    }

    func removeCustomTopic(_ topic: String) {
        withAnimation(Theme.Motion.snappy) {
            customTopics.removeAll { $0 == topic }
            customResults[topic] = nil
            notifyLevels[topic] = nil
            if selectedTopic == topic { selectedTopic = enabledTopics.first ?? "world" }
        }
    }

    func loadCustom(_ topic: String, force: Bool = false) async {
        if force {
            // Refresh re-search: skip when one is in flight or the results are fresh.
            // Launch fired refresh() and the first visit's loadCustom simultaneously —
            // the slower fetch visibly overwrote the faster one seconds later.
            guard !loadingCustom.contains(topic),
                  Date.now.timeIntervalSince(customFetchedAt[topic] ?? .distantPast) > 60 else { return }
        } else {
            guard customResults[topic] == nil, !loadingCustom.contains(topic) else { return }
        }
        let epoch = customEpoch
        loadingCustom.insert(topic)
        defer { loadingCustom.remove(topic) }
        // On failure leave nil (retry on next selection) — caching `[]` bricked the
        // topic for the whole session, on the product's flagship feature.
        guard let results = await searchCustom(topic), epoch == customEpoch else { return }
        customFetchedAt[topic] = .now
        let existing = customResults[topic] ?? []
        if !existing.isEmpty {
            // Refresh over a rendered pane: identical content must not rewrite (the
            // "articles load then get replaced" flash), and an updated list slides in
            // WITHOUT animation — identity-stable rows stay put, only newcomers appear.
            guard Set(results.map(\.id)) != Set(existing.map(\.id)) else { return }
            customResults[topic] = results
        } else {
            withAnimation(Theme.Motion.feed) { customResults[topic] = results }
        }
        if googleNewsCustoms { enrichGoogle(topic, epoch: epoch) }
    }

    /// Engine-aware custom search: our FTS index, or Google News RSS while the
    /// experiment toggle is on. Google rows carry content-derived ids, so a re-search
    /// keeps already-enriched rows (publisher URL + image) for stories still present
    /// instead of regressing them to imageless.
    private func searchCustom(_ topic: String) async -> [Article]? {
        switch customEngine {
        case .corpus:
            return try? await api.searchArticles(matching: topic)
        case .google:
            guard let fresh = try? await GoogleNewsRSS.fetch(topic: topic) else { return nil }
            logGNCensus(fresh, topic: topic)
            return keepEnriched(fresh, topic: topic)
        case .hybrid:
            // Our High-priority matches lead (they're what the push matcher alerts
            // on, so the column's top == the notifications), Google fills beneath.
            async let oursReq = api.searchArticles(matching: topic)
            async let googleReq = GoogleNewsRSS.fetch(topic: topic)
            let ours = ((try? await oursReq) ?? []).filter { $0.tier == .high }
            let googleFresh = (try? await googleReq) ?? []
            logGNCensus(googleFresh, topic: topic)
            let google = keepEnriched(googleFresh, topic: topic)
            guard !(ours.isEmpty && google.isEmpty) else { return nil }
            var seen = Set(ours.map { Self.titleKey($0.title) })
            return ours + google.filter { seen.insert(Self.titleKey($0.title)).inserted }
        }
    }

    /// Stable content-derived google ids mean a re-search can keep already-enriched
    /// rows (publisher URL + image) instead of regressing them to imageless.
    private func keepEnriched(_ fresh: [Article], topic: String) -> [Article] {
        let old = Dictionary((customResults[topic] ?? []).map { ($0.id, $0) },
                             uniquingKeysWith: { a, _ in a })
        return fresh.map { new in old[new.id].flatMap { $0.imageURL != nil ? $0 : nil } ?? new }
    }

    /// The experiment's payoff: count which publishers Google surfaces (once per
    /// topic per session) — the top of that table is the corpus's shopping list.
    private func logGNCensus(_ rows: [Article], topic: String) {
        guard !rows.isEmpty, !gnCountedTopics.contains(topic) else { return }
        gnCountedTopics.insert(topic)
        var counts: [String: Int] = [:]
        for r in rows where r.isExternal { counts[r.sourceName, default: 0] += 1 }
        let entries = counts.map { SupabaseAPI.GNEntry(name: $0.key, topic: topic, n: $0.value) }
        Task { await api.logGNSources(entries) }
    }

    /// Second census pass: enrichment learned the publisher's real domain — file it.
    private func logGNDomains(_ enriched: [Article]) {
        let entries: [SupabaseAPI.GNEntry] = enriched.compactMap { a in
            guard let host = a.url.host(), !gnDomainLogged.contains(a.sourceName) else { return nil }
            gnDomainLogged.insert(a.sourceName)
            return SupabaseAPI.GNEntry(name: a.sourceName, domain: host, n: 0)
        }
        if !entries.isEmpty { Task { await api.logGNSources(entries) } }
    }

    /// Cheap cross-engine dedupe key: same story, two tellings, one row.
    private static func titleKey(_ t: String) -> String {
        String(t.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(40))
    }

    /// Google News rows arrive imageless behind a news.google.com redirect: resolve
    /// the first screenfuls' publisher URLs + og:image (three requests each, six at a
    /// time — measured ~25s for 16 rows) and swap them in place — same ids, so rows
    /// update without re-animating. Rows beyond 16 stay lean; the reader resolves
    /// their URL on demand.
    private func enrichGoogle(_ topic: String, epoch: Int) {
        let batch = (customResults[topic] ?? []).filter {
            $0.imageURL == nil && ($0.url.host()?.contains("news.google.com") ?? false)
        }.prefix(16)
        guard !batch.isEmpty else { return }
        batch.forEach { enrichQueued.insert($0.id) }
        Task {
            var i = 0
            while i < batch.count {
                let chunk = Array(batch[i..<min(i + 6, batch.count)])
                i += 6
                let enriched = await withTaskGroup(of: Article?.self) { group in
                    for a in chunk { group.addTask { await GoogleNewsRSS.enrich(a) } }
                    var out: [Article] = []
                    for await e in group { if let e { out.append(e) } }
                    return out
                }
                guard epoch == customEpoch, googleNewsCustoms, var rows = customResults[topic] else { return }
                logGNDomains(enriched)
                for e in enriched {
                    if let idx = rows.firstIndex(where: { $0.id == e.id }) { rows[idx] = e }
                }
                // Attempted but imageless (failed resolve, or the page has no og:image):
                // stop the shimmer — these rows settle into the branded placeholder.
                let landed = Dictionary(enriched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for a in chunk where landed[a.id]?.imageURL == nil { gnNoImage.insert(a.id) }
                withAnimation(.easeInOut(duration: 0.3)) { customResults[topic] = rows }
            }
        }
    }

    /// Rows beyond the eager first-16 enrich as they scroll into view (google mode):
    /// one attempt per row per engine-epoch, swapped in place like the eager batch.
    func enrichIfNeeded(_ a: Article, topic: String? = nil) {
        guard googleNewsCustoms, a.isExternal, a.imageURL == nil,
              a.url.host()?.contains("news.google.com") == true,
              !enrichQueued.contains(a.id) else { return }
        guard let t = topic ?? customResults.first(where: { $0.value.contains { $0.id == a.id } })?.key
        else { return }
        enrichQueued.insert(a.id)
        let epoch = customEpoch
        Task {
            let e = await GoogleNewsRSS.enrich(a)
            guard epoch == customEpoch, googleNewsCustoms, var rows = customResults[t] else { return }
            if let e {
                logGNDomains([e])
                if let i = rows.firstIndex(where: { $0.id == e.id }) { rows[i] = e }
            }
            if e?.imageURL == nil { gnNoImage.insert(a.id) }
            withAnimation(.easeInOut(duration: 0.3)) { customResults[t] = rows }
        }
    }

    // MARK: - Helpers

    /// No source may own the screen: cap at 2 consecutive rows per source.
    private func diversify(_ input: [Article]) -> [Article] {
        guard input.count > 3 else { return input }
        var out: [Article] = []
        var pool = input
        while !pool.isEmpty {
            let n = out.count
            let blocked = n >= 2 && out[n-1].sourceName == out[n-2].sourceName ? out[n-1].sourceName : nil
            if let idx = pool.firstIndex(where: { $0.sourceName != blocked }) ?? pool.indices.first {
                out.append(pool.remove(at: idx))
            }
        }
        return out
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder.api.decode([Article].self, from: data) else { return }
        articles = cached
        hasLoadedOnce = true
    }

    private func saveCache(_ items: [Article]) {
        Task.detached(priority: .background) { [cacheURL] in
            if let data = try? JSONEncoder.api.encode(items) {
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
    }
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            // Postgres emits up to 6 fractional digits; ISO8601DateFormatter tolerates 3.
            let trimmed = s.replacingOccurrences(of: #"\.(\d{3})\d+"#, with: ".$1", options: .regularExpression)
            if let date = ISO8601DateFormatter.fractional.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
