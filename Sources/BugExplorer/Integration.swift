import AppKit
import BugOSKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// System-wide shortcut (like Win+E): ⌥⌘E opens a new BugExplorer window from anywhere.
/// Uses Carbon hot keys, which need no Accessibility permission.
enum GlobalHotkey {
    static var onPress: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var installed = false

    static func register() {
        guard ref == nil else { return }
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { GlobalHotkey.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = EventHotKeyID(signature: OSType(0x4245_5850), id: 1)   // "BEXP"
        guard let k = current else { return }   // turned off on the BugOS page
        RegisterEventHotKey(k.keyCode, k.mods, id, GetApplicationEventTarget(), 0, &ref)
    }

    /// The shortcut from BugOS › File Explorer (⌥⌘E unless changed; none if cleared).
    static var current: Shortcut? {
        guard let s = UserDefaults.standard.string(forKey: ExplorerSetting.newWindowShortcut) else {
            return ExplorerSetting.defaultNewWindowShortcut
        }
        return Shortcut(stored: s)
    }

    static func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    static func reload() {
        unregister()
        register()
    }
}

/// Make BugExplorer (or Finder again) the app that opens folders system-wide.
enum FolderHandler {
    static let finder = "com.apple.finder"

    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func set(_ useBugExplorer: Bool, done: ((Error?) -> Void)? = nil) {
        let target: URL?
        if useBugExplorer { target = Bundle.main.bundleURL }
        else { target = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finder) }
        guard let target else { done?(nil); return }
        NSWorkspace.shared.setDefaultApplication(at: target, toOpen: .folder) { err in
            DispatchQueue.main.async { done?(err) }
        }
    }
}
