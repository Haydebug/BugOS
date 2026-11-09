import AppKit
import UniformTypeIdentifiers
import Combine
import SwiftUI
import BugOSKit

/// Sizes follow BugOS › Taskbar › Size (small 40, medium 48, large 56 points tall).
enum Metrics {
    static var barHeight: CGFloat {
        switch UserDefaults.standard.string(forKey: DockSetting.barSize) {
        case "small": 40
        case "large": 56
        default: 48
        }
    }
    static var button: CGFloat { barHeight - 4 }
    static var icon: CGFloat { (barHeight * 0.625).rounded() }
}

/// The bar's look, from BugOS › Taskbar.
struct BarStyle: Equatable {
    var alignLeft = UserDefaults.standard.string(forKey: DockSetting.barAlignment) == "left"
    var background = UserDefaults.standard.string(forKey: DockSetting.barBackground) ?? "clear"
    var opacity = UserDefaults.standard.object(forKey: DockSetting.barOpacity) as? Double ?? 0.8
    var height = Metrics.barHeight
    var showPreviews = UserDefaults.standard.object(forKey: DockSetting.showPreviews) as? Bool ?? true
    var tint = UserDefaults.standard.string(forKey: DockSetting.barTint) ?? ""
    var floating = UserDefaults.standard.string(forKey: DockSetting.barShape) == "floating"
    var corner = UserDefaults.standard.object(forKey: DockSetting.barCorner) as? Double ?? 14
    var indicator = UserDefaults.standard.string(forKey: DockSetting.indicator) ?? "pill"
    var accentHex = UserDefaults.standard.string(forKey: BugOSColor.accentKey) ?? ""
    var handoff = UserDefaults.standard.string(forKey: DockSetting.handoffPlacement) ?? "island"
    var handoffBadge = UserDefaults.standard.object(forKey: DockSetting.handoffBadge) as? Bool ?? true
    var handoffGlass = UserDefaults.standard.object(forKey: DockSetting.handoffGlass) as? Bool ?? true

    var accent: Color { Color(nsColor: BugOSColor.accent) }
    var tintColor: Color? { BugOSColor.color(hex: tint).map { Color(nsColor: $0) } }
}

@MainActor
final class TaskbarController: ObservableObject {
    let tracker: WindowTracker
    let panel = FloatingPanel(level: .taskbar)
    let nowPlaying: NowPlaying
    /// The main screen's bar (menu-bar screen) has the music, the quick corner, Alt-Tab and the shortcuts;
    /// the bars on other screens (BugOS › Taskbar › Show the taskbar on all displays) are plain taskbars.
    let isPrimary: Bool
    /// Which screen an extra bar belongs to (nil: the main screen).
    let displayID: CGDirectDisplayID?
    /// The apps this bar shows (all of them, or the ones with a window on its screen; a setting).
    @Published private(set) var shownGroups: [AppGroup] = []
    private var groupsSub: AnyCancellable?
    private var refreshTimer: Timer?
    lazy var preview = PreviewController(tracker: tracker, bar: self)
    lazy var startMenu = StartMenuController(tracker: tracker, bar: self)
    lazy var quickCorner = QuickCornerController(bar: self)
    lazy var altTab = AltTabController(tracker: tracker, bar: self)
    var isDragging = false
    var suppressClicksUntil = Date.distantPast
    var menuOpen = false
    /// Published to the bar's view so a change from the BugOS page redraws it.
    @Published var style = BarStyle()
    /// Button frames in bar-view coordinates (top-left origin), for right-click hit testing.
    var itemFrames: [String: CGRect] = [:]

