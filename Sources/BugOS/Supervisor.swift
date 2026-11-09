// BugOS runs its three parts as its own child processes.
//
// Why: macOS checks a child process's privacy permissions (Accessibility, Screen Recording, Full Disk
// Access, Microphone) against the app that started it. So when BugOS starts BugDock, File Explorer
// and Squiggle itself, every permission prompt and every System Settings entry is just "BugOS", one
// switch each, instead of one per part. (Opened any other way, a part hands itself back to BugOS:
// see BugOSChild in each part.)
//
// BugOS stays running (no Dock icon, no window) while any part is running:
//   - a part that crashes is restarted (at most 5 times a minute);
//   - a part you quit on purpose stays quit (opening BugOS, or the part, starts it again);
//   - when every part has quit, BugOS quits too.
// Other copies of BugOS and the parts talk to it with distributed notifications (BugOSCommand).
import AppKit
import BugOSKit

enum Part: String, CaseIterable {
    case dock, explorer, squiggle

    var bundleID: String {
        switch self {
        case .dock: "com.bugos.dock"
        case .explorer: BugOSID.explorer
        case .squiggle: "com.bugos.squiggle"
        }
    }
    var appURL: URL {
        switch self {
        case .dock: parts.appendingPathComponent("BugDock.app")
        case .explorer: parts.appendingPathComponent("File Explorer.app")
        case .squiggle: parts.appendingPathComponent("Squiggle.app")
        }
    }
    var executableURL: URL {
        let exe: String
        switch self {
        case .dock: exe = "BugDock"
        case .explorer: exe = "BugExplorer"
        case .squiggle: exe = "Squiggle"
        }
        return appURL.appendingPathComponent("Contents/MacOS/" + exe)
    }

    /// Turned on in BugOS › Features (all on by default). A part that's off is never started.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled." + rawValue) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "enabled." + rawValue) }
    }
}

/// Messages between BugOS copies and its parts. Name is fixed; `object` is the command.
enum BugOSCommand {
    static let name = BugOSID.command
    static func send(_ cmd: String, paths: [String] = []) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: cmd, userInfo: paths.isEmpty ? nil : ["paths": paths], deliverImmediately: true)
    }
}

@MainActor
final class Supervisor {
    static let shared = Supervisor()
    private var children: [Part: Process] = [:]
    /// Parts being restarted: when the old copy exits, start a new one with these arguments.
    private var restartArgs: [Part: [String]] = [:]
    private var crashes: [Part: [Date]] = [:]
    private var quitting = false
    private let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Bug OS.log")
    var onAllPartsQuit: (() -> Void)?

    func log(_ s: String) {
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
    }

    func isRunning(_ p: Part) -> Bool { children[p]?.isRunning == true }
    var anyRunning: Bool { children.values.contains { $0.isRunning } }

