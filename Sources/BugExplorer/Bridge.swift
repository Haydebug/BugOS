import AppKit
import BugOSKit
import ApplicationServices

/// The Save/Open bridge: when another app shows Apple's Save or Open dialog, File Explorer shows
/// its own Windows-style window over it, then fills Apple's dialog in with your choice.
/// Rule: fail open. If any step can't be verified, our window goes away and Apple's dialog is left as is.
final class Bridge {
    static let shared = Bridge()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "bridgeEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeEnabled"); newValue ? start() : stop() }
    }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var trustTimer: Timer?
    private var picker: PickerController?
    private var target: NSRunningApplication?
    private var released: AXUIElement?          // a dialog the user chose to handle with Apple's UI
    private var watchTimer: Timer?
    private var predictionDeadline: Date?
    private var predictionKey = ""
    private var driving = false

    private let excluded: Set<String> = ["com.apple.finder", "com.bugos.explorer",
                                         "com.apple.Terminal", "com.googlecode.iterm2"]

    // MARK: Start / stop

    func start() {
        guard enabled else { return }
        guard AXK.trusted else {
            if !BugOSChild.isChild { AXK.askForTrust() }   // under BugOS, its setup window asks
            // Keep checking quietly; start as soon as Accessibility is turned on.
            trustTimer?.invalidate()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if AXK.trusted { t.invalidate(); self?.start() }
            }
            return
        }
        installTap()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let front = NSWorkspace.shared.frontmostApplication { observe(front) }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        unobserve()
        finish(close: true)
    }

    var isRunning: Bool { tap != nil }

    // MARK: Keyboard: predict a dialog from ⌘⇧S / ⌘S / ⌘O so our window is up before Apple's draws

    private enum Trigger: String { case save, saveAs, open }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<Bridge>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type == .keyDown {
                me.keyDown(event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func keyDown(_ e: CGEvent) {
        let f = e.flags
        guard f.contains(.maskCommand), !f.contains(.maskControl) else { return }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let trigger: Trigger
        switch code {
        case 1: trigger = f.contains(.maskShift) ? .saveAs : .save     // S
        case 31: if f.contains(.maskShift) { return }; trigger = .open  // O
        default: return
        }
        DispatchQueue.main.async { self.predict(trigger) }
    }

    private func predict(_ trigger: Trigger) {
        guard picker == nil, !driving, let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier, !excluded.contains(bid) else { return }
        let key = "\(bid)|\(trigger.rawValue)"
        // Learn: if this shortcut in this app twice didn't open a dialog, stop predicting there.
        if (misses[key] ?? 0) >= 2 { return }
        let win = AXK.focusedWindow(app.processIdentifier)
        if trigger == .save {
            // Plain ⌘S only asks where to save for documents that were never saved.
            if let w = win, let doc = AXK.str(w, kAXDocumentAttribute), !doc.isEmpty { return }
            let t = win.map(AXK.title) ?? ""
            if !t.lowercased().hasPrefix("untitled") { return }
        }
        predictionKey = key
        predictionDeadline = Date().addingTimeInterval(1.0)
        showPicker(kind: trigger == .open ? .open : .save, app: app, cover: win.flatMap(AXK.frame), panel: nil)
        startWatching()
    }

    private var misses: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "bridgeMisses") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeMisses") }
    }

    // MARK: Accessibility: notice dialogs we didn't predict (menu clicks, "Choose file…" buttons)

    @objc private func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        observe(app)
    }

    private func observe(_ app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier, !excluded.contains(bid) else { return }
        let pid = app.processIdentifier
        guard pid != observedPid else { return }
        unobserve()
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            let me = Unmanaged<Bridge>.fromOpaque(refcon!).takeUnretainedValue()
            DispatchQueue.main.async { me.somethingAppeared() }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXSheetCreatedNotification, kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(obs, appEl, n as CFString, ref)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPid = pid
    }

    private func unobserve() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil
        observedPid = 0
    }

    private func somethingAppeared() {
        guard picker == nil, !driving, observedPid != 0 else { return }
        guard let p = ApplePanel.find(in: observedPid), !isReleased(p),
              let app = NSRunningApplication(processIdentifier: observedPid) else { return }
        showPicker(kind: p.kind == .save ? .save : .open, app: app, cover: p.frame, panel: p)
        startWatching()
    }

    private func isReleased(_ p: ApplePanel) -> Bool {
        guard let r = released else { return false }
        if AXK.frame(r) == nil { released = nil; return false }      // that dialog has closed
        return CFEqual(r, p.element)
    }

    // MARK: Picker

    private func showPicker(kind: PickerController.Kind, app: NSRunningApplication, cover: CGRect?, panel: ApplePanel?) {
        target = app
        let bid = app.bundleIdentifier ?? ""
        let start = lastFolder(for: bid) ?? FS.home.appendingPathComponent(kind == .save ? "Desktop" : "Downloads")
        let p = PickerController(kind: kind, appName: app.localizedName ?? "App", startDir: start, cover: cover)
        p.onCancel = { [weak self] in self?.cancel() }
        p.onNative = { [weak self] in self?.useNative() }
        p.onSave = { [weak self] dir, name in self?.save(dir: dir, name: name) }
        p.onOpen = { [weak self] url in self?.open(url) }
        picker = p
        if let panel { p.attach(panel) }
        p.show()
    }

    /// While our window is up: attach to Apple's dialog once it exists, and notice if it goes away.
    private func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(watchTimer!, forMode: .common)
    }

    private func tick() {
        guard let picker, let target, !driving else { return }
        let pid = target.processIdentifier
        if picker.panel == nil {
            if let p = ApplePanel.find(in: pid) {
                picker.attach(p)
                if !predictionKey.isEmpty { var m = misses; m[predictionKey] = 0; misses = m; predictionKey = "" }
            } else if let d = predictionDeadline, Date() > d {
                // We guessed a dialog was coming and none did: remember, and get out of the way.
                if !predictionKey.isEmpty { var m = misses; m[predictionKey, default: 0] += 1; misses = m; predictionKey = "" }
                finish(close: true, reactivate: true)
            }
        } else if let p = picker.panel, !p.isOpen {
            finish(close: true)          // the app closed its dialog itself
        }
    }

    private func finish(close: Bool, reactivate: Bool = false) {
        watchTimer?.invalidate(); watchTimer = nil
        predictionDeadline = nil
        if close { picker?.close() }
        picker = nil
        if reactivate { target?.activate() }
        target = nil
    }

    private func lastFolder(for bid: String) -> URL? {
        guard let p = (UserDefaults.standard.dictionary(forKey: "bridgeLastFolder") as? [String: String])?[bid] else { return nil }
        let u = URL(fileURLWithPath: p)
        return FS.isDirectory(u) ? u : nil
    }
    private func remember(_ dir: URL, for bid: String) {
        var d = UserDefaults.standard.dictionary(forKey: "bridgeLastFolder") as? [String: String] ?? [:]
        d[bid] = dir.path
        UserDefaults.standard.set(d, forKey: "bridgeLastFolder")
    }

    // MARK: Actions

    private func cancel() {
        guard let picker, let target else { finish(close: true); return }
        let panel = picker.panel
        finish(close: true)
        target.activate()
        if let c = panel?.cancelButton { AXK.press(c) }
    }

    /// Hand over to Apple's dialog (and don't take it over again).
    private func useNative() {
        guard let picker, let target else { return }
        released = picker.panel?.element
        finish(close: true)
        target.activate()
    }

    private func fail(_ why: String) {
        NSLog("File Explorer bridge: %@ — showing Apple's dialog", why)
        driving = false
        useNative()
    }

    private func save(dir: URL, name: String) {
        guard let picker, let panel = picker.panel, let target else { return }
        driving = true
        picker.setBusy("Saving…")
        guard bringForward(target) else { return fail("couldn't switch back to the app") }
        guard let nameField = panel.nameField else { return fail("no name box") }
        AXK.set(nameField, kAXFocusedAttribute, kCFBooleanTrue)
        guard goTo(dir.path, in: panel) else { return fail("Go to folder didn't work") }
        // Check Apple's dialog really is in the folder we picked before saving anything.
        let wanted = [FS.displayName(dir), dir.lastPathComponent]
        guard wait(1.5, { wanted.contains { w in panel.whereValue.contains(w) } }) else {
            return fail("folder check failed (\(panel.whereValue))")
        }
        AXK.set(nameField, kAXFocusedAttribute, kCFBooleanTrue)
        AXK.set(nameField, kAXValueAttribute, name as CFString)
        guard wait(0.5, { AXK.value(nameField) == name }) else { return fail("name check failed") }
        guard let ok = panel.okButton, AXK.press(ok) else { return fail("couldn't press Save") }
        // If the file exists Apple asks again; we already asked you, so confirm "Replace".
        _ = wait(1.0) {
            if let r = self.replaceButton(target.processIdentifier) { AXK.press(r); return true }
            return !panel.isOpen
        }
        guard wait(3.0, { !panel.isOpen }) else { return fail("dialog didn't close after Save") }
        remember(dir, for: target.bundleIdentifier ?? "")
        driving = false
        finish(close: true)
    }

    private func open(_ url: URL) {
        guard let picker, let panel = picker.panel, let target else { return }
        driving = true
        picker.setBusy("Opening…")
        guard bringForward(target) else { return fail("couldn't switch back to the app") }
        guard goTo(url.path, in: panel) else { return fail("Go to file didn't work") }
        guard let ok = panel.okButton else { return fail("no Open button") }
        _ = wait(0.6) { (AXK.get(ok, kAXEnabledAttribute) as? Bool) == true }
        AXK.press(ok)
        guard wait(3.0, { !panel.isOpen }) else { return fail("the app didn't accept that file") }
        remember(url.deletingLastPathComponent(), for: target.bundleIdentifier ?? "")
        driving = false
        finish(close: true)
    }

    // MARK: Driving Apple's dialog

    private func bringForward(_ app: NSRunningApplication) -> Bool {
        app.activate()
        return wait(1.5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
    }

    /// ⌘⇧G ("Go to Folder"), type the path, Return.
    private func goTo(_ path: String, in panel: ApplePanel) -> Bool {
        AXK.key(5, [.maskCommand, .maskShift])
        var field: AXUIElement?
        guard wait(1.5, {
            for w in AXK.windows(panel.pid) {
                if let f = AXK.find(w, maxDepth: 18, { AXK.ident($0) == "PathTextField" }) { field = f; return true }
            }
            return false
        }), let field else { return false }
        AXK.set(field, kAXValueAttribute, path as CFString)
        AXK.key(36)   // Return
        return wait(1.5) {
            !AXK.windows(panel.pid).contains { w in AXK.find(w, maxDepth: 18, { AXK.ident($0) == "PathTextField" }) != nil }
        }
    }

    private func replaceButton(_ pid: pid_t) -> AXUIElement? {
        for w in AXK.windows(pid) {
            if let b = AXK.find(w, maxDepth: 10, { AXK.role($0) == kAXButtonRole as String && AXK.title($0) == "Replace" }) { return b }
        }
        return nil
    }

    private func wait(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }
}
