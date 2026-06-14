import Cocoa
import ServiceManagement
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var currentMenu: NSMenu?
    private var popover: NSPopover?
    private var cloudSyncTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock and App Switcher
        NSApp.setActivationPolicy(.accessory)
        // Close any window the storyboard opened
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }

        setupStatusItem()
        startCloudSync()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "bookmark.fill",
                                       accessibilityDescription: "Read This Later")
                button.imagePosition = .imageLeading
            } else {
                button.title = "📖"
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateCount()
    }

    private func updateCount() {
        let items = ReadLaterStore.shared.visible()
        let unread = items.filter { !$0.read }.count
        DispatchQueue.main.async {
            self.statusItem.button?.title = unread > 0 ? " \(unread)" : ""
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if #available(macOS 12.0, *) {
            togglePopover()
        } else {
            let items = ReadLaterStore.shared.visible()
            let menu = buildMenu(items: items)
            currentMenu = menu
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    @available(macOS 12.0, *)
    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let items = ReadLaterStore.shared.visible()
        let view = ReadLaterPopover(
            items: items,
            launchAtLoginOn: launchAtLoginEnabled,
            onOpenItem: { [weak self] url in
                self?.openItemByURL(url)
                self?.popover?.performClose(nil)
            },
            onToggleLaunchAtLogin: { [weak self] in
                self?.toggleLaunchAtLogin()
            },
            onQuit: { NSApp.terminate(nil) }
        )

        let popover = self.popover ?? NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
    }

    private func openItemByURL(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
        ReadLaterStore.shared.toggleRead(url: urlStr)
        updateCount()
        syncWithCloud()
    }

    private func buildMenu(items: [ReadLaterItem]) -> NSMenu {
        let menu = NSMenu()

        let unread = items.filter { !$0.read }
        let header = NSMenuItem(title: "\(unread.count) unread · \(items.count) total", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for item in unread.prefix(10) {
            let label = item.title.count > 55 ? String(item.title.prefix(55)) + "…" : item.title
            let menuItem = NSMenuItem(title: label, action: #selector(openItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.url
            menu.addItem(menuItem)
        }
        if unread.count > 10 {
            let overflow = NSMenuItem(title: "… and \(unread.count - 10) more unread", action: nil, keyEquivalent: "")
            overflow.isEnabled = false
            menu.addItem(overflow)
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ReadLater", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard let urlStr = sender.representedObject as? String else { return }
        openItemByURL(urlStr)
    }

    // MARK: - Launch at Login

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            } else {
                try? SMAppService.mainApp.register()
            }
        }
    }

    // MARK: - Cloud Sync

    private func startCloudSync() {
        syncWithCloud()
        cloudSyncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.syncWithCloud()
        }
    }

    private func syncWithCloud() {
        ReadLaterStore.shared.syncWithCloud { [weak self] _ in
            DispatchQueue.main.async { self?.updateCount() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - SwiftUI Popover (macOS 12+)

@available(macOS 12.0, *)
struct ReadLaterPopover: View {
    let items: [ReadLaterItem]
    let launchAtLoginOn: Bool
    let onOpenItem: (String) -> Void
    let onToggleLaunchAtLogin: () -> Void
    let onQuit: () -> Void

    @State private var hoveredURL: String?
    @State private var launchAtLoginToggled: Bool = false

    private var unreadItems: [ReadLaterItem] { items.filter { !$0.read } }
    private static let brandPink = Color(red: 0.925, green: 0.251, blue: 0.478)
    private static let brandOrange = Color(red: 1.000, green: 0.541, blue: 0.298)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        ZStack {
            LinearGradient(
                colors: [Self.brandOrange, Self.brandPink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                Text("Read This Later")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                if !unreadItems.isEmpty {
                    Text("\(unreadItems.count) unread")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.22))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(height: 50)
    }

    @ViewBuilder
    private var content: some View {
        if unreadItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bookmark")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("Nothing unread")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(unreadItems.prefix(15), id: \.url) { item in
                        row(item)
                    }
                    if unreadItems.count > 15 {
                        Text("… and \(unreadItems.count - 15) more")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }

    private func row(_ item: ReadLaterItem) -> some View {
        Button(action: { onOpenItem(item.url) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Self.brandPink)
                    .frame(width: 5, height: 5)
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(hoveredURL == item.url ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredURL = hovering ? item.url : nil }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: {
                onToggleLaunchAtLogin()
                launchAtLoginToggled.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: (launchAtLoginOn != launchAtLoginToggled) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundColor((launchAtLoginOn != launchAtLoginToggled) ? Self.brandPink : .secondary)
                    Text("Launch at Login")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onQuit) {
                Text("Quit")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}
