// Small reusable UI pieces: icon/color buttons, the drawing tool strip, the corner toast.
import AppKit

// MARK: - Swatch (icon or color button)

final class Swatch: NSView {
    var color: NSColor?
    var dot: CGFloat
    var symbol: String? { didSet { needsDisplay = true } }
    var tint: NSColor? { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var action: (() -> Void)?
    let side: CGFloat

    init(color: NSColor? = nil, dot: CGFloat = 14, symbol: String? = nil, tip: String, side: CGFloat = 26) {
        self.color = color; self.dot = dot; self.symbol = symbol; self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { action?() }

    override func draw(_ r: NSRect) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        if let sym = symbol, let base = NSImage(systemSymbolName: sym, accessibilityDescription: toolTip) {
            let img = base.withSymbolConfiguration(.init(pointSize: side * 0.55, weight: .medium)) ?? base
            let fill = tint ?? .labelColor
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect); fill.set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: (bounds.width - img.size.width) / 2, y: (bounds.height - img.size.height) / 2,
                                   width: img.size.width, height: img.size.height))
            return
        }
        let o = NSRect(x: (bounds.width - dot) / 2, y: (bounds.height - dot) / 2, width: dot, height: dot)
        (color ?? .labelColor).setFill()
        NSBezierPath(ovalIn: o).fill()
        NSColor.gray.withAlphaComponent(0.6).setStroke()
        let rim = NSBezierPath(ovalIn: o); rim.lineWidth = 1; rim.stroke()
    }
}

func spacer(_ w: CGFloat) -> NSView {
    let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
    v.widthAnchor.constraint(equalToConstant: w).isActive = true
    return v
}

// MARK: - Tool strip bound to a Canvas

final class ToolStrip: NSStackView {
    weak var canvas: Canvas?
    private let penSw = Swatch(symbol: "paintbrush.pointed", tip: "Pen (B)")
    private let hlSw = Swatch(symbol: "highlighter", tip: "Highlighter (H)")
    private let textSw = Swatch(symbol: "textformat", tip: "Text (T)")
    private let eraserSw = Swatch(symbol: "eraser.line.dashed", tip: "Eraser (E) — press again to switch whole-stroke / precision")
    private let colorBtn: ColorButton
    let sizeBtn: SizeButton

    init(canvas: Canvas) {
        self.canvas = canvas
        colorBtn = ColorButton(canvas: canvas)
        canvas.onColorKey = { [weak colorBtn] in colorBtn?.openPicker() }
        sizeBtn = SizeButton(canvas: canvas)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 2
        alignment = .centerY
        penSw.action = { [weak self] in self?.canvas?.selectPen(highlighter: false) }
        hlSw.action = { [weak self] in self?.canvas?.selectPen(highlighter: true) }
        textSw.action = { [weak self] in self?.canvas?.tool = .text }
        eraserSw.action = { [weak self] in self?.canvas?.pressEraser() }
        let undo = Swatch(symbol: "arrow.uturn.backward", tip: "Undo (⌘Z)")
        undo.action = { [weak self] in self?.canvas?.undo() }
        let redo = Swatch(symbol: "arrow.uturn.forward", tip: "Redo (⇧⌘Z)")
        redo.action = { [weak self] in self?.canvas?.redo() }
        let clear = Swatch(symbol: "clear", tip: "Clear all drawings (Delete key)")
        clear.action = { [weak self] in self?.canvas?.clear() }
        [penSw, hlSw, textSw, eraserSw, spacer(10), colorBtn, sizeBtn, spacer(10), undo, redo, clear].forEach { addArrangedSubview($0) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard let c = canvas else { return }
        penSw.selected = c.tool == .pen && !c.highlighter
        hlSw.selected = c.tool == .pen && c.highlighter
        textSw.selected = c.tool == .text
        eraserSw.selected = c.tool == .eraser
        eraserSw.symbol = c.eraserMode == .precision ? "eraser" : "eraser.line.dashed"
        colorBtn.needsDisplay = true
        colorBtn.colorMaybeChanged()
        sizeBtn.needsDisplay = true
    }
}

// MARK: - Flyout (small popover panel under a button)

final class Flyout: NSPanel {
    private var monitors: [Any] = []
    var onClose: (() -> Void)?

    init(content: NSView) {
        let size = content.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        let bg = hudBackground(size)
        content.frame = bg.bounds
        bg.addSubview(content)
        contentView = bg
    }

