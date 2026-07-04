import CoreGraphics
import Foundation
import SwiftUI

/// Image loading with an in-memory cache: remounted views (topic swipes, view switches,
/// expansion) render instantly from RAM instead of re-fetching — no flash, ever.
/// `preloaded` remains for headless demo snapshots.
enum ImagePipeline {
    nonisolated(unsafe) static var preloaded: [URL: CGImage] = [:]
    nonisolated(unsafe) static var failedURLs: Set<URL> = []

    // NSCache is documented thread-safe; Swift 6 cannot see that.
    nonisolated(unsafe) private static let cache: NSCache<NSURL, CacheBox> = {
        let c = NSCache<NSURL, CacheBox>()
        c.countLimit = 400
        return c
    }()

    final class CacheBox { let image: CGImage; init(_ i: CGImage) { self.image = i } }

    static func cached(_ url: URL) -> CGImage? { cache.object(forKey: url as NSURL)?.image }

    static func load(_ url: URL) async -> CGImage? {
        if let hit = cached(url) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            failedURLs.insert(url)
            return nil
        }
        cache.setObject(CacheBox(img), forKey: url as NSURL)
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
        _failed = State(initialValue: ImagePipeline.failedURLs.contains(url))   // known-dead → placeholder on frame 1, no flicker
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
            if image != nil || failed { return }
            if let hit = ImagePipeline.cached(url) { image = hit; return }   // sync-fast path: no flash
            if let loaded = await ImagePipeline.load(url) {
                image = loaded          // no animation: the picture is part of the panel, not an event
            } else {
                failed = true
            }
        }
    }
}
