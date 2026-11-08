import AppKit
import BugOSKit

// MARK: - Shared protocol between the details table and the icon grid

protocol FileListDelegate: AnyObject {
    func listSelectionChanged()
    func listOpen(_ item: FileItem)
    func listMenu(for items: [FileItem]) -> NSMenu?
    func listRename(_ item: FileItem, to name: String)
    func listDrop(_ urls: [URL], into dir: URL?, copy: Bool)
    func listBack()
    func listDelete(permanent: Bool)
    func listSortChanged(_ key: SortKey, ascending: Bool)
    func listZoom(_ bigger: Bool)
    func listOpenInNewTab(_ item: FileItem)
    var listCurrentFolder: URL? { get }
}

/// ⌘+scroll steps through the view sizes (Explorer's Ctrl+wheel). Accumulates small trackpad deltas.
final class ZoomScroll {
    private var acc: CGFloat = 0
    func feed(_ e: NSEvent, step: (Bool) -> Void) -> Bool {
        guard e.modifierFlags.contains(.command) else { acc = 0; return false }
        acc += e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 10)
        if abs(acc) >= 30 { step(acc > 0); acc = 0 }
        return true
    }
}

protocol FileListView: NSView {
    var delegate: FileListDelegate? { get set }
    func show(items: [FileItem], groups: [(title: String, items: [FileItem])], state: FolderViewState, searchMode: Bool)
    var selectedItems: [FileItem] { get }
    func select(urls: Set<URL>, scroll: Bool)
    func selectAllItems()
    func selectNone()
    func invertSelection()
    func beginRename(_ url: URL)
    func focus()
    func refreshAppearance()
}

/// Selects the stem of a name ("report" of "report.txt") in the field editor, like Explorer's F2.
func selectStem(in field: NSTextField, name: String, isFolder: Bool) {
    guard let ed = field.currentEditor() else { return }
    let ext = (name as NSString).pathExtension
    let len = (isFolder || ext.isEmpty) ? (name as NSString).length : (name as NSString).length - (ext as NSString).length - 1
    ed.selectedRange = NSRange(location: 0, length: max(0, len))
}

/// Type-to-select: typing letters jumps to the next matching name.
final class TypeSelect {
    private var buffer = ""
    private var last = Date.distantPast
    func feed(_ chars: String, items: [FileItem], from current: Int) -> Int? {
        if Date().timeIntervalSince(last) > 0.9 { buffer = "" }
        last = Date()
        buffer += chars.lowercased()
        let n = items.count
        guard n > 0 else { return nil }
        // Repeating the same letter cycles through matches, like Explorer.
        let cycling = buffer.count > 1 && Set(buffer).count == 1
        let needle = cycling ? String(buffer.first!) : buffer
        let start = cycling || buffer.count == 1 ? current + 1 : max(current, 0)
        for k in 0..<n {
            let i = (start + k) % n
            if items[i].displayName.lowercased().hasPrefix(needle) { return i }
        }
        return nil
    }
}

// MARK: - Details view (table)

