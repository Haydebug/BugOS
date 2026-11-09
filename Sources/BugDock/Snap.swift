// Window snapping, Windows 11 style (BugOS › Snapping):
//   ⌃⌥ ← →     left / right half; again to send it to the next screen that way (or back where it was)
//   ⌃⌥ ↑ ↓     maximize / restore, or the top / bottom quarter of a half; ↓ on an ordinary window minimizes
//   drag        to the left or right edge for a half, a corner for a quarter, the top for snap layouts
//               (drop on a zone) or maximize; dragging a snapped window away gives it its old size back
//   green button  rest the pointer on it for snap layouts; click it to maximize like Windows (click again
//                 to restore), ⌘-click for the Mac's real full screen (BugOS › Full Screen)
//   snap assist   after a half (or third) the rest of the screen offers your other windows: click one to
//                 fill it
// ⌃⌥ because ⌃ + arrows are the Mac's desktop / Mission Control keys. Windows move through Accessibility.
import AppKit
import BugOSKit
import Carbon.HIToolbox
import SwiftUI

// MARK: Geometry

/// A snap zone as fractions of the usable screen (0…1, top-left origin).
struct SnapZone: Equatable {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    static let left = SnapZone(x: 0, y: 0, w: 0.5, h: 1), right = SnapZone(x: 0.5, y: 0, w: 0.5, h: 1)
    static let max = SnapZone(x: 0, y: 0, w: 1, h: 1)
    static let topLeft = SnapZone(x: 0, y: 0, w: 0.5, h: 0.5), topRight = SnapZone(x: 0.5, y: 0, w: 0.5, h: 0.5)
    static let bottomLeft = SnapZone(x: 0, y: 0.5, w: 0.5, h: 0.5), bottomRight = SnapZone(x: 0.5, y: 0.5, w: 0.5, h: 0.5)

    /// The rest of the screen next to a full-height column (for snap assist), if it is one.
    var remainder: SnapZone? {
        guard h == 1, w < 1 else { return nil }
        if x == 0 { return SnapZone(x: w, y: 0, w: 1 - w, h: 1) }
        if x + w >= 0.999 { return SnapZone(x: 0, y: 0, w: x, h: 1) }
        return nil
    }
}

/// Snap layouts (the grid that drops down), each a set of zones.
enum SnapLayouts {
    static let all: [[SnapZone]] = [
        [.left, .right],
        [SnapZone(x: 0, y: 0, w: 2.0 / 3, h: 1), SnapZone(x: 2.0 / 3, y: 0, w: 1.0 / 3, h: 1)],
        [SnapZone(x: 0, y: 0, w: 1.0 / 3, h: 1), SnapZone(x: 1.0 / 3, y: 0, w: 1.0 / 3, h: 1), SnapZone(x: 2.0 / 3, y: 0, w: 1.0 / 3, h: 1)],
        [.left, .topRight, .bottomRight],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
        [SnapZone(x: 0, y: 0, w: 0.25, h: 1), SnapZone(x: 0.25, y: 0, w: 0.5, h: 1), SnapZone(x: 0.75, y: 0, w: 0.25, h: 1)],
    ]
}

@MainActor
enum SnapGeometry {
    static var mainH: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Where windows may go on a screen (Cocoa coordinates): below the menu bar, above the taskbar.
    static func usable(_ s: NSScreen) -> CGRect {
        var r = s.visibleFrame
        if TaskbarSet.hasBar(s) {
            let bar = Metrics.barHeight
            let cut = max(0, s.frame.minY + bar - r.minY)
            r.origin.y += cut; r.size.height -= cut
        }
        return r
    }

    /// A zone on a screen, in AX coordinates (top-left origin at the main screen), with a small gap.
    static func rect(_ z: SnapZone, on s: NSScreen) -> CGRect {
        let u = usable(s)
        let gap: CGFloat = 0
        let cocoa = CGRect(x: u.minX + z.x * u.width + gap, y: u.maxY - (z.y + z.h) * u.height + gap,
                           width: z.w * u.width - gap * 2, height: z.h * u.height - gap * 2)
        return toAX(cocoa)
    }

