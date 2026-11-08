import AppKit
import Quartz

// MARK: - Actions shared by menus

enum Actions {
    static func openInTerminal(_ dir: URL) {
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([dir], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
    }
    static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    static func chooseApp(for url: URL, window: NSWindow?) {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.prompt = "Open"
        p.message = "Choose an app to open “\(url.lastPathComponent)”"
        if p.runModal() == .OK, let app = p.url { open(url, with: app) }
    }
}

// MARK: - Quick Look (space bar)

final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func toggle(urls: [URL], from window: NSWindow?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible { panel.orderOut(nil); return }
        guard !urls.isEmpty else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func update(urls: [URL]) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible, !urls.isEmpty else { return }
        self.urls = urls
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

// MARK: - Details pane (right side)

final class DetailsPane: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let typeLabel = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    private var shownURL: URL?
    var onProperties: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.isSelectable = true
        typeLabel.textColor = .secondaryLabelColor
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        let propsButton = NSButton(title: "Properties", target: self, action: #selector(props))
        propsButton.bezelStyle = .rounded
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let sep = NSBox(); sep.boxType = .separator
        [iconView, nameLabel, typeLabel, sep, grid, propsButton].forEach(stack.addArrangedSubview)
        iconView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        let doc = FlippedView()
        doc.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        doc.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll); scroll.pin(to: self)
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = Theme.content.cgColor }

    @objc private func props() { onProperties?() }

    func show(selection: [FileItem], folder: URL?, folderItemCount: Int) {
        grid.subviews.forEach { $0.removeFromSuperview() }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        func row(_ k: String, _ v: String) {
            guard !v.isEmpty else { return }
            let kl = NSTextField(labelWithString: k); kl.textColor = .secondaryLabelColor; kl.font = .systemFont(ofSize: 12)
            let vl = NSTextField(wrappingLabelWithString: v); vl.font = .systemFont(ofSize: 12); vl.isSelectable = true
            vl.preferredMaxLayoutWidth = max(120, bounds.width - 140)
            grid.addRow(with: [kl, vl])
        }
        if selection.count > 1 {
            shownURL = nil
            iconView.image = symbol("square.on.square", size: 64)
            nameLabel.stringValue = "\(selection.count) items selected"
            let files = selection.filter { !$0.isDirectory }
            typeLabel.stringValue = ""
            row("Total size", files.isEmpty ? "" : Fmt.size(files.reduce(0) { $0 + $1.size }))
            row("Folders", "\(selection.count - files.count)")
            row("Files", "\(files.count)")
            return
        }
        if let it = selection.first {
            shownURL = it.url
            iconView.image = Thumbs.cached(it.url, size: 256) ?? it.icon(size: 256)
            if Thumbs.wants(it) {
                let u = it.url
                Thumbs.request(u, size: 256) { [weak self] img in if self?.shownURL == u { self?.iconView.image = img } }
            }
            nameLabel.stringValue = it.name
            typeLabel.stringValue = it.typeName
            if !it.isDirectory { row("Size", Fmt.size(it.size)) }
            row("Date modified", Fmt.date(it.modified))
            row("Date created", Fmt.date(it.created))
            if let app = NSWorkspace.shared.urlForApplication(toOpen: it.url), !it.isDirectory, !it.isApp {
                row("Opens with", FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
            }
            if let dims = imageDimensions(it.url) { row("Dimensions", dims) }
            row("Location", it.folder.path)
            return
        }
        shownURL = folder
        if let folder {
            iconView.image = Icons.icon(for: folder, size: 256)
            nameLabel.stringValue = FS.displayName(folder)
            typeLabel.stringValue = Fmt.items(folderItemCount)
            let v = try? folder.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            row("Date modified", Fmt.date(v?.contentModificationDate))
            row("Date created", Fmt.date(v?.creationDate))
            row("Location", folder.deletingLastPathComponent().path)
        } else {
            iconView.image = nil
            nameLabel.stringValue = "Select a single file to get more information"
            typeLabel.stringValue = ""
        }
    }

    private func imageDimensions(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) × \(h)"
    }
}