final class DetailsView: NSView, FileListView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: FileListDelegate?
    private let table = FileTable()
    private let scroll = NSScrollView()
    private enum Row { case group(String, Int), item(FileItem) }
    private var rows: [Row] = []
    private var items: [FileItem] = []
    private var searchMode = false
    private var renaming: FileItem?
    private let typeSelect = TypeSelect()

    private static let allColumns: [(SortKey, CGFloat)] = [(.name, 300), (.dateModified, 160), (.type, 150), (.size, 90), (.dateCreated, 160), (.folder, 260)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.style = .fullWidth
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Theme.content
        table.gridStyleMask = []
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        table.owner = self
        table.autosaveName = nil

        for (key, width) in DetailsView.allColumns {
            let c = NSTableColumn(identifier: .init(key.rawValue))
            c.title = key.title
            c.width = width
            c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            if key == .size { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        applyColumnVisibility()
        table.headerView?.menu = headerMenu()

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = Theme.content
        addSubview(scroll); scroll.pin(to: self)
        NotificationCenter.default.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func clipboardChanged() { refreshAppearance() }

    // MARK: Columns

    private var visibleColumns: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "detailsColumns") ?? ["name", "dateModified", "type", "size"]) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "detailsColumns") }
    }

    private func applyColumnVisibility() {
        for c in table.tableColumns {
            let id = c.identifier.rawValue
            c.isHidden = id == SortKey.folder.rawValue ? !searchMode : !(visibleColumns.contains(id) || id == "name")
        }
    }

    private func headerMenu() -> NSMenu {
        let m = NSMenu()
        for (key, _) in DetailsView.allColumns where key != .name && key != .folder {
            let it = menuItem(key.title) { [weak self] in
                guard let self else { return }
                var v = self.visibleColumns
                if v.contains(key.rawValue) { v.remove(key.rawValue) } else { v.insert(key.rawValue) }
                self.visibleColumns = v
                self.applyColumnVisibility()
                self.table.headerView?.menu = self.headerMenu()
            }
            it.state = visibleColumns.contains(key.rawValue) ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(menuItem("Size all columns to fit") { [weak self] in self?.sizeToFit() })
        return m
    }

    private func sizeToFit() {
        for c in table.tableColumns where !c.isHidden {
            var w: CGFloat = c.headerCell.cellSize.width + 20
            for r in 0..<min(table.numberOfRows, 500) {
                if let v = table.view(atColumn: table.column(withIdentifier: c.identifier), row: r, makeIfNecessary: true) as? NSTableCellView {
                    w = max(w, (v.textField?.fittingSize.width ?? 0) + (c.identifier.rawValue == "name" ? 40 : 16))
                }
            }
            c.width = min(w, 600)
        }
    }

    // MARK: FileListView

    /// A folder refresh while you're typing a new name would wipe out the rename box (this is what
    /// broke "New folder → rename"), so refreshes wait until the rename is finished.
    private var pendingShow: (() -> Void)?
    private func flushPendingShow() { if let p = pendingShow { pendingShow = nil; p() } }

    func show(items: [FileItem], groups: [(title: String, items: [FileItem])], state: FolderViewState, searchMode: Bool) {
        if renaming != nil {
            pendingShow = { [weak self] in self?.show(items: items, groups: groups, state: state, searchMode: searchMode) }
            return
        }
        let keep = Set(selectedItems.map(\.url))
        self.items = items
        self.searchMode = searchMode
        if groups.isEmpty { rows = items.map { .item($0) } }
        else { rows = groups.flatMap { g in [Row.group(g.title, g.items.count)] + g.items.map { .item($0) } } }
        applyColumnVisibility()
        table.sortDescriptors = [NSSortDescriptor(key: state.sortKey.rawValue, ascending: state.ascending)]
        table.reloadData()
        select(urls: keep, scroll: false)
    }

    var selectedItems: [FileItem] {
        table.selectedRowIndexes.compactMap { i -> FileItem? in
            guard rows.indices.contains(i), case .item(let it) = rows[i] else { return nil }
            return it
        }
    }

    func select(urls: Set<URL>, scroll doScroll: Bool) {
        var set = IndexSet()
        // Compare paths, not URLs: folder URLs may or may not end in "/", and /tmp is really /private/tmp.
        let paths = Set(urls.flatMap { [$0.path, FS.canonical($0)] })
        for (i, r) in rows.enumerated() { if case .item(let it) = r, paths.contains(it.url.path) { set.insert(i) } }
        table.selectRowIndexes(set, byExtendingSelection: false)
        if doScroll, let f = set.first { table.scrollRowToVisible(f) }
    }

    func selectAllItems() { table.selectAll(nil) }
    func selectNone() { table.deselectAll(nil) }
    func invertSelection() {
        var set = IndexSet()
        for (i, r) in rows.enumerated() { if case .item = r, !table.selectedRowIndexes.contains(i) { set.insert(i) } }
        table.selectRowIndexes(set, byExtendingSelection: false)
    }
    func focus() { window?.makeFirstResponder(table) }
    func refreshAppearance() {
        table.enumerateAvailableRowViews { rv, row in
            guard self.rows.indices.contains(row), case .item(let it) = self.rows[row] else { return }
            rv.alphaValue = FileClipboard.shared.isCut(it.url) || it.isHidden ? 0.5 : 1
        }
    }

    func beginRename(_ url: URL) {
        guard let row = rows.firstIndex(where: { if case .item(let it) = $0 { return FS.samePath(it.url, url) }; return false }),
              case .item(let it) = rows[row] else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        let col = table.column(withIdentifier: .init("name"))
        guard let cell = table.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView, let tf = cell.textField else { return }
        renaming = it
        tf.stringValue = it.name
        tf.isEditable = true
        tf.isSelectable = true
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        window?.makeFirstResponder(tf)
        selectStem(in: tf, name: it.name, isFolder: it.isDirectory)
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let tf = n.object as? NSTextField, let it = renaming else { return }
        renaming = nil
        tf.isEditable = false
        tf.drawsBackground = false
        let movement = (n.userInfo?["NSTextMovement"] as? Int) ?? 0
        let newName = tf.stringValue
        tf.stringValue = it.displayName
        if movement != NSTextMovement.cancel.rawValue { delegate?.listRename(it, to: newName) }
        focus()
        flushPendingShow()
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)), let it = renaming {
            (c as? NSTextField)?.stringValue = it.name
            renaming = nil
            (c as? NSTextField)?.isEditable = false
            (c as? NSTextField)?.drawsBackground = false
            (c as? NSTextField)?.stringValue = it.displayName
            focus()
            flushPendingShow()
            return true
        }
        return false
    }

    // MARK: Table data

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return 32 }
        return 24
    }

    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .group = rows[row] { return false }
        return true
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title, let count):
            return GroupHeaderView(title: "\(title) (\(count))")
        case .item(let it):
            guard let col else { return nil }
            let id = col.identifier.rawValue
            let cell = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 12.5)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = tf
            cell.addSubview(tf)
            var lead: CGFloat = 8
            switch SortKey(rawValue: id) ?? .name {
            case .name:
                let iv = NSImageView(image: it.icon(size: 16))
                iv.translatesAutoresizingMaskIntoConstraints = false
                cell.imageView = iv
                cell.addSubview(iv)
                var ivLead: CGFloat = 8
                if Settings.shared.itemCheckBoxes {
                    let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(rowCheckToggled(_:)))
                    cb.translatesAutoresizingMaskIntoConstraints = false
                    cb.identifier = .init("check")
                    cb.state = table.selectedRowIndexes.contains(row) ? .on : .off
                    cell.addSubview(cb)
                    NSLayoutConstraint.activate([cb.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                                                 cb.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                    ivLead = 30
                }
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: ivLead),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                ])
                lead = ivLead + 22
                tf.stringValue = it.displayName
                tf.delegate = self
                tf.toolTip = it.name
            case .dateModified: tf.stringValue = Fmt.date(it.modified); tf.textColor = .secondaryLabelColor
            case .dateCreated: tf.stringValue = Fmt.date(it.created); tf.textColor = .secondaryLabelColor
            case .type: tf.stringValue = it.typeName; tf.textColor = .secondaryLabelColor
            case .size:
                tf.stringValue = it.isDirectory || it.isPackage ? "" : Fmt.kb(it.size)
                tf.alignment = .right
                tf.textColor = .secondaryLabelColor
            case .folder: tf.stringValue = it.folder.path.replacingOccurrences(of: FS.home.path, with: "~"); tf.textColor = .secondaryLabelColor
                tf.lineBreakMode = .byTruncatingMiddle
            }
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: lead),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AccentRowView() }

    func tableView(_ t: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard rows.indices.contains(row), case .item(let it) = rows[row] else { return }
        rowView.alphaValue = FileClipboard.shared.isCut(it.url) || it.isHidden ? 0.5 : 1
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        syncChecks()
        delegate?.listSelectionChanged()
    }

    /// Item check boxes: a click adds/removes just that row, leaving the rest of the selection alone.
    @objc private func rowCheckToggled(_ b: NSButton) {
        let r = table.row(for: b)
        guard r >= 0 else { return }
        if table.selectedRowIndexes.contains(r) { table.deselectRow(r) }
        else { table.selectRowIndexes([r], byExtendingSelection: true) }
        syncChecks()
    }

    private func syncChecks() {
        guard Settings.shared.itemCheckBoxes else { return }
        let col = table.column(withIdentifier: .init("name"))
        guard col >= 0 else { return }
        table.enumerateAvailableRowViews { _, row in
            if let cell = table.view(atColumn: col, row: row, makeIfNecessary: false),
               let cb = cell.subviews.first(where: { $0.identifier?.rawValue == "check" }) as? NSButton {
                cb.state = table.selectedRowIndexes.contains(row) ? .on : .off
            }
        }
    }

    func tableView(_ t: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let d = t.sortDescriptors.first, let key = d.key.flatMap(SortKey.init(rawValue:)) else { return }
        delegate?.listSortChanged(key, ascending: d.ascending)
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard r >= 0, rows.indices.contains(r), case .item(let it) = rows[r] else { return }
        delegate?.listOpen(it)
    }

    // MARK: Drag and drop

    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .item(let it) = rows[row] else { return nil }
        return it.url as NSURL
    }

    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on, rows.indices.contains(row), case .item(let it) = rows[row], it.isDirectory {
            return Drag.operation(info, to: it.url)
        }
        guard let cur = delegate?.listCurrentFolder else { return [] }
        t.setDropRow(-1, dropOperation: .on)          // drop on the whole folder
        // Dropping files back into the folder they came from does nothing.
        if Drag.urls(info).allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == cur.standardizedFileURL }) { return [] }
        return Drag.operation(info, to: cur)
    }

    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let urls = Drag.urls(info)
        guard !urls.isEmpty else { return false }
        var dir: URL? = nil
        if row >= 0, rows.indices.contains(row), case .item(let it) = rows[row], it.isDirectory { dir = it.url }
        let target = dir ?? delegate?.listCurrentFolder
        guard let target else { return false }
        delegate?.listDrop(urls, into: dir, copy: Drag.operation(info, to: target) == .copy)
        return true
    }

    // MARK: Keyboard / menu (called by FileTable)

    fileprivate func middleClick(row: Int) {
        guard rows.indices.contains(row), case .item(let it) = rows[row], it.isDirectory else { return }
        delegate?.listOpenInNewTab(it)
    }

    fileprivate func menu(at row: Int) -> NSMenu? {
        if row >= 0, rows.indices.contains(row), case .item = rows[row] {
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            return delegate?.listMenu(for: selectedItems)
        }
        table.deselectAll(nil)
        return delegate?.listMenu(for: [])
    }

    fileprivate func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch e.keyCode {
        case 36, 76:   // Return / Enter = open (Explorer behaviour)
            if mods.isEmpty, let it = selectedItems.first {
                if selectedItems.count > 1 { selectedItems.forEach { delegate?.listOpen($0) } } else { delegate?.listOpen(it) }
                return true
            }
        case 51:       // Backspace = back
            if mods.isEmpty { delegate?.listBack(); return true }
        case 117:      // Forward delete (fn+⌫) = delete, ⇧ = permanently
            delegate?.listDelete(permanent: mods.contains(.shift)); return true
        case 49:       // Space = Quick Look
            QuickLook.shared.toggle(urls: selectedItems.map(\.url), from: window); return true
        default: break
        }
        if mods.isEmpty || mods == [.shift], let chars = e.characters, chars.count == 1, chars.rangeOfCharacter(from: .alphanumerics.union(.punctuationCharacters)) != nil {
            let flat = rows.compactMap { r -> FileItem? in if case .item(let it) = r { return it }; return nil }
            let cur = selectedItems.first.flatMap { s in flat.firstIndex { $0 == s } } ?? -1
            if let i = typeSelect.feed(chars, items: flat, from: cur) { select(urls: [flat[i].url], scroll: true) }
            return true
        }
        return false
    }
}

