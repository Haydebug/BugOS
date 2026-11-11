// Everything BugOS changes on the Mac outside its own app, and how each is put back:
//   - start at login (a LaunchAgent),
//   - the Mac Dock tucked away (left side, auto-hide) and the bottom-right hot corner off,
//   - File Explorer as the app that opens folders (on by default; Finder again if you turn it off),
//   - Notification Center's trackpad swipe off while the quick corner's gesture (which takes its place) is on,
// plus first-run setup (moving into Applications) and uninstalling.
import AppKit
import BugOSKit

enum SystemChanges {
    static let stateDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Bug OS")
    static let installedFile = stateDir.appendingPathComponent("installed.plist")
    static let restoreDockScript = stateDir.appendingPathComponent("restore-dock.sh")
    static let loginAgentURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(BugOSID.loginAgentLabel).plist")
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    // MARK: Start at login

    static var startsAtLogin: Bool { FileManager.default.fileExists(atPath: loginAgentURL.path) }

    /// A LaunchAgent that runs BugOS with --login and restarts it if it crashes (from the next login).
    static func setStartsAtLogin(_ on: Bool) {
        guard on else { try? FileManager.default.removeItem(at: loginAgentURL); return }
        let plist: [String: Any] = [
            "Label": BugOSID.loginAgentLabel,
            "ProgramArguments": [Bundle.main.executableURL!.path, "--login"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        try? FileManager.default.createDirectory(at: loginAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        (plist as NSDictionary).write(to: loginAgentURL, atomically: true)
    }

    // MARK: The Mac Dock

    private static let dockKeys = ["orientation", "autohide", "autohide-delay", "wvous-br-corner", "wvous-br-modifier"]
    private static let tuckedKey = "dockTucked"

    static var dockTucked: Bool { UserDefaults.standard.bool(forKey: tuckedKey) }

    /// On: the Dock moves to the left and hides (it would cover the taskbar), and the bottom-right hot
    /// corner is turned off (BugDock's quick corner is there). Off: exactly how it was before BugOS.
    static func setDockTucked(_ on: Bool) {
        if on {
            saveDockOnce()
            shell("/usr/bin/defaults", "write", "com.apple.dock", "orientation", "-string", "left")
            shell("/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", "true")
            shell("/usr/bin/defaults", "write", "com.apple.dock", "autohide-delay", "-float", "1000")
            shell("/usr/bin/defaults", "write", "com.apple.dock", "wvous-br-corner", "-int", "1")
            shell("/usr/bin/defaults", "write", "com.apple.dock", "wvous-br-modifier", "-int", "0")
        } else if FileManager.default.fileExists(atPath: restoreDockScript.path) {
            shell("/bin/bash", restoreDockScript.path)
        }
        shell("/usr/bin/killall", "Dock")
        UserDefaults.standard.set(on, forKey: tuckedKey)
    }

    /// Record the Dock settings from before BugOS, once, as a script that puts them back.
    private static func saveDockOnce() {
        guard !FileManager.default.fileExists(atPath: restoreDockScript.path) else { return }
        var lines = ["# Written by BugOS: puts the Mac Dock back how it was before BugOS."]
        for k in dockKeys {
            if let v = CFPreferencesCopyAppValue(k as CFString, "com.apple.dock" as CFString) {
                let (flag, text): (String, String)
                if CFGetTypeID(v) == CFBooleanGetTypeID() { (flag, text) = ("-bool", (v as! Bool) ? "true" : "false") }
                else if let n = v as? NSNumber { (flag, text) = CFNumberIsFloatType(n) ? ("-float", n.stringValue) : ("-int", n.stringValue) }
                else { (flag, text) = ("-string", "\(v)") }
                lines.append("defaults write com.apple.dock \(k) \(flag) '\(text.replacingOccurrences(of: "'", with: ""))'")
            } else {
                lines.append("defaults delete com.apple.dock \(k) 2>/dev/null")
            }
        }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: restoreDockScript, atomically: true, encoding: .utf8)
    }

    // MARK: Trackpad gestures macOS would take first

    /// A macOS trackpad gesture BugOS turns off while the quick corner's gesture needs it:
    ///   - Notification Center's swipe in from the right edge (the corner gesture also starts at the right edge),
    ///   - three- or four-finger swipe up/down for Mission Control / App Exposé, whichever the corner gesture
    ///     uses (they stay on the other one).
    /// The old values are saved once and put back when it's no longer needed, or on uninstall.
    struct TrackpadGesturePref {
        let name: String          // for the log and the restore file
        let key: String           // in the trackpad domains
        let globalKey: String     // -currentHost -g
        var restoreFile: URL { stateDir.appendingPathComponent("restore-\(name).plist") }
        var mutedKey: String { "muted.\(name)" }
    }
    static let notificationSwipe = TrackpadGesturePref(name: "swipe", key: "TrackpadTwoFingerFromRightEdgeSwipeGesture",
                                                       globalKey: "com.apple.trackpad.twoFingerFromRightEdgeSwipeGesture")
    static let threeFingerVertical = TrackpadGesturePref(name: "three-finger-vertical", key: "TrackpadThreeFingerVertSwipeGesture",
                                                         globalKey: "com.apple.trackpad.threeFingerVertSwipeGesture")
    static let fourFingerVertical = TrackpadGesturePref(name: "four-finger-vertical", key: "TrackpadFourFingerVertSwipeGesture",
                                                        globalKey: "com.apple.trackpad.fourFingerVertSwipeGesture")
    private static let trackpadDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]

    static func isMuted(_ g: TrackpadGesturePref) -> Bool {
        // (1.1 kept the Notification Center one under its own key.)
        UserDefaults.standard.bool(forKey: g.mutedKey) || (g.name == "swipe" && UserDefaults.standard.bool(forKey: "notificationSwipeMuted"))
    }

    static func setMuted(_ g: TrackpadGesturePref, _ mute: Bool) {
        let legacy = stateDir.appendingPathComponent("restore-swipe.plist")   // same file name as 1.1
        let file = g.name == "swipe" ? legacy : g.restoreFile
        if mute {
            if !FileManager.default.fileExists(atPath: file.path) {   // save the originals once
                var saved: [String: Any] = [:]
                for d in trackpadDomains {
                    if let v = CFPreferencesCopyAppValue(g.key as CFString, d as CFString) { saved[d] = v }
                }
                if let v = CFPreferencesCopyValue(g.globalKey as CFString, kCFPreferencesAnyApplication,
                                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) { saved["global"] = v }
                try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
                (saved as NSDictionary).write(to: file, atomically: true)
            }
            for d in trackpadDomains { shell("/usr/bin/defaults", "write", d, g.key, "-int", "0") }
            shell("/usr/bin/defaults", "-currentHost", "write", "-g", g.globalKey, "-int", "0")
        } else {
            let saved = NSDictionary(contentsOf: file) as? [String: Any] ?? [:]
            for d in trackpadDomains {
                if let v = saved[d] as? Int { shell("/usr/bin/defaults", "write", d, g.key, "-int", "\(v)") }
                else { shell("/usr/bin/defaults", "delete", d, g.key) }
            }
            if let v = saved["global"] as? Int { shell("/usr/bin/defaults", "-currentHost", "write", "-g", g.globalKey, "-int", "\(v)") }
            else { shell("/usr/bin/defaults", "-currentHost", "delete", "-g", g.globalKey) }
            try? FileManager.default.removeItem(at: file)
        }
        // Apply it now (no need to log out). Mission Control's swipes belong to the Dock, which only rereads
        // them when it starts, so restart it too (the Mac Dock is tucked away; it comes straight back).
        shell("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", "-u")
        if g.name != "swipe" { shell("/usr/bin/killall", "Dock") }
        UserDefaults.standard.set(mute, forKey: g.mutedKey)
        if g.name == "swipe" { UserDefaults.standard.set(mute, forKey: "notificationSwipeMuted") }
        MainActor.assumeIsolated { Supervisor.shared.log("trackpad \(g.name) \(mute ? "turned off" : "back on")") }
    }

    /// Keep them in step with the settings.
    @MainActor static func syncNotificationSwipe() {
        CFPreferencesAppSynchronize(BugOSID.dock as CFString)
        func dock<T>(_ k: String, _ d: T) -> T { CFPreferencesCopyAppValue(k as CFString, BugOSID.dock as CFString) as? T ?? d }
        let gestureOn = Part.dock.enabled && dock(QuickCornerCatalog.gestureKey, true)   // Quick Access
        // The gesture is Notification Center's old spot, so that swipe is off while it's on. Mission Control's
        // swipes are never touched any more (1.2 betas moved them; put them back).
        let wantNC = gestureOn
        if wantNC != isMuted(notificationSwipe) { setMuted(notificationSwipe, wantNC) }
        for g in [threeFingerVertical, fourFingerVertical] where isMuted(g) { setMuted(g, false) }
    }

    /// Uninstall: every trackpad gesture back how it was.
    static func restoreTrackpadGestures() {
        for g in [notificationSwipe, threeFingerVertical, fourFingerVertical] where isMuted(g) || FileManager.default.fileExists(atPath: g.restoreFile.path) {
            setMuted(g, false)
        }
        if FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("restore-swipe.plist").path) { setMuted(notificationSwipe, false) }
    }

    // MARK: Mouse and trackpad (BugOS › Mouse)

    /// The Mac's own pointer settings, changed in place (no driver). The values from before BugOS first
    /// changed one are saved and put back on uninstall.
    enum Pointer {
        static let keys = ["com.apple.mouse.linear", "com.apple.mouse.scaling", "com.apple.scrollwheel.scaling",
                           "com.apple.trackpad.scaling", "com.apple.swipescrolldirection", "AppleActionOnDoubleClick"]
        static func string(_ key: String, _ d: String) -> String { value(key) as? String ?? d }
        static let restoreFile = stateDir.appendingPathComponent("restore-mouse.plist")

        static func value(_ key: String) -> Any? {
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            return CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication)
        }
        static func double(_ key: String, _ d: Double) -> Double { (value(key) as? NSNumber)?.doubleValue ?? d }
        static func bool(_ key: String, _ d: Bool) -> Bool { (value(key) as? NSNumber)?.boolValue ?? d }

        static func set(_ key: String, _ v: Any) {
            saveOnce()
            let value: CFPropertyList = (v as? Bool).map { $0 as NSNumber } ?? ((v as? Double).map { $0 as NSNumber }
                ?? ((v as? String).map { $0 as NSString } ?? (v as! CFPropertyList)))
            CFPreferencesSetAppValue(key as CFString, value, kCFPreferencesAnyApplication)
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            applySoon()
        }

        /// Takes effect straight away (the way System Settings does it), once a slider stops moving.
        nonisolated(unsafe) private static var pending: DispatchWorkItem?
        static func applySoon() {
            pending?.cancel()
            let work = DispatchWorkItem { DispatchQueue.global(qos: .userInitiated).async { apply() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        static func apply() {
            shell("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", "-u")
        }

        private static func saveOnce() {
            guard !FileManager.default.fileExists(atPath: restoreFile.path) else { return }
            var saved: [String: Any] = [:]
            for k in keys { if let v = value(k) { saved[k] = v } }
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            (saved as NSDictionary).write(to: restoreFile, atomically: true)
        }

        /// Uninstall: everything back how it was.
        static func restore() {
            guard let saved = NSDictionary(contentsOf: restoreFile) as? [String: Any] else { return }
            for k in keys {
                if let str = saved[k] as? String {
                    shell("/usr/bin/defaults", "write", "-g", k, "-string", str)
                } else if let n = saved[k] as? NSNumber {
                    if CFGetTypeID(n) == CFBooleanGetTypeID() { shell("/usr/bin/defaults", "write", "-g", k, "-bool", n.boolValue ? "true" : "false") }
                    else { shell("/usr/bin/defaults", "write", "-g", k, "-float", n.stringValue) }
                } else {
                    shell("/usr/bin/defaults", "delete", "-g", k)
                }
            }
            try? FileManager.default.removeItem(at: restoreFile)
            apply()
        }
    }

    // MARK: Holding a key repeats it (BugOS › Mouse & keyboard)

    /// Like Windows: hold a key and it types again and again (E → eeeee) instead of showing the accent
    /// menu, and Backspace keeps deleting quickly. Done with the Mac's own settings: press-and-hold off,
    /// a short delay and a fast repeat. What was there before comes back when it's turned off or on uninstall.
    enum KeyRepeat {
        static let enabledKey = "windowsKeyRepeat"
        static let keys = ["ApplePressAndHoldEnabled", "KeyRepeat", "InitialKeyRepeat"]
        static let restoreFile = stateDir.appendingPathComponent("restore-keyrepeat.plist")
        /// In the Mac's 15ms units: 25 = 375ms before it starts.
        static let initialTicks = 25
        static let ticksKey = "windowsKeyRepeatTicks"
        /// How often it repeats, in the Mac's 15ms units: 1 (every 15ms, ~67 a second) … 10 (~7 a second).
        /// Default 2: every 30ms, about 33 a second, Windows' default rate.
        static var repeatTicks: Int {
            let t = UserDefaults.standard.integer(forKey: ticksKey)
            return t == 0 ? 2 : min(max(t, 1), 10)
        }
        static func perSecond(ticks: Int) -> Int { Int((1000.0 / Double(ticks * 15)).rounded()) }

        static var isOn: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

        /// The slider under the switch.
        static func setRepeatTicks(_ t: Int) {
            UserDefaults.standard.set(min(max(t, 1), 10), forKey: ticksKey)
            guard isOn else { return }
            write("KeyRepeat", repeatTicks as NSNumber)
            applyLive()
        }

        static func setOn(_ on: Bool) {
            UserDefaults.standard.set(on, forKey: enabledKey)
            // The taskbar stops the accent menu in apps that were open before this (they read the Mac's setting once).
            dockPrefs.set(KeyboardSetting.repeatOnSince, on ? Date().timeIntervalSince1970 : 0.0)
            if on {
                saveOnce()
                write("ApplePressAndHoldEnabled", false as NSNumber)
                write("KeyRepeat", repeatTicks as NSNumber)
                write("InitialKeyRepeat", initialTicks as NSNumber)
            } else {
                restoreValues()
            }
            applyLive()
        }

        private static func value(_ key: String) -> Any? {
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            return CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication)
        }
        private static func write(_ key: String, _ v: CFPropertyList?) {
            CFPreferencesSetAppValue(key as CFString, v, kCFPreferencesAnyApplication)
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        }

        private static func saveOnce() {
            guard !FileManager.default.fileExists(atPath: restoreFile.path) else { return }
            var saved: [String: Any] = [:]
            for k in keys { if let v = value(k) { saved[k] = v } }
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            (saved as NSDictionary).write(to: restoreFile, atomically: true)
        }

        /// The saved values back (a key that wasn't set before is removed, so macOS uses its default).
        private static func restoreValues() {
            guard let saved = NSDictionary(contentsOf: restoreFile) as? [String: Any] else { return }
            for k in keys { write(k, saved[k] as CFPropertyList?) }
            try? FileManager.default.removeItem(at: restoreFile)
        }

        /// At startup: 1.8.0 turned it on without telling the taskbar when, so the taskbar's fix for apps that
        /// were already open had nothing to go by. Count from now.
        static func startup() {
            if isOn, (dockPrefs.value(KeyboardSetting.repeatOnSince, default: 0.0) as Double) == 0 {
                dockPrefs.set(KeyboardSetting.repeatOnSince, Date().timeIntervalSince1970)
            }
        }

        /// Uninstall.
        static func restore() {
            dockPrefs.set(KeyboardSetting.repeatOnSince, 0.0)
            guard FileManager.default.fileExists(atPath: restoreFile.path) else { return }
            restoreValues()
            applyLive()
        }

        /// The repeat speed takes effect straight away, the way System Settings does it (the keyboard
        /// driver's own setting, in nanoseconds). Press-and-hold is read by each app; most pick it up
        /// at once, the rest the next time they open.
        static func applyLive() {
            func ticks(_ k: String, _ d: Int) -> Int { (value(k) as? NSNumber)?.intValue ?? d }
            // macOS's defaults when nothing is set: 500ms delay, 83ms repeat.
            let initialNS = value("InitialKeyRepeat") == nil ? 500_000_000 : Int64(ticks("InitialKeyRepeat", 0)) * 15_000_000
            let repeatNS = value("KeyRepeat") == nil ? 83_333_333 : Int64(ticks("KeyRepeat", 0)) * 15_000_000
            HIDKeyboard.set(initial: initialNS, repeat: repeatNS)
        }
    }

    /// IOHIDEventSystemClient (IOKit, not in the public headers): what System Settings uses to change the
    /// key-repeat speed without logging out.
    enum HIDKeyboard {
        private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        private typealias SetProp = @convention(c) (AnyObject, CFString, CFTypeRef) -> Bool
        private typealias CopyProp = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
        private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

        private static func client() -> AnyObject? {
            guard let f = dlsym(iokit, "IOHIDEventSystemClientCreateSimpleClient") else { return nil }
            return unsafeBitCast(f, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
        }

        static func set(initial: Int64, repeat: Int64) {
            guard let c = client(), let f = dlsym(iokit, "IOHIDEventSystemClientSetProperty") else { return }
            let setProp = unsafeBitCast(f, to: SetProp.self)
            _ = setProp(c, "HIDInitialKeyRepeat" as CFString, NSNumber(value: initial))
            _ = setProp(c, "HIDKeyRepeat" as CFString, NSNumber(value: `repeat`))
        }

        /// (delay, repeat) in nanoseconds, as the keyboard driver has them now.
        static func current() -> (Int64, Int64)? {
            guard let c = client(), let f = dlsym(iokit, "IOHIDEventSystemClientCopyProperty") else { return nil }
            let copy = unsafeBitCast(f, to: CopyProp.self)
            func n(_ k: String) -> Int64? { (copy(c, k as CFString)?.takeRetainedValue() as? NSNumber)?.int64Value }
            guard let i = n("HIDInitialKeyRepeat"), let r = n("HIDKeyRepeat") else { return nil }
            return (i, r)
        }
    }

    // MARK: Staying on this desktop

    /// macOS jumps to another desktop when you open an app whose windows are there ("When switching to an
    /// application, switch to a Space with open windows for the application"). With the taskbar on "This
    /// desktop" (and BugOS › Taskbar › Open apps on this desktop, on by default) that's turned off, like
    /// Windows: clicking Chrome on desktop 1 opens a new window here instead of taking you to desktop 2.
    /// The old value is saved and put back when it's no longer wanted, or on uninstall.
    enum DesktopSwitch {
        static let key = "workspaces-auto-swoosh"
        static let restoreFile = stateDir.appendingPathComponent("restore-swoosh.plist")

        static var current: Bool? {
            CFPreferencesAppSynchronize("com.apple.dock" as CFString)
            return (CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? NSNumber)?.boolValue
        }

        @MainActor static func sync() {
            CFPreferencesAppSynchronize(BugOSID.dock as CFString)
            func dock<T>(_ k: String, _ d: T) -> T { CFPreferencesCopyAppValue(k as CFString, BugOSID.dock as CFString) as? T ?? d }
            // No longer turned off (2026-11-09): with it off, macOS wouldn't even take you to a one-copy app's
            // window (Discord). The taskbar opens apps here another way; this only puts back what 1.6 betas changed.
            _ = dock(DockSetting.stayOnDesktop, true)
            let stay = false
            let saved = FileManager.default.fileExists(atPath: restoreFile.path)
            if stay && !saved {
                var d: [String: Any] = [:]
                if let v = current { d["value"] = v }
                try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
                (d as NSDictionary).write(to: restoreFile, atomically: true)
                shell("/usr/bin/defaults", "write", "com.apple.dock", key, "-bool", "false")
                shell("/usr/bin/killall", "Dock")
                Supervisor.shared.log("staying on this desktop when opening apps (macOS desktop jumping off)")
            } else if !stay && saved {
                restore()
                Supervisor.shared.log("desktop jumping back how it was")
            }
        }

        static func restore() {
            guard let d = NSDictionary(contentsOf: restoreFile) as? [String: Any] else { return }
            if let v = d["value"] as? Bool { shell("/usr/bin/defaults", "write", "com.apple.dock", key, "-bool", v ? "true" : "false") }
            else { shell("/usr/bin/defaults", "delete", "com.apple.dock", key) }
            try? FileManager.default.removeItem(at: restoreFile)
            shell("/usr/bin/killall", "Dock")
        }
    }

    // MARK: Folders

    /// File Explorer takes over folders: it redirects Finder windows (macOS 26+, see FinderRedirect in
    /// File Explorer), and where macOS still allows it (15), it's also the system's folder handler.
    static var explorerOpensFolders: Bool {
        CFPreferencesAppSynchronize(BugOSID.explorer as CFString)
        let pref = CFPreferencesCopyAppValue(ExplorerSetting.openFolders as CFString, BugOSID.explorer as CFString) as? Bool
        return Part.explorer.enabled && (pref ?? true)
    }

    static func setExplorerOpensFolders(_ on: Bool, done: @escaping () -> Void = {}) {
        explorerPrefs.set(ExplorerSetting.openFolders, on)   // File Explorer picks this up straight away
        setSystemFolderHandler(explorer: on, done: done)
    }

    /// The system's folder handler (only changeable before macOS 26). Off only touches it if it's
    /// File Explorer, so Finder stays Finder.
    static func setSystemFolderHandler(explorer on: Bool, done: @escaping () -> Void = {}) {
        let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        let current = NSWorkspace.shared.urlForApplication(toOpen: .folder).flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard let target = on ? explorer.url : (current == BugOSID.explorer ? finder : nil) else { done(); return }
        if on {   // a fresh copy may not be known to LaunchServices yet
            shell("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                  "-f", target.path)
        }
        NSWorkspace.shared.setDefaultApplication(at: target, toOpen: .folder) { err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // paramErr on macOS 26: expected, the Finder redirect does the job there.
                    Supervisor.shared.log("folder handler → \(on ? "File Explorer" : "Finder"): \(err.map { "\($0.localizedDescription)" } ?? "ok")")
                }
                done()
            }
        }
    }

    // MARK: First run

    /// BugOS must run from Applications (it starts at login from there). Returns false if it's moving
    /// itself there and relaunching.
    @MainActor static func ensureInApplications() -> Bool {
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        let homeApps = NSHomeDirectory() + "/Applications"
        guard here != "/Applications", here != homeApps else { return true }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Move BugOS to Applications?"
        a.informativeText = "BugOS runs from your Applications folder. It'll move itself there and open again."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Quit")
        guard a.runModal() == .alertFirstButtonReturn else { exit(0) }
        let dir = FileManager.default.isWritableFile(atPath: "/Applications") ? "/Applications" : homeApps
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = dir + "/BugOS.app"
        try? FileManager.default.removeItem(atPath: dest)
        try? FileManager.default.removeItem(atPath: dir + "/Bug OS.app")   // the name before 1.1
        shell("/usr/bin/ditto", Bundle.main.bundleURL.path, dest)
        shell("/usr/bin/xattr", "-dr", "com.apple.quarantine", dest)   // it's the same app you just opened
        shell("/usr/bin/open", "-n", dest)
        exit(0)
    }

    /// First open after installing (or after moving the app): start at login and tuck the Dock away.
    static func firstRunIfNeeded() {
        let saved = NSDictionary(contentsOf: installedFile)
        let path = Bundle.main.bundleURL.path
        if saved == nil {
            setStartsAtLogin(true)
            setDockTucked(true)
            // Pointer acceleration off by default, like a gaming mouse setup (saved first; back on uninstall).
            if !Pointer.bool("com.apple.mouse.linear", false) { Pointer.set("com.apple.mouse.linear", true) }
            // Folders open in File Explorer by default (Finder comes back from the page or Uninstall).
            var done = false
            setExplorerOpensFolders(true) { done = true }
            for _ in 0..<60 where !done { pump(0.05) }
        } else if saved?["path"] as? String != path, startsAtLogin {
            setStartsAtLogin(true)   // moved: point the login item at the new place
        }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        (["path": path, "version": version] as NSDictionary).write(to: installedFile, atomically: true)
    }

    // MARK: Uninstall

    /// Put the Mac back how it was, remove BugOS, and quit. With `keepSettings`, BugOS's own
    /// settings (pinned apps, saved tabs, quick corner) stay for a reinstall.
    @MainActor static func uninstall(keepSettings: Bool) {
        let app = Bundle.main.bundleURL.path
        Supervisor.shared.stopAll()
        if dockTucked || FileManager.default.fileExists(atPath: restoreDockScript.path) {
            if FileManager.default.fileExists(atPath: restoreDockScript.path) { shell("/bin/bash", restoreDockScript.path) }
            shell("/usr/bin/killall", "Dock")
        }
        do {
            var done = false
            setSystemFolderHandler(explorer: false) { done = true }
            for _ in 0..<60 where !done { pump(0.05) }
        }
        restoreTrackpadGestures()
        Pointer.restore()
        KeyRepeat.restore()
        DesktopSwitch.restore()
        setStartsAtLogin(false)
        // Permission entries in System Settings go too.
        for id in [BugOSID.os, BugOSID.dock, BugOSID.explorer, BugOSID.squiggle] { shell("/usr/bin/tccutil", "reset", "All", id) }
        let fm = FileManager.default
        if !keepSettings {
            for id in [BugOSID.os, BugOSID.dock, BugOSID.explorer, BugOSID.squiggle] { shell("/usr/bin/defaults", "delete", id) }
            let lib = NSHomeDirectory() + "/Library"
            for p in ["Application Support/BugDock", "Application Support/BugExplorer", "Logs/Squiggle.log", "Logs/Bug OS.log"] {
                try? fm.removeItem(atPath: lib + "/" + p)
            }
        }
        try? fm.removeItem(at: stateDir)
        // The app itself goes once BugOS has quit, from a separate process (and the login job with it).
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        // Without keepSettings, also the preference files and log BugOS may write while quitting.
        let lib = NSHomeDirectory() + "/Library"
        let wipe = keepSettings ? "" : [BugOSID.os, BugOSID.dock, BugOSID.explorer, BugOSID.squiggle]
            .map { "defaults delete \($0) 2>/dev/null; rm -f '\(lib)/Preferences/\($0).plist'" }
            .joined(separator: "\n") + "\nrm -f '\(lib)/Logs/Bug OS.log' '\(lib)/Logs/Squiggle.log'"
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        launchctl bootout gui/\(getuid())/\(BugOSID.loginAgentLabel) 2>/dev/null
        '\(lsregister)' -u '\(app)' 2>/dev/null
        rm -rf '\(app)'
        \(wipe)
        """
        spawnDetached("/bin/bash", ["-c", script])
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    @discardableResult
    static func shell(_ tool: String, _ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Run a command in its own session, so it outlives BugOS (and its login job).
    static func spawnDetached(_ tool: String, _ args: [String]) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv: [UnsafeMutablePointer<CChar>?] = ([tool] + args).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        posix_spawn(&pid, tool, nil, &attr, argv, environ)
        argv.forEach { free($0) }
        posix_spawnattr_destroy(&attr)
    }
}
