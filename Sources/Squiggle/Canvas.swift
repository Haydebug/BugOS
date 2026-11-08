// Drawing surface shared by the screenshot editor and the live recording overlay.
import AppKit
import Carbon.HIToolbox

let palette: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.18, blue: 0.13, alpha: 1), // red
    NSColor(srgbRed: 1.00, green: 0.55, blue: 0.00, alpha: 1), // orange
    NSColor(srgbRed: 1.00, green: 0.84, blue: 0.00, alpha: 1), // yellow
    NSColor(srgbRed: 0.20, green: 0.80, blue: 0.30, alpha: 1), // green
    NSColor(srgbRed: 0.10, green: 0.75, blue: 0.85, alpha: 1), // teal
    NSColor(srgbRed: 0.10, green: 0.45, blue: 1.00, alpha: 1), // blue
    NSColor(srgbRed: 0.60, green: 0.30, blue: 1.00, alpha: 1), // purple
    NSColor(srgbRed: 1.00, green: 0.35, blue: 0.70, alpha: 1), // pink
    .white,
    NSColor(white: 0.55, alpha: 1),                              // gray
    .black,
    NSColor(srgbRed: 0.55, green: 0.33, blue: 0.18, alpha: 1), // brown
]
let minPenWidth: CGFloat = 1, maxPenWidth: CGFloat = 40
func textFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .bold) }

struct Stroke {
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var highlighter: Bool
    var drawWidth: CGFloat { highlighter ? width * 4 : width }
}

struct TextItem {
    var string: String
    var origin: CGPoint
    var color: NSColor
    var size: CGFloat
    var attributed: NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: textFont(size), .foregroundColor: color])
    }
    var rect: NSRect { NSRect(origin: origin, size: attributed.size()) }
}

enum Item {
    case stroke(Stroke)
    case erase(Stroke)   // precision eraser path: clears annotation pixels it passes over
    case text(TextItem)
}

enum Tool { case pen, eraser, text }
enum EraserMode { case wholeStroke, precision }

final class Canvas: NSView {
    let cgImage: CGImage?
    private(set) var items: [Item] = []
    private var history: [[Item]] = []
    private var redoStack: [[Item]] = []
    /// Snapshot before a change; any new change clears redo.
    private func pushHistory() { history.append(items); redoStack.removeAll() }
    private var current: Item?

    var tool: Tool = .pen { didSet { if tool != .text { commitText() }; toolChanged() } }
    var eraserMode: EraserMode = .wholeStroke { didSet { toolChanged() } }
    var color: NSColor = Canvas.savedColor { didSet { Canvas.savedColor = color; toolChanged() } }
    var penWidth: CGFloat = Canvas.savedWidth { didSet { penWidth = min(max(penWidth, minPenWidth), maxPenWidth); Canvas.savedWidth = penWidth; toolChanged() } }
    var textSize: CGFloat { (penWidth * 4 + 8).rounded() }
    var eraserSize: CGFloat { penWidth * 5 + 4 }

