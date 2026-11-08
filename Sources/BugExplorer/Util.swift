import AppKit
import UniformTypeIdentifiers

// MARK: - Notifications

extension Notification.Name {
    static let settingsChanged = Notification.Name("BugExplorer.settingsChanged")
    static let pinsChanged = Notification.Name("BugExplorer.pinsChanged")
    static let clipboardChanged = Notification.Name("BugExplorer.clipboardChanged")
    static let filesChanged = Notification.Name("BugExplorer.filesChanged")   // object: [URL] of affected folders
}

// MARK: - View modes and sorting

enum ViewMode: String, CaseIterable {
    case extraLarge, large, medium, small, list, details, tiles, content

    var title: String {
        switch self {
        case .extraLarge: return "Extra large icons"
        case .large: return "Large icons"
        case .medium: return "Medium icons"
        case .small: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        case .content: return "Content"
        }
    }
    var symbol: String {
        switch self {
        case .extraLarge: return "square"
        case .large: return "square.grid.2x2"
        case .medium: return "square.grid.3x3"
        case .small: return "square.grid.4x3.fill"
        case .list: return "list.bullet"
        case .details: return "list.bullet.rectangle"
        case .tiles: return "rectangle.grid.2x2"
        case .content: return "rectangle.grid.1x2"
        }
    }
    /// Icon edge in points.
    var iconSize: CGFloat {
        switch self {
        case .extraLarge: return 176
        case .large: return 96
        case .medium: return 48
        case .small, .list, .details: return 16
        case .tiles: return 48
        case .content: return 32
        }
    }
}

enum SortKey: String, CaseIterable {
    case name, dateModified, type, size, dateCreated, folder
    var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .dateCreated: return "Date created"
        case .folder: return "Folder"
        }
    }
}

enum GroupKey: String, CaseIterable {
    case none, type, dateModified, name
    var title: String {
        switch self {
        case .none: return "(None)"
        case .type: return "Type"
        case .dateModified: return "Date modified"
        case .name: return "Name"
        }
    }
}

struct FolderViewState: Codable, Equatable {
    var mode: String = ViewMode.details.rawValue
    var sort: String = SortKey.name.rawValue
    var ascending: Bool = true
    var group: String = GroupKey.none.rawValue
    var viewMode: ViewMode { ViewMode(rawValue: mode) ?? .details }
    var sortKey: SortKey { SortKey(rawValue: sort) ?? .name }
    var groupKey: GroupKey { GroupKey(rawValue: group) ?? .none }
}

enum SidePane: String { case none, details, preview }

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var showHidden: Bool {
        get { d.bool(forKey: "showHidden") }
        set { d.set(newValue, forKey: "showHidden"); changed() }
    }
    var showExtensions: Bool {
        get { d.object(forKey: "showExtensions") as? Bool ?? true }
        set { d.set(newValue, forKey: "showExtensions"); changed() }
    }
    var showNavPane: Bool {
        get { d.object(forKey: "showNavPane") as? Bool ?? true }
        set { d.set(newValue, forKey: "showNavPane"); changed() }
    }
    var sidePane: SidePane {
        get { SidePane(rawValue: d.string(forKey: "sidePane") ?? "") ?? .none }
        set { d.set(newValue.rawValue, forKey: "sidePane"); changed() }
    }
    var itemCheckBoxes: Bool {
        get { d.bool(forKey: "itemCheckBoxes") }
        set { d.set(newValue, forKey: "itemCheckBoxes"); changed() }
    }

    /// Pinned folders in the navigation pane ("Quick access").
    var pinned: [URL] {
        get {
            if let paths = d.stringArray(forKey: "pinned") { return paths.map { URL(fileURLWithPath: $0) } }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return ["Desktop", "Downloads", "Documents", "Pictures", "Music", "Movies"].map { home.appendingPathComponent($0) }
        }
        set { d.set(newValue.map(\.path), forKey: "pinned"); NotificationCenter.default.post(name: .pinsChanged, object: nil) }
    }
    func isPinned(_ url: URL) -> Bool { pinned.contains { $0.standardizedFileURL == url.standardizedFileURL } }
    func togglePin(_ url: URL) {
        if isPinned(url) { pinned.removeAll { $0.standardizedFileURL == url.standardizedFileURL } }
        else { pinned.append(url) }
    }

    /// Per-folder view, sort and grouping (Windows remembers these per folder).
    func viewState(for url: URL?) -> FolderViewState {
        let key = url?.standardizedFileURL.path ?? "~search"
        if let data = (d.dictionary(forKey: "folderViews") as? [String: Data])?[key],
           let s = try? JSONDecoder().decode(FolderViewState.self, from: data) { return s }
        return defaultViewState
    }
    func setViewState(_ s: FolderViewState, for url: URL?) {
        let key = url?.standardizedFileURL.path ?? "~search"
        var all = (d.dictionary(forKey: "folderViews") as? [String: Data]) ?? [:]
        all[key] = try? JSONEncoder().encode(s)
        d.set(all, forKey: "folderViews")
    }
    var defaultViewState: FolderViewState {
        get {
            if let data = d.data(forKey: "defaultView"), let s = try? JSONDecoder().decode(FolderViewState.self, from: data) { return s }
            return FolderViewState()
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "defaultView") }
    }

    var savedTabs: [String] {
        get { d.stringArray(forKey: "savedTabs") ?? [] }
        set { d.set(newValue, forKey: "savedTabs") }
    }

    private func changed() { NotificationCenter.default.post(name: .settingsChanged, object: nil) }
}