    /// Copies of a part that BugOS didn't start (an old install, or one opened before BugOS was
    /// running). They'd have their own permissions, so they're asked to quit and BugOS starts its own.
    func replaceStrays(_ parts: [Part]) {
        var strays: [NSRunningApplication] = []
        for p in parts {
            let mine = children[p]?.processIdentifier
            strays += NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID)
                .filter { $0.processIdentifier != mine }
        }
        guard !strays.isEmpty else { return }
        log("replacing \(strays.count) part(s) not started by BugOS")
        strays.forEach { $0.terminate() }   // polite: File Explorer saves its tabs
        let deadline = Date().addingTimeInterval(4)
        while strays.contains(where: { !$0.isTerminated }) && Date() < deadline { pump(0.1) }
        strays.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    func start(_ p: Part, args: [String] = []) {
        guard !isRunning(p), p.enabled else { return }
        replaceStrays([p])
        let proc = Process()
        proc.executableURL = p.executableURL
        // BugDock: --handoff lets it take the bar over from anything left behind.
        proc.arguments = (p == .dock ? ["--handoff"] : []) + args
        var env = ProcessInfo.processInfo.environment
        env["BUGOS_CHILD"] = "1"
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] t in
            let crashed = t.terminationReason == .uncaughtSignal || t.terminationStatus != 0
            let status = t.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(p, proc: t, crashed: crashed, status: status) } }
        }
        do {
            try proc.run()
            children[p] = proc
            log("started \(p.rawValue) pid \(proc.processIdentifier) \(args)")
        } catch {
            log("couldn't start \(p.rawValue): \(error)")
        }
    }

    private func ended(_ p: Part, proc: Process, crashed: Bool, status: Int32) {
        guard children[p] === proc else { return }   // an older copy (already replaced)
        children[p] = nil
        log("\(p.rawValue) exited (\(crashed ? "crash/status \(status)" : "quit"))")
        if let again = restartArgs.removeValue(forKey: p) {
            start(p, args: again)
            return
        }
        if crashed && !quitting {
            let now = Date()
            let recent = (crashes[p] ?? []).filter { now.timeIntervalSince($0) < 60 } + [now]
            crashes[p] = recent
            if recent.count <= 5 {
                // File Explorer comes back quietly (no window) after a crash.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.start(p, args: p == .explorer ? ["--background"] : [])
                }
                return
            }
            log("\(p.rawValue) crashed 5 times in a minute; leaving it off")
        }
        if !anyRunning { onAllPartsQuit?() }
    }

    /// Quit a part politely and start it again (picks up new permissions or a new build). Doesn't
    /// wait: the new copy starts when the old one has exited (forced after 4 seconds).
    func restart(_ p: Part) {
        let again = p == .explorer ? ["--background"] : []
        guard let proc = children[p], proc.isRunning else {
            if p != .explorer || !NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).isEmpty {
                start(p, args: again)
            }
            return
        }
        restartArgs[p] = again
        NSRunningApplication(processIdentifier: proc.processIdentifier)?.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    func stop(_ p: Part) {
        guard let proc = children[p], proc.isRunning else { replaceStrays([p]); return }
        children[p] = nil   // so `ended` doesn't treat it as a crash or a last-part quit
        NSRunningApplication(processIdentifier: proc.processIdentifier)?.terminate()
        let deadline = Date().addingTimeInterval(4)
        while proc.isRunning && Date() < deadline { pump(0.1) }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }

    /// BugOS › Features: turn a whole part on or off, along with what it changes on the Mac.
    func setEnabled(_ p: Part, _ on: Bool) {
        p.enabled = on
        log("\(p.rawValue) turned \(on ? "on" : "off")")
        switch p {
        case .dock:
            // The Mac Dock is only tucked away to make room for the taskbar.
            if on { start(.dock); if !SystemChanges.dockTucked { SystemChanges.setDockTucked(true) } }
            else { stop(.dock); if SystemChanges.dockTucked { SystemChanges.setDockTucked(false) } }
            SystemChanges.syncNotificationSwipe()   // the gesture lives in the taskbar
        case .explorer:
            if on {
                start(.explorer, args: ["--background"])
                if SystemChanges.explorerOpensFolders { SystemChanges.setSystemFolderHandler(explorer: true) }
            } else {
                SystemChanges.setSystemFolderHandler(explorer: false)   // its redirect stops with it
                stop(.explorer)
            }
        case .squiggle:
            if on { start(.squiggle) } else { stop(.squiggle) }
        }
    }

    func stopAll() {
        quitting = true
        for p in Part.allCases { stop(p) }
    }

    /// Bring up File Explorer: a new window if it's running, else start it with one.
    func showExplorer() {
        if isRunning(.explorer) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: explorer.url, configuration: cfg) { _, _ in }   // a reopen → new window
        } else {
            start(.explorer)
        }
    }

    /// Open folders/files in File Explorer (the folder handler and "Open With" go through here when
    /// File Explorer wasn't running yet).
    func openInExplorer(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard Part.explorer.enabled else {   // File Explorer is off: Finder
            urls.forEach { NSWorkspace.shared.open($0) }
            return
        }
        if !isRunning(.explorer) {
            start(.explorer, args: ["--background"])
            // Wait for it to check in with the system, then hand it the folders.
            for _ in 0..<60 where NSRunningApplication.runningApplications(withBundleIdentifier: Part.explorer.bundleID)
                .first(where: { $0.isFinishedLaunching }) == nil { pump(0.05) }
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: explorer.url, configuration: cfg) { _, _ in }
    }
}
