import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import BugOSKit

/// One shortcut in the bottom-right quick-access stack. Add new ones to `QuickCornerController.items`
/// (the first item sits nearest the corner).
struct QuickItem: Identifiable {
    /// symbol: an SF Symbol; glyph: a one-colour image drawn like a symbol (tinted the icon colour);
    /// image: a full-colour icon (apps you added).
    enum Icon { case symbol(String), glyph(NSImage), image(NSImage) }
    let id: String
    let label: String
    let icon: Icon
    let action: @MainActor () -> Void
}

/// Bottom-right "hot corner": rest the pointer in the corner and a Dock-Stacks-style fan of
/// shortcuts springs up from it. Moving back toward the screen closes it.
@MainActor
final class QuickCornerController {
    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "quickCornerEnabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "quickCornerEnabled") }
    }

    // Stack geometry (points).
    static let icon: CGFloat = 44
    static let spacing: CGFloat = 54          // vertical distance between items
    static let edgeInset: CGFloat = 34        // icon center distance from the right screen edge (item 0)
    /// BugOS › Quick Corner › Curve: 0 = a straight column up the edge, 1 = the default curve, 2 = extra curvy.
    static var curve: CGFloat { CGFloat(UserDefaults.standard.object(forKey: QuickCornerCatalog.curveKey) as? Double ?? 1) }
    static var bend: CGFloat { 1.0 * curve }            // leftward drift per item², so the column curves away from the edge
    static var tilt: Double { 1.7 * Double(curve) }     // extra rotation per item, in degrees
    static let width: CGFloat = 300
    static let rowWidth: CGFloat = 230

    private unowned let bar: TaskbarController
    private let trigger = FloatingPanel(level: .taskbarPopup)
    private let triggerView = CornerTriggerView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
    private let fan = FloatingPanel(level: .taskbarPopup)
    private let model = QuickFanModel()
    private var dwell: DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var moveMonitorGlobal: Any?
    private var moveMonitorLocal: Any?
    private var setMenuOpen = false
    private var closing = false

    /// The items as arranged on the BugOS page (order, and which are hidden).
    var items: [QuickItem] { items(for: QuickCornerCatalog.corner) }

    /// A list's shortcuts (the fan's, or Quick Access's), nearest-the-corner / bottom first.
    func items(for list: QuickCornerCatalog.List) -> [QuickItem] {
        let d = UserDefaults.standard
        let hidden = Set(d.stringArray(forKey: list.hidden) ?? list.defaultHidden)
        let apps = d.stringArray(forKey: list.apps) ?? []
        let entries = QuickCornerCatalog.ordered(d.stringArray(forKey: list.order), apps: apps, defaultOrder: list.defaultOrder)
        return entries.compactMap { e in
            if let path = e.appPath {   // an app you added on the BugOS page
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return QuickItem(id: e.id, label: e.label, icon: .image(NSWorkspace.shared.icon(forFile: path))) {
                    let url = URL(fileURLWithPath: path)
                    if url.pathExtension == "app" {
                        let cfg = NSWorkspace.OpenConfiguration()
                        cfg.activates = true
                        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
                    } else {
                        NSWorkspace.shared.open(url)   // a folder opens in File Explorer, a file in its app
                    }
                }
            }
            if e.id == "recent" { return Self.recentItem() }   // its name changes with the app you'd go back to
            if e.id == "ai", let ai = allItems.first(where: { $0.id == "ai" }) {
                // Named after the app it opens: "Claude", "Codex", "ChatGPT".
                return QuickItem(id: ai.id, label: QuickCornerCatalog.aiName, icon: ai.icon, action: ai.action)
            }
            return allItems.first { $0.id == e.id }
        }.filter { !hidden.contains($0.id) }
    }

    /// "Recent: <app>": back to the app you were using before this one (use it again to flip back).
    static func recentItem() -> QuickItem {
        let prev = AppHistory.shared.previous
        let label = prev?.localizedName.map { "Recent: \($0)" } ?? "Recent"
        return QuickItem(id: "recent", label: label, icon: .symbol("clock")) {
            guard let prev, let url = prev.bundleURL else { return }
            if prev.isHidden { prev.unhide() }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        }
    }

    private lazy var allItems: [QuickItem] = {
        let ws = NSWorkspace.shared
        let settingsURL = ws.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
        let screenshotPath = "/System/Applications/Utilities/Screenshot.app"
        let missionControlPath = "/System/Applications/Mission Control.app"
        // Default order, bottom (nearest the corner) to top; the BugOS page can rearrange and hide them.
        return [
            QuickItem(id: "finder", label: "File Explorer", icon: .symbol("folder.fill")) {
                // BugOS's File Explorer; Finder at Home only if it's missing.
                if let explorer = ws.urlForApplication(withBundleIdentifier: BugOSID.explorer) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    ws.openApplication(at: explorer, configuration: config, completionHandler: nil)
                } else {
                    ws.open(FileManager.default.homeDirectoryForCurrentUser)
                }
            },
            QuickItem(id: "missioncontrol", label: "Mission Control", icon: .symbol("rectangle.3.group.fill")) {
                ws.openApplication(at: URL(fileURLWithPath: missionControlPath), configuration: .init(), completionHandler: nil)
            },
            QuickItem(id: "screenshot", label: "Squiggle", icon: .symbol("scribble.variable")) {
                // Squiggle runs in the background with no window, so opening it does nothing: ask it for the
                // Snip or Record bar instead. Apple's Screenshot tool if Squiggle isn't running (turned off).
                if !NSRunningApplication.runningApplications(withBundleIdentifier: BugOSID.squiggle).isEmpty {
                    DistributedNotificationCenter.default().postNotificationName(
                        BugOSID.squiggleSettingsChanged, object: "snip", userInfo: nil, deliverImmediately: true)
                } else {
                    ws.openApplication(at: URL(fileURLWithPath: screenshotPath), configuration: .init(), completionHandler: nil)
                }
            },
            QuickItem(id: "music", label: "Music", icon: .symbol("music.note")) {
                // Spotify by default (BugOS › Quick Corner › Music opens); Apple Music if it isn't installed.
                let chosen = UserDefaults.standard.string(forKey: QuickCornerCatalog.musicAppKey) ?? "com.spotify.client"
                let url = ws.urlForApplication(withBundleIdentifier: chosen) ?? ws.urlForApplication(withBundleIdentifier: "com.apple.Music")
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                if let url { ws.openApplication(at: url, configuration: cfg, completionHandler: nil) }
            },
            QuickItem(id: "ai", label: "AI", icon: .symbol("sparkles")) {
                // Claude by default (BugOS › Quick Corner › AI shortcut opens); otherwise the first AI app installed.
                let chosen = UserDefaults.standard.string(forKey: QuickCornerCatalog.aiAppKey) ?? "com.anthropic.claudefordesktop"
                let url = ([chosen] + QuickCornerCatalog.aiApps.map(\.id)).lazy
                    .compactMap { ws.urlForApplication(withBundleIdentifier: $0) }.first
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                if let url { ws.openApplication(at: url, configuration: cfg, completionHandler: nil) }
            },
            QuickItem(id: "browser", label: "Browser", icon: .symbol("globe")) {
                // The Mac's default browser, or the one chosen on the BugOS page.
                let chosen = UserDefaults.standard.string(forKey: QuickCornerCatalog.browserAppKey) ?? "default"
                let url = (chosen == "default" ? nil : ws.urlForApplication(withBundleIdentifier: chosen))
                    ?? ws.urlForApplication(toOpen: URL(string: "https://example.com")!)
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                if let url { ws.openApplication(at: url, configuration: cfg, completionHandler: nil) }
            },
            // Discord, its logo as a glyph (lifted from the app's own icon) so it matches the others.
            QuickItem(id: "discord", label: "Discord",
                      icon: ws.urlForApplication(withBundleIdentifier: "com.hnc.Discord").flatMap { LogoGlyph.from(appAt: $0) }
                        .map { .glyph($0) } ?? .symbol("bubble.left.and.bubble.right.fill")) {
                guard let url = ws.urlForApplication(withBundleIdentifier: "com.hnc.Discord") else {
                    ws.open(URL(string: "https://discord.com/app")!)   // not installed: the web app
                    return
                }
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.openApplication(at: url, configuration: cfg, completionHandler: nil)
            },
            QuickItem(id: "activity", label: "Activity Monitor", icon: .symbol("waveform.path.ecg")) {
                let path = "/System/Applications/Utilities/Activity Monitor.app"
                ws.openApplication(at: URL(fileURLWithPath: path), configuration: .init(), completionHandler: nil)
            },
            QuickItem(id: "apps", label: "All apps", icon: .symbol("square.grid.3x3.fill")) { [weak self] in
                self?.bar.startMenu.open()
            },
            QuickItem(id: "spotlight", label: "Search", icon: .symbol("magnifyingglass")) { Spotlight.open() },
            QuickItem(id: "bugos", label: "BugOS Settings", icon: .symbol("switch.2")) { BugOSChild.send("page:general") },
            QuickItem(id: "settings", label: "System Settings",
                      icon: .symbol("gearshape.fill")) {
                if let u = settingsURL { ws.openApplication(at: u, configuration: .init(), completionHandler: nil) }
            },
        ]
    }()

    init(bar: TaskbarController) {
        self.bar = bar
        trigger.contentView = triggerView
        triggerView.onEnter = { [weak self] in self?.pointerEnteredCorner() }
        triggerView.onExit = { [weak self] in self?.dwell?.cancel() }
    }

    var isOpen: Bool { fan.isVisible && !closing }
    /// The trackpad gesture's look: a column sliding in from the right edge (QuickPanel.swift).
    lazy var side = QuickPanelController(corner: self, bar: bar)
    var isHiddenForFullScreen: Bool { bar.hiddenForFullScreen }

    /// Place (or hide) the corner trigger on the bar's screen. Call on launch, screen changes and toggles.
    func layout() {
        TrackpadGesture.shared.corner = self
        TrackpadGesture.shared.reload()
        let f = bar.screen.frame
        guard Self.isEnabled, !bar.hiddenForFullScreen else { trigger.orderOut(nil); close(); return }
        trigger.setFrame(NSRect(x: f.maxX - 4, y: f.minY, width: 4, height: 4), display: true)
        trigger.orderFrontRegardless()
        if fan.isVisible { fan.setFrame(fanFrame, display: true) }
    }

    static func height(for count: Int) -> CGFloat {
        Metrics.barHeight + 8 + CGFloat(count) * spacing + 24
    }

    private var fanFrame: NSRect {
        let f = bar.screen.frame
        return NSRect(x: f.maxX - Self.width, y: f.minY, width: Self.width, height: Self.height(for: items.count))
    }

    private func pointerEnteredCorner() {
        guard Self.isEnabled, !isOpen else { return }
        dwell?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.open() }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func open() {
        guard !isOpen, !bar.menuOpen, !bar.isDragging else { return }
        closing = false
        bar.preview.hide()
        bar.menuOpen = true          // suppresses thumbnail popups / peek while the stack is up
        setMenuOpen = true
        model.hovered = nil

        // Static SwiftUI layout; the motion is Core Animation on the hosting layer. (SwiftUI's own
        // animations stall in this never-active, non-activating panel and leave items half-faded.)
        let frame = fanFrame
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let host = ClickThroughHostingView(rootView: QuickFanView(model: model, items: items) { [weak self] item in
            self?.run(item)
        })
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        container.wantsLayer = true
        container.addSubview(host)
        fan.contentView = container
        fan.setFrame(frame, display: true)
        fan.alphaValue = 1
        fan.acceptsMouseMovedEvents = true
        fan.orderFrontRegardless()
        animate(host, opening: true)

        pendingClose?.cancel(); pendingClose = nil
        moveMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(NSEvent.mouseLocation) }
        }
        moveMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            MainActor.assumeIsolated { self?.pointerMoved(NSEvent.mouseLocation) }
            return e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.close() } }   // Esc
        }
    }

    func close() {
        guard fan.isVisible, !closing else { return }
        closing = true
        dwell?.cancel()
        pendingClose?.cancel(); pendingClose = nil
        for m in [moveMonitorGlobal, moveMonitorLocal, clickMonitor, keyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        moveMonitorGlobal = nil; moveMonitorLocal = nil; clickMonitor = nil; keyMonitor = nil
        if setMenuOpen { bar.menuOpen = false; setMenuOpen = false }
        model.hovered = nil
        guard let host = fan.contentView?.subviews.first else { finishClose(); return }
        animate(host, opening: false)   // the stack drops back into the corner (~0.12s)
        // Safety net in case the animation's completion never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.closing else { return }
            self.finishClose()
        }
    }

    private func finishClose() {
        fan.orderOut(nil)
        fan.contentView = nil
        closing = false
    }

    /// Scale about the bottom-right corner (the hot corner) plus a fade.
    /// Layer-backed views anchor at the bottom-left, so shift to the corner, scale, and shift back.
    private func cornerTransform(_ s: CGFloat, width w: CGFloat) -> CATransform3D {
        var t = CATransform3DMakeTranslation(-w, 0, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(s, s, 1))
        return CATransform3DConcat(t, CATransform3DMakeTranslation(w, 0, 0))
    }

    private func animate(_ view: NSView, opening: Bool) {
        guard let layer = view.layer else { if !opening { finishClose() }; return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let w = view.bounds.width
        let small = cornerTransform(reduce ? 1 : 0.35, width: w)

        CATransaction.begin()
        if !opening {
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.closing else { return }
                    self.finishClose()
                }
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opening ? 0 : 1
        fade.toValue = opening ? 1 : 0
        fade.duration = opening ? 0.16 : 0.12
        fade.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)

        let move: CABasicAnimation
        if opening && !reduce {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.damping = 18
            spring.stiffness = 260
            spring.mass = 1
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            move = spring
        } else {
            move = CABasicAnimation(keyPath: "transform")
            move.duration = 0.12
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        move.fromValue = NSValue(caTransform3D: opening ? small : CATransform3DIdentity)
        move.toValue = NSValue(caTransform3D: opening ? CATransform3DIdentity : small)

        layer.opacity = opening ? 1 : 0
        layer.transform = opening ? CATransform3DIdentity : small
        layer.add(fade, forKey: "fade")
        layer.add(move, forKey: "move")
        CATransaction.commit()
    }

    // MARK: Pointer-following dismissal

    /// Where each item's icon center sits, in screen coordinates (matches QuickFanView's layout).
    /// The trackpad gesture opened the fan: put the pointer on a shortcut (0 = nearest the corner).
    func pointToItem(_ i: Int) {
        guard !items.isEmpty else { return }
        let c = iconCenter(max(0, min(items.count - 1, i)))
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: c.x, y: mainH - c.y))   // CG coordinates: top-left origin
        CGAssociateMouseAndMouseCursorPosition(1)
        pointerMoved(c)
        model.hovered = items[max(0, min(items.count - 1, i))].id
    }
    /// Gesture slid back down: nothing highlighted, so lifting opens nothing.
    func clearHighlight() { model.hovered = nil }

    /// Gesture lifted: open the highlighted shortcut (if any; otherwise the fan stays open).
    func runHighlighted() {
        guard let id = model.hovered, let item = items.first(where: { $0.id == id }) else { return }
        run(item)
    }

    /// 0…1 up the fan, as the fingers keep sliding.
    func pointToItem(fraction: Double, fromTop: Bool = false) {
        guard !items.isEmpty, fraction >= 0 else { return }
        let step = Int((fraction * Double(items.count - 1)).rounded())
        let i = fromTop ? items.count - 1 - step : step
        if model.hovered != items[i].id { pointToItem(i) }
    }

    private func iconCenter(_ i: Int) -> CGPoint {
        let f = fanFrame
        let fi = CGFloat(i)
        return CGPoint(x: f.maxX - Self.edgeInset - Self.bend * fi * fi,
                       y: f.minY + Metrics.barHeight + 8 + Self.icon / 2 + fi * Self.spacing)
    }

    /// Visible items (icon + label) inflated ~10pt, plus the corner and the gap up to the first item.
    private var safeZone: [NSRect] {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        var rects: [NSRect] = []
        for (i, item) in items.enumerated() {
            let c = iconCenter(i)
            let labelW = (item.label as NSString).size(withAttributes: [.font: font]).width + 16
            let left = c.x - Self.icon / 2 - 10 - labelW
            rects.append(NSRect(x: left, y: c.y - Self.icon / 2, width: c.x + Self.icon / 2 - left, height: Self.icon)
                .insetBy(dx: -10, dy: -10))
        }
        let f = bar.screen.frame
        let firstLeft = iconCenter(0).x - Self.icon / 2 - 10
        rects.append(NSRect(x: firstLeft, y: f.minY, width: f.maxX - firstLeft, height: iconCenter(0).y - f.minY))
        return rects
    }

    private func pointerMoved(_ p: CGPoint) {
        guard isOpen else { return }
        let f = bar.screen.frame
        let corner = CGPoint(x: f.maxX, y: f.minY)
        let zone = safeZone
        let top = iconCenter(items.count - 1)
        let reach = hypot(top.x - corner.x, top.y - corner.y) + Self.icon / 2
        let leftmost = zone.dropLast().map(\.minX).min() ?? fanFrame.minX
        // Clearly heading back toward the middle of the screen: close right away.
        if hypot(p.x - corner.x, p.y - corner.y) > reach + 40 || p.x < leftmost - 20 {
            close(); return
        }
        if zone.contains(where: { $0.contains(p) }) {
            pendingClose?.cancel(); pendingClose = nil
            return
        }
        guard pendingClose == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClose = nil
            if !self.safeZone.contains(where: { $0.contains(NSEvent.mouseLocation) }) { self.close() }
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func run(_ item: QuickItem) {
        close()
        item.action()
    }
}

