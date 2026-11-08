import AppKit
import BugOSKit

// MARK: - Hover button (flat, Windows 11 command-bar style)

final class BarButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    var menuProvider: (() -> NSMenu?)?
    var isToggled = false { didSet { needsDisplay = true } }

    convenience init(symbolName: String, title: String = "", tip: String, dropdown: Bool = false,
                     target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        image = symbol(symbolName, size: 14)
        self.title = title
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 12.5)
        toolTip = tip
        self.target = target
        self.action = action
        contentTintColor = .labelColor
        if dropdown, !title.isEmpty { self.title = title + "  ▾" }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        if title.isEmpty { widthAnchor.constraint(equalToConstant: 34).isActive = true }
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        if !title.isEmpty { s.width += 18 }
        return s
    }

    override func draw(_ dirty: NSRect) {
        if (hovering && isEnabled) || isToggled || (isHighlighted && isEnabled) {
            (isToggled ? BugOSColor.accent.withAlphaComponent(0.18) : Theme.hover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirty)
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    override func mouseDown(with e: NSEvent) {
        if let menu = menuProvider?() {
            hovering = true
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
            hovering = false
            return
        }
        super.mouseDown(with: e)
    }
    override var isFlipped: Bool { true }
}

func separatorView(vertical: Bool = true) -> NSView {
    let v = NSBox()
    v.boxType = .separator
    v.translatesAutoresizingMaskIntoConstraints = false
    if vertical { v.heightAnchor.constraint(equalToConstant: 20).isActive = true; v.widthAnchor.constraint(equalToConstant: 1).isActive = true }
    return v
}

// MARK: - Address bar: breadcrumbs that turn into a plain, copyable path on click

final class AddressBar: NSView, NSTextFieldDelegate {
    var location: Location = .home { didSet { if !editing { rebuild() } } }
    var onNavigate: ((Location) -> Void)?
    var onTyped: ((String) -> Void)?
    var recent: () -> [Location] = { [] }

    private let crumbs = NSStackView()
    private let field = AddressField()
    private let iconView = NSImageView()
    private let historyButton = NSButton()
    private(set) var editing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        iconView.imageScaling = .scaleProportionallyUpOrDown
        crumbs.orientation = .horizontal
        crumbs.spacing = 0
        crumbs.alignment = .centerY
        crumbs.setHuggingPriority(.defaultLow, for: .horizontal)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.isHidden = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.onCancel = { [weak self] in self?.endEditing() }

        historyButton.image = symbol("chevron.down", size: 10, weight: .semibold)
        historyButton.isBordered = false
        historyButton.toolTip = "Previous locations"
        historyButton.target = self
        historyButton.action = #selector(showHistory)
        historyButton.contentTintColor = .secondaryLabelColor

        for v in [iconView, crumbs, field, historyButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16), iconView.heightAnchor.constraint(equalToConstant: 16),
            crumbs.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: historyButton.leadingAnchor, constant: -4),
            field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: historyButton.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            historyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            historyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            historyButton.widthAnchor.constraint(equalToConstant: 20),
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = Theme.field.cgColor
        layer?.borderColor = (editing ? BugOSColor.accent : Theme.fieldBorder).cgColor
        layer?.borderWidth = editing ? 2 : 1
    }

    override func layout() { super.layout(); fitCrumbs() }

    // MARK: Breadcrumbs

    private struct Segment { let title: String; let loc: Location; let url: URL? }

    private func segments() -> [Segment] {
        switch location {
        case .home: return [Segment(title: "Home", loc: .home, url: nil)]
        case .thisMac: return [Segment(title: "This Mac", loc: .thisMac, url: nil)]
        case .search(let u, let q):
            return folderSegments(u) + [Segment(title: "Search Results for “\(q)”", loc: location, url: nil)]
        case .folder(let u): return folderSegments(u)
        }
    }

    /// Folders that start a short breadcrumb trail, like Explorer's "Desktop › Projects".
    /// The full path is still what you get when you click into the bar.
    private static var trailRoots: [URL] {
        let h = FS.home
        var r = ["Desktop", "Downloads", "Documents", "Pictures", "Music", "Movies"].map { h.appendingPathComponent($0) }
        if let ic = Places.iCloud { r.insert(ic, at: 0) }
        r.append(h)                                  // anything else in your home folder starts at your user folder
        return r
    }

    private func folderSegments(_ url: URL) -> [Segment] {
        let u = url.standardizedFileURL
        let root = AddressBar.trailRoots.first { u.path == $0.path || u.path.hasPrefix($0.path + "/") }
        var chain: [URL] = []
        var cur = u
        while true {
            chain.insert(cur, at: 0)
            if let root, cur.path == root.path { break }
            if cur.path == "/" { break }
            if root == nil, (try? cur.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false { break }
            cur = cur.deletingLastPathComponent()
        }
        return chain.map { Segment(title: FS.displayName($0), loc: .folder($0), url: $0) }
    }

    private var allCrumbViews: [NSView] = []

    private func rebuild() {
        iconView.image = location.icon
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        allCrumbViews = []
        let segs = segments()
        let overflow = CrumbButton(title: "«", target: self, action: #selector(showOverflow(_:)))
        overflow.isHidden = true
        overflow.toolTip = "Show more locations"
        crumbs.addArrangedSubview(overflow)
        for (i, s) in segs.enumerated() {
            let b = CrumbButton(title: s.title, target: self, action: #selector(crumbTapped(_:)))
            b.tag = i
            b.toolTip = s.url?.path ?? s.title
            crumbs.addArrangedSubview(b)
            allCrumbViews.append(b)
            // The › after a segment lists that folder's subfolders.
            if s.url != nil || s.loc == .thisMac {
                let chev = CrumbButton(title: "", target: self, action: #selector(chevronTapped(_:)))
                chev.image = symbol("chevron.right", size: 9, weight: .semibold)
                chev.tag = i
                crumbs.addArrangedSubview(chev)
                allCrumbViews.append(chev)
            }
        }
        if let lastChev = crumbs.arrangedSubviews.last as? CrumbButton, lastChev.title.isEmpty, case .search = location {
            lastChev.isHidden = true
        }
        needsLayout = true
        needsDisplay = true
    }

    /// Hide leading segments (into «) until the trail fits, like Explorer.
    private func fitCrumbs() {
        guard !allCrumbViews.isEmpty else { return }
        let avail = bounds.width - 9 - 16 - 4 - 30 - 90   // keep ~90pt free to click into text mode
        allCrumbViews.forEach { $0.isHidden = false }
        let overflow = crumbs.arrangedSubviews.first
        overflow?.isHidden = true
        func width() -> CGFloat { crumbs.arrangedSubviews.filter { !$0.isHidden }.reduce(0) { $0 + $1.fittingSize.width } }
        var i = 0
        while width() > avail && i < allCrumbViews.count - 2 {
            allCrumbViews[i].isHidden = true
            overflow?.isHidden = false
            i += 1
        }
        window?.invalidateCursorRects(for: self)
    }

    @objc private func crumbTapped(_ b: NSButton) {
        let segs = segments()
        guard segs.indices.contains(b.tag) else { return }
        // The current folder's own name does nothing useful as a link, so it opens the text path instead.
        if b.tag == segs.count - 1 { DispatchQueue.main.async { [weak self] in self?.beginEditing() }; return }
        onNavigate?(segs[b.tag].loc)
    }

    @objc private func chevronTapped(_ b: NSButton) {
        let segs = segments()
        guard segs.indices.contains(b.tag) else { return }
        let menu = NSMenu()
        if let dir = segs[b.tag].url {
            let subs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey], options: [.skipsHiddenFiles])) ?? [])
                .filter(FS.isDirectory).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let next = segs.indices.contains(b.tag + 1) ? segs[b.tag + 1].url : nil
            for s in subs.prefix(400) {
                let it = menuItem(FS.displayName(s)) { [weak self] in self?.onNavigate?(.folder(s)) }
                it.image = Icons.icon(for: s, size: 16)
                if s.standardizedFileURL == next?.standardizedFileURL { it.state = .on; it.title = FS.displayName(s) }
                menu.addItem(it)
            }
            if subs.isEmpty { let e = NSMenuItem(title: "No subfolders", action: nil, keyEquivalent: ""); e.isEnabled = false; menu.addItem(e) }
        } else {
            for v in Places.volumes() {
                let it = menuItem(FS.volumeName(v)) { [weak self] in self?.onNavigate?(.folder(v)) }
                it.image = Icons.icon(for: v, size: 16)
                menu.addItem(it)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 2), in: b)
    }

    @objc private func showOverflow(_ b: NSButton) {
        let segs = segments()
        let menu = NSMenu()
        for (i, s) in segs.enumerated().reversed() where i < segs.count - 1 {
            let it = menuItem(s.title) { [weak self] in self?.onNavigate?(s.loc) }
            it.image = s.url.map { Icons.icon(for: $0, size: 16) } ?? symbol("laptopcomputer", size: 13)
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 2), in: b)
    }

    @objc private func showHistory() {
        let menu = NSMenu()
        for loc in recent().prefix(20) {
            let it = menuItem(loc.editText) { [weak self] in self?.onNavigate?(loc) }
            it.image = loc.icon
            menu.addItem(it)
        }
        if menu.items.isEmpty { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: historyButton.bounds.height + 4), in: historyButton)
    }

    // MARK: Editing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !editing, frame.contains(point) else { return super.hitTest(point) }
        let v = super.hitTest(point)
        if v is CrumbButton || v === historyButton { return v }
        return self
    }

    override func resetCursorRects() {
        // I-beam over the free space after the breadcrumbs, like a text box.
        guard !editing else { return }
        let used = crumbs.frame.maxX
        addCursorRect(NSRect(x: used, y: 0, width: max(0, historyButton.frame.minX - used), height: bounds.height), cursor: .iBeam)
        addCursorRect(iconView.frame.insetBy(dx: -4, dy: -6), cursor: .iBeam)
    }

    // Switch to text only once the click has finished; doing it mid-click lets the
    // rest of the click pull focus straight back out of the text box.
    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) { DispatchQueue.main.async { [weak self] in self?.beginEditing() } }

    func beginEditing() {
        guard !editing else { field.currentEditor()?.selectAll(nil); return }
        editing = true
        crumbs.isHidden = true
        field.isHidden = false
        field.stringValue = location.editText
        // makeFirstResponder selects the whole path already. (selectText would end the edit it just began.)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    func endEditing() {
        guard editing else { return }
        suggestions.hide()
        editing = false
        field.isHidden = true
        crumbs.isHidden = false
        rebuild()
        if window?.firstResponder == field.currentEditor() { window?.makeFirstResponder(nil) }
    }

    func controlTextDidEndEditing(_ n: Notification) {
        let movement = (n.userInfo?["NSTextMovement"] as? Int) ?? 0
        let text = field.stringValue
        endEditing()
        if movement == NSTextMovement.return.rawValue { onTyped?(text) }
    }

    // MARK: Suggestions (folders matching what you've typed) and Tab completion

    private let suggestions = SuggestionList()

    func controlTextDidChange(_ n: Notification) { updateSuggestions() }

    /// Folders in the typed path's parent whose names start with the last part typed.
    private func matches(for text: String) -> [URL] {
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return [] }
        let dirPath: String, prefix: String
        if expanded.hasSuffix("/") { dirPath = expanded; prefix = "" }
        else { dirPath = (expanded as NSString).deletingLastPathComponent; prefix = (expanded as NSString).lastPathComponent }
        let dir = URL(fileURLWithPath: dirPath)
        let opts: FileManager.DirectoryEnumerationOptions = prefix.hasPrefix(".") || Settings.shared.showHidden ? [] : [.skipsHiddenFiles]
        let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: opts)) ?? []
        return kids.filter { $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) && FS.isDirectory($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(12).map { $0 }
    }

    private func updateSuggestions() {
        let list = matches(for: field.stringValue)
        guard editing, !list.isEmpty, let win = window else { suggestions.hide(); return }
        let typedTilde = field.stringValue.hasPrefix("~")
        suggestions.show(list, typedTilde: typedTilde, below: self, in: win) { [weak self] url in
            self?.accept(url, typedTilde: typedTilde)
        }
    }

    private func accept(_ url: URL, typedTilde: Bool) {
        var path = url.path + "/"
        if typedTilde, path.hasPrefix(FS.home.path) { path = "~" + path.dropFirst(FS.home.path.count) }
        field.stringValue = path
        field.currentEditor()?.selectedRange = NSRange(location: (path as NSString).length, length: 0)
        updateSuggestions()
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)) where suggestions.isVisible: suggestions.move(1); return true
        case #selector(NSResponder.moveUp(_:)) where suggestions.isVisible: suggestions.move(-1); return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab: take the highlighted suggestion, or complete as far as all matches agree.
            if let u = suggestions.highlighted { accept(u, typedTilde: field.stringValue.hasPrefix("~")); return true }
            let list = matches(for: field.stringValue)
            if list.count == 1 { accept(list[0], typedTilde: field.stringValue.hasPrefix("~")); return true }
            if list.count > 1 {
                let names = list.map(\.lastPathComponent)
                var common = names[0]
                for n in names.dropFirst() { while !n.lowercased().hasPrefix(common.lowercased()) { common.removeLast() } }
                let expanded = (field.stringValue as NSString).expandingTildeInPath
                let parent = expanded.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent + "/"
                var path = parent + common
                if field.stringValue.hasPrefix("~"), path.hasPrefix(FS.home.path) { path = "~" + path.dropFirst(FS.home.path.count) }
                field.stringValue = path
                updateSuggestions()
            }
            return true
        case #selector(NSResponder.insertNewline(_:)) where suggestions.highlighted != nil:
            if let u = suggestions.highlighted { field.stringValue = u.path }
            return false      // let Return go through and navigate
        case #selector(NSResponder.cancelOperation(_:)) where suggestions.isVisible:
            suggestions.hide(); return true
        default: return false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(menuItem("Copy address", "doc.on.doc") { [weak self] in
            guard let self, let u = self.location.url else { return }
            FileClipboard.shared.copy([u])
        })
        m.addItem(menuItem("Copy address as text", "text.cursor") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.location.editText, forType: .string)
        })
        m.addItem(menuItem("Edit address", "pencil") { [weak self] in self?.beginEditing() })
        return m
    }
}

