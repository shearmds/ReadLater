import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {

    private var sharedURL: URL?
    private var pageTitle: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Research Sync"
        extractSharedContent()
    }

    override func isContentValid() -> Bool {
        return sharedURL != nil
    }

    override func didSelectPost() {
        guard let url = sharedURL else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        let title = contentText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? pageTitle?.nilIfEmpty
            ?? url.absoluteString
        ReadLaterStore.shared.add(url: url.absoluteString, title: title)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    override func configurationItems() -> [Any]! {
        return []
    }

    // Some browsers (notably Arc and Quiche on iOS) only put the root URL
    // (e.g. https://nytimes.com) in the URL attachment, but include the full
    // article URL elsewhere in the share payload (plain-text attachment or
    // attributedContentText). We collect every URL from every source and pick
    // the most specific one.
    private func extractSharedContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        
        let group = DispatchGroup()
        let lock = NSLock()
        var collectedURLs: [URL] = []
        var candidateTitle: String?

        func addURL(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            collectedURLs.append(url)
        }
        func addURLs(_ urls: [URL]) {
            lock.lock(); defer { lock.unlock() }
            collectedURLs.append(contentsOf: urls)
        }

        for item in items {
            // Pull text from the item itself (title text from the source app).
            // If it doesn't look like a URL, keep it as a candidate display
            // title. If it does, scan for URLs.
            for text in [item.attributedTitle?.string, item.attributedContentText?.string].compactMap({ $0 }) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let urlsInText = Self.extractURLs(from: trimmed)
                    if !urlsInText.isEmpty {
                        addURLs(urlsInText)
                    } else if candidateTitle == nil {
                        candidateTitle = trimmed
                    }
                }
            }

            for provider in (item.attachments ?? []) {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { data, _ in
                        defer { group.leave() }
                        if let u = data as? URL {
                            addURL(u)
                        } else if let s = data as? String, let u = URL(string: s) {
                            addURL(u)
                        }
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                        defer { group.leave() }
                        if let text = data as? String {
                            addURLs(Self.extractURLs(from: text))
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard let bestURL = Self.pickBestURL(from: collectedURLs) else { return }
            self.sharedURL = bestURL

            if let t = candidateTitle {
                self.pageTitle = t
                self.textView?.text = t
                self.validateContent()
            } else {
                self.validateContent()
                self.fetchTitle(from: bestURL)
            }
        }
    }

    // Pick the URL with the most specific path/query (most "article-like").
    // A URL like https://nytimes.com/2026/06/article-slug wins over https://nytimes.com.
    private static func pickBestURL(from urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        return urls.max { lhs, rhs in
            let l = lhs.path.count + (lhs.query?.count ?? 0)
            let r = rhs.path.count + (rhs.query?.count ?? 0)
            return l < r
        }
    }

    private static func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range)
        return matches.compactMap { $0.url }
    }

    private func fetchTitle(from url: URL) {
        var request = URLRequest(url: url, timeoutInterval: 5)
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let html = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else { return }
            guard let title = Self.extractTitle(from: html) else { return }
            DispatchQueue.main.async {
                self?.pageTitle = title
                if self?.textView?.text?.isEmpty ?? true {
                    self?.textView?.text = title
                }
            }
        }.resume()
    }

    private static func extractTitle(from html: String) -> String? {
        // Prefer og:title (better for news sites with paywalls); fall back to <title>.
        if let og = html.range(of: #"<meta[^>]+property=["']og:title["'][^>]*content=["']([^"']+)["']"#,
                               options: [.regularExpression, .caseInsensitive]) {
            let snippet = String(html[og])
            if let valueRange = snippet.range(of: #"content=["']([^"']+)["']"#,
                                              options: [.regularExpression, .caseInsensitive]) {
                let raw = String(snippet[valueRange])
                    .replacingOccurrences(of: "content=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if let decoded = decodeHTMLEntities(raw).nilIfEmpty {
                    return decoded
                }
            }
        }
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let tagEnd = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let end = html.range(of: "</title>", options: .caseInsensitive,
                                   range: tagEnd.upperBound..<html.endIndex) else { return nil }
        let raw = String(html[tagEnd.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeHTMLEntities(raw).nilIfEmpty
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        guard let data = s.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else {
            return s
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
