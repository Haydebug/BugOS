import AppKit
import BugOSKit
import QuickLookThumbnailing

// MARK: - Locations

enum Location: Equatable {
    case home
    case thisMac
    case folder(URL)
    case search(URL, String)

    var url: URL? {
        switch self {
        case .folder(let u), .search(let u, _): return u
        default: return nil
        }
    }
    var title: String {
        switch self {
        case .home: return "Home"
        case .thisMac: return "This Mac"
        case .folder(let u): return FS.displayName(u)
        case .search(let u, let q): return "Search Results in \(FS.displayName(u)) for “\(q)”"
        }
    }
    var tabTitle: String {
        switch self {
        case .search(_, let q): return "\(q) - Search Results"
        default: return title
        }
    }
    var icon: NSImage {
        switch self {
        case .home: return symbol("house", size: 14) ?? NSImage()
        case .thisMac: return symbol("laptopcomputer", size: 14) ?? NSImage()
        case .search: return symbol("magnifyingglass", size: 14) ?? NSImage()
        case .folder(let u): return Icons.icon(for: u, size: 16)
        }
    }
    /// Text for the address bar in edit mode.
    var editText: String {
        switch self {
        case .home: return "Home"
        case .thisMac: return "This Mac"
        case .folder(let u), .search(let u, _): return u.path
        }
    }
    /// Restorable string form (saved tabs).
    var token: String {
        switch self {
        case .home: return "home:"
        case .thisMac: return "thismac:"
        case .folder(let u), .search(let u, _): return u.path
        }
    }
    /// Where to go when a saved place is gone (the app sets it to your "Open new windows to" place).
    static var fallback: () -> Location = { .home }

    static func from(token: String) -> Location {
        if token == "home:" { return .home }
        if token == "thismac:" { return .thisMac }
        let u = URL(fileURLWithPath: token)
        return FS.exists(u) ? .folder(u) : fallback()
    }
}

// MARK: - File items

final class FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool      // a real folder (packages like .app count as files)
    let isPackage: Bool
    let size: Int64
    let modified: Date?
    let created: Date?
    let typeName: String
    let isHidden: Bool
    let isSymlink: Bool
    let isApp: Bool
    /// Parent folder, shown in search results.
    var folder: URL { url.deletingLastPathComponent() }

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                         .creationDateKey, .localizedTypeDescriptionKey, .isHiddenKey, .isSymbolicLinkKey,
                                         .localizedNameKey, .isApplicationKey]

    init(url: URL) {
        self.url = url
        let v = try? url.resourceValues(forKeys: Set(FileItem.keys))
        isPackage = v?.isPackage ?? false
        isDirectory = (v?.isDirectory ?? false) && !isPackage
        size = Int64(v?.fileSize ?? 0)
        modified = v?.contentModificationDate
        created = v?.creationDate
        typeName = isDirectory ? "File folder" : (v?.localizedTypeDescription ?? "File")
        isHidden = (v?.isHidden ?? false) || url.lastPathComponent.hasPrefix(".")
        isSymlink = v?.isSymbolicLink ?? false
        isApp = v?.isApplication ?? false
        name = url.lastPathComponent
    }

    /// Name as shown, honouring "File name extensions".
    var displayName: String {
        if Settings.shared.showExtensions || isDirectory { return name }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    func icon(size: CGFloat) -> NSImage { Icons.icon(for: url, size: size) }

    static func == (a: FileItem, b: FileItem) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

// MARK: - Icons and thumbnails

enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL, size: CGFloat) -> NSImage {
        let key = "\(url.path)|\(Int(size))" as NSString
        if let i = cache.object(forKey: key) { return i }
        // On a network share, asking for a folder's icon makes macOS look inside the folder (for a
        // custom icon), which can mount Windows junctions one by one. Use the stock folder icon there.
        let img: NSImage
        if url.path.hasPrefix("/Volumes/"), FS.isNetwork(url), FS.isDirectory(url), !isVolumeRoot(url) {
            img = NSWorkspace.shared.icon(for: .folder)
        } else if let app = windowsStyleIcon(for: url) {
            img = app
        } else {
            img = NSWorkspace.shared.icon(forFile: url.path)
        }
        img.size = NSSize(width: size, height: size)
        cache.setObject(img, forKey: key)
        return img
    }

    /// Windows-style file icons (BugOS › File Explorer › File icons, the default): a file shows the icon of the
    /// app that opens it, like Explorer, instead of macOS 26's blank page with a tiny badge. Folders, apps
    /// and other packages, and files nothing opens, keep their own icon. Looked up once per file type.
    private static let appIconByType = NSCache<NSString, NSImage>()
    private static var noAppTypes = Set<String>()
    static var windowsStyle: Bool { UserDefaults.standard.string(forKey: ExplorerSetting.fileIcons) != "mac" }

    private static func windowsStyleIcon(for url: URL) -> NSImage? {
        guard windowsStyle else { return nil }
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey, .isAliasFileKey])
        if v?.isDirectory == true || v?.isPackage == true || v?.isAliasFile == true { return nil }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        let key = ext as NSString
        if let i = appIconByType.object(forKey: key) { return i.copy() as? NSImage }
        if noAppTypes.contains(ext) { return nil }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { noAppTypes.insert(ext); return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        appIconByType.setObject(icon, forKey: key)
        return icon.copy() as? NSImage
    }

    /// The File icons setting changed: draw everything again.
    static func reset() {
        cache.removeAllObjects()
        appIconByType.removeAllObjects()
        noAppTypes = []
    }

    private static func isVolumeRoot(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
    }

    static func forget(_ url: URL) {
        for s in [16, 32, 48, 64, 96, 128, 176, 256] { cache.removeObject(forKey: "\(url.path)|\(s)" as NSString) }
        Thumbs.forget(url)
    }
}

