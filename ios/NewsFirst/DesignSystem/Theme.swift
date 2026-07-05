import SwiftUI

/// Midnight Glass palette + Kinetic Editorial motion. One place; no hex literals in feature code.
enum Theme {
    /// Scheme-adaptive color: (light, dark). Kinetic Editorial palette from the POC.
    private static func dyn(_ l: (Double, Double, Double), _ d: (Double, Double, Double)) -> Color {
        #if os(iOS)
        Color(UIColor { tc in
            let c = tc.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(NSColor(name: nil) { app in
            let c = app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    // Midnight Glass colours (Tom's approved scheme); light = clean editorial ivory.
    // Kinetic Editorial contributes TYPE, SPACING and MOTION only — not colour.
    static let canvas = dyn((0.953, 0.949, 0.937), (0.047, 0.055, 0.078))   // dark #0C0E14
    static let panel  = dyn((1.0, 1.0, 1.0),       (0.118, 0.133, 0.184))   // dark #1E2230
    static let panelBorder = dyn((0.886, 0.882, 0.859), (0.255, 0.275, 0.333))
    static let accent = Color(red: 0.30, green: 0.62, blue: 0.92)           // glassy blue
    static let link = dyn((0.10, 0.42, 0.85), (0.30, 0.62, 0.92))
    static var selectionGradient: LinearGradient {
        LinearGradient(colors: [accent, Color(red: 0.18, green: 0.42, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let tierHigh = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let tierMedium = Color(red: 1.0, green: 0.58, blue: 0.16)
    static let tierLow = Color(red: 0.24, green: 0.78, blue: 0.45)

    static func tierColor(_ tier: Article.Tier) -> Color {
        switch tier { case .high: tierHigh; case .medium: tierMedium; case .low: tierLow }
    }

    static var groupedBackground: Color { canvas }
    static var cardBackground: Color { panel }
    static var rowBackground: Color { panel }

    // Kinetic Editorial: springs only, entrances that slide-and-settle, breathing accents.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.25)
        static let card = Animation.smooth(duration: 0.32)
        static let feed = Animation.smooth(duration: 0.38)
        static let press = Animation.spring(response: 0.28, dampingFraction: 0.7)
        static let expand = Animation.easeInOut(duration: 0.30)   // v2.5 LayoutAnimation.easeInEaseOut
    }

    enum Text {
        static let hero = Font.system(.title2, weight: .bold)
        static let headline = Font.system(.title3, design: .default, weight: .bold)
        static let cardTitle = Font.system(.headline, weight: .semibold)
        static let rowTitle = Font.system(.subheadline, weight: .semibold)
        static let excerpt = Font.system(.footnote)
        static let meta = Font.system(.caption, weight: .medium)
        static let badge = Font.system(.caption2, weight: .bold)
    }
}

// MARK: - Kinetic entrance (cards slide up, settle, un-blur — staggered by index)

enum KineticGate {
    nonisolated(unsafe) static var suppressed = false   // set true for swipe navigation, false for chip taps
}

struct KineticEntrance: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 26)
            .onAppear {
                // The rise is a topic-entry flourish for the first screenful only;
                // rows appearing during scroll must arrive already-settled.
                if KineticGate.suppressed || index > 7 {
                    shown = true
                } else {
                    // POC .kn-rise: cubic-bezier(.2,.75,.25,1) over 0.65s, 0.12s stagger
                    withAnimation(.timingCurve(0.2, 0.75, 0.25, 1, duration: 0.65)
                        .delay(Double(min(index, 6)) * 0.12)) { shown = true }
                }
            }
    }
}

extension View {
    func kineticEntrance(_ index: Int) -> some View { modifier(KineticEntrance(index: index)) }
}

// MARK: - Shared components

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
                .shadow(color: Theme.tierColor(tier).opacity(0.6), radius: 6)
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.tierColor(tier))
                .frame(width: 4, height: 14)
                .shadow(color: Theme.tierColor(tier).opacity(0.7), radius: 3)
        }
    }
}

/// Band header: "High Priority" pill on a tier-tinted gradient that fades out rightward.
struct PriorityBand: View {
    let tier: Article.Tier
    var trailing: AnyView? = nil
    private var label: String {
        switch tier { case .high: "High Priority"; case .medium: "Medium Priority"; case .low: "Low Priority" }
    }
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Capsule().fill(Theme.tierColor(tier)).frame(width: 6, height: 16)
                    .shadow(color: Theme.tierColor(tier).opacity(0.8), radius: 4)
                Text(label)
                    .font(.system(.footnote, weight: .heavy))   // compact + punchy, not headline-sized
                    .foregroundStyle(.primary)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            LinearGradient(colors: [Theme.tierColor(tier).opacity(0.22), .clear],
                           startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct SourceLine: View {
    let article: Article
    var body: some View {
        HStack(spacing: 6) {
            SourceLink(article: article)
            Spacer(minLength: 8)
            Text(article.publishedAt, format: .relative(presentation: .named))
                .foregroundStyle(.secondary)
        }
        .font(Theme.Text.meta)
    }
}

/// Tapping a source name jumps to that source's own feed (Sources browse mode).
struct SourceLink: View {
    @Environment(FeedStore.self) private var store
    let article: Article
    var body: some View {
        Button {
            withAnimation(Theme.Motion.feed) {
                store.browse = .sources
                store.selectedSource = article.sourceName
            }
            Task { await store.loadSources(); await store.backfillIfSparse() }
        } label: {
            Text(article.sourceName)
                .foregroundStyle(Theme.link)
                .underline()
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

/// Glass press feedback: scale + brighten, spring-driven, interruptible.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// iOS-26-style glass chip/button surface.
struct GlassSurface: ViewModifier {
    var prominent = false
    func body(content: Content) -> some View {
        content
            .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0.25 : 0.10), lineWidth: 1))
            .shadow(color: prominent ? Theme.accent.opacity(0.45) : .clear, radius: 8, y: 2)
    }
}

extension View {
    func glassChip(prominent: Bool = false) -> some View { modifier(GlassSurface(prominent: prominent)) }
}

/// Branded fallback when an article image is missing/broken — never a misleading stock photo.
struct TopicPlaceholder: View {
    let topic: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.panel],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(topic.capitalized)
                .font(Theme.Text.badge)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Skeleton shimmer (glassy)

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear],
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
            .fill(.primary.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.05), lineWidth: 1))
            .frame(height: height)
            .shimmer()
    }
}