final class FileTable: NSTableView {
    weak var owner: DetailsView?
    private let zoom = ZoomScroll()
    override func scrollWheel(with e: NSEvent) {
        if zoom.feed(e, step: { owner?.delegate?.listZoom($0) }) { return }
        super.scrollWheel(with: e)
    }
    override func otherMouseDown(with e: NSEvent) {
        let r = row(at: convert(e.locationInWindow, from: nil))
        if e.buttonNumber == 2, r >= 0 { owner?.middleClick(row: r); return }
        super.otherMouseDown(with: e)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(at: row(at: convert(event.locationInWindow, from: nil)))
    }
    override func keyDown(with e: NSEvent) {
        if owner?.key(e) == true { return }
        super.keyDown(with: e)
    }
    // Clicking empty space clears the selection (Explorer behaviour).
    override func mouseDown(with e: NSEvent) {
        let r = row(at: convert(e.locationInWindow, from: nil))
        if r < 0 { deselectAll(nil) }
        super.mouseDown(with: e)
    }
}

final class GroupHeaderView: NSView {
    init(title: String) {
        super.init(frame: .zero)
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = BugOSColor.accent
        let line = NSBox(); line.boxType = .separator
        for v in [l, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            l.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            line.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: l.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Icon views (extra large / large / medium / small icons, list, tiles, content)

final class IconsView: NSView, FileListView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {
    weak var delegate: FileListDelegate?
    private let collection = FileCollection()
    private let scroll = NSScrollView()
    private let layoutObj = NSCollectionViewFlowLayout()
    private var sections: [(title: String, items: [FileItem])] = []
    private var flat: [FileItem] = []
    private var mode: ViewMode = .large
    private var searchMode = false
    private var renaming: (FileItem, NSTextField)?
    private let typeSelect = TypeSelect()

    init(mode: ViewMode) {
        self.mode = mode
        super.init(frame: .zero)
        collection.collectionViewLayout = layoutObj
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [Theme.content]
        collection.register(FileCell.self, forItemWithIdentifier: FileCell.id)
        collection.register(SectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: SectionHeader.id)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.owner = self
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = Theme.content
        addSubview(scroll); scroll.pin(to: self)
        configureLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func clipboardChanged() { refreshAppearance() }

    override func layout() {
        super.layout()
        if mode == .content { configureLayout() }
    }

    private func configureLayout() {
        let L = layoutObj
        L.scrollDirection = mode == .list ? .horizontal : .vertical
        L.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        L.minimumInteritemSpacing = mode == .list ? 0 : 4
        L.minimumLineSpacing = mode == .list ? 8 : 4
        L.itemSize = FileCell.size(for: mode, width: scroll.contentSize.width - 24)
        L.headerReferenceSize = sections.count > 1 || !(sections.first?.title.isEmpty ?? true) ? NSSize(width: 100, height: 34) : .zero
        L.invalidateLayout()
    }

    // MARK: FileListView

    /// A folder refresh while you're typing a new name would wipe out the rename box (this is what
    /// broke "New folder → rename"), so refreshes wait until the rename is finished.
    private var pendingShow: (() -> Void)?
    private func flushPendingShow() { if let p = pendingShow { pendingShow = nil; p() } }

    func show(items: [FileItem], groups: [(title: String, items: [FileItem])], state: FolderViewState, searchMode: Bool) {
        if renaming != nil {
            pendingShow = { [weak self] in self?.show(items: items, groups: groups, state: state, searchMode: searchMode) }
            return
        }
        let keep = Set(selectedItems.map(\.url))
        self.searchMode = searchMode
        sections = groups.isEmpty ? [("", items)] : groups
        flat = sections.flatMap(\.items)
        configureLayout()
        collection.reloadData()
        select(urls: keep, scroll: false)
    }

    private func indexPath(of url: URL) -> IndexPath? {
        for (s, sec) in sections.enumerated() {
            if let i = sec.items.firstIndex(where: { FS.samePath($0.url, url) }) { return IndexPath(item: i, section: s) }
        }
        return nil
    }
    private func item(at ip: IndexPath) -> FileItem? {
        guard sections.indices.contains(ip.section), sections[ip.section].items.indices.contains(ip.item) else { return nil }
        return sections[ip.section].items[ip.item]
    }

    var selectedItems: [FileItem] {
        collection.selectionIndexPaths.sorted().compactMap(item(at:))
    }

    func select(urls: Set<URL>, scroll doScroll: Bool) {
        let paths = Set(urls.flatMap { [$0.path, FS.canonical($0)] })
        var ips = Set<IndexPath>()
        for (s, sec) in sections.enumerated() {
            for (i, it) in sec.items.enumerated() where paths.contains(it.url.path) { ips.insert(IndexPath(item: i, section: s)) }
        }
        collection.selectionIndexPaths = ips
        if doScroll, let f = ips.sorted().first { collection.scrollToItems(at: [f], scrollPosition: .nearestHorizontalEdge.union(.nearestVerticalEdge)) }
        delegate?.listSelectionChanged()
    }
    func selectAllItems() { collection.selectAll(nil); delegate?.listSelectionChanged() }
    func selectNone() { collection.deselectAll(nil); delegate?.listSelectionChanged() }
    func invertSelection() {
        let cur = collection.selectionIndexPaths
        var all = Set<IndexPath>()
        for (s, sec) in sections.enumerated() { for i in sec.items.indices { all.insert(IndexPath(item: i, section: s)) } }
        collection.selectionIndexPaths = all.subtracting(cur)
        delegate?.listSelectionChanged()
    }
    func focus() { window?.makeFirstResponder(collection) }
    func refreshAppearance() {
        for case let c as FileCell in collection.visibleItems() { c.updateAlpha() }
    }

    func beginRename(_ url: URL) {
        guard let ip = indexPath(of: url), let it = item(at: ip) else { return }
        collection.selectionIndexPaths = [ip]
        collection.scrollToItems(at: [ip], scrollPosition: .nearestVerticalEdge)
        collection.layoutSubtreeIfNeeded()
        guard let cell = collection.item(at: ip) as? FileCell else { return }
        let tf = cell.nameField
        renaming = (it, tf)
        tf.stringValue = it.name
        tf.isEditable = true
        tf.isSelectable = true
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.delegate = self
        window?.makeFirstResponder(tf)
        selectStem(in: tf, name: it.name, isFolder: it.isDirectory)
    }

    private func endRename(commit: Bool, text: String) {
        guard let (it, tf) = renaming else { return }
        renaming = nil
        tf.isEditable = false
        tf.drawsBackground = false
        tf.stringValue = it.displayName
        if commit { delegate?.listRename(it, to: text) }
        focus()
        flushPendingShow()
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let tf = n.object as? NSTextField, renaming?.1 === tf else { return }
        let movement = (n.userInfo?["NSTextMovement"] as? Int) ?? 0
        endRename(commit: movement != NSTextMovement.cancel.rawValue, text: tf.stringValue)
    }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)) { endRename(commit: false, text: ""); return true }
        return false
    }

    // MARK: Data

    func numberOfSections(in cv: NSCollectionView) -> Int { sections.count }
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection s: Int) -> Int { sections[s].items.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let c = cv.makeItem(withIdentifier: FileCell.id, for: ip) as! FileCell
        if let it = item(at: ip) { c.configure(it, mode: mode, searchMode: searchMode) }
        return c
    }

    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at ip: IndexPath) -> NSView {
        let h = cv.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeader.id, for: ip) as! SectionHeader
        h.label.stringValue = "\(sections[ip.section].title) (\(sections[ip.section].items.count))"
        return h
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) { delegate?.listSelectionChanged() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) { delegate?.listSelectionChanged() }

    // MARK: Drag and drop

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        item(at: ip)?.url as NSURL?
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath ipPtr: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation opPtr: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let ip = ipPtr.pointee as IndexPath
        if opPtr.pointee == .on, let it = item(at: ip), it.isDirectory { return Drag.operation(info, to: it.url) }
        guard let cur = delegate?.listCurrentFolder else { return [] }
        if Drag.urls(info).allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == cur.standardizedFileURL }) { return [] }
        opPtr.pointee = .before
        return Drag.operation(info, to: cur)
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath, dropOperation op: NSCollectionView.DropOperation) -> Bool {
        let urls = Drag.urls(info)
        guard !urls.isEmpty else { return false }
        var dir: URL? = nil
        if op == .on, let it = item(at: ip), it.isDirectory { dir = it.url }
        guard let target = dir ?? delegate?.listCurrentFolder else { return false }
        delegate?.listDrop(urls, into: dir, copy: Drag.operation(info, to: target) == .copy)
        return true
    }

    // MARK: Called by FileCollection

    fileprivate func checkChanged() { delegate?.listSelectionChanged() }

    fileprivate func middleClick(at p: NSPoint) {
        guard let ip = collection.indexPathForItem(at: p), let it = item(at: ip), it.isDirectory else { return }
        delegate?.listOpenInNewTab(it)
    }

    fileprivate func doubleClick(at p: NSPoint) {
        guard let ip = collection.indexPathForItem(at: p), let it = item(at: ip) else { return }
        delegate?.listOpen(it)
    }

    fileprivate func menu(at p: NSPoint) -> NSMenu? {
        if let ip = collection.indexPathForItem(at: p), item(at: ip) != nil {
            if !collection.selectionIndexPaths.contains(ip) { collection.selectionIndexPaths = [ip]; delegate?.listSelectionChanged() }
            return delegate?.listMenu(for: selectedItems)
        }
        collection.deselectAll(nil)
        delegate?.listSelectionChanged()
        return delegate?.listMenu(for: [])
    }

    fileprivate func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch e.keyCode {
        case 36, 76:
            if mods.isEmpty, !selectedItems.isEmpty { selectedItems.forEach { delegate?.listOpen($0) }; return true }
        case 51:
            if mods.isEmpty { delegate?.listBack(); return true }
        case 117:
            delegate?.listDelete(permanent: mods.contains(.shift)); return true
        case 49:
            QuickLook.shared.toggle(urls: selectedItems.map(\.url), from: window); return true
        case 123, 124, 125, 126:
            if collection.selectionIndexPaths.isEmpty, !flat.isEmpty {
                select(urls: [flat[0].url], scroll: true); return true
            }
        default: break
        }
        if mods.isEmpty || mods == [.shift], let chars = e.characters, chars.count == 1, chars.rangeOfCharacter(from: .alphanumerics.union(.punctuationCharacters)) != nil {
            let cur = selectedItems.first.flatMap { s in flat.firstIndex { $0 == s } } ?? -1
            if let i = typeSelect.feed(chars, items: flat, from: cur) { select(urls: [flat[i].url], scroll: true) }
            return true
        }
        return false
    }
}

