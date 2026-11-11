// Shared by BugOS and its three parts (BugDock, File Explorer, Squiggle).
import AppKit
import Carbon.HIToolbox

/// Bundle ids, and the names of the notifications BugOS and its parts talk with.
public enum BugOSID {
    public static let os = "com.bugos.os"
    public static let dock = "com.bugos.dock"
    public static let explorer = "com.bugos.explorer"
    public static let squiggle = "com.bugos.squiggle"
    /// Commands for the running BugOS (`object` is the command, userInfo["paths"] optional).
    public static let command = Notification.Name("com.bugos.os.command")
    /// BugOS changed one of BugDock's settings (from the BugOS page).
    public static let dockSettingsChanged = Notification.Name("com.bugos.dock.settings")
    /// … File Explorer's / Squiggle's settings.
    public static let explorerSettingsChanged = Notification.Name("com.bugos.explorer.settings")
    public static let squiggleSettingsChanged = Notification.Name("com.bugos.squiggle.settings")
    /// The LaunchAgent that starts BugOS at login.
    public static let loginAgentLabel = "com.bugos.os"
}

/// BugDock settings the BugOS page can change (stored in BugDock's preferences).
public enum DockSetting {
    public static let showNowPlaying = "showNowPlaying"
    /// Your own Spotify app's client id, for "Connect Spotify" (liking songs). Not built into the app.
    public static let spotifyClientID = "spotifyClientID"
    /// "small" | "medium" (default) | "large".
    public static let barSize = "barSize"
    /// "center" (default) | "left".
    public static let barAlignment = "barAlignment"
    /// "clear" (default) | "translucent" | "solid".
    public static let barBackground = "barBackground"
    /// 0…1, how opaque the background is (default 0.8).
    public static let barOpacity = "barOpacity"
    /// "#RRGGBB" colour of the background (missing = dark grey).
    public static let barTint = "barTint"
    /// "full" (default, edge to edge) | "floating" (a rounded bar with a gap around it).
    public static let barShape = "barShape"
    /// Corner radius of the floating bar (default 14).
    public static let barCorner = "barCorner"
    /// Under each running app: "pill" (default) | "dot" | "line" | "none".
    public static let indicator = "indicator"
    /// Window previews when the pointer rests on a taskbar button (default on).
    public static let showPreviews = "showPreviews"
    /// Seconds before a preview appears (default 0.35).
    public static let previewDelay = "previewDelay"
    /// Which windows the taskbar shows: "this" (default: only the desktop you're on, like Windows) or "all"
    /// (every desktop, like the Mac Dock: nothing changes when you switch desktops).
    public static let appsFromDesktops = "appsFromDesktops"
    /// With "This desktop": opening an app stays on this desktop (a new window here) instead of jumping to
    /// another desktop where it has windows. Default on.
    public static let stayOnDesktop = "stayOnDesktop"
    /// A taskbar on every display, not just the main one (default on).
    public static let allDisplays = "barAllDisplays"
    /// With "all displays" off, which screen the one taskbar is on: "primary" (default, the menu-bar screen)
    /// or a display's UUID (`BugOSDisplay.uuid`). Falls back to the primary screen while that one's unplugged.
    public static let barDisplay = "barDisplay"
    /// With several taskbars, which apps each shows: "all" (default, every app on every bar) or "where"
    /// (the bars of the screens its windows are on; pinned apps on the main bar).
    public static let barAppsOn = "barAppsOn"
    /// Handoff from an iPhone/iPad (the Dock's Handoff icon): "island" (default, its own little island in the
    /// taskbar's right corner) | "apps" (after the app icons, like the Mac Dock) | "off".
    public static let handoffPlacement = "handoffPlacement"
    /// The small iPhone/iPad badge on the Handoff icon (default on).
    public static let handoffBadge = "handoffBadge"
    /// A glass background behind the Handoff island (default on).
    public static let handoffGlass = "handoffGlass"
}

