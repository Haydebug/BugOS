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
