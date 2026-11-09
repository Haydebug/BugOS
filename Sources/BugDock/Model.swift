import AppKit
import UniformTypeIdentifiers
import ApplicationServices
import Combine
import BugOSKit

/// One taskbar button: every process + window of the same app (by bundle id) combined.
struct AppGroup: Identifiable, Equatable {
    let id: String              // bundle id, or "pid:N" for apps without one
    var name: String
    var bundleURL: URL?
    var pids: [pid_t]
    var windows: [TrackedWindow]
    var isPinned: Bool
    var isActive: Bool
    /// Running with windows on another desktop (or full screen) that this desktop can't list.
    var elsewhere = false

    var isRunning: Bool { !pids.isEmpty }
    var canPin: Bool { !id.hasPrefix("pid:") && bundleURL != nil }
}

struct PinnedApp: Codable, Equatable {
    var bundleID: String
    var path: String
    var name: String
}

@MainActor
final class PinStore {
    private(set) var items: [PinnedApp]
    var onChange: (() -> Void)?
    private let key = "pinnedApps"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([PinnedApp].self, from: data) {
            items = saved
        } else {
            items = []
        }
        if !UserDefaults.standard.bool(forKey: "migratedUnpinFinder") {
            UserDefaults.standard.set(true, forKey: "migratedUnpinFinder")
            items.removeAll { $0.bundleID == "com.apple.finder" }
            if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    func isPinned(_ id: String) -> Bool { items.contains { $0.bundleID == id } }

    func pin(bundleID: String, url: URL, name: String) {
        guard !isPinned(bundleID) else { return }
        items.append(PinnedApp(bundleID: bundleID, path: url.path, name: name))
        save()
    }

    func unpin(_ id: String) {
        items.removeAll { $0.bundleID == id }
        save()
    }

    func move(_ id: String, by offset: Int) {
        guard let i = items.firstIndex(where: { $0.bundleID == id }) else { return }
        let j = max(0, min(items.count - 1, i + offset))
        guard i != j else { return }
        items.insert(items.remove(at: i), at: j)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
        onChange?()
    }
}

/// The desktop (Space) you're on, as a number (private CoreGraphics call, as window managers use).
@_silgen_name("CGSMainConnectionID") nonisolated private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") nonisolated private func CGSGetActiveSpace(_ cid: Int32) -> Int
enum Desktop {
    nonisolated static var current: Int { CGSGetActiveSpace(CGSMainConnectionID()) }
}

@MainActor
final class IconCache: ObservableObject {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    /// Bumped when a custom icon changes, so the bar redraws.
    @Published private(set) var revision = 0

    private init() {
        // File Explorer went dark or light (its setting, or the Mac's): its icon changes.
        let refresh: (Notification) -> Void = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                IconCache.shared.cache[BugOSID.explorer] = nil
                IconCache.shared.revision += 1
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: BugOSID.explorerSettingsChanged, object: nil, queue: .main, using: refresh)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main, using: refresh)
    }

    /// Per-app custom icons chosen by the user: ~/Library/Application Support/BugDock/Icons/<bundle id>.png
    static var customDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BugDock/Icons", isDirectory: true)
    }
    static func customURL(_ id: String) -> URL { customDir.appendingPathComponent(id + ".png") }
    func hasCustomIcon(_ id: String) -> Bool { FileManager.default.fileExists(atPath: Self.customURL(id).path) }

    /// Save `image` as this app's custom icon (PNG), or remove it with nil.
    func setCustomIcon(_ image: NSImage?, for id: String) {
        let url = Self.customURL(id)
        if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: Self.customDir, withIntermediateDirectories: true)
            try? png.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        cache[id] = nil
        revision += 1
    }

    func icon(for g: AppGroup) -> NSImage {
        if let i = cache[g.id] { return i }
        var img: NSImage
        if let custom = NSImage(contentsOf: Self.customURL(g.id)) {
            img = custom
        } else if g.id == BugOSID.explorer, ExplorerSetting.iconIsDark, let url = g.bundleURL,
                  let dark = NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/AppIconDark.icns")) {
            img = dark   // File Explorer is in dark mode
        } else if g.id == "com.apple.finder" {
            // A plain folder rather than Finder's face.
            img = NSWorkspace.shared.icon(for: .folder)
        } else if let url = g.bundleURL {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else if let pid = g.pids.first, let i = NSRunningApplication(processIdentifier: pid)?.icon {
            img = i
        } else {
            img = NSWorkspace.shared.icon(for: .application)
        }
        img.size = NSSize(width: 64, height: 64)
        cache[g.id] = img
        return img
    }

    func icon(forPath path: String) -> NSImage {
        if let i = cache[path] { return i }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 64, height: 64)
        cache[path] = img
        return img
    }
}