    static func toAX(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height) }
    static func toCocoa(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height) }

    /// The screen a window (AX frame) is mostly on.
    static func screen(ofAX f: CGRect) -> NSScreen? {
        let c = toCocoa(f)
        func overlap(_ s: NSScreen) -> CGFloat { let r = s.frame.intersection(c); return r.isNull ? 0 : r.width * r.height }
        return NSScreen.screens.max { overlap($0) < overlap($1) }
    }

    static func screen(at p: NSPoint) -> NSScreen? { NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 14 && abs(a.minY - b.minY) < 14 && abs(a.width - b.width) < 20 && abs(a.height - b.height) < 20
    }
}

// MARK: The snapper

@MainActor
final class Snapper {
    static let shared = Snapper()
    weak var tracker: WindowTracker?

    private var hotKeys: [EventHotKeyRef?] = []
    private var handlerInstalled = false
    /// Frame before a window was first snapped (to give it back), by window.
    private var restore: [String: CGRect] = [:]

    private var downMonitor: Any?, dragMonitor: Any?, upMonitor: Any?, moveMonitor: Any?
    private var drag: (window: AXUIElement, start: CGRect, key: String, moved: Bool)?
    private var dropZone: (SnapZone, NSScreen)?
    private let preview = SnapPreview()
    let flyout = SnapFlyout()
    let assist = SnapAssist()
    private var hoverWork: DispatchWorkItem?

    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    var enabled: Bool { Self.on(SnapSetting.enabled) }

    func reload() {
        registerKeys()
        reloadGreenButton()
        let wantMouse = enabled && (Self.on(SnapSetting.drag) || Self.on(SnapSetting.layouts))
        if wantMouse && downMonitor == nil { startMouse() } else if !wantMouse && downMonitor != nil { stopMouse() }
    }

    // MARK: Keys

    private func registerKeys() {
        for r in hotKeys { if let r { UnregisterEventHotKey(r) } }
        hotKeys = []
        guard enabled, Self.on(SnapSetting.keys) else { return }
        if !handlerInstalled {
            handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                guard hk.signature == OSType(0x4253_4E50) else { return OSStatus(eventNotHandledErr) }   // "BSNP"
                let id = hk.id
                DispatchQueue.main.async { MainActor.assumeIsolated { Snapper.shared.key(id) } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        for (i, code) in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4253_4E50), id: UInt32(i + 1)),
                                GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    private func focusedWindow() -> (AXUIElement, pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let w = WindowReader.focusedWindow(pid: app.processIdentifier) else { return nil }
        return (w, app.processIdentifier)
    }

    /// One of the four snap keys (1 ←, 2 →, 3 ↑, 4 ↓) on the window in front (also the "snap:N" test command).
    func key(_ id: UInt32) {
        guard let (w, _) = focusedWindow(), let f = AX.frame(w), let s = SnapGeometry.screen(ofAX: f) else { return }
        let k = Self.key(w)
        func at(_ z: SnapZone) -> Bool { SnapGeometry.close(f, SnapGeometry.rect(z, on: s)) }
        switch id {
        case 1:   // ←
            if at(.left), let next = neighbour(of: s, left: true) { place(w, .right, on: next) }
            else if at(.right) { giveBack(w) }
            else { place(w, .left, on: s) }
        case 2:   // →
            if at(.right), let next = neighbour(of: s, left: false) { place(w, .left, on: next) }
            else if at(.left) { giveBack(w) }
            else { place(w, .right, on: s) }
        case 3:   // ↑
            if at(.left) { place(w, .topLeft, on: s) }
            else if at(.right) { place(w, .topRight, on: s) }
            else if at(.bottomLeft) { place(w, .left, on: s) }
            else if at(.bottomRight) { place(w, .right, on: s) }
            else { place(w, .max, on: s) }
        case 4:   // ↓
            if at(.max) { giveBack(w) }
            else if at(.left) { place(w, .bottomLeft, on: s) }
            else if at(.right) { place(w, .bottomRight, on: s) }
            else if at(.topLeft) { place(w, .left, on: s) }
            else if at(.topRight) { place(w, .right, on: s) }
            else if restore[k] != nil { giveBack(w) }
            else { AX.set(w, kAXMinimizedAttribute, true) }
        default: break
        }
    }

    /// The screen next to this one, to the left or right.
    private func neighbour(of s: NSScreen, left: Bool) -> NSScreen? {
        let others = NSScreen.screens.filter { $0 != s && (left ? $0.frame.midX < s.frame.midX : $0.frame.midX > s.frame.midX) }
        return others.min { abs($0.frame.midX - s.frame.midX) < abs($1.frame.midX - s.frame.midX) }
    }

    // MARK: Moving windows

    static func key(_ w: AXUIElement) -> String { "\(CFHash(w))" }

    /// Put a window in a zone (remembering where it was, the first time).
    func place(_ w: AXUIElement, _ z: SnapZone, on s: NSScreen, assist offerAssist: Bool = true) {
        let k = Self.key(w)
        if restore[k] == nil, let f = AX.frame(w) { restore[k] = f }
        if AX.bool(w, kAXMinimizedAttribute) == true { AX.set(w, kAXMinimizedAttribute, false) }
        Self.setFrame(w, SnapGeometry.rect(z, on: s))
        if offerAssist, enabled, Self.on(SnapSetting.assist), let rest = z.remainder {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.offerAssist(rest, on: s, except: w) }
        }
    }