    func show(below view: NSView) {
        guard let win = view.window else { return }
        let r = win.convertToScreen(view.convert(view.bounds, to: nil))
        let vf = (win.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = r.midX - frame.width / 2
        x = min(max(x, vf.minX + 6), vf.maxX - frame.width - 6)
        var y = r.minY - frame.height - 6
        if y < vf.minY { y = r.maxY + 6 }
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
        invalidateShadow()
        // Close on a click anywhere else, or Esc.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown { if e.keyCode == 53 { self.dismiss(); return nil }; return e }
            if e.window !== self { self.dismiss() }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.dismiss() }) {
            monitors.append(m)
        }
    }

    func dismiss() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        orderOut(nil)
        onClose?()
        onClose = nil
    }
}

// MARK: - Color button: click to open the picker, or press-drag-release onto a color

final class ColorButton: NSView {
    weak var canvas: Canvas?
    private var flyout: Flyout?
    private var cells: [Swatch] = []

    init(canvas: Canvas) {
        self.canvas = canvas
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        toolTip = "Color — click to pick, or press and drag onto a color (1–9)"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ r: NSRect) {
        let c = canvas?.color ?? .red
        let dot = NSRect(x: 3, y: 5, width: 18, height: 18)
        c.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSColor.labelColor.withAlphaComponent(0.6).setStroke()
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)); ring.lineWidth = 1.5; ring.stroke()
        chevron(in: NSRect(x: 25, y: 10, width: 9, height: 8))
    }

    private func makeFlyout() -> Flyout {
        cells.removeAll()
        // One vertical column of the preset colors: press the color button and drag down through them.
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        for (i, c) in palette.enumerated() {
            let s = Swatch(color: c, dot: 22, tip: i < 9 ? "\(i + 1)" : "", side: 30)
            s.selected = canvas.map { $0.color.isClose(to: c) } ?? false
            s.action = { [weak self] in self?.pick(c) }
            cells.append(s)
            column.addArrangedSubview(s)
        }
        return Flyout(content: column)
    }

    /// Open the picker from the keyboard (C). Number keys still pick while it's open.
    func openPicker() {
        if let f = flyout, f.isVisible { f.dismiss(); return }
        let f = makeFlyout()
        flyout = f
        shownColor = canvas?.color
        f.show(below: self)
    }
    private var shownColor: NSColor?
    /// Close the picker if the color was changed some other way (e.g. a number key).
    func colorMaybeChanged() {
        guard let f = flyout, f.isVisible, let c = canvas?.color, let shown = shownColor, !c.isClose(to: shown) else { return }
        f.dismiss()
    }

    private func pick(_ c: NSColor) {
        canvas?.color = c
        flyout?.dismiss()
    }

    /// Forgiving hit test: matches the row you're level with, even if you drift a bit sideways.
    private func cell(atScreen p: NSPoint) -> Swatch? {
        cells.first { s in
            guard let w = s.window else { return false }
            let r = w.convertToScreen(s.convert(s.bounds, to: nil)).insetBy(dx: 0, dy: -1)
            return p.y >= r.minY && p.y < r.maxY && abs(p.x - r.midX) < 90
        }
    }

    override func mouseDown(with e: NSEvent) {
        flyout?.dismiss()
        let f = makeFlyout()
        flyout = f
        shownColor = canvas?.color
        f.show(below: self)
        var dragged = false
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = NSEvent.mouseLocation
            if ev.type == .leftMouseDragged {
                dragged = true
                if let hit = cell(atScreen: p), let c = hit.color {
                    for s in cells { s.selected = s === hit }
                    shownColor = c          // live preview without closing the list
                    canvas?.color = c
                    needsDisplay = true
                }
            } else {
                if let hit = cell(atScreen: p), let c = hit.color { pick(c) }
                else if dragged { f.dismiss() }   // let go anywhere: keep the last color you passed over
                break // plain click: leave the list open
            }
        }
    }

    @objc private func openColorPanel() {
        flyout?.dismiss()
        let panel = NSColorPanel.shared
        panel.color = canvas?.color ?? .red
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.isContinuous = true
        panel.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
    }
    @objc private func colorPanelChanged(_ sender: NSColorPanel) { canvas?.color = sender.color }
}

// MARK: - Size button: press and drag sideways to scrub, or click for a slider

final class SizeButton: NSView {
    weak var canvas: Canvas?
    private var flyout: Flyout?
    private var wedge: SizeWedge?
    private var valueLabel: NSTextField?