final class FileCollection: NSCollectionView {
    weak var owner: IconsView?
    private let zoom = ZoomScroll()
    override func scrollWheel(with e: NSEvent) {
        if zoom.feed(e, step: { owner?.delegate?.listZoom($0) }) { return }
        super.scrollWheel(with: e)
    }
    override func otherMouseDown(with e: NSEvent) {
        if e.buttonNumber == 2 { owner?.middleClick(at: convert(e.locationInWindow, from: nil)); return }
        super.otherMouseDown(with: e)
    }
    override func mouseDown(with e: NSEvent) {
        super.mouseDown(with: e)
        if e.clickCount == 2 { owner?.doubleClick(at: convert(e.locationInWindow, from: nil)) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(at: convert(event.locationInWindow, from: nil)) }
    override func keyDown(with e: NSEvent) {
        if owner?.key(e) == true { return }
        super.keyDown(with: e)
    }
}

final class SectionHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("SectionHeader")
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = BugOSColor.accent
        let line = NSBox(); line.boxType = .separator
        for v in [label, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One item in the icon views. Lays itself out for each view mode.
final class FileCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("FileCell")
    let iconView = NSImageView()
    let nameField = NSTextField(wrappingLabelWithString: "")
    let line2 = NSTextField(labelWithString: "")
    let line3 = NSTextField(labelWithString: "")
    let right1 = NSTextField(labelWithString: "")
    let right2 = NSTextField(labelWithString: "")
    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var hovering = false { didSet { updateCheck() } }
    private(set) var file: FileItem?
    private var mode: ViewMode = .large

    static func size(for mode: ViewMode, width: CGFloat) -> NSSize {
        switch mode {
        case .extraLarge: return NSSize(width: 200, height: 232)
        case .large: return NSSize(width: 118, height: 146)
        case .medium: return NSSize(width: 92, height: 98)
        case .small: return NSSize(width: 230, height: 24)
        case .list: return NSSize(width: 250, height: 22)
        case .tiles: return NSSize(width: 270, height: 66)
        case .content: return NSSize(width: max(300, width), height: 56)
        case .details: return NSSize(width: 100, height: 24)
        }
    }

    override func loadView() {
        let v = CellBackground()
        v.cell = self
        view = v
        for f in [nameField, line2, line3, right1, right2] {
            f.font = .systemFont(ofSize: 12.5)
            f.isEditable = false
            f.isSelectable = false
            f.drawsBackground = false
            f.isBordered = false
        }
        for f in [line2, line3, right1, right2] { f.textColor = .secondaryLabelColor; f.font = .systemFont(ofSize: 11.5); f.lineBreakMode = .byTruncatingTail }
        right1.alignment = .right; right2.alignment = .right
        iconView.imageScaling = .scaleProportionallyUpOrDown
        [iconView, nameField, line2, line3, right1, right2, check].forEach(v.addSubview)
        check.target = self
        check.action = #selector(checkToggled)
        check.isHidden = true
    }

    override var isSelected: Bool { didSet { view.needsDisplay = true; updateCheck() } }

    func updateCheck() {
        let on = Settings.shared.itemCheckBoxes
        check.isHidden = !on || !(isSelected || hovering)
        check.state = isSelected ? .on : .off
    }

    @objc private func checkToggled() {
        guard let cv = collectionView as? FileCollection, let ip = cv.indexPath(for: self) else { return }
        if isSelected { cv.deselectItems(at: [ip]) } else { cv.selectItems(at: [ip], scrollPosition: []) }
        cv.owner?.checkChanged()
    }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { view.needsDisplay = true } }