/// Watches running apps + their windows and publishes the taskbar's button list.
@MainActor
final class WindowTracker: ObservableObject {
    @Published private(set) var groups: [AppGroup] = []
    @Published private(set) var axTrusted = AX.isTrusted

    /// Re-read settings the BugOS page changed.
    func reloadSettings() {
        let v = UserDefaults.standard.bool(forKey: "showWindowlessApps")
        if v != showWindowlessApps { showWindowlessApps = v }
        perDesktop.removeAll()   // e.g. "Show apps from" changed: what each desktop showed no longer holds
        scheduleRefresh()
    }

    /// Windows-style default: only apps that actually have a window (plus pins).
    var showWindowlessApps = UserDefaults.standard.bool(forKey: "showWindowlessApps") {
        didSet { UserDefaults.standard.set(showWindowlessApps, forKey: "showWindowlessApps"); scheduleRefresh() }
    }

    let pins: PinStore
    let fitter = WindowFitter()
    /// Left-to-right order of every button (pinned and running), changed by dragging. Persisted.
    private var order: [String] = UserDefaults.standard.stringArray(forKey: "taskbarOrder") ?? []
    private let axQueue = DispatchQueue(label: "com.bugos.dock.ax", qos: .userInitiated)
    private var inFlight = false
    private var pending = false
    private var observers: [pid_t: AXObserver] = [:]
    private var timer: Timer?