    init(canvas: Canvas) {
        self.canvas = canvas
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        toolTip = "Size — press and drag down for bigger / up for smaller, or click to pick ([ / ])"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func draw(_ r: NSRect) {
        let w = canvas?.penWidth ?? 4
        let d = min(20, 5 + w * 0.75)
        (canvas?.color ?? .labelColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12 - d / 2, y: 14 - d / 2, width: d, height: d)).fill()
        chevron(in: NSRect(x: 25, y: 10, width: 9, height: 8))
    }

    private func makeFlyout() -> Flyout {
        let w = canvas?.penWidth ?? 4
        let wedge = SizeWedge(canvas: canvas)
        wedge.onChange = { [weak self] in self?.update() }
        let label = NSTextField(labelWithString: "\(Int(w)) px")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let row = NSStackView(views: [label, wedge])   // small at the top, big at the bottom
        row.orientation = .vertical
        row.spacing = 8
        row.alignment = .centerX
        row.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        self.wedge = wedge; valueLabel = label
        return Flyout(content: row)
    }

    private func update() {
        guard let w = canvas?.penWidth else { return }
        wedge?.needsDisplay = true
        valueLabel?.stringValue = "\(Int(w)) px"
        needsDisplay = true
    }

    func openSlider() {
        flyout?.dismiss()
        let f = makeFlyout()
        flyout = f
        f.show(below: self)
    }


    override func mouseDown(with e: NSEvent) {
        flyout?.dismiss()
        let f = makeFlyout()
        flyout = f
        f.show(below: self)
        let startY = NSEvent.mouseLocation.y
        let startW = canvas?.penWidth ?? 4
        var dragged = false
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dy = startY - NSEvent.mouseLocation.y   // drag down = bigger (matches the wedge)
            if ev.type == .leftMouseDragged {
                if abs(dy) > 2 { dragged = true }
                if dragged {
                    canvas?.penWidth = (startW * pow(1.025, dy)).rounded()
                    update()
                }
            } else {
                if dragged { f.dismiss() } // press-drag-release: done; plain click keeps the slider open
                break
            }
        }
    }
}

/// Tapered size picker: thin at the top (small brush), wide at the bottom (big brush).
/// Click or drag anywhere on it; the marker shows the current size at its real width.
final class SizeWedge: NSView {
    weak var canvas: Canvas?
    var onChange: (() -> Void)?
    private let pad: CGFloat = 12          // room for the round ends
    private let maxDraw: CGFloat = 44      // widest drawn width (points)

    init(canvas: Canvas?) {
        self.canvas = canvas
        super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 230))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 230).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // t: 0 at the top (min size) → 1 at the bottom (max size). Eased so small sizes get more room.
    private func size(forT t: CGFloat) -> CGFloat { minPenWidth + (maxPenWidth - minPenWidth) * pow(t, 1.6) }
    private func t(forSize w: CGFloat) -> CGFloat { pow((w - minPenWidth) / (maxPenWidth - minPenWidth), 1 / 1.6) }
    private func y(forT t: CGFloat) -> CGFloat { bounds.maxY - pad - t * (bounds.height - 2 * pad) }
    private func drawWidth(forT t: CGFloat) -> CGFloat { min(maxDraw, size(forT: t)) }

    override func draw(_ r: NSRect) {
        let color = canvas?.color ?? .systemRed
        let cx = bounds.midX
        // The wedge: a stack of round slices from thin to thick.
        let path = NSBezierPath()
        let steps = 240
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let d = drawWidth(forT: t)
            path.appendOval(in: NSRect(x: cx - d / 2, y: y(forT: t) - d / 2, width: d, height: d))
        }
        color.withAlphaComponent(0.35).setFill()
        path.fill()
        // Current size marker: a solid dot at its real size (capped) with a guide line.
        let w = canvas?.penWidth ?? 4
        let tt = t(forSize: w)
        let my = y(forT: tt)
        let d = min(maxDraw, max(3, w))
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let guide = NSBezierPath()
        guide.move(to: NSPoint(x: 4, y: my)); guide.line(to: NSPoint(x: bounds.maxX - 4, y: my))
        guide.lineWidth = 1
        guide.stroke()
        let dot = NSRect(x: cx - d / 2, y: my - d / 2, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)); ring.lineWidth = 2; ring.stroke()
    }

    private func set(from e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let t = min(max((bounds.maxY - pad - p.y) / (bounds.height - 2 * pad), 0), 1)
        canvas?.penWidth = size(forT: t).rounded()
        needsDisplay = true
        onChange?()
    }
    override func mouseDown(with e: NSEvent) { set(from: e) }
    override func mouseDragged(with e: NSEvent) { set(from: e) }
}

