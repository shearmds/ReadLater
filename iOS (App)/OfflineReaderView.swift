import SwiftUI
import WebKit

// Renders a locally-cached (or freshly-fetched) article body for offline
// reading. The body was sanitized on the capture side (DOMPurify) and is
// re-wrapped here in a minimal reader document; JavaScript is disabled in the
// web view as defense in depth.
// The reader's content — loads the cached body and renders it in a JS-disabled
// web view. Embeddable and chrome-free: used both by the iPhone sheet
// (OfflineReaderView) and the iPad detail pane.
struct OfflineArticleReader: View {
    let item: ReadLaterItem
    @AppStorage("appTheme") private var themeName: String = AppTheme.ocean.rawValue
    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .ocean }

    @State private var state: LoadState = .loading

    enum LoadState {
        case loading
        case ready(OfflineArticle)
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let article):
                ReaderWebView(html: readerDocument(article), baseURL: URL(string: item.url))
                    .ignoresSafeArea(edges: .bottom)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Reload when switched to a different article in the iPad detail pane.
        .id(item.url)
        .onAppear(perform: load)
    }

    private func load() {
        OfflineBodyStore.shared.article(for: item.url) { result in
            switch result {
            case .success(let article): state = .ready(article)
            case .failure(let error):
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func readerDocument(_ article: OfflineArticle) -> String {
        let host = URL(string: item.url)?.host ?? ""
        let site = article.siteName.isEmpty ? host : article.siteName
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>\(readerCSS(theme: theme))</style>
        </head>
        <body>
        <article>
          <header>
            <h1>\(escape(article.title))</h1>
            <div class="site">\(escape(site))</div>
          </header>
          <div class="content">\(article.html)</div>
        </article>
        </body>
        </html>
        """
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // Light-locked and tinted to the selected theme, matching the app family's
    // readers: the article sits on a floating white page over a faint theme
    // wash, with a themed gradient rule under the header and themed links.
    private func readerCSS(theme: AppTheme) -> String {
        """
        :root {
          color-scheme: light;
          --theme-start: \(theme.start.hexString);
          --theme-end: \(theme.end.hexString);
        }
        body {
          margin: 0;
          font: 18px/1.65 -apple-system, system-ui, sans-serif;
          color: #1c1c1e;
          background: color-mix(in srgb, var(--theme-start) 5%, #ffffff);
          -webkit-text-size-adjust: 100%;
        }
        article {
          max-width: 42rem;
          margin: 1.5rem auto 4rem;
          padding: 2rem 1.5rem 4rem;
          background: #fff;
          border-radius: 16px;
          box-shadow: 0 4px 20px rgba(0, 0, 0, 0.06);
        }
        header {
          border-width: 0 0 2px;
          border-style: solid;
          border-image: linear-gradient(90deg, var(--theme-start), var(--theme-end)) 1;
          padding-bottom: 1rem;
          margin-bottom: 1.5rem;
        }
        h1 { font-size: 1.7rem; line-height: 1.2; margin: 0 0 0.4rem; }
        .site { color: #8e8e93; font-size: 0.95rem; }
        .content img, .content figure, .content video { max-width: 100%; height: auto; }
        .content figure { margin: 1.5rem 0; }
        .content figcaption { font-size: 0.85rem; color: #8e8e93; text-align: center; margin-top: 0.4rem; }
        .content a { color: var(--theme-end); }
        .content pre { overflow-x: auto; background: #f2f2f7; padding: 1rem; border-radius: 8px; font-size: 0.85rem; }
        .content blockquote { margin: 1.25rem 0; padding-left: 1rem; border-left: 3px solid var(--theme-end); color: #48484a; }
        @media (max-width: 46rem) {
          article { margin: 0; border-radius: 0; box-shadow: none; padding: 1.5rem 1.25rem 4rem; }
        }
        """
    }
}

// iPhone sheet presentation: the embeddable reader wrapped in a nav bar with a
// Done button and an "open in Safari" link.
struct OfflineReaderView: View {
    let item: ReadLaterItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OfflineArticleReader(item: item)
                .navigationTitle("Reader")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if let url = URL(string: item.url) {
                            Link(destination: url) { Image(systemName: "safari") }
                        }
                    }
                }
        }
    }
}

// Minimal WKWebView wrapper that renders a self-contained HTML string with
// JavaScript disabled. baseURL is the article URL so relative image/link
// references resolve when online (and simply fail harmlessly offline).
private struct ReaderWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}
