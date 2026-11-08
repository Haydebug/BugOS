import AppKit
import ApplicationServices

/// Small Accessibility toolkit for the Save/Open bridge.
enum AXK {
    static func get(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    static func str(_ e: AXUIElement, _ a: String) -> String? { get(e, a) as? String }
    static func kids(_ e: AXUIElement) -> [AXUIElement] { (get(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    static func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) ?? "" }
    static func ident(_ e: AXUIElement) -> String { str(e, kAXIdentifierAttribute) ?? "" }
    static func title(_ e: AXUIElement) -> String { str(e, kAXTitleAttribute) ?? "" }
    static func value(_ e: AXUIElement) -> String { str(e, kAXValueAttribute) ?? "" }
    static func windows(_ pid: pid_t) -> [AXUIElement] {
        (get(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }
    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        get(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
    }
    @discardableResult static func set(_ e: AXUIElement, _ a: String, _ v: AnyObject) -> Bool {
        AXUIElementSetAttributeValue(e, a as CFString, v) == .success
    }
    @discardableResult static func press(_ e: AXUIElement) -> Bool {
        AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }
    /// Frame in Accessibility coordinates (top-left origin of the main screen).
    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = get(e, kAXPositionAttribute), let s = get(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
    /// Convert an Accessibility rect to a Cocoa screen rect (bottom-left origin).
    static func cocoa(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
    /// Bounded breadth-first search; never walks into file lists (thousands of rows).
    static func find(_ root: AXUIElement, maxDepth: Int = 14, limit: Int = 3000, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        while !queue.isEmpty {
            let (e, d) = queue.removeFirst()
            seen += 1
            if seen > limit { return nil }
            if pred(e) { return e }
            let r = role(e)
            if r == kAXOutlineRole || r == kAXTableRole || r == kAXBrowserRole || r == kAXListRole { continue }
            if d < maxDepth { queue += kids(e).map { ($0, d + 1) } }
        }
        return nil
    }

    /// A key press sent through the system (needed: Save panels of sandboxed apps live in another process).
    static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    }

    static var trusted: Bool { AXIsProcessTrusted() }
    static func askForTrust() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
}

/// Apple's Save or Open dialog found inside another app.
struct ApplePanel {
    enum Kind { case save, open }
    let kind: Kind
    let element: AXUIElement     // the sheet or the panel window
    let pid: pid_t

    var frame: CGRect? { AXK.frame(element) }
    var nameField: AXUIElement? { AXK.find(element) { AXK.ident($0) == "saveAsNameTextField" } }
    var okButton: AXUIElement? { AXK.find(element) { AXK.ident($0) == "OKButton" } }
    var cancelButton: AXUIElement? { AXK.find(element) { AXK.ident($0) == "CancelButton" } }
    var whereValue: String { AXK.find(element) { AXK.ident($0) == "where popup" }.map(AXK.value) ?? "" }
    var isOpen: Bool { AXK.frame(element) != nil }
    var prefilledName: String { nameField.map(AXK.value) ?? "" }

    /// Finds a Save/Open dialog in the app: a sheet on a document window, or its own window.
    static func find(in pid: pid_t) -> ApplePanel? {
        for w in AXK.windows(pid) {
            if let p = from(w, pid) { return p }
            for k in AXK.kids(w) where AXK.role(k) == kAXSheetRole as String {
                if let p = from(k, pid) { return p }
            }
        }
        return nil
    }

    private static func from(_ e: AXUIElement, _ pid: pid_t) -> ApplePanel? {
        switch AXK.ident(e) {
        case "save-panel": return ApplePanel(kind: .save, element: e, pid: pid)
        case "open-panel": return ApplePanel(kind: .open, element: e, pid: pid)
        default: return nil
        }
    }
}
