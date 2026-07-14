import Combine
import SwiftUI

struct ReadLaterView: View {
    @State private var items: [ReadLaterItem] = []
    @State private var filter: Filter = .unread
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var notesItem: ReadLaterItem?
    @State private var readerItem: ReadLaterItem?
    // iPad master/detail selection (by URL, so it survives list refreshes).
    @State private var selectedURL: String?
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

    // Search is revealed on demand from the header (QuickNote's pattern), rather
    // than living in a bottom `.searchable` bar where the keyboard can hide it.
    @State private var isSearchVisible = false
    @FocusState private var isSearchFocused: Bool
    @AppStorage("noteTextSizeV2") private var textSizeRaw: Int = NoteTextSize.standard.rawValue

    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .ocean }
    private var textSize: NoteTextSize { NoteTextSize(rawValue: textSizeRaw) ?? .standard }

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
    private var contentMaxWidth: CGFloat { isRegular ? 760 : .infinity }
    // The currently-selected article for the iPad detail pane, resolved from the
    // live list so it reflects edits (read state, notes) as they happen.
    private var selectedItem: ReadLaterItem? { items.first { $0.url == selectedURL } }
    // Title sits in the (narrow) iPad sidebar as well as the iPhone header, so
    // it stays a compact size on both rather than ballooning on regular width.
    private var titleFont: Font { .system(.title2, design: .rounded).bold() }

    // A search field styled to match QuickNote's: a soft filled capsule with a
    // leading glyph and a clear button that also dismisses the field.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                searchText = ""
                isSearchFocused = false
                withAnimation(.easeInOut(duration: 0.2)) { isSearchVisible = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .scaledFont(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(10)
        .frame(maxWidth: contentMaxWidth)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

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
        Group {
            if isRegular {
                iPadBody
            } else {
                iPhoneBody
            }
        }
        .preferredColorScheme(.light)
        .environment(\.noteTextScale, textSize.scale)
        .onAppear { refresh() }
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

    // iPhone / compact width: single column; tapping a row opens the article.
    private var iPhoneBody: some View {
        NavigationStack {
            listColumn(isSplit: false)
                .navigationBarHidden(true)
        }
    }

    // iPad / regular width: the list on the left, the selected article on the
    // right. Tapping a row selects it into the detail pane instead of jumping
    // straight to Safari.
    private var iPadBody: some View {
        NavigationSplitView {
            listColumn(isSplit: true)
                .navigationBarHidden(true)
        } detail: {
            NavigationStack {
                if let selectedItem {
                    ArticleDetailPane(
                        item: selectedItem,
                        theme: theme,
                        onOpen: { openAndMarkRead(selectedItem) },
                        onToggleRead: { toggleRead(selectedItem.url) },
                        onNotes: { notesItem = selectedItem })
                } else {
                    detailPlaceholder
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var detailPlaceholder: some View {
        ZStack {
            theme.appBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 46))
                    .foregroundStyle(theme.gradient.opacity(0.5))
                Text("Select an article")
                    .scaledFont(.headline)
                    .foregroundColor(.secondary)
                Text("Pick something from the list to read it here.")
                    .scaledFont(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    // Header card + reveal-search + list, shared by both layouts.
    private func listColumn(isSplit: Bool) -> some View {
        ZStack(alignment: .top) {
            theme.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                headerCard
                // Search field slides in just below the header when the
                // magnifying glass is tapped (QuickNote's pattern).
                if isSearchVisible {
                    searchBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if filtered.isEmpty {
                    emptyState
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        itemList(isSplit: isSplit)
                            .frame(maxWidth: contentMaxWidth)
                        Spacer(minLength: 0)
                    }
                    // A persistent gap between the header and the list. Because the
                    // list clips scrolling rows to its own frame, this whitespace
                    // stays put as the list scrolls, so rows never butt up against
                    // the header card.
                    .padding(.top, 18)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bookmark")
                .font(.system(size: 48))
                .foregroundStyle(theme.gradient.opacity(0.5))
            Text(searchText.isEmpty ? "Nothing here yet" : "No results")
                .scaledFont(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Header — a white section with black text and icons, framed by a subtle
    // themed gradient outline (echoing QuickNote's focused-field border).
    private var headerCard: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center) {
                // Title, with the unread count as a quiet subtitle beneath it.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Research Sync")
                        .font(titleFont)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if unreadCount > 0 {
                        Text("\(unreadCount) unread")
                            .scaledFont(.subheadline, weight: .medium)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                // Search / folder / settings grouped on a subtle raised pill.
                HStack(spacing: 18) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isSearchVisible = true }
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass").foregroundColor(.primary)
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button { groupByFolder.toggle() } label: {
                        Image(systemName: groupByFolder ? "folder.fill" : "folder")
                            .foregroundColor(.primary.opacity(
                                groupByFolder ? (effectiveGrouped ? 1.0 : 0.4) : 0.6))
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill").foregroundColor(.primary)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .font(isRegular ? .title3 : .body)
                .imageScale(.large)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(Color.white)
                        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                )
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }

            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: contentMaxWidth)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.gradient, lineWidth: 1.5))
        .shadow(color: theme.start.opacity(0.15), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func itemList(isSplit: Bool) -> some View {
        List {
            if effectiveGrouped {
                ForEach(groupedSections, id: \.folder) { section in
                    DisclosureGroup(isExpanded: expandedBinding(for: section.folder)) {
                        ForEach(section.items, id: \.url) { item in
                            row(for: item, showFolder: false, isSplit: isSplit).cardRow()
                        }
                    } label: {
                        FolderSectionHeader(
                            name: section.folder,
                            count: section.items.count,
                            showDot: !expandedBinding(for: section.folder).wrappedValue
                                && recentlyClassifiedFolder() == section.folder)
                    }
                    .cardRow()
                }
            } else {
                ForEach(filtered, id: \.url) { item in
                    row(for: item, showFolder: true, isSplit: isSplit).cardRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { refresh() }
    }

    private func row(for item: ReadLaterItem, showFolder: Bool, isSplit: Bool) -> some View {
        ItemRow(
            item: item,
            showFolder: showFolder,
            isPending: isPendingClassification(item),
            theme: theme,
            isSelected: isSplit && item.url == selectedURL,
            onTap: {
                if isSplit { select(item) } else { openAndMarkRead(item) }
            },
            onToggleRead: { toggleRead(item.url) },
            onDelete: { delete(item.url) },
            onNoteTap: { notesItem = item },
            onOfflineRead: {
                if isSplit { select(item) } else { readerItem = item }
            })
    }

    // Selecting on iPad only fills the detail pane — it deliberately does NOT
    // mark the item read, so it won't vanish from an "Unread" filter mid-read.
    private func select(_ item: ReadLaterItem) {
        selectedURL = item.url
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
                .scaledFont(.subheadline, weight: .semibold)
                .foregroundColor(.secondary)
            if showDot {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("A new item just landed here")
            }
            Spacer()
            Text("\(count)")
                .scaledFont(.caption, weight: .semibold)
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.vertical, 2)
    }
}

struct ItemRow: View {
    let item: ReadLaterItem
    // Only shown in flat view — in grouped view the folder is already the
    // section header, so repeating it on every item would be redundant.
    let showFolder: Bool
    let isPending: Bool
    let theme: AppTheme
    // Highlights the row as the current detail selection (iPad only).
    var isSelected: Bool = false
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
                    .scaledFont(hSizeClass == .regular ? .title3 : .body, weight: .medium)
                    .foregroundColor(item.read ? .secondary : .primary.opacity(0.9))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(hostname)
                        .scaledFont(hSizeClass == .regular ? .subheadline : .caption)
                        .foregroundColor(.secondary)
                        // Let a long host truncate rather than squeeze the tag.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                    // Only the AI-assigned folder tag is shown; the older
                    // URL-derived category tag was redundant with it.
                    if showFolder, let folder = item.folder {
                        Text(folder)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(theme.end)
                            .lineLimit(1)
                            // Keep the capsule at its natural width so labels
                            // like "Entertainment" never wrap onto two lines.
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(theme.end.opacity(0.15))
                            .clipShape(Capsule())
                            .layoutPriority(1)
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
                    .foregroundColor(hasNotes ? theme.end : .secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        // Recede the row's content once read, but keep the card itself solid.
        .opacity(item.read ? 0.7 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(item.read ? Color.primary.opacity(0.04) : Color.white)
        )
        // Accent spine: the selected theme's gradient for unread items, a muted
        // grey once read — so the theme threads through every card.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.read ? AnyShapeStyle(Color.secondary.opacity(0.3))
                                : AnyShapeStyle(theme.gradient))
                .frame(width: 4)
                .padding(.vertical, 10)
                .padding(.leading, 5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(theme.gradient)
                               : AnyShapeStyle(Color.primary.opacity(0.06)),
                    lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
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
                    .foregroundColor(theme.end)
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
        let host = URL(string: item.url).flatMap { $0.host } ?? item.url
        // Drop the "www." prefix so more room is left for the folder tag.
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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
    @AppStorage("noteTextSizeV2") private var textSizeRaw: Int = NoteTextSize.standard.rawValue
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

                Section("Text Size") {
                    Picker("Text Size", selection: $textSizeRaw) {
                        ForEach(NoteTextSize.allCases) { size in
                            Text(size.label).tag(size.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
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

// The iPad detail pane: renders the offline reader inline when a copy exists,
// otherwise an article-info view with a prominent "Open in Safari" action. The
// toolbar carries read-toggle, notes, and open actions.
struct ArticleDetailPane: View {
    let item: ReadLaterItem
    let theme: AppTheme
    let onOpen: () -> Void
    let onToggleRead: () -> Void
    let onNotes: () -> Void

    private var hostname: String { URL(string: item.url)?.host ?? item.url }
    private var hasNotes: Bool { !(item.notes ?? "").isEmpty }

    var body: some View {
        Group {
            if item.offline == .saved {
                OfflineArticleReader(item: item)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ArticleInfoView(item: item, theme: theme, onOpen: onOpen)
            }
        }
        .navigationTitle(hostname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: onToggleRead) {
                    Image(systemName: item.read ? "envelope.badge" : "checkmark.circle")
                }
                .help(item.read ? "Mark unread" : "Mark read")

                Button(action: onNotes) {
                    Image(systemName: hasNotes ? "note.text" : "note.text.badge.plus")
                        .foregroundColor(hasNotes ? theme.end : nil)
                }
                .help("Notes")

                Button(action: onOpen) {
                    Image(systemName: "safari")
                }
                .help("Open in Safari")
            }
        }
    }
}

// Shown in the iPad detail pane when there's no offline copy to read inline.
private struct ArticleInfoView: View {
    let item: ReadLaterItem
    let theme: AppTheme
    let onOpen: () -> Void

    private var hostname: String { URL(string: item.url)?.host ?? item.url }
    private var faviconURL: URL? {
        URL(string: "https://www.google.com/s2/favicons?domain=\(hostname)&sz=128")
    }

    var body: some View {
        ZStack {
            theme.appBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                AsyncImage(url: faviconURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "globe")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 6) {
                    Text(item.title)
                        .scaledFont(.title3, weight: .semibold)
                        .multilineTextAlignment(.center)
                    Text(hostname)
                        .scaledFont(.subheadline)
                        .foregroundColor(.secondary)
                }

                offlineStatus

                Button(action: onOpen) {
                    Label("Open in Safari", systemImage: "safari")
                        .scaledFont(.body, weight: .semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(theme.gradient)
                        .clipShape(Capsule())
                        .shadow(color: theme.start.opacity(0.3), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, 4)
            }
            .padding(40)
            .frame(maxWidth: 440)
        }
    }

    @ViewBuilder
    private var offlineStatus: some View {
        switch item.offline {
        case .requested:
            offlineLabel("Saving an offline copy…", icon: "arrow.down.circle")
        case .unavailable:
            offlineLabel("Offline copy unavailable", icon: "book.closed")
        case .none:
            offlineLabel("No offline copy yet", icon: "book.closed")
        case .saved:
            EmptyView()
        }
    }

    private func offlineLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .scaledFont(.footnote)
            .foregroundColor(.secondary)
    }
}