    func configure(_ it: FileItem, mode: ViewMode, searchMode: Bool) {
        file = it
        self.mode = mode
        let s = mode.iconSize
        iconView.image = Thumbs.cached(it.url, size: s) ?? it.icon(size: s)
        if s >= 32, Thumbs.wants(it), Thumbs.cached(it.url, size: s) == nil {
            let url = it.url
            Thumbs.request(url, size: s) { [weak self] img in
                if self?.file?.url == url { self?.iconView.image = img }
            }
        }
        nameField.stringValue = it.displayName
        nameField.toolTip = it.name
        let vertical = [.extraLarge, .large, .medium].contains(mode)
        nameField.alignment = vertical ? .center : .left
        nameField.maximumNumberOfLines = vertical ? 2 : 1
        nameField.lineBreakMode = vertical ? .byWordWrapping : .byTruncatingTail
        nameField.cell?.truncatesLastVisibleLine = true
        line2.stringValue = ""; line3.stringValue = ""; right1.stringValue = ""; right2.stringValue = ""
        switch mode {
        case .tiles:
            line2.stringValue = it.typeName
            line3.stringValue = it.isDirectory ? "" : Fmt.size(it.size)
        case .content:
            line2.stringValue = searchMode ? it.folder.path.replacingOccurrences(of: FS.home.path, with: "~") : (it.isDirectory ? "" : it.typeName)
            right1.stringValue = it.modified.map { "Date modified: " + Fmt.date($0) } ?? ""
            right2.stringValue = it.isDirectory ? "" : "Size: " + Fmt.size(it.size)
        default: break
        }
        updateAlpha()
        updateCheck()
        view.needsLayout = true
        view.needsDisplay = true
    }