    private func giveBack(_ w: AXUIElement) {
        let k = Self.key(w)
        guard var old = restore.removeValue(forKey: k) else { return }
        // Moved to another screen since it was snapped: its old size, centred on the screen it's on now,
        // rather than jumping back to the screen it started on.
        if let now = AX.frame(w), let here = SnapGeometry.screen(ofAX: now), let there = SnapGeometry.screen(ofAX: old), here != there {
            let u = SnapGeometry.toAX(SnapGeometry.usable(here))
            let size = CGSize(width: min(old.width, u.width), height: min(old.height, u.height))
            old = CGRect(x: u.midX - size.width / 2, y: u.midY - size.height / 2, width: size.width, height: size.height)
        }
        Self.setFrame(w, old)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        apply(w, r)
        // macOS can still clip the size to the screen a window is leaving (moving between displays): check
        // a moment later and set it again (twice at most).
        func recheck(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard let f = AX.frame(w), !SnapGeometry.close(f, r) else { return }
                apply(w, r)
                if tries > 1 { recheck(tries - 1) }
            }
        }
        recheck(2)
    }

    private static func apply(_ w: AXUIElement, _ r: CGRect) {
        var p = r.origin, sz = r.size
        // Position, size, position again: some apps clamp the size to the screen they're still on.
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }

    // MARK: The green button: maximize, like Windows

    private var clickTap: CFMachPort?
    /// A green-button press we swallowed, waiting for its release: the window, and whether ⌘ was held.
    private var greenPress: (window: AXUIElement, command: Bool)?
    static var greenMaximizes: Bool { UserDefaults.standard.object(forKey: FullScreenSetting.greenMaximizes) as? Bool ?? true }

    func reloadGreenButton() {
        let want = Self.greenMaximizes
        if want, clickTap == nil {
            let mask = CGEventMask((1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue))
            clickTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { _, type, event, _ in
                MainActor.assumeIsolated { Snapper.shared.greenClick(type, event) ? nil : Unmanaged.passUnretained(event) }
            }, userInfo: nil)
            if let clickTap {
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, clickTap, 0), .commonModes)
            }
        }
        if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: want) }
    }

    private let systemWide: AXUIElement = {
        let s = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(s, 0.05)   // never hold a click up for an app that's slow to answer
        return s
    }()

    /// True = swallow the event.
    private func greenClick(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: true) }
            return false
        }
        if type == .leftMouseUp {
            guard let press = greenPress else { return false }
            greenPress = nil
            if press.command { AXUIElementSetAttributeValue(press.window, "AXFullScreen" as CFString, kCFBooleanTrue) }
            else { toggleMaximize(press.window) }
            return true
        }
        // Mouse down: is it on a window's green button?
        let p = e.location   // global, top-left origin: the same as AX
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &el) == .success, let el,
              AX.string(el, kAXSubroleAttribute) == kAXFullScreenButtonSubrole,
              let w = AX.element(el, kAXWindowAttribute) else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
        flyout.hide()
        greenPress = (w, e.flags.contains(.maskCommand))
        return true
    }

    /// Maximize (above the taskbar), or back to its old size if it already is.
    func toggleMaximize(_ w: AXUIElement) {
        guard let f = AX.frame(w), let s = SnapGeometry.screen(ofAX: f) else { return }
        if SnapGeometry.close(f, SnapGeometry.rect(.max, on: s)), restore[Self.key(w)] != nil { giveBack(w) }
        else { place(w, .max, on: s, assist: false) }
    }

    // MARK: Snap assist

    private func offerAssist(_ z: SnapZone, on s: NSScreen, except: AXUIElement) {
        guard let tracker else { return }
        let others = tracker.groups.flatMap { g in g.windows.map { (g, $0) } }.filter { _, w in
            !w.isMinimized && !CFEqual(w.element, except) &&
            (AX.frame(w.element).flatMap(SnapGeometry.screen(ofAX:)) == s)
        }
        guard !others.isEmpty else { return }
        assist.show(in: SnapGeometry.toCocoa(SnapGeometry.rect(z, on: s)), windows: others.map { (g, w) in
            (w, g.name, IconCache.shared.icon(for: g))
        }) { [weak self] w in
            self?.place(w.element, z, on: s, assist: false)
            WindowActions.focus(w)
        }
    }

    // MARK: Dragging and the green button

    private func startMouse() {
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            MainActor.assumeIsolated { Snapper.shared.mouseDown() }
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in
            MainActor.assumeIsolated { Snapper.shared.mouseDragged() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            MainActor.assumeIsolated { Snapper.shared.mouseUp() }
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            MainActor.assumeIsolated { Snapper.shared.mouseMoved() }
        }
    }

    private func stopMouse() {
        for m in [downMonitor, dragMonitor, upMonitor, moveMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        downMonitor = nil; dragMonitor = nil; upMonitor = nil; moveMonitor = nil
    }

    /// The window under the pointer and whether the pointer is on its title bar.
    private func windowAtPointer() -> (window: AXUIElement, element: AXUIElement)? {
        let p = NSEvent.mouseLocation
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(SnapGeometry.mainH - p.y), &el) == .success,
              let el else { return nil }
        if AX.string(el, kAXRoleAttribute) == kAXWindowRole { return (el, el) }
        guard let w = AX.element(el, kAXWindowAttribute) else { return nil }
        return (w, el)
    }

    private func mouseDown() {
        drag = nil
        guard enabled, Self.on(SnapSetting.drag), let (w, el) = windowAtPointer(), let f = AX.frame(w),
              AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        // Only a grab on the title bar (the top strip), not its buttons.
        let p = NSEvent.mouseLocation, axY = SnapGeometry.mainH - p.y
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        guard axY - f.minY < 38, role != kAXButtonRole else { return }
        drag = (w, f, Self.key(w), false)
    }

    private func mouseDragged() {
        guard var d = drag else { return }
        if !d.moved {
            guard let f = AX.frame(d.window), abs(f.minX - d.start.minX) + abs(f.minY - d.start.minY) > 3 else { return }
            d.moved = true
            drag = d
            // A snapped window dragged away gets its old size back (under the pointer, like Windows).
            if let old = restore.removeValue(forKey: d.key), !SnapGeometry.close(old, d.start) {
                let p = NSEvent.mouseLocation
                let frac = (p.x - d.start.minX) / max(1, d.start.width)
                var size = old.size
                var origin = CGPoint(x: p.x - frac * old.width, y: SnapGeometry.mainH - p.y - 14)
                if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(d.window, kAXSizeAttribute as CFString, v) }
                if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(d.window, kAXPositionAttribute as CFString, v) }
            }
        }
        let p = NSEvent.mouseLocation
        guard let s = SnapGeometry.screen(at: p) else { return }
        let fr = s.frame, edge: CGFloat = 6, cornerZone: CGFloat = 80
        let atLeft = p.x <= fr.minX + edge, atRight = p.x >= fr.maxX - edge
        let top = SnapGeometry.usable(s).maxY
        let atTop = p.y >= top - edge
        var z: SnapZone?
        if atLeft || atRight {
            if p.y >= top - cornerZone { z = atLeft ? .topLeft : .topRight }
            else if p.y <= SnapGeometry.usable(s).minY + cornerZone { z = atLeft ? .bottomLeft : .bottomRight }
            else { z = atLeft ? .left : .right }
        } else if atTop {
            if Self.on(SnapSetting.layouts) {
                // Snap layouts drop down at the top; pointing at a zone in them picks it.
                if !flyout.isOpen { flyout.show(below: NSPoint(x: p.x, y: top), screen: s, forDrag: true) { _ in } }
            } else {
                z = .max
            }
        }
        if flyout.isOpen, flyout.forDrag {
            if let hit = flyout.zone(at: p) { z = hit }
            else if !atTop && !flyout.contains(p) { flyout.hide() }
            else if atTop && z == nil { z = .max }
        }
        if let z { dropZone = (z, s); preview.show(SnapGeometry.toCocoa(SnapGeometry.rect(z, on: s))) }
        else { dropZone = nil; preview.hide() }
    }

    private func mouseUp() {
        defer { drag = nil; dropZone = nil; preview.hide(); if flyout.forDrag { flyout.hide() } }
        guard let d = drag, d.moved, let (z, s) = dropZone else { return }
        if restore[d.key] == nil { restore[d.key] = d.start }
        // Let the system finish its own move first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.place(d.window, z, on: s) }
    }

    /// Rest the pointer on a window's green button: snap layouts.
    private func mouseMoved() {
        guard enabled, Self.on(SnapSetting.layouts), !flyout.isOpen || !flyout.forDrag else { return }
        if flyout.isOpen, !flyout.forDrag {
            // Close once the pointer leaves the flyout (and the button it came from).
            if !flyout.contains(NSEvent.mouseLocation) && !flyout.nearAnchor(NSEvent.mouseLocation) { flyout.hide() }
            return
        }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkGreenButton() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func checkGreenButton() {
        guard let (w, el) = windowAtPointer() else { return }
        let sub = AX.string(el, kAXSubroleAttribute)
        guard sub == kAXZoomButtonSubrole || sub == kAXFullScreenButtonSubrole,
              let bf = AX.frame(el), let wf = AX.frame(w), let s = SnapGeometry.screen(ofAX: wf) else { return }
        let below = NSPoint(x: bf.midX, y: SnapGeometry.mainH - bf.maxY)
        flyout.show(below: below, screen: s, forDrag: false, anchor: SnapGeometry.toCocoa(bf)) { [weak self] z in
            self?.place(w, z, on: s)
        }
    }
}

