// NewsFirst v3 — macOS demo shell.
// Runs the real SwiftUI feed views against the live v3 backend at iPhone dimensions.
// Modes:  ./NewsFirstDemo             → interactive window (topic chips + List/Immersive toggle)
//         ./NewsFirstDemo --snapshot  → headless PNG renders to demo/out/ for design review
import SwiftUI
import AppKit

// MARK: - Topic bar (topic-based news is the core value prop — chips drive everything)

struct TopicBar: View {
    @Environment(FeedStore.self) private var store
    let topics: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(topics, id: \.self) { topic in
                    let selected = store.selectedTopic == topic
                    Button {
                        withAnimation(Theme.Motion.snappy) { store.selectedTopic = topic }
                    } label: {
                        Text(topic.capitalized)
                            .font(Theme.Text.meta)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(selected ? Theme.accent : Theme.cardBackground, in: Capsule())
                            .foregroundStyle(selected ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct DemoRoot: View {
    @Environment(FeedStore.self) private var store
    @State private var mode = 0
    private let topics = ["world", "business", "economics", "tech", "ai", "science", "sports", "crypto", "gaming", "entertainment"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("NewsFirst")
                        .font(Theme.Text.headline)
                    Spacer()
                    Picker("", selection: $mode.animation(Theme.Motion.snappy)) {
                        Text("List").tag(0)
                        Text("Immersive").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                .padding(.horizontal, 16)
                TopicBar(topics: topics)
            }
            .padding(.top, 14).padding(.bottom, 10)
            .background(Theme.groupedBackground)
            if mode == 0 { FeedListView() } else { ImmersiveView() }
        }
        .frame(width: 393, height: 852)
        .background(Theme.groupedBackground)
        .preferredColorScheme(.dark)
    }
}

struct DemoApp: App {
    @State private var store = FeedStore()
    var body: some Scene {
        WindowGroup {
            DemoRoot()
                .environment(store)
                .task { await store.start() }
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Headless snapshot mode (design self-review without a screen)

@MainActor
func preload(_ articles: [Article], limit: Int) async {
    for a in articles.prefix(limit) {
        guard let url = a.imageURL, ImagePipeline.preloaded[url] == nil else { continue }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let img = NSImage(data: data),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ImagePipeline.preloaded[url] = cg
        }
    }
}

@MainActor
func snap<V: View>(_ view: V, name: String, size: CGSize) {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
    renderer.scale = 2
    renderer.proposedSize = .init(size)
    guard let cg = renderer.cgImage else { print("RENDER FAIL \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let path = "demo/out/\(name).png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

struct SnapshotList: View {
    let articles: [Article]
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("NewsFirst").font(Theme.Text.headline).foregroundStyle(.primary)
                    Spacer()
                    Text("List | Immersive").font(Theme.Text.meta).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(["World", "Business", "Tech", "AI"], id: \.self) { t in
                        Text(t).font(Theme.Text.meta)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(t == "World" ? Theme.accent : Theme.cardBackground, in: Capsule())
                            .foregroundStyle(t == "World" ? .white : .secondary)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            VStack(spacing: 12) {
                ForEach(articles) { ArticleCard(article: $0) }
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .background(Theme.groupedBackground)
    }
}

if CommandLine.arguments.contains("--snapshot") {
    Task { @MainActor in
        do {
            let api = SupabaseAPI()
            let all = try await api.fetchFeed(limit: 120)
            print("fetched \(all.count) articles")
            let world = all.filter { $0.topics.contains("world") }
            let listPick = Array(world.prefix(3))
            let immersivePick = world.first(where: { $0.imageURL != nil }) ?? all[0]
            await preload(listPick + [immersivePick], limit: 6)
            print("preloaded \(ImagePipeline.preloaded.count) images")
            snap(SnapshotList(articles: listPick), name: "list", size: .init(width: 393, height: 852))
            snap(ImmersivePage(article: immersivePick), name: "immersive", size: .init(width: 393, height: 852))
        } catch {
            print("SNAPSHOT ERROR: \(error)")
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    DemoApp.main()
}
