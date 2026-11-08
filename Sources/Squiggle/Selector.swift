// PrtSc capture session (Windows 11 style): the screen dims and the mouse is already a rectangle
// selector — one drag snips. The bar at the top switches Snip/Record and Rectangle/Window/Full screen.
import AppKit
import Carbon.HIToolbox

enum CaptureMode: Int { case snip = 0, record = 1 }
enum CaptureShape { case rectangle, window, fullScreen }

/// What the user picked.
enum CaptureTarget {
    case rect(NSRect, NSScreen)          // global Cocoa coords
    case window(CGWindowID, NSRect, NSScreen)
    case screen(NSScreen)
}

private var mainScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

/// On-screen windows (front to back) of other apps, in Cocoa coordinates.
private func windowsUnderneath() -> [(CGWindowID, NSRect)] {
    let me = ProcessInfo.processInfo.processIdentifier
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowOwnerPID as String] as? Int32) != me,
              let id = w[kCGWindowNumber as String] as? CGWindowID,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
              width > 40, height > 40 else { return nil }
        return (id, NSRect(x: x, y: mainScreenHeight - y - height, width: width, height: height))
    }
}

final class CaptureSession {
    var mode: CaptureMode = .snip { didSet { bar?.refresh(); overlays.forEach { $0.view.needsDisplay = true } } }
    var shape: CaptureShape = .rectangle { didSet { bar?.refresh(); overlays.forEach { $0.view.needsDisplay = true } } }
    private var overlays: [CaptureOverlayWindow] = []
    private(set) var bar: CaptureBar!
    fileprivate let windows = windowsUnderneath()
    var onTarget: ((CaptureMode, CaptureTarget) -> Void)?
    var onEnd: (() -> Void)?
    private var ended = false

    static var micOn: Bool {
        get { UserDefaults.standard.bool(forKey: "mic") }
        set { UserDefaults.standard.set(newValue, forKey: "mic") }
    }
    static var systemAudioOn: Bool {
        get { UserDefaults.standard.object(forKey: "sysAudio") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sysAudio") }
    }

    var showBar = true

    func begin() {
        for screen in NSScreen.screens {
            let w = CaptureOverlayWindow(screen: screen, session: self)
            overlays.append(w)
            w.orderFrontRegardless()
        }
        bar = CaptureBar(session: self, screen: screenUnderMouse())
        if showBar { bar.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (overlays.first { NSMouseInRect(mouse, $0.frame, false) } ?? overlays.first)?.makeKey()
    }

    func end() {
        guard !ended else { return }
        ended = true
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        bar?.orderOut(nil)
        onEnd?()
    }

    fileprivate func finish(_ target: CaptureTarget) {
        let m = mode
        end()
        onTarget?(m, target)
    }

    func window(at p: NSPoint) -> (CGWindowID, NSRect)? { windows.first { $0.1.contains(p) } }

    /// Shared keyboard handling for the overlay and the bar.
    func handleKey(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case kVK_Escape: end(); return true
        case kVK_Tab: mode = mode == .snip ? .record : .snip; return true
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "r": shape = .rectangle
        case "w": shape = .window
        case "f": finish(.screen(screenUnderMouse()))
        case "s": mode = .snip
        case "v": mode = .record
        default: return false
        }
        return true
    }
}

// MARK: - Dimmed overlay per screen

final class CaptureOverlayWindow: NSWindow {
    weak var session: CaptureSession?
    let view: CaptureOverlayView
    let screenRef: NSScreen

    init(screen: NSScreen, session: CaptureSession) {
        self.session = session
        self.screenRef = screen
        view = CaptureOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.owner = self
        contentView = view
    }
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) { if session?.handleKey(e) != true { super.keyDown(with: e) } }
    override func cancelOperation(_ sender: Any?) { session?.end() }
}

final class CaptureOverlayView: NSView {
    weak var owner: CaptureOverlayWindow?
    private var start: NSPoint?
    private var sel: NSRect?
    private var hover: NSRect?   // window under the mouse (local coords)
    private var hoverID: CGWindowID?

    var session: CaptureSession? { owner?.session }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: session?.shape == .window ? .pointingHand : .crosshair) }
    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func toGlobal(_ r: NSRect) -> NSRect { r.offsetBy(dx: owner?.frame.minX ?? 0, dy: owner?.frame.minY ?? 0) }
    private func toLocal(_ r: NSRect) -> NSRect { r.offsetBy(dx: -(owner?.frame.minX ?? 0), dy: -(owner?.frame.minY ?? 0)) }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session else { return }
        window?.invalidateCursorRects(for: self)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let accent: NSColor = s.mode == .record ? .systemRed : .white
        if let r = sel ?? (s.shape == .window ? hover : nil) {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            accent.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)); p.lineWidth = 2; p.stroke()
            if sel != nil {
                let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                            .foregroundColor: NSColor.white]
                label.draw(at: NSPoint(x: r.minX + 4, y: max(4, r.minY - 18)), withAttributes: attrs)
            }
        }
        if sel == nil {
            let verb = s.mode == .record ? "record" : "snip"
            let hint = (s.shape == .window ? "Click a window to \(verb)" : "Drag to \(verb)") + " · Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 110), withAttributes: attrs)
        }
    }

    override func mouseMoved(with e: NSEvent) {
        guard let s = session, s.shape == .window else { if hover != nil { hover = nil; needsDisplay = true }; return }
        let g = NSEvent.mouseLocation
        let w = s.window(at: g)
        let local = w.map { toLocal($0.1) }
        if local != hover { hover = local; hoverID = w?.0; needsDisplay = true }
    }

    override func mouseDown(with e: NSEvent) {
        guard let s = session else { return }
        if s.shape == .window {
            if let id = hoverID, let r = hover, let o = owner { s.finish_(window: id, rect: toGlobal(r), screen: o.screenRef) }
            return
        }
        start = convert(e.locationInWindow, from: nil)
        sel = nil
    }
    override func mouseDragged(with e: NSEvent) {
        guard let st = start else { return }
        let p = convert(e.locationInWindow, from: nil)
        sel = NSRect(x: min(st.x, p.x), y: min(st.y, p.y), width: abs(p.x - st.x), height: abs(p.y - st.y)).integral
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        defer { start = nil }
        guard let r = sel, r.width >= 4, r.height >= 4, let o = owner else { sel = nil; needsDisplay = true; return }
        session?.finish_(rect: toGlobal(r), screen: o.screenRef)
    }
    override func rightMouseDown(with event: NSEvent) { session?.end() }
}