    func updateAlpha() {
        guard let it = file else { return }
        iconView.alphaValue = FileClipboard.shared.isCut(it.url) || it.isHidden ? 0.45 : 1
    }

    func layoutCell(in b: NSRect) {
        let s = mode.iconSize
        let vertical = [.extraLarge, .large, .medium].contains(mode)
        check.frame = vertical ? NSRect(x: 4, y: b.height - 22, width: 18, height: 18) : NSRect(x: 2, y: (b.height - 18) / 2, width: 18, height: 18)
        switch mode {
        case .extraLarge, .large, .medium:
            iconView.frame = NSRect(x: (b.width - s) / 2, y: b.height - s - 6, width: s, height: s)
            nameField.frame = NSRect(x: 4, y: 2, width: b.width - 8, height: b.height - s - 10)
            nameField.isHidden = false
            let fit = nameField.sizeThatFits(NSSize(width: b.width - 8, height: 40))
            nameField.frame = NSRect(x: 4, y: b.height - s - 10 - min(fit.height, 34), width: b.width - 8, height: min(fit.height, 34))
        case .small, .list:
            let ox: CGFloat = Settings.shared.itemCheckBoxes ? 20 : 0
            iconView.frame = NSRect(x: 4 + ox, y: (b.height - 16) / 2, width: 16, height: 16)
            nameField.frame = NSRect(x: 26 + ox, y: (b.height - 17) / 2, width: b.width - 30 - ox, height: 17)
        case .tiles:
            iconView.frame = NSRect(x: 6, y: (b.height - 48) / 2, width: 48, height: 48)
            nameField.frame = NSRect(x: 62, y: b.height - 24, width: b.width - 68, height: 17)
            line2.frame = NSRect(x: 62, y: b.height - 41, width: b.width - 68, height: 15)
            line3.frame = NSRect(x: 62, y: b.height - 57, width: b.width - 68, height: 15)
        case .content:
            iconView.frame = NSRect(x: 8, y: (b.height - 32) / 2, width: 32, height: 32)
            let rightW: CGFloat = min(260, b.width * 0.35)
            nameField.frame = NSRect(x: 50, y: b.height - 26, width: b.width - 60 - rightW, height: 17)
            line2.frame = NSRect(x: 50, y: 8, width: b.width - 60 - rightW, height: 15)
            right1.frame = NSRect(x: b.width - rightW - 10, y: b.height - 26, width: rightW, height: 15)
            right2.frame = NSRect(x: b.width - rightW - 10, y: 8, width: rightW, height: 15)
        case .details: break
        }
    }
}

final class CellBackground: NSView {
    weak var cell: FileCell?
    private var hovering = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); cell?.layoutCell(in: bounds) }
    override func draw(_ dirty: NSRect) {
        guard let cell else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        if cell.isSelected || cell.highlightState == .forSelection {
            let active = window?.isKeyWindow == true && (window?.firstResponder as? NSView).map { $0.isDescendant(of: superview ?? self) } ?? false
            BugOSColor.accent.withAlphaComponent(active ? 0.28 : 0.16).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            BugOSColor.accent.withAlphaComponent(0.6).setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5); p.lineWidth = 1; p.stroke()
        } else if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; cell?.hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false; cell?.hovering = false }
}

/// Selected rows in the BugOS accent colour (BugOS › General › Accent colour).
final class AccentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let a = BugOSColor.accent
        (isEmphasized ? a.withAlphaComponent(0.30) : a.withAlphaComponent(0.16)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }   // keep text colours readable
}