/// Text field that reports Escape.
final class AddressField: NSTextField {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class CrumbButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = .systemFont(ofSize: 13)
        lineBreakMode = .byTruncatingTail
        contentTintColor = .secondaryLabelColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += title.isEmpty ? 6 : 10
        s.height = 24
        return s
    }
    override func draw(_ dirty: NSRect) {
        if hovering { Theme.hover.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill() }
        super.draw(dirty)
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
}

// MARK: - Search box

final class SearchBox: NSSearchField, NSSearchFieldDelegate {
    var onFilter: ((String) -> Void)?
    var onSearch: ((String) -> Void)?
    private var debounce: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        sendsSearchStringImmediately = false
        sendsWholeSearchString = true
        font = .systemFont(ofSize: 13)
        focusRingType = .none
        target = self
        action = #selector(submit)
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ n: Notification) {
        debounce?.cancel()
        let text = stringValue
        let w = DispatchWorkItem { [weak self] in self?.onFilter?(text) }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    @objc private func submit() {
        let q = stringValue.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { onFilter?("") } else { onSearch?(q) }
    }
}

// MARK: - Status bar

final class StatusBar: NSView {
    let label = NSTextField(labelWithString: "")
    let detailsButton: BarButton
    let iconsButton: BarButton
    var onMode: ((ViewMode) -> Void)?

