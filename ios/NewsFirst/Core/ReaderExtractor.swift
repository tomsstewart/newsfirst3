import Foundation
import WebKit

/// Article-body extraction downstream of a REAL reader implementation: Mozilla's
/// Readability (the Firefox reader-view algorithm, Apache-2.0, vendored in Resources)
/// evaluated in a hidden WKWebView. Handles JavaScript-rendered pages the raw-HTML
/// harvest can't; the regex harvest in ArticleText remains the fallback.
@MainActor
final class ReaderExtractor: NSObject, WKNavigationDelegate {
    static let shared = ReaderExtractor()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[String], Never>?

    private static let readabilityJS: String? = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    func extract(_ url: URL) async -> [String] {
        guard Self.readabilityJS != nil else { return [] }
        // One extraction at a time; a second caller just gets the fallback path.
        guard continuation == nil else { return [] }
        return await withCheckedContinuation { cont in
            continuation = cont
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
            webView = wv
            wv.load(URLRequest(url: url, timeoutInterval: 10))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                self?.finish([])   // no-op if already finished
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.runReadability(in: webView) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish([]) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish([]) }
    }

    private func runReadability(in webView: WKWebView) {
        guard let js = Self.readabilityJS else { finish([]); return }
        let script = js + """
        ;(function() {
            try {
                var article = new Readability(document.cloneNode(true)).parse();
                return article ? article.textContent : "";
            } catch (e) { return ""; }
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            let text = (result as? String) ?? ""
            let paragraphs = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 60 }
            Task { @MainActor in self?.finish(Array(paragraphs.prefix(40))) }
        }
    }

    private func finish(_ paragraphs: [String]) {
        continuation?.resume(returning: paragraphs)
        continuation = nil
        webView?.stopLoading()
        webView = nil
    }
}