// MARK: Preview, layouts flyout, snap assist

/// The glassy rectangle showing where a dragged window will land.
@MainActor
final class SnapPreview {
    private let panel = FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
    private var shown: CGRect?
    init() {
        panel.ignoresMouseEvents = true
        panel.contentView = ClickThroughHostingView(rootView: SnapPreviewView())
    }
    func show(_ r: CGRect) {
        guard shown != r else { return }
        shown = r
        let target = r.insetBy(dx: 6, dy: 6)
        if !panel.isVisible {
            panel.setFrame(target.insetBy(dx: target.width * 0.1, dy: target.height * 0.1), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.15
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }
    func hide() { shown = nil; panel.orderOut(nil) }
}

struct SnapPreviewView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: BugOSColor.accent).opacity(0.18))
            .background(VisualEffect(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5))
    }
}

/// The snap layouts grid (Windows 11's flyout): six layouts, each zone a button.
@MainActor
final class SnapFlyout {
    private let panel = FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2))
    private var zones: [(SnapZone, CGRect)] = []   // zone, its button in screen coordinates
    private var anchor: CGRect?
    private(set) var forDrag = false
    var isOpen: Bool { panel.isVisible }
    let model = SnapFlyoutModel()

    static let cell = CGSize(width: 64, height: 44)

    func show(below p: NSPoint, screen s: NSScreen, forDrag: Bool, anchor: CGRect? = nil, onPick: @escaping (SnapZone) -> Void) {
        self.forDrag = forDrag
        self.anchor = anchor
        model.hovered = nil
        let cols = 3, rows = 2, pad: CGFloat = 10, gap: CGFloat = 10
        let size = CGSize(width: CGFloat(cols) * Self.cell.width + CGFloat(cols - 1) * gap + pad * 2,
                          height: CGFloat(rows) * Self.cell.height + CGFloat(rows - 1) * gap + pad * 2)
        var origin = CGPoint(x: p.x - size.width / 2, y: p.y - size.height - 6)
        let u = s.visibleFrame
        origin.x = min(max(origin.x, u.minX + 8), u.maxX - size.width - 8)
        origin.y = max(origin.y, u.minY + 8)
        let frame = CGRect(origin: origin, size: size)
        // Where each zone's button is, for hit-testing while dragging.
        zones = []
        for (i, layout) in SnapLayouts.all.enumerated() {
            let c = i % cols, r = i / cols
            let cellRect = CGRect(x: frame.minX + pad + CGFloat(c) * (Self.cell.width + gap),
                                  y: frame.maxY - pad - CGFloat(r + 1) * Self.cell.height - CGFloat(r) * gap,
                                  width: Self.cell.width, height: Self.cell.height)
            for z in layout {
                zones.append((z, CGRect(x: cellRect.minX + z.x * cellRect.width, y: cellRect.maxY - (z.y + z.h) * cellRect.height,
                                        width: z.w * cellRect.width, height: z.h * cellRect.height)))
            }
        }
        panel.contentView = ClickThroughHostingView(rootView: SnapFlyoutView(model: model, onPick: { [weak self] z in
            self?.hide(); onPick(z)
        }))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil); model.hovered = nil }
    func contains(_ p: NSPoint) -> Bool { isOpen && panel.frame.insetBy(dx: -6, dy: -6).contains(p) }
    func nearAnchor(_ p: NSPoint) -> Bool { anchor.map { $0.insetBy(dx: -8, dy: -8).contains(p) } ?? false }

    /// While dragging: the zone under the pointer (and light it up).
    func zone(at p: NSPoint) -> SnapZone? {
        let hit = zones.first { $0.1.insetBy(dx: -1, dy: -1).contains(p) }?.0
        if model.hovered != hit { model.hovered = hit }
        return hit
    }
}

