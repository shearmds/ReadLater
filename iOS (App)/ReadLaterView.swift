import Combine
import SwiftUI

struct ReadLaterView: View {
    @State private var items: [ReadLaterItem] = []
    @State private var filter: Filter = .unread
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var notesItem: ReadLaterItem?
    @State private var readerItem: ReadLaterItem?
    @AppStorage("appTheme") private var themeName: String = AppTheme.ocean.rawValue
    // Local to this app install — not synced, so the app can show folders
    // independently of the browser extensions (or vice versa).
    @AppStorage("groupByFolder") private var groupByFolder: Bool = false
    @State private var collapsedFolders: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedFolders") ?? [])
    // The most recently classified item, so its folder can show a "new" dot
    // if that section is collapsed. Session-only, cleared on expand or once
    // it times out (see recentlyClassifiedFolder).
    @State private var recentlyClassified: (url: String, folder: String, at: Date)?
    // Bumped by a periodic timer purely to force body re-evaluation, so the
    // "Sorting…" spinner and the "new" dot correctly time out on their own
    // even with no further data change.
    @State private var tick = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .ocean }

    enum Filter: String, CaseIterable {
        case all = "All", unread = "Unread", read = "Read"
    }

    private static let unsortedLabel = "Unsorted"
    private static let pendingWindow: TimeInterval = 3 * 60
    private static let recentDotWindow: TimeInterval = 5 * 60

    private var effectiveGrouped: Bool { groupByFolder && searchText.isEmpty }

    private func isPendingClassification(_ item: ReadLaterItem) -> Bool {
        _ = tick // read to establish a dependency so the timer bump re-evaluates this
        return !item.deleted
            && Date().timeIntervalSince1970 * 1000 - item.savedAt < Self.pendingWindow * 1000
    }

    private func recentlyClassifiedFolder() -> String? {
        _ = tick
        guard let recentlyClassified else { return nil }
        guard Date().timeIntervalSince(recentlyClassified.at) <= Self.recentDotWindow else { return nil }
        return recentlyClassified.folder
    }

    private var groupedSections: [(folder: String, items: [ReadLaterItem])] {
        var groups: [String: [ReadLaterItem]] = [:]
        for item in filtered {
            groups[item.folder ?? Self.unsortedLabel, default: []].append(item)
        }
        let named = groups.keys.filter { $0 != Self.unsortedLabel }.sorted()
        let ordered = groups[Self.unsortedLabel] != nil ? named + [Self.unsortedLabel] : named
        return ordered.map { ($0, groups[$0] ?? []) }
    }

    private func expandedBinding(for folder: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(folder) },
            set: { isExpanded in
                var next = collapsedFolders
                if isExpanded {
                    next.remove(folder)
                    if recentlyClassified?.folder == folder { recentlyClassified = nil }
                } else {
                    next.insert(folder)
                }
                collapsedFolders = next
                UserDefaults.standard.set(Array(next), forKey: "collapsedFolders")
            }
        )
    }

    // Detects a folder-classification transition (existed before with no
    // folder, now has one) before overwriting `items`, so both the fast-poll
    // path and the notification-driven refresh path share one diff.
    private func updateItems(_ newItems: [ReadLaterItem]) {
        let oldFolders = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0.folder) })
        for item in newItems {
            if let folder = item.folder, let old = oldFolders[item.url], old == nil {
                recentlyClassified = (item.url, folder, Date())
            }
        }
        items = newItems
    }

    private var isRegular: Bool { hSizeClass == .regular }
    private var headerHeight: CGFloat { isRegular ? 180 : 130 }
    private var contentMaxWidth: CGFloat { isRegular ? 760 : .infinity }
    private var titleFont: Font { isRegular ? .system(size: 28, weight: .bold) : .title2.bold() }

    var filtered: [ReadLaterItem] {
        items.filter { item in
            switch filter {
            case .all:    return true
            case .unread: return !item.read
            case .read:   return item.read
            }
        }.filter { item in
            guard !searchText.isEmpty else { return true }
            let q = searchText.lowercased()
            return item.title.lowercased().contains(q) || item.url.lowercased().contains(q)
        }
    }

    var unreadCount: Int { items.filter { !$0.read }.count }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    // Gradient header — extends edge-to-edge; inner content is width-capped on iPad.
                    ZStack {
                        theme.gradient
                        .ignoresSafeArea(edges: .top)

                        VStack(spacing: 12) {
                            HStack {
                                Text("Research Sync")
                                    .font(titleFont)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                Spacer()
                                if unreadCount > 0 {
                                    Text("\(unreadCount) unread")
                                        .font(isRegular ? .body : .subheadline)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(.white.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                                Button { groupByFolder.toggle() } label: {
                                    Image(systemName: groupByFolder ? "folder.fill" : "folder")
                                        .font(isRegular ? .title3 : .body)
                                        // Dims (without turning fully off) while a search
                                        // is overriding grouping — signals "paused", not "off".
                                        .foregroundColor(.white.opacity(
                                            groupByFolder ? (effectiveGrouped ? 0.9 : 0.5) : 0.6))
                                }
                                Button { showSettings = true } label: {
                                    Image(systemName: "gearshape.fill")
                                        .font(isRegular ? .title3 : .body)
                                        .foregroundColor(.white.opacity(0.9))
                                }
                            }
                            .padding(.horizontal)

                            Picker("Filter", selection: $filter) {
                                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                            .colorMultiply(.white)
                        }
                        .frame(maxWidth: contentMaxWidth)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                    }
                    .frame(height: headerHeight)

                    if filtered.isEmpty {
                        Spacer()
                        Image(systemName: "bookmark")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.4))
                            .padding(.bottom, 12)
                        Text(searchText.isEmpty ? "Nothing here yet" : "No results")
                            .foregroundColor(.secondary)
                        Spacer()
                    } else {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            List {
                                if effectiveGrouped {
                                    ForEach(groupedSections, id: \.folder) { section in
                                        DisclosureGroup(isExpanded: expandedBinding(for: section.folder)) {
                                            ForEach(section.items, id: \.url) { item in
                                                ItemRow(item: item, showFolder: false,
                                                    isPending: isPendingClassification(item),
                                                    onTap:        { openAndMarkRead(item) },
                                                    onToggleRead: { toggleRead(item.url) },
                                                    onDelete:     { delete(item.url) },
                                                    onNoteTap:    { notesItem = item },
                                                    onOfflineRead: { readerItem = item })
                                            }
                                        } label: {
                                            FolderSectionHeader(
                                                name: section.folder,
                                                count: section.items.count,
                                                showDot: !expandedBinding(for: section.folder).wrappedValue
                                                    && recentlyClassifiedFolder() == section.folder)
                                        }
                                    }
                                } else {
                                    ForEach(filtered, id: \.url) { item in
                                        ItemRow(item: item, showFolder: true,
                                            isPending: isPendingClassification(item),
                                            onTap:        { openAndMarkRead(item) },
                                            onToggleRead: { toggleRead(item.url) },
                                            onDelete:     { delete(item.url) },
                                            onNoteTap:    { notesItem = item },
                                            onOfflineRead: { readerItem = item })
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .background(Color(.systemBackground))
                            .frame(maxWidth: contentMaxWidth)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .searchable(text: $searchText, prompt: "Search")
            .onAppear { refresh() }
            .refreshable { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .readLaterDidChange)) { _ in
                updateItems(ReadLaterStore.shared.visible())
            }
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                let hasPending = items.contains { $0.folder == nil && isPendingClassification($0) }
                if hasPending || recentlyClassifiedFolder() != nil { tick.toggle() }
            }
            .sheet(isPresented: $showSettings, onDismiss: { refresh() }) {
                SyncKeySettingsView()
            }
            .sheet(item: $notesItem) { item in
                NotesEditorView(
                    item: item,
                    onSave: { newNotes in
                        ReadLaterStore.shared.setNotes(url: item.url, notes: newNotes)
                        updateItems(ReadLaterStore.shared.visible())
                        ReadLaterStore.shared.syncWithCloud()
                    },
                    onOpen: { openAndMarkRead(item) }
                )
            }
            .sheet(item: $readerItem) { item in
                OfflineReaderView(item: item)
            }
        }
    }

    private func refresh() {
        updateItems(ReadLaterStore.shared.visible())
        ReadLaterStore.shared.syncWithCloud { _ in
            DispatchQueue.main.async {
                let latest = ReadLaterStore.shared.visible()
                updateItems(latest)
                // Pre-download bodies for newly-saved items so they're
                // readable offline later (while we still have a connection).
                OfflineBodyStore.shared.prefetchMissing(latest)
            }
        }
    }

    private func openAndMarkRead(_ item: ReadLaterItem) {
        if let url = URL(string: item.url) {
            UIApplication.shared.open(url)
        }
        if !item.read {
            ReadLaterStore.shared.toggleRead(url: item.url)
            updateItems(ReadLaterStore.shared.visible())
            ReadLaterStore.shared.syncWithCloud()
        }
    }

    private func toggleRead(_ url: String) {
        ReadLaterStore.shared.toggleRead(url: url)
        updateItems(ReadLaterStore.shared.visible())
        ReadLaterStore.shared.syncWithCloud()
    }

    private func delete(_ url: String) {
        ReadLaterStore.shared.delete(url: url)
        updateItems(ReadLaterStore.shared.visible())
        ReadLaterStore.shared.syncWithCloud()
    }
}