    init(tracker: WindowTracker, nowPlaying: NowPlaying? = nil, displayID: CGDirectDisplayID? = nil) {
        self.tracker = tracker
        self.nowPlaying = nowPlaying ?? NowPlaying()
        self.displayID = displayID
        self.isPrimary = displayID == nil
        // The BugOS page changed a setting: pick it up now.
        // Its settings live on the BugOS page (there's no menu-bar icon); the page also sends commands here.
        DistributedNotificationCenter.default().addObserver(forName: BugOSID.dockSettingsChanged, object: nil, queue: .main) { [weak self] n in
            let command = n.object as? String
            MainActor.assumeIsolated {
                // Commands are for the main bar; every bar picks up new settings.
                if command != nil, self?.isPrimary != true { return }
                switch command {
                case "pause": QuickAccessHotkey.unregister(); ClipboardPanel.shared.pauseShortcut(); return   // the page is recording a shortcut
                case "clipboard:clear": ClipboardHistory.shared.clear(); return
                case "clipboard:log": ClipboardHistory.shared.logSummary(); return
                case "clipboard:open": if !ClipboardPanel.shared.isOpen { ClipboardPanel.shared.open() }; return
                case "clipboard:close": ClipboardPanel.shared.close(handBack: false); return
                case let c? where c.hasPrefix("snap:"): Snapper.shared.key(UInt32(c.dropFirst(5)) ?? 0); return
                case "spotify:connect": SpotifyAuth.shared.connect(); return
                case "spotify:disconnect": SpotifyAuth.shared.disconnect(); return
                case "allapps": self?.startMenu.open(); return
                case "quickcorner": self?.quickCorner.open(); return
                case "quickpanel": self?.quickCorner.side.open(); return
                default: break
                }
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
                if self?.isPrimary == true {
                    QuickAccessHotkey.reload()
                    ShiftScroll.shared.reload()
                    Snapper.shared.reload()
                    ClipboardPanel.shared.reload()
                    self?.altTab.reload()
                    self?.tracker.reloadSettings()
                    TaskbarSet.shared?.sync()
                }
                self?.style = BarStyle()
                self?.refreshShown()
                self?.layout()
            }
        }
        if isPrimary {
            AppHistory.shared.start()   // for Quick Access's "Recent"
            QuickAccessHotkey.corner = quickCorner
            QuickAccessHotkey.reload()
            _ = altTab   // Alt-Tab listens from the start
            ShiftScroll.shared.reload()
            Snapper.shared.tracker = tracker
            Snapper.shared.reload()
            ClipboardPanel.shared.reload()
        }
        groupsSub = tracker.$groups.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShown() }
        }
        // Windows move between screens without the app list changing: look again now and then.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShown() }
        }
        refreshTimer?.tolerance = 0.3
        // Every space, but hidden by Mission Control / Exposé (macOS does that for "transient" windows).
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let root = TaskbarView(tracker: tracker, bar: self, nowPlaying: self.nowPlaying, style: self)
        let host = BarHostingView(rootView: root)
        host.bar = self
        panel.contentView = host
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
    }

    /// The screen this bar sits on: the menu-bar screen, or an extra bar's own screen.
    var screen: NSScreen {
        if let displayID, let s = NSScreen.screens.first(where: { ScreenID.of($0) == displayID }) { return s }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    /// Which apps this bar shows. "All taskbars" (default): every app on every bar. "Where the window is
    /// open": an app shows on the bars of the screens its windows are on, and pinned or windowless apps on
    /// the main bar only (like Windows).
    func refreshShown() {
        guard !retired else { return }
        let groups = tracker.groups
        let mode = UserDefaults.standard.string(forKey: DockSetting.barAppsOn) ?? "all"
        let new: [AppGroup]
        if mode != "where" || TaskbarSet.shared?.hasExtraBars != true {
            new = groups
        } else {
            let mine = screen
            new = groups.filter { g in
                let screens = g.windows.compactMap { TaskbarSet.screen(of: $0) }
                if screens.isEmpty { return isPrimary }                        // pinned / no windows: main bar
                return screens.contains { $0 == mine }
            }
        }
        if new.map(\.id) != shownGroups.map(\.id) || new != shownGroups { shownGroups = new }
    }

    /// An extra bar going away (its screen was unplugged, or the setting turned off). It must never come
    /// back: its view keeps it alive, and its full-screen and screen-change handlers would otherwise show it
    /// again on the main screen, on top of the real bar (every app looked doubled).
    private(set) var retired = false
    func tearDown() {
        retired = true
        refreshTimer?.invalidate()
        fullScreenTimer?.invalidate()
        groupsSub = nil
        for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        preview.hide()
        panel.orderOut(nil)
        panel.contentView = nil   // drops the view, and with it the reference that kept this bar alive
    }
    private var observers: [NSObjectProtocol] = []

    func show() {
        guard !retired else { return }
        layout()
        panel.orderFrontRegardless()
        watchFullScreen()
    }

    // MARK: Full-screen apps

    /// Like Windows: while the app in front is full screen on the bar's screen, the taskbar and the quick
    /// corner get out of the way, and come back when you leave full screen.
    private(set) var hiddenForFullScreen = false
    private var fullScreenTimer: Timer?

    private func watchFullScreen() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkFullScreen()
                    // A space switch finishes animating a moment later.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.checkFullScreen() }
                }
            })
        }
        // Also catches an app going full screen without switching apps (the green button, a video).
        fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullScreen() }
        }
        fullScreenTimer?.tolerance = 0.15   // lets macOS line its wakeups up with the other timers
    }

    private var frontIsFullScreen: Bool {
        guard UserDefaults.standard.object(forKey: FullScreenSetting.hideBar) as? Bool ?? true else { return false }
        let probe = FrontFullScreen.read()
        guard probe.full else { return false }
        // Only if it's full screen on the bar's screen (AX frames are top-left based on the main screen).
        guard let f = probe.frame else { return true }
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height)
        return screen.frame.intersects(cocoa.insetBy(dx: 2, dy: 2))
    }

    func checkFullScreen() {
        guard !retired else { return }
        let full = frontIsFullScreen
        guard full != hiddenForFullScreen else { return }
        hiddenForFullScreen = full
        if full {
            preview.hide()
            startMenu.close()
            if isPrimary { quickCorner.close() }
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        if isPrimary { quickCorner.layout() }
    }

    func layout() {
        guard !retired else { return }
        // An extra bar whose screen is gone never falls back onto the main screen.
        if displayID != nil, !NSScreen.screens.contains(where: { ScreenID.of($0) == displayID }) { panel.orderOut(nil); return }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.minX, y: f.minY, width: f.width, height: Metrics.barHeight), display: true)
        if isPrimary { quickCorner.layout() }
    }

    /// Convert a SwiftUI `.global` rect inside the bar to screen coordinates.
    func screenRect(_ r: CGRect) -> CGRect {
        let p = panel.frame
        return CGRect(x: p.minX + r.minX, y: p.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Right-click on the bar: native NSMenu, which stays open until you pick something
    /// (SwiftUI's .contextMenu kept getting dismissed when the bar redrew).
    func rightClick(at p: CGPoint, in view: NSView) {
        guard let (id, button) = itemFrames.first(where: { $0.value.contains(p) }) else { return }
        guard let g = tracker.groups.first(where: { $0.id == id }) else { return }
        let menu = itemMenu(for: g)
        preview.hide()
        menuOpen = true
        // Windows-style: open the menu ABOVE the clicked button, centered on it.
        // popUp(positioning: nil) puts the menu's top-left corner at `location`, so aim the
        // top-left at (button center - width/2, bar top + gap + menu height), clamped on screen.
        menu.update()
        let size = menu.size
        let gap: CGFloat = 6
        let minX: CGFloat = 8
        let maxX = max(minX, view.bounds.width - size.width - 8)
        let x = min(max(button.midX - size.width / 2, minX), maxX)
        let aboveTop = gap + size.height                  // distance above the bar's top edge
        let y = view.isFlipped ? -aboveTop : view.bounds.height + aboveTop
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: view)   // blocks until the menu closes
        menuOpen = false
    }

    private func itemMenu(for g: AppGroup) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let tracker = self.tracker
        if !g.windows.isEmpty {
            for w in g.windows {
                m.addItem(MenuAction(w.title.isEmpty ? g.name : w.title) { WindowActions.focus(w); tracker.refreshSoon() })
            }
            m.addItem(.separator())
        }
        if let url = g.bundleURL {
            m.addItem(MenuAction(g.isRunning ? "Open new window" : "Open \(g.name)") {
                // Running: a new window here, from the app's own File › New Window (just "opening" it again does
                // nothing for an app that already has windows on another desktop). Not running: open it.
                if g.isRunning, let pid = g.pids.first {
                    // Make the window first, then bring the app forward: with a window here macOS stays put.
                    if WindowActions.newWindowHere(pid: pid) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSRunningApplication(processIdentifier: pid)?.activate() }
                    } else {
                        WindowActions.open(url)
                    }
                    tracker.refreshSoon()
                } else {
                    WindowActions.open(url)
                }
            })
            if g.isRunning { m.addItem(MenuAction("Open new instance") { WindowActions.newInstance(url) }) }
        }
        if g.canPin {
            m.addItem(MenuAction(g.isPinned ? "Unpin from taskbar" : "Pin to taskbar") { tracker.togglePin(g) })
        }
        if let url = g.bundleURL {
            m.addItem(MenuAction("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        if g.canPin {
            let icons = IconCache.shared
            let id = g.id
            m.addItem(MenuAction("Change icon…") { IconPicker.pick(for: id) })
            if icons.hasCustomIcon(id) {
                m.addItem(MenuAction("Reset icon") { icons.setCustomIcon(nil, for: id) })
            }
        }
        if g.isRunning {
            m.addItem(.separator())
            if !g.windows.isEmpty {
                m.addItem(MenuAction(g.windows.count == 1 ? "Close window" : "Close all windows") {
                    g.windows.forEach(WindowActions.close); tracker.refreshSoon()
                })
            }
            m.addItem(MenuAction(g.pids.count > 1 ? "Quit all \(g.pids.count) instances" : "Quit") { tracker.quit(g) })
        }
        return m
    }

}

