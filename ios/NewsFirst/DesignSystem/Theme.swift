import SwiftUI

/// Design tokens. One place; no hex literals in feature code.
enum Theme {
    // MARK: Color
    static let accent = Color(red: 0.12, green: 0.22, blue: 0.39)          // navy
    static let tierHigh = Color(red: 0.85, green: 0.25, blue: 0.20)
    static let tierMedium = Color(red: 0.95, green: 0.62, blue: 0.10)
    static let tierLow = Color(red: 0.20, green: 0.60, blue: 0.40)

    static func tierColor(_ tier: Article.Tier) -> Color {
        switch tier {
        case .high: tierHigh
        case .medium: tierMedium
        case .low: tierLow
        }
    }

    // MARK: Motion — every animation in the app uses these; all are interruptible springs.
    // 120Hz rule: no async-after choreography, no JS-style timers; springs + transactions only.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.25)
        static let card = Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let feed = Animation.spring(response: 0.4, dampingFraction: 0.9)
    }

    // MARK: Type
    enum Type {
        static let headline = Font.system(.title3, design: .default, weight: .bold)
        static let cardTitle = Font.system(.headline, weight: .semibold)
        static let excerpt = Font.system(.subheadline)
        static let meta = Font.system(.caption, weight: .medium)
    }
}

/// Branded fallback when an article image is missing/broken — never a misleading stock photo.
struct TopicPlaceholder: View {
    let topic: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(topic.capitalized)
                .font(Theme.Type.meta)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