/// Stable ids for displays (CGDirectDisplayIDs can change after a restart or replug; UUIDs don't).
public enum BugOSDisplay {
    public static func id(_ s: NSScreen) -> CGDirectDisplayID {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
    public static func uuid(_ s: NSScreen) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id(s))?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }
}

/// Squiggle settings the BugOS page can change (stored in Squiggle's preferences).
public enum SquiggleSetting {
    /// Folder screenshots are saved to (default ~/Desktop/Screenshots); recordings go in its Recordings folder.
    public static let saveFolder = "saveFolder"
    /// [action id: Shortcut.stored] — a missing action uses its default, "" means no shortcut.
    public static let shortcuts = "shortcuts"
    /// The snip thumbnail in the bottom-right after a snip (default on).
    public static let showThumbnail = "showThumbnail"
    public static let recordMic = "mic"
    public static let recordSystemAudio = "sysAudio"

    public static var defaultFolder: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Screenshots") }
}

/// A part normally runs as a child process of BugOS (BugOS.app/Contents/MacOS/BugOS), so macOS files
/// its permissions under "BugOS". Opened any other way (Spotlight, Finder, "Open With"), it hands
/// itself to BugOS and quits before asking macOS for anything.
public enum BugOSChild {
    /// Started by BugOS (it sets this in our environment).
    public static var isChild: Bool { ProcessInfo.processInfo.environment["BUGOS_CHILD"] == "1" }

    /// The BugOS app this part lives in (…/BugOS.app/Contents/Applications/<part>.app).
    public static var bugOSURL: URL? {
        let applications = Bundle.main.bundleURL.deletingLastPathComponent()
        let contents = applications.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard applications.lastPathComponent == "Applications", contents.lastPathComponent == "Contents",
              app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == BugOSID.os else { return nil }
        return app
    }

    /// Inside BugOS but not started by it: this copy must not run.
    public static var shouldHandOff: Bool { !isChild && bugOSURL != nil }

    /// Ask the running BugOS to do `command` ("setup", "start:explorer", "open" + paths…),
    /// starting BugOS if it isn't running.
    public static func send(_ command: String, paths: [String] = []) {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: BugOSID.os).isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                BugOSID.command, object: command, userInfo: paths.isEmpty ? nil : ["paths": paths], deliverImmediately: true)
            return
        }
        guard let url = bugOSURL else { return }
        var args: [String]
        if command == "open" { args = ["--open"] + paths }
        else if command.hasPrefix("start:") { args = ["--start", String(command.dropFirst(6))] }
        else { args = ["--" + command] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.path, "--args"] + args
        try? p.run()
        p.waitUntilExit()
    }

    /// Hand this part to BugOS and quit.
    public static func handOff(_ command: String, paths: [String] = []) -> Never {
        send(command, paths: paths)
        exit(0)
    }
}

