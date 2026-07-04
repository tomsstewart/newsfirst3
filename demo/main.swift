// NewsFirst v3 — macOS demo shell around the real app RootView.
// Modes:  ./NewsFirstDemo             → interactive window (full app at iPhone dimensions)
//         ./NewsFirstDemo --snapshot  → headless PNG renders to demo/out/ for design review
import SwiftUI
import AppKit

struct DemoApp: App {
    @State private var store = FeedStore()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.start() }
                .frame(width: 393, height: 852)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Headless snapshot mode

@MainActor
func preload(_ articles: [Article], limit: Int) async {
    for a in articles.prefix(limit) {
        guard let orig = a.imageURL, ImagePipeline.preloaded[orig] == nil,
              let proxied = ImageProxy.url(orig, width: 800) else { continue }
        if let (data, _) = try? await URLSession.shared.data(from: proxied),
           let img = NSImage(data: data),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ImagePipeline.preloaded[orig] = cg
        }
    }
}

@MainActor
func snap<V: View>(_ view: V, name: String, dark: Bool = true, width: CGFloat = 393) {
    let renderer = ImageRenderer(content: view
        .frame(width: width, height: 852)
        .background(Theme.groupedBackground)
        .environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = 2
    renderer.proposedSize = .init(width: width, height: 852)
    guard let cg = renderer.cgImage else { print("RENDER FAIL \(name)"); return }
    guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: "demo/out/\(name).png"))
    print("wrote demo/out/\(name).png")
}

/// Static topic bar + header lookalike for snapshots (interactive state lives in the real app).
struct SnapHeader: View {
    let selected: String
    let mode: String
    var custom: [String] = []
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("NewsFirst").font(Theme.Text.headline)
                Spacer()
                Text("List · Immersive · Full").font(Theme.Text.meta).foregroundStyle(.secondary)
                Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["world", "business", "tech", "ai"] + custom, id: \.self) { t in
                        HStack(spacing: 5) {
                            if custom.contains(t) { Image(systemName: "dot.radiowaves.left.and.right").font(.caption2) }
                            Text(t.capitalized)
                        }
                        .font(Theme.Text.meta)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(t == selected ? Theme.accent : Theme.cardBackground, in: Capsule())
                        .foregroundStyle(t == selected ? .white : .secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.caption2.bold())
                        Text("Custom")
                    }
                    .font(Theme.Text.meta)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.cardBackground, in: Capsule())
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }
}

