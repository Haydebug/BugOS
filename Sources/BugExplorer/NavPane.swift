import AppKit
import BugOSKit

enum Places {
    /// Mounted volumes the user cares about (startup disk first), no system snapshots.
    static func volumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey, .volumeIsRootFileSystemKey, .volumeLocalizedNameKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let filtered = vols.filter { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.volumeIsRootFileSystem == true { return true }
            return (v?.volumeIsBrowsable ?? true) && u.path.hasPrefix("/Volumes/")
        }
        return filtered.sorted { a, b in
            if a.path == "/" { return true }
            if b.path == "/" { return false }
            return FS.volumeName(a).localizedStandardCompare(FS.volumeName(b)) == .orderedAscending
        }
    }
    static var localVolumes: [URL] { volumes().filter { !FS.isNetwork($0) } }
    static var networkVolumes: [URL] { volumes().filter { FS.isNetwork($0) } }

    static var iCloud: URL? {
        let u = FS.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FS.exists(u) ? u : nil
    }
}

/// A row in the navigation pane.
final class NavNode {
    enum Kind { case home, thisMac, network, pinned, folder, volume, separator, iCloud, recycleBin, applications }
    let kind: Kind
    let url: URL?
    let title: String
    var children: [NavNode]?          // nil = not loaded yet
    let expandable: Bool

    init(_ kind: Kind, url: URL? = nil, title: String, expandable: Bool = false) {
        self.kind = kind; self.url = url; self.title = title; self.expandable = expandable
    }

    var location: Location? {
        switch kind {
        case .home: return .home
        case .thisMac: return .thisMac
        case .network, .separator: return nil
        default: return url.map { .folder($0) }
        }
    }

    var icon: NSImage? {
        switch kind {
        case .home: return symbol("house.fill", size: 13)
        case .thisMac: return symbol("laptopcomputer", size: 13)
        case .network: return symbol("network", size: 13)
        case .iCloud: return symbol("icloud.fill", size: 13)
        case .recycleBin: return symbol("trash", size: 13)
        case .applications: return symbol("square.grid.3x3.fill", size: 12)
        case .separator: return nil
        default: return url.map { Icons.icon(for: $0, size: 16) }
        }
    }

    /// Children are folders only, listed when the row is expanded (one directory listing, never deeper).
    func loadChildren() {
        guard children == nil else { return }
        switch kind {
        case .thisMac:
            children = Places.localVolumes.map { NavNode(.volume, url: $0, title: FS.volumeName($0), expandable: true) }
        case .network:
            children = Places.networkVolumes.map { NavNode(.volume, url: $0, title: FS.volumeName($0), expandable: true) }
        default:
            guard let url else { children = []; return }
            let subs = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: Settings.shared.showHidden ? [] : [.skipsHiddenFiles])) ?? []
            children = subs.filter(FS.isDirectory)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { NavNode(.folder, url: $0, title: FS.displayName($0), expandable: true) }
        }
    }
}