/// Quick Look thumbnails for images, videos, PDFs etc. at medium sizes and up.
enum Thumbs {
    private static let cache = NSCache<NSString, NSImage>()
    private static var pending = Set<String>()
    private static let lock = NSLock()

    static func key(_ url: URL, _ size: CGFloat) -> NSString { "\(url.path)|\(Int(size))" as NSString }

    static func cached(_ url: URL, size: CGFloat) -> NSImage? { cache.object(forKey: key(url, size)) }

    static func forget(_ url: URL) {
        for s in [32, 48, 96, 176, 256] { cache.removeObject(forKey: key(url, CGFloat(s))) }
    }

    /// Calls back on the main thread only when a real thumbnail (not just an icon) was made.
    static func request(_ url: URL, size: CGFloat, done: @escaping (NSImage) -> Void) {
        let k = key(url, size) as String
        lock.lock()
        if pending.contains(k) { lock.unlock(); return }
        pending.insert(k); lock.unlock()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            lock.lock(); pending.remove(k); lock.unlock()
            guard let rep, rep.type == .thumbnail else { return }
            let img = rep.nsImage
            DispatchQueue.main.async {
                cache.setObject(img, forKey: k as NSString)
                done(img)
            }
        }
    }

    /// Worth asking Quick Look for a picture of this file?
    static func wants(_ item: FileItem) -> Bool {
        if item.isDirectory || item.isApp { return false }
        // Don't pull big files over the network just to draw a thumbnail.
        if item.size > 20_000_000, item.url.path.hasPrefix("/Volumes/"), FS.isNetwork(item.url) { return false }
        let ext = item.url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "psd", "svg", "ico", "icns",
                "pdf", "mp4", "mov", "m4v", "avi", "mkv", "webm", "raw", "cr2", "nef", "dng", "arw", "key", "pages",
                "numbers", "blend", "fbx", "obj", "usdz", "rbxm"].contains(ext)
    }
}

// MARK: - Directory model

/// Loads a folder in the background, keeps it fresh while it's open, and applies filter/sort/group.
final class DirectoryModel {
    let url: URL
    private(set) var all: [FileItem] = []
    private(set) var items: [FileItem] = []
    private(set) var groups: [(title: String, items: [FileItem])] = []
    private(set) var loaded = false
    private(set) var error: String?
    var filter = "" { didSet { apply() } }
    var state: FolderViewState { didSet { apply() } }
    var onChange: (() -> Void)?

    private var watcher: DispatchSourceFileSystemObject?
    private var generation = 0
    private var reloadPending = false

