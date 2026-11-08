import AppKit

/// Everything below the tab strip for one tab: navigation row, command bar, panes, file view, status bar.
final class BrowserViewController: NSViewController, FileListDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    private(set) var location: Location
    var onLocationChange: (() -> Void)?
    /// Picker (Save/Open bridge) hooks: a file was double-clicked / the selection changed.
    var pickFile: ((FileItem) -> Void)?
    var onSelection: (([FileItem]) -> Void)?
    var currentDirectory: URL? { currentFolder }
    weak var windowController: ExplorerWindowController?

    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    static var recentLocations: [Location] = []

    // Rows
    private let backButton = BarButton(symbolName: "arrow.left", tip: "Back (⌘[)", target: nil, action: nil)
    private let forwardButton = BarButton(symbolName: "arrow.right", tip: "Forward (⌘])", target: nil, action: nil)
    private let upButton = BarButton(symbolName: "arrow.up", tip: "Up to parent folder (⌘↑)", target: nil, action: nil)
    private let refreshButton = BarButton(symbolName: "arrow.clockwise", tip: "Refresh (⌘R)", target: nil, action: nil)
    private let address = AddressBar()
    private let search = SearchBox()
    private var cutButton: BarButton!, copyButton: BarButton!, pasteButton: BarButton!, renameButton: BarButton!
    private var shareButton: BarButton!, deleteButton: BarButton!, detailsToggle: BarButton!, previewToggle: BarButton!

    // Panes
    private let split = NSSplitView()
    private let navPane = NavPane()
    private let contentHost = NSView()
    private let detailsPane = DetailsPane()
    private let previewPane = PreviewPane()
    private let status = StatusBar()
    private let emptyLabel = NSTextField(labelWithString: "")

    // Content
    private var dirModel: DirectoryModel?
    private var searchModel: SearchModel?
    private var listView: FileListView?
    private var page: PageView?
    private var state = FolderViewState()
    private var afterLoad: (() -> Void)?

    init(location: Location) {
        self.location = location
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    override func loadView() {
        let root = ToolbarBackground()
        view = root

        for (b, sel) in [(backButton, #selector(goBack(_:))), (forwardButton, #selector(goForward(_:))),
                         (upButton, #selector(goUp(_:))), (refreshButton, #selector(refresh(_:)))] {
            b.target = self; b.action = sel
        }
        backButton.menuProvider = nil
        address.onNavigate = { [weak self] loc in self?.navigate(loc) }
        address.onTyped = { [weak self] text in self?.navigateTyped(text) }
        address.recent = { BrowserViewController.recentLocations }
        search.onFilter = { [weak self] q in self?.filter(q) }
        search.onSearch = { [weak self] q in self?.startSearch(q) }

        let navRow = NSStackView(views: [backButton, forwardButton, upButton, refreshButton, address, search])
        navRow.spacing = 4
        navRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        address.translatesAutoresizingMaskIntoConstraints = false
        address.heightAnchor.constraint(equalToConstant: 32).isActive = true
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: 250).isActive = true
        search.heightAnchor.constraint(equalToConstant: 30).isActive = true
        navRow.setCustomSpacing(10, after: refreshButton)
        navRow.setCustomSpacing(10, after: address)

        let commandRow = buildCommandBar()

        let line = NSBox(); line.boxType = .separator

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        navPane.onNavigate = { [weak self] loc in self?.navigate(loc) }
        navPane.onOpenInNewTab = { [weak self] loc in self?.windowController?.addTab(loc, select: false) }
        navPane.onDrop = { [weak self] urls, dir, copy in FileOps.transfer(urls, to: dir, move: !copy, window: self?.view.window) }
        navPane.onProperties = { u in PropertiesWindow.show([u]) }
        detailsPane.onProperties = { [weak self] in self?.showProperties(nil) }
        contentHost.wantsLayer = true
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        split.addArrangedSubview(navPane)
        split.addArrangedSubview(contentHost)
        navPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        contentHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        detailsPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        previewPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)
        status.onMode = { [weak self] m in self?.setViewMode(m) }

        for v in [navRow, commandRow, line, split, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            navRow.topAnchor.constraint(equalTo: root.topAnchor),
            navRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            navRow.heightAnchor.constraint(equalToConstant: 46),
            commandRow.topAnchor.constraint(equalTo: navRow.bottomAnchor),
            commandRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commandRow.heightAnchor.constraint(equalToConstant: 44),
            line.topAnchor.constraint(equalTo: commandRow.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: line.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCommands), name: .clipboardChanged, object: nil)
        applyPaneSettings()
        DispatchQueue.main.async { [self] in
            split.setPosition(CGFloat(UserDefaults.standard.double(forKey: "navWidth").nonZero ?? 250), ofDividerAt: 0)
        }
        navigate(location, record: false)
    }

    private func buildCommandBar() -> NSView {
        let newB = BarButton(symbolName: "plus.circle", title: "New", tip: "Create a new item in the current location.", dropdown: true, target: nil, action: nil)
        newB.menuProvider = { [weak self] in self?.newMenu() }
        cutButton = BarButton(symbolName: "scissors", tip: "Cut (⌘X)", target: self, action: #selector(cut(_:)))
        copyButton = BarButton(symbolName: "doc.on.doc", tip: "Copy (⌘C)", target: self, action: #selector(copy(_:)))
        pasteButton = BarButton(symbolName: "doc.on.clipboard", tip: "Paste (⌘V)", target: self, action: #selector(paste(_:)))
        renameButton = BarButton(symbolName: "character.cursor.ibeam", tip: "Rename (F2)", target: self, action: #selector(renameSelection(_:)))
        shareButton = BarButton(symbolName: "square.and.arrow.up", tip: "Share", target: self, action: #selector(share(_:)))
        deleteButton = BarButton(symbolName: "trash", tip: "Delete (⌘⌫)", target: self, action: #selector(deleteSelection(_:)))
        let sortB = BarButton(symbolName: "arrow.up.arrow.down", title: "Sort", tip: "Sort items", dropdown: true, target: nil, action: nil)
        sortB.menuProvider = { [weak self] in self?.sortMenu() }
        let viewB = BarButton(symbolName: "rectangle.grid.1x2", title: "View", tip: "Change how items are shown", dropdown: true, target: nil, action: nil)
        viewB.menuProvider = { [weak self] in self?.viewMenu() }
        let moreB = BarButton(symbolName: "ellipsis", tip: "See more", target: nil, action: nil)
        moreB.menuProvider = { [weak self] in self?.moreMenu() }
        previewToggle = BarButton(symbolName: "eye", title: "Preview", tip: "Show or hide the preview pane (⌥P)", target: self, action: #selector(togglePreviewPane(_:)))
        detailsToggle = BarButton(symbolName: "sidebar.right", title: "Details", tip: "Show or hide the details pane (⌥⇧P)", target: self, action: #selector(toggleDetailsPane(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [newB, separatorView(), cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton,
                                      separatorView(), sortB, viewB, separatorView(), moreB, spacer, previewToggle, detailsToggle])
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        row.setCustomSpacing(8, after: newB)
        return row
    }

    // MARK: - Panes

    private func applyPaneSettings() {
        let s = Settings.shared
        navPane.isHidden = !s.showNavPane
        let wanted: NSView? = s.sidePane == .details ? detailsPane : (s.sidePane == .preview ? previewPane : nil)
        for p in [detailsPane, previewPane] as [NSView] where p !== wanted && p.superview === split {
            split.removeArrangedSubview(p); p.removeFromSuperview()
        }
        if let wanted, wanted.superview !== split {
            split.addArrangedSubview(wanted)
            let w = UserDefaults.standard.double(forKey: "sidePaneWidth").nonZero ?? 300
            DispatchQueue.main.async { [self] in split.setPosition(split.bounds.width - CGFloat(w) - split.dividerThickness, ofDividerAt: 1) }
        }
        split.adjustSubviews()
        detailsToggle?.isToggled = s.sidePane == .details
        previewToggle?.isToggled = s.sidePane == .preview
        updateSidePane()
    }

    func splitView(_ sv: NSSplitView, canCollapseSubview v: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ n: Notification) {
        guard view.window != nil else { return }
        if !navPane.isHidden, navPane.frame.width > 100 { UserDefaults.standard.set(Double(navPane.frame.width), forKey: "navWidth") }
        for p in [detailsPane, previewPane] as [NSView] where p.superview === split && p.frame.width > 100 {
            UserDefaults.standard.set(Double(p.frame.width), forKey: "sidePaneWidth")
        }
    }

    @objc private func settingsChanged() {
        applyPaneSettings()
        listView?.refreshAppearance()
        if let dirModel { show(dirModel.items, groups: dirModel.groups) }
    }

    // MARK: - Navigation

    func navigate(_ loc: Location, record: Bool = true, select: URL? = nil) {
        if case .folder(let u) = loc, !FS.exists(u) {
            showError("Location is not available", info: "“\(u.path)” is unavailable. It may have been moved, renamed or deleted, or the drive may be disconnected.", in: view.window)
            return
        }
        if record, loc != location { backStack.append(location); forwardStack.removeAll() }
        let cameFrom = location.url
        location = loc
        BrowserViewController.recentLocations.removeAll { $0 == loc }
        BrowserViewController.recentLocations.insert(loc, at: 0)
        if case .search = loc {} else { search.stringValue = "" }
        search.placeholderString = "Search \(loc.tabTitle)"
        address.location = loc
        navPane.highlight(loc)
        buildContent()
        // Going up selects the folder you came from, like Explorer.
        if let s = select ?? cameFrom, case .folder(let u) = loc, s.deletingLastPathComponent().standardizedFileURL == u.standardizedFileURL {
            afterLoad = { [weak self] in self?.listView?.select(urls: [s], scroll: true) }
        }
        updateNavButtons()
        onLocationChange?()
        if !address.editing { focusContent() }      // keyboard goes back to the files, like Explorer
    }

    private func navigateTyped(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let server = ServerConnect.url(fromTyped: t) {
            ServerConnect.connect(server, window: view.window) { [weak self] dir in self?.navigate(.folder(dir)) }
            return
        }
        if t.lowercased() == "home" { navigate(.home); return }
        if t.lowercased() == "this mac" || t.lowercased() == "this pc" { navigate(.thisMac); return }
        guard let u = FS.resolve(typed: t, relativeTo: location.url), FS.exists(u) else {
            showError("File Explorer can’t find “\(t)”.", info: "Check the spelling and try again.", in: view.window)
            focusAddress(nil)
            return
        }
        if FS.isDirectory(u) { navigate(.folder(u)) }
        else { reveal(u); NSWorkspace.shared.open(u) }   // a file path opens the file and shows it in its folder
    }

    /// Open the item's folder and select it.
    func reveal(_ url: URL) {
        navigate(.folder(url.deletingLastPathComponent()))
        let pick = { [weak self] in self?.listView?.select(urls: [url], scroll: true); self?.listView?.focus() }
        // A folder that's already loaded was shown inside navigate, so there's no load left to wait for.
        if dirModel?.items.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) == true { pick() }
        else { afterLoad = pick }
    }

    private func updateNavButtons() {
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        upButton.isEnabled = parentLocation != nil
    }

    private var parentLocation: Location? {
        switch location {
        case .home: return nil
        case .thisMac: return nil
        case .search(let u, _): return .folder(u)
        case .folder(let u):
            let isVolume = (try? u.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
            if u.path == "/" || isVolume { return .thisMac }
            return .folder(u.deletingLastPathComponent())
        }
    }

    @objc func goBack(_ sender: Any?) {
        guard let prev = backStack.popLast() else { NSSound.beep(); return }
        forwardStack.append(location)
        navigate(prev, record: false)
    }
    @objc func goForward(_ sender: Any?) {
        guard let next = forwardStack.popLast() else { NSSound.beep(); return }
        backStack.append(location)
        navigate(next, record: false)
    }
    @objc func goUp(_ sender: Any?) { if let p = parentLocation { navigate(p) } }
    @objc func goPlace(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        let h = FS.home
        let places: [Location] = [.home, .thisMac, .folder(h.appendingPathComponent("Desktop")), .folder(h.appendingPathComponent("Downloads")),
                                  .folder(h.appendingPathComponent("Documents")), .folder(URL(fileURLWithPath: "/Applications"))]
        if places.indices.contains(tag) { navigate(places[tag]) }
    }

    // MARK: - Content

    private func clearContent() {
        dirModel?.onChange = nil
        dirModel = nil
        searchModel?.stop()
        searchModel = nil
        listView?.removeFromSuperview()
        listView = nil
        page?.removeFromSuperview()
        page = nil
        emptyLabel.removeFromSuperview()
        afterLoad = nil
    }

    private func buildContent() {
        clearContent()
        switch location {
        case .home, .thisMac:
            let p: PageView = location == .home ? HomePage() : ThisMacPage()
            p.onOpen = { [weak self] u in self?.openURL(u) }
            p.onSelectionChange = { [weak self] _ in self?.selectionChanged() }
            p.menuProvider = { [weak self] u in self?.listMenu(for: [FileItem(url: u)]) }
            contentHost.addSubview(p); p.pin(to: contentHost)
            page = p
            focusContent()
            status.set(mode: nil)
            status.label.stringValue = location == .thisMac ? Fmt.items(Places.volumes().count) : ""
        case .folder(let u):
            let m = DirectoryModel(url: u)
            state = m.state
            dirModel = m
            makeListView()
            m.onChange = { [weak self, weak m] in
                guard let self, let m else { return }
                self.show(m.items, groups: m.groups)
                if m.error != nil, RecycleBin.contains(m.url) {
                    self.showEmpty("To show the Recycle Bin, BugOS needs Full Disk Access.\nSystem Settings › Privacy & Security › Full Disk Access › turn on BugOS,\nthen reopen the Recycle Bin. (Emptying it works without this.)")
                }
                else if let err = m.error { self.showEmpty("This location couldn't be opened.\n\(err)") }
                else if m.items.isEmpty && RecycleBin.contains(m.url) { self.showEmpty("The Recycle Bin is empty.") }
                else if m.items.isEmpty { self.showEmpty(m.filter.isEmpty ? "This folder is empty." : "No items match your search.") }
                else { self.emptyLabel.removeFromSuperview() }
            }
            m.load()
        case .search(let root, let q):
            state = Settings.shared.viewState(for: nil)
            let s = SearchModel(root: root, query: q)
            searchModel = s
            makeListView()
            showEmpty("Searching…")
            s.onChange = { [weak self, weak s] in
                guard let self, let s else { return }
                let items = DirectoryModel.sorted(s.items, self.state)
                self.show(items, groups: DirectoryModel.grouped(items, self.state.groupKey))
                if items.isEmpty { self.showEmpty(s.finished ? "No items match your search." : "Searching…") } else { self.emptyLabel.removeFromSuperview() }
            }
            s.start()
        }
        updateSidePane()
        updateCommands()
    }

    private func makeListView() {
        listView?.removeFromSuperview()
        let v: FileListView = state.viewMode == .details ? DetailsView() : IconsView(mode: state.viewMode)
        v.delegate = self
        contentHost.addSubview(v, positioned: .below, relativeTo: nil)
        v.pin(to: contentHost)
        listView = v
        status.set(mode: state.viewMode)
    }

    private func show(_ items: [FileItem], groups: [(title: String, items: [FileItem])]) {
        var isSearch = false
        if case .search = location { isSearch = true }
        listView?.show(items: items, groups: groups, state: state, searchMode: isSearch)
        if let a = afterLoad { afterLoad = nil; a() }
        selectionChanged()
    }

    private func showEmpty(_ text: String) {
        emptyLabel.stringValue = text
        if emptyLabel.superview == nil {
            contentHost.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
                emptyLabel.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 60),
            ])
        }
    }

    private var currentItems: [FileItem] { dirModel?.items ?? searchModel?.items ?? [] }

    var selection: [FileItem] {
        if let page { return page.selectedURLs.map(FileItem.init) }
        return listView?.selectedItems ?? []
    }

    func focusContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let l = self.listView { l.focus() } else { self.view.window?.makeFirstResponder(self.page) }
        }
    }

    func teardown() {
        clearContent()
        previewPane.teardown()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Filter & search

    private func filter(_ q: String) {
        if case .search(let root, _) = location, q.isEmpty { navigate(.folder(root)); return }
        dirModel?.filter = q
    }

    private func startSearch(_ q: String) {
        let root: URL
        switch location {
        case .folder(let u), .search(let u, _): root = u
        default: root = FS.home
        }
        navigate(.search(root, q))
        search.stringValue = q
    }

    // MARK: - Selection-driven UI

    private func selectionChanged() {
        onSelection?(selection)
        updateStatus()
        updateSidePane()
        updateCommands()
        QuickLook.shared.update(urls: selection.map(\.url))
    }

    private func updateStatus() {
        guard page == nil else { return }
        let items = currentItems.filter { Settings.shared.showHidden || !$0.isHidden }
        var text = Fmt.items(dirModel?.items.count ?? items.count)
        let sel = selection
        if !sel.isEmpty {
            text += "     \(sel.count == 1 ? "1 item" : "\(sel.count) items") selected"
            let files = sel.filter { !$0.isDirectory }
            if !files.isEmpty { text += "  \(Fmt.size(files.reduce(0) { $0 + $1.size }))" }
        }
        status.label.stringValue = text
    }

    private func updateSidePane() {
        switch Settings.shared.sidePane {
        case .details: detailsPane.show(selection: selection, folder: location.url, folderItemCount: currentItems.count)
        case .preview: previewPane.show(selection.count == 1 ? selection[0] : nil)
        case .none: break
        }
    }

    @objc private func updateCommands() {
        let has = !selection.isEmpty
        let inFolder = currentFolder != nil
        cutButton?.isEnabled = has && inFolder
        copyButton?.isEnabled = has
        renameButton?.isEnabled = selection.count == 1 && inFolder
        shareButton?.isEnabled = has
        deleteButton?.isEnabled = has
        pasteButton?.isEnabled = inFolder && FileClipboard.shared.canPaste
    }

    /// The folder new items and pastes go into.
    private var currentFolder: URL? {
        if case .folder(let u) = location { return u }
        return nil
    }

    // MARK: - FileListDelegate

    var listCurrentFolder: URL? { currentFolder }
    func listSelectionChanged() { selectionChanged() }
    func listOpen(_ item: FileItem) { open(item, newTab: NSEvent.modifierFlags.contains(.command)) }
    func listMenu(for items: [FileItem]) -> NSMenu? { items.isEmpty ? backgroundMenu() : itemMenu(items) }
    func listBack() { goBack(nil) }
    func listOpenInNewTab(_ item: FileItem) { windowController?.addTab(.folder(item.url), select: false) }

    /// Explorer's Ctrl+wheel order, biggest first.
    private static let zoomOrder: [ViewMode] = [.extraLarge, .large, .medium, .small, .list, .details, .tiles, .content]
    func listZoom(_ bigger: Bool) {
        let order = BrowserViewController.zoomOrder
        guard let i = order.firstIndex(of: state.viewMode) else { return }
        let j = bigger ? i - 1 : i + 1
        guard order.indices.contains(j) else { return }
        setViewMode(order[j])
    }
    func listDelete(permanent: Bool) { permanent ? deletePermanently(nil) : deleteSelection(nil) }

    func listRename(_ item: FileItem, to name: String) {
        if let dst = FileOps.rename(item.url, to: name, window: view.window) {
            afterLoad = { [weak self] in self?.listView?.select(urls: [dst], scroll: true) }
        }
    }

    func listDrop(_ urls: [URL], into dir: URL?, copy: Bool) {
        guard let target = dir ?? currentFolder else { return }
        FileOps.transfer(urls, to: target, move: !copy, window: view.window)
    }

    func listSortChanged(_ key: SortKey, ascending: Bool) {
        state.sort = key.rawValue
        state.ascending = ascending
        applyState()
    }

    private func applyState() {
        Settings.shared.setViewState(state, for: location.url.flatMap { if case .search = location { return nil }; return $0 })
        if let dirModel { dirModel.state = state }
        else if let s = searchModel {
            let items = DirectoryModel.sorted(s.items, state)
            show(items, groups: DirectoryModel.grouped(items, state.groupKey))
        }
    }

    // MARK: - Opening

    func open(_ item: FileItem, newTab: Bool = false) {
        var target = item.url
        // Follow aliases and symlinks to folders.
        if let resolved = try? URL(resolvingAliasFileAt: target), resolved != target { target = resolved }
        if FS.isDirectory(target) {
            if newTab, windowController != nil { windowController?.addTab(.folder(target), select: false) } else { navigate(.folder(target)) }
        } else if let pickFile {
            pickFile(FileItem(url: target))
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    private func openURL(_ u: URL) { open(FileItem(url: u)) }

    // MARK: - Menus

    private func newMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(menuItem("Folder", "folder.badge.plus") { [weak self] in self?.newFolder(nil) })
        m.addItem(.separator())
        m.addItem(menuItem("Text Document", "doc.text") { [weak self] in self?.newTextDocument(nil) })
        m.addItem(menuItem("Markdown Document", "doc.richtext") { [weak self] in self?.newFile(base: "New Markdown Document", ext: "md") })
        m.addItem(menuItem("Rich Text Document", "doc.richtext") { [weak self] in
            self?.newFile(base: "New Rich Text Document", ext: "rtf", contents: "{\\rtf1\\ansi\n}")
        })
        if currentFolder == nil { m.items.forEach { $0.isEnabled = false }; m.autoenablesItems = false }
        return m
    }

    private func sortMenu() -> NSMenu {
        let m = NSMenu()
        var keys: [SortKey] = [.name, .dateModified, .type, .size, .dateCreated]
        if case .search = location { keys.append(.folder) }
        for k in keys {
            let it = menuItem(k.title) { [weak self] in self?.listSortChanged(k, ascending: self?.state.ascending ?? true) }
            it.state = state.sortKey == k ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        let asc = menuItem("Ascending", "arrow.up") { [weak self] in guard let self else { return }; self.listSortChanged(self.state.sortKey, ascending: true) }
        asc.state = state.ascending ? .on : .off
        let desc = menuItem("Descending", "arrow.down") { [weak self] in guard let self else { return }; self.listSortChanged(self.state.sortKey, ascending: false) }
        desc.state = state.ascending ? .off : .on
        m.addItem(asc); m.addItem(desc)
        m.addItem(.separator())
        let g = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        g.image = symbol("square.stack.3d.up", size: 13)
        g.submenu = groupMenu()
        m.addItem(g)
        return m
    }

    private func groupMenu() -> NSMenu {
        let m = NSMenu()
        for k in GroupKey.allCases {
            let it = menuItem(k.title) { [weak self] in self?.state.group = k.rawValue; self?.applyState() }
            it.state = state.groupKey == k ? .on : .off
            m.addItem(it)
        }
        return m
    }

    private func viewMenu() -> NSMenu {
        let m = NSMenu()
        for (i, mode) in ViewMode.allCases.enumerated() {
            let it = menuItem(mode.title, mode.symbol, key: "\(i + 1)", mods: [.command, .shift]) { [weak self] in self?.setViewMode(mode) }
            it.state = state.viewMode == mode ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        let showItem = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        showItem.image = symbol("checklist", size: 13)
        let s = NSMenu()
        let S = Settings.shared
        let rows: [(String, Bool, () -> Void)] = [
            ("Navigation pane", S.showNavPane, { S.showNavPane.toggle() }),
            ("Details pane", S.sidePane == .details, { S.sidePane = S.sidePane == .details ? .none : .details }),
            ("Preview pane", S.sidePane == .preview, { S.sidePane = S.sidePane == .preview ? .none : .preview }),
            ("Item check boxes", S.itemCheckBoxes, { S.itemCheckBoxes.toggle() }),
            ("File name extensions", S.showExtensions, { S.showExtensions.toggle() }),
            ("Hidden items", S.showHidden, { S.showHidden.toggle() }),
        ]
        for (title, on, act) in rows {
            let it = menuItem(title, nil, key: "", mods: [], act)
            it.state = on ? .on : .off
            s.addItem(it)
        }
        showItem.submenu = s
        m.addItem(showItem)
        return m
    }

    private func moreMenu() -> NSMenu {
        let m = NSMenu()
        let undo = menuItem(Undo.shared.title.map { "Undo \($0)" } ?? "Undo", "arrow.uturn.backward") { Undo.shared.undo() }
        undo.isEnabled = Undo.shared.title != nil
        m.autoenablesItems = false
        m.addItem(undo)
        m.addItem(.separator())
        m.addItem(menuItem("Select all", "checkmark.circle") { [weak self] in self?.listView?.selectAllItems() })
        m.addItem(menuItem("Select none", "circle") { [weak self] in self?.listView?.selectNone() })
        m.addItem(menuItem("Invert selection", "circle.lefthalf.filled") { [weak self] in self?.listView?.invertSelection() })
        m.addItem(.separator())
        if let u = selection.first?.url ?? location.url {
            let pinned = Settings.shared.isPinned(u)
            m.addItem(menuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", pinned ? "pin.slash" : "pin") { Settings.shared.togglePin(u) })
            m.addItem(menuItem("Copy as path", "doc.on.clipboard") { [weak self] in self?.copyAsPath(nil) })
        }
        if let dir = currentFolder {
            m.addItem(menuItem("Open in Terminal", "terminal") { Actions.openInTerminal(dir) })
            m.addItem(menuItem("Show in Finder", "macwindow.on.rectangle") { [weak self] in
                let sel = self?.selection.map(\.url) ?? []
                FinderRedirect.shared.showInFinder(sel.isEmpty ? [dir] : sel)
            })
        }
        m.addItem(.separator())
        m.addItem(menuItem("Properties", "info.circle") { [weak self] in self?.showProperties(nil) })
        return m
    }

    private func itemMenu(_ items: [FileItem]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let urls = items.map(\.url)
        if inRecycleBin {
            m.addItem(menuItem("Restore", "arrow.uturn.backward.circle") { [weak self] in RecycleBin.restore(urls, window: self?.view.window) })
            m.addItem(.separator())
            m.addItem(menuItem("Delete permanently", "trash.slash") { [weak self] in FileOps.deletePermanently(urls, window: self?.view.window) })
            m.addItem(menuItem("Properties", "info.circle") { PropertiesWindow.show(urls) })
            return m
        }
        let single = items.count == 1 ? items[0] : nil
        let openItem = menuItem("Open", "arrow.up.forward.app") { [weak self] in items.forEach { self?.open($0) } }
        openItem.attributedTitle = NSAttributedString(string: "Open", attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        m.addItem(openItem)
        if let f = single, f.isDirectory {
            m.addItem(menuItem("Open in new tab", "plus.square.on.square") { [weak self] in self?.windowController?.addTab(.folder(f.url), select: false) })
            m.addItem(menuItem("Open in new window", "macwindow") { (NSApp.delegate as? AppDelegate)?.newWindow(locations: [.folder(f.url)]) })
        }
        if let f = single, !f.isDirectory {
            let ow = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
            ow.image = symbol("square.grid.2x2", size: 13)
            let sub = NSMenu()
            for app in FS.appsToOpen(f.url).prefix(20) {
                let it = menuItem(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) { Actions.open(f.url, with: app) }
                it.image = Icons.icon(for: app, size: 16)
                sub.addItem(it)
            }
            if !sub.items.isEmpty { sub.addItem(.separator()) }
            sub.addItem(menuItem("Choose another app…") { [weak self] in Actions.chooseApp(for: f.url, window: self?.view.window) })
            ow.submenu = sub
            m.addItem(ow)
        }
        m.addItem(.separator())
        let inFolder = currentFolder != nil
        let cutI = menuItem("Cut", "scissors") { [weak self] in self?.cut(nil) }; cutI.isEnabled = inFolder
        m.addItem(cutI)
        m.addItem(menuItem("Copy", "doc.on.doc") { [weak self] in self?.copy(nil) })
        if let f = single, f.isDirectory, FileClipboard.shared.canPaste {
            m.addItem(menuItem("Paste into folder", "doc.on.clipboard") { [weak self] in FileClipboard.shared.paste(into: f.url, window: self?.view.window) })
        }
        let ren = menuItem("Rename", "character.cursor.ibeam") { [weak self] in self?.renameSelection(nil) }; ren.isEnabled = single != nil && inFolder
        m.addItem(ren)
        m.addItem(menuItem("Delete", "trash") { [weak self] in self?.deleteSelection(nil) })
        m.addItem(.separator())
        m.addItem(menuItem("Copy as path", "doc.on.clipboard") { FileClipboard.shared.copyPaths(urls) })
        let share = NSSharingServicePicker(items: urls).standardShareMenuItem
        m.addItem(share)
        m.addItem(.separator())
        if let f = single, f.url.pathExtension.lowercased() == "zip" {
            m.addItem(menuItem("Extract All…", "archivebox") { [weak self] in FileOps.extract(f.url, window: self?.view.window) })
        }
        m.addItem(menuItem("Compress to ZIP file", "doc.zipper") { [weak self] in FileOps.compress(urls, window: self?.view.window) })
        if let f = single, f.isDirectory {
            let pinned = Settings.shared.isPinned(f.url)
            m.addItem(menuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", pinned ? "pin.slash" : "pin") { Settings.shared.togglePin(f.url) })
            m.addItem(menuItem("Open in Terminal", "terminal") { Actions.openInTerminal(f.url) })
        }
        m.addItem(menuItem("Show in Finder", "macwindow.on.rectangle") { FinderRedirect.shared.showInFinder(urls) })
        m.addItem(menuItem("Quick Look", "eye") { [weak self] in QuickLook.shared.toggle(urls: urls, from: self?.view.window) })
        m.addItem(.separator())
        m.addItem(menuItem("Properties", "info.circle") { PropertiesWindow.show(urls) })
        return m
    }

    private func backgroundMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        if inRecycleBin || location.url.map(RecycleBin.contains) == true {
            m.addItem(menuItem("Empty Recycle Bin", "trash.slash") { [weak self] in RecycleBin.empty(window: self?.view.window) })
            m.addItem(menuItem("Refresh", "arrow.clockwise") { [weak self] in self?.refresh(nil) })
            return m
        }
        let v = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); v.image = symbol("rectangle.grid.1x2", size: 13); v.submenu = viewMenu()
        let s = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: ""); s.image = symbol("arrow.up.arrow.down", size: 13); s.submenu = sortMenu()
        let g = NSMenuItem(title: "Group by", action: nil, keyEquivalent: ""); g.image = symbol("square.stack.3d.up", size: 13); g.submenu = groupMenu()
        [v, s, g].forEach(m.addItem)
        m.addItem(menuItem("Refresh", "arrow.clockwise") { [weak self] in self?.refresh(nil) })
        m.addItem(.separator())
        let paste = menuItem("Paste", "doc.on.clipboard") { [weak self] in self?.paste(nil) }
        paste.isEnabled = currentFolder != nil && FileClipboard.shared.canPaste
        m.addItem(paste)
        let undo = menuItem(Undo.shared.title.map { "Undo \($0)" } ?? "Undo", "arrow.uturn.backward") { Undo.shared.undo() }
        undo.isEnabled = Undo.shared.title != nil
        m.addItem(undo)
        m.addItem(.separator())
        let n = NSMenuItem(title: "New", action: nil, keyEquivalent: ""); n.image = symbol("plus.circle", size: 13); n.submenu = newMenu()
        n.isEnabled = currentFolder != nil
        m.addItem(n)
        if let dir = location.url {
            m.addItem(.separator())
            m.addItem(menuItem("Open in Terminal", "terminal") { Actions.openInTerminal(dir) })
            m.addItem(menuItem("Copy path of this folder", "doc.on.clipboard") { FileClipboard.shared.copyPaths([dir]) })
            m.addItem(menuItem("Show in Finder", "macwindow.on.rectangle") { FinderRedirect.shared.showInFinder([dir]) })
            let pinned = Settings.shared.isPinned(dir)
            m.addItem(menuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", pinned ? "pin.slash" : "pin") { Settings.shared.togglePin(dir) })
            m.addItem(.separator())
            m.addItem(menuItem("Properties", "info.circle") { PropertiesWindow.show([dir]) })
        }
        return m
    }

    // MARK: - Commands (menu bar, command bar, shortcuts)

    @objc func cut(_ sender: Any?) { guard currentFolder != nil, !selection.isEmpty else { return }; FileClipboard.shared.cut(selection.map(\.url)) }
    @objc func copy(_ sender: Any?) { guard !selection.isEmpty else { return }; FileClipboard.shared.copy(selection.map(\.url)) }
    @objc func paste(_ sender: Any?) {
        guard let dir = currentFolder else { return }
        FileClipboard.shared.paste(into: dir, window: view.window) { [weak self] pasted in
            self?.afterLoad = { [weak self] in self?.listView?.select(urls: Set(pasted), scroll: true) }
        }
    }
    @objc func copyAsPath(_ sender: Any?) {
        let urls = selection.map(\.url)
        FileClipboard.shared.copyPaths(urls.isEmpty ? (location.url.map { [$0] } ?? []) : urls)
    }
    override func selectAll(_ sender: Any?) { listView?.selectAllItems() }
    @objc func selectNone(_ sender: Any?) { listView?.selectNone() }
    @objc func invertSelection(_ sender: Any?) { listView?.invertSelection() }

    @objc func renameSelection(_ sender: Any?) {
        guard currentFolder != nil, let it = selection.first else { return }
        listView?.beginRename(it.url)
    }
    private var inRecycleBin: Bool { currentFolder.map(RecycleBin.contains) ?? false }

    @objc func deleteSelection(_ sender: Any?) {
        let urls = selection.map(\.url)
        guard !urls.isEmpty, location != .thisMac, location != .home || page != nil else { return }
        if inRecycleBin { FileOps.deletePermanently(urls, window: view.window); return }
        FileOps.trash(urls, window: view.window)
    }
    @objc func deletePermanently(_ sender: Any?) { FileOps.deletePermanently(selection.map(\.url), window: view.window) }

    @objc func newFolder(_ sender: Any?) {
        guard let dir = currentFolder, let u = FileOps.newFolder(in: dir, window: view.window) else { return }
        afterLoad = { [weak self] in self?.listView?.beginRename(u) }
    }
    @objc func newTextDocument(_ sender: Any?) { newFile(base: "New Text Document", ext: "txt") }
    private func newFile(base: String, ext: String, contents: String = "") {
        guard let dir = currentFolder, let u = FileOps.newFile(in: dir, base: base, ext: ext, contents: contents, window: view.window) else { return }
        afterLoad = { [weak self] in self?.listView?.beginRename(u) }
    }

    @objc func openSelection(_ sender: Any?) { selection.forEach { open($0) } }
    @objc func openInNewTab(_ sender: Any?) {
        for f in selection where f.isDirectory { windowController?.addTab(.folder(f.url), select: false) }
    }
    @objc func openInNewWindow(_ sender: Any?) {
        let locs = selection.filter(\.isDirectory).map { Location.folder($0.url) }
        (NSApp.delegate as? AppDelegate)?.newWindow(locations: locs.isEmpty ? [location] : locs)
    }
    @objc func openInTerminal(_ sender: Any?) {
        if let f = selection.first, f.isDirectory { Actions.openInTerminal(f.url) }
        else if let d = location.url { Actions.openInTerminal(d) }
    }
    @objc func showProperties(_ sender: Any?) {
        let urls = selection.map(\.url)
        PropertiesWindow.show(urls.isEmpty ? (location.url.map { [$0] } ?? []) : urls)
    }
    @objc func compress(_ sender: Any?) { FileOps.compress(selection.map(\.url), window: view.window) }
    @objc func togglePin(_ sender: Any?) {
        if let u = selection.first(where: \.isDirectory)?.url ?? location.url { Settings.shared.togglePin(u) }
    }
    @objc func share(_ sender: Any?) {
        let urls = selection.map(\.url)
        guard !urls.isEmpty, let b = shareButton else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }
    @objc func undoFileOperation(_ sender: Any?) { Undo.shared.undo() }
    @objc func redoFileOperation(_ sender: Any?) { Undo.shared.redo() }

    @objc func refresh(_ sender: Any?) {
        Icons.forget(location.url ?? FS.home)
        if let dirModel { dirModel.reload() } else { buildContent() }
    }

    @objc func setViewModeFromMenu(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, ViewMode.allCases.indices.contains(tag) else { return }
        setViewMode(ViewMode.allCases[tag])
    }
    func setViewMode(_ mode: ViewMode) {
        guard page == nil else { return }
        let sel = Set(selection.map(\.url))
        state.mode = mode.rawValue
        Settings.shared.setViewState(state, for: { if case .search = location { return nil }; return location.url }())
        makeListView()
        show(dirModel?.items ?? DirectoryModel.sorted(searchModel?.items ?? [], state),
             groups: dirModel?.groups ?? DirectoryModel.grouped(DirectoryModel.sorted(searchModel?.items ?? [], state), state.groupKey))
        listView?.select(urls: sel, scroll: true)
        listView?.focus()
    }

    @objc func toggleNavPane(_ sender: Any?) { Settings.shared.showNavPane.toggle() }
    @objc func toggleDetailsPane(_ sender: Any?) { Settings.shared.sidePane = Settings.shared.sidePane == .details ? .none : .details }
    @objc func togglePreviewPane(_ sender: Any?) { Settings.shared.sidePane = Settings.shared.sidePane == .preview ? .none : .preview }
    @objc func toggleHidden(_ sender: Any?) { Settings.shared.showHidden.toggle() }
    @objc func toggleExtensions(_ sender: Any?) { Settings.shared.showExtensions.toggle() }
    @objc func toggleCheckBoxes(_ sender: Any?) { Settings.shared.itemCheckBoxes.toggle() }

    @objc func focusAddress(_ sender: Any?) { address.beginEditing() }
    @objc func focusSearch(_ sender: Any?) { view.window?.makeFirstResponder(search) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let S = Settings.shared
        switch item.action {
        case #selector(setViewModeFromMenu(_:)):
            item.state = state.viewMode == ViewMode.allCases[item.tag] ? .on : .off
            return page == nil
        case #selector(toggleNavPane(_:)): item.state = S.showNavPane ? .on : .off
        case #selector(toggleDetailsPane(_:)): item.state = S.sidePane == .details ? .on : .off
        case #selector(togglePreviewPane(_:)): item.state = S.sidePane == .preview ? .on : .off
        case #selector(toggleHidden(_:)): item.state = S.showHidden ? .on : .off
        case #selector(toggleExtensions(_:)): item.state = S.showExtensions ? .on : .off
        case #selector(toggleCheckBoxes(_:)): item.state = S.itemCheckBoxes ? .on : .off
        case #selector(cut(_:)), #selector(renameSelection(_:)):
            return currentFolder != nil && !selection.isEmpty
        case #selector(copy(_:)), #selector(deleteSelection(_:)), #selector(deletePermanently(_:)),
             #selector(openSelection(_:)), #selector(compress(_:)):
            return !selection.isEmpty
        case #selector(paste(_:)): return currentFolder != nil && FileClipboard.shared.canPaste
        case #selector(newFolder(_:)), #selector(newTextDocument(_:)): return currentFolder != nil
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goUp(_:)): return parentLocation != nil
        case #selector(undoFileOperation(_:)):
            item.title = Undo.shared.title.map { "Undo \($0)" } ?? "Undo"
            return Undo.shared.title != nil
        case #selector(redoFileOperation(_:)):
            item.title = Undo.shared.redoTitle.map { "Redo \($0)" } ?? "Redo"
            return Undo.shared.redoTitle != nil
        case #selector(togglePin(_:)):
            let u = selection.first(where: \.isDirectory)?.url ?? location.url
            item.title = u.map { Settings.shared.isPinned($0) } == true ? "Unpin from Quick access" : "Pin to Quick access"
            return u != nil
        default: break
        }
        return true
    }
}

/// Toolbar-coloured background for the rows above the file view.
final class ToolbarBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.toolbar.cgColor }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
}

extension Double { var nonZero: Double? { self == 0 ? nil : self } }
extension NSFont { var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) } }
