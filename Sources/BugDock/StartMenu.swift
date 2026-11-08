import AppKit
import BugOSKit
import SwiftUI

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?
    var id: String { url.path }
}

enum AppCatalog {
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        // Inside BugOS, BugDock's siblings (File Explorer, Squiggle) live in BugOS.app/Contents/Applications.
        let parts = Bundle.main.bundleURL.deletingLastPathComponent()
        if parts.lastPathComponent == "Applications", parts.deletingLastPathComponent().lastPathComponent == "Contents" {
            roots.append(parts.path)
        }
        var seen = Set<String>()
        var out: [InstalledApp] = []

        func add(_ url: URL) {
            guard url.pathExtension == "app" else { return }
            let bundle = Bundle(url: url)
            let id = bundle?.bundleIdentifier
            let key = id ?? url.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            out.append(InstalledApp(url: url, name: name, bundleID: id))
        }

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" { add(item); continue }
                // One level into plain folders (e.g. "/Applications/Adobe Photoshop 2026/").
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                   let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    inner.forEach(add)
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class StartMenuModel: ObservableObject {
    @Published var query = ""
    @Published var apps: [InstalledApp] = []
    @Published var focusToken = 0

    var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        let starts = apps.filter { $0.name.range(of: q, options: [.caseInsensitive, .anchored]) != nil }
        let contains = apps.filter { $0.name.localizedCaseInsensitiveContains(q) && !starts.contains($0) }
        return starts + contains
    }

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppCatalog.scan()
            DispatchQueue.main.async { self.apps = list }
        }
    }
}

@MainActor
final class StartMenuController: NSObject, NSWindowDelegate {
    private let tracker: WindowTracker
    private unowned let bar: TaskbarController
    private let panel = KeyablePanel(level: .taskbarPopup)
    private let model = StartMenuModel()
    private var clickMonitor: Any?
    private var lastClosed = Date.distantPast

    init(tracker: WindowTracker, bar: TaskbarController) {
        self.tracker = tracker
        self.bar = bar
        super.init()
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = ClickThroughHostingView(rootView: StartMenuView(model: model, tracker: tracker, close: { [weak self] in self?.close() }))
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { close(); return }
        // The click that closed it (resign key) also lands on the Start button; don't instantly reopen.
        if Date().timeIntervalSince(lastClosed) < 0.3 { return }
        open()
    }

    func open() {
        model.query = ""
        model.reload()
        let size = NSSize(width: 640, height: 560)
        let s = bar.screen.frame
        panel.setFrame(NSRect(x: s.midX - size.width / 2, y: bar.panel.frame.maxY + 10, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastClosed = Date()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { close() }
    }
}

struct StartMenuView: View {
    @ObservedObject var model: StartMenuModel
    let tracker: WindowTracker
    let close: () -> Void
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

    var body: some View {
        let results = model.filtered
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for apps", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { if let first = results.first { launch(first) } }
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
            .overlay(alignment: .bottom) {
                Capsule().fill(Color(nsColor: BugOSColor.accent)).frame(height: 2).padding(.horizontal, 18).opacity(searchFocused ? 1 : 0)
            }

            HStack {
                Text(model.query.isEmpty ? "All apps" : "Best matches").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 6)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(results) { app in
                        AppTile(app: app, tracker: tracker) { launch(app) }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .background(VisualEffect(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
        .onExitCommand { close() }
    }

    private func launch(_ app: InstalledApp) {
        close()
        WindowActions.open(app.url)
    }
}

struct AppTile: View {
    let app: InstalledApp
    let tracker: WindowTracker
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(nsImage: IconCache.shared.icon(forPath: app.url.path)).resizable().frame(width: 40, height: 40)
                Text(app.name)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if let id = app.bundleID {
                if tracker.pins.isPinned(id) {
                    Button("Unpin from taskbar") { tracker.pins.unpin(id) }
                } else {
                    Button("Pin to taskbar") { tracker.pins.pin(bundleID: id, url: app.url, name: app.name) }
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        }
    }
}
