import AppKit
import BugOSKit

@main
enum BugDockMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var tracker: WindowTracker!
    private var bars: TaskbarSet!
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Inside BugOS, only BugOS may start the bar (so its permissions are BugOS's).
        if BugOSChild.shouldHandOff { BugOSChild.handOff("start:dock") }
        // Only one BugDock at a time. A `--handoff` copy (a fresh install) takes over and asks the
        // old one to quit; any other duplicate quits itself.
        let others = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).filter { $0 != .current }
        } ?? []
        if !others.isEmpty {
            guard CommandLine.arguments.contains("--handoff") else {
                NSApp.terminate(nil)
                return
            }
            others.forEach { $0.terminate() }
            waitForOthersToExit(others, deadline: Date().addingTimeInterval(3))
            return
        }
        start()
    }

    private func waitForOthersToExit(_ others: [NSRunningApplication], deadline: Date) {
        if others.allSatisfy(\.isTerminated) { start(); return }
        if Date() > deadline { others.forEach { _ = $0.forceTerminate() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForOthersToExit(others, deadline: deadline)
        }
    }

    private func start() {
        guard !started else { return }
        // Right after login the display may not be attached yet; wait (without blocking) for one.
        guard !NSScreen.screens.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
            return
        }
        started = true
        // Under BugOS, its setup window asks for permissions (all filed under "BugOS").
        if !BugOSChild.isChild {
            if !AX.isTrusted { AX.promptForTrust() }
            Thumbnails.shared.requestPermissionIfNeeded()
        }
        tracker = WindowTracker(pins: PinStore())
        bars = TaskbarSet(tracker: tracker)   // the main bar, and one per extra display
        bars.show()   // (BugOS starts at login and restarts the bar if it crashes.)
    }
}