@MainActor
final class QuickFanModel: ObservableObject {
    @Published var hovered: String?
}

/// Dock-Stacks-style fan: a gently curved column rising from the bottom-right corner,
/// each icon with its name in a dark label to its left. Static layout; motion is done in Core Animation.
struct QuickFanView: View {
    @ObservedObject var model: QuickFanModel
    let items: [QuickItem]
    let onSelect: (QuickItem) -> Void

    var body: some View {
        let W = QuickCornerController.width
        let H = QuickCornerController.height(for: items.count)
        let rowW = QuickCornerController.rowWidth
        let d = QuickCornerController.icon
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let fi = CGFloat(i)
                let iconX = W - QuickCornerController.edgeInset - QuickCornerController.bend * fi * fi
                let iconY = H - (Metrics.barHeight + 8 + d / 2 + fi * QuickCornerController.spacing)
                QuickStackRow(item: item, hovered: model.hovered == item.id) { onSelect(item) }
                    .frame(width: rowW, alignment: .trailing)
                    .onHover { h in
                        if h { model.hovered = item.id } else if model.hovered == item.id { model.hovered = nil }
                    }
                    .rotationEffect(.degrees(-QuickCornerController.tilt * Double(i)),
                                    anchor: UnitPoint(x: 1 - (d / 2) / rowW, y: 0.5))
                    // Right-aligned row: put its center so the icon lands on (iconX, iconY).
                    .position(x: iconX + d / 2 - rowW / 2, y: iconY)
            }
        }
        .frame(width: W, height: H)
        .environment(\.colorScheme, .dark)
    }
}