final class NavPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NavOutlineView()
    private var roots: [NavNode] = []
    var onNavigate: ((Location) -> Void)?
    var onOpenInNewTab: ((Location) -> Void)?
    var onDrop: (([URL], URL, Bool) -> Void)?
    var onProperties: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Solid background (no translucent sidebar glass), same colour as the file list, like Windows.
        let bg = SolidBackground(color: Theme.nav)
        addSubview(bg); bg.pin(to: self)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowHeight = 26
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = false
        let col = NSTableColumn(identifier: .init("nav"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        outline.menuProvider = { [weak self] row in self?.menu(row: row) }
        scroll.documentView = outline
        addSubview(scroll); scroll.pin(to: self)

        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .pinsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .settingsChanged, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(reload), name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(reload), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc func reload() {
        // Sections you can hide in BugOS › File Explorer › Navigation pane (all shown by default).
        let hidden = Set(UserDefaults.standard.stringArray(forKey: ExplorerSetting.navHidden) ?? [])
        func on(_ id: String) -> Bool { !hidden.contains(id) }
        let mac = NavNode(.thisMac, title: "This Mac", expandable: true)
        // Sections in your order; a divider wherever the kind of section changes.
        var groups: [(kind: String, nodes: [NavNode])] = []
        func add(_ kind: String, _ nodes: [NavNode]) {
            guard !nodes.isEmpty else { return }
            if groups.last?.kind == kind { groups[groups.count - 1].nodes += nodes } else { groups.append((kind, nodes)) }
        }
        for sec in ExplorerSetting.orderedNavSections(UserDefaults.standard.stringArray(forKey: ExplorerSetting.navOrder)) where on(sec.id) {
            switch sec.id {
            case "home": add("places", [NavNode(.home, title: "Home")])
            case "applications": add("places", [NavNode(.applications, url: URL(fileURLWithPath: "/Applications"), title: "Applications", expandable: true)])
            case "icloud": if let ic = Places.iCloud { add("places", [NavNode(.iCloud, url: ic, title: "iCloud Drive", expandable: true)]) }
            case "quickAccess": add("pins", Settings.shared.pinned.filter(FS.exists).map { NavNode(.pinned, url: $0, title: FS.displayName($0), expandable: true) })
            case "thisMac": add("drives", [mac])
            case "network": if !Places.networkVolumes.isEmpty { add("drives", [NavNode(.network, title: "Network", expandable: true)]) }
            case "recycleBin": add("bin", [NavNode(.recycleBin, url: RecycleBin.url, title: "Recycle Bin")])
            default: break
            }
        }
        var r: [NavNode] = []
        for g in groups {
            if !r.isEmpty { r.append(NavNode(.separator, title: "")) }
            r += g.nodes
        }
        roots = r
        outline.reloadData()
        restoreExpanded()
    }

    // MARK: Remembering which arrows are open

    /// Which rows you left expanded (This Mac, Network, folders…), kept across windows and restarts.
    /// Never set before: just This Mac open, as it always was.
    private static let expandedKey = "navExpanded"
    private var restoringExpanded = false
    private static var expanded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? ["thisMac"]) }
        set { UserDefaults.standard.set(Array(newValue), forKey: expandedKey) }
    }

    /// A row's name for remembering it: This Mac / Network by kind, everything else by its folder.
    private static func key(_ n: NavNode) -> String? {
        switch n.kind {
        case .thisMac: return "thisMac"
        case .network: return "network"
        case .separator, .home, .recycleBin: return nil
        default: return n.url.map { "\(n.kind == .pinned ? "pin" : "dir"):\($0.standardizedFileURL.path)" }
        }
    }

    /// Open again what was open (top level first, then inside those, a few levels down).
    private func restoreExpanded() {
        let want = Self.expanded
        restoringExpanded = true
        defer { restoringExpanded = false }
        func walk(_ nodes: [NavNode], depth: Int) {
            guard depth < 6 else { return }
            for n in nodes where n.expandable {
                guard let k = Self.key(n), want.contains(k) else { continue }
                outline.expandItem(n)
                walk(n.children ?? [], depth: depth + 1)
            }
        }
        walk(roots, depth: 0)
    }

    func outlineViewItemDidExpand(_ n: Notification) { remember(n, open: true) }
    func outlineViewItemDidCollapse(_ n: Notification) { remember(n, open: false) }

    private func remember(_ n: Notification, open: Bool) {
        guard !restoringExpanded, let node = n.userInfo?["NSObject"] as? NavNode, let k = Self.key(node) else { return }
        var e = Self.expanded
        if open { e.insert(k) } else { e.remove(k) }
        Self.expanded = e
    }

    /// Highlight the row for the current location if it's a top-level place.
    func highlight(_ loc: Location) {
        for (i, n) in roots.enumerated() {
            if n.location == loc { outline.selectRowIndexes([outline.row(forItem: n)], byExtendingSelection: false); _ = i; return }
        }
        outline.deselectAll(nil)
    }

    // MARK: Data source

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? NavNode else { return roots.count }
        n.loadChildren()
        return n.children?.count ?? 0
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? NavNode else { return roots[index] }
        return n.children![index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? NavNode)?.expandable ?? false }

    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? NavNode)?.kind == .separator ? 11 : 26
    }
    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? NavNode)?.kind != .separator }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? NavNode else { return nil }
        if n.kind == .separator {
            let v = NSView()
            let line = NSBox(); line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(line)
            NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                                         line.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                                         line.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            return v
        }
        let cell = NSTableCellView()
        let iv = NSImageView(); iv.image = n.icon; iv.contentTintColor = n.kind == .home ? .systemOrange : .secondaryLabelColor
        if n.kind == .iCloud || n.kind == .applications { iv.contentTintColor = .systemBlue }
        let tf = NSTextField(labelWithString: n.title)
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .systemFont(ofSize: 13)
        cell.imageView = iv; cell.textField = tf
        for v in [iv, tf] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        var cons = [
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 7),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if n.kind == .pinned {
            let pin = NSImageView(image: symbol("pin.fill", size: 9) ?? NSImage())
            pin.contentTintColor = .tertiaryLabelColor
            pin.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(pin)
            cons += [pin.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                     pin.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                     tf.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -4)]
        } else {
            cons.append(tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4))
        }
        NSLayoutConstraint.activate(cons)
        return cell
    }

    @objc private func clicked() {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? NavNode else { return }
        if let loc = n.location {
            if NSEvent.modifierFlags.contains(.command) { onOpenInNewTab?(loc) } else { onNavigate?(loc) }
        } else if n.expandable {
            outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n)
        }
    }

    // MARK: Drop files onto a folder in the pane

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let n = item as? NavNode, n.url != nil, index == NSOutlineViewDropOnItemIndex else { return [] }
        return Drag.operation(info, to: n.url!)
    }
    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let n = item as? NavNode, let dir = n.url else { return false }
        let urls = Drag.urls(info)
        guard !urls.isEmpty else { return false }
        onDrop?(urls, dir, Drag.operation(info, to: dir) == .copy)
        return true
    }

    // MARK: Context menu

    private func menu(row: Int) -> NSMenu? {
        guard row >= 0, let n = outline.item(atRow: row) as? NavNode, let loc = n.location else { return nil }
        let m = NSMenu()
        m.addItem(menuItem("Open", "arrow.up.forward.app") { [weak self] in self?.onNavigate?(loc) })
        m.addItem(menuItem("Open in new tab", "plus.square.on.square") { [weak self] in self?.onOpenInNewTab?(loc) })
        m.addItem(menuItem("Open in new window", "macwindow") { (NSApp.delegate as? AppDelegate)?.newWindow(locations: [loc]) })
        guard let u = n.url else { return m }
        if n.kind == .recycleBin {
            m.addItem(.separator())
            m.addItem(menuItem("Empty Recycle Bin", "trash.slash") { RecycleBin.empty(window: nil) })
            return m
        }
        m.addItem(.separator())
        let pinned = Settings.shared.isPinned(u)
        m.addItem(menuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", pinned ? "pin.slash" : "pin") { Settings.shared.togglePin(u) })
        m.addItem(menuItem("Copy as path", "doc.on.clipboard") { FileClipboard.shared.copyPaths([u]) })
        m.addItem(menuItem("Open in Terminal", "terminal") { Actions.openInTerminal(u) })
        m.addItem(menuItem("Show in Finder", "macwindow.on.rectangle") { FinderRedirect.shared.showInFinder([u]) })
        if n.kind == .volume && u.path != "/" {
            m.addItem(menuItem("Eject", "eject") {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: u) }
                catch { showError("Couldn't eject “\(FS.volumeName(u))”.", info: error.localizedDescription, in: nil) }
            })
        }
        m.addItem(.separator())
        m.addItem(menuItem("Properties", "info.circle") { [weak self] in self?.onProperties?(u) })
        return m
    }
}

final class NavOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return menuProvider?(row)
    }
    // Keep the source-list look but don't steal the file view's focus ring.
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Drag helpers (Windows rules: same disk = move, other disk = copy; ⌥ forces copy, ⌘ forces move)

enum Drag {
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func operation(_ info: NSDraggingInfo, to dir: URL) -> NSDragOperation {
        let srcs = urls(info)
        guard !srcs.isEmpty else { return [] }
        if srcs.contains(where: { $0.standardizedFileURL == dir.standardizedFileURL }) { return [] }
        let mods = NSEvent.modifierFlags
        if mods.contains(.option) { return .copy }
        if mods.contains(.command) { return .move }
        return sameVolume(srcs[0], dir) ? .move : .copy
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool { FS.sameVolume(a, b) }
}

final class SolidBackground: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}
