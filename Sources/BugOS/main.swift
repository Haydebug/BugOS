// BugOS (BugOS.app/Contents/MacOS/BugOS).
//
// One app that carries three parts inside it, in Contents/Applications:
//   BugDock.app        the Windows 11-style taskbar   (com.bugos.dock)
//   File Explorer.app  the Windows 11-style explorer  (com.bugos.explorer)
//   Squiggle.app       screenshots / recordings       (com.bugos.squiggle)
// BugOS starts them as its own child processes (Supervisor.swift), so macOS files every permission
// under "BugOS" alone, and keeps running in the background while they do.
//
// Opening BugOS (Applications, Spotlight, the taskbar) shows the BugOS page (SettingsPage.swift):
// version, permissions, settings, Uninstall. The first open moves it into Applications if needed and
// sets it up (SystemChanges.swift).
//
//   BugOS --login              started at login (LaunchAgent com.bugos.os): parts only, the page only if
//                              a permission is missing
//   BugOS --setup              show the page at Permissions
//   BugOS --page <section>     show the page at general | features | permissions | taskbar | quickCorner | explorer | squiggle
//   BugOS --start <part>       start dock | explorer | squiggle (the parts use this to hand themselves over)
//   BugOS --open <paths…>      open folders in File Explorer
//   BugOS --restart <part>     restart one part (./build.sh update uses this)
//   BugOS --folders on|off     File Explorer (or Finder) opens folders
//   BugOS --quit               quit every part and BugOS
//   BugOS --uninstall [--keep-settings]   what General › Uninstall does, without asking
// With a copy already running, these are passed to it and this copy exits.
import AppKit
import BugOSKit

let parts = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications")
let explorer = (id: BugOSID.explorer, url: parts.appendingPathComponent("File Explorer.app"))
let args = CommandLine.arguments

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func paths(after flag: String) -> [String] {
    guard let i = args.firstIndex(of: flag) else { return [] }
    return Array(args[(i + 1)...]).filter { !$0.hasPrefix("--") }
}

/// What this launch asks for, as a command for the running copy.
func requestedCommand() -> (cmd: String, paths: [String]) {
    if args.contains("--quit") { return ("quit", []) }
    if args.contains("--uninstall") { return (args.contains("--keep-settings") ? "uninstall:keep" : "uninstall", []) }
    if args.contains("--setup") { return ("setup", []) }
    if let p = value(after: "--page") { return ("page:\(p)", []) }
    if let p = value(after: "--restart") { return ("restart:\(p)", []) }
    if let v = value(after: "--folders") { return ("folders:\(v)", []) }
    if args.contains("--open") { return ("open", paths(after: "--open")) }
    if let p = value(after: "--start") { return ("start:\(p)", []) }
    if args.contains("--login") { return ("login", []) }
    return ("reopen", [])
}

// MARK: Only one BugOS: pass the request on to the running one.

let me = getpid()
if NSRunningApplication.runningApplications(withBundleIdentifier: BugOSID.os)
    .contains(where: { $0.processIdentifier != me && !$0.isTerminated }) {
    let r = requestedCommand()
    BugOSCommand.send(r.cmd, paths: r.paths)
    exit(0)
}
if args.contains("--quit") || args.contains("--restart") { exit(0) }   // nothing running to act on

// MARK: The running BugOS

@MainActor
final class BugOSDelegate: NSObject, NSApplicationDelegate {
    let sup = Supervisor.shared
    var page: PageController?

    func applicationDidFinishLaunching(_ n: Notification) {
        let r = requestedCommand()
        if r.cmd != "login" {
            guard SystemChanges.ensureInApplications() else { return }
        }
        SystemChanges.firstRunIfNeeded()
        sup.onAllPartsQuit = { [weak self] in self?.quitIfIdle() }
        DistributedNotificationCenter.default().addObserver(forName: BugOSID.command, object: nil, queue: .main) { [weak self] n in
            let cmd = n.object as? String ?? ""
            let paths = n.userInfo?["paths"] as? [String] ?? []
            MainActor.assumeIsolated { self?.handle(cmd, paths: paths) }
        }
        sup.log("BugOS \(SystemChanges.version) started (\(r.cmd))")
        Updater.shared.onNewVersion = { [weak self] in self?.showPage(.general) }
        Updater.shared.startAutomaticChecks()
        // Every launch starts all three parts; File Explorer quietly (hotkey, folder opening) unless it
        // was asked for.
        sup.start(.dock)
        sup.start(.squiggle)
        sup.start(.explorer, args: r.cmd == "start:explorer" ? [] : ["--background"])
        switch r.cmd {
        case "login", "start:dock", "start:squiggle", "start:explorer":
            if Permissions.missingRequired { showPage(.permissions) }
        case "reopen":
            showPage(Permissions.missingRequired ? .permissions : .general)
        default:
            handle(r.cmd, paths: r.paths)
        }
    }

    /// Opening BugOS again (Applications, Spotlight, the taskbar) while it's running.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        handle("reopen", paths: [])
        return false
    }

    func handle(_ cmd: String, paths: [String]) {
        sup.log("command \(cmd) \(paths)")
        switch cmd {
        case "setup":
            showPage(.permissions)
        case "reopen":
            for p in [Part.dock, .squiggle, .explorer] where !sup.isRunning(p) && p.enabled {
                sup.start(p, args: p == .explorer ? ["--background"] : [])
            }
            showPage(page == nil ? (Permissions.missingRequired ? .permissions : .general) : nil)
        case "login":
            if Permissions.missingRequired { showPage(.permissions) }
        case "open":
            sup.openInExplorer(paths)
        case "quit":
            sup.stopAll()
            NSApp.terminate(nil)
        case "uninstall", "uninstall:keep":
            SystemChanges.uninstall(keepSettings: cmd == "uninstall:keep")
        default:
            if cmd.hasPrefix("page:") {
                showPage(PageSection(rawValue: String(cmd.dropFirst(5))) ?? .general)
            } else if cmd.hasPrefix("start:"), let p = part(String(cmd.dropFirst(6))) {
                if p == .explorer { sup.showExplorer() } else { sup.start(p) }
            } else if cmd.hasPrefix("folders:") {
                SystemChanges.setExplorerOpensFolders(cmd == "folders:on")
            } else if cmd.hasPrefix("restart:"), let p = part(String(cmd.dropFirst(8))) {
                sup.restart(p)
            }
        }
    }

    private func part(_ s: String) -> Part? {
        switch s {
        case "dock", "bugdock": .dock
        case "explorer": .explorer
        case "squiggle": .squiggle
        default: nil
        }
    }

    func showPage(_ section: PageSection?) {
        if page == nil {
            page = PageController(section: section ?? .general) { [weak self] in
                self?.page = nil
                NSApp.setActivationPolicy(.accessory)
                self?.quitIfIdle()
            }
        }
        NSApp.setActivationPolicy(.regular)   // a normal window (and taskbar button) while it's open
        page?.show(section)
    }

    private func quitIfIdle() {
        guard page == nil, !sup.anyRunning else { return }
        sup.log("all parts quit; BugOS quits")
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ n: Notification) {
        sup.log("BugOS quitting")
        sup.stopAll()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = BugOSDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
    // app.run() only returns if something stopped the event loop; don't leave the parts orphaned.
    Supervisor.shared.log("event loop ended unexpectedly; quitting parts")
    Supervisor.shared.stopAll()
}
