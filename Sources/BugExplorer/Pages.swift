import AppKit
import BugOSKit

/// Clickable tile/row used on the Home and This Mac pages.
final class PageTile: NSView {
    let url: URL
    var onOpen: ((URL) -> Void)?
    var onSelect: ((PageTile) -> Void)?
    var menuProvider: ((URL) -> NSMenu?)?
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        if isSelected {
            BugOSColor.accent.withAlphaComponent(0.22).setFill()
        } else if hovering { Theme.hover.setFill() } else { return }
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) {
        onSelect?(self)
        if e.clickCount == 2 { onOpen?(url) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { onSelect?(self); return menuProvider?(url) }

    // Pass clicks on labels/images through to the tile.
    override func hitTest(_ p: NSPoint) -> NSView? { frame.contains(p) ? self : nil }
}

class PageView: FlippedView {
    override var acceptsFirstResponder: Bool { true }
    var onOpen: ((URL) -> Void)?
    var onSelectionChange: (([URL]) -> Void)?
    var menuProvider: ((URL) -> NSMenu?)?
    var tiles: [PageTile] = []
    let scroll = NSScrollView()
    let doc = FlippedView()
    var selectedURLs: [URL] { tiles.filter(\.isSelected).map(\.url) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        addSubview(scroll); scroll.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 14, weight: .semibold)
        doc.addSubview(l)
        return l
    }

    func makeTile(_ url: URL) -> PageTile {
        let t = PageTile(url: url)
        t.onOpen = { [weak self] u in self?.onOpen?(u) }
        t.onSelect = { [weak self] tile in
            guard let self else { return }
            self.tiles.forEach { $0.isSelected = $0 === tile }
            self.onSelectionChange?(self.selectedURLs)
        }
        t.menuProvider = { [weak self] u in self?.menuProvider?(u) }
        tiles.append(t)
        doc.addSubview(t)
        return t
    }

    override func mouseDown(with e: NSEvent) {
        tiles.forEach { $0.isSelected = false }
        onSelectionChange?([])
    }
}

// MARK: - Home

final class HomePage: PageView {
    private var recent: [URL] = []
    private var query: NSMetadataQuery?
    private var quickHeader: NSTextField!
    private var recentHeader: NSTextField!
    private var recentTiles: [PageTile] = []
    private var quickTiles: [PageTile] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        startRecent()
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged), name: .pinsChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { query?.stop(); NotificationCenter.default.removeObserver(self) }

    @objc private func pinsChanged() { build() }

    private func build() {
        doc.subviews.forEach { $0.removeFromSuperview() }
        tiles = []
        quickHeader = header("Quick access")
        quickTiles = Settings.shared.pinned.filter(FS.exists).map { u in
            let t = makeTile(u)
            let iv = NSImageView(image: Icons.icon(for: u, size: 48))
            iv.frame = NSRect(x: 10, y: 10, width: 48, height: 48)
            let name = NSTextField(labelWithString: FS.displayName(u))
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: 66, y: 14, width: 150, height: 18)
            let sub = NSTextField(labelWithString: u.path.replacingOccurrences(of: FS.home.path, with: "~"))
            sub.font = .systemFont(ofSize: 11.5)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingMiddle
            sub.frame = NSRect(x: 66, y: 34, width: 128, height: 16)
            let pin = NSImageView(image: symbol("pin.fill", size: 9) ?? NSImage())
            pin.contentTintColor = .tertiaryLabelColor
            pin.frame = NSRect(x: 198, y: 36, width: 12, height: 12)
            [iv, name, sub, pin].forEach(t.addSubview)
            return t
        }
        recentHeader = header("Recent")
        buildRecentRows()
        needsLayout = true
    }

    private func buildRecentRows() {
        recentTiles.forEach { t in t.removeFromSuperview(); tiles.removeAll { $0 === t } }
        recentTiles = recent.prefix(40).map { u in
            let t = makeTile(u)
            let iv = NSImageView(image: Icons.icon(for: u, size: 16)); iv.frame = NSRect(x: 8, y: 5, width: 16, height: 16)
            let name = NSTextField(labelWithString: u.lastPathComponent); name.lineBreakMode = .byTruncatingTail; name.tag = 1
            let date = NSTextField(labelWithString: Fmt.date((try? u.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate))
            date.textColor = .secondaryLabelColor; date.tag = 2
            let loc = NSTextField(labelWithString: u.deletingLastPathComponent().path.replacingOccurrences(of: FS.home.path, with: "~"))
            loc.textColor = .secondaryLabelColor; loc.lineBreakMode = .byTruncatingMiddle; loc.tag = 3
            for f in [name, date, loc] { f.font = .systemFont(ofSize: 12.5) }
            [iv, name, date, loc].forEach(t.addSubview)
            return t
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = max(bounds.width, 400)
        var y: CGFloat = 16
        quickHeader.frame = NSRect(x: 20, y: y, width: 300, height: 20); y += 30
        let tileW: CGFloat = 222, tileH: CGFloat = 68
        let cols = max(1, Int((w - 40 + 8) / (tileW + 8)))
        for (i, t) in quickTiles.enumerated() {
            t.frame = NSRect(x: 20 + CGFloat(i % cols) * (tileW + 8), y: y + CGFloat(i / cols) * (tileH + 8), width: tileW, height: tileH)
        }
        y += CGFloat((quickTiles.count + cols - 1) / cols) * (tileH + 8) + 18
        recentHeader.frame = NSRect(x: 20, y: y, width: 300, height: 20); y += 28
        let rowW = w - 40
        for t in recentTiles {
            t.frame = NSRect(x: 20, y: y, width: rowW, height: 26)
            for case let f as NSTextField in t.subviews {
                switch f.tag {
                case 1: f.frame = NSRect(x: 32, y: 4, width: rowW * 0.38, height: 18)
                case 2: f.frame = NSRect(x: 32 + rowW * 0.40, y: 4, width: 150, height: 18)
                default: f.frame = NSRect(x: 32 + rowW * 0.40 + 160, y: 4, width: max(60, rowW - (32 + rowW * 0.40 + 170)), height: 18)
                }
            }
            y += 26
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 20, scroll.contentSize.height))
    }

    // Recently used files from Spotlight (local home folder only).
    private func startRecent() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        let since = Date().addingTimeInterval(-30 * 86400) as NSDate
        q.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@", since)
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(recentReady), name: .NSMetadataQueryDidFinishGathering, object: q)
        query = q
        q.start()
    }

    @objc private func recentReady() {
        guard let q = query else { return }
        q.stop()
        var urls: [URL] = []
        for i in 0..<min(q.resultCount, 200) {
            guard let it = q.result(at: i) as? NSMetadataItem, let p = it.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if p.contains("/Library/") || p.contains("/.") || p.hasSuffix(".app") { continue }
            let u = URL(fileURLWithPath: p)
            if FS.isDirectory(u) { continue }
            urls.append(u)
            if urls.count >= 40 { break }
        }
        recent = urls
        buildRecentRows()
    }
}