    override init(frame: NSRect) {
        detailsButton = BarButton(symbolName: "list.bullet", tip: "Display information about each item in the window.", target: nil, action: nil)
        iconsButton = BarButton(symbolName: "square.grid.2x2", tip: "Display items by using large thumbnails.", target: nil, action: nil)
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        detailsButton.target = self; detailsButton.action = #selector(details)
        iconsButton.target = self; iconsButton.action = #selector(icons)
        for v in [label, detailsButton, iconsButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for b in [detailsButton, iconsButton] {
            b.constraints.filter { $0.firstAttribute == .height }.forEach { $0.constant = 22 }
            b.constraints.filter { $0.firstAttribute == .width }.forEach { $0.constant = 26 }
            b.image = symbol(b === detailsButton ? "list.bullet" : "square.grid.2x2", size: 12)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detailsButton.leadingAnchor, constant: -8),
            iconsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            iconsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: iconsButton.leadingAnchor, constant: -2),
            detailsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(mode: ViewMode?) {
        detailsButton.isToggled = mode == .details
        iconsButton.isToggled = mode == .large
        detailsButton.isHidden = mode == nil
        iconsButton.isHidden = mode == nil
    }

    @objc private func details() { onMode?(.details) }
    @objc private func icons() { onMode?(.large) }
}


// MARK: - Suggestion dropdown under the address bar

final class SuggestionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private let table = NSTableView()
    private var items: [URL] = []
    private var typedTilde = false
    private var onPick: ((URL) -> Void)?
    var isVisible: Bool { panel?.isVisible ?? false }
    var highlighted: URL? { isVisible && table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow] : nil }

    func show(_ urls: [URL], typedTilde: Bool, below anchor: NSView, in win: NSWindow, pick: @escaping (URL) -> Void) {
        items = urls; self.typedTilde = typedTilde; onPick = pick
        let p = panel ?? makePanel()
        table.reloadData()
        table.deselectAll(nil)
        let r = anchor.window!.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let h = CGFloat(min(urls.count, 12)) * 26 + 8
        p.setFrame(NSRect(x: r.minX, y: r.minY - h - 4, width: r.width, height: h), display: true)
        if p.parent == nil { win.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    func hide() {
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    func move(_ d: Int) {
        let n = items.count
        guard n > 0 else { return }
        let r = table.selectedRow < 0 ? (d > 0 ? 0 : n - 1) : (table.selectedRow + d + n) % n
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        let fx = NSVisualEffectView()
        fx.material = .menu
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 8
        fx.layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 26
        table.style = .plain
        table.intercellSpacing = .zero
        table.addTableColumn(NSTableColumn(identifier: .init("s")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        fx.addSubview(scroll); scroll.pin(to: fx, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        p.contentView = fx
        panel = p
        return p
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0, r < items.count else { return }
        onPick?(items[r])
    }

    func numberOfRows(in t: NSTableView) -> Int { items.count }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let u = items[row]
        let cell = NSTableCellView()
        let iv = NSImageView(image: Icons.icon(for: u, size: 16))
        var shown = u.path
        if typedTilde, shown.hasPrefix(FS.home.path) { shown = "~" + shown.dropFirst(FS.home.path.count) }
        let tf = NSTextField(labelWithString: shown)
        tf.lineBreakMode = .byTruncatingHead
        tf.font = .systemFont(ofSize: 13)
        for v in [iv, tf] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