struct TaskbarView: View {
    @ObservedObject var tracker: WindowTracker
    let bar: TaskbarController
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var style: TaskbarController

    // Drag-to-reorder state.
    @State private var dragging: String?
    @State private var liveOrder: [String]?
    @State private var dragStartIndex = 0
    @State private var dragOffset: CGFloat = 0
    private var slot: CGFloat { style.style.height - 2 }   // button width + HStack spacing

    private var displayed: [AppGroup] {
        let groups = style.shownGroups
        guard let liveOrder else { return groups }
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return liveOrder.compactMap { byID[$0] } + groups.filter { !liveOrder.contains($0.id) }
    }

    var body: some View {
        let st = style.style
        ZStack {
            BarBackground(style: st)
            HStack(spacing: 0) {
                if st.alignLeft { Spacer().frame(width: st.floating ? 16 : 8) }
                apps
                if st.alignLeft { Spacer() }
            }
            HStack(spacing: 8) {
                if !tracker.axTrusted && bar.isPrimary { permissionsButton }
                if !st.alignLeft && bar.isPrimary { NowPlayingWidget(model: nowPlaying) }
                Spacer()
                if st.alignLeft && bar.isPrimary { NowPlayingWidget(model: nowPlaying).padding(.trailing, 10) }
                // Handoff from an iPhone/iPad (the Dock's Handoff icon) as its own island, clear of the quick corner.
                if bar.isPrimary && st.handoff == "island" { HandoffButton(look: st, island: true).padding(.trailing, 12) }
            }
            .padding(.leading, st.floating ? 18 : 10)
            .padding(.trailing, st.floating ? 8 : 0)
            .animation(.easeOut(duration: 0.2), value: nowPlaying.info)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.15), value: st)
    }

    private var apps: some View {
            HStack(spacing: 2) {
                ForEach(displayed) { g in
                    TaskbarItem(group: g, tracker: tracker, bar: bar, isDragging: dragging == g.id, barHeight: style.style.height, look: style.style)
                        .offset(x: dragging == g.id ? dragOffset : 0)
                        .zIndex(dragging == g.id ? 1 : 0)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 6, coordinateSpace: .named("bar"))
                                .onChanged { dragChanged(g.id, $0.translation.width) }
                                .onEnded { _ in dragEnded() }
                        )
                }
                if bar.isPrimary && style.style.handoff == "apps" { HandoffButton(look: style.style, island: false) }
            }
            .coordinateSpace(name: "bar")
            .animation(.easeOut(duration: 0.15), value: displayed.map(\.id))
    }

    private var permissionsButton: some View {
                    Button {
                        // The BugOS page lists what's missing and why.
                        if BugOSChild.bugOSURL != nil { BugOSChild.send("setup") }
                        else { AX.promptForTrust(); AX.openAccessibilitySettings() }
                    } label: {
                        Label("Missing Permissions", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
    }

    private func dragChanged(_ id: String, _ dx: CGFloat) {
        if dragging == nil {
            let ids = style.shownGroups.map(\.id)
            guard let i = ids.firstIndex(of: id) else { return }
            dragging = id
            liveOrder = ids
            dragStartIndex = i
            bar.isDragging = true
            bar.preview.hide()
        }
        guard dragging == id, var order = liveOrder, let cur = order.firstIndex(of: id) else { return }
        let target = max(0, min(order.count - 1, dragStartIndex + Int((dx / slot).rounded())))
        if target != cur {
            order.remove(at: cur)
            order.insert(id, at: target)
            withAnimation(.easeOut(duration: 0.15)) { liveOrder = order }
        }
        dragOffset = dx - CGFloat(target - dragStartIndex) * slot
    }

    private func dragEnded() {
        if let order = liveOrder { tracker.setOrder(order) }
        withAnimation(.easeOut(duration: 0.15)) {
            dragging = nil
            liveOrder = nil
            dragOffset = 0
        }
        bar.suppressClicksUntil = Date().addingTimeInterval(0.25)
        bar.isDragging = false
    }
}

struct TaskbarItem: View {
    let group: AppGroup
    @ObservedObject var tracker: WindowTracker
    @ObservedObject private var icons = IconCache.shared
    let bar: TaskbarController
    var isDragging = false
    var barHeight: CGFloat = Metrics.barHeight   // redraws the button when the size setting changes
    var look = BarStyle()
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            // The mouse-up that ends a drag shouldn't also count as a click.
            guard !bar.isDragging, Date() > bar.suppressClicksUntil else { return }
            bar.preview.hide()
            tracker.clicked(group)
        } label: {
            ZStack(alignment: .bottom) {
                Image(nsImage: IconCache.shared.icon(for: group))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Metrics.icon, height: Metrics.icon)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 3)
                Capsule()
                    .fill(group.isActive ? look.accent : Color.white.opacity(0.55))
                    .frame(width: indicatorSize.width, height: indicatorSize.height)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .opacity((group.windows.isEmpty && !group.elsewhere) || look.indicator == "none" ? 0 : 1)   // only with an open window
                    .padding(.bottom, 2)
            }
            .frame(width: Metrics.button, height: Metrics.button)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.11 : (group.isActive ? 0.06 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global); bar.itemFrames[group.id] = frame }
                .onChange(of: geo.frame(in: .global)) { _, f in frame = f; bar.itemFrames[group.id] = f }
                .onDisappear { bar.itemFrames[group.id] = nil }
        })
        .scaleEffect(isDragging ? 1.08 : 1)
        .onHover { h in
            hovering = h
            if h && (bar.isDragging || bar.menuOpen) { return }
            if h { bar.preview.hoverBegan(groupID: group.id, anchor: bar.screenRect(frame)) }
            else { bar.preview.hoverEnded(groupID: group.id) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: group.isActive)
    }
}

