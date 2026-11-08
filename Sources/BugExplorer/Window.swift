import AppKit
import BugOSKit

/// One tab: a full browser (address bar, panes, file view) with its own history.
final class ExplorerTab {
    let browser: BrowserViewController
    var location: Location { browser.location }
    init(_ loc: Location) { browser = BrowserViewController(location: loc) }
}

final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    private(set) var tabs: [ExplorerTab] = []
    private(set) var selected = 0
    private let strip = TabStripView()
    private let container = NSView()
    var onClose: (() -> Void)?
    var current: BrowserViewController? { tabs.indices.contains(selected) ? tabs[selected].browser : nil }

    init(locations: [Location]) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 620, height: 380)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.setFrameAutosaveName("BugExplorerMain")
        if w.frame.origin == .zero { w.center() }
        super.init(window: w)
        w.delegate = self

        let root = NSView()
        w.contentView = root
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor), backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        strip.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(strip)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 40),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        strip.onSelect = { [weak self] i in self?.select(i) }
        strip.onClose = { [weak self] i in self?.close(tab: i) }
        strip.onNew = { [weak self] in self?.newTab(nil) }
        strip.onMove = { [weak self] from, to in self?.moveTab(from, to) }
        strip.onMenu = { [weak self] i in self?.tabMenu(i) }

        strip.onLayout = { [weak self] in self?.positionTrafficLights() }

        for loc in locations { addTab(loc, select: false) }
        if tabs.isEmpty { addTab(.home, select: false) }
        select(0)
        positionTrafficLights()
        applyTheme()
    }

    /// Behind everything: nothing (Windows 11), a tinted blur (Mica) or Liquid Glass.
    private let backdrop = NSView()

    private func fill(_ host: NSView, with v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }

    func applyTheme() {
        guard let w = window else { return }
        backdrop.subviews.forEach { $0.removeFromSuperview() }
        let glass = Theme.style != .windows
        w.isOpaque = !glass
        w.backgroundColor = glass ? .clear : .windowBackgroundColor
        if glass {
            let fx: NSView
            if Theme.style == .glass, #available(macOS 26.0, *) {
                let g = NSGlassEffectView()
                g.cornerRadius = 0
                g.style = .regular
                fx = g
            } else {
                let v = NSVisualEffectView()
                v.material = Theme.style == .mica ? .underWindowBackground : .hudWindow
                v.blendingMode = .behindWindow
                v.state = .active
                fx = v
            }
            fill(backdrop, with: fx)
            // Optional colour wash over the glass (BugOS › File Explorer › Tint).
            if let hex = UserDefaults.standard.string(forKey: ExplorerSetting.glassTint), let c = BugOSColor.color(hex: hex) {
                let strength = UserDefaults.standard.object(forKey: ExplorerSetting.glassTintStrength) as? Double ?? 0.2
                let t = NSView()
                t.wantsLayer = true
                t.layer?.backgroundColor = c.withAlphaComponent(strength).cgColor
                fill(backdrop, with: t)
            }
        }
        w.invalidateShadow()
        func redraw(_ v: NSView) { v.needsDisplay = true; v.needsLayout = true; v.subviews.forEach(redraw) }
        if let c = w.contentView { redraw(c) }
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    /// Centre the close/minimise/zoom buttons vertically on the tabs instead of macOS's default top spot.
    /// macOS puts them back on some events (resize, full screen, focus), so this runs after each of those.
    func positionTrafficLights() {
        guard let w = window, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let barHeight: CGFloat = 40
        let tabCentreFromTop: CGFloat = 40 - 17          // tabs are 34pt tall, sitting on the bottom of the bar
        var cf = container.frame
        cf.size.height = barHeight
        cf.origin.y = w.frame.height - barHeight
        if container.frame != cf { container.frame = cf }
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, k) in kinds.enumerated() {
            guard let b = w.standardWindowButton(k) else { continue }
            var f = b.frame
            f.origin.x = 14 + CGFloat(i) * 20
            f.origin.y = titlebar.isFlipped ? tabCentreFromTop - f.height / 2 : barHeight - tabCentreFromTop - f.height / 2
            if b.frame != f { b.frame = f }
        }
    }

    func windowDidResize(_ n: Notification) { positionTrafficLights() }
    func windowDidExitFullScreen(_ n: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ n: Notification) { positionTrafficLights() }
    func windowDidResignKey(_ n: Notification) { positionTrafficLights() }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Tabs

    func addTab(_ loc: Location, select sel: Bool, at index: Int? = nil) {
        let t = ExplorerTab(loc)
        t.browser.onLocationChange = { [weak self] in self?.refreshStrip() }
        t.browser.windowController = self
        let i = index ?? tabs.count
        tabs.insert(t, at: i)
        if sel { select(i) } else { refreshStrip() }
    }

    func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        selected = i
        let v = tabs[i].browser.view
        container.addSubview(v)
        v.pin(to: container)
        refreshStrip()
        tabs[i].browser.focusContent()
    }

    func close(tab i: Int) {
        guard tabs.indices.contains(i) else { return }
        if tabs.count == 1 { window?.performClose(nil); return }
        tabs[i].browser.teardown()
        tabs.remove(at: i)
        select(min(selected >= i ? max(selected - 1, 0) : selected, tabs.count - 1))
    }

    private func moveTab(_ from: Int, _ to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
        selected = to
        refreshStrip()
        strip.needsLayout = true
    }

    func refreshStrip() {
        strip.tabs = tabs.map { ($0.location.tabTitle, $0.location.icon) }
        strip.selected = selected
        window?.title = current?.location.title ?? "File Explorer"
        if let u = current?.location.url { window?.representedURL = u } else { window?.representedURL = nil }
    }

    private func tabMenu(_ i: Int) -> NSMenu {
        let m = NSMenu()
        m.addItem(menuItem("New tab", "plus", key: "") { [weak self] in self?.newTab(nil) })
        m.addItem(menuItem("Duplicate tab", "plus.square.on.square") { [weak self] in
            guard let self else { return }
            self.addTab(self.tabs[i].location, select: true, at: i + 1)
        })
        m.addItem(menuItem("Move tab to new window", "macwindow.badge.plus") { [weak self] in
            guard let self, self.tabs.count > 1 else { return }
            let loc = self.tabs[i].location
            self.close(tab: i)
            (NSApp.delegate as? AppDelegate)?.newWindow(locations: [loc])
        })
        m.addItem(.separator())
        m.addItem(menuItem("Close tab", "xmark") { [weak self] in self?.close(tab: i) })
        m.addItem(menuItem("Close other tabs") { [weak self] in
            guard let self else { return }
            let keep = self.tabs[i]
            for t in self.tabs where t !== keep { t.browser.teardown() }
            self.tabs = [keep]; self.select(0)
        })
        m.addItem(menuItem("Close tabs to the right") { [weak self] in
            guard let self else { return }
            for t in self.tabs[(i + 1)...] { t.browser.teardown() }
            self.tabs.removeSubrange((i + 1)...)
            self.select(min(self.selected, self.tabs.count - 1))
        })
        return m
    }

    /// Menu shortcuts (⌘⇧N, ⌘C, F2…) always reach the current tab, even when nothing inside it
    /// has keyboard focus (e.g. right after typing a path in the address bar).
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let b = current, b.responds(to: action) { return b }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    @objc func newTab(_ sender: Any?) { addTab(.home, select: true) }
    @objc func closeTab(_ sender: Any?) { close(tab: selected) }
    @objc func nextTab(_ sender: Any?) { select((selected + 1) % tabs.count) }
    @objc func previousTab(_ sender: Any?) { select((selected - 1 + tabs.count) % tabs.count) }

    func windowWillClose(_ n: Notification) {
        Settings.shared.savedTabs = tabs.map { $0.location.token }
        tabs.forEach { $0.browser.teardown() }
        onClose?()
    }
}