// MARK: - File system helpers

enum FS {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Network volumes (SMB/AFP/NFS) are never crawled: no recursive search, no automatic folder sizes.
    static func isNetwork(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        if let local = v?.volumeIsLocal { return !local }
        return url.path.hasPrefix("/Volumes/") && !isLocalVolumePath(url)
    }
    private static func isLocalVolumePath(_ url: URL) -> Bool {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return false }
        return (Int32(st.f_flags) & MNT_LOCAL) != 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// True when two URLs point at the same file or folder on disk (handles symlinks, "//", case).
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        let k: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let ia = (try? a.resourceValues(forKeys: k))?.fileResourceIdentifier as? NSObject,
           let ib = (try? b.resourceValues(forKeys: k))?.fileResourceIdentifier as? NSObject {
            return ia.isEqual(ib)
        }
        return canonical(a) == canonical(b)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let va, let vb else { return false }
        return va.isEqual(vb)
    }

    /// True when `inner` is `outer` itself or somewhere inside it.
    static func isInside(_ inner: URL, _ outer: URL) -> Bool {
        if sameItem(inner, outer) { return true }
        let i = canonical(inner), o = canonical(outer)
        return i.hasPrefix(o.hasSuffix("/") ? o : o + "/")
    }

    /// Same file by path (cheap check first, then with shortcuts like /tmp → /private/tmp resolved).
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.path == b.path || canonical(a) == canonical(b)
    }

    static func canonical(_ u: URL) -> String {
        URL(fileURLWithPath: u.path.replacingOccurrences(of: "//", with: "/")).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Display name used everywhere (Windows-style: "Macintosh HD", "Desktop", …).
    static func displayName(_ url: URL) -> String {
        if url.path == "/" { return volumeName(url) }
        return FileManager.default.displayName(atPath: url.path)
    }
    static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    }

    /// Resolve whatever the user typed in the address bar.
    static func resolve(typed raw: String, relativeTo base: URL?) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("file://"), let u = URL(string: s) { return u }
        // Undo shell escaping ("My\ Folder") that people paste from Terminal.
        if s.contains("\\ ") { s = s.replacingOccurrences(of: "\\ ", with: " ") }
        if s.isEmpty { return nil }
        let lower = s.lowercased()
        let shortcuts: [String: URL] = [
            "desktop": home.appendingPathComponent("Desktop"),
            "downloads": home.appendingPathComponent("Downloads"),
            "documents": home.appendingPathComponent("Documents"),
            "pictures": home.appendingPathComponent("Pictures"),
            "music": home.appendingPathComponent("Music"),
            "movies": home.appendingPathComponent("Movies"),
            "videos": home.appendingPathComponent("Movies"),
            "applications": URL(fileURLWithPath: "/Applications"),
            "trash": home.appendingPathComponent(".Trash"),
            "recycle bin": home.appendingPathComponent(".Trash"),
        ]
        if let u = shortcuts[lower] { return u }
        s = (s as NSString).expandingTildeInPath
        if s.hasPrefix("/") { return URL(fileURLWithPath: s).standardizedFileURL }
        if let base { return base.appendingPathComponent(s).standardizedFileURL }
        return nil
    }

    /// "New folder", "New folder (2)", … like Windows.
    static func uniqueName(in dir: URL, base: String, ext: String = "") -> URL {
        let dot = ext.isEmpty ? "" : "." + ext
        var u = dir.appendingPathComponent(base + dot)
        var n = 2
        while exists(u) { u = dir.appendingPathComponent("\(base) (\(n))\(dot)"); n += 1 }
        return u
    }

    /// "report - Copy.txt", "report - Copy (2).txt" for pasting into the same folder.
    static func copyName(for src: URL, in dir: URL) -> URL {
        let ext = src.pathExtension
        let stem = ext.isEmpty || FS.isDirectory(src) ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent
        let dot = (ext.isEmpty || FS.isDirectory(src)) ? "" : "." + ext
        var u = dir.appendingPathComponent("\(stem) - Copy\(dot)")
        var n = 2
        while exists(u) { u = dir.appendingPathComponent("\(stem) - Copy (\(n))\(dot)"); n += 1 }
        return u
    }

    /// "report (2).txt" for "Keep both".
    static func keepBothName(for name: String, in dir: URL) -> URL {
        let ns = name as NSString
        let ext = ns.pathExtension, stem = ext.isEmpty ? name : ns.deletingPathExtension
        let dot = ext.isEmpty ? "" : "." + ext
        var n = 2
        var u = dir.appendingPathComponent("\(stem) (\(n))\(dot)")
        while exists(u) { n += 1; u = dir.appendingPathComponent("\(stem) (\(n))\(dot)") }
        return u
    }

    static func appsToOpen(_ url: URL) -> [URL] {
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let def = NSWorkspace.shared.urlForApplication(toOpen: url) {
            apps.removeAll { $0 == def }
            apps.insert(def, at: 0)
        }
        var seen = Set<String>()
        return apps.filter { seen.insert($0.lastPathComponent).inserted }
    }
}