/// One row of the stack: name label on the left, icon on the right. Hover changes are instant.
struct QuickStackRow: View {
    let item: QuickItem
    let hovered: Bool
    let action: () -> Void

    var body: some View {
        let d = QuickCornerController.icon
        Button(action: action) {
            HStack(spacing: 10) {
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(hovered ? 0.82 : 0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovered ? 0.3 : 0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                icon
                    .frame(width: d, height: d)
                    .scaleEffect(hovered ? 1.08 : 1)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
    }

    @ViewBuilder private var icon: some View {
        switch item.icon {
        case .image(let img):
            Image(nsImage: img).resizable().interpolation(.high)
        case .symbol, .glyph:
            // Colours from BugOS › Quick Corner (tile tint, icon colour); hover rings in the accent colour.
            let d = UserDefaults.standard
            let tint = d.string(forKey: QuickCornerCatalog.tileColorKey).flatMap(BugOSColor.color(hex:)).map { Color(nsColor: $0) }
            let glyph = d.string(forKey: QuickCornerCatalog.iconColorKey).flatMap(BugOSColor.color(hex:)).map { Color(nsColor: $0) } ?? .white
            ZStack {
                VisualEffect(material: .hudWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let tint {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.55))
                }
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? Color(nsColor: BugOSColor.accent) : Color.white.opacity(0.18), lineWidth: hovered ? 1.5 : 0.5)
                QuickGlyph(icon: item.icon, size: 19).foregroundStyle(glyph)
            }
            .padding(2)
        }
    }
}

/// 4×4pt near-invisible view in the screen corner that notices the pointer arriving.
final class CornerTriggerView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Fully transparent pixels let the mouse fall through to the window below, so paint a 1% fill.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.01).setFill()
        dirtyRect.fill()
    }
}

