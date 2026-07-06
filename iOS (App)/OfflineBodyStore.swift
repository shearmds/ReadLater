import Foundation
import CryptoKit

// The decrypted article payload, matching the JSON envelope the capturing client
// encrypts and uploads (see dia-read-later/offline.js `offlineBuildPayload` and
// ../readlater-sync/CRYPTO.md). Everything article-derived lives inside the
// ciphertext, so the Worker only ever holds an opaque blob.
struct OfflineArticle: Codable {
    var v: Int
    var url: String
    var title: String
    var siteName: String
    var excerpt: String
    var length: Int
    var html: String
    var capturedAt: Double
}

// Reads offline article bodies for the iOS app: fetches the E2E-encrypted blob
// from the Worker, decrypts it with a key derived from the sync token, and
// caches the plaintext in the shared App Group container so it renders with no
// network (airplane mode). The app never *writes* bodies — capture happens on
// the browser/Safari-extension side; this is the consuming end.
final class OfflineBodyStore {
    static let shared = OfflineBodyStore()

    private let appGroupSuite = "group.com.mdshear.ReadLater"
    private let bodyURL = URL(string: "https://readlater-sync.shearm.workers.dev/body")!

    private var token: String { ReadLaterStore.shared.syncToken }

    // MARK: Crypto (HKDF-SHA256 -> AES-256-GCM; see CRYPTO.md)

    private func deriveKey() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: Data("rtl-offline-v1".utf8),
            info: Data("body".utf8),
            outputByteCount: 32
        )
    }

    // `wire` is base64( iv(12) || ciphertext || tag(16) ) — exactly the layout
    // of CryptoKit's SealedBox.combined, so no manual byte splitting is needed.
    private func decrypt(wireBase64: String) throws -> Data {
        guard let combined = Data(base64Encoded: wireBase64) else {
            throw OfflineError.badCiphertext
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: deriveKey())
    }

    // MARK: Local cache (App Group container, plaintext, keyed by sha256(url))

    private func cacheDirectory() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupSuite) else { return nil }
        let dir = container.appendingPathComponent("OfflineBodies", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func cacheFile(for url: String) -> URL? {
        let hash = SHA256.hash(data: Data(url.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDirectory()?.appendingPathComponent("\(hash).json")
    }

    func isCached(_ url: String) -> Bool {
        guard let file = cacheFile(for: url) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    func cachedArticle(_ url: String) -> OfflineArticle? {
        guard let file = cacheFile(for: url),
              let data = try? Data(contentsOf: file),
              let article = try? JSONDecoder().decode(OfflineArticle.self, from: data) else {
            return nil
        }
        return article
    }

    private func writeCache(_ article: OfflineArticle) {
        guard let file = cacheFile(for: article.url),
              let data = try? JSONEncoder().encode(article) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func deleteCached(_ url: String) {
        guard let file = cacheFile(for: url) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Fetch

    // Response shape from GET /body: { ciphertext, meta, updatedAt }.
    private struct BodyResponse: Decodable { let ciphertext: String }

    // Downloads + decrypts + caches the body for `url`. Completion runs on main.
    func fetch(_ url: String, completion: @escaping (Result<OfflineArticle, Error>) -> Void) {
        var comps = URLComponents(url: bodyURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "url", value: url)]
        var request = URLRequest(url: comps.url!, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let finish: (Result<OfflineArticle, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            guard let self else { return }
            if let error { return finish(.failure(error)) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else {
                return finish(.failure(code == 404 ? OfflineError.notOnServer : OfflineError.http(code)))
            }
            do {
                let body = try JSONDecoder().decode(BodyResponse.self, from: data)
                let plain = try self.decrypt(wireBase64: body.ciphertext)
                let article = try JSONDecoder().decode(OfflineArticle.self, from: plain)
                self.writeCache(article)
                finish(.success(article))
            } catch {
                finish(.failure(error))
            }
        }.resume()
    }

    // Cache-first: returns the cached copy immediately if present, otherwise
    // fetches. This is what the reader calls — so it works offline once cached.
    func article(for url: String, completion: @escaping (Result<OfflineArticle, Error>) -> Void) {
        if let cached = cachedArticle(url) {
            completion(.success(cached))
            return
        }
        fetch(url, completion: completion)
    }

    // Pre-download bodies for items marked saved that aren't cached yet, so
    // they're available later with no network. Call after a sync, while online.
    func prefetchMissing(_ items: [ReadLaterItem]) {
        for item in items where item.offline == .saved && !isCached(item.url) {
            fetch(item.url) { _ in }
        }
    }

    enum OfflineError: LocalizedError {
        case badCiphertext, notOnServer, http(Int)
        var errorDescription: String? {
            switch self {
            case .badCiphertext: return "The saved copy couldn’t be read."
            case .notOnServer:   return "No offline copy has been uploaded for this article yet."
            case .http(let c):   return "Couldn’t reach the sync service (HTTP \(c))."
            }
        }
    }
}
