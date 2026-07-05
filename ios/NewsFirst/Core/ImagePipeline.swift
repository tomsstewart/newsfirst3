import CoreGraphics
import Foundation
import SwiftUI

/// Image loading with an in-memory cache: remounted views (topic swipes, view switches,
/// expansion) render instantly from RAM instead of re-fetching — no flash, ever.
/// `preloaded` remains for headless demo snapshots.
enum ImagePipeline {
    nonisolated(unsafe) static var preloaded: [URL: CGImage] = [:]

    // All mutable state below is guarded by `lock` — loads come from MainActor views
    // AND detached prefetch tasks concurrently.
    private static let lock = NSLock()
    /// Decode failures only. Transport errors (offline blips) must NOT land here —
    /// blacklisting them turned one bad moment into placeholders until relaunch.
    nonisolated(unsafe) private static var failedURLs: Set<URL> = []
    /// One download per URL no matter how many views/prefetchers race for it.
    nonisolated(unsafe) private static var inflight: [URL: Task<CGImage?, Never>] = [:]

    // NSCache is documented thread-safe; Swift 6 cannot see that.
    // Cost-capped: 400 uncosted 800px CGImages ≈ .5GB — jetsam territory.
    nonisolated(unsafe) private static let cache: NSCache<NSURL, CacheBox> = {
        let c = NSCache<NSURL, CacheBox>()
        c.countLimit = 400
        c.totalCostLimit = 120 * 1024 * 1024   // ~120MB of decoded pixels
        return c
    }()

    final class CacheBox { let image: CGImage; init(_ i: CGImage) { self.image = i } }

    static func cached(_ url: URL) -> CGImage? { cache.object(forKey: url as NSURL)?.image }

    /// Synchronous critical section — never suspends while holding the lock.
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    static func isKnownDead(_ url: URL) -> Bool {
        withLock { failedURLs.contains(url) }
    }

    static func load(_ url: URL) async -> CGImage? {
        if let hit = cached(url) { return hit }
        let task = withLock {
            if let existing = inflight[url] { return existing }
            let t = Task { await fetch(url) }
            inflight[url] = t
            return t
        }
        let result = await task.value
        withLock { inflight[url] = nil }
        return result
    }

    private static func fetch(_ url: URL) async -> CGImage? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10   // a hung proxy request must become a placeholder, not an eternal shimmer
        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            return nil   // transport failure: transient, retry freely later
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil   // upstream/proxy error (4xx/5xx): also transient, never blacklist
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            withLock { _ = failedURLs.insert(url) }   // 200 but undecodable: truly dead
            return nil
        }
        cache.setObject(CacheBox(img), forKey: url as NSURL, cost: img.bytesPerRow * img.height)
        return img
    }
}

/// Drop-in replacement for AsyncImage backed by ImagePipeline's cache.
struct CachedImage: View {
    let url: URL
    let topicFallback: String
    @State private var image: CGImage?
    @State private var failed = false

    init(url: URL, topicFallback: String) {
        self.url = url
        self.topicFallback = topicFallback
        _image = State(initialValue: ImagePipeline.cached(url))   // sync hit → part of the pane from frame 1
        _failed = State(initialValue: ImagePipeline.isKnownDead(url))   // known-dead → placeholder on frame 1, no flicker
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else if failed {
                TopicPlaceholder(topic: topicFallback)
            } else {
                Rectangle().fill(.white.opacity(0.05)).shimmer()
            }
        }
        .task(id: url) {
            // Runs on EVERY appearance — a transient `failed` must not stick for the
            // session (LazyVStack keeps cell state; one blip froze the placeholder
            // while the same image loaded fine in Full Coverage's fresh view).
            if image != nil { return }
            if ImagePipeline.isKnownDead(url) { failed = true; return }
            if let hit = ImagePipeline.cached(url) { image = hit; failed = false; return }   // sync-fast path: no flash
            for attempt in 1...3 {
                if let loaded = await ImagePipeline.load(url) {
                    image = loaded      // no animation: the picture is part of the panel, not an event
                    failed = false
                    return
                }
                if ImagePipeline.isKnownDead(url) { break }
                try? await Task.sleep(for: .seconds(Double(attempt) * 1.5))   // cancelled on disappear
            }
            failed = true   // placeholder for now; next appearance retries
        }
    }
}
