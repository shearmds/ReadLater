import SwiftUI

struct ReadLaterView: View {
    @State private var items: [ReadLaterItem] = []
    @State private var filter: Filter = .unread
    @State private var searchText = ""
    @Environment(\.horizontalSizeClass) private var hSizeClass

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
                        LinearGradient(
                            colors: [Color(red: 1.000, green: 0.541, blue: 0.298),
                                     Color(red: 0.925, green: 0.251, blue: 0.478)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
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
