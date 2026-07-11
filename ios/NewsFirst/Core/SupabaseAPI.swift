import Foundation

/// Thin PostgREST client. Reads go through the `feed` view — score/tier are computed in
/// Postgres at read time, so the client can never hold a stale tier.
struct SupabaseAPI {
    static let projectURL = URL(string: "https://sbqdvtzsezxupxxbmjsb.supabase.co")!
    // Publishable key — safe to ship in the client; RLS is the security boundary.
    static let publishableKey = "sb_publishable_zakPOvvP-fVhODt3_hVesA_AIDDGwV7"

    private static let fields = "id,url,title,excerpt,image_url,published_at,topics,regions,source_name,score,tier,cluster_id,cluster_sources,cluster_label"

    /// Whole ranked feed in one query — all preset topics filter client-side, so switching
    /// topics is instant (zero network).
    func fetchFeed(limit: Int = 250, offset: Int = 0) async throws -> [Article] {
        try await get([
            .init(name: "offset", value: String(offset)),
            .init(name: "select", value: Self.fields),
            .init(name: "order", value: "score.desc,published_at.desc"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    /// One article by id — the notification-tap path.
    func fetchArticle(id: String) async throws -> Article? {
        try await get([
            .init(name: "id", value: "eq.\(id)"),
            .init(name: "select", value: Self.fields),
            .init(name: "limit", value: "1"),
        ]).first
    }

    /// Every telling of one story — the Full Coverage page.
    func fetchCluster(_ clusterID: UUID) async throws -> [Article] {
        try await get([
            .init(name: "cluster_id", value: "eq.\(clusterID.uuidString.lowercased())"),
            .init(name: "select", value: Self.fields),
            .init(name: "order", value: "published_at.asc"),
            .init(name: "limit", value: "40"),
        ])
    }

    /// Sparse-topic / source-browse fallbacks: targeted server queries against the same view.
    func fetchTopic(_ topic: String, limit: Int = 60, offset: Int = 0) async throws -> [Article] {
        try await get([
            .init(name: "offset", value: String(offset)),
            .init(name: "topics", value: "cs.{\(topic)}"),
            .init(name: "select", value: Self.fields),
            .init(name: "order", value: "score.desc,published_at.desc"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    func fetchSource(_ name: String, limit: Int = 60, offset: Int = 0) async throws -> [Article] {
        try await get([
            .init(name: "offset", value: String(offset)),
            .init(name: "source_name", value: "eq.\(name)"),
            .init(name: "select", value: Self.fields),
            .init(name: "order", value: "published_at.desc"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    /// Custom topic = full-text search across title+excerpt (server-side, websearch
    /// semantics: word-boundary matches, stemming, multi-word AND) — `ilike *apple*`
    /// matched "pineapple", which is below the floor for the flagship feature.
    /// Google News source census: fire-and-forget counts into gn_source_sightings
    /// (via the gn_log definer RPC) so the most-surfaced publishers become corpus
    /// feed candidates. Failures are silently dropped — it's telemetry.
    struct GNEntry: Encodable, Sendable {
        let name: String
        var topic: String? = nil
        var domain: String? = nil
        let n: Int
    }
    func logGNSources(_ entries: [GNEntry]) async {
        struct Payload: Encodable { let entries: [GNEntry] }
        guard !entries.isEmpty,
              let body = try? JSONEncoder().encode(Payload(entries: entries)) else { return }
        var req = URLRequest(url: Self.projectURL.appending(path: "rest/v1/rpc/gn_log"))
        req.httpMethod = "POST"
        req.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(Self.publishableKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: req)
    }

    func searchArticles(matching query: String, limit: Int = 80) async throws -> [Article] {
        let q = query.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces)
        // Relevance × freshness ranking server-side (search_feed RPC) — recency-only
        // ordering front-loaded whichever blog posted last.
        var req = URLRequest(url: Self.projectURL.appending(path: "rest/v1/rpc/search_feed"))
        req.httpMethod = "POST"
        req.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(Self.publishableKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["q": q])
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder.api.decode([Article].self, from: data)
    }

    /// The signed-in user's push history — ONLY articles that actually notified them
    /// (the `alert_inbox` view). RLS-scoped, so it must carry the user's JWT, not the
    /// shared anon key.
    func fetchAlertInbox(token: String, limit: Int = 50) async throws -> [InboxItem] {
        var comps = URLComponents(url: Self.projectURL.appending(path: "rest/v1/alert_inbox"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "select", value: "alert_id,sent_at,\(Self.fields)"),
            .init(name: "order", value: "sent_at.desc"),
            .init(name: "limit", value: String(limit)),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder.api.decode([InboxItem].self, from: data)
    }

    func fetchBriefs() async throws -> [String: String] {
        var comps = URLComponents(url: Self.projectURL.appending(path: "rest/v1/briefs"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "select", value: "topic,content"),   // brief_date orders fine unselected
            .init(name: "order", value: "brief_date.desc"),
            .init(name: "limit", value: "40"),
        ]
        struct Row: Codable { let topic: String; let content: String }
        let rows: [Row] = try await request(comps.url!)
        var out: [String: String] = [:]
        for r in rows where out[r.topic] == nil { out[r.topic] = r.content }   // newest wins
        return out
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
    private static let strict = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func url(_ original: URL?, width: Int) -> URL? {
        guard let original else { return nil }
        // Fully percent-encode the nested URL: URLComponents legally leaves `&` bare
        // inside query values, which truncated signed CDN URLs (Guardian) at the proxy.
        guard let encoded = original.absoluteString.addingPercentEncoding(withAllowedCharacters: strict) else { return nil }
        return URL(string: "https://wsrv.nl/?url=\(encoded)&w=\(width)&fit=cover&output=webp&q=72")
    }
}