/// The shortcuts in BugDock's bottom-right quick corner, and how the BugOS page arranges them.
/// The first item sits nearest the corner (the page lists them the other way up, like the fan looks).
/// Stored in BugDock's preferences. Apps you add are entries with id "app:<path>".
public enum QuickCornerCatalog {
    public struct Entry: Identifiable, Hashable {
        public let id: String
        public let label: String
        public let symbol: String
        /// An app, file or folder you added (shown with its own icon), or nil for a built-in shortcut.
        public var appPath: String? { id.hasPrefix("app:") ? String(id.dropFirst(4)) : nil }
    }
    public static let all: [Entry] = [
        Entry(id: "finder", label: "File Explorer", symbol: "folder.fill"),
        Entry(id: "missioncontrol", label: "Mission Control", symbol: "rectangle.3.group.fill"),
        Entry(id: "screenshot", label: "Squiggle", symbol: "scribble.variable"),
        Entry(id: "music", label: "Music", symbol: "music.note"),
        Entry(id: "ai", label: "AI app", symbol: "sparkles"),
        Entry(id: "browser", label: "Browser", symbol: "globe"),
        Entry(id: "discord", label: "Discord", symbol: "bubble.left.and.bubble.right.fill"),
        Entry(id: "activity", label: "Activity Monitor", symbol: "waveform.path.ecg"),
        Entry(id: "apps", label: "All apps", symbol: "square.grid.3x3.fill"),
        Entry(id: "spotlight", label: "Search", symbol: "magnifyingglass"),
        Entry(id: "bugos", label: "BugOS Settings", symbol: "switch.2"),
        Entry(id: "settings", label: "System Settings", symbol: "gearshape.fill"),
        // Last = top: in Quick Access (which hides the two settings) a swipe in and release flips apps.
        Entry(id: "recent", label: "Recent", symbol: "clock"),
    ]
    public static let orderKey = "quickCornerOrder"
    public static let hiddenKey = "quickCornerHidden"
    /// Paths of apps, files and folders you added with + on the BugOS page.
    public static let appsKey = "quickCornerApps"
    /// "#RRGGBB" tint for the shortcut tiles (missing = plain glass) and for their icons (missing = white).
    public static let tileColorKey = "quickCornerTileColor"
    /// Two fingers up from the trackpad's bottom-right corner open the fan (default on); corner size 0.15…0.4.
    public static let gestureKey = "quickCornerGesture"
    /// Keyboard shortcut that opens Quick Access (Shortcut.stored; missing or "" = none, the default).
    public static let accessShortcutKey = "quickAccessShortcut"
    /// How much the fan curves away from the screen edge: 0 straight … 1 (default) … 2.
    public static let curveKey = "quickCornerCurve"
    /// Where the pointer has to land to open the fan: "auto" (default: a strip along whichever edge
    /// is a wall, so a screen below or to the right doesn't swallow the corner), "corner" (the exact
    /// 4pt corner), "right" (the bottom of the right edge) or "bottom" (the right end of the bottom edge).
    public static let hitAreaKey = "quickCornerHitArea"
    public static let hitAreas: [(String, String)] = [
        ("auto", "Automatic"), ("corner", "Exact corner"), ("right", "Bottom of right edge"), ("bottom", "Right end of bottom edge"),
    ]
    /// Which app the Music shortcut opens (bundle id; default Spotify, or Apple Music without it).
    public static let musicAppKey = "quickCornerMusicApp"
    /// Which app the AI shortcut opens (bundle id; default Claude). Shared by the quick corner and Quick Access.
    public static let aiAppKey = "quickCornerAIApp"
    /// Which browser the Browser shortcut opens: "default" (the Mac's default browser) or a bundle id.
    public static let browserAppKey = "quickCornerBrowserApp"
    public static let browsers: [(id: String, name: String)] = [
        ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"), ("company.thebrowser.Browser", "Arc"),
        ("org.mozilla.firefox", "Firefox"), ("com.microsoft.edgemac", "Edge"), ("com.brave.Browser", "Brave"),
        ("com.operasoftware.Opera", "Opera"),
    ]

    /// The AI shortcut's name: the app it opens.
    public static var aiName: String {
        let id = UserDefaults.standard.string(forKey: aiAppKey) ?? "com.anthropic.claudefordesktop"
        return aiApps.first { $0.id == id }?.name ?? "AI"
    }
    public static let aiApps: [(id: String, name: String)] = [
        ("com.anthropic.claudefordesktop", "Claude"), ("com.openai.codex", "Codex"), ("com.openai.chat", "ChatGPT"),
    ]
    public static let gestureZoneKey = "quickCornerGestureZone"
    /// Turn off macOS's swipe-in-from-the-right for Notification Center while the gesture is on (default on).
    public static let muteSwipeKey = "quickCornerMuteNotificationSwipe"
    /// How many fingers the gesture takes: 2, 3 or 4 (default 4).
    public static let gestureFingersKey = "quickCornerGestureFingers"
    public static let iconColorKey = "quickCornerIconColor"