// MARK: - Tab strip (Windows 11-style tabs in the title bar)

final class TabStripView: NSView {
    var tabs: [(String, NSImage)] = [] { didSet { rebuild() } }
    var selected = 0 { didSet { updateSelection() } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onMenu: ((Int) -> NSMenu?)?
    var onLayout: (() -> Void)?

    private var tabViews: [TabView] = []
    private let addButton = NSButton()
    private let leftInset: CGFloat = 78     // room for the traffic lights

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addButton.image = symbol("plus", size: 13, weight: .medium)
        addButton.isBordered = false
        addButton.bezelStyle = .regularSquare
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.toolTip = "New tab (⌘T)"
        addButton.contentTintColor = .secondaryLabelColor
        addSubview(addButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.strip.cgColor
    }

    override func mouseUp(with e: NSEvent) {
        if e.clickCount == 2 { window?.performZoom(nil) }   // double-click title bar = zoom, like any Mac window
    }

    @objc private func addTapped() { onNew?() }

    private func rebuild() {
        tabViews.forEach { $0.removeFromSuperview() }
        tabViews = tabs.enumerated().map { (i, t) in
            let v = TabView(title: t.0, icon: t.1)
            v.index = i
            v.onSelect = { [weak self] in self?.onSelect?(i) }
            v.onClose = { [weak self] in self?.onClose?(i) }
            v.onDragEnd = { [weak self] x in self?.dropTab(i, x) }
            v.menuProvider = { [weak self] in self?.onMenu?(i) }
            addSubview(v)
            return v
        }
        updateSelection()
        needsLayout = true
    }

    private func updateSelection() {
        for (i, v) in tabViews.enumerated() { v.isSelected = i == selected }
    }

    private var tabWidth: CGFloat {
        let avail = bounds.width - leftInset - 50
        return max(90, min(240, avail / CGFloat(max(tabs.count, 1))))
    }

    override func layout() {
        super.layout()
        let w = tabWidth
        for (i, v) in tabViews.enumerated() where !v.dragging {
            v.frame = NSRect(x: leftInset + CGFloat(i) * w, y: 0, width: w, height: 34)
        }
        let x = leftInset + CGFloat(tabViews.count) * w + 4
        addButton.frame = NSRect(x: x, y: 5, width: 28, height: 24)
        onLayout?()
    }

    override var isFlipped: Bool { false }

    private func dropTab(_ i: Int, _ x: CGFloat) {
        // x = dragged tab's left edge; its centre decides the new slot.
        let w = tabWidth
        let target = max(0, min(tabs.count - 1, Int((x + w / 2 - leftInset) / w)))
        if target != i { onMove?(i, target) } else { needsLayout = true }
    }
}

final class TabView: NSView {
    var index = 0
    var isSelected = false { didSet { needsDisplay = true; closeButton.isHidden = !(isSelected || hovering) } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragEnd: ((CGFloat) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private(set) var dragging = false

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var hovering = false { didSet { needsDisplay = true; closeButton.isHidden = !(isSelected || hovering) } }
    private var downPoint: NSPoint = .zero
    private var startX: CGFloat = 0

    init(title: String, icon: NSImage) {
        super.init(frame: .zero)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.stringValue = title
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = title
        closeButton.image = symbol("xmark", size: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Close tab (⌘W)"
        closeButton.isHidden = true
        [iconView, label, closeButton].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 28, y: (bounds.height - 20) / 2, width: 20, height: 20)
        label.frame = NSRect(x: 34, y: (bounds.height - 16) / 2, width: bounds.width - 34 - 32, height: 16)
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 0)
        if isSelected {
            let path = NSBezierPath()
            let rad: CGFloat = 8
            path.move(to: NSPoint(x: r.minX - 6, y: 0))
            path.appendArc(withCenter: NSPoint(x: r.minX - 6, y: rad - 2), radius: rad - 2, startAngle: 270, endAngle: 360) // outer curve
            path.line(to: NSPoint(x: r.minX, y: r.maxY - rad))
            path.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad, startAngle: 180, endAngle: 90, clockwise: true)
            path.line(to: NSPoint(x: r.maxX - rad, y: r.maxY))
            path.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: r.maxX, y: rad - 2))
            path.appendArc(withCenter: NSPoint(x: r.maxX + 6, y: rad - 2), radius: rad - 2, startAngle: 180, endAngle: 270)
            path.close()
            Theme.toolbar.setFill()
            path.fill()
        } else if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 4).offsetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        if !isSelected && !hovering {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: 10, width: 1, height: bounds.height - 18).fill()
        }
    }

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    override func mouseDown(with e: NSEvent) {
        downPoint = superview?.convert(e.locationInWindow, from: nil) ?? .zero
        startX = frame.minX
        onSelect?()
    }
    override func mouseDragged(with e: NSEvent) {
        let p = superview?.convert(e.locationInWindow, from: nil) ?? .zero
        let dx = p.x - downPoint.x
        if !dragging && abs(dx) < 4 { return }
        dragging = true
        frame.origin.x = startX + dx
    }
    override func mouseUp(with e: NSEvent) {
        if dragging { dragging = false; onDragEnd?(frame.minX) }
    }
    override func otherMouseUp(with e: NSEvent) { if e.buttonNumber == 2 { onClose?() } }   // middle-click closes
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    @objc private func closeTapped() { onClose?() }
}