/// The apps you've been switching between (normal apps with windows, newest first), for "Recent".
@MainActor
final class AppHistory {
    static let shared = AppHistory()
    private var order: [pid_t] = []

    private init() {
        if let front = NSWorkspace.shared.frontmostApplication { note(front) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { AppHistory.shared.note(app) } }
        }
    }

    func start() {}   // creating `shared` starts listening

    private func note(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        order.removeAll { $0 == app.processIdentifier }
        order.insert(app.processIdentifier, at: 0)
        if order.count > 12 { order.removeLast() }
    }

    /// The app before the one in front now (still running).
    var previous: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return order.lazy.filter { $0 != front }
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .first { !$0.isTerminated }
    }
}

/// A shortcut's symbol or glyph at a given size (colour comes from the caller's foregroundStyle).
struct QuickGlyph: View {
    let icon: QuickItem.Icon
    let size: CGFloat
    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size, weight: .medium))
        case .glyph(let img):
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                .frame(width: size * 1.25, height: size * 1.25)
        case .image(let img):
            Image(nsImage: img).resizable().interpolation(.high)
        }
    }
}

/// Turns an app icon whose logo is white on a coloured tile (Discord's) into a one-colour glyph: the bright
/// pixels become the shape, everything else transparent, cropped to the logo.
enum LogoGlyph {
    static func from(appAt url: URL) -> NSImage? {
        let n = 128
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        guard let px = rep.bitmapData else { return nil }
        // 1. White-ish and opaque: maybe part of the logo.
        var on = [Bool](repeating: false, count: n * n)
        for i in 0..<(n * n) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2]), a = Int(px[i * 4 + 3])
            on[i] = a > 200 && min(r, g, b) > 150   // the logo's lower half is shaded grey
        }
        // 2. The logo is the biggest connected shape; the icon's dotted texture is lots of tiny ones.
        var label = [Int](repeating: 0, count: n * n)
        var best = 0, bestSize = 0, next = 0
        for start in 0..<(n * n) where on[start] && label[start] == 0 {
            next += 1
            var stack = [start], size = 0
            label[start] = next
            while let i = stack.popLast() {
                size += 1
                let x = i % n, y = i / n
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < n, ny < n else { continue }
                    let j = ny * n + nx
                    if on[j] && label[j] == 0 { label[j] = next; stack.append(j) }
                }
            }
            if size > bestSize { bestSize = size; best = next }
        }
        let keep = label.map { $0 == best && best != 0 }
        var minX = n, minY = n, maxX = 0, maxY = 0
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x, k = keep[i] && x > 0 && y > 0 && x < n - 1 && y < n - 1
                let v: UInt8 = k ? 255 : 0   // premultiplied: a clear pixel must be 0,0,0,0
                px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = v
                if k { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX > minX, maxY > minY, let cg = rep.cgImage else { return nil }
        // Square crop around the logo.
        let side = max(maxX - minX, maxY - minY) + 2
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let crop = CGRect(x: max(0, cx - side / 2), y: max(0, cy - side / 2), width: min(side, n), height: min(side, n))
        guard let cut = cg.cropping(to: crop) else { return nil }
        let img = NSImage(cgImage: cut, size: NSSize(width: crop.width, height: crop.height))
        img.isTemplate = true
        return img
    }
}
