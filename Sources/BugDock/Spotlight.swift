import AppKit
import CoreGraphics

/// Opens Spotlight by sending its keyboard shortcut (there's no public "show Spotlight" API).
/// Reads the user's configured shortcut so it still works if they've rebound it.
enum Spotlight {
    static func open() {
        let (keyCode, flags) = shortcut()
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Symbolic hotkey 64 = "Show Spotlight search". Default ⌘Space.
    private static func shortcut() -> (CGKeyCode, CGEventFlags) {
        let fallback: (CGKeyCode, CGEventFlags) = (49, .maskCommand)
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all["64"] as? [String: Any],
              (entry["enabled"] as? Bool) ?? true,
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Int], params.count >= 3,
              params[1] >= 0, params[1] < 0xFFFF
        else { return fallback }
        // The modifier values here match CGEventFlags bit-for-bit (⌘ = 0x100000, etc.).
        let mask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue
        return (CGKeyCode(params[1]), CGEventFlags(rawValue: UInt64(params[2]) & mask))
    }
}
