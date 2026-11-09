// One taskbar per display, like Windows (BugOS › Taskbar › Show the taskbar on all displays, on by default).
// The main bar (on the menu-bar screen) has the music, the quick corner, Alt-Tab and the shortcuts; each
// other screen gets a plain taskbar along its bottom. Bars come and go as displays are plugged in or out.
import AppKit
import BugOSKit

enum ScreenID {
    static func of(_ s: NSScreen) -> CGDirectDisplayID {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

@MainActor
final class TaskbarSet {
    static weak var shared: TaskbarSet?

    let main: TaskbarController
    private let tracker: WindowTracker
    private var extras: [CGDirectDisplayID: TaskbarController] = [:]

    init(tracker: WindowTracker) {
        self.tracker = tracker
        main = TaskbarController(tracker: tracker)
        TaskbarSet.shared = self
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            // Displays settle a moment after they change.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { TaskbarSet.shared?.sync() } }
        }
    }

    static var allDisplays: Bool { UserDefaults.standard.object(forKey: DockSetting.allDisplays) as? Bool ?? true }

    var hasExtraBars: Bool { !extras.isEmpty }
    var bars: [TaskbarController] { [main] + extras.values }

    func show() {
        main.show()
        sync()
    }

    /// A bar for every screen but the main one (when the setting's on), none for screens that are gone.
    func sync() {
        let others = NSScreen.screens.dropFirst()
        let wanted = Self.allDisplays ? Set(others.map(ScreenID.of)) : []
        for (id, bar) in extras where !wanted.contains(id) {
            bar.tearDown()
            extras[id] = nil
        }
        for id in wanted where extras[id] == nil {
            let bar = TaskbarController(tracker: tracker, nowPlaying: main.nowPlaying, displayID: id)
            extras[id] = bar
            bar.show()
        }
        for bar in bars { bar.layout(); bar.refreshShown() }
    }

    /// Whether a screen has a taskbar along its bottom.
    static func hasBar(_ s: NSScreen) -> Bool {
        s == NSScreen.screens.first || (allDisplays && NSScreen.screens.contains(s))
    }

    /// The screen a window is mostly on (AX frames are top-left based on the main screen).
    static func screen(of w: TrackedWindow) -> NSScreen? {
        guard let f = AX.frame(w.element) else { return nil }
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height)
        func overlap(_ s: NSScreen) -> CGFloat { let r = s.frame.intersection(cocoa); return r.isNull ? 0 : r.width * r.height }
        return NSScreen.screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
    }
}