    init(url: URL) {
        self.url = url
        state = Settings.shared.viewState(for: url)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(filesChanged(_:)), name: .filesChanged, object: nil)
    }

    deinit { watcher?.cancel(); NotificationCenter.default.removeObserver(self) }

    @objc private func settingsChanged() { apply() }
    @objc private func filesChanged(_ n: Notification) {
        guard let dirs = n.object as? [URL] else { reload(); return }
        if dirs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { scheduleReload() }
    }

    func load() {
        generation += 1
        let gen = generation, url = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var err: String?
            var list: [FileItem] = []
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.keys, options: [])
                list = urls.map(FileItem.init)
            } catch {
                err = (error as NSError).localizedDescription
            }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.all = list
                self.error = err
                self.loaded = true
                self.apply()
                self.startWatching()
            }
        }
    }

    func reload() { load() }

    private func scheduleReload() {
        if reloadPending { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func apply() {
        let showHidden = Settings.shared.showHidden
        var list = all.filter { showHidden || !$0.isHidden }
        if !filter.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        items = DirectoryModel.sorted(list, state)
        groups = DirectoryModel.grouped(items, state.groupKey)
        onChange?()
    }

    static func sorted(_ list: [FileItem], _ s: FolderViewState) -> [FileItem] {
        let asc = s.ascending
        func cmpName(_ a: FileItem, _ b: FileItem) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let sorted = list.sorted { a, b in
            // Explorer keeps folders together at the top when sorting by name/type/size.
            if s.sortKey != .dateModified && s.sortKey != .dateCreated, a.isDirectory != b.isDirectory {
                return a.isDirectory == asc
            }
            let r: ComparisonResult
            switch s.sortKey {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .type: r = a.typeName.localizedStandardCompare(b.typeName)
            case .size: r = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .dateModified: r = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case .dateCreated: r = (a.created ?? .distantPast).compare(b.created ?? .distantPast)
            case .folder: r = a.folder.path.localizedStandardCompare(b.folder.path)
            }
            if r == .orderedSame { return cmpName(a, b) }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
        return sorted
    }

    static func grouped(_ items: [FileItem], _ key: GroupKey) -> [(title: String, items: [FileItem])] {
        guard key != .none else { return [] }
        var order: [String] = []
        var map: [String: [FileItem]] = [:]
        let cal = Calendar.current
        for it in items {
            let g: String
            switch key {
            case .none: g = ""
            case .type: g = it.typeName
            case .name:
                let c = it.name.prefix(1).uppercased()
                g = c.rangeOfCharacter(from: .letters) != nil ? c : "#"
            case .dateModified:
                guard let d = it.modified else { g = "A long time ago"; break }
                if cal.isDateInToday(d) { g = "Today" }
                else if cal.isDateInYesterday(d) { g = "Yesterday" }
                else if cal.isDate(d, equalTo: Date(), toGranularity: .weekOfYear) { g = "Earlier this week" }
                else if let w = cal.date(byAdding: .weekOfYear, value: -1, to: Date()), cal.isDate(d, equalTo: w, toGranularity: .weekOfYear) { g = "Last week" }
                else if cal.isDate(d, equalTo: Date(), toGranularity: .month) { g = "Earlier this month" }
                else if let m = cal.date(byAdding: .month, value: -1, to: Date()), cal.isDate(d, equalTo: m, toGranularity: .month) { g = "Last month" }
                else if cal.isDate(d, equalTo: Date(), toGranularity: .year) { g = "Earlier this year" }
                else { g = "A long time ago" }
            }
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(it)
        }
        return order.map { ($0, map[$0]!) }
    }
}

// MARK: - Search

/// Recursive name search under a folder. Uses Spotlight on local disks; on network volumes it only
/// searches the current folder (never crawls a network share).
final class SearchModel {
    let root: URL
    let query: String
    private(set) var items: [FileItem] = []
    var onChange: (() -> Void)?
    private(set) var finished = false
    private var mdq: NSMetadataQuery?
    private var cancelled = false

    init(root: URL, query: String) { self.root = root; self.query = query }

    func start() {
        if FS.isNetwork(root) {
            let q = query
            DispatchQueue.global().async { [weak self, root] in
                let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: FileItem.keys)) ?? []
                let hits = urls.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(q) }.map(FileItem.init)
                DispatchQueue.main.async { self?.items = hits; self?.finished = true; self?.onChange?() }
            }
            return
        }
        let q = NSMetadataQuery()
        q.searchScopes = [root]
        q.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, query)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .NSMetadataQueryDidUpdate, object: q)
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: q)
        mdq = q
        q.start()
    }

    func stop() {
        cancelled = true
        mdq?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func update() { collect() }
    @objc private func gathered() { finished = true; collect() }

    private func collect() {
        guard let q = mdq, !cancelled else { return }
        q.disableUpdates()
        var urls: [URL] = []
        for i in 0..<min(q.resultCount, 5000) {
            if let it = q.result(at: i) as? NSMetadataItem, let p = it.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.append(URL(fileURLWithPath: p))
            }
        }
        q.enableUpdates()
        DispatchQueue.global().async { [weak self] in
            let list = urls.map(FileItem.init)
            DispatchQueue.main.async { self?.items = list; self?.onChange?() }
        }
    }
}
