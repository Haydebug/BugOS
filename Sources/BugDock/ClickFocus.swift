// Windows-style click focus (BugOS › Mouse & keyboard, on by default). On Windows any mouse button pressed on a
// background window brings it to the front and the press still lands; the Mac only does that for the left
// button. For right and middle presses we hold back the press (plus its drags and release), bring the window
// forward, wait until the app is really in front, then replay everything in order. Holding is what keeps
// context menus open and camera drags (Roblox Studio's right-drag) intact.
// Moved here from the separate MacUtilities app (2026-11-12) so it's all one app.
import AppKit
import ApplicationServices
import BugOSKit

@MainActor
final class ClickFocus {
    static let shared = ClickFocus()
    private static let replayTag: Int64 = 0x57434C4B
    private var tap: CFMachPort?
    private var holdingButton: Int64?
    private var held: [CGEvent] = []
    private static let downs: [CGEventType] = [.rightMouseDown, .otherMouseDown]
    private static let follow: [CGEventType] = [.rightMouseDragged, .rightMouseUp, .otherMouseDragged, .otherMouseUp]

    static var enabled: Bool { UserDefaults.standard.object(forKey: MouseSetting.clickFocus) as? Bool ?? true }

    /// Follow the setting.
    func reload() {
        if Self.enabled { start() } else { stop() }
    }

    private func start() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return }
        let mask = (Self.downs + Self.follow).reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = ClickFocus.shared.tap, ClickFocus.enabled { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard let out = ClickFocus.shared.handle(type, event) else { return nil }
                return Unmanaged.passUnretained(out)
            }
        }, userInfo: nil)
        guard let tap else { NSLog("BugDock: click focus needs Accessibility"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        replay()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag { return event }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if let hb = holdingButton {
            if button == hb, let c = event.copy() { held.append(c); return nil }
            return event
        }
        guard Self.downs.contains(type), let (app, win) = target(at: event.location), let c = event.copy() else { return event }
        holdingButton = button; held = [c]
        DispatchQueue.main.async { [self] in
            bringForward(app, win)
            // Wait (≤ ~300 ms) until the app is really in front, then replay. Keep this as short as possible: apps
            // like Roblox Studio ignore a replayed press for focus if the physical button has already been released.
            var tries = 0
            func check() {
                tries += 1
                if app.isActive || tries >= 15 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.replay() } }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check) }
            }
            check()
        }
        return nil
    }

    /// The app + window that would receive a click here, if it's a normal window of an app that isn't in front.
    private func target(at p: CGPoint) -> (NSRunningApplication, AXUIElement)? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &hit) == .success, let el = hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid), !app.isActive,
              let win = Self.window(of: el) else { return nil }
        return (app, win)
    }

    /// The window an element lives in. Some apps (Roblox Studio's viewport) don't answer AXWindow, so walk parents too.
    private static func window(of el: AXUIElement) -> AXUIElement? {
        func role(_ e: AXUIElement) -> String? { AX.string(e, kAXRoleAttribute) }
        if role(el) == kAXWindowRole { return el }
        if let w = AX.element(el, kAXWindowAttribute), role(w) == kAXWindowRole { return w }
        var e = el
        for _ in 0..<30 {
            let r = role(e)
            if r == kAXWindowRole { return e }
            if r == kAXApplicationRole { return nil }
            guard let parent = AX.element(e, kAXParentAttribute) else { return nil }
            e = parent
        }
        return nil
    }

    private func bringForward(_ app: NSRunningApplication, _ w: AXUIElement) {
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(AX.app(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if !app.isActive { app.activate() }
    }

    private func replay() {
        for e in held { e.setIntegerValueField(.eventSourceUserData, value: Self.replayTag); e.post(tap: .cgSessionEventTap) }
        held.removeAll(); holdingButton = nil
    }
}
