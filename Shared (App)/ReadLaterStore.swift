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
    // Assigned server-side by the sync Worker (title/URL only — it never sees
    // article bodies, which stay E2E-encrypted). nil means "not yet
    // classified" (rides the same Worker guardrail as the browser
    // extensions: it only ever fills this, never overwrites an existing
    // value), not a real "Unsorted" folder.
    var folder: String?

    enum CodingKeys: String, CodingKey {
        case url, title, savedAt, read, updatedAt, deleted, notes, offline, folder
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
        self.folder = nil
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
        self.folder = dict["folder"] as? String
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
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = ["url": url, "title": title, "savedAt": savedAt, "read": read, "updatedAt": updatedAt, "deleted": deleted]
        if let notes { dict["notes"] = notes }
        // Omit when .none/nil so existing items serialize byte-identically
        // (no spurious churn on the Worker's change comparison).
        if offline != .none { dict["offline"] = offline.rawValue }
        if let folder { dict["folder"] = folder }
        return dict
    }
}

extension ReadLaterItem: Identifiable {
    var id: String { url }
}

private nonisolated struct SyncPayload: Codable {
    var items: [ReadLaterItem]
}

extension Notification.Name {
    // Posted at the end of ReadLaterStore.save(_:) — the single write path
    // for every local mutation (user actions, cloud sync, fast-poll). Views
    // observe this instead of only refreshing on their own explicit calls,
    // so a background fast-poll result shows up without user action.
    static let readLaterDidChange = Notification.Name("ReadLaterStore.didChange")
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
        // save() can be called from a background thread (URLSession
        // completions), but SwiftUI observers of this notification mutate
        // @State — that must happen on main.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .readLaterDidChange, object: nil)
        }
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

            let hasFreshUnsorted = payload.items.contains { item in
                !item.deleted && item.folder == nil
                    && Date().timeIntervalSince1970 * 1000 - item.savedAt < 60_000
            }
            if hasFreshUnsorted { self.fastPollForClassify() }
        }.resume()
    }

    // Whole-item last-writer-wins, EXCEPT folder: if the winning revision
    // doesn't carry one, keep whatever the losing revision had. Mirrors the
    // Worker's own merge() — without this, a stale local copy re-uploaded
    // here could clobber a folder the Worker already assigned server-side.
    static func merge(_ a: [ReadLaterItem], _ b: [ReadLaterItem]) -> [ReadLaterItem] {
        var map: [String: ReadLaterItem] = [:]
        for item in a { map[item.url] = item }
        for item in b {
            if let existing = map[item.url] {
                let existingTime = max(existing.updatedAt, existing.savedAt)
                let itemTime = max(item.updatedAt, item.savedAt)
                if itemTime > existingTime {
                    var winner = item
                    if winner.folder == nil, let existingFolder = existing.folder {
                        winner.folder = existingFolder
                    }
                    map[item.url] = winner
                } else {
                    map[item.url] = existing
                }
            } else {
                map[item.url] = item
            }
        }
        return map.values.sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: - Fast-poll for classification

    private static let itemsURL = URL(string: "https://readlater-sync.shearm.workers.dev/items")!
    private var fastPolling = false

    // Plain GET /items — no classify call, so this can't reintroduce the
    // /sync latency issue the Worker already had to fix. Used only to check
    // whether a background classification result has landed yet.
    private func fetchItemsOnly(completion: @escaping ([ReadLaterItem]) -> Void) {
        var request = URLRequest(url: Self.itemsURL, timeoutInterval: 10)
        request.setValue("Bearer \(syncToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let items: [ReadLaterItem]
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let payload = try? JSONDecoder().decode(SyncPayload.self, from: data) {
                items = payload.items
            } else {
                items = []
            }
            // URLSession completions don't run on main — everything downstream
            // here (fastPolling, save(), recursion) needs to be consistently
            // on one thread, so hop back before calling out.
            DispatchQueue.main.async { completion(items) }
        }.resume()
    }

    // After a sync leaves something freshly unsorted, poll a few times over
    // ~12s instead of waiting for the next explicit sync (pull-to-refresh,
    // toggling an item, etc.) — classification typically lands within a few
    // seconds server-side, so this closes the gap between "the server is
    // done" and "the app finds out." Stops early once something changes,
    // nothing's pending anymore, or the network's unreachable.
    func fastPollForClassify(attemptsRemaining: Int = 5) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.fastPolling else { return }
            self.fastPolling = true
            self.pollNext(attemptsRemaining: attemptsRemaining)
        }
    }

    private func pollNext(attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else { fastPolling = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.fetchItemsOnly { fetched in
                guard !fetched.isEmpty else { self.fastPolling = false; return }

                let current = self.load()
                let oldFolders = Dictionary(uniqueKeysWithValues: current.map { ($0.url, $0.folder) })
                let gained = fetched.contains { item in
                    guard let folder = item.folder, !folder.isEmpty else { return false }
                    guard let old = oldFolders[item.url] else { return false }
                    return old == nil
                }
                if gained {
                    self.save(fetched)
                    self.fastPolling = false
                    return
                }

                let stillPending = fetched.contains { item in
                    !item.deleted && item.folder == nil
                        && Date().timeIntervalSince1970 * 1000 - item.savedAt < 60_000
                }
                guard stillPending else { self.fastPolling = false; return }
                self.pollNext(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }
}
