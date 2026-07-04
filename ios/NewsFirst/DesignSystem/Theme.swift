import SwiftUI

/// Design tokens. One place; no hex literals in feature code.
enum Theme {
    static let accent = Color(red: 0.16, green: 0.35, blue: 0.85)   // electric blue
    static let tierHigh = Color(red: 0.92, green: 0.26, blue: 0.21)
    static let tierMedium = Color(red: 0.95, green: 0.62, blue: 0.10)
    static let tierLow = Color(red: 0.35, green: 0.65, blue: 0.45)

    static func tierColor(_ tier: Article.Tier) -> Color {
        switch tier { case .high: tierHigh; case .medium: tierMedium; case .low: tierLow }
    }

    #if os(iOS)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let rowBackground = Color(.secondarySystemGroupedBackground)
    #else
    static let groupedBackground = Color(nsColor: .underPageBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let rowBackground = Color(nsColor: .controlBackgroundColor)
    #endif

    // 120Hz rule: interruptible springs only; no async-after choreography.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.25)
        static let card = Animation.spring(response: 0.35, dampingFraction: 0.82)
        static let feed = Animation.spring(response: 0.42, dampingFraction: 0.88)
        static let press = Animation.spring(response: 0.28, dampingFraction: 0.7)
    }

    enum Text {
        static let hero = Font.system(.title2, weight: .bold)
        static let headline = Font.system(.title3, design: .default, weight: .bold)
        static let cardTitle = Font.system(.headline, weight: .semibold)
        static let rowTitle = Font.system(.subheadline, weight: .semibold)
        static let excerpt = Font.system(.subheadline)
        static let meta = Font.system(.caption, weight: .medium)
        static let badge = Font.system(.caption2, weight: .bold)
    }
}

// MARK: - Shared components

/// Priority badge — quiet dot in dense contexts, loud capsule in full-bleed.
struct TierBadge: View {
    let tier: Article.Tier
    var loud = false
    var body: some View {
        if loud {
            Text(tier.rawValue.uppercased())
                .font(Theme.Text.badge)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.tierColor(tier), in: Capsule())
                .foregroundStyle(.white)
        } else {
            Circle().fill(Theme.tierColor(tier)).frame(width: 7, height: 7)
        }
    }
}

struct SourceLine: View {
    let article: Article
    var body: some View {
        HStack(spacing: 6) {
            TierBadge(tier: article.tier)
            Text(article.sourceName).lineLimit(1)
            Text("·")
            Text(article.publishedAt, format: .relative(presentation: .named))
        }
        .font(Theme.Text.meta)
        .foregroundStyle(.secondary)
    }
}

/// Press feedback: scale + dim, spring-driven, interruptible.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Branded fallback when an article image is missing/broken — never a misleading stock photo.
struct TopicPlaceholder: View {
    let topic: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.85), Theme.accent.opacity(0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(topic.capitalized)
                .font(Theme.Text.badge)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

// MARK: - Skeleton shimmer

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.7)
                        .offset(x: phase * geo.size.width * 1.7)
                }
                .allowsHitTesting(false)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

struct SkeletonBlock: View {
    var height: CGFloat
    var radius: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.quaternary)
            .frame(height: height)
            .shimmer()
    }
}
