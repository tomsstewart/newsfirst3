import Foundation
import Observation

/// Cache-first article store — the cold-start budget (<400ms to first feed frame) lives here.
/// The last feed is persisted to disk and rendered synchronously on launch;
/// the network refresh happens behind it and animates in. No network on the render path, ever.
@Observable @MainActor
final class FeedStore {
    private(set) var articles: [Article] = []
    private(set) var isRefreshing = false
    var selectedTopic: String = "world"

    private let api = SupabaseAPI()
    private let cacheURL = URL.cachesDirectory.appending(path: "feed-cache.json")

    var visible: [Article] {
        articles
            .filter { $0.topics.contains(selectedTopic) }
            .sorted { ($0.score, $0.publishedAt) > ($1.score, $1.publishedAt) }
    }

    func start() async {
        loadCache()          // synchronous-fast: feed is on screen before any network
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await api.fetchFeed(limit: 200)
            withAnimation(.snappy(duration: 0.3)) { articles = fresh }
            saveCache(fresh)
        } catch {
            // Cache remains on screen; surface staleness subtly, never a blocking error.
        }
    }

    // MARK: - disk cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder.api.decode([Article].self, from: data) else { return }
        articles = cached
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
            if let date = ISO8601DateFormatter.fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
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
