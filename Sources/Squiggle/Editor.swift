// Screenshot editor window: image + tools; every change re-copies to the clipboard.
import AppKit
import BugOSKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// BugOS › Squiggle › Save to (default ~/Desktop/Screenshots).
var saveFolder: URL {
    UserDefaults.standard.string(forKey: SquiggleSetting.saveFolder).map { URL(fileURLWithPath: $0) } ?? SquiggleSetting.defaultFolder
}

func timestamp() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
    return f.string(from: Date())
}

func copyImageToClipboard(_ rep: NSBitmapImageRep) {
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(png, forType: .png)
    if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
}

final class EditorWindow: NSWindow, NSWindowDelegate {
    let canvas: Canvas
    let strip: ToolStrip
    var onClosed: ((EditorWindow) -> Void)?
    private var savedNote: String?

    /// `placeAt`: put the image exactly over this screen area (global coords), so it looks like drawing on the screen.
    init(cgImage: CGImage, pointSize: NSSize, screen: NSScreen, placeAt: NSRect? = nil) {
        let toolbarH: CGFloat = 38
        let vf = screen.visibleFrame
        let scale = placeAt != nil ? 1 : min(1, (vf.width * 0.9) / pointSize.width, (vf.height * 0.9 - toolbarH) / pointSize.height)
        let canvasSize = NSSize(width: max(1, floor(pointSize.width * scale)), height: max(1, floor(pointSize.height * scale)))
        canvas = Canvas(cgImage: cgImage, size: canvasSize)
        strip = ToolStrip(canvas: canvas)

        let save = Swatch(symbol: "square.and.arrow.down", tip: "Save to Screenshots folder (⌘S)")
        let saveAs = Swatch(symbol: "square.and.arrow.down.on.square", tip: "Save As… (⇧⌘S)")
        strip.addArrangedSubview(spacer(8))
        strip.addArrangedSubview(save)
        strip.addArrangedSubview(saveAs)

        let stripW = strip.fittingSize.width + 16
        let contentW = max(canvasSize.width, stripW)
        let contentSize = NSSize(width: contentW, height: canvasSize.height + toolbarH)
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        delegate = self
        level = .floating

        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))
        canvas.frame.origin = NSPoint(x: (contentW - canvasSize.width) / 2, y: 0)
        content.addSubview(canvas)
        strip.frame = NSRect(x: 8, y: canvasSize.height, width: contentW - 16, height: toolbarH)
        content.addSubview(strip)
        contentView = content

        save.action = { [weak self] in self?.saveToFolder() }
        saveAs.action = { [weak self] in self?.saveAs() }
        canvas.onChange = { [weak self] in self?.copyToClipboard() }
        canvas.onToolChange = { [weak self] in self?.strip.refresh(); self?.updateTitle() }
        updateTitle()
        if let r = placeAt {
            // Window content origin so the canvas lands on r, then keep the window on screen.
            let contentOrigin = NSPoint(x: r.minX - canvas.frame.minX, y: r.minY)
            var f = frameRect(forContentRect: NSRect(origin: contentOrigin, size: contentSize))
            if f.maxY > vf.maxY { f.origin.y -= f.maxY - vf.maxY }
            if f.minY < vf.minY { f.origin.y = vf.minY }
            if f.maxX > vf.maxX { f.origin.x -= f.maxX - vf.maxX }
            if f.minX < vf.minX { f.origin.x = vf.minX }
            setFrame(f, display: false)
        } else {
            setFrameOrigin(NSPoint(x: vf.midX - frame.width / 2, y: vf.midY - frame.height / 2))
        }
    }

    func updateTitle() {
        title = "Squiggle — \(canvas.toolDescription)" + (savedNote.map { " · \($0)" } ?? " · copied to clipboard")
    }

    func copyToClipboard() {
        if let rep = canvas.render() { copyImageToClipboard(rep) }
    }

    private func pngData() -> Data? { canvas.render()?.representation(using: .png, properties: [:]) }

    func saveToFolder() {
        canvas.commitText()
        guard let png = pngData() else { return }
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let url = saveFolder.appendingPathComponent("Squiggle \(timestamp()).png")
        do { try png.write(to: url); savedNote = "saved \(url.lastPathComponent)"; updateTitle() } catch { NSSound.beep() }
    }

    func saveAs() {
        canvas.commitText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "Squiggle \(timestamp()).png"
        panel.directoryURL = saveFolder
        panel.canCreateDirectories = true
        level = .normal
        panel.beginSheetModal(for: self) { [weak self] resp in
            guard let self else { return }
            self.level = .floating
            guard resp == .OK, let url = panel.url, let rep = self.canvas.render() else { return }
            let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
            let data = isJPEG ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
                              : rep.representation(using: .png, properties: [:])
            do { try data?.write(to: url); self.savedNote = "saved \(url.lastPathComponent)"; self.updateTitle() } catch { NSSound.beep() }
        }
    }

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), let ch = e.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: e) }
        if canvas.isEditingText {
            if ch == "v" { canvas.pasteText(); return true }
            canvas.commitText() // any other shortcut finishes the text first
        }
        switch (ch, mods.contains(.shift)) {
        case ("z", false): canvas.undo(); return true
        case ("z", true): canvas.redo(); return true
        case ("w", false), ("q", false): close(); return true
        case ("c", _): copyToClipboard(); return true
        case ("s", false): saveToFolder(); return true
        case ("s", true): saveAs(); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    override func keyDown(with e: NSEvent) {
        if canvas.handleKey(e) { return }
        if e.keyCode == UInt16(kVK_Escape) || e.keyCode == UInt16(kVK_Return) { close(); return }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        canvas.commitText()
        copyToClipboard()
        onClosed?(self)
    }
}
