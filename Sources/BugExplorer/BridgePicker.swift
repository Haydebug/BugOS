import AppKit

/// The Windows-style Save As / Open window shown in place of Apple's dialog.
/// It only collects the choice; Bridge then fills in Apple's (hidden) dialog with it.
final class PickerController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    enum Kind { case save, open }

    let kind: Kind
    let window: PickerPanel
    let browser: BrowserViewController
    private let nameField = NSTextField()
    private let actionButton = NSButton()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let nativeButton = NSButton(title: "Use macOS dialog", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var userTypedName = false
    private(set) var panel: ApplePanel?

    var onSave: ((URL, String) -> Void)?
    var onOpen: ((URL) -> Void)?
    var onCancel: (() -> Void)?
    var onNative: (() -> Void)?

    init(kind: Kind, appName: String, startDir: URL, cover axFrame: CGRect?) {
        self.kind = kind
        browser = BrowserViewController(location: .folder(startDir))
        window = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = (kind == .save ? "Save As" : "Open") + " — " + appName
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 420)
        window.delegate = self
        window.onCancel = { [weak self] in self?.cancel() }

        browser.pickFile = { [weak self] item in self?.picked(item) }
        browser.onSelection = { [weak self] sel in self?.selectionChanged(sel) }

        let bottom = buildBottomBar()
        let root = NSView()
        let bv = browser.view
        for v in [bv, bottom] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            bv.topAnchor.constraint(equalTo: root.topAnchor),
            bv.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bv.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: kind == .save ? 92 : 62),
        ])
        window.contentView = root
        place(over: axFrame)
        setWaiting(true)
    }

    private func buildBottomBar() -> NSView {
        let bar = ToolbarBackground()
        let label = NSTextField(labelWithString: "File name:")
        label.alignment = .right
        nameField.placeholderString = kind == .save ? "Name" : "Type a name or choose a file"
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(primary)
        nameField.font = .systemFont(ofSize: 13)
        actionButton.title = kind == .save ? "Save" : "Open"
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(primary)
        actionButton.keyEquivalent = ""          // Return in the address bar must not save; the name box handles Return
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        nativeButton.bezelStyle = .rounded
        nativeButton.target = self
        nativeButton.action = #selector(native)
        nativeButton.toolTip = "Close this window and use Apple's standard dialog instead"
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        for v in [label, nameField, actionButton, cancelButton, nativeButton, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(v)
        }
        let showName = kind == .save
        label.isHidden = !showName
        nameField.isHidden = !showName
        var cons = [
            cancelButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            cancelButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -14),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            actionButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            nativeButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            nativeButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: nativeButton.trailingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),
        ]
        if showName {
            cons += [
                label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
                label.widthAnchor.constraint(equalToConstant: 80),
                label.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
                nameField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
                nameField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
                nameField.topAnchor.constraint(equalTo: bar.topAnchor, constant: 14),
            ]
        }
        NSLayoutConstraint.activate(cons)
        return bar
    }

    /// The usable area of the screen the app's window is on (keeping clear of the BugDock bar).
    private var screenArea: NSRect = .zero
    private func area(for axFrame: CGRect?) -> NSRect {
        let c = axFrame.map(AXK.cocoa)
        let scr = c.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.screens.first
        var v = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        v.origin.y += 56; v.size.height -= 56                      // BugDock's taskbar
        return v
    }

    private func clamp(_ f: NSRect) -> NSRect {
        let screen = screenArea
        var f = f
        f.size.width = min(f.width, screen.width)
        f.size.height = min(f.height, screen.height)
        f.origin.x = max(screen.minX, min(f.origin.x, screen.maxX - f.width))
        f.origin.y = max(screen.minY, min(f.origin.y, screen.maxY - f.height))
        return f
    }

    /// Sit centred over the app's window, big enough to hide Apple's dialog completely.
    func place(over axFrame: CGRect?) {
        screenArea = area(for: axFrame)
        let screen = screenArea
        var f = window.frame
        if let ax = axFrame {
            let c = AXK.cocoa(ax)
            f.size.width = max(f.width, min(c.width + 40, screen.width - 40), 960)
            f.size.height = max(f.height, 600)
            f.origin = NSPoint(x: c.midX - f.width / 2, y: c.maxY - f.height + 20)
        } else {
            f.origin = NSPoint(x: screen.midX - f.width / 2, y: screen.midY - f.height / 2)
        }
        window.setFrame(clamp(f), display: true)
    }

    /// Grow/move if needed so Apple's dialog is fully underneath us.
    func cover(_ axFrame: CGRect) {
        let need = AXK.cocoa(axFrame).insetBy(dx: -12, dy: -12)
        if !window.frame.contains(need) { window.setFrame(clamp(window.frame.union(need)), display: true) }
    }

    private var keyMonitor: Any?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        focus()
        // Activation finishes a moment later and macOS re-focuses the app's last window; take focus back.
        for delay in [0.05, 0.2, 0.45] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.focus() } }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window, e.keyCode == 53 else { return e }
            // Escape cancels (unless it's closing the address bar's text mode first).
            if let tv = self.window.firstResponder as? NSTextView, tv.delegate is AddressField { return e }
            self.cancel(); return nil
        }
    }

    private var closed = false

    private func focus() {
        guard !closed else { return }
        window.makeKeyAndOrderFront(nil)
        if kind == .save {
            if window.firstResponder !== nameField.currentEditor() {
                window.makeFirstResponder(nameField)
                selectStem()
            }
        } else if !(window.firstResponder is NSTableView || window.firstResponder is NSCollectionView) {
            browser.focusContent()
        }
    }

    /// Apple's dialog has been found: we can act on it now.
    func attach(_ p: ApplePanel) {
        panel = p
        if let f = p.frame { cover(f) }
        if kind == .save, !userTypedName {
            nameField.stringValue = p.prefilledName
            if window.isKeyWindow { window.makeFirstResponder(nameField) }
            selectStem()
        }
        setWaiting(false)
    }

    func setWaiting(_ waiting: Bool) {
        actionButton.isEnabled = !waiting
        status.stringValue = waiting ? "Getting ready…" : ""
    }

    func setBusy(_ text: String) {
        status.stringValue = text
        [actionButton, cancelButton, nativeButton, nameField].forEach { ($0 as? NSControl)?.isEnabled = false }
    }

    func close() {
        closed = true
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        window.delegate = nil
        window.orderOut(nil)
        browser.teardown()
    }

    private func selectStem() {
        guard let ed = nameField.currentEditor() else { return }
        let n = nameField.stringValue as NSString
        let ext = n.pathExtension
        ed.selectedRange = NSRange(location: 0, length: ext.isEmpty ? n.length : n.length - (ext as NSString).length - 1)
    }

    func controlTextDidChange(_ n: Notification) { userTypedName = true }

    // MARK: Choices

    private func selectionChanged(_ sel: [FileItem]) {
        // Clicking a file puts its name in the box, like Windows.
        if kind == .save, sel.count == 1, !sel[0].isDirectory {
            nameField.stringValue = sel[0].name
            userTypedName = true
        }
    }

    private func picked(_ item: FileItem) {
        switch kind {
        case .open: finishOpen(item.url)
        case .save:
            nameField.stringValue = item.name
            primary()
        }
    }

    @objc private func primary() {
        guard panel != nil else { NSSound.beep(); return }
        switch kind {
        case .open:
            let sel = browser.selection
            if sel.count == 1, sel[0].isDirectory { browser.open(sel[0]); return }
            if sel.count == 1 { finishOpen(sel[0].url); return }
            if sel.count > 1 {
                showError("Choose one file.", info: "To open several files at once, use “Use macOS dialog”.", in: window); return
            }
            NSSound.beep()
        case .save:
            finishSave()
        }
    }

    private func finishOpen(_ url: URL) { onOpen?(url) }

    private func finishSave() {
        var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard var dir = browser.currentDirectory else {
            showError("Choose a folder to save in.", info: "Open a folder (Desktop, Documents, …) first.", in: window); return
        }
        guard !name.isEmpty else { NSSound.beep(); return }
        // A typed path ("~/Desktop/notes.txt" or "Projects/notes.txt") works too.
        if name.contains("/") {
            guard let u = FS.resolve(typed: name, relativeTo: dir) else { NSSound.beep(); return }
            if FS.isDirectory(u) { browser.navigate(.folder(u)); nameField.stringValue = ""; return }
            dir = u.deletingLastPathComponent()
            name = u.lastPathComponent
            guard FS.isDirectory(dir) else { showError("That folder doesn't exist.", info: dir.path, in: window); return }
        }
        // Keep the extension the app suggested if the name has none (Apple would add it anyway).
        let suggestedExt = ((panel?.prefilledName ?? "") as NSString).pathExtension
        if (name as NSString).pathExtension.isEmpty, !suggestedExt.isEmpty { name += "." + suggestedExt }
        if FS.exists(dir.appendingPathComponent(name)) {
            let a = NSAlert()
            a.messageText = "“\(name)” already exists."
            a.informativeText = "Do you want to replace it?"
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Cancel")
            a.alertStyle = .warning
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        onSave?(dir, name)
    }

    @objc func cancel() { onCancel?() }
    @objc private func native() { onNative?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
}

final class PickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