@MainActor
final class SnapFlyoutModel: ObservableObject { @Published var hovered: SnapZone? }

struct SnapFlyoutView: View {
    @ObservedObject var model: SnapFlyoutModel
    let onPick: (SnapZone) -> Void

    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(SnapFlyout.cell.width), spacing: 10), count: 3)
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(SnapLayouts.all.indices, id: \.self) { i in
                ZStack(alignment: .topLeading) {
                    ForEach(SnapLayouts.all[i].indices, id: \.self) { j in
                        let z = SnapLayouts.all[i][j]
                        SnapZoneButton(lit: model.hovered == z) { onPick(z) }
                            .frame(width: z.w * SnapFlyout.cell.width - 3, height: z.h * SnapFlyout.cell.height - 3)
                            .offset(x: z.x * SnapFlyout.cell.width + 1.5, y: z.y * SnapFlyout.cell.height + 1.5)
                            .onHover { if $0 { model.hovered = z } }
                    }
                }
                .frame(width: SnapFlyout.cell.width, height: SnapFlyout.cell.height, alignment: .topLeading)
            }
        }
        .padding(10)
        .background(VisualEffect(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

private struct SnapZoneButton: View {
    let lit: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(lit ? Color(nsColor: BugOSColor.accent) : Color.white.opacity(0.22))
        }
        .buttonStyle(.plain)
    }
}