// MARK: - Formatting (Windows conventions)

enum Fmt {
    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()
    static let longDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .medium; return f
    }()
    static let group: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()

    /// Details-view size column: always KB, rounded up, like Explorer ("1,234 KB").
    static func kb(_ bytes: Int64) -> String {
        let k = bytes == 0 ? 0 : max(1, (bytes + 1023) / 1024)
        return (group.string(from: NSNumber(value: k)) ?? "\(k)") + " KB"
    }
    /// Status bar / properties: "1.20 MB".
    static func size(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(bytes), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(bytes) bytes" }
        let digits = v < 10 ? 2 : (v < 100 ? 1 : 0)
        return String(format: "%.\(digits)f %@", v, units[i])
    }
    static func exactSize(_ bytes: Int64) -> String {
        "\(size(bytes)) (\(group.string(from: NSNumber(value: bytes)) ?? "\(bytes)") bytes)"
    }
    static func date(_ d: Date?) -> String { d.map { dateTime.string(from: $0) } ?? "" }
    static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(group.string(from: NSNumber(value: n)) ?? "\(n)") items" }
}

// MARK: - Small UI helpers

func symbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    return img?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

func menuItem(_ title: String, _ symbolName: String? = nil, key: String = "", mods: NSEvent.ModifierFlags = [.command],
              target: AnyObject? = nil, action: Selector? = nil, _ handler: (() -> Void)? = nil) -> NSMenuItem {
    let item = ClosureMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = mods
    item.target = target
    if let symbolName { item.image = symbol(symbolName, size: 13) }
    if let handler { item.handler = handler; item.target = item; item.action = #selector(ClosureMenuItem.fire) }
    return item
}

final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

extension NSView {
    func pin(to v: NSView, insets: NSEdgeInsets = .init()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: v.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

func showError(_ message: String, info: String = "", in window: NSWindow?) {
    let a = NSAlert()
    a.messageText = message
    a.informativeText = info
    a.alertStyle = .warning
    if let window { a.beginSheetModal(for: window) } else { a.runModal() }
}

/// Plain flipped container so subviews lay out top-down.
class FlippedView: NSView { override var isFlipped: Bool { true } }