// MARK: - Preview pane

final class PreviewPane: NSView {
    private var preview: QLPreviewView?
    private let message = NSTextField(labelWithString: "Select a file to preview.")
    private var current: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        message.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        message.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        if let p = QLPreviewView(frame: .zero, style: .compact) {
            p.autostarts = true
            p.shouldCloseWithWindow = false
            addSubview(p); p.pin(to: self)
            p.isHidden = true
            preview = p
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() { layer?.backgroundColor = Theme.content.cgColor }

    func show(_ item: FileItem?) {
        guard let item, !item.isDirectory else {
            current = nil
            preview?.isHidden = true
            message.isHidden = false
            message.stringValue = item == nil ? "Select a file to preview." : "No preview available."
            return
        }
        guard item.url != current else { return }
        current = item.url
        // Don't pull large files over the network just to preview them.
        if FS.isNetwork(item.url) && item.size > 50_000_000 {
            preview?.isHidden = true; message.isHidden = false
            message.stringValue = "Large file on a network drive.\nOpen it to view."
            return
        }
        message.isHidden = true
        preview?.isHidden = false
        preview?.previewItem = item.url as NSURL
    }

    func teardown() { preview?.close() }
}

// MARK: - Properties window

final class PropertiesWindow: NSWindowController, NSWindowDelegate {
    private static var open: [PropertiesWindow] = []
    private let urls: [URL]
    private var sizeLabel: NSTextField?
    private var containsLabel: NSTextField?
    private var cancelled = false
    private var hiddenBox: NSButton?
    private var lockBox: NSButton?

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let w = PropertiesWindow(urls: urls)
        open.append(w)
        w.showWindow(nil)
        w.window?.center()
    }

    init(urls: [URL]) {
        self.urls = urls
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        w.title = urls.count == 1 ? "\(FS.displayName(urls[0])) Properties" : "\(urls.count) items Properties"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ n: Notification) {
        cancelled = true
        PropertiesWindow.open.removeAll { $0 === self }
    }

