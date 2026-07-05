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
    // Google News rows may still carry the news.google.com redirect (only the first
    // screenfuls get pre-enriched) — resolve to the publisher before opening Safari,
    // or the user lands on Google's consent wall instead of the story.
    @State private var resolved: URL?

    var body: some View {
        #if os(iOS)
        // Floating Listen: SFSafariViewController is sealed (no injection, no DOM
        // access), so the button lives in our layer and the text comes from fetching
        // the page ourselves.
        ZStack(alignment: .bottomTrailing) {
            if let url = resolved {
                if article.isExternal {
                    // External pages arrive cold (consent walls, sign-in overlays).
                    // SFSafariViewController is sealed, so external rows get our own
                    // WKWebView instead: banner-hiding rules + an auto-reject script
                    // actively decline the common consent frameworks.
                    ExternalReader(url: url, title: article.sourceName)
                } else {
                    SafariView(url: url, readerMode: store.readerMode)
                        .ignoresSafeArea()
                }
                ReaderListenButton(article: article)
                    .padding(.trailing, 16)
                    .padding(.bottom, 60)   // above Safari's own toolbar
            } else {
                ZStack { Theme.canvas.ignoresSafeArea(); ProgressView() }
            }
        }
        .task { resolved = await GoogleNewsRSS.realURL(for: article.url) }
        .onDisappear { Speech.shared.stop() }
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

/// "Read this article to me": extracts the page's readable paragraphs and pipes them
/// through the studio voice. Falls back to title + excerpt when a page won't yield text.
struct ReaderListenButton: View {
    let article: Article
    @State private var speech = Speech.shared
    @State private var preparing = false

    var body: some View {
        Button {
            if speech.isSpeaking { speech.stop(); return }
            guard !preparing else { return }
            preparing = true
            Task {
                await Speech.shared.listenToArticle(article)
                preparing = false
            }
        } label: {
            HStack(spacing: 6) {
                if preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                        .font(.footnote.bold())
                }
                Text(preparing ? "Preparing…" : (speech.isSpeaking ? "Stop" : "Listen"))
                    .font(Theme.Text.rowTitle)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassChip(prominent: speech.isSpeaking)
            .foregroundStyle(speech.isSpeaking ? .white : Theme.accent)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(PressableStyle())
    }
}

#if os(iOS)
/// Our own browser chrome for pages outside the corpus: WKWebView is scriptable,
/// so consent banners get hidden AND actively declined (CookieBanners).
struct ExternalReader: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Theme.Text.rowTitle).lineLimit(1)
                Spacer()
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Image(systemName: "safari").font(.footnote.bold()).foregroundStyle(.primary)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.footnote.bold()).foregroundStyle(.primary)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.canvas)
            ExternalWebView(url: url)
        }
    }
}

struct ExternalWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // a declined banner stays declined
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.allowsBackForwardNavigationGestures = true
        CookieBanners.apply(to: v)
        v.load(URLRequest(url: url))
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

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
        // Actively DECLINE the frameworks we recognise (hiding alone leaves some
        // sites gated): known reject-button ids first, then a conservative text
        // match. Retries briefly — banners mount late. Runs in iframes too
        // (SourcePoint/guce render there).
        let autoReject = WKUserScript(source: """
        (function () {
          const KNOWN = ['#onetrust-reject-all-handler', '.didomi-continue-without-agreeing',
            '.qc-cmp2-summary-buttons button[mode=secondary]', 'button.sp_choice_type_13',
            'button[name=reject]', 'button[value=reject]', '.fc-cta-do-not-consent',
            '#CybotCookiebotDialogBodyButtonDecline', '.osano-cm-denyAll', '#truste-consent-required'];
          const PHRASES = /^(reject all|decline all|refuse all|do not consent|continue without (accepting|agreeing)|only necessary|essential only|necessary only)$/i;
          function attempt() {
            for (const sel of KNOWN) {
              const b = document.querySelector(sel);
              if (b) { b.click(); return true; }
            }
            for (const b of document.querySelectorAll('button, [role=button]')) {
              const t = (b.innerText || '').trim();
              if (t.length < 40 && PHRASES.test(t)) { b.click(); return true; }
            }
            return false;
          }
          let tries = 0;
          const timer = setInterval(() => { if (attempt() || ++tries > 8) clearInterval(timer); }, 700);
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(autoReject)
    }
}
