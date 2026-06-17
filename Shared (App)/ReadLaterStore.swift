import Foundation

struct ReadLaterItem: Codable {
    var url: String
    var title: String
    var savedAt: Double
    var read: Bool
    var updatedAt: Double
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case url, title, savedAt, read, updatedAt, deleted
    }

    init(url: String, title: String, savedAt: Double? = nil, read: Bool = false) {
        let now = Date().timeIntervalSince1970 * 1000
        self.url = url
        self.title = title
        self.savedAt = savedAt ?? now
        self.read = read
        self.updatedAt = savedAt ?? now
        self.deleted = false
    }

    init?(jsonDict dict: [String: Any]) {
        guard let url = dict["url"] as? String,
              let title = dict["title"] as? String else { return nil }
        self.url = url
        self.title = title
        self.savedAt = dict["savedAt"] as? Double ?? Date().timeIntervalSince1970 * 1000
        self.read = dict["read"] as? Bool ?? false
        self.updatedAt = dict["updatedAt"] as? Double ?? self.savedAt
        self.deleted = dict["deleted"] as? Bool ?? false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        savedAt = try c.decode(Double.self, forKey: .savedAt)
        read = try c.decode(Bool.self, forKey: .read)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    func toDict() -> [String: Any] {
        ["url": url, "title": title, "savedAt": savedAt, "read": read, "updatedAt": updatedAt, "deleted": deleted]
    }
}

private nonisolated struct SyncPayload: Codable {
    var items: [ReadLaterItem]
}

class ReadLaterStore {
    static let shared = ReadLaterStore()

    private let appGroupSuite = "group.com.mdshear.ReadLater"
    private let storeKey = "readLater"

    private let syncURL = URL(string: "https://readlater-sync.shearm.workers.dev/sync")!
    private let tokenKey = "syncToken"

    /// Per-user sync key. Stored in the shared App Group so the app, the share
    /// extension, and the Safari handler all use the same key. A fresh key is
    /// generated on first access; paste an existing key (in Settings) to link
    /// this device to your other devices.
    var syncToken: String {
        get {
            let defaults = UserDefaults(suiteName: appGroupSuite)
            if let existing = defaults?.string(forKey: tokenKey), existing.count >= 32 {
                return existing
            }
            let generated = ReadLaterStore.generateToken()
            defaults?.set(generated, forKey: tokenKey)
            return generated
        }
        set {
            UserDefaults(suiteName: appGroupSuite)?.set(newValue, forKey: tokenKey)
        }
    }

    static func generateToken() -> String {
        (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    func load() -> [ReadLaterItem] {
        guard let data = UserDefaults(suiteName: appGroupSuite)?.data(forKey: storeKey),
              let items = try? JSONDecoder().decode([ReadLaterItem].self, from: data) else {
            return []
        }
        return items
    }

    func save(_ items: [ReadLaterItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults(suiteName: appGroupSuite)?.set(data, forKey: storeKey)
    }

    func add(url: String, title: String) {
        var items = load()
        if let i = items.firstIndex(where: { $0.url == url }) {
            guard items[i].deleted else { return }
            let now = Date().timeIntervalSince1970 * 1000
            items[i].deleted = false
            items[i].read = false
            items[i].title = title
            items[i].savedAt = now
            items[i].updatedAt = now
            save(items)
            return
        }
        items.insert(ReadLaterItem(url: url, title: title), at: 0)
        save(items)
    }

    func delete(url: String) {
        var items = load()
        if let i = items.firstIndex(where: { $0.url == url }) {
            items[i].deleted = true
            items[i].updatedAt = Date().timeIntervalSince1970 * 1000
        }
        save(items)
    }

    // Items not marked as deleted, for display.
    func visible() -> [ReadLaterItem] {
        load().filter { !$0.deleted }
    }

    func toggleRead(url: String) {
        var items = load()
        if let i = items.firstIndex(where: { $0.url == url }) {
            items[i].read = !items[i].read
            items[i].updatedAt = Date().timeIntervalSince1970 * 1000
        }
        save(items)
    }

    // Called by HTTP sync endpoint: merges incoming items and returns result
    func merge(with incoming: [ReadLaterItem]) -> [ReadLaterItem] {
        let merged = ReadLaterStore.merge(load(), incoming)
        save(merged)
        return merged
    }

    func toJSONArray() -> [[String: Any]] {
        visible().map { $0.toDict() }
    }

    func toJSON() -> Any {
        toJSONArray()
    }

    // Pushes local items to the cloud sync endpoint and merges the result back locally.
    func syncWithCloud(completion: @escaping ([ReadLaterItem]) -> Void = { _ in }) {
        guard let body = try? JSONEncoder().encode(SyncPayload(items: load())) else {
            completion(load())
            return
        }

        var request = URLRequest(url: syncURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(syncToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self,
                  let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
                completion(self?.load() ?? [])
                return
            }
            self.save(payload.items)
            completion(payload.items)
        }.resume()
    }

    static func merge(_ a: [ReadLaterItem], _ b: [ReadLaterItem]) -> [ReadLaterItem] {
        var map: [String: ReadLaterItem] = [:]
        for item in a { map[item.url] = item }
        for item in b {
            if let existing = map[item.url] {
                let existingTime = max(existing.updatedAt, existing.savedAt)
                let itemTime = max(item.updatedAt, item.savedAt)
                map[item.url] = itemTime > existingTime ? item : existing
            } else {
                map[item.url] = item
            }
        }
        return map.values.sorted { $0.savedAt > $1.savedAt }
    }
}
