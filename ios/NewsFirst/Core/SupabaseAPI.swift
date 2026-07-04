import Foundation

/// Thin PostgREST client. Reads go through the `feed` view — score/tier are computed in
/// Postgres at read time, so the client can never hold a stale tier.
struct SupabaseAPI {
    static let projectURL = URL(string: "https://sbqdvtzsezxupxxbmjsb.supabase.co")!
    // Publishable key — safe to ship in the client; RLS is the security boundary.
    static let publishableKey = "sb_publishable_zakPOvvP-fVhODt3_hVesA_AIDDGwV7"

    private static let fields = "id,url,title,excerpt,image_url,published_at,topics,source_name,score,tier"

    /// Whole ranked feed in one query — all preset topics filter client-side, so switching
    /// topics is instant (zero network).
    func fetchFeed(limit: Int = 250) async throws -> [Article] {
        try await get([
            .init(name: "select", value: Self.fields),
            .init(name: "order", value: "score.desc,published_at.desc"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    /// Sparse-topic / source-browse fallbacks: targeted server queries against the same view.
    func fetchTopic(_ topic: String, limit: Int = 60) async throws -> [Article] {
        try await get([
            .init(name: "topics", value: "cs.{\(topic)}"),
            .init(name: "select", value: Self.fields),
            .init(name: "order", value: "score.desc,published_at.desc"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    func fetchSource(_ name: String, limit: Int = 60) async throws -> [Article] {
        try await get([
            .init(name: "source_name", value: "eq.\(name)"),
            .init(name: "select", value: Self.fields),
            .init(name: "order", value: "published_at.desc"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    /// Custom topic = keyword search across title/excerpt (server-side), ranked as usual.
    func searchArticles(matching query: String, limit: Int = 80) async throws -> [Article] {
        let q = query.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces)
        return try await get([
            .init(name: "or", value: "(title.ilike.*\(q)*,excerpt.ilike.*\(q)*)"),
            .init(name: "select", value: Self.fields),
            .init(name: "order", value: "published_at.desc"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    func fetchSources() async throws -> [FeedSource] {
        var comps = URLComponents(url: Self.projectURL.appending(path: "rest/v1/sources"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "select", value: "id,name,category"),
            .init(name: "is_enabled", value: "eq.true"),
            .init(name: "order", value: "name.asc"),
        ]
        return try await request(comps.url!)
    }

    private func get(_ query: [URLQueryItem]) async throws -> [Article] {
        var comps = URLComponents(url: Self.projectURL.appending(path: "rest/v1/feed"), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        return try await request(comps.url!)
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(Self.publishableKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder.api.decode(T.self, from: data)
    }
}

struct FeedSource: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let category: String
}

/// Image CDN proxy: resizes + caches at the edge and shields us from hotlink blocks.
enum ImageProxy {
    static func url(_ original: URL?, width: Int) -> URL? {
        guard let original else { return nil }
        var comps = URLComponents(string: "https://wsrv.nl/")!
        comps.queryItems = [
            .init(name: "url", value: original.absoluteString),
            .init(name: "w", value: String(width)),
            .init(name: "fit", value: "cover"),
            .init(name: "output", value: "webp"),
            .init(name: "q", value: "72"),
        ]
        return comps.url
    }
}
