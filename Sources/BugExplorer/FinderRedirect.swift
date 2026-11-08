// "Open folders with File Explorer" on macOS 26+.
//
// macOS 26 no longer lets an app make itself the handler for folders (LaunchServices answers paramErr,
// even for Finder itself), so folders keep opening in Finder. Instead, File Explorer watches Finder
// (Accessibility, which BugOS already has): when a Finder window opens on a folder, from the Desktop,
// `open`, the Downloads stack or another app's "Show in Finder", File Explorer opens that folder and
// closes the Finder window. Reading the window's folder uses
// Finder's AppleScript, so macOS asks once whether BugOS may control Finder.
//
// Finder windows File Explorer opens on purpose ("Show in Finder" in its menus) are left alone.
import AppKit
import ApplicationServices
import BugOSKit

@MainActor
final class FinderRedirect {
    static let shared = FinderRedirect()
    private static let finderID = "com.apple.finder"

    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var started = false
    /// Our own "Show in Finder": don't redirect Finder windows until then.
    private var pausedUntil = Date.distantPast

    /// One line in BugOS's log (~/Library/Logs/Bug OS.log).
    static func log(_ s: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Bug OS.log")
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile(); h.write(Data("\(Date()) File Explorer \(s)\n".utf8)); try? h.close()
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: ExplorerSetting.openFolders) as? Bool ?? true }

    func start() {
        guard !started else { attach(); return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == FinderRedirect.finderID else { return }
            MainActor.assumeIsolated { FinderRedirect.shared.attach() }
        }
        attach()
    }

    /// Settings changed: watch Finder or stop.
    func reload() { Self.enabled ? attach() : detach() }

    /// Open Finder on purpose (File Explorer's own "Show in Finder").
    func showInFinder(_ urls: [URL]) {
        pausedUntil = Date().addingTimeInterval(3)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func attach() {
        guard Self.enabled, AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderID).first else { return }
        let pid = finder.processIdentifier
        guard pid != observedPid || observer == nil else { return }
        detach()
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, _ in
            let w = element
            DispatchQueue.main.async { MainActor.assumeIsolated { FinderRedirect.shared.windowCreated(w) } }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        AXObserverAddNotification(obs, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPid = pid
    }

    private func detach() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil
        observedPid = 0
    }

    private func windowCreated(_ w: AXUIElement) {
        guard Self.enabled, Date() > pausedUntil, AXK.str(w, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return }
        // Give Finder a moment to point the new window at its folder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.redirect(w) }
    }

    private func redirect(_ w: AXUIElement) {
        let title = AXK.title(w)
        guard !title.isEmpty else { return }
        // The newest Finder window, if it's the one that just opened: its folder and selection, then close it.
        // Windows with no folder behind them (Recents, AirDrop, Network) raise an error and stay in Finder.
        let esc = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            set w to Finder window 1
            if name of w is not "\(esc)" then return ""
            set p to POSIX path of (target of w as alias)
            close w
            return p
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue, !out.isEmpty else {
            if let err { Self.log("redirect skipped: \(err[NSAppleScript.errorMessage] ?? err)") }
            return
        }
        // Finder's selection isn't used: for a moment after a window opens it still holds an old one.
        (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [URL(fileURLWithPath: out)])
    }
}
