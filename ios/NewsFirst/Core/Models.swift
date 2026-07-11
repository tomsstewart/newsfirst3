import Foundation

struct Article: Codable, Identifiable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let excerpt: String?
    let imageURL: URL?
    let publishedAt: Date
    let topics: [String]
    let regions: [String]?          // ISO-3166 alpha-2 the story is ABOUT (drives locale weighting)
    let sourceName: String
    let score: Double
    let tier: Tier
    let clusterID: UUID?            // story identity — one story told by many sources
    let clusterSources: Int?        // distinct sources in the cluster (≥2 → Full Coverage)
    let clusterLabel: String?       // dominant subject across the cluster's headlines ("Xbox")
    /// True for rows fetched from outside our corpus (Google News experiment):
    /// their source name isn't in our Sources browse, so it must not be a link.
    /// Not in CodingKeys — server rows decode with the default.
    var isExternal: Bool = false

    enum Tier: String, Codable { case high, medium, low }

    enum CodingKeys: String, CodingKey {
        case id, url, title, excerpt, topics, regions, score, tier
        case imageURL = "image_url"
        case publishedAt = "published_at"
        case sourceName = "source_name"
        case clusterID = "cluster_id"
        case clusterSources = "cluster_sources"
        case clusterLabel = "cluster_label"
    }

    /// Display copy at a different tier. Used to cap the High band to a handful without
    /// touching the server-computed tier (badge + band header then stay consistent).
    func withTier(_ t: Tier) -> Article {
        Article(id: id, url: url, title: title, excerpt: excerpt, imageURL: imageURL,
                publishedAt: publishedAt, topics: topics, regions: regions, sourceName: sourceName,
                score: score, tier: t, clusterID: clusterID, clusterSources: clusterSources,
                clusterLabel: clusterLabel, isExternal: isExternal)
    }
}

/// One entry in the notification drawer: an article that ACTUALLY pushed to this user
/// (from the `alert_inbox` view), plus when it was sent. Decodes the flat row into the
/// shared Article shape + the alert metadata.
struct InboxItem: Identifiable, Decodable, Hashable {
    let alertId: String
    let sentAt: Date
    let article: Article
    var id: String { alertId }

    enum CodingKeys: String, CodingKey { case alertId = "alert_id"; case sentAt = "sent_at" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alertId = try c.decode(String.self, forKey: .alertId)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        article = try Article(from: decoder)   // same flat container carries the article columns
    }
}

/// Per-topic notification control — a core product feature, mirrored by
/// `topic_subscriptions.notify_level` and enforced server-side by the alert matcher.
enum NotifyLevel: String, Codable, CaseIterable {
    case none   // no pushes for this topic
    case high   // high-priority matches only
    case all    // every match (the "be first to know" mode)
}

struct TopicSubscription: Codable, Identifiable, Hashable {
    var id: String { topic }
    let topic: String
    let kind: Kind
    var notifyLevel: NotifyLevel

    enum Kind: String, Codable { case preset, custom }
    enum CodingKeys: String, CodingKey {
        case topic, kind
        case notifyLevel = "notify_level"
    }
}

enum PresetTopic: String, CaseIterable {
    case world, business, economics, tech, ai, science, sports, space,
         climate, entertainment, travel, crypto, health, gaming
}
