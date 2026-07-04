import CoreGraphics
import Foundation

/// Pre-decoded images for headless rendering (demo snapshots); empty in the live app,
/// where AsyncImage handles loading. Phase 3 replaces this with a real cache + proxy URLs.
enum ImagePipeline {
    nonisolated(unsafe) static var preloaded: [URL: CGImage] = [:]
}
