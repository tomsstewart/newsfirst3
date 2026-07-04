import Foundation
import Observation
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case immersive = "Immersive"
    case full = "Full"
    var id: String { rawValue }
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
    private(set) var loadingCustom: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var hasLoadedOnce = false

    var selectedTopic: String = "world"
    var mode: ViewMode = .list
    var reading: Article?                                     // in-app reader presentation

    // Persisted preferences (UserDefaults now; syncs to topic_subscriptions post-auth)
    var customTopics: [String] { didSet { defaults.set(customTopics, forKey: "customTopics") } }
    var enabledTopics: [String] { didSet { defaults.set(enabledTopics, forKey: "enabledTopics") } }
    var disabledSources: Set<String> { didSet { defaults.set(Array(disabledSources), forKey: "disabledSources") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var defaultMode: ViewMode { didSet { defaults.set(defaultMode.rawValue, forKey: "defaultMode") } }

    private let api = SupabaseAPI()
    private let defaults = UserDefaults.standard
    private let cacheURL = URL.cachesDirectory.appending(path: "feed-cache.json")

    init() {
        customTopics = defaults.stringArray(forKey: "customTopics") ?? []
        enabledTopics = defaults.stringArray(forKey: "enabledTopics") ?? Array(Self.presetTopics.prefix(8))
        disabledSources = Set(defaults.stringArray(forKey: "disabledSources") ?? [])
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .auto
        defaultMode = ViewMode(rawValue: defaults.string(forKey: "defaultMode") ?? "") ?? .list
        mode = defaultMode
    }

    var topicBar: [String] { enabledTopics + customTopics }

    var isCustomSelected: Bool { customTopics.contains(selectedTopic) }

    /// Articles for the selected topic, source-diversity capped.
    var visible: [Article] {
        let base: [Article]
        if isCustomSelected {
            base = customResults[selectedTopic] ?? []
        } else {
            base = articles.filter { $0.topics.contains(selectedTopic) }
        }
        let filtered = base.filter { !disabledSources.contains($0.sourceName) }
        return diversify(filtered.sorted { ($0.score, $0.publishedAt) > ($1.score, $1.publishedAt) })
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
            let fresh = try await api.fetchFeed()
            withAnimation(Theme.Motion.feed) { articles = fresh; hasLoadedOnce = true }
            saveCache(fresh)
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
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
