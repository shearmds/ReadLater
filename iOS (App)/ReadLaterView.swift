import SwiftUI

struct ReadLaterView: View {
    @State private var items: [ReadLaterItem] = []
    @State private var filter: Filter = .unread
    @State private var searchText = ""
    @State private var showSettings = false
    @AppStorage("appTheme") private var themeName: String = AppTheme.sunset.rawValue
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .sunset }

    enum Filter: String, CaseIterable {
        case all = "All", unread = "Unread", read = "Read"
    }

    private var isRegular: Bool { hSizeClass == .regular }
    private var headerHeight: CGFloat { isRegular ? 180 : 130 }
    private var contentMaxWidth: CGFloat { isRegular ? 760 : .infinity }
    private var titleFont: Font { isRegular ? .system(size: 40, weight: .bold) : .largeTitle.bold() }

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
                                Image(systemName: "bookmark.fill")
                                    .font(isRegular ? .title : .title2)
                                    .foregroundColor(.white.opacity(0.9))
                                Text("Read Later")
                                    .font(titleFont)
                                    .foregroundColor(.white)
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
                                ForEach(filtered, id: \.url) { item in
                                    ItemRow(item: item,
                                        onTap:        { openAndMarkRead(item) },
                                        onToggleRead: { toggleRead(item.url) },
                                        onDelete:     { delete(item.url) })
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
            .sheet(isPresented: $showSettings, onDismiss: { refresh() }) {
                SyncKeySettingsView()
            }
        }
    }

    private func refresh() {
        items = ReadLaterStore.shared.visible()
        ReadLaterStore.shared.syncWithCloud { _ in
            DispatchQueue.main.async { items = ReadLaterStore.shared.visible() }
        }
    }

    private func openAndMarkRead(_ item: ReadLaterItem) {
        if let url = URL(string: item.url) {
            UIApplication.shared.open(url)
        }
        if !item.read {
            ReadLaterStore.shared.toggleRead(url: item.url)
            items = ReadLaterStore.shared.visible()
            ReadLaterStore.shared.syncWithCloud()
        }
    }

    private func toggleRead(_ url: String) {
        ReadLaterStore.shared.toggleRead(url: url)
        items = ReadLaterStore.shared.visible()
        ReadLaterStore.shared.syncWithCloud()
    }

    private func delete(_ url: String) {
        ReadLaterStore.shared.delete(url: url)
        items = ReadLaterStore.shared.visible()
        ReadLaterStore.shared.syncWithCloud()
    }
}

struct ItemRow: View {
    let item: ReadLaterItem
    let onTap: () -> Void
    let onToggleRead: () -> Void
    let onDelete: () -> Void
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
                Text(hostname)
                    .font(hSizeClass == .regular ? .subheadline : .caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
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
    @AppStorage("appTheme") private var themeName: String = AppTheme.sunset.rawValue
    @State private var key: String = ReadLaterStore.shared.syncToken
    @State private var message: String?

    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .sunset }
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
}
