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

    var selectedTopic: String = "world"
    var swipeProgress: CGFloat = 0   // live drag: -1..1 toward prev/next bar item
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
    var showBriefings: Bool { didSet { defaults.set(showBriefings, forKey: "showBriefings") } }
    var disabledSources: Set<String> { didSet { defaults.set(Array(disabledSources), forKey: "disabledSources"); rankedCache.removeAll() } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var regionPref: RegionBucket { didSet { defaults.set(regionPref.rawValue, forKey: "regionPref"); rankedCache.removeAll() } }
    var showPriorityDebug: Bool { didSet { defaults.set(showPriorityDebug, forKey: "priorityDebug") } }
    var readerMode: Bool { didSet { defaults.set(readerMode, forKey: "readerMode") } }
    var defaultMode: ViewMode { didSet { defaults.set(defaultMode.rawValue, forKey: "defaultMode") } }

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
        readerMode = defaults.object(forKey: "readerMode") as? Bool ?? true
        defaultMode = ViewMode(rawValue: defaults.string(forKey: "defaultMode") ?? "") ?? .list
        notifyTopics = Set(defaults.stringArray(forKey: "notifyTopics") ?? [])
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
            if !r.isDisjoint(with: home) { adj += 12 }                 // my market's story
            else if r.isSubset(of: Self.marketCodes) { adj -= 8 }      // exclusively someone else's market
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
            let extra = (topicExtra[topic] ?? []).filter { e in !articles.contains(where: { $0.id == e.id }) }
            base = articles + extra
        } else {
            let local = articles.filter { $0.topics.contains(topic) }
            base = local.isEmpty ? (topicExtra[topic] ?? []) : local + (topicExtra[topic] ?? []).filter { e in !local.contains(where: { $0.id == e.id }) }
        }
        let filtered = base.filter { !disabledSources.contains($0.sourceName) }
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

    /// Full Coverage sheet: the seed article whose story cluster is open.
    var story: Article? {
        didSet { if story != nil { Analytics.capture("full_coverage_open") } }
    }

    /// Briefing cards dismissed this session (per topic; fresh launch restores them).
    private(set) var dismissedBriefs: Set<String> = []
    func dismissBrief(_ topic: String) { dismissedBriefs.insert(topic) }

    /// Per-topic notification opt-in (v2.5's bell-next-to-title). Bell on = server
    /// notify_level 'high' (breaking only); custom topics always alert on any match.
    var notifyTopics: Set<String> {
        didSet { defaults.set(Array(notifyTopics), forKey: "notifyTopics") }
    }
    func toggleNotify(_ topic: String) {
        if notifyTopics.contains(topic) { notifyTopics.remove(topic) } else { notifyTopics.insert(topic) }
        Analytics.capture("topic_notify_toggle", ["topic": topic, "on": notifyTopics.contains(topic)])
        // The bell IS the moment of intent: ask for permission here, never at launch.
        if notifyTopics.contains(topic) { PushManager.shared.enablePush() }
        Task { await AuthClient.shared.syncTopics(preset: enabledTopics, custom: customTopics) }
    }

    /// Notification tap → reader. Pools first (instant), server fallback for an
    /// article that scrolled out of the cached window.
    func openArticle(id: String) async {
        let target = id.lowercased()
        let pools = articles + topicExtra.values.flatMap { $0 } + sourceResults.values.flatMap { $0 }
        if let hit = pools.first(where: { $0.id.uuidString.lowercased() == target }) {
            reading = hit
            return
        }
        if let fetched = try? await api.fetchArticle(id: target) { reading = fetched }
    }

    /// The bell inbox: current breaking stories (high tier = notification-grade), one per cluster.
    var breakingStories: [Article] {
        collapseDuplicates(articles.filter { $0.tier == .high }
            .sorted { $0.publishedAt > $1.publishedAt })
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
        let intros = ["The top story, from", "Next, from", "And finally, from"]
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
            parts.append("We begin with breaking news.")
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
            parts.append(breaking.isEmpty ? "First, the topics you follow." : "Next, the topics you follow.")
            parts.append(contentsOf: customParts)
        }

        // Then the rest of the front page (skipping anything already covered above).
        let top = visibleItems(topic: Self.topStories, source: "")
            .filter { a in !mentionedIDs.contains(a.id) && (a.clusterID.map { !mentionedClusters.contains($0) } ?? true) }
            .prefix(3)
        if !top.isEmpty {
            parts.append(parts.count <= 1 ? "Today's top stories." : "Now, the rest of today's top stories.")
            let intros = ["The lead story, from", "In other news, from", "And finally, from"]
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
        return ["\(greeting)."] + parts + ["That's your briefing."]
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
                Task {
                    if let results = try? await api.searchArticles(matching: t) {
                        withAnimation(Theme.Motion.feed) { customResults[t] = results }
                    }
                }
            }
            dismissedBriefs.removeAll()   // a manual refresh brings dismissed briefings back
            if let fetched = try? await api.fetchBriefs() {
                // Animated: the brief card lands above an on-screen feed — a hard
                // insert shoved every row down in a single frame.
                withAnimation(Theme.Motion.feed) { briefs = fetched }
            }
        } catch {
            hasLoadedOnce = true   // keep cache on screen; never a blocking error
        }
    }

    // MARK: - Custom topics

    func addCustomTopic(_ raw: String) {
        let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !topic.isEmpty, !customTopics.contains(topic), !Self.presetTopics.contains(topic) else { return }
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
            if selectedTopic == topic { selectedTopic = enabledTopics.first ?? "world" }
        }
    }

    func loadCustom(_ topic: String) async {
        guard customResults[topic] == nil, !loadingCustom.contains(topic) else { return }
        loadingCustom.insert(topic)
        defer { loadingCustom.remove(topic) }
        // On failure leave nil (retry on next selection) — caching `[]` bricked the
        // topic for the whole session, on the product's flagship feature.
        if let results = try? await api.searchArticles(matching: topic) {
            withAnimation(Theme.Motion.feed) { customResults[topic] = results }
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