    /// Where a list of shortcuts is kept. The quick corner (the fan from the bottom-right corner) and Quick
    /// Access (the column the trackpad swipe brings in) each have their own order, hidden items and added apps.
    public struct List: Sendable {
        public let order: String, hidden: String, apps: String
        /// Until you arrange them: the order (nearest the corner / bottom first) and what's hidden.
        public let defaultOrder: [String]
        public let defaultHidden: [String]
    }
    /// The fan, from the corner up: File Explorer … System Settings.
    public static let corner = List(order: orderKey, hidden: hiddenKey, apps: appsKey,
                                    defaultOrder: ["finder", "missioncontrol", "screenshot", "music", "browser", "activity",
                                                   "apps", "spotlight", "bugos", "settings"],
                                    defaultHidden: ["recent", "ai", "discord"])
    /// Quick Access, top to bottom: Recent, Music, Browser, Squiggle, Search, All apps, Activity Monitor,
    /// Mission Control, File Explorer (stored bottom first).
    public static let access = List(order: "quickAccessOrder", hidden: "quickAccessHidden", apps: "quickAccessApps",
                                    defaultOrder: ["finder", "missioncontrol", "activity", "apps", "spotlight", "screenshot",
                                                   "browser", "music", "recent"],
                                    defaultHidden: ["settings", "bugos", "ai", "discord"])

    public static func appEntry(_ path: String) -> Entry {
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return Entry(id: "app:" + path, label: name, symbol: "app")
    }

    /// Every entry (built-in and added apps) in the saved order; new ones go on the end (the top of the fan).
    public static func ordered(_ saved: [String]?, apps: [String] = [], defaultOrder: [String] = []) -> [Entry] {
        let everything = all + apps.map(appEntry)
        let saved = saved ?? []
        let known = saved.compactMap { id in everything.first { $0.id == id } }
        let rest = everything.filter { !saved.contains($0.id) }
        // Not arranged yet: the list's default order (shortcuts it leaves out go nearest the corner, hidden by
        // default), with added apps just under the top two.
        if saved.isEmpty {
            let builtIns = all.map(\.id)
            let listed = defaultOrder.compactMap { id in rest.first { $0.id == id } }
            let others = rest.filter { builtIns.contains($0.id) && !defaultOrder.contains($0.id) }
            let base = others + (defaultOrder.isEmpty ? rest.filter { builtIns.contains($0.id) } : listed)
            let added = rest.filter { !builtIns.contains($0.id) }
            return base.dropLast(2) + added + base.suffix(2)
        }
        // A built-in shortcut that's new since you arranged them goes right after its neighbour in the default
        // order (Music after Squiggle), not on top. Added apps go on the end (the top of the fan).
        var result = known
        for e in rest {
            if let i = all.firstIndex(where: { $0.id == e.id }), i > 0,
               let after = result.firstIndex(where: { $0.id == all[i - 1].id }) {
                result.insert(e, at: after + 1)
            } else {
                result.append(e)
            }
        }
        return result
    }
}

/// A global keyboard shortcut (Carbon hot key): key code + Carbon modifier mask, plus how to show it.
public struct Shortcut: Equatable, Hashable {
    public var keyCode: UInt32
    public var mods: UInt32
    public var label: String   // the key alone, e.g. "E", "F13", "Space"

    public init(keyCode: UInt32, mods: UInt32, label: String) {
        self.keyCode = keyCode; self.mods = mods; self.label = label
    }
    public init(_ keyCode: Int, _ mods: Int) {
        self.init(keyCode: UInt32(keyCode), mods: UInt32(mods), label: Shortcut.keyName(UInt16(keyCode), chars: nil))
    }

