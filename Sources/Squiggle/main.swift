// Squiggle: Windows 11 Snipping Tool behaviour for macOS.
//   Shortcuts are set on the BugOS page (defaults: ⇧⌘5 / PrtSc (F13) → Snip / Record bar,
//   ⇧⌘3 → area snip, ⇧⌘4 → snip & draw in place, ⇧⌘2 → quick area snip).
// A snip is copied immediately and shows a thumbnail in the bottom-right; click it to draw on it.
import AppKit
import BugOSKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Squiggle.log")
func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

func screenUnderMouse() -> NSScreen {
    let m = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

/// 1-based display index as `screencapture -D` expects.
func displayIndex(of screen: NSScreen) -> Int {
    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return 1 }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return (ids.firstIndex(of: id) ?? 0) + 1
}

/// Hot key ids: Esc is fixed; the rest are numbered from the action list (BugOS › Squiggle › Shortcuts).
let escapeHotKeyID: UInt32 = 99

final class App: NSObject, NSApplicationDelegate {
    var editors: [EditorWindow] = []
    var videoEditors: [VideoEditorWindow] = []
    var session: CaptureSession?
    var recorder: Recorder?
    var toast: Toast?
    var capturing = false
    var hotKeyRefs: [EventHotKeyRef?] = []
    var escRef: EventHotKeyRef?

