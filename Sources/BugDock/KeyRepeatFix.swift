// Hold a key to repeat it (BugOS › Mouse & keyboard). BugOS turns the Mac's press-and-hold accent menu off
// (ApplePressAndHoldEnabled), but apps read that once when they open, and the accent menu (ł ļ ľ) still came
// up in apps that were already running. Taking the "repeat" mark off the held key wasn't enough: the accent
// menu goes by the key still being down. So while you type in a text field, each of the keyboard's own
// repeats is handed to the app as a quick release and press of that key: the accent menu never sees a held
// key and the letter types again, like on Windows. Outside text fields (games: holding W to walk) a held key
// stays a held key.
import AppKit
import ApplicationServices
import BugOSKit

@MainActor
final class KeyRepeatFix {
    static let shared = KeyRepeatFix()
    private var tap: CFMachPort?

    /// When the switch went on (seconds since 1970), 0 = off.
    static var onSince: Double { UserDefaults.standard.double(forKey: KeyboardSetting.repeatOnSince) }
    /// Whether the key going down landed in a text field (worked out on the main thread at the first press,
    /// well before the first repeat arrives 375ms later).
    nonisolated(unsafe) static var typingInText = false

    func reload() {
        if Self.onSince > 0 { start() } else if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    /// The focused control takes text (a text field, text area, search or combo box, or anything with a caret).
    static func focusIsText() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return false }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.15)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if let r = role as? String, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) { return true }
        var range: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success
    }

    private func start() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { MainActor.assumeIsolated { KeyRepeatFix.shared.reenable() } }
                return Unmanaged.passUnretained(event)
            }
            guard event.flags.intersection([.maskCommand, .maskControl]).isEmpty else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                // A fresh press: is it going into a text field?
                DispatchQueue.main.async { KeyRepeatFix.typingInText = KeyRepeatFix.focusIsText() }
                return Unmanaged.passUnretained(event)
            }
            guard KeyRepeatFix.typingInText,
                  let up = event.copy(), let down = event.copy() else { return Unmanaged.passUnretained(event) }
            // The repeat becomes: key up, then a fresh key down. Posted after this tap, in that order.
            up.type = .keyUp
            up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            up.post(tap: .cgAnnotatedSessionEventTap)
            down.post(tap: .cgAnnotatedSessionEventTap)
            return nil
        }, userInfo: nil)
        guard let tap else { return }
        // Its own thread, like Shift + scroll: every key press passes through here.
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "BugOS key repeat"
        thread.qualityOfService = .userInteractive
        thread.start()
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenable() { if let tap, Self.onSince > 0 { CGEvent.tapEnable(tap: tap, enable: true) } }
}
