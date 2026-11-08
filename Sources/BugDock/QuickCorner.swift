import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import BugOSKit

/// One shortcut in the bottom-right quick-access stack. Add new ones to `QuickCornerController.items`
/// (the first item sits nearest the corner).
struct QuickItem: Identifiable {
    enum Icon { case symbol(String), image(NSImage) }
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
    static let bend: CGFloat = 1.0            // leftward drift per item², so the column curves away from the edge
    static let tilt: Double = 1.7             // extra rotation per item, in degrees
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
    var items: [QuickItem] {
        let d = UserDefaults.standard
        let hidden = Set(d.stringArray(forKey: QuickCornerCatalog.hiddenKey) ?? [])
        let apps = d.stringArray(forKey: QuickCornerCatalog.appsKey) ?? []
        let entries = QuickCornerCatalog.ordered(d.stringArray(forKey: QuickCornerCatalog.orderKey), apps: apps)
        return entries.compactMap { e in
            if let path = e.appPath {   // an app you added on the BugOS page
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return QuickItem(id: e.id, label: e.label, icon: .image(NSWorkspace.shared.icon(forFile: path))) {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = true
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg, completionHandler: nil)
                }
            }
            return allItems.first { $0.id == e.id }
        }.filter { !hidden.contains($0.id) }
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
                // BugOS's Squiggle; Apple's Screenshot tool only if it's missing.
                let squiggle = ws.urlForApplication(withBundleIdentifier: "com.bugos.squiggle")
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                ws.openApplication(at: squiggle ?? URL(fileURLWithPath: screenshotPath), configuration: config, completionHandler: nil)
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

    /// Place (or hide) the corner trigger on the bar's screen. Call on launch, screen changes and toggles.
    func layout() {
        let f = bar.screen.frame
        guard Self.isEnabled else { trigger.orderOut(nil); close(); return }
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
        case .symbol(let name):
            ZStack {
                VisualEffect(material: .hudWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                Image(systemName: name)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
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
