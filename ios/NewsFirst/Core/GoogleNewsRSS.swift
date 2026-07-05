import CryptoKit
import Foundation

/// EXPERIMENT (Settings → Experimental): custom topic columns fetched straight from
/// Google News RSS search instead of NewsFirst's own FTS index. Client-side only,
/// no server involvement — evaluating breadth/recency vs our 121-source corpus.
/// Not a permanent path: no scoring/clustering, and Google links route through
/// news.google.com redirects (see enrich(_:) for how images + real URLs are recovered).
enum GoogleNewsRSS {
    static func fetch(topic: String) async throws -> [Article] {
        let q = topic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? topic
        guard let url = URL(string: "https://news.google.com/rss/search?q=\(q)&hl=en-GB&gl=GB&ceid=GB:en") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        return parse(xml)
    }

    private static func parse(_ xml: String) -> [Article] {
        let blocks = matches("<item>([\\s\\S]*?)</item>", in: xml)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        var out: [Article] = []
        var seen = Set<UUID>()
        for block in blocks.prefix(60) {
            guard let rawTitle = first("<title>([\\s\\S]*?)</title>", in: block),
                  let link = first("<link>([\\s\\S]*?)</link>", in: block),
                  let url = URL(string: decode(link)) else { continue }
            let source = first("<source[^>]*>([\\s\\S]*?)</source>", in: block).map(decode) ?? "Google News"
            var title = decode(rawTitle)
            // Google News suffixes " - Source"; the row already shows the source.
            if title.hasSuffix(" - \(source)") { title = String(title.dropLast(source.count + 3)) }
            let published = first("<pubDate>([\\s\\S]*?)</pubDate>", in: block).flatMap { df.date(from: $0) } ?? .now
            let id = stableID(url.absoluteString)
            guard seen.insert(id).inserted else { continue }   // Google repeats items across sections
            out.append(Article(
                id: id, url: url, title: title, excerpt: nil, imageURL: nil,
                publishedAt: published, topics: [], regions: nil, sourceName: source,
                score: 0, tier: .low, clusterID: nil, clusterSources: nil))
        }
        return out.sorted { $0.publishedAt > $1.publishedAt }
    }

    /// Content-derived id: the same story keeps the same identity across re-fetches,
    /// so a refresh doesn't re-identify every row (blink) and enriched rows survive.
    private static func stableID(_ s: String) -> UUID {
        let d = Array(SHA256.hash(data: Data(s.utf8)).prefix(16))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    /// On-demand escape hatch for rows that haven't been image-enriched yet: the
    /// reader and Listen must never land on news.google.com (it's a consent wall in
    /// any embedded browser). Non-google URLs pass straight through.
    static func realURL(for url: URL) async -> URL {
        guard url.host()?.contains("news.google.com") == true else { return url }
        return await resolveRealURL(url) ?? url
    }

    // MARK: - Enrichment (publisher URL + image)

    /// Google stopped encoding the target URL in the article id (opaque AU_yqL…
    /// payloads), so the working path is the one Google's own splash page uses:
    /// fetch the article page for its data-n-a-ts/-sg signature attributes, exchange
    /// them at batchexecute for the publisher URL, then read og:image off the
    /// publisher page. Two round-trips — callers cap how many rows they enrich.
    static func enrich(_ a: Article) async -> Article? {
        guard a.url.host()?.contains("news.google.com") == true,
              let real = await resolveRealURL(a.url) else { return nil }
        let meta = await ogMeta(at: real)
        return Article(id: a.id, url: real, title: a.title, excerpt: meta.description ?? a.excerpt,
                       imageURL: meta.image, publishedAt: a.publishedAt, topics: a.topics,
                       regions: a.regions, sourceName: a.sourceName, score: a.score,
                       tier: a.tier, clusterID: a.clusterID, clusterSources: a.clusterSources)
    }

    /// CFNetwork's default UA gets 302'd to the GDPR consent wall (URLSession follows
    /// it silently and the signature attrs never appear); Safari's UA + the SOCS
    /// cookie are served the article page directly.
    private static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static func googleRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        return req
    }

