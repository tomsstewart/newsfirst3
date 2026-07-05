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

    enum Tier: String, Codable { case high, medium, low }

    enum CodingKeys: String, CodingKey {
        case id, url, title, excerpt, topics, regions, score, tier
        case imageURL = "image_url"
        case publishedAt = "published_at"
        case sourceName = "source_name"
        case clusterID = "cluster_id"
        case clusterSources = "cluster_sources"
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