    private func build() {
        let grid = NSGridView()
        grid.rowSpacing = 9
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .leading
        func label(_ s: String, secondary: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.isSelectable = true
            l.font = .systemFont(ofSize: 12.5)
            if secondary { l.textColor = .secondaryLabelColor }
            l.preferredMaxLayoutWidth = 280
            return l
        }
        func sep() { let b = NSBox(); b.boxType = .separator; let r = grid.addRow(with: [b]); r.mergeCells(in: NSRange(location: 0, length: 2)); _ = r }

        let first = urls[0]
        let item = FileItem(url: first)
        let icon = NSImageView(image: urls.count == 1 ? item.icon(size: 48) : (symbol("doc.on.doc", size: 32) ?? NSImage()))
        let nameField = NSTextField(string: urls.count == 1 ? first.lastPathComponent : "\(urls.count) items")
        nameField.isEditable = false
        nameField.isSelectable = true
        grid.addRow(with: [icon, nameField])
        sep()
        if urls.count == 1 {
            grid.addRow(with: [label("Type:", secondary: true), label(item.typeName)])
            if !item.isDirectory, let app = NSWorkspace.shared.urlForApplication(toOpen: first) {
                grid.addRow(with: [label("Opens with:", secondary: true), label(FileManager.default.displayName(atPath: app.path))])
            }
            sep()
            grid.addRow(with: [label("Location:", secondary: true), label(first.deletingLastPathComponent().path)])
        } else {
            grid.addRow(with: [label("Type:", secondary: true), label("Multiple types")])
            grid.addRow(with: [label("Location:", secondary: true), label("All in " + first.deletingLastPathComponent().path)])
        }
        let size = label("Calculating…")
        sizeLabel = size
        grid.addRow(with: [label("Size:", secondary: true), size])
        let anyFolder = urls.contains(where: FS.isDirectory)
        if anyFolder {
            let c = label("")
            containsLabel = c
            grid.addRow(with: [label("Contains:", secondary: true), c])
        }
        sep()
        if urls.count == 1 {
            let v = try? first.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .contentAccessDateKey])
            grid.addRow(with: [label("Created:", secondary: true), label(v?.creationDate.map { Fmt.longDate.string(from: $0) } ?? "")])
            grid.addRow(with: [label("Modified:", secondary: true), label(v?.contentModificationDate.map { Fmt.longDate.string(from: $0) } ?? "")])
            grid.addRow(with: [label("Accessed:", secondary: true), label(v?.contentAccessDate.map { Fmt.longDate.string(from: $0) } ?? "")])
            sep()
            let rv = try? first.resourceValues(forKeys: [.isHiddenKey, .isUserImmutableKey])
            let lock = NSButton(checkboxWithTitle: "Read-only (locked)", target: self, action: #selector(toggleLock(_:)))
            lock.state = (rv?.isUserImmutable ?? false) ? .on : .off
            let hid = NSButton(checkboxWithTitle: "Hidden", target: self, action: #selector(toggleHidden(_:)))
            hid.state = (rv?.isHidden ?? false) ? .on : .off
            lockBox = lock; hiddenBox = hid
            let boxes = NSStackView(views: [lock, hid]); boxes.orientation = .vertical; boxes.alignment = .leading
            grid.addRow(with: [label("Attributes:", secondary: true), boxes])
        }
        let ok = NSButton(title: "OK", target: self, action: #selector(closeIt))
        ok.keyEquivalent = "\r"
        let stack = NSStackView(views: [grid, ok])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        window?.contentView = stack
        window?.setContentSize(stack.fittingSize)
        computeSize()
    }

    /// Folder sizes are computed on request only, and never by walking a network share.
    private func computeSize() {
        let urls = self.urls
        if urls.contains(where: { FS.isDirectory($0) && FS.isNetwork($0) }) {
            sizeLabel?.stringValue = "Not calculated on network drives"
            containsLabel?.stringValue = "—"
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var bytes: Int64 = 0, files = 0, folders = 0
            var lastUpdate = Date()
            for u in urls {
                if FS.isDirectory(u) {
                    folders += 1
                    let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [], errorHandler: { _, _ in true })
                    while let f = e?.nextObject() as? URL {
                        if self?.cancelled ?? true { return }
                        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                        if v?.isDirectory == true { folders += 1 } else { files += 1; bytes += Int64(v?.fileSize ?? 0) }
                        if Date().timeIntervalSince(lastUpdate) > 0.25 {
                            lastUpdate = Date()
                            let b = bytes, fi = files, fo = folders
                            DispatchQueue.main.async { self?.setSize(b, fi, fo, done: false) }
                        }
                    }
                    folders -= 1   // don't count the selected folder itself
                } else {
                    files += 1
                    bytes += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
            let b = bytes, fi = files, fo = folders
            DispatchQueue.main.async { self?.setSize(b, fi, fo, done: true) }
        }
    }

    private func setSize(_ bytes: Int64, _ files: Int, _ folders: Int, done: Bool) {
        sizeLabel?.stringValue = Fmt.exactSize(bytes) + (done ? "" : " …")
        containsLabel?.stringValue = "\(Fmt.group.string(from: NSNumber(value: files)) ?? "\(files)") Files, \(Fmt.group.string(from: NSNumber(value: folders)) ?? "\(folders)") Folders"
    }

    @objc private func toggleLock(_ b: NSButton) {
        var u = urls[0]
        var v = URLResourceValues(); v.isUserImmutable = b.state == .on
        do { try u.setResourceValues(v) } catch { b.state = b.state == .on ? .off : .on; showError("Couldn't change the attribute.", info: error.localizedDescription, in: window) }
    }
    @objc private func toggleHidden(_ b: NSButton) {
        var u = urls[0]
        var v = URLResourceValues(); v.isHidden = b.state == .on
        do { try u.setResourceValues(v); FileOps.notify([u.deletingLastPathComponent()]) }
        catch { b.state = b.state == .on ? .off : .on; showError("Couldn't change the attribute.", info: error.localizedDescription, in: window) }
    }
    @objc private func closeIt() { window?.close() }
}