extension TaskbarItem {
    var indicatorSize: CGSize {
        switch look.indicator {
        case "dot": CGSize(width: 4, height: 4)
        case "line": CGSize(width: group.isActive ? Metrics.button - 12 : 10, height: 2)
        default: CGSize(width: group.isActive ? 16 : 6, height: 3)
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// The bar's hosting view: routes right-clicks to native menus.
final class BarHostingView<Content: View>: NSHostingView<Content> {
    weak var bar: TaskbarController?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    // Open on release, not press: the menu sits above the icon (away from the pointer), and a menu
    // opened on press closes as soon as the click is released there — on a trackpad, instantly.
    // Opened after release, it stays up until you pick something or click elsewhere.
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let topLeft = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        MainActor.assumeIsolated { bar?.rightClick(at: topLeft, in: self) }
    }
}

/// NSMenuItem that runs a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// "Change icon…": pick any image file to use as an app's icon on the bar.
@MainActor
enum IconPicker {
    static func pick(for id: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose an icon"
        panel.prompt = "Use as icon"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
        IconCache.shared.setCustomIcon(img, for: id)
    }
}

/// Behind the bar: nothing (the default), a blur, or a solid strip, in the chosen colour and opacity.
/// Floating: a rounded bar with a gap around it instead of edge to edge.
struct BarBackground: View {
    let style: BarStyle
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.floating ? style.corner : 0, style: .continuous)
        Group {
            switch style.background {
            case "translucent":
                ZStack {
                    VisualEffect(material: .hudWindow)
                    if let t = style.tintColor { t.opacity(0.45) }
                }
                .opacity(style.opacity)
            case "solid":
                (style.tintColor ?? Color(white: 0.11)).opacity(style.opacity)
            default:
                Color.clear
            }
        }
        .clipShape(shape)
        .overlay {
            if style.background != "clear" {
                if style.floating { shape.strokeBorder(Color.white.opacity(0.12)) }
                else { VStack { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1); Spacer() } }
            }
        }
        .padding(style.floating ? EdgeInsets(top: 3, leading: 8, bottom: 5, trailing: 8) : EdgeInsets())
    }
}