private func chevron(in r: NSRect) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX, y: r.maxY))
    p.line(to: NSPoint(x: r.midX, y: r.minY))
    p.line(to: NSPoint(x: r.maxX, y: r.maxY))
    p.lineWidth = 1.5
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    NSColor.secondaryLabelColor.setStroke()
    p.stroke()
}

extension NSColor {
    func isClose(to o: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = o.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.03
    }
}

// MARK: - Rounded HUD background

func hudBackground(_ size: NSSize) -> NSVisualEffectView {
    let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    v.material = .hudWindow
    v.blendingMode = .behindWindow
    v.state = .active
    v.maskImage = roundedMask(12) // proper rounded vibrancy: no square edges or shadow artifacts
    return v
}

func roundedMask(_ r: CGFloat) -> NSImage {
    let d = r * 2 + 1
    let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

/// Text button with an SF Symbol, used for bigger labelled actions.
func labelButton(_ title: String, symbol: String, tip: String, action: @escaping () -> Void) -> NSButton {
    let b = ClosureButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: nil, action: nil)
    b.imagePosition = .imageLeading
    b.bezelStyle = .rounded
    b.controlSize = .regular
    b.toolTip = tip
    b.handler = action
    b.target = b
    b.action = #selector(ClosureButton.fire)
    return b
}

final class ClosureButton: NSButton {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

/// Live microphone level bars.
final class MicMeter: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var muted = false { didSet { needsDisplay = true } }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 18))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        toolTip = "Microphone level"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let bars = 6
        let w: CGFloat = 4, gap: CGFloat = 2
        let lit = muted ? 0 : Int((level * Float(bars)).rounded(.up))
        for i in 0..<bars {
            let h = bounds.height * (0.35 + 0.65 * CGFloat(i) / CGFloat(bars - 1))
            let rect = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            let on = i < lit
            let c: NSColor = !on ? .tertiaryLabelColor : (i >= bars - 1 ? .systemRed : (i >= bars - 2 ? .systemYellow : .systemGreen))
            c.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

// MARK: - Corner toast (Windows-style "Snip copied" thumbnail)

final class Toast: NSPanel {
    private var hideTimer: Timer?
    private var hovering = false
    var onClick: (() -> Void)?

    init(thumbnail: NSImage, title: String, subtitle: String, screen: NSScreen) {
        let maxW: CGFloat = 300, maxH: CGFloat = 180
        let s = min(maxW / max(thumbnail.size.width, 1), maxH / max(thumbnail.size.height, 1), 1)
        let thumbSize = NSSize(width: max(60, thumbnail.size.width * s), height: max(40, thumbnail.size.height * s))
        let w = max(thumbSize.width + 20, 260), h = thumbSize.height + 64
        let vf = screen.visibleFrame
        super.init(contentRect: NSRect(x: vf.maxX - w - 16, y: vf.minY + 16, width: w, height: h),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = hudBackground(NSSize(width: w, height: h))
        let iv = NSImageView(frame: NSRect(x: (w - thumbSize.width) / 2, y: 54, width: thumbSize.width, height: thumbSize.height))
        iv.image = thumbnail
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        bg.addSubview(iv)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.frame = NSRect(x: 12, y: 28, width: w - 24, height: 18)
        bg.addSubview(t)
        let st = NSTextField(labelWithString: subtitle)
        st.font = .systemFont(ofSize: 11)
        st.textColor = .secondaryLabelColor
        st.frame = NSRect(x: 12, y: 10, width: w - 24, height: 16)
        bg.addSubview(st)
        let close = Swatch(symbol: "xmark", tip: "Dismiss", side: 20)
        close.frame.origin = NSPoint(x: w - 26, y: h - 26)
        close.translatesAutoresizingMaskIntoConstraints = true
        close.action = { [weak self] in self?.dismiss() }
        bg.addSubview(close)
        contentView = bg
        bg.addTrackingArea(NSTrackingArea(rect: bg.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    func show() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        armTimer()
    }
    private func armTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self, !self.hovering else { return }
            self.dismiss()
        }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; armTimer() }
    override func mouseUp(with event: NSEvent) {
        let p = event.locationInWindow
        if p.x > frame.width - 30 && p.y > frame.height - 30 { return } // close button
        onClick?()
        dismiss()
    }
    func dismiss() {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; animator().alphaValue = 0 }) { [weak self] in self?.orderOut(nil) }
    }
}
