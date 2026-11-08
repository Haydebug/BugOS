// Video editor: watch a recording, pause anywhere, draw, choose how long it stays up, export with drawings burned in.
import AppKit
import AVFoundation
import Carbon.HIToolbox
import QuartzCore

func formatTime(_ t: Double) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// One batch of drawings shown from `start` to `end`.
struct Segment {
    var items: [Item]
    var start: Double
    var end: Double
    var image: CGImage
}

// MARK: - Timeline

final class TimelineView: NSView {
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var time: Double = 0 { didSet { needsDisplay = true } }
    var ranges: [(Double, Double)] = [] { didSet { needsDisplay = true } }
    var pending: (Double, Double)? { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func x(_ t: Double) -> CGFloat { bounds.minX + 8 + CGFloat(t / max(duration, 0.001)) * (bounds.width - 16) }

    override func draw(_ r: NSRect) {
        let midY = bounds.midY
        let track = NSRect(x: bounds.minX + 8, y: midY - 3, width: bounds.width - 16, height: 6)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: x(time) - track.minX, height: 6), xRadius: 3, yRadius: 3).fill()
        for (a, b) in ranges {
            NSColor.systemYellow.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: x(a), y: midY - 9, width: max(4, x(b) - x(a)), height: 4), xRadius: 2, yRadius: 2).fill()
        }
        if let (a, b) = pending {
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: NSRect(x: x(a), y: midY - 9, width: max(4, x(b) - x(a)), height: 4), xRadius: 2, yRadius: 2).fill()
        }
        let head = NSRect(x: x(time) - 7, y: midY - 7, width: 14, height: 14)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: head).fill()
        NSColor.gray.setStroke()
        NSBezierPath(ovalIn: head).stroke()
    }
    private func seek(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let f = Double((p.x - bounds.minX - 8) / (bounds.width - 16))
        onSeek?(min(max(f, 0), 1) * duration)
    }
    override func mouseDown(with e: NSEvent) { seek(e) }
    override func mouseDragged(with e: NSEvent) { seek(e) }
}

// MARK: - Overlay preview of finished segments

final class SegmentPreview: NSView {
    var images: [CGImage] = [] { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for img in images { ctx.draw(img, in: bounds) }
    }
}

/// While playing, a click on the video pauses it (so you can draw).
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class PlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}

// MARK: - Editor window

final class VideoEditorWindow: NSWindow, NSWindowDelegate {
    let url: URL
    let player: AVPlayer
    let asset: AVURLAsset
    let videoSize: CGSize
    let duration: Double
    let canvas: Canvas
    let strip: ToolStrip
    let preview: SegmentPreview
    let catcher = ClickCatcher()
    let timeline = TimelineView()
    let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    let hintLabel = NSTextField(labelWithString: "")
    let playButton = Swatch(symbol: "play.fill", tip: "Play / Pause (Space)", side: 30)
    let showFor = NSPopUpButton()
    let chips = NSStackView()
    var segments: [Segment] = [] { didSet { refreshSegments() } }
    var pendingStart: Double?
    var pendingEnd: Double?   // keeps an adopted drawing's original end time
    var timeObserver: Any?
    var exporting = false
    var onClosed: ((VideoEditorWindow) -> Void)?

    static let showForOptions: [(String, Double?)] = [("2 sec", 2), ("3 sec", 3), ("5 sec", 5), ("10 sec", 10), ("Until end", nil)]

