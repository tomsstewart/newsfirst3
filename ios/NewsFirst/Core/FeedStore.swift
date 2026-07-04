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

    private(set) var articles: [Article] = []                 // whole ranked feed
    private(set) var customResults: [String: [Article]] = [:] // custom topic -> results
    private(set) var topicExtra: [String: [Article]] = [:]     // sparse preset topic -> targeted fetch
    private(set) var sourceResults: [String: [Article]] = [:]  // source name -> targeted fetch
    private(set) var briefs: [String: String] = [:]             // topic -> latest AI overview
    private(set) var loadingCustom: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var hasLoadedOnce = false

    var selectedTopic: String = "world"
    var browse: BrowseMode = .topics
    var selectedSource: String = ""
    private(set) var sources: [FeedSource] = []
    var mode: ViewMode = .list
    var reading: Article? {
        didSet { if let a = reading { Analytics.capture("article_open", ["source": a.sourceName, "tier": a.tier.rawValue]) } }
    }

    // Persisted preferences (UserDefaults now; syncs to topic_subscriptions post-auth)
    var customTopics: [String] { didSet { defaults.set(customTopics, forKey: "customTopics") } }
    var enabledTopics: [String] { didSet { defaults.set(enabledTopics, forKey: "enabledTopics") } }
    var disabledSources: Set<String> { didSet { defaults.set(Array(disabledSources), forKey: "disabledSources") } }
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
    }

    var topicBar: [String] { enabledTopics + customTopics }
    var sourceBar: [String] { sources.map(\.name) }

    /// Called when a preset topic or source shows empty — targeted server fetch fills it.
    func backfillIfSparse() async {
        if browse == .sources {
            let s = selectedSource
            guard !s.isEmpty, articles.filter({ $0.sourceName == s }).isEmpty, sourceResults[s] == nil else { return }
            sourceResults[s] = (try? await api.fetchSource(s)) ?? []
        } else if !isCustomSelected {
            let t = selectedTopic
            // Backfill thin topics too, not just empty ones — every section deserves a full page.
            guard articles.filter({ $0.topics.contains(t) }).count < 8, topicExtra[t] == nil else { return }
            topicExtra[t] = (try? await api.fetchTopic(t)) ?? []
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

    /// Sensible initial page; "Load more" raises the cap and pulls further pages server-side.
    static let pageSize = 30
    private(set) var renderCaps: [String: Int] = [:]

    private var capKey: String { browse == .topics ? "t:\(selectedTopic)" : "s:\(selectedSource)" }
    var renderCap: Int { renderCaps[capKey] ?? Self.pageSize }
    var canLoadMore: Bool { visibleUncapped.count > renderCap || visibleUncapped.count >= renderCap }

    func loadMore() async {
        let key = capKey
        let newCap = (renderCaps[key] ?? Self.pageSize) + Self.pageSize
        renderCaps[key] = newCap
        // If the local pool can't fill the new cap, page more from the server.
        if visibleUncapped.count < newCap {
            if browse == .sources {
                let extra = (try? await api.fetchSource(selectedSource, limit: Self.pageSize, offset: visibleUncapped.count)) ?? []
                sourceResults[selectedSource, default: []].append(contentsOf: extra.filter { a in !visibleUncapped.contains(where: { $0.id == a.id }) })
            } else if !isCustomSelected {
                let extra = (try? await api.fetchTopic(selectedTopic, limit: Self.pageSize, offset: visibleUncapped.count)) ?? []
                topicExtra[selectedTopic, default: []].append(contentsOf: extra.filter { a in !visibleUncapped.contains(where: { $0.id == a.id }) })
            }
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
        return browse == .topics ? visibleItems(topic: item, source: "") : visibleItems(topic: "", source: item)
    }

    func barItem(offset: Int) -> String {
        let bar = browse == .topics ? topicBar : sourceBar
        let current = browse == .topics ? selectedTopic : selectedSource
        guard !bar.isEmpty, let idx = bar.firstIndex(of: current) else { return current }
        return bar[(idx + offset + bar.count) % bar.count]
    }

    private func visibleItems(topic: String, source: String) -> [Article] {
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

    func start() async {
        loadCache()          // synchronous-fast: feed on screen before any network
        await refresh()
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
            briefs = (try? await api.fetchBriefs()) ?? briefs
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
        if let results = try? await api.searchArticles(matching: topic) {
            withAnimation(Theme.Motion.feed) { customResults[topic] = results }
        } else {
            customResults[topic] = []
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