struct SnapList: View {
    let articles: [Article]
    let title: String
    var custom: [String] = []
    var body: some View {
        VStack(spacing: 0) {
            SnapHeader(selected: title, mode: "List", custom: custom)
            VStack(spacing: 10) {
                ForEach([Article.Tier.high, .medium, .low], id: \.self) { tier in
                    let items = articles.filter { $0.tier == tier }.prefix(2)
                    if !items.isEmpty {
                        PriorityBand(tier: tier)
                        ForEach(Array(items), id: \.id) { a in ListRow(article: a) }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

struct SnapImmersive: View {
    let articles: [Article]
    var body: some View {
        VStack(spacing: 0) {
            SnapHeader(selected: "world", mode: "Immersive")
            VStack(spacing: 14) {
                ForEach(Array(articles.prefix(3).enumerated()), id: \.element.id) { i, a in
                    ImmersiveCard(article: a, hero: i == 0)
                }
            }
            .padding(.horizontal, 14).padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

struct SnapListExpanded: View {
    let articles: [Article]
    var body: some View {
        VStack(spacing: 0) {
            SnapHeader(selected: "world", mode: "List")
            VStack(spacing: 0) {
                if articles.count > 3 {
                    ListRow(article: articles[0])
                    Divider().padding(.leading, 16)
                    ArticleExpandableCell(article: articles[1], expanded: true) {}
                        .environment(FeedStore())
                        .padding(.vertical, 8)
                    ListRow(article: articles[2])
                }
            }
            .background(Theme.rowBackground, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12).padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}


if CommandLine.arguments.contains("--selftest") {
    Task { @MainActor in
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
            if !ok { failures += 1 }
        }
        let api = SupabaseAPI()
        // API 1: feed
        let all = (try? await api.fetchFeed(limit: 250)) ?? []
        check("feed API", !all.isEmpty, "\(all.count) articles")
        // API 2: sources
        let sources = (try? await api.fetchSources()) ?? []
        check("sources API", sources.count > 50, "\(sources.count) sources")
        // API 3: custom search
        let claude = (try? await api.searchArticles(matching: "claude")) ?? []
        check("search API (claude)", !claude.isEmpty, "\(claude.count) matches")
        // Topic population via the real store logic
        let store = FeedStore()
        await store.refresh()
        print("\n— Topic population (store.visible per topic) —")
        for topic in FeedStore.presetTopics {
            store.selectedTopic = topic
            await store.backfillIfSparse()   // same path the app's task runs
            let n = store.visible.count
            let tiers = Dictionary(grouping: store.visible, by: \.tier).mapValues(\.count)
            check("topic \(topic)", n > 0, "\(n) articles (H\(tiers[.high] ?? 0)/M\(tiers[.medium] ?? 0)/L\(tiers[.low] ?? 0))")
        }
        // Source browse via the real store logic
        print("\n— Source population (sources browse mode) —")
        store.browse = .sources
        await store.loadSources()
        var emptySources: [String] = []
        for s in store.sourceBar {
            store.selectedSource = s
            await store.backfillIfSparse()
            if store.visible.isEmpty { emptySources.append(s) }
        }
        check("sources with articles", emptySources.count < store.sourceBar.count / 2,
              "\(store.sourceBar.count - emptySources.count)/\(store.sourceBar.count) populated; empty: \(emptySources.joined(separator: ", "))")
        // Custom topic flow via the store
        store.browse = .topics
        store.addCustomTopic("tether")
        try? await Task.sleep(for: .seconds(3))
        check("custom topic flow (tether)", !(store.customResults["tether"] ?? []).isEmpty,
              "\(store.customResults["tether"]?.count ?? 0) results")
        store.removeCustomTopic("tether")
        // Image proxy reachable
        if let u = ImageProxy.url(all.first(where: { $0.imageURL != nil })?.imageURL, width: 100) {
            let ok = (try? await URLSession.shared.data(from: u)) != nil
            check("image proxy", ok, u.host() ?? "")
        }
        print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")")
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--snapshot") {
    Task { @MainActor in
        do {
            let api = SupabaseAPI()
            let all = try await api.fetchFeed(limit: 200)
            let store = FeedStore()   // reuse diversity/sorting via a scratch store? snapshots filter manually
            _ = store
            let world = all.filter { $0.topics.contains("world") }
            let claude = try await api.searchArticles(matching: "claude")
            print("fetched \(all.count) world=\(world.count) claude=\(claude.count)")
            await preload(Array(world.prefix(10)) + Array(claude.prefix(7)), limit: 17)
            snap(SnapList(articles: world, title: "world"), name: "list_dark")
            snap(SnapList(articles: world, title: "world"), name: "list_light", dark: false)
            snap(SnapImmersive(articles: world), name: "immersive_dark")
            if let top = world.first(where: { $0.imageURL != nil }) {
                snap(FullPage(article: top).environment(FeedStore()), name: "full_dark")
            }
            snap(SnapList(articles: claude, title: "claude", custom: ["claude"]), name: "custom_claude")
            snap(SnapListExpanded(articles: world), name: "list_expanded")
            snap(SnapListExpanded(articles: world), name: "list_expanded_narrow", width: 350)
            snap(SnapImmersive(articles: world), name: "immersive_narrow", width: 350)
            snap(FeedSkeleton(mode: .list), name: "skeleton_list")
            snap(SplashView(), name: "splash")
            snap(SettingsView(snapshotStatic: true).environment(FeedStore()), name: "settings_page")
        } catch {
            print("SNAPSHOT ERROR: \(error)")
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    DemoApp.main()
}