    init?(url: URL, screen: NSScreen) {
        self.url = url
        asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let nat = track.naturalSize.applying(track.preferredTransform)
        videoSize = CGSize(width: abs(nat.width), height: abs(nat.height))
        duration = max(asset.duration.seconds, 0.1)
        player = AVPlayer(url: url)

        // Fit the video (in points) on screen, leaving room for controls.
        let controlsH: CGFloat = 38 + 44 + 34
        let vf = screen.visibleFrame
        let pts = CGSize(width: videoSize.width / screen.backingScaleFactor, height: videoSize.height / screen.backingScaleFactor)
        let scale = min(1, (vf.width * 0.85) / pts.width, (vf.height * 0.85 - controlsH) / pts.height)
        let vSize = NSSize(width: floor(pts.width * scale), height: floor(pts.height * scale))

        let cv = Canvas(cgImage: nil, size: vSize)
        let ts = ToolStrip(canvas: cv)
        canvas = cv
        strip = ts
        preview = SegmentPreview(frame: NSRect(origin: .zero, size: vSize))

        let exportBtn = Swatch(symbol: "square.and.arrow.up", tip: "Export with drawings & copy (⌘E)", side: 26)
        let saveAsBtn = Swatch(symbol: "square.and.arrow.down.on.square", tip: "Export As… (⇧⌘S)", side: 26)
        let finderBtn = Swatch(symbol: "folder", tip: "Show original in Finder", side: 26)
        let deleteBtn = Swatch(symbol: "trash", tip: "Delete this recording (moves it to the Trash)", side: 26)
        deleteBtn.tint = .systemRed
        ts.addArrangedSubview(spacer(8))
        for b in [exportBtn, saveAsBtn, finderBtn] { ts.addArrangedSubview(b) }
        ts.addArrangedSubview(spacer(8))
        ts.addArrangedSubview(deleteBtn)

        let contentW = max(vSize.width, ts.fittingSize.width + 16, 640)
        let contentSize = NSSize(width: contentW, height: vSize.height + controlsH)
        super.init(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        delegate = self
        title = url.deletingPathExtension().lastPathComponent

        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))
        content.wantsLayer = true
        let videoOrigin = NSPoint(x: (contentW - vSize.width) / 2, y: 38 + 44 + 34 - 38)
        // Layout bottom → top: chips (34), transport (44), video, tools (38) on top.
        let videoY: CGFloat = 34 + 44
        let pv = PlayerView(frame: NSRect(x: videoOrigin.x, y: videoY, width: vSize.width, height: vSize.height))
        pv.playerLayer.player = player
        content.addSubview(pv)
        preview.frame = pv.frame
        content.addSubview(preview)
        canvas.frame = pv.frame
        content.addSubview(canvas)
        catcher.frame = pv.frame
        content.addSubview(catcher)
        strip.frame = NSRect(x: 8, y: videoY + vSize.height, width: contentW - 16, height: 38)
        content.addSubview(strip)

        // Transport row
        playButton.frame.origin = NSPoint(x: 10, y: 34 + 7)
        playButton.translatesAutoresizingMaskIntoConstraints = true
        content.addSubview(playButton)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.frame = NSRect(x: 46, y: 34 + 13, width: 90, height: 18)
        content.addSubview(timeLabel)
        let showLabel = NSTextField(labelWithString: "Show drawing for")
        showLabel.font = .systemFont(ofSize: 12)
        showLabel.textColor = .secondaryLabelColor
        showLabel.sizeToFit()
        showFor.addItems(withTitles: VideoEditorWindow.showForOptions.map { $0.0 })
        showFor.selectItem(at: UserDefaults.standard.object(forKey: "showFor") as? Int ?? 1)
        showFor.controlSize = .small
        showFor.sizeToFit()
        showFor.frame.origin = NSPoint(x: contentW - showFor.frame.width - 10, y: 34 + 10)
        showLabel.frame.origin = NSPoint(x: showFor.frame.minX - showLabel.frame.width - 4, y: 34 + 14)
        content.addSubview(showFor)
        content.addSubview(showLabel)
        timeline.frame = NSRect(x: 138, y: 34 + 4, width: showLabel.frame.minX - 146, height: 36)
        timeline.duration = duration
        content.addSubview(timeline)

