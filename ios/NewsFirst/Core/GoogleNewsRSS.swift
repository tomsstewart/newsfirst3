import Foundation

/// EXPERIMENT (Settings → Experimental): custom topic columns fetched straight from
/// Google News RSS search instead of NewsFirst's own FTS index. Client-side only,
/// no server involvement — evaluating breadth/recency vs our 121-source corpus.
/// Not a permanent path: no images, no scoring/clustering, and Google links route
/// through news.google.com redirects.
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
        for block in blocks.prefix(60) {
            guard let rawTitle = first("<title>([\\s\\S]*?)</title>", in: block),
                  let link = first("<link>([\\s\\S]*?)</link>", in: block),
                  let url = URL(string: decode(link)) else { continue }
            let source = first("<source[^>]*>([\\s\\S]*?)</source>", in: block).map(decode) ?? "Google News"
            var title = decode(rawTitle)
            // Google News suffixes " - Source"; the row already shows the source.
            if title.hasSuffix(" - \(source)") { title = String(title.dropLast(source.count + 3)) }
            let published = first("<pubDate>([\\s\\S]*?)</pubDate>", in: block).flatMap { df.date(from: $0) } ?? .now
            out.append(Article(
                id: UUID(), url: url, title: title, excerpt: nil, imageURL: nil,
                publishedAt: published, topics: [], regions: nil, sourceName: source,
                score: 0, tier: .low, clusterID: nil, clusterSources: nil))
        }
        return out.sorted { $0.publishedAt > $1.publishedAt }
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
        s.replacingOccurrences(of: "<!\\[CDATA\\[|\\]\\]>", with: "", options: .regularExpression)
         .replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&#39;|&apos;", with: "'", options: .regularExpression)
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&nbsp;", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
