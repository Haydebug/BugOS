// Alt+Enter toggles full screen, like Windows (BugOS › Full Screen; off by default, ⌥↩ unless changed).
// Puts the window you're in into the Mac's real full screen (its own desktop), or back out of it.
import AppKit
import BugOSKit
import Carbon.HIToolbox

@MainActor
enum FullScreenHotkey {
    private static var ref: EventHotKeyRef?
    private static var installed = false

    static var enabled: Bool { UserDefaults.standard.bool(forKey: FullScreenSetting.altEnter) }
    static var current: Shortcut? {
        guard let s = UserDefaults.standard.string(forKey: FullScreenSetting.altEnterShortcut) else { return FullScreenSetting.defaultShortcut }
        return Shortcut(stored: s)
    }

    static func reload() {
        unregister()
        guard enabled, let k = current else { return }
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                guard hk.signature == OSType(0x4246_5343) else { return OSStatus(eventNotHandledErr) }   // "BFSC"
                DispatchQueue.main.async { MainActor.assumeIsolated { FullScreenHotkey.toggle() } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        RegisterEventHotKey(k.keyCode, k.mods, EventHotKeyID(signature: OSType(0x4246_5343), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    static func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    /// The front app's focused window into or out of full screen.
    static func toggle() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let win = WindowReader.focusedWindow(pid: app.processIdentifier) else { return }
        let isFull = AX.bool(win, "AXFullScreen") ?? false
        let r = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, (isFull ? kCFBooleanFalse : kCFBooleanTrue)!)
        WindowTracker.log("alt-enter: \(app.localizedName ?? "?") \(isFull ? "leave" : "enter") full screen -> \(r.rawValue)")
    }
}
