// Screen recording with ScreenCaptureKit, plus a live drawing overlay that ends up in the video.
import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit

var recordingsFolder: URL { saveFolder.appendingPathComponent("Recordings") }

/// Transparent window over the recorded area; when drawing is on it takes the mouse, otherwise clicks pass through.
final class OverlayWindow: NSWindow {
    let canvas: Canvas
    var onEscape: (() -> Void)?
    init(rect: NSRect) {
        canvas = Canvas(cgImage: nil, size: rect.size)
        super.init(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(rect, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = canvas
    }
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) {
        if canvas.handleKey(e) { return }
        if Int(e.keyCode) == kVK_Escape { onEscape?(); return }
        super.keyDown(with: e)
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if !canvas.isEditingText, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "z" {
            if e.modifierFlags.contains(.shift) { canvas.redo() } else { canvas.undo() }
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
}

/// Thin border just outside the recorded area (excluded from the video).
final class BorderWindow: NSWindow {
    init(rect: NSRect) {
        let r = rect.insetBy(dx: -4, dy: -4)
        super.init(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(r, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = BorderView(frame: NSRect(origin: .zero, size: r.size))
    }
}
private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = 3
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        p.setLineDash([8, 5], count: 2, phase: 0)
        p.stroke()
    }
}

/// Floating control bar: timer, draw toggle, drawing tools, stop.
final class RecordBar: NSPanel {
    let timeLabel = NSTextField(labelWithString: "Starting…")
    let drawSw = Swatch(symbol: "pencil.and.scribble", tip: "Draw on screen (click again to go back to using your apps)", side: 30)
    let stopSw = Swatch(symbol: "stop.circle.fill", tip: "Stop recording (PrtSc)", side: 30)
    let discardSw = Swatch(symbol: "trash", tip: "Discard this recording", side: 30)
    let muteSw = Swatch(symbol: "mic.fill", tip: "Mute microphone", side: 30)
    let meter = MicMeter()
    let strip: ToolStrip
    private let stack = NSStackView()

    init(canvas: Canvas, mic: Bool) {
        strip = ToolStrip(canvas: canvas)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .systemRed
        stopSw.tint = .systemRed
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        var views: [NSView] = [timeLabel, spacer(6)]
        if mic { views += [muteSw, meter, spacer(6)] }
        views += [drawSw, strip, spacer(6), discardSw, stopSw]
        views.forEach { stack.addArrangedSubview($0) }
        setDrawing(false)
    }

    func setMuted(_ m: Bool) {
        muteSw.symbol = m ? "mic.slash.fill" : "mic.fill"
        muteSw.tint = m ? .systemRed : nil
        muteSw.toolTip = m ? "Unmute microphone" : "Mute microphone"
        meter.muted = m
    }

    func setDrawing(_ on: Bool) {
        drawSw.selected = on
        strip.isHidden = !on
        relayout()
    }

    func relayout() {
        let size = stack.fittingSize
        if contentView?.subviews.first !== stack {
            let bg = hudBackground(size)
            bg.addSubview(stack)
            contentView = bg
        }
        let center = frame.width > 0 ? frame.midX : 0
        let y = frame.minY
        contentView?.frame.size = size
        stack.frame = NSRect(origin: .zero, size: size)
        if frame.width > 0 { setFrame(NSRect(x: center - size.width / 2, y: y, width: size.width, height: size.height), display: true) }
        else { setContentSize(size) }
    }

    /// Below the recorded area if there's room, else above, else inside the top edge.
    func place(near rect: NSRect, on screen: NSScreen) {
        let size = frame.size
        let vf = screen.visibleFrame
        var y = rect.minY - size.height - 12
        if y < vf.minY + 4 { y = rect.maxY + 12 }
        if y + size.height > vf.maxY - 4 { y = min(rect.maxY, vf.maxY) - size.height - 12 }
        let x = min(max(rect.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Mic level monitor for the meter (separate from the recording itself).
final class MicMonitor {
    private let engine = AVAudioEngine()
    var onLevel: ((Float) -> Void)?
    func start() {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 0.000_01))
            let level = min(1, max(0, (db + 50) / 45))
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        do { try engine.start() } catch { log("mic monitor failed: \(error)") }
    }
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Big 3-2-1 shown over the area before recording starts (gone before capture begins).
final class CountdownWindow: NSWindow {
    private let label = NSTextField(labelWithString: "3")
    init(center: NSPoint) {
        let s: CGFloat = 120
        super.init(contentRect: NSRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        let bg = hudBackground(NSSize(width: s, height: s))
        label.font = .systemFont(ofSize: 64, weight: .bold)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (s - 80) / 2, width: s, height: 80)
        bg.addSubview(label)
        contentView = bg
    }
    func run(_ done: @escaping () -> Void) {
        orderFrontRegardless()
        var n = 3
        label.stringValue = "\(n)"
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { t in
            n -= 1 // strong capture keeps the window alive until the countdown ends
            if n == 0 { t.invalidate(); self.orderOut(nil); done() } else { self.label.stringValue = "\(n)" }
        }
    }
}

final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    let rect: NSRect
    let screen: NSScreen
    let url: URL
    let overlay: OverlayWindow
    let border: BorderWindow
    let bar: RecordBar
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var startDate: Date?
    private var timer: Timer?
    private var finished = false
    private var discarded = false
    private var config: SCStreamConfiguration?
    private let micOn: Bool
    private var micMonitor: MicMonitor?
    private(set) var muted = false
    private(set) var drawing = false
    var onFinish: ((URL?) -> Void)?

    init(rect: NSRect, screen: NSScreen, mic: Bool) {
        self.rect = rect
        self.screen = screen
        self.micOn = mic
        try? FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        url = recordingsFolder.appendingPathComponent("Squiggle Recording \(timestamp()).mp4")
        overlay = OverlayWindow(rect: rect)
        border = BorderWindow(rect: rect)
        bar = RecordBar(canvas: overlay.canvas, mic: mic)
        super.init()
        bar.drawSw.action = { [weak self] in self?.toggleDrawing() }
        bar.stopSw.action = { [weak self] in self?.stop() }
        bar.discardSw.action = { [weak self] in self?.discard() }
        bar.muteSw.action = { [weak self] in self?.toggleMute() }
        overlay.onEscape = { [weak self] in self?.setDrawing(false) }
        overlay.canvas.onToolChange = { [weak self] in self?.bar.strip.refresh() }
    }

    func start(mic: Bool, systemAudio: Bool) {
        overlay.orderFrontRegardless()
        border.orderFrontRegardless()
        bar.timeLabel.stringValue = "Get ready…"
        bar.relayout()
        bar.place(near: rect, on: screen)
        bar.orderFrontRegardless()
        if mic {
            let m = MicMonitor()
            m.onLevel = { [weak self] l in self?.bar.meter.level = l }
            m.start()
            micMonitor = m
        }

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            fail("no display id"); return
        }
        CountdownWindow(center: NSPoint(x: rect.midX, y: rect.midY)).run { [weak self] in
            guard let self, !self.finished else { return }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, err in
                DispatchQueue.main.async { self.configure(content: content, err: err, displayID: displayID, mic: mic, systemAudio: systemAudio) }
            }
        }
    }

    func toggleMute() {
        guard micOn else { return }
        muted.toggle()
        bar.setMuted(muted)
        guard let cfg = config, let s = stream else { return }
        cfg.captureMicrophone = !muted
        s.updateConfiguration(cfg) { err in if let err { log("mute update failed: \(err)") } }
    }

    func discard() {
        let a = NSAlert()
        a.messageText = "Discard this recording?"
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Keep Recording")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        discarded = true
        stop()
    }

    private func configure(content: SCShareableContent?, err: Error?, displayID: CGDirectDisplayID, mic: Bool, systemAudio: Bool) {
        guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
            fail("shareable content unavailable: \(String(describing: err))"); return
        }
        let hide = Set([bar.windowNumber, border.windowNumber].map { CGWindowID($0) })
        let excluded = content.windows.filter { hide.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let cfg = SCStreamConfiguration()
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor
        cfg.sourceRect = local
        cfg.width = Int(local.width * scale) & ~1
        cfg.height = Int(local.height * scale) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = true
        cfg.capturesAudio = systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = mic

        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        let out = SCRecordingOutput(configuration: rc, delegate: self)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do { try s.addRecordingOutput(out) } catch { fail("addRecordingOutput: \(error)"); return }
        stream = s
        output = out
        config = cfg
        s.startCapture { error in
            DispatchQueue.main.async {
                if let error { self.fail("startCapture: \(error)"); return }
                log("recording started \(self.url.lastPathComponent) mic=\(mic) audio=\(systemAudio)")
                self.startDate = Date()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let d = startDate else { return }
        let t = Int(Date().timeIntervalSince(d))
        bar.timeLabel.stringValue = String(format: "● %d:%02d", t / 60, t % 60)
    }

    func toggleDrawing() { setDrawing(!drawing) }
    func setDrawing(_ on: Bool) {
        drawing = on
        overlay.ignoresMouseEvents = !on
        bar.setDrawing(on)
        bar.place(near: rect, on: screen)
        if on { NSApp.activate(ignoringOtherApps: true); overlay.makeKeyAndOrderFront(nil) }
        else { overlay.canvas.commitText() }
    }

    func stop() {
        guard !finished else { return }
        bar.timeLabel.stringValue = discarded ? "Discarding…" : "Saving…"
        timer?.invalidate()
        guard let s = stream else { finished = true; cleanup(); onFinish?(nil); return }
        s.stopCapture { error in
            if let error { log("stopCapture error: \(error)") }
            // recordingOutputDidFinishRecording delivers the final callback; fall back after a timeout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.complete(ok: FileManager.default.fileExists(atPath: self.url.path)) }
        }
    }

    private func complete(ok: Bool) {
        guard !finished else { return }
        finished = true
        cleanup()
        log("recording finished ok=\(ok) discarded=\(discarded)")
        if discarded { try? FileManager.default.removeItem(at: url); onFinish?(nil); return }
        onFinish?(ok ? url : nil)
    }

    private func cleanup() {
        timer?.invalidate()
        micMonitor?.stop()
        micMonitor = nil
        [overlay, border, bar].forEach { $0.orderOut(nil) }
    }

    private func fail(_ msg: String) {
        log("recording failed: \(msg)")
        finished = true
        cleanup()
        let a = NSAlert()
        a.messageText = "Couldn't start recording"
        a.informativeText = "Make sure BugOS is allowed under System Settings → Privacy & Security → Screen & System Audio Recording (and Microphone if the mic is on).\n\n\(msg)"
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        onFinish?(nil)
    }

    // MARK: Delegates

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { self.complete(ok: true) }
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        log("recording output error: \(error)")
        DispatchQueue.main.async { self.complete(ok: FileManager.default.fileExists(atPath: self.url.path)) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error)")
        DispatchQueue.main.async { self.complete(ok: FileManager.default.fileExists(atPath: self.url.path)) }
    }
}

func videoThumbnail(_ url: URL, completion: @escaping (NSImage?) -> Void) {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 600, height: 400)
    gen.generateCGImageAsynchronously(for: .zero) { cg, _, _ in
        DispatchQueue.main.async { completion(cg.map { NSImage(cgImage: $0, size: .zero) }) }
    }
}