/// Is the app in front full screen, and where? Asked once for every bar (each extra display's bar checks
/// every second too): one round trip for the focused window's full-screen flag, position and size,
/// shared for a moment, instead of ~5 calls per bar.
@MainActor
enum FrontFullScreen {
    private static var at = Date.distantPast
    private static var last: (full: Bool, frame: CGRect?) = (false, nil)
    private static let attrs = ["AXFullScreen", kAXPositionAttribute, kAXSizeAttribute] as CFArray

    static func read() -> (full: Bool, frame: CGRect?) {
        if Date().timeIntervalSince(at) < 0.2 { return last }
        at = Date()
        last = (false, nil)
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let w = WindowReader.focusedWindow(pid: front.processIdentifier) else { return last }
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(w, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let v = raw as? [AnyObject], v.count == 3, (v[0] as? NSNumber)?.boolValue == true else { return last }
        var p = CGPoint.zero, s = CGSize.zero
        let pv = v[1] as CFTypeRef, sv = v[2] as CFTypeRef
        let ok = CFGetTypeID(pv) == AXValueGetTypeID() && CFGetTypeID(sv) == AXValueGetTypeID()
            && AXValueGetValue(pv as! AXValue, .cgPoint, &p) && AXValueGetValue(sv as! AXValue, .cgSize, &s)
        last = (true, ok ? CGRect(origin: p, size: s) : nil)
        return last
    }
}