// MARK: - Colours

/// File Explorer's look, from BugOS › File Explorer › Theme:
///   windows  solid Windows 11 surfaces (the default)
///   mica     Windows 11 Mica: the wallpaper's tint shows through the frame, content stays solid
///   glass    macOS Liquid Glass: the whole window is glass, panes float on it
/// Colours resolve when drawn, so switching theme only needs a redraw.
enum Theme {
    enum Style: String { case windows, mica, glass }
    static var style = Style(rawValue: UserDefaults.standard.string(forKey: ExplorerSetting.theme) ?? "") ?? .windows

    /// Light / dark / follow the Mac (BugOS › File Explorer › Appearance).
    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: ExplorerSetting.appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        // Dark: the black icon (Dock, ⌘-Tab); light: the normal one from the bundle.
        let darkIcon = Bundle.main.url(forResource: "AppIconDark", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
        NSApp.applicationIconImage = ExplorerSetting.isDark ? darkIcon : nil
    }

    /// Re-read the theme and redraw every window.
    static func reload() {
        style = Style(rawValue: UserDefaults.standard.string(forKey: ExplorerSetting.theme) ?? "") ?? .windows
        applyAppearance()
        for w in NSApp.windows { (w.windowController as? ExplorerWindowController)?.applyTheme() }
    }

    /// A grey for dark / light mode, see-through by `alpha` per style (windows, mica, glass).
    static func dyn(_ dark: CGFloat, _ light: CGFloat, _ alpha: [Style: CGFloat] = [:]) -> NSColor {
        NSColor(name: nil) { a in
            NSColor(white: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: alpha[style] ?? 1)
        }
    }
    static let strip = dyn(0.13, 0.90, [.mica: 0, .glass: 0])
    static let toolbar = dyn(0.19, 0.975, [.mica: 0.55, .glass: 0.14])
    static let content = dyn(0.15, 1.0, [.mica: 0.94, .glass: 0.28])
    static let nav = dyn(0.15, 1.0, [.mica: 0.35, .glass: 0.08])
    static let hover = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)
    }
    static let field = dyn(0.15, 1.0, [.mica: 0.85, .glass: 0.45])
    static let fieldBorder = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.12)
    }
}