struct FolderSectionHeader: View {
    let name: String
    let count: Int
    let showDot: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            if showDot {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("A new item just landed here")
            }
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
    }
}

struct ItemRow: View {
    let item: ReadLaterItem
    // Only shown in flat view — in grouped view the folder is already the
    // section header, so repeating it on every item would be redundant.
    let showFolder: Bool
    let isPending: Bool
    let onTap: () -> Void
    let onToggleRead: () -> Void
    let onDelete: () -> Void
    let onNoteTap: () -> Void
    let onOfflineRead: () -> Void
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var faviconSize: CGFloat { hSizeClass == .regular ? 36 : 28 }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: faviconURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    Image(systemName: "globe")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: faviconSize, height: faviconSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(hSizeClass == .regular ? .title3 : .body)
                    .foregroundColor(item.read ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(hostname)
                        .font(hSizeClass == .regular ? .subheadline : .caption)
                        .foregroundColor(.secondary)
                    if let category = ArticleCategory.forURL(item.url) {
                        Text(category.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(category.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(category.color.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if showFolder, let folder = item.folder {
                        Text(folder)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(Color(red: 0.42, green: 0.25, blue: 0.63))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(red: 0.42, green: 0.25, blue: 0.63).opacity(0.15))
                            .clipShape(Capsule())
                    } else if item.folder == nil && isPending {
                        // Shown regardless of showFolder (unlike the folder tag) —
                        // meaningful even inside a collapsed "Unsorted" group, since
                        // it explains *why* the item is still there.
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Sorting…")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            offlineIndicator
            Button(action: onNoteTap) {
                Image(systemName: "note.text")
                    .font(hSizeClass == .regular ? .title3 : .body)
                    .foregroundColor(hasNotes ? .accentColor : .secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, hSizeClass == .regular ? 6 : 4)
        .opacity(item.read ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button(action: onToggleRead) {
                Label(item.read ? "Mark Unread" : "Mark Read",
                      systemImage: item.read ? "envelope.badge" : "checkmark")
            }
            .tint(item.read ? .orange : .green)
        }
    }

    private var iconFont: Font { hSizeClass == .regular ? .title3 : .body }

    // Mirrors the browser extension's per-item offline badge:
    // saved = tappable book, requested = spinner, unavailable = muted closed
    // book (informational — capture happens on a browser/Safari surface, so
    // there's nothing to retry from the app), none = nothing.
    @ViewBuilder
    private var offlineIndicator: some View {
        switch item.offline {
        case .saved:
            Button(action: onOfflineRead) {
                Image(systemName: "book")
                    .font(iconFont)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read offline")
        case .requested:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Saving for offline")
        case .unavailable:
            Image(systemName: "book.closed")
                .font(iconFont)
                .foregroundColor(.secondary.opacity(0.35))
                .accessibilityLabel("Offline not available")
        case .none:
            EmptyView()
        }
    }

    private var hasNotes: Bool { !(item.notes ?? "").isEmpty }

    private var hostname: String {
        URL(string: item.url).flatMap { $0.host } ?? item.url
    }

    private var faviconURL: URL? {
        URL(string: "https://www.google.com/s2/favicons?domain=\(hostname)&sz=64")
    }

    private var displayTitle: String {
        let host = URL(string: item.url).flatMap { $0.host } ?? ""
        return (item.title == host || item.title == "www." + host) ? item.url : item.title
    }
}

struct SyncKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appTheme") private var themeName: String = AppTheme.ocean.rawValue
    @State private var key: String = ReadLaterStore.shared.syncToken
    @State private var message: String?

    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .ocean }
    private let columns = Array(repeating: GridItem(.flexible()), count: 6)

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(AppTheme.allCases, id: \.self) { t in
                            Button { themeName = t.rawValue } label: {
                                ZStack {
                                    Circle().fill(t.gradient).frame(width: 44, height: 44)
                                    if t == theme {
                                        Circle().strokeBorder(.white, lineWidth: 2.5).frame(width: 44, height: 44)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    TextField("Sync key", text: $key, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Sync Key")
                } footer: {
                    Text("Your sync key links your devices. Paste the same key on each device — this app, the browser extension, and the Raycast extension — to share one list. Keep it private: anyone with it can read your saved pages. There's no account recovery, so copy it somewhere safe.")
                }

                Section {
                    Button("Copy Key") {
                        UIPasteboard.general.string = key
                        flash("Copied")
                    }
                    Button("Generate New Key") {
                        key = ReadLaterStore.generateToken()
                        flash("Generated — tap Save to use it")
                    }
                }

                Section {
                    if let url = Self.exportURL(extension: "json", content: Self.jsonExport()) {
                        ShareLink("Export as JSON", item: url)
                    }
                    if let url = Self.exportURL(extension: "csv", content: Self.csvExport()) {
                        ShareLink("Export as CSV", item: url)
                    }
                } header: {
                    Text("Export Data")
                } footer: {
                    Text("Save or share a copy of everything in your Read Later list, including notes.")
                }

                if let message {
                    Section { Text(message).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if message == text { message = nil }
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 32 else {
            flash("Key must be at least 32 characters")
            return
        }
        ReadLaterStore.shared.syncToken = trimmed
        ReadLaterStore.shared.syncWithCloud()
        dismiss()
    }

    private static func jsonExport() -> Data? {
        try? JSONSerialization.data(withJSONObject: ReadLaterStore.shared.toJSONArray(), options: [.prettyPrinted])
    }

    private static func csvExport() -> Data? {
        var rows = [["Title", "URL", "Saved", "Read", "Folder", "Notes"]]
        let formatter = ISO8601DateFormatter()
        for item in ReadLaterStore.shared.visible() {
            rows.append([
                item.title,
                item.url,
                formatter.string(from: Date(timeIntervalSince1970: item.savedAt / 1000)),
                item.read ? "Yes" : "No",
                item.folder ?? "",
                item.notes ?? "",
            ])
        }
        let csv = rows.map { row in row.map(csvField).joined(separator: ",") }.joined(separator: "\n")
        return csv.data(using: .utf8)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // Writes export content to a temp file so ShareLink has something
    // file-backed (with the right extension/filename) to share or save.
    private static func exportURL(extension ext: String, content: Data?) -> URL? {
        guard let content else { return nil }
        let dateString = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLater-\(dateString)")
            .appendingPathExtension(ext)
        do {
            try content.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