extension CaptureSession {
    fileprivate func finish_(rect: NSRect, screen: NSScreen) { finish(.rect(rect, screen)) }
    fileprivate func finish_(window id: CGWindowID, rect: NSRect, screen: NSScreen) { finish(.window(id, rect, screen)) }
}

// MARK: - The bar on top

final class CaptureBar: NSPanel {
    weak var session: CaptureSession?
    private let modeControl = NSSegmentedControl()
    private let rectSw = Swatch(symbol: "rectangle.dashed", tip: "Rectangle (R)", side: 32)
    private let winSw = Swatch(symbol: "macwindow", tip: "Window (W)", side: 32)
    private let fullSw = Swatch(symbol: "display", tip: "Full screen (F)", side: 32)
    private let micSw = Swatch(symbol: "mic.slash", tip: "Microphone", side: 32)
    private let audioSw = Swatch(symbol: "speaker.wave.2", tip: "System audio", side: 32)
    private let stack = NSStackView()

    init(session: CaptureSession, screen: NSScreen) {
        self.session = session
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        modeControl.segmentCount = 2
        modeControl.setImage(NSImage(systemSymbolName: "camera", accessibilityDescription: "Snip"), forSegment: 0)
        modeControl.setImage(NSImage(systemSymbolName: "video", accessibilityDescription: "Record"), forSegment: 1)
        modeControl.setLabel("Snip", forSegment: 0)
        modeControl.setLabel("Record", forSegment: 1)
        modeControl.setToolTip("Snip (Tab to switch)", forSegment: 0)
        modeControl.setToolTip("Record (Tab to switch)", forSegment: 1)
        modeControl.trackingMode = .selectOne
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        rectSw.action = { [weak self] in self?.session?.shape = .rectangle }
        winSw.action = { [weak self] in self?.session?.shape = .window }
        fullSw.action = { [weak self] in guard let s = self?.session, let scr = self?.screen else { return }; s.finish(.screen(scr)) }
        micSw.action = { [weak self] in CaptureSession.micOn.toggle(); self?.refresh() }
        audioSw.action = { [weak self] in CaptureSession.systemAudioOn.toggle(); self?.refresh() }
        let close = Swatch(symbol: "xmark", tip: "Cancel (Esc)", side: 32)
        close.action = { [weak self] in self?.session?.end() }

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        [modeControl, spacer(6), rectSw, winSw, fullSw, micSw, audioSw, spacer(6), close].forEach { stack.addArrangedSubview($0) }

        let bg = hudBackground(stack.fittingSize)
        bg.addSubview(stack)
        contentView = bg
        let vf = screen.visibleFrame
        let size = stack.fittingSize
        setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 12, width: size.width, height: size.height), display: false)
        refresh()
    }

    func refresh() {
        guard let s = session else { return }
        modeControl.selectedSegment = s.mode.rawValue
        rectSw.selected = s.shape == .rectangle
        winSw.selected = s.shape == .window
        let rec = s.mode == .record
        micSw.isHidden = !rec
        audioSw.isHidden = !rec
        micSw.symbol = CaptureSession.micOn ? "mic.fill" : "mic.slash"
        micSw.selected = CaptureSession.micOn
        micSw.toolTip = CaptureSession.micOn ? "Microphone: on" : "Microphone: off"
        audioSw.symbol = CaptureSession.systemAudioOn ? "speaker.wave.2.fill" : "speaker.slash"
        audioSw.selected = CaptureSession.systemAudioOn
        audioSw.toolTip = CaptureSession.systemAudioOn ? "System audio: on" : "System audio: off"
        let size = stack.fittingSize
        let center = frame.width > 0 ? frame.midX : 0
        contentView?.frame.size = size
        stack.frame = NSRect(origin: .zero, size: size)
        if frame.width > 0 { setFrame(NSRect(x: center - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true) }
        invalidateShadow()
    }

    @objc private func modeChanged() { session?.mode = CaptureMode(rawValue: modeControl.selectedSegment) ?? .snip }

    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) { if session?.handleKey(e) != true { super.keyDown(with: e) } }
    override func cancelOperation(_ sender: Any?) { session?.end() }
}
