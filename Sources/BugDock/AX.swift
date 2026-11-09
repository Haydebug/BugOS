import AppKit
import ApplicationServices

/// Thin wrappers over the public Accessibility (AXUIElement) API.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        value(el, name) as? String
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        (value(el, name) as? NSNumber)?.boolValue
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (value(el, name) as? [AXUIElement]) ?? []
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        guard let v = value(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Window frame in global top-left-origin coordinates (same space ScreenCaptureKit uses).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let s = size(el), let v = value(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, (value as CFBoolean)) == .success
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        // Never let a hung app freeze the taskbar.
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }
}

/// One real window of an app.
struct TrackedWindow: Identifiable, Equatable {
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let isMinimized: Bool
    /// Where it was when last read (top-left global, like AX), and whether it was full screen. Not part of ==:
    /// moving a window doesn't change its button.
    var frame: CGRect? = nil
    var fullScreen = false

    var id: String { "\(pid)-\(CFHash(element))" }

    static func == (a: TrackedWindow, b: TrackedWindow) -> Bool {
        a.pid == b.pid && a.title == b.title && a.isMinimized == b.isMinimized && CFEqual(a.element, b.element)
    }
}

enum WindowReader {
    /// Standard windows of a process, front-to-back, limited to the CURRENT desktop like Windows' taskbar.
    /// AX can also report windows on other Spaces (Chrome does), so a window is kept only if it's
    /// minimized, its app is hidden (hidden windows aren't on screen anywhere, so their Space is
    /// unknowable), or it matches a window that's on screen right now (`onScreen`, from WindowMatch).
    static func windows(pid: pid_t, onScreen: [WindowMatch.CGWin], appHidden: Bool) -> [TrackedWindow] {
        let all = windows(pid: pid)
        if appHidden { return all }
        let visible = all.enumerated().compactMap { i, w -> (Int, CGRect)? in
            guard !w.isMinimized, let f = w.frame else { return nil }
            return (i, f)
        }
        let matched = WindowMatch.assign(ax: visible.map { ($0.1, all[$0.0].title) }, cg: onScreen)
        var keep = Set(matched.keys.map { visible[$0].0 })
        for (i, w) in all.enumerated() where w.isMinimized || w.frame == nil { keep.insert(i) }
        // Full-screen windows live on their own desktop, so they're never "on screen" from anywhere else;
        // keep them, or the app drops off the taskbar whenever you're not in it (Roblox, games, videos).
        for (i, w) in all.enumerated() where w.fullScreen { keep.insert(i) }
        return all.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }

    /// What the taskbar reads from each window, asked for in ONE round trip to the app
    /// (AXUIElementCopyMultipleAttributeValues) instead of one per attribute (it was ~10 per window).
    private static let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXSizeAttribute, kAXPositionAttribute,
                                kAXTitleAttribute, kAXMinimizedAttribute, "AXFullScreen"] as CFArray

    /// Every standard window AX reports for a process (may include other Spaces).
    static func windows(pid: pid_t) -> [TrackedWindow] {
        let app = AX.app(pid)
        return AX.elements(app, kAXWindowsAttribute).compactMap { w in
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(w, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let v = raw as? [AnyObject], v.count == 7 else { return nil }
            func ax<T>(_ i: Int, _ type: AXValueType, _ empty: T) -> T? {
                let o = v[i] as CFTypeRef
                guard CFGetTypeID(o) == AXValueGetTypeID(), AXValueGetType(o as! AXValue) == type else { return nil }
                var out = empty
                return AXValueGetValue(o as! AXValue, type, &out) ? out : nil
            }
            guard v[0] as? String == kAXWindowRole else { return nil }
            let sub = v[1] as? String
            guard sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole else { return nil }
            let size = ax(2, .cgSize, CGSize.zero)
            if let s = size, s.width < 60 || s.height < 40 { return nil }
            let pos = ax(3, .cgPoint, CGPoint.zero)
            return TrackedWindow(
                element: w,
                pid: pid,
                title: v[4] as? String ?? "",
                isMinimized: (v[5] as? NSNumber)?.boolValue ?? false,
                frame: size.flatMap { s in pos.map { CGRect(origin: $0, size: s) } },
                fullScreen: (v[6] as? NSNumber)?.boolValue ?? false
            )
        }
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        AX.element(AX.app(pid), kAXFocusedWindowAttribute)
    }
}

/// Window / app actions, all through public APIs.
@MainActor
enum WindowActions {
    static func focus(_ w: TrackedWindow) {
        let app = NSRunningApplication(processIdentifier: w.pid)
        if app?.isHidden == true { app?.unhide() }
        if w.isMinimized { AX.set(w.element, kAXMinimizedAttribute, false) }
        AX.set(AX.app(w.pid), kAXFrontmostAttribute, true)
        AX.set(w.element, kAXMainAttribute, true)
        AX.perform(w.element, kAXRaiseAction)
        app?.activate()
    }

    /// Open a new window of a running app on this desktop by pressing its own "New Window" menu item (File ›
    /// New Window, New Finder Window…; not private/incognito ones). False if it has none.
    @discardableResult
    static func newWindowHere(pid: pid_t) -> Bool {
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return false }
        for top in AX.elements(bar, kAXChildrenAttribute) {
            for menu in AX.elements(top, kAXChildrenAttribute) {
                for item in AX.elements(menu, kAXChildrenAttribute) {
                    guard let t = AX.string(item, kAXTitleAttribute), t.hasPrefix("New"), t.contains("Window"),
                          !t.localizedCaseInsensitiveContains("private"), !t.localizedCaseInsensitiveContains("incognito"),
                          AX.bool(item, kAXEnabledAttribute) != false else { continue }
                    return AX.perform(item, kAXPressAction)
                }
            }
        }
        return false
    }

    static func minimize(_ w: TrackedWindow) {
        AX.set(w.element, kAXMinimizedAttribute, true)
    }

    static func close(_ w: TrackedWindow) {
        if let button = AX.element(w.element, kAXCloseButtonAttribute) {
            AX.perform(button, kAXPressAction)
        }
    }

    /// Launch, or "reopen" (what the Dock does: brings it forward, makes a window if it has none).
    static func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    static func newInstance(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }
}