    /// "keyCode:mods:label"
    public var stored: String { "\(keyCode):\(mods):\(label)" }
    public init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.init(keyCode: k, mods: m, label: String(parts[2]))
    }

    /// "⌃⌥⇧⌘E"
    public var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    /// From a key press. Nil for a key that can't be a global shortcut on its own (letters without
    /// ⌘/⌃/⌥); function keys work alone.
    public init?(event e: NSEvent) {
        var m: UInt32 = 0
        let f = e.modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        let isFn = Shortcut.functionKeys[e.keyCode] != nil
        guard isFn || m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(e.keyCode), mods: m, label: Shortcut.keyName(e.keyCode, chars: e.charactersIgnoringModifiers))
    }

    static let functionKeys: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12", UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14",
        UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]
    static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "Esc", UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "Home", UInt16(kVK_End): "End", UInt16(kVK_PageUp): "PgUp", UInt16(kVK_PageDown): "PgDn",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7",
        UInt16(kVK_ANSI_8): "8", UInt16(kVK_ANSI_9): "9", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_S): "S",
        UInt16(kVK_ANSI_V): "V",
    ]
    static func keyName(_ code: UInt16, chars: String?) -> String {
        if let f = functionKeys[code] { return f }
        if let n = namedKeys[code] { return n }
        if let c = chars?.uppercased(), !c.isEmpty, !c.contains(":") { return c }
        return "#\(code)"
    }
}

/// Global shortcuts the BugOS page can change. `defaults` may hold several per action.
public struct ShortcutAction: Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let defaults: [Shortcut]
}

public enum SquiggleShortcuts {
    public static let actions: [ShortcutAction] = [
        ShortcutAction(id: "selector", title: "Snip or Record bar", detail: "The full bar: area, window or screen, snip or record.",
                       defaults: [Shortcut(kVK_ANSI_5, cmdKey | shiftKey), Shortcut(kVK_F13, 0)]),
        ShortcutAction(id: "area", title: "Snip an area", detail: "Drag a box; the snip is copied.",
                       defaults: [Shortcut(kVK_ANSI_3, cmdKey | shiftKey)]),
        ShortcutAction(id: "drawInPlace", title: "Snip & draw in place", detail: "The editor opens right over what you snipped.",
                       defaults: [Shortcut(kVK_ANSI_4, cmdKey | shiftKey)]),
        ShortcutAction(id: "quickArea", title: "Quick area snip", detail: "The Mac's own area picker; copied straight away.",
                       defaults: [Shortcut(kVK_ANSI_2, cmdKey | shiftKey)]),
        ShortcutAction(id: "fullScreen", title: "Snip the whole screen", detail: "No picker: the screen under the pointer.",
                       defaults: []),
        ShortcutAction(id: "record", title: "Record an area", detail: "Starts the bar in Record mode. Press again to stop.",
                       defaults: []),
    ]

    /// Each action's shortcuts from Squiggle's saved [id: "a|b"] value ("" = none).
    public static func resolve(_ saved: [String: String]) -> [String: [Shortcut]] {
        var r: [String: [Shortcut]] = [:]
        for a in actions {
            if let s = saved[a.id] { r[a.id] = s.split(separator: "|").compactMap { Shortcut(stored: String($0)) } }
            else { r[a.id] = a.defaults }
        }
        return r
    }
    public static func encode(_ list: [Shortcut]) -> String { list.map(\.stored).joined(separator: "|") }
}