// MARK: - This Mac (drives with usage bars)

final class ThisMacPage: PageView {
    private var headers: [NSTextField] = []
    private var groups: [[PageTile]] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(rebuild), name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(rebuild), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func rebuild() { build() }

    private func build() {
        doc.subviews.forEach { $0.removeFromSuperview() }
        tiles = []; headers = []; groups = []
        let sections: [(String, [URL])] = [("Devices and drives", Places.localVolumes), ("Network locations", Places.networkVolumes)]
        for (title, vols) in sections where !vols.isEmpty {
            headers.append(header(title))
            groups.append(vols.map(driveTile))
        }
        needsLayout = true
    }

    private func driveTile(_ u: URL) -> PageTile {
        let t = makeTile(u)
        let iv = NSImageView(image: Icons.icon(for: u, size: 48)); iv.frame = NSRect(x: 10, y: 12, width: 48, height: 48)
        let name = NSTextField(labelWithString: FS.volumeName(u))
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.frame = NSRect(x: 68, y: 10, width: 220, height: 18)
        let v = try? u.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let free = v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
        let bar = UsageBar(fraction: total > 0 ? Double(total - free) / Double(total) : 0)
        bar.frame = NSRect(x: 68, y: 32, width: 220, height: 12)
        let sub = NSTextField(labelWithString: total > 0 ? "\(Fmt.size(free)) free of \(Fmt.size(total))" : "")
        sub.font = .systemFont(ofSize: 11.5); sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 68, y: 48, width: 220, height: 16)
        [iv, name, bar, sub].forEach(t.addSubview)
        return t
    }

    override func layout() {
        super.layout()
        let w = max(bounds.width, 400)
        var y: CGFloat = 16
        let tileW: CGFloat = 310, tileH: CGFloat = 74
        let cols = max(1, Int((w - 40 + 8) / (tileW + 8)))
        for (h, g) in zip(headers, groups) {
            h.frame = NSRect(x: 20, y: y, width: 300, height: 20); y += 30
            for (i, t) in g.enumerated() {
                t.frame = NSRect(x: 20 + CGFloat(i % cols) * (tileW + 8), y: y + CGFloat(i / cols) * (tileH + 8), width: tileW, height: tileH)
            }
            y += CGFloat((g.count + cols - 1) / cols) * (tileH + 8) + 18
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y, scroll.contentSize.height))
    }
}

/// Explorer's drive usage bar: accent colour, red when nearly full.
final class UsageBar: NSView {
    let fraction: Double
    init(fraction: Double) { self.fraction = fraction; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        (fraction > 0.9 ? NSColor.systemRed : BugOSColor.accent).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}