        // Segment chips row
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 2, width: contentW, height: 30))
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = chips
        content.addSubview(scroll)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        contentView = content

        playButton.action = { [weak self] in self?.togglePlay() }
        catcher.onClick = { [weak self] in self?.pause() }
        timeline.onSeek = { [weak self] t in self?.seek(to: t) }
        exportBtn.action = { [weak self] in self?.export(to: nil) }
        saveAsBtn.action = { [weak self] in self?.exportAs() }
        deleteBtn.action = { [weak self] in self?.deleteRecording() }
        finderBtn.action = { [weak self] in if let u = self?.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
        showFor.target = self
        showFor.action = #selector(showForChanged)
        canvas.onChange = { [weak self] in self?.canvasChanged() }
        canvas.onToolChange = { [weak self] in self?.strip.refresh() }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            self?.tick()
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            self?.updatePlayState()
        }
        setFrameOrigin(NSPoint(x: vf.midX - frame.width / 2, y: vf.midY - frame.height / 2))
        updatePlayState()
        refreshSegments()
    }

    var isPlaying: Bool { player.rate != 0 }
    var now: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }

    func showForSeconds() -> Double? { VideoEditorWindow.showForOptions[max(0, showFor.indexOfSelectedItem)].1 }
    func endTime(from start: Double) -> Double { showForSeconds().map { min(duration, start + $0) } ?? duration }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }
    func play() {
        commitPending()
        if now >= duration - 0.05 { player.seek(to: .zero) }
        player.play()
        updatePlayState()
    }
    func pause() { player.pause(); updatePlayState(); adoptSegment(at: now) }
    func seek(to t: Double) {
        commitPending()
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if !isPlaying { adoptSegment(at: t) }
        tick()
    }

    /// When paused on a frame that already shows a drawing, put it back on the canvas so it can be
    /// erased, cleared (Delete / clear button), undone or added to.
    func adoptSegment(at t: Double) {
        guard !isPlaying, pendingStart == nil,
              let i = segments.lastIndex(where: { t >= $0.start - 0.01 && t < $0.end }) else { return }
        let seg = segments.remove(at: i)
        canvas.setItems(seg.items)
        pendingStart = seg.start
        pendingEnd = seg.end
        tick()
    }
    func step(_ d: Double) { pause(); seek(to: min(max(0, now + d), duration)) }

    func updatePlayState() {
        playButton.symbol = isPlaying ? "pause.fill" : "play.fill"
        catcher.isHidden = !isPlaying
        canvas.isHidden = isPlaying
        if isPlaying { canvas.commitText() }
        tick()
        window_title()
    }

    private func window_title() {
        let base = url.deletingPathExtension().lastPathComponent
        title = isPlaying ? "\(base) — click the video to pause and draw" : "\(base) — paused: draw on this frame, press Space to play"
    }

    func tick() {
        let t = now
        timeLabel.stringValue = "\(formatTime(t)) / \(formatTime(duration))"
        timeline.time = t
        timeline.pending = pendingStart.map { ($0, pendingEnd ?? endTime(from: $0)) }
        preview.images = segments.filter { t >= $0.start - 0.01 && t < $0.end }.map { $0.image }
        if isPlaying != (playButton.symbol == "pause.fill") { updatePlayState() }
    }

    // MARK: Drawing segments

    func canvasChanged() {
        if pendingStart == nil { pendingStart = now }
        timeline.pending = pendingStart.map { ($0, endTime(from: $0)) }
    }

    @objc func showForChanged() {
        UserDefaults.standard.set(showFor.indexOfSelectedItem, forKey: "showFor")
        pendingEnd = nil
        timeline.pending = pendingStart.map { ($0, endTime(from: $0)) }
    }

    /// Turn what's on the canvas into a timed segment.
    func commitPending() {
        canvas.commitText()
        guard let start = pendingStart else { return }
        pendingStart = nil
        let end = pendingEnd ?? endTime(from: start)
        pendingEnd = nil
        let items = canvas.items
        canvas.setItems([])
        guard !items.isEmpty else { return }
        let tmp = Canvas(cgImage: nil, size: canvas.bounds.size)
        tmp.setItems(items)
        guard let img = tmp.renderAnnotations(pixelSize: videoSize) else { return }
        segments.append(Segment(items: items, start: start, end: end, image: img))
        segments.sort { $0.start < $1.start }
    }

    func editSegment(_ i: Int) {
        commitPending()
        pause()
        let seg = segments.remove(at: i)
        player.seek(to: CMTime(seconds: seg.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let len = seg.end - seg.start
        if let idx = VideoEditorWindow.showForOptions.firstIndex(where: { $0.1.map { abs($0 - len) < 0.05 } ?? (seg.end >= duration - 0.05) }) {
            showFor.selectItem(at: idx)
        }
        canvas.setItems(seg.items)
        pendingStart = seg.start
        pendingEnd = nil
        tick()
    }

    func deleteRecording() {
        let a = NSAlert()
        a.messageText = "Delete this recording?"
        a.informativeText = "\(url.lastPathComponent) will be moved to the Trash."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        pause()
        player.replaceCurrentItem(with: nil)
        NSWorkspace.shared.recycle([url]) { [weak self] _, err in
            DispatchQueue.main.async {
                if let err { log("delete failed: \(err)"); NSSound.beep(); return }
                log("moved to trash: \(self?.url.lastPathComponent ?? "")")
                self?.pendingStart = nil
                self?.canvas.setItems([])
                self?.segments.removeAll()
                self?.exportedSegmentCount = 0
                self?.close()
            }
        }
    }

    func refreshSegments() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        timeline.ranges = segments.map { ($0.start, $0.end) }
        if segments.isEmpty {
            hintLabel.stringValue = "Pause anywhere (click the video or press Space) and draw. Drawings show up in the exported video."
            hintLabel.sizeToFit()
            chips.addArrangedSubview(hintLabel)
        }
        for (i, s) in segments.enumerated() {
            let b = labelButton("\(formatTime(s.start))–\(s.end >= duration - 0.05 ? "end" : formatTime(s.end))", symbol: "pencil",
                                tip: "Edit this drawing") { [weak self] in self?.editSegment(i) }
            b.controlSize = .small
            let x = Swatch(symbol: "xmark.circle.fill", tip: "Delete this drawing", side: 20)
            x.action = { [weak self] in self?.segments.remove(at: i); self?.tick() }
            let row = NSStackView(views: [b, x])
            row.spacing = 2
            chips.addArrangedSubview(row)
        }
        chips.layoutSubtreeIfNeeded()
        chips.frame.size = NSSize(width: max(chips.fittingSize.width, 10), height: 30)
    }

    // MARK: Export

    func exportAs() {
        commitPending()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (drawn).mp4"
        panel.directoryURL = recordingsFolder
        panel.beginSheetModal(for: self) { [weak self] r in
            guard r == .OK, let dest = panel.url else { return }
            self?.export(to: dest)
        }
    }

    func export(to dest: URL?) {
        commitPending()
        guard !exporting else { return }
        if segments.isEmpty && dest == nil {
            copyFileToClipboard(url)
            title = "No drawings — copied the original recording"
            return
        }
        let out = dest ?? url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (drawn).mp4")
        try? FileManager.default.removeItem(at: out)
        guard !segments.isEmpty else {
            do { try FileManager.default.copyItem(at: url, to: out); copyFileToClipboard(out) } catch { NSSound.beep() }
            return
        }
        exporting = true
        pause()
        title = "Exporting…"

        let comp = AVMutableVideoComposition(propertiesOf: asset)
        let size = comp.renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        for s in segments {
            let l = CALayer()
            l.frame = parent.frame
            l.contents = s.image
            l.contentsGravity = .resize
            l.opacity = 0
            // Keyframes across the whole video: hidden → shown at start → hidden at end (discrete steps).
            let a = CAKeyframeAnimation(keyPath: "opacity")
            let d = max(duration, 0.1)
            a.values = [0, 1, 0, 0]
            a.keyTimes = [0, NSNumber(value: max(0, s.start) / d), NSNumber(value: min(d, s.end) / d), 1]
            a.calculationMode = .discrete
            a.beginTime = AVCoreAnimationBeginTimeAtZero
            a.duration = d
            a.isRemovedOnCompletion = false
            a.fillMode = .both
            l.add(a, forKey: "show")
            parent.addSublayer(l)
        }
        comp.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            exporting = false; NSSound.beep(); return
        }
        session.outputURL = out
        session.outputFileType = out.pathExtension.lowercased() == "mov" ? .mov : .mp4
        session.videoComposition = comp
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                if session.status == .completed {
                    copyFileToClipboard(out)
                    self.title = "Exported & copied: \(out.lastPathComponent)"
                    self.exportedSegmentCount = self.segments.count
                    log("exported \(out.lastPathComponent)")
                } else {
                    log("export failed: \(String(describing: session.error))")
                    self.title = "Export failed"
                    NSSound.beep()
                }
            }
        }
    }
    var exportedSegmentCount = 0

    // MARK: Keys & closing

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), let ch = e.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: e) }
        if canvas.isEditingText {
            if ch == "v" { canvas.pasteText(); return true }
            canvas.commitText()
        }
        switch (ch, mods.contains(.shift)) {
        case ("z", false): canvas.undo(); return true
        case ("z", true): canvas.redo(); return true
        case ("e", false): export(to: nil); return true
        case ("s", true): exportAs(); return true
        case ("w", false): close(); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    override func keyDown(with e: NSEvent) {
        switch Int(e.keyCode) {
        case kVK_Space: togglePlay(); return
        case kVK_LeftArrow: step(e.modifierFlags.contains(.shift) ? -5 : -1); return
        case kVK_RightArrow: step(e.modifierFlags.contains(.shift) ? 5 : 1); return
        default: break
        }
        if !isPlaying, canvas.handleKey(e) { return }
        super.keyDown(with: e)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commitPending()
        guard segments.count > 0, segments.count != exportedSegmentCount else { return true }
        let a = NSAlert()
        a.messageText = "Export your drawings before closing?"
        a.informativeText = "The original recording is already saved. Your drawings only end up in a video when you export."
        a.addButton(withTitle: "Export & Copy")
        a.addButton(withTitle: "Close Without Exporting")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: export(to: nil); return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o) }
        onClosed?(self)
    }
}

func copyFileToClipboard(_ url: URL) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.writeObjects([url as NSURL])
}