    /// Esc is grabbed globally only while the PrtSc bar is up, so it closes the bar no matter which app has focus.
    func setEscapeGrab(_ on: Bool) {
        if on, escRef == nil {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x5351_4747), id: escapeHotKeyID),
                                GetApplicationEventTarget(), 0, &escRef)
        } else if !on, let r = escRef {
            UnregisterEventHotKey(r)
            escRef = nil
        }
    }

    /// Each action's shortcuts (BugOS › Squiggle › Shortcuts).
    var shortcuts: [String: [Shortcut]] = [:]
    var hotKeyHandlerInstalled = false
    var freezing = false

    func applicationDidFinishLaunching(_ n: Notification) {
        registerHotKeys()   // no menu-bar icon: shortcuts, the quick corner and the BugOS page start everything
        // The BugOS page changed a Squiggle setting.
        DistributedNotificationCenter.default().addObserver(forName: BugOSID.squiggleSettingsChanged, object: nil, queue: .main) { [weak self] n in
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            // "pause": the page is recording a new shortcut, so let every key through until it's done.
            switch n.object as? String {
            case "pause": self?.unregisterHotKeys(); return       // the page is recording a new shortcut
            case "openVideo": self?.menuOpenVideo(); return       // BugOS › Squiggle › Draw on a Recording…
            case "snip": self?.menuSelector(); return
            default: break
            }
            self?.registerHotKeys()
        }
        log("started")
    }

    // MARK: Hotkeys

    /// (Re)register every action's shortcuts. Hot key id = action index * 10 + shortcut index + 1.
    func registerHotKeys() {
        if !hotKeyHandlerInstalled {
            hotKeyHandlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { app.hotKey(id) }
                return noErr
            }, 1, &spec, nil, nil)
        }
        unregisterHotKeys()
        let saved = UserDefaults.standard.dictionary(forKey: SquiggleSetting.shortcuts) as? [String: String] ?? [:]
        shortcuts = SquiggleShortcuts.resolve(saved)
        for (ai, action) in SquiggleShortcuts.actions.enumerated() {
            for (si, k) in (shortcuts[action.id] ?? []).enumerated() {
                var ref: EventHotKeyRef?
                let id = UInt32(ai * 10 + si + 1)
                let st = RegisterEventHotKey(k.keyCode, k.mods, EventHotKeyID(signature: OSType(0x5351_4747), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
                hotKeyRefs.append(ref)
                log("hotkey \(action.id) \(k.display) status=\(st)")
            }
        }
    }

    func unregisterHotKeys() {
        for r in hotKeyRefs { if let r { UnregisterEventHotKey(r) } }
        hotKeyRefs = []
    }

    func hotKey(_ id: UInt32) {
        if id == escapeHotKeyID { session?.end(); return }
        let i = Int(id - 1) / 10
        guard i < SquiggleShortcuts.actions.count else { return }
        switch SquiggleShortcuts.actions[i].id {
        case "selector":                 // full options bar; stops a recording
            if let r = recorder { r.stop() } else { showSelector() }
        case "record":
            if let r = recorder { r.stop() } else { showSelector(mode: .record) }
        case "area": showSelector(showBar: false)                       // boxed snip → copied + thumbnail
        case "drawInPlace": showSelector(showBar: false, editInPlace: true)
        case "quickArea": snip(.rectangle)
        case "fullScreen": snip(.fullScreen)
        default: break
        }
    }

    @objc func menuSelector() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showSelector() } }
    @objc func menuRecord() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showSelector(mode: .record) } }
    @objc func menuArea() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showSelector(showBar: false) } }
    @objc func menuDrawInPlace() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showSelector(showBar: false, editInPlace: true) } }
    @objc func menuFull() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.snip(.fullScreen) } }
    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveFolder)
    }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Selector

    /// PrtSc: dim the screen with the mouse already a rectangle snipper; the top bar switches modes.
    func showSelector(mode: CaptureMode = .snip, showBar: Bool = true, editInPlace: Bool = false) {
        if let s = session { s.end(); return }
        guard !capturing, recorder == nil || showBar else { return }
        guard !freezing else { return }
        // Freeze the screen first, before Squiggle takes focus (which would close menus and hover effects).
        freezing = true
        FrozenScreens.capture { [weak self] frozen in
            self?.freezing = false
            self?.beginSelector(mode: mode, showBar: showBar, editInPlace: editInPlace, frozen: frozen)
        }
    }

    private func beginSelector(mode: CaptureMode, showBar: Bool, editInPlace: Bool, frozen: FrozenScreens) {
        guard session == nil else { return }
        let s = CaptureSession()
        s.frozen = frozen
        s.mode = mode
        s.showBar = showBar
        s.onEnd = { [weak self] in self?.setEscapeGrab(false); self?.session = nil }
        s.onTarget = { [weak self] mode, target in
            // A snip comes straight from the frozen screens; without them (no permission yet), or for a
            // recording, wait for the overlay to go before grabbing live pixels.
            if mode == .snip, let self, self.snipFrozen(target, frozen: frozen, editInPlace: editInPlace) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if mode == .snip { self?.snip(target, editInPlace: editInPlace) } else { self?.record(target) }
            }
        }
        session = s
        setEscapeGrab(true)
        s.begin()
    }

    // MARK: Snip

    func snip(_ shape: CaptureShape) {
        guard !capturing, recorder == nil else { return }
        capturing = true
        let screen = screenUnderMouse()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("squiggle-\(UUID().uuidString).png")
        var args: [String]
        switch shape {
        case .rectangle: args = ["-i", "-x", "-o"]
        case .window: args = ["-i", "-W", "-x", "-o"]
        case .fullScreen: args = ["-x", "-D", "\(displayIndex(of: screen))"]
        }
        args.append(url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.capturing = false
                self.snipped(url: url, screen: screen)
            }
        }
        do { try p.run() } catch { capturing = false; log("screencapture failed: \(error)") }
    }

    /// Capture exactly what was picked in the PrtSc overlay.
    func snip(_ target: CaptureTarget, editInPlace: Bool = false) {
        guard !capturing else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("squiggle-\(UUID().uuidString).png")
        var args = ["-x"]
        let screen: NSScreen
        var placeAt: NSRect?
        switch target {
        case .rect(let r, let scr):
            let mainH = NSScreen.screens.first?.frame.height ?? 0
            args += ["-R", "\(Int(r.minX)),\(Int(mainH - r.maxY)),\(Int(r.width)),\(Int(r.height))"]
            screen = scr
            placeAt = r
        case .window(let id, let r, let scr):
            args += ["-o", "-l", "\(id)"]
            screen = scr
            placeAt = r
        case .screen(let scr):
            args += ["-D", "\(displayIndex(of: scr))"]
            screen = scr
        }
        args.append(url.path)
        capturing = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.capturing = false
                self.snipped(url: url, screen: screen, editAt: editInPlace ? (placeAt ?? screen.frame) : nil)
            }
        }
        do { try p.run() } catch { capturing = false; log("screencapture failed: \(error)") }
    }

    /// The picked area, window or screen, cut from the frozen screens. False if there's no frozen picture.
    func snipFrozen(_ target: CaptureTarget, frozen: FrozenScreens, editInPlace: Bool) -> Bool {
        let cg: CGImage?, screen: NSScreen, placeAt: NSRect?
        switch target {
        case .rect(let r, let scr): cg = frozen.crop(r, on: scr); screen = scr; placeAt = r
        case .window(_, let r, let scr): cg = frozen.crop(r, on: scr); screen = scr; placeAt = r
        case .screen(let scr): cg = frozen.image(for: scr); screen = scr; placeAt = nil
        }
        guard let cg else { return false }
        let size = NSSize(width: CGFloat(cg.width) / screen.backingScaleFactor, height: CGFloat(cg.height) / screen.backingScaleFactor)
        snipped(cg: cg, size: size, screen: screen, editAt: editInPlace ? (placeAt ?? screen.frame) : nil)
        return true
    }

    func snipped(url: URL, screen: NSScreen, editAt: NSRect? = nil) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return } // cancelled
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let s = CGFloat(dpi / 72)
        let size = NSSize(width: CGFloat(cg.width) / s, height: CGFloat(cg.height) / s)
        snipped(cg: cg, size: size, screen: screen, editAt: editAt)
    }

    /// A snip: copied straight away, then the corner thumbnail (or the editor in place).
    func snipped(cg: CGImage, size: NSSize, screen: NSScreen, editAt: NSRect? = nil) {

        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        copyImageToClipboard(rep)

        let thumb = NSImage(cgImage: cg, size: size)
        if let r = editAt { openEditor(cg: cg, size: size, screen: screen, placeAt: r); return }
        guard UserDefaults.standard.object(forKey: SquiggleSetting.showThumbnail) as? Bool ?? true else { return }
        showToast(thumb, title: "Snip copied to clipboard", subtitle: "Click to draw on it, save, or Save As") { [weak self] in
            self?.openEditor(cg: cg, size: size, screen: screenUnderMouse())
        }
    }

    func showToast(_ image: NSImage, title: String, subtitle: String, onClick: @escaping () -> Void) {
        toast?.dismiss()
        let t = Toast(thumbnail: image, title: title, subtitle: subtitle, screen: screenUnderMouse())
        t.onClick = onClick
        toast = t
        t.show()
    }

    /// While an editor is open, Squiggle is a normal app (on the taskbar and in ⌘-Tab), so a window that went
    /// behind others is easy to get back to; with none open it's back in the background.
    func updateDockPresence() {
        let want: NSApplication.ActivationPolicy = editors.isEmpty && videoEditors.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    func openEditor(cg: CGImage, size: NSSize, screen: NSScreen, placeAt: NSRect? = nil) {
        let w = EditorWindow(cgImage: cg, pointSize: size, screen: screen, placeAt: placeAt)
        w.onClosed = { [weak self] win in self?.editors.removeAll { $0 === win }; self?.updateDockPresence() }
        editors.append(w)
        updateDockPresence()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(w.canvas)
    }

    func openVideoEditor(_ url: URL) {
        guard let w = VideoEditorWindow(url: url, screen: screenUnderMouse()) else { NSWorkspace.shared.open(url); return }
        w.onClosed = { [weak self] win in self?.videoEditors.removeAll { $0 === win }; self?.updateDockPresence() }
        videoEditors.append(w)
        updateDockPresence()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc func menuOpenVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.directoryURL = recordingsFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let u = panel.url { openVideoEditor(u) }
    }

    // MARK: Record

    func record(_ target: CaptureTarget) {
        guard recorder == nil else { return }
        switch target {
        case .rect(let r, let scr): startRecording(rect: r, screen: scr)
        case .window(_, let r, let scr): startRecording(rect: r.intersection(scr.frame), screen: scr)
        case .screen(let scr): startRecording(rect: scr.frame, screen: scr)
        }
    }

    func startRecording(rect: NSRect, screen: NSScreen) {
        let r = Recorder(rect: rect, screen: screen, mic: CaptureSession.micOn)
        recorder = r
        r.onFinish = { [weak self] url in
            self?.recorder = nil
            guard let url else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            videoThumbnail(url) { img in
                let thumb = img ?? NSImage(systemSymbolName: "video", accessibilityDescription: nil) ?? NSImage()
                self?.showToast(thumb, title: "Recording copied to clipboard", subtitle: "Click to watch it or draw on it") {
                    self?.openVideoEditor(url)
                }
            }
        }
        r.start(mic: CaptureSession.micOn, systemAudio: CaptureSession.systemAudioOn)
    }
}

// Inside BugOS, only BugOS may start Squiggle (so its permissions are BugOS's).
if BugOSChild.shouldHandOff { BugOSChild.handOff("start:squiggle") }

let app = App()
NSApplication.shared.delegate = app
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