/// Snap assist: the empty part of the screen shows your other windows; click one to fill it.
@MainActor
final class SnapAssist {
    private let panel = KeyablePanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
    private var monitor: Any?
    private var keyMonitor: Any?

    func show(in r: CGRect, windows: [(TrackedWindow, String, NSImage)], pick: @escaping (TrackedWindow) -> Void) {
        hide()
        let view = SnapAssistView(windows: windows.map { SnapAssistItem(window: $0.0, name: $0.1, icon: $0.2) }) { [weak self] w in
            self?.hide(); pick(w)
        }
        panel.contentView = ClickThroughHostingView(rootView: view)
        panel.setFrame(r.insetBy(dx: 6, dy: 6), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; panel.animator().alphaValue = 1 }
        // Click anywhere else or press Esc: never mind.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.hide() } }
        }
    }

    func hide() {
        for m in [monitor, keyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        monitor = nil; keyMonitor = nil
        panel.orderOut(nil)
    }
}

struct SnapAssistItem: Identifiable {
    let window: TrackedWindow
    let name: String
    let icon: NSImage
    var id: String { window.id }
}

struct SnapAssistView: View {
    let windows: [SnapAssistItem]
    let pick: (TrackedWindow) -> Void
    @State private var thumbs: [String: NSImage] = [:]
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            let pad: CGFloat = 18, gap: CGFloat = 14
            // Two or three across in a half, more in a wide zone; never more than there are windows.
            let cols = max(1, min(windows.count, Int((geo.size.width - pad * 2 + gap) / 300), 4))
            let cardW = (geo.size.width - pad * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Choose a window for this side").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Esc to skip").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardW), spacing: gap), count: cols), spacing: gap) {
                        ForEach(windows) { item in
                            card(item, width: cardW)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(pad)
        }
        // Glass with a dark tint, so the white titles read on any wallpaper or window behind it.
        .background(ZStack { SnapGlass(); Color.black.opacity(0.45) })
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .task {
            for item in windows {
                if let img = Thumbnails.shared.cached(item.window) { thumbs[item.id] = img }
                else if let img = await Thumbnails.shared.capture(item.window) { thumbs[item.id] = img }
            }
        }
    }

    private func card(_ item: SnapAssistItem, width: CGFloat) -> some View {
        let lit = hovered == item.id
        let thumbH = (width - 16) * 0.625
        return Button { pick(item.window) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(nsImage: item.icon).resizable().frame(width: 18, height: 18)
                    Text(item.window.title.isEmpty ? item.name : item.window.title)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25))
                    if let t = thumbs[item.id] {
                        Image(nsImage: t).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                            .padding(4)
                    } else {
                        Image(nsImage: item.icon).resizable().frame(width: 52, height: 52).opacity(0.9)
                    }
                }
                .frame(width: width - 16, height: thumbH)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(lit ? 0.16 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(lit ? Color(nsColor: BugOSColor.accent) : Color.white.opacity(0.08), lineWidth: lit ? 2.5 : 1))
            .scaleEffect(lit ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: lit)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
    }
}

/// Liquid Glass behind snap assist on macOS 26 (a blur before that).
struct SnapGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 16
            g.style = .regular
            return g
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
