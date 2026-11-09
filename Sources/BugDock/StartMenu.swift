import AppKit
import BugOSKit
import SwiftUI

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?
    /// From Spotlight (fast, no walking through the bundle): when it was installed, last opened, how big.
    var added: Date?
    var lastUsed: Date?
    var size: Int64 = 0
    var id: String { url.path }
}

/// How All apps is sorted (saved in the taskbar's preferences).
enum AppSort: String, CaseIterable, Identifiable {
    case name, recent, added, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .recent: "Recently used"
        case .added: "Date added"
        case .size: "Size"
        }
    }
    var symbol: String {
        switch self {
        case .name: "textformat"
        case .recent: "clock"
        case .added: "calendar.badge.plus"
        case .size: "internaldrive"
        }
    }
    static var saved: AppSort { AppSort(rawValue: UserDefaults.standard.string(forKey: "allAppsSort") ?? "") ?? .name }

    func sorted(_ apps: [InstalledApp]) -> [InstalledApp] {
        let byName: (InstalledApp, InstalledApp) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch self {
        case .name: return apps.sorted(by: byName)
        case .recent: return apps.sorted { ($0.lastUsed ?? .distantPast, $1.name) > ($1.lastUsed ?? .distantPast, $0.name) }
        case .added: return apps.sorted { ($0.added ?? .distantPast, $1.name) > ($1.added ?? .distantPast, $0.name) }
        case .size: return apps.sorted { ($0.size, $1.name) > ($1.size, $0.name) }
        }
    }
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
            if id == BugOSID.dock { return }   // the taskbar itself: nothing to open
            let key = id ?? url.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            var app = InstalledApp(url: url, name: name, bundleID: id)
            if let md = MDItemCreateWithURL(nil, url as CFURL) {
                app.added = MDItemCopyAttribute(md, kMDItemDateAdded) as? Date
                app.lastUsed = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
                app.size = (MDItemCopyAttribute(md, "kMDItemPhysicalSize" as CFString) as? NSNumber)?.int64Value
                    ?? (MDItemCopyAttribute(md, kMDItemFSSize) as? NSNumber)?.int64Value ?? 0
            }
            if app.added == nil { app.added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate }
            out.append(app)
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
    @Published var sort: AppSort = AppSort.saved {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "allAppsSort") }
    }

    var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sort.sorted(apps) }
        let starts = apps.filter { $0.name.range(of: q, options: [.caseInsensitive, .anchored]) != nil }
        let contains = apps.filter { $0.name.localizedCaseInsensitiveContains(q) && !starts.contains($0) }
        return starts + contains
    }

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppCatalog.scan()
            DispatchQueue.main.async { if list != self.apps { self.apps = list } }   // unchanged: no redraw mid-animation
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
        // Know the apps before the first open (in the background, once things have settled after login),
        // so the first All apps isn't empty for a moment. Every open still rescans, as before.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.model.reload() }
        let host = ClickThroughHostingView(rootView: StartMenuView(model: model, tracker: tracker, close: { [weak self] in self?.close() }))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        // Liquid Glass on macOS 26 (the same material as Spotlight and Control Center); a blur before that.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.corner
            glass.style = .regular
            glass.contentView = host
            panel.contentView = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = Self.corner
            fx.layer?.masksToBounds = true
            host.frame = fx.bounds
            host.autoresizingMask = [.width, .height]
            fx.addSubview(host)
            panel.contentView = fx
        }
    }

    static let size = NSSize(width: 720, height: 600)
    static let corner: CGFloat = 30

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
        // Centred on the screen (its visible part: below the menu bar, above the taskbar).
        let size = Self.size
        var s = bar.screen.visibleFrame
        if !bar.hiddenForFullScreen { s.origin.y += Metrics.barHeight / 2; s.size.height -= Metrics.barHeight / 2 }
        let frame = NSRect(x: (s.midX - size.width / 2).rounded(), y: (s.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        // Scale and fade in from slightly smaller, like Spotlight.
        panel.setFrame(frame.insetBy(dx: size.width * 0.03, dy: size.height * 0.03), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }   // shadow follows the rounded glass
        }
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        let results = model.filtered
        VStack(spacing: 16) {
            SearchCapsule(query: $model.query, focused: $searchFocused) {
                if let first = results.first { launch(first) }
            }

            HStack(alignment: .center) {
                Text(model.query.isEmpty ? "All apps" : "Best matches").font(.system(size: 15, weight: .semibold))
                Text("\(results.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if model.query.isEmpty { SortMenu(sort: $model.sort) }
            }
            .padding(.horizontal, 10)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(results) { app in
                        AppTile(app: app, tracker: tracker, detail: model.query.isEmpty ? detail(app) : nil) { launch(app) }
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 10)
        .frame(width: StartMenuController.size.width, height: StartMenuController.size.height)
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
        .onExitCommand { close() }
    }

    private func launch(_ app: InstalledApp) {
        close()
        WindowActions.open(app.url)
    }

    /// Under each name, what it's sorted by (nothing for Name).
    private func detail(_ app: InstalledApp) -> String? {
        switch model.sort {
        case .name: return nil
        case .size: return app.size > 0 ? ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file) : nil
        case .added: return app.added.map { $0.formatted(date: .abbreviated, time: .omitted) }
        case .recent: return app.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never opened"
        }
    }
}

/// Sort: a small glass capsule with a menu (Name, Recently used, Date added, Size).
struct SortMenu: View {
    @Binding var sort: AppSort
    var body: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
            Text(sort.title).font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(height: 28)
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(AppSort.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s) }
            }
            .pickerStyle(.inline)
        } label: {
            Group {
                if #available(macOS 26.0, *) { label.glassEffect(.regular.interactive(), in: .capsule) }
                else { label.background(Capsule().fill(.ultraThinMaterial)) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The search field: a glass capsule, ringed in the accent colour while you type.
struct SearchCapsule: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    var body: some View {
        let field = HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search for apps", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused(focused)
                .onSubmit(submit)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).frame(height: 44)
        Group {
            if #available(macOS 26.0, *) {
                field.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                field.background(Capsule().fill(.ultraThinMaterial))
            }
        }
        .overlay(Capsule().strokeBorder(Color(nsColor: BugOSColor.accent).opacity(focused.wrappedValue ? 0.7 : 0), lineWidth: 1.5))
    }
}

struct AppTile: View {
    let app: InstalledApp
    let tracker: WindowTracker
    var detail: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(nsImage: IconCache.shared.icon(forPath: app.url.path)).resizable().interpolation(.high)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                    .scaleEffect(hovering ? 1.06 : 1)
                VStack(spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(detail == nil ? 2 : 1)
                        .multilineTextAlignment(.center)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(height: 30, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                // A soft glass highlight under the pointer.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovering ? 0.18 : 0), lineWidth: 0.5))
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hovering)
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
