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
@Observable @MainActor
final class FeedStore {
    static let presetTopics = ["world", "business", "economics", "tech", "ai", "science", "sports", "crypto", "gaming", "entertainment", "space", "climate", "health", "travel"]

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
    var customTopics: [String] { didSet { defaults.set(customTopics, forKey: "customTopics"); validateSelection() } }
    var enabledTopics: [String] { didSet { defaults.set(enabledTopics, forKey: "enabledTopics"); validateSelection() } }
    var disabledSources: Set<String> { didSet { defaults.set(Array(disabledSources), forKey: "disabledSources"); rankedCache.removeAll() } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var showPriorityDebug: Bool { didSet { defaults.set(showPriorityDebug, forKey: "priorityDebug") } }
    var readerMode: Bool { didSet { defaults.set(readerMode, forKey: "readerMode") } }
    var defaultMode: ViewMode { didSet { defaults.set(defaultMode.rawValue, forKey: "defaultMode") } }

    private let api = SupabaseAPI()
    private let defaults = UserDefaults.standard
    private let cacheURL = URL.cachesDirectory.appending(path: "feed-cache.json")

    init() {
        customTopics = defaults.stringArray(forKey: "customTopics") ?? []
        enabledTopics = defaults.stringArray(forKey: "enabledTopics") ?? Array(Self.presetTopics.prefix(8))
        disabledSources = Set(defaults.stringArray(forKey: "disabledSources") ?? [])
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .auto
        showPriorityDebug = defaults.bool(forKey: "priorityDebug")
        readerMode = defaults.object(forKey: "readerMode") as? Bool ?? true
        defaultMode = ViewMode(rawValue: defaults.string(forKey: "defaultMode") ?? "") ?? .list
        mode = defaultMode
        validateSelection()
    }

    /// The selected topic must always exist in the bar — otherwise no chip highlights,
    /// the pill vanishes and swipes dead-end (e.g. after disabling the selected topic).
    private func validateSelection() {
        if browse == .topics, !topicBar.contains(selectedTopic) {
            selectedTopic = topicBar.first ?? "world"
        }
    }

    var topicBar: [String] { enabledTopics + customTopics }
    var sourceBar: [String] { sources.map(\.name) }

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
        } else {
            let local = articles.filter { $0.topics.contains(topic) }
            base = local.isEmpty ? (topicExtra[topic] ?? []) : local + (topicExtra[topic] ?? []).filter { e in !local.contains(where: { $0.id == e.id }) }
        }
        let filtered = base.filter { !disabledSources.contains($0.sourceName) }
        let ranked = filtered.sorted {
            // score first; among peers prefer image-bearing (beautiful sections), then freshness
            if $0.score != $1.score { return $0.score > $1.score }
            if ($0.imageURL != nil) != ($1.imageURL != nil) { return $0.imageURL != nil }
            return $0.publishedAt > $1.publishedAt
        }
        return diversify(collapseDuplicates(ranked))
    }

    /// Same story from many feeds: keep the best-ranked telling, drop echoes.
    private func collapseDuplicates(_ input: [Article]) -> [Article] {
        var seen: Set<String> = []
        return input.filter { a in
            let key = String(a.title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(56))
            guard !key.isEmpty else { return true }
            return seen.insert(key).inserted
        }
    }

    var isLoadingSelected: Bool {
        if isCustomSelected { return loadingCustom.contains(selectedTopic) && (customResults[selectedTopic] ?? []).isEmpty }
        return !hasLoadedOnce && articles.isEmpty
    }

    /// The one topic pane that carries this session's AI briefing (set once at launch —
    /// one overview per session, not one per topic).
    private(set) var sessionBriefTopic: String?

    func start() async {
        loadCache()          // synchronous-fast: feed on screen before any network
        sessionBriefTopic = selectedTopic
        await refresh()
    }

    /// Whether this session's briefing was dismissed (session-scoped, not persisted —
    /// a fresh launch brings the card back).
    var briefDismissed = false

    /// Session briefing in the assistant "tell me the news" register: greeting, the
    /// user's CUSTOM topics with real depth (two stories each, summary sentence on the
    /// lead), then attributed top stories from their chosen topics. Spoken in full;
    /// the card truncates visually.
    var personalBriefing: String { personalBriefingParts.joined(separator: " ") }

    /// Segments, not one blob: the speech engine gives each story its own utterance
    /// with a newsreader beat between them — same text, dramatically better delivery.
    var personalBriefingParts: [String] {
        var parts: [String] = []
        let hour = Calendar.current.component(.hour, from: .now)
        let greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"

        for t in customTopics.prefix(3) {
            let items = customResults[t] ?? []
            guard let lead = items.first else { continue }
            var line = "On \(t.capitalized) — from \(lead.sourceName): \(Self.sentence(lead.title))"
            if let s = Self.firstSentence(lead.excerpt) { line += " \(s)" }
            parts.append(line)
            if let second = items.dropFirst().first(where: { $0.sourceName != lead.sourceName || $0.title != lead.title }) {
                parts.append("Also: \(Self.sentence(second.title))")
            }
        }

        var seen: Set<String> = []
        let highs = articles
            .filter { a in a.tier == .high && a.topics.contains(where: { enabledTopics.contains($0) }) }
            .filter { a in
                let key = String(a.title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(40))
                return seen.insert(key).inserted
            }
            .prefix(3)
        if !highs.isEmpty {
            parts.append(parts.isEmpty ? "The top stories from your topics." : "Now, the top stories from your topics.")
            for (i, a) in highs.enumerated() {
                var line = "From \(a.sourceName): \(Self.sentence(a.title))"
                if i < 2, let s = Self.firstSentence(a.excerpt) { line += " \(s)" }
                parts.append(line)
            }
        }

        // Thin day and no customs: the server's per-topic overview still beats silence.
        if parts.isEmpty, let brief = briefs[sessionBriefTopic ?? selectedTopic] {
            parts.append(brief)
        }
        guard !parts.isEmpty else { return [] }
        return ["\(greeting). Here's your briefing."] + parts + ["That's your briefing."]
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
            // Custom topics live server-side only — warm them with the feed so swiping
            // into one lands on content, not a blank pane waiting for its first search.
            for t in customTopics where customResults[t] == nil {
                Task { await loadCustom(t) }
            }
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