public enum ExplorerSetting {
    /// File Explorer is showing dark (its Appearance is Dark, or Auto while the Mac is dark). Readable from any part.
    /// App icon (taskbar, Dock, ⌘-Tab): "auto" (default, follows File Explorer's appearance) | "light" | "dark".
    public static let iconStyle = "iconStyle"
    /// Whether File Explorer's icon is the black one (AppIconDark.icns).
    public static var iconIsDark: Bool {
        CFPreferencesAppSynchronize(BugOSID.explorer as CFString)
        switch CFPreferencesCopyAppValue(iconStyle as CFString, BugOSID.explorer as CFString) as? String {
        case "dark": return true
        case "light": return false
        default: return isDark
        }
    }
    public static var isDark: Bool {
        CFPreferencesAppSynchronize(BugOSID.explorer as CFString)
        let a = CFPreferencesCopyAppValue("appearance" as CFString, BugOSID.explorer as CFString) as? String ?? "system"
        if a == "dark" { return true }
        if a == "light" { return false }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Stored Shortcut for "new File Explorer window" ("" = none; missing = ⌥⌘E).
    public static let newWindowShortcut = "newWindowShortcut"
    public static let defaultNewWindowShortcut = Shortcut(kVK_ANSI_E, cmdKey | optionKey)
    /// Where new windows open: "home:" (default), "thismac:", or a folder path.
    public static let startLocation = "startLocation"
    /// "windows" (default: a file shows the icon of the app that opens it) | "mac" (macOS document icons).
    public static let fileIcons = "fileIcons"
    /// Navigation pane sections you've hidden: home, applications, icloud, quickAccess, thisMac, network, recycleBin.
    public static let navHidden = "navHidden"
    /// Your order for them (missing = the order below).
    public static let navOrder = "navOrder"
    /// The sections in your order (new ones at the end).
    public static func orderedNavSections(_ saved: [String]?) -> [(id: String, title: String, symbol: String)] {
        let saved = saved ?? []
        return saved.compactMap { id in navSections.first { $0.id == id } } + navSections.filter { !saved.contains($0.id) }
    }
    public static let navSections: [(id: String, title: String, symbol: String)] = [
        ("home", "Home", "house.fill"), ("applications", "Applications", "square.grid.3x3.fill"),
        ("icloud", "iCloud Drive", "icloud.fill"), ("quickAccess", "Quick access (pinned folders)", "pin.fill"),
        ("thisMac", "This Mac (drives)", "laptopcomputer"), ("network", "Network", "network"),
        ("recycleBin", "Recycle Bin", "trash"),
    ]
    /// "windows" (default) | "mica" | "glass".
    public static let theme = "theme"
    /// "system" (default) | "light" | "dark".
    public static let appearance = "appearance"
    /// Mica / Liquid Glass tint: "#RRGGBB" (missing = none) and how strong (0…0.6, default 0.2).
    public static let glassTint = "glassTint"
    public static let glassTintStrength = "glassTintStrength"
    /// Folders that open in Finder open in File Explorer instead (default on).
    public static let openFolders = "openFolders"
    /// The first window brings back the tabs you had open (default on).
    public static let restoreTabs = "restoreTabs"
}

/// Colours the BugOS page lets you pick, stored as "#RRGGBB" (or "#RRGGBBAA") strings.
public enum BugOSColor {
    /// BugOS › General › Accent colour, saved into every part's preferences. Missing = the Mac's accent.
    public static let accentKey = "accentColor"

    public static var accent: NSColor {
        UserDefaults.standard.string(forKey: accentKey).flatMap(color(hex:)) ?? .controlAccentColor
    }

