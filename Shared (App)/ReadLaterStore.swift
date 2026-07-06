import Foundation
import WidgetKit
import UserNotifications

// Offline-reading availability for an item's article body. Rides the existing
// /sync list (tiny), so every device learns availability. The body itself is
// NOT synced through the list — it's E2E-encrypted and stored separately via
// the Worker's /body endpoints (or cached locally on the capturing device).
enum OfflineStatus: String, Codable {
    case none         // no offline copy, none requested
    case requested    // capture in flight
    case saved        // body available (uploaded / cached)
    case unavailable  // capture failed (e.g. paywalled stub) — don't retry silently
}

struct ReadLaterItem: Codable {
    var url: String
    var title: String
    var savedAt: Double
    var read: Bool
    var updatedAt: Double
    var deleted: Bool
    var notes: String?
    var offline: OfflineStatus

    enum CodingKeys: String, CodingKey {
        case url, title, savedAt, read, updatedAt, deleted, notes, offline
    }

    init(url: String, title: String, savedAt: Double? = nil, read: Bool = false) {
        let now = Date().timeIntervalSince1970 * 1000
        self.url = url
        self.title = title
        self.savedAt = savedAt ?? now
        self.read = read
        self.updatedAt = savedAt ?? now
        self.deleted = false
        self.notes = nil
        self.offline = .none
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
        self.notes = dict["notes"] as? String
        self.offline = (dict["offline"] as? String).flatMap(OfflineStatus.init(rawValue:)) ?? .none
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        savedAt = try c.decode(Double.self, forKey: .savedAt)
        read = try c.decode(Bool.self, forKey: .read)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        // Decode defensively: tolerate a missing field (older data) and an
        // unknown future status string without throwing.
        offline = (try c.decodeIfPresent(String.self, forKey: .offline))
            .flatMap(OfflineStatus.init(rawValue:)) ?? .none
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = ["url": url, "title": title, "savedAt": savedAt, "read": read, "updatedAt": updatedAt, "deleted": deleted]
        if let notes { dict["notes"] = notes }
        // Omit when .none so existing items serialize byte-identically (no
        // spurious churn on the Worker's change comparison), matching notes.
        if offline != .none { dict["offline"] = offline.rawValue }
        return dict
    }
}

extension ReadLaterItem: Identifiable {
    var id: String { url }
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
        // The macOS Safari extension target's deployment target predates WidgetKit.
        if #available(iOS 14.0, macOS 11.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        reconcileStaleReminders(items)
    }

    // How long an unread item sits before we nudge about it.
    private static let staleThresholdMillis: Double = 14 * 24 * 60 * 60 * 1000

    // Keeps scheduled local notifications in sync with the current item list:
    // cancels reminders for items that are now read/deleted, and schedules
    // one for any unread item that doesn't have a pending reminder yet. Runs
    // after every save() so it applies uniformly across add/delete/markRead/
    // toggleRead/merge, including changes pulled in from other devices.
    //
    // Permission is requested here, lazily, rather than at app launch — the
    // first time there's actually something to remind about (i.e. the first
    // save), not before the user has done anything.
    private func reconcileStaleReminders(_ items: [ReadLaterItem]) {
        let center = UNUserNotificationCenter.current()
        let activeUnread = items.filter { !$0.deleted && !$0.read }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.scheduleReminders(activeUnread, center: center)
            case .notDetermined where !activeUnread.isEmpty:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    self.scheduleReminders(activeUnread, center: center)
                }
            default:
                break // denied, restricted, or nothing to remind about yet
            }
        }
    }

    private func scheduleReminders(_ activeUnread: [ReadLaterItem], center: UNUserNotificationCenter) {
        let activeIDs = Set(activeUnread.map { "stale-" + $0.url })

        center.getPendingNotificationRequests { pending in
            let pendingStaleIDs = Set(pending.map { $0.identifier }.filter { $0.hasPrefix("stale-") })
            let toCancel = pendingStaleIDs.subtracting(activeIDs)
            if !toCancel.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: Array(toCancel))
            }

            for item in activeUnread {
                let id = "stale-" + item.url
                guard !pendingStaleIDs.contains(id) else { continue }
                let fireDate = Date(timeIntervalSince1970: item.savedAt / 1000 + Self.staleThresholdMillis / 1000)
                let interval = fireDate.timeIntervalSinceNow
                // Skip items already past the threshold (e.g. existing items
                // when this feature first ships) rather than firing immediately.
                guard interval > 60 else { continue }

                let content = UNMutableNotificationContent()
                content.title = "Still want to read this?"
                content.body = item.title
                content.sound = .default
                content.userInfo = ["url": item.url]

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
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

    // Idempotent mark-as-read, used when opening an item from outside the
    // list UI (e.g. tapping the widget), where toggleRead's flip-flop
    // behavior would be wrong if the item were already read.
    func markRead(url: String) {
        var items = load()
        if let i = items.firstIndex(where: { $0.url == url }), !items[i].read {
            items[i].read = true
            items[i].updatedAt = Date().timeIntervalSince1970 * 1000
            save(items)
        }
    }

    func setNotes(url: String, notes: String) {
        var items = load()
        guard let i = items.firstIndex(where: { $0.url == url }) else { return }
        items[i].notes = notes.isEmpty ? nil : notes
        items[i].updatedAt = Date().timeIntervalSince1970 * 1000
        save(items)
    }

    func toggleRead(url: String) {
        var items = load()
        if let i = items.firstIndex(where: { $0.url == url }) {
            items[i].read = !items[i].read
            items[i].updatedAt = Date().timeIntervalSince1970 * 1000
        }
        save(items)
    }

    // Sets an item's offline-availability status (set by a capturing client,
    // e.g. the Safari extension after it uploads an encrypted body). Bumps
    // updatedAt so the change wins the merge and propagates to other devices.
    func setOffline(url: String, status: String) {
        var items = load()
        guard let i = items.firstIndex(where: { $0.url == url }) else { return }
        items[i].offline = OfflineStatus(rawValue: status) ?? .none
        items[i].updatedAt = Date().timeIntervalSince1970 * 1000
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