    static var savedColor: NSColor {
        get {
            if let d = UserDefaults.standard.data(forKey: "penColor"),
               let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: d) { return c }
            return palette[0]
        }
        set { UserDefaults.standard.set(try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true), forKey: "penColor") }
    }
    static var savedWidth: CGFloat {
        get { (UserDefaults.standard.object(forKey: "penWidth") as? Double).map { CGFloat($0) } ?? 4 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "penWidth") }
    }
    var highlighter = false { didSet { toolChanged() } }

    var onChange: (() -> Void)?
    var onToolChange: (() -> Void)?
    var onColorKey: (() -> Void)?   // C → open the color picker

    /// Text being typed right now — drawn exactly as it will look when placed.
    private var editingText: TextItem?
    private var caretOn = true
    private var caretTimer: Timer?
    private var editPushedHistory = false
    private var erasedThisDrag = false
    private var lastErasePoint: CGPoint?

    var isEditingText: Bool { editingText != nil }

    init(cgImage: CGImage?, size: NSSize) {
        self.cgImage = cgImage
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Tool state

    private func toolChanged() {
        window?.invalidateCursorRects(for: self)
        if var t = editingText {
            // Keep the text's top edge put while the size changes.
            let top = t.rect.maxY
            t.color = color
            t.size = textSize
            t.origin.y = top - t.rect.height
            editingText = t
            needsDisplay = true
        }
        onToolChange?()
    }

    var toolDescription: String {
        switch tool {
        case .pen: return highlighter ? "Highlighter" : "Pen"
        case .text: return "Text — click to type"
        case .eraser: return eraserMode == .wholeStroke ? "Eraser: whole strokes (E for precision)" : "Eraser: precision (E for whole strokes)"
        }
    }

    func selectPen(highlighter hl: Bool) { tool = .pen; highlighter = hl }
    func pressEraser() { if tool == .eraser { eraserMode = eraserMode == .wholeStroke ? .precision : .wholeStroke } else { tool = .eraser } }

    /// Shared tool shortcuts. Returns true if handled.
    func handleKey(_ e: NSEvent) -> Bool {
        if isEditingText { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        if e.keyCode == UInt16(kVK_Delete) || e.keyCode == UInt16(kVK_ForwardDelete) { clear(); return true }
        guard let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        if let n = Int(ch), n >= 1, n <= min(9, palette.count) { color = palette[n - 1]; return true }
        switch ch {
        case "e": pressEraser()
        case "p", "d", "b": selectPen(highlighter: false)
        case "h": selectPen(highlighter: !(tool == .pen && highlighter))
        case "t": tool = .text
        case "c": onColorKey?()
        case "[": penWidth = (penWidth / 1.25).rounded(.down)
        case "]": penWidth = max(penWidth + 1, (penWidth * 1.25).rounded(.up))
        default: return false
        }
        return true
    }

    // MARK: Cursor

    override func resetCursorRects() {
        switch tool {
        case .pen: addCursorRect(bounds, cursor: Canvas.brushCursor(highlighter ? penWidth * 4 : penWidth,
                                                                    color: highlighter ? color.withAlphaComponent(0.4) : color))
        case .text: addCursorRect(bounds, cursor: .iBeam)
        case .eraser: addCursorRect(bounds, cursor: Canvas.circleCursor(eraserMode == .precision ? eraserSize : 12,
                                                                       dashed: eraserMode == .wholeStroke))
        }
    }

    /// Pen cursor: a circle exactly the brush's size (filled faintly with the brush color) plus a center dot.
    static func brushCursor(_ size: CGFloat, color: NSColor) -> NSCursor {
        let d = max(size, 3)
        let s = ceil(max(d + 6, 15))
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
            let c = NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)
            color.withAlphaComponent(min(color.alphaComponent, 0.35)).setFill()
            NSBezierPath(ovalIn: c).fill()
            let o = NSBezierPath(ovalIn: c)
            NSColor.black.withAlphaComponent(0.8).setStroke(); o.lineWidth = 2.5; o.stroke()
            NSColor.white.setStroke(); o.lineWidth = 1; o.stroke()
            let dot = NSRect(x: s / 2 - 1, y: s / 2 - 1, width: 2, height: 2)
            NSColor.black.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -0.75, dy: -0.75)).fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: dot).fill()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: s / 2, y: s / 2))
    }

    static func circleCursor(_ d: CGFloat, dashed: Bool) -> NSCursor {
        let s = d + 4
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
            let o = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            NSColor.black.setStroke(); o.lineWidth = 3; o.stroke()
            NSColor.white.setStroke(); o.lineWidth = 1.5
            if dashed { o.setLineDash([3, 2], count: 2, phase: 0) }
            o.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: s / 2, y: s / 2))
    }

    // MARK: Drawing

    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count == 1 { p.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)); return p }
        for i in 1..<pts.count {
            let c = pts[i]
            let end = i == pts.count - 1 ? c : CGPoint(x: (c.x + pts[i + 1].x) / 2, y: (c.y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: end, control: c)
        }
        return p
    }

    static func strokePath(_ ctx: CGContext, _ s: Stroke, color: NSColor, width: CGFloat) {
        ctx.addPath(smoothPath(s.points))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color.cgColor)
        ctx.strokePath()
    }

    /// Draws annotations into their own transparency layer so the precision eraser only clears annotations.
    static func drawItems(_ items: [Item], in ctx: CGContext) {
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for it in items {
            switch it {
            case .stroke(let s):
                ctx.setBlendMode(.normal)
                strokePath(ctx, s, color: s.highlighter ? s.color.withAlphaComponent(0.4) : s.color, width: s.drawWidth)
            case .erase(let s):
                ctx.setBlendMode(.clear)
                strokePath(ctx, s, color: .black, width: s.width)
            case .text(let t):
                ctx.setBlendMode(.normal)
                t.attributed.draw(in: t.rect)
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let img = cgImage {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: bounds)
        }
        var all = items + (current.map { [$0] } ?? [])
        if let t = editingText { all.append(.text(t)) }
        Canvas.drawItems(all, in: ctx)
        if let t = editingText { drawTextCaret(t) }
    }

    /// Full-resolution image with annotations burned in.
    func render() -> NSBitmapImageRep? {
        guard let img = cgImage else { return nil }
        let pw = img.width, ph = img.height
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let ctx = g.cgContext
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: CGFloat(pw) / bounds.width, y: CGFloat(ph) / bounds.height)
        Canvas.drawItems(items, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = bounds.size
        return rep
    }

    /// Annotations only (transparent background) at a given pixel size — used for video overlays.
    func renderAnnotations(pixelSize: CGSize) -> CGImage? {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: CGFloat(w) / bounds.width, y: CGFloat(h) / bounds.height)
        Canvas.drawItems(items, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Replace everything (used when switching between video drawing segments).
    func setItems(_ new: [Item]) {
        commitText()
        items = new
        history.removeAll()
        redoStack.removeAll()
        current = nil
        needsDisplay = true
    }

    // MARK: Editing

    private func changed() { needsDisplay = true; onChange?() }

    func undo() {
        commitText()
        guard let last = history.popLast() else { NSSound.beep(); return }
        redoStack.append(items)
        items = last
        changed()
    }

    func redo() {
        commitText()
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        history.append(items)
        items = next
        changed()
    }

    func clear() {
        commitText()
        guard !items.isEmpty else { return }
        pushHistory()
        items.removeAll()
        changed()
    }

    private func hit(_ it: Item, _ p: CGPoint) -> Bool {
        switch it {
        case .stroke(let s):
            return Canvas.smoothPath(s.points)
                .copy(strokingWithWidth: s.drawWidth + 10, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .contains(p)
        case .text(let t): return t.rect.insetBy(dx: -4, dy: -4).contains(p)
        case .erase: return false
        }
    }

    private func eraseWhole(at p: CGPoint) {
        let before = items.count
        items.removeAll { hit($0, p) }
        if items.count != before { erasedThisDrag = true; needsDisplay = true }
    }

    private func eraseAlong(to p: CGPoint) {
        let from = lastErasePoint ?? p
        let dist = hypot(p.x - from.x, p.y - from.y)
        let steps = max(1, Int(dist / 3))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            eraseWhole(at: CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t))
        }
        lastErasePoint = p
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .pen:
            current = .stroke(Stroke(points: [p], color: color, width: penWidth, highlighter: highlighter))
        case .eraser:
            if eraserMode == .precision {
                current = .erase(Stroke(points: [p], color: .black, width: eraserSize, highlighter: false))
            } else {
                history.append(items) // only kept (and redo cleared) if something gets erased
                erasedThisDrag = false
                lastErasePoint = p
                eraseWhole(at: p)
            }
        case .text:
            if isEditingText { commitText(); return }
            if let idx = items.lastIndex(where: { if case .text(let t) = $0 { return t.rect.insetBy(dx: -4, dy: -4).contains(p) }; return false }),
               case .text(let t) = items[idx] {
                pushHistory()
                items.remove(at: idx)
                needsDisplay = true
                beginText(existing: t, at: p, pushedHistory: true)
            } else {
                beginText(existing: nil, at: p, pushedHistory: false)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch current {
        case .stroke(var s)?: s.points.append(p); current = .stroke(s)
        case .erase(var s)?: s.points.append(p); current = .erase(s)
        default:
            if tool == .eraser && eraserMode == .wholeStroke { eraseAlong(to: p) }
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let c = current {
            pushHistory()
            items.append(c)
            current = nil
            changed()
        } else if tool == .eraser && eraserMode == .wholeStroke {
            if erasedThisDrag { redoStack.removeAll(); changed() } else { _ = history.popLast() }
            lastErasePoint = nil
        }
    }

    // MARK: Text (typed straight onto the canvas, WYSIWYG)

    private func lineHeight(_ size: CGFloat) -> CGFloat {
        let f = textFont(size)
        return ceil(f.ascender - f.descender + f.leading)
    }

    private func drawTextCaret(_ t: TextItem) {
        let h = lineHeight(t.size)
        let w = t.string.isEmpty ? 0 : t.attributed.size().width
        // faint box so you can see where the text sits
        let box = NSRect(x: t.origin.x - 4, y: t.origin.y - 2, width: max(w, 12) + 8, height: h + 4)
        let dash = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        dash.setLineDash([4, 3], count: 2, phase: 0)
        dash.lineWidth = 1
        NSColor.white.withAlphaComponent(0.7).setStroke()
        dash.stroke()
        guard caretOn else { return }
        let caret = NSRect(x: t.origin.x + w + 1, y: t.origin.y + 1, width: max(2, t.size / 14), height: h - 2)
        t.color.setFill()
        caret.fill()
    }

    private func beginText(existing: TextItem?, at p: CGPoint, pushedHistory: Bool) {
        let size = existing?.size ?? textSize
        editingText = existing ?? TextItem(string: "", origin: CGPoint(x: p.x, y: p.y - lineHeight(size) / 2), color: color, size: size)
        editPushedHistory = pushedHistory
        window?.makeFirstResponder(self)
        caretOn = true
        caretTimer?.invalidate()
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            self?.caretOn.toggle(); self?.needsDisplay = true
        }
        needsDisplay = true
    }

    func commitText() {
        guard let t = editingText else { return }
        editingText = nil
        caretTimer?.invalidate()
        caretTimer = nil
        needsDisplay = true
        if !t.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !editPushedHistory { pushHistory() }
            items.append(.text(t))
            changed()
        } else if editPushedHistory {
            changed() // an existing text item was emptied → deleted
        }
        editPushedHistory = false
    }

    private func editText(_ f: (inout String) -> Void) {
        guard var t = editingText else { return }
        f(&t.string)
        editingText = t
        caretOn = true
        needsDisplay = true
    }

    func pasteText() {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        editText { $0 += str.replacingOccurrences(of: "\n", with: " ") }
    }

    override func keyDown(with e: NSEvent) {
        if isEditingText { interpretKeyEvents([e]); return }
        super.keyDown(with: e)
    }
    override func insertText(_ insertString: Any) {
        let str = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        editText { $0 += str }
    }
    override func doCommand(by sel: Selector) {
        switch sel {
        case #selector(NSResponder.deleteBackward(_:)): editText { if !$0.isEmpty { $0.removeLast() } }
        case #selector(NSResponder.deleteWordBackward(_:)):
            editText { s in
                while s.last == " " { s.removeLast() }
                while let c = s.last, c != " " { s.removeLast() }
            }
        case #selector(NSResponder.deleteToBeginningOfLine(_:)): editText { $0 = "" }
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)): commitText()
        default: break
        }
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard isEditingText, e.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: e) }
        if e.charactersIgnoringModifiers?.lowercased() == "v" { pasteText(); return true }
        return super.performKeyEquivalent(with: e)
    }
}
