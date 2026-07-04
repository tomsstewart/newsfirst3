import Foundation

/// Thin PostgREST client for the v3 backend.
/// Reads go through the `feed` view — priority score/tier are computed in Postgres at read
/// time, so the client can never hold a stale tier.
struct SupabaseAPI {
    static let projectURL = URL(string: "https://sbqdvtzsezxupxxbmjsb.supabase.co")!
    // Publishable key — safe to ship in the client; RLS is the security boundary.
    static let publishableKey = "sb_publishable_zakPOvvP-fVhODt3_hVesA_AIDDGwV7"

    func fetchFeed(topic: String? = nil, limit: Int = 100) async throws -> [Article] {
        var components = URLComponents(url: Self.projectURL.appending(path: "rest/v1/feed"), resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "select", value: "id,url,title,excerpt,image_url,published_at,topics,source_name,score,tier"),
            URLQueryItem(name: "order", value: "score.desc,published_at.desc"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let topic { query.append(URLQueryItem(name: "topics", value: "cs.{\(topic)}")) }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.publishableKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder.api.decode([Article].self, from: data)
    }
}
