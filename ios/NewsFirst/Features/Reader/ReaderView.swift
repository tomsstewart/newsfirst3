import SwiftUI
import WebKit
#if os(iOS)
import SafariServices
#endif

/// In-app article reader. iOS: SFSafariViewController (Reader Mode capable, share sheet,
/// content blockers — the platform-blessed in-app browser). macOS demo: WKWebView sheet.
struct ReaderSheet: View {
    let article: Article
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        SafariView(url: article.url)
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
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = true       // v2's "Reader View" setting, honored by default
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
        v.load(URLRequest(url: url))
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#endif