    public static func color(hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let has = h.count == 8
        let r = CGFloat((v >> (has ? 24 : 16)) & 0xff) / 255
        let g = CGFloat((v >> (has ? 16 : 8)) & 0xff) / 255
        let b = CGFloat((v >> (has ? 8 : 0)) & 0xff) / 255
        let a = has ? CGFloat(v & 0xff) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        let r = Int((s.redComponent * 255).rounded()), g = Int((s.greenComponent * 255).rounded()), b = Int((s.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Ready-made swatches for the page.
    public static let swatches: [(name: String, hex: String)] = [
        ("Blue", "#0A84FF"), ("Purple", "#BF5AF2"), ("Pink", "#FF375F"), ("Red", "#FF453A"), ("Orange", "#FF9F0A"),
        ("Yellow", "#FFD60A"), ("Green", "#30D158"), ("Mint", "#63E6E2"), ("Teal", "#40C8E0"), ("Indigo", "#5E5CE6"),
        ("Graphite", "#8E8E93"),
    ]
}

/// Alt-Tab (Windows 11 style window switcher) settings, in the taskbar's preferences.
public enum AltTabSetting {
    /// On by default.
    public static let enabled = "altTabEnabled"
    /// "option" (default: ⌥ Tab) or "command" (⌘ Tab, instead of the Mac's app switcher).
    public static let key = "altTabKey"
    /// Minimized windows and hidden apps' windows too (default on).
    public static let showMinimized = "altTabShowMinimized"
    /// "small" | "medium" (default) | "large" thumbnails.
    public static let size = "altTabSize"
    /// Window order: "recent" (default: most recently used first), "taskbar" (the taskbar's order) or "name" (A–Z).
    public static let order = "altTabOrder"
}

/// BugOS › Misc settings (in the taskbar's preferences: the taskbar process does the work).
public enum MiscSetting {
    /// 1.5.0's on/off switch (true = "sideways"); read only if shiftScrollMode isn't set.
    public static let shiftScroll = "shiftScrollSideways"
    /// Shift + scroll: "default" (the Mac's own), "sideways" (always) or "vertical" (never sideways).
    public static let shiftScrollMode = "shiftScrollMode"
}

/// Window snapping (BugOS › Snapping), in the taskbar's preferences. All on by default.
public enum SnapSetting {
    public static let enabled = "snapEnabled"
    /// ⌃⌥ + arrow keys.
    public static let keys = "snapKeys"
    /// Drag a window to an edge or corner.
    public static let drag = "snapDrag"
    /// Snap layouts: drag to the top, or rest the pointer on the green button.
    public static let layouts = "snapLayouts"
    /// After a half or third, offer the other windows for the rest of the screen.
    public static let assist = "snapAssist"
}

/// Clipboard history (BugOS › Clipboard), in the taskbar's preferences.
public enum ClipboardSetting {
    /// On by default.
    public static let enabled = "clipboardEnabled"
    /// Shortcut.stored; missing = ⌃⌥V, "" = none.
    public static let shortcut = "clipboardShortcut"
    public static let defaultShortcut = Shortcut(kVK_ANSI_V, controlKey | optionKey)
    /// How many (unpinned) items to keep: 25 (default), 50 or 100.
    public static let limit = "clipboardLimit"
    /// Paste the item straight into the app (default) or only copy it.
    public static let pasteNow = "clipboardPasteNow"
}

/// BugOS › Mouse settings that BugOS does itself (the rest are the Mac's own pointer settings).
public enum MouseSetting {
    /// Lines per mouse-wheel notch, no scroll acceleration (0 = the Mac's own scrolling). Default 3.
    public static let wheelLines = "mouseWheelLines"
}

/// BugOS › Full Screen (in the taskbar's preferences).
/// BugOS › Mouse & keyboard › Hold a key to repeat it (the Mac's own settings are changed by BugOS itself).
public enum KeyboardSetting {
    /// When "Hold a key to repeat it" went on (seconds since 1970; 0/missing = off). The taskbar process uses it
    /// to stop the accent menu in apps that were already open then.
    public static let repeatOnSince = "keyRepeatOnSince"
}

public enum FullScreenSetting {
    /// The green button maximizes like Windows (⌘-click = the Mac's full screen). Default on.
    public static let greenMaximizes = "greenMaximizes"
    /// The taskbar hides while an app is full screen. Default on.
    public static let hideBar = "hideBarForFullScreen"
    /// A shortcut toggles the window you're in into / out of full screen, like Windows' Alt+Enter. Default off.
    public static let altEnter = "altEnterFullScreen"
    /// Shortcut.stored; missing = ⌥↩.
    public static let altEnterShortcut = "altEnterShortcut"
    public static let defaultShortcut = Shortcut(kVK_Return, optionKey)
}
