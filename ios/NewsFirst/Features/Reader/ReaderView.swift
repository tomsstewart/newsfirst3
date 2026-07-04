import SwiftUI
import WebKit
#if os(iOS)
import SafariServices
#endif

/// In-app article reader. iOS: SFSafariViewController (Reader Mode capable, share sheet,
/// content blockers — the platform-blessed in-app browser). macOS demo: WKWebView sheet.
struct ReaderSheet: View {
    let article: Article
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        SafariView(url: article.url, readerMode: store.readerMode)
            .ignoresSafeArea()
        #else
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.sourceName).font(Theme.Text.meta).foregroundStyle(.secondary)
                    Text(article.title).font(Theme.Text.rowTitle).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)
            WebView(url: article.url)
        }
        .frame(width: 393, height: 780)
        #endif
    }
}

#if os(iOS)
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var readerMode = true
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = readerMode   // Settings → "Open in Reader"
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(Theme.accent)
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
#else
struct WebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        CookieBanners.apply(to: v)
        v.load(URLRequest(url: url))
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#endif

/// Hides the common consent-banner frameworks in any WKWebView we own.
/// (The iOS SFSafariViewController path prefers Reader Mode, which sidesteps banners.)
enum CookieBanners {
    static let selectors = [
        "#onetrust-consent-sdk", ".onetrust-pc-dark-filter", "#didomi-host", ".didomi-popup-open",
        ".qc-cmp2-container", "[id^='sp_message_container']", ".fc-consent-root",
        "#CybotCookiebotDialog", "#usercentrics-root", ".osano-cm-window", "#cookie-banner",
        ".cookie-banner", "#gdpr-banner", ".gdpr", "#consent_blackbar", ".truste_box_overlay",
        "#truste-consent-track", ".cc-window", "#cmpbox", "#cmpbox2",
    ]
    static func apply(to webView: WKWebView) {
        let rules = """
        [{"trigger": {"url-filter": ".*"},
          "action": {"type": "css-display-none", "selector": "\(selectors.joined(separator: ", "))"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "hide-cookie-banners", encodedContentRuleList: rules
        ) { list, _ in
            if let list { webView.configuration.userContentController.add(list) }
        }
        // Also un-freeze pages that lock scroll behind the banner.
        let unfreeze = WKUserScript(
            source: "const s=document.createElement('style');s.textContent='html,body{overflow:auto !important}';document.head?.appendChild(s);",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(unfreeze)
    }
}
