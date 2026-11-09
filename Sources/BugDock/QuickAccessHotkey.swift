// A keyboard shortcut for Quick Access (BugOS › Quick Access › Keyboard shortcut; none by default).
// Pressing it opens Quick Access (or closes it); while open: ↑ ↓ to pick, Return to open, Esc to close.
import AppKit
import BugOSKit
import Carbon.HIToolbox

@MainActor
enum QuickAccessHotkey {
    static weak var corner: QuickCornerController?
    private static var ref: EventHotKeyRef?
    private static var installed = false

    static var current: Shortcut? {
        UserDefaults.standard.string(forKey: QuickCornerCatalog.accessShortcutKey).flatMap(Shortcut.init(stored:))
    }

    static func reload() {
        unregister()
        guard let k = current else { return }
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                guard hk.signature == OSType(0x4251_4143) else { return OSStatus(eventNotHandledErr) }   // "BQAC"
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickAccessHotkey.pressed() } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        RegisterEventHotKey(k.keyCode, k.mods, EventHotKeyID(signature: OSType(0x4251_4143), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    static func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    private static func pressed() {
        guard let side = corner?.side else { return }
        if side.isOpen { side.close() } else { side.open(withKeyboard: true) }
    }
}