    init(pins: PinStore) {
        self.pins = pins
        pins.onChange = { [weak self] in self?.scheduleRefresh() }

        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for n in names {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if n == NSWorkspace.activeSpaceDidChangeNotification {
                        self.desktopChanged(via: "macOS signal")
                    } else {
                        self.scheduleRefresh()
                    }
                }
            }
        }
        // Safety net for anything the AX notifications miss (e.g. a closed window). Skipped when a refresh
        // ran in the last second anyway (they come with every app switch, window and title change).
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = AX.isTrusted
                if t != self.axTrusted { self.axTrusted = t }
                if Date().timeIntervalSince(self.lastRefresh) >= 0.9 { self.scheduleRefresh() }
            }
        }
        timer?.tolerance = 0.2
        scheduleRefresh()
    }

    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.scheduleRefresh() }
    }

    // MARK: Switching desktops

    /// Each desktop's last-known apps, so the bar shows them the moment you switch (no blank bar while
    /// macOS animates), then confirms once the animation is over.
    private var perDesktop: [Int: [AppGroup]] = [:]
    /// Readings taken before this moment come from mid-animation (the new desktop's windows aren't
    /// reported yet) and are thrown away.
    private var settleUntil = Date.distantPast

    /// The desktop the bar is showing. (macOS reports a switch only once its animation has finished, and
    /// the desktop ID changes no earlier, measured 2026-11-09; so the signal is all there is to go on.)
    private var shownDesktop = Desktop.current

    private func desktopChanged(via source: String) {
        let d = Desktop.current
        shownDesktop = d
        // All desktops: the bar doesn't change when you switch, so there's nothing to swap.
        if !Self.allDesktops, let known = perDesktop[d], known != groups { groups = known }
        settleUntil = Date().addingTimeInterval(0.25)
        for delay in [0.26, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleRefresh() }
        }
    }

    /// Show apps from: all desktops (like the Mac Dock; nothing changes when you switch) or only this one
    /// (like Windows' default). Default: this desktop.
    static var allDesktops: Bool { UserDefaults.standard.string(forKey: DockSetting.appsFromDesktops) == "all" }

    /// Apps that only run one copy (a second launch goes to the running one), so they can't open on this
    /// desktop: they stay on every desktop's bar while they have a window anywhere, and a click takes you to it.
    /// Some are known; the rest are learned the first time a click ends up going to their window.
    static let knownOneCopy: Set<String> = [
        "com.hnc.Discord", "com.spotify.client", "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "us.zoom.xos",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.facebook.archon", "com.valvesoftware.steam",
    ]
    static var oneCopy: Set<String> {
        let learned = UserDefaults.standard.stringArray(forKey: "oneCopyApps") ?? []
        return knownOneCopy.union(learned)
    }
    static func learnOneCopy(_ id: String) {
        guard !oneCopy.contains(id) else { return }
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: "oneCopyApps") ?? []) + [id], forKey: "oneCopyApps")
        log("learned: \(id) runs one copy")
    }

    static func log(_ s: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Bug OS.log")
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile(); h.write(Data("\(Date()) Taskbar \(s)\n".utf8)); try? h.close()
    }

    /// When the last refresh started (the safety net skips a beat after one).
    private var lastRefresh = Date.distantPast
    private var coalescing = false

    /// From AX notifications, which come in bursts (a page loading changes Chrome's title several times, a
    /// new window sends created + focused + main changed): one refresh for the burst, a frame later.
    func refreshCoalesced() {
        guard !coalescing else { return }
        coalescing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.coalescing = false
            self.scheduleRefresh()
        }
    }

    func scheduleRefresh() {
        if inFlight { pending = true; return }
        inFlight = true
        lastRefresh = Date()
        let desktopAtStart = Desktop.current
        let startedAt = Date()
        let allDesktops = Self.allDesktops

        let me = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
        let pids = apps.map(\.processIdentifier)
        let oneCopy = Self.oneCopy
        let oneCopyPids = Set(apps.filter { $0.bundleIdentifier.map(oneCopy.contains) ?? false }.map(\.processIdentifier))
        let hidden = Set(apps.filter(\.isHidden).map(\.processIdentifier))
        let trusted = AX.isTrusted
        if trusted { syncObservers(pids); fitter.sync(pids) }

        axQueue.async { [weak self] in
            var byPid: [pid_t: [TrackedWindow]] = [:]
            var elsewhere = Set<pid_t>(), fullScreenElsewhere = Set<pid_t>()
            if trusted {
                let onScreen = WindowMatch.onScreenWindows()   // current desktop only; one call for all apps
                for pid in pids {
                    // All desktops (BugOS › Taskbar): every window the app has, wherever it is.
                    byPid[pid] = allDesktops ? WindowReader.windows(pid: pid)
                        : WindowReader.windows(pid: pid, onScreen: onScreen[pid] ?? [], appHidden: hidden.contains(pid))
                }
                (elsewhere, fullScreenElsewhere) = WindowMatch.appsWithWindowsElsewhere()
                // "This desktop": from elsewhere, only full-screen apps (their desktop is their own) and one-copy
                // apps (they can't open here, so they stay on the bar and a click goes to them).
                if !allDesktops { elsewhere = fullScreenElsewhere.union(elsewhere.intersection(oneCopyPids)) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Taken mid-switch, or you've moved to another desktop since: not this desktop's apps.
                    if startedAt >= self.settleUntil, Desktop.current == desktopAtStart {
                        self.apply(apps: apps, windows: byPid, elsewhere: elsewhere, trusted: trusted)
                        self.perDesktop[desktopAtStart] = self.groups
                    }
                    self.inFlight = false
                    if self.pending { self.pending = false; self.scheduleRefresh() }
                }
            }
        }
    }

    private func apply(apps: [NSRunningApplication], windows: [pid_t: [TrackedWindow]], elsewhere: Set<pid_t>, trusted: Bool) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var byKey: [String: AppGroup] = [:]
        var keysInLaunchOrder: [String] = []

        for app in apps {
            let pid = app.processIdentifier
            let key = app.bundleIdentifier ?? "pid:\(pid)"
            let w = windows[pid] ?? []
            if var g = byKey[key] {
                g.pids.append(pid)
                g.windows += w
                if pid == front { g.isActive = true }
                if elsewhere.contains(pid) { g.elsewhere = true }
                byKey[key] = g
            } else {
                var g = AppGroup(id: key, name: app.localizedName ?? key, bundleURL: app.bundleURL,
                                 pids: [pid], windows: w, isPinned: false, isActive: pid == front)
                g.elsewhere = elsewhere.contains(pid)
                byKey[key] = g
                keysInLaunchOrder.append(key)
            }
        }

        // Every running app, shown or not (an app with no windows on this desktop is still running).
        let running = Set(byKey.keys)
        var visible: [String: AppGroup] = [:]
        for pin in pins.items {
            if var g = byKey.removeValue(forKey: pin.bundleID) {
                g.isPinned = true
                visible[pin.bundleID] = g
            } else {
                visible[pin.bundleID] = AppGroup(id: pin.bundleID, name: pin.name, bundleURL: URL(fileURLWithPath: pin.path),
                                                 pids: [], windows: [], isPinned: true, isActive: false)
            }
        }
        // `elsewhere` already follows "Show apps from": with "This desktop" only full-screen apps count, so an
        // app whose windows are on another desktop is off the bar like on Windows.
        for (k, g) in byKey where !trusted || showWindowlessApps || !g.windows.isEmpty || g.elsewhere { visible[k] = g }

        // Pinned apps keep their spot forever; unpinned ones keep it while they're running, even while they're
        // off the bar because their windows are on another desktop, and go on the end once they've quit and
        // come back (like Windows). (Forgetting them on every desktop switch reset your arrangement.)
        let before = order
        order.removeAll { visible[$0] == nil && !running.contains($0) }
        for p in pins.items where !order.contains(p.bundleID) { order.append(p.bundleID) }
        for k in keysInLaunchOrder where visible[k] != nil && !order.contains(k) { order.append(k) }
        if order != before { saveOrder() }

        let result = order.compactMap { visible[$0] }
        if result != groups { groups = result }
    }

    /// Called after a drag on the bar.
    func setOrder(_ ids: [String]) {
        // The dragged (visible) apps take their new order in the slots they already had; apps hidden on
        // another desktop keep their place in between.
        let moved = Set(ids)
        var next = ids.makeIterator()
        var merged = order.map { moved.contains($0) ? (next.next() ?? $0) : $0 }
        for extra in IteratorSequence(next) where !merged.contains(extra) { merged.append(extra) }
        order = merged
        saveOrder()
        groups = order.compactMap { id in groups.first { $0.id == id } }
    }

    private func saveOrder() {
        UserDefaults.standard.set(order.filter { !$0.hasPrefix("pid:") }, forKey: "taskbarOrder")
    }

    // MARK: AX observers (instant updates when windows open/close/rename)

    private func syncObservers(_ pids: [pid_t]) {
        let live = Set(pids)
        for (pid, obs) in observers where !live.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observers[pid] = nil
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pid in pids where observers[pid] == nil {
            var obs: AXObserver?
            guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { continue }
            let appEl = AX.app(pid)
            // App not ready yet (just launched)? Try again on the next refresh.
            guard AXObserverAddNotification(obs, appEl, kAXWindowCreatedNotification as CFString, refcon) == .success else { continue }
            for n in [kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(obs, appEl, n as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observers[pid] = obs
        }
    }

    // MARK: Clicks

    func clicked(_ g: AppGroup) {
        guard g.isRunning else {
            if let url = g.bundleURL { WindowActions.open(url) }
            return
        }
        let wins = g.windows
        if wins.isEmpty {
            // Its windows are on another desktop: bring the app forward, which goes there (opening it
            // again would make some apps start a new window here instead).
            if g.elsewhere, let pid = g.pids.first {
                NSRunningApplication(processIdentifier: pid)?.activate()
                refreshSoon()
                return
            }
            // Running, but its windows are all on other desktops ("This desktop" + "Open apps on this desktop"):
            // open it here, like Windows. macOS only jumps to another desktop when an app has no window on this
            // one, so it stays when a new copy or a new window appears here.
            let stay = !Self.allDesktops && (UserDefaults.standard.object(forKey: DockSetting.stayOnDesktop) as? Bool ?? true)
            if stay, g.isRunning, let url = g.bundleURL, let pid = g.pids.first {
                let before = Set(g.pids), desktop = Desktop.current, id = g.id
                // Known one-copy app (Discord): straight to its window, no second launch.
                if Self.oneCopy.contains(id) {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                    refreshSoon()
                    return
                }
                // 1. A new instance (what you'd get on Windows). A one-copy app (Discord) hands that to its running
                //    copy, which comes forward with no window here, so macOS takes you to its window.
                WindowActions.newInstance(url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    let alive = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
                    let newCopy = alive.contains { !before.contains($0.processIdentifier) && $0.isFinishedLaunching }
                    let hereNow = self.groups.first { $0.id == id }.map { !$0.windows.isEmpty } ?? false
                    if !newCopy, !hereNow, Desktop.current != desktop { Self.learnOneCopy(id) }   // it handed over and went there
                    guard !newCopy, !hereNow, Desktop.current == desktop else { self.refreshSoon(); return }
                    // 2. Still nothing here: its own File › New Window, made before it comes forward.
                    if WindowActions.newWindowHere(pid: pid) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSRunningApplication(processIdentifier: pid)?.activate() }
                    } else {
                        // 3. Neither: go to its window (macOS switches desktops), and remember it runs one copy.
                        NSRunningApplication(processIdentifier: pid)?.activate()
                        Self.learnOneCopy(id)
                    }
                    self.refreshSoon()
                }
                return
            }
            if let url = g.bundleURL { WindowActions.open(url) }
            else if let pid = g.pids.first { NSRunningApplication(processIdentifier: pid)?.activate() }
            refreshSoon()
            return
        }

        let focused = g.isActive ? focusedWindow(in: g) : nil
        if wins.count == 1 {
            let w = wins[0]
            if let f = focused, CFEqual(f.element, w.element), !w.isMinimized {
                WindowActions.minimize(w)      // click the active app again = minimize (Windows behaviour)
            } else {
                WindowActions.focus(w)
            }
        } else if !g.isActive {
            WindowActions.focus(wins.first { !$0.isMinimized } ?? wins[0])
        } else {
            // Already in front: cycle through its windows.
            let others = wins.filter { w in focused.map { !CFEqual($0.element, w.element) } ?? true }
            if let next = others.last(where: { !$0.isMinimized }) ?? others.first {
                WindowActions.focus(next)
            }
        }
        refreshSoon()
    }

    func focusedWindow(in g: AppGroup) -> TrackedWindow? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              g.pids.contains(front),
              let el = WindowReader.focusedWindow(pid: front) else { return nil }
        return g.windows.first { CFEqual($0.element, el) }
    }

    func quit(_ g: AppGroup) {
        for pid in g.pids { NSRunningApplication(processIdentifier: pid)?.terminate() }
        refreshSoon()
    }

    func togglePin(_ g: AppGroup) {
        if g.isPinned { pins.unpin(g.id) }
        else if let url = g.bundleURL { pins.pin(bundleID: g.id, url: url, name: g.name) }
    }
}

private let axCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { tracker.refreshCoalesced() }
}