    private static func resolveRealURL(_ googleURL: URL) async -> URL? {
        guard let id = googleURL.pathComponents.last, id.count > 20 else { return nil }
        let req = googleRequest(googleURL)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8),
              let ts = first("data-n-a-ts=\"([0-9]+)\"", in: html),
              let sg = first("data-n-a-sg=\"([^\"]+)\"", in: html) else { return nil }
        let inner = "[\"garturlreq\",[[\"X\",\"X\",[\"X\",\"X\"],null,null,1,1,\"GB:en\",null,1,null,null,null,null,null,0,1],\"X\",\"X\",1,[1,1,1],1,1,null,0,0,null,0],\"\(id)\",\(ts),\"\(sg)\"]"
        guard let freq = try? JSONSerialization.data(withJSONObject: [[["Fbv4je", inner, NSNull(), "generic"]]]),
              let freqJSON = String(data: freq, encoding: .utf8),
              let encoded = freqJSON.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        var post = googleRequest(URL(string: "https://news.google.com/_/DotsSplashUi/data/batchexecute")!)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        post.httpBody = Data("f.req=\(encoded)".utf8)
        guard let (rdata, rresp) = try? await URLSession.shared.data(for: post),
              (rresp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: rdata, encoding: .utf8) else { return nil }
        return matches("(https:[^\"\\\\]+)", in: text)
            .first { !$0.contains("google.com") && !$0.contains("gstatic.com") }
            .flatMap { URL(string: $0) }
    }

    /// One head-fetch, two payloads: og:image fills the tile picture, og:description
    /// fills the preview line (Google's RSS carries no excerpt at all).
    private static func ogMeta(at url: URL) async -> (image: URL?, description: String?) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        guard let (bytes, resp) = try? await URLSession.shared.bytes(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return (nil, nil) }
        var data = Data()
        data.reserveCapacity(131_072)
        do {
            for try await b in bytes {
                data.append(b)
                if data.count >= 131_072 { break }   // og: tags live in <head>
            }
        } catch {}   // a partial read still parses
        // The cut can land mid-multibyte-char (UTF-8 then fails); Latin-1 never does,
        // and og:image URLs are ASCII either way.
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return (nil, nil) }
        let image = metaContent("og:image", in: html).flatMap { URL(string: decode($0)) }
        let desc = (metaContent("og:description", in: html) ?? metaContent("description", in: html))
            .map { decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.count >= 20 ? $0 : nil }   // "Read more" stubs aren't a preview
        return (image, desc)
    }

    private static func metaContent(_ prop: String, in html: String) -> String? {
        first("<meta[^>]+(?:property|name)=[\"']\(prop)[\"'][^>]*content=[\"']([^\"']+)", in: html)
            ?? first("<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\(prop)[\"']", in: html)
    }

    private static func first(_ pattern: String, in s: String) -> String? {
        matches(pattern, in: s).first
    }
    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: range).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }
    private static func decode(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<!\\[CDATA\\[|\\]\\]>", with: "", options: .regularExpression)
         .replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&nbsp;", with: " ")
        // Numeric entities in every publisher variant: &#39; &#039; &#x27; …
        // (runs after &amp; so double-encoded &amp;#039; resolves too).
        while let r = t.range(of: "&#[xX]?[0-9a-fA-F]{1,6};", options: .regularExpression) {
            let entity = t[r]
            let hex = entity.hasPrefix("&#x") || entity.hasPrefix("&#X")
            let digits = entity.dropFirst(hex ? 3 : 2).dropLast()
            if let v = UInt32(digits, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) {
                t.replaceSubrange(r, with: String(Character(u)))
            } else {
                t.replaceSubrange(r, with: " ")
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
