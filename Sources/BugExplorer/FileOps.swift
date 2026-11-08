import AppKit

// MARK: - Clipboard (Finder-compatible, plus real Cut like Windows)

final class FileClipboard {
    static let shared = FileClipboard()
    private var cutURLs: Set<String> = []      // paths (folder URLs may or may not end in "/")
    private var cutChangeCount = -1

    func copy(_ urls: [URL]) { write(urls); cutURLs = []; cutChangeCount = -1; changed() }

    func cut(_ urls: [URL]) {
        write(urls)
        cutURLs = Set(urls.map(\.standardizedFileURL.path))
        cutChangeCount = NSPasteboard.general.changeCount
        changed()
    }

    /// Paths as plain text, one per line ("Copy as path").
    func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        changed()
    }

    var isCut: Bool { cutChangeCount == NSPasteboard.general.changeCount && !cutURLs.isEmpty }
    func isCut(_ url: URL) -> Bool { isCut && cutURLs.contains(url.standardizedFileURL.path) }

    var urls: [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    var canPaste: Bool { NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) }

    func paste(into dir: URL, window: NSWindow?, completion: (([URL]) -> Void)? = nil) {
        let src = urls
        guard !src.isEmpty else { return }
        let move = isCut
        FileOps.transfer(src, to: dir, move: move, window: window) { done in
            if move { self.cutURLs = []; self.cutChangeCount = -1; self.changed() }
            completion?(done)
        }
    }

    private func write(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }
    private func changed() { NotificationCenter.default.post(name: .clipboardChanged, object: nil) }
}

// MARK: - Undo (Windows lets you undo rename, move, copy, delete, new folder)

final class Undo {
    static let shared = Undo()
    struct Action { let title: String; let undo: () -> Void; let redo: () -> Void }
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []

    /// Both closures must be safe to run repeatedly (undo, redo, undo, …).
    func push(_ title: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoStack.append(Action(title: title, undo: undo, redo: redo))
        redoStack.removeAll()
        if undoStack.count > 50 { undoStack.removeFirst() }
    }
    var title: String? { undoStack.last?.title }
    var redoTitle: String? { redoStack.last?.title }
    func undo() {
        guard let a = undoStack.popLast() else { NSSound.beep(); return }
        a.undo(); redoStack.append(a)
    }
    func redo() {
        guard let a = redoStack.popLast() else { NSSound.beep(); return }
        a.redo(); undoStack.append(a)
    }
}

/// Remembers where an item currently sits in the Trash so undo/redo can go back and forth.
final class TrashSlot { var url: URL?; init(_ u: URL? = nil) { url = u } }

extension FileOps {
    /// Trash `u`, remembering where it landed.
    static func trashInto(_ slot: TrashSlot, _ u: URL) {
        var r: NSURL?
        if (try? FileManager.default.trashItem(at: u, resultingItemURL: &r)) != nil { slot.url = r as URL? }
    }
    /// Bring a trashed item back to `u`.
    static func restore(_ slot: TrashSlot, to u: URL) {
        guard let t = slot.url else { return }
        if (try? FileManager.default.moveItem(at: t, to: u)) != nil { slot.url = nil }
    }
}

// MARK: - Operations

enum ConflictChoice { case replace, skip, keepBoth, cancel }

enum FileOps {
    static func notify(_ dirs: [URL]) {
        let unique = Array(Set(dirs.map(\.standardizedFileURL)))
        NotificationCenter.default.post(name: .filesChanged, object: unique)
    }

    // MARK: New

    static func newFolder(in dir: URL, window: NSWindow?) -> URL? {
        let u = FS.uniqueName(in: dir, base: "New folder")
        do {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
            let slot = TrashSlot()
            Undo.shared.push("New Folder", undo: { trashInto(slot, u); notify([dir]) },
                             redo: { restore(slot, to: u); notify([dir]) })
            notify([dir])
            return u
        } catch { showError("Couldn't create the folder.", info: error.localizedDescription, in: window); return nil }
    }

    static func newFile(in dir: URL, base: String, ext: String, contents: String = "", window: NSWindow?) -> URL? {
        let u = FS.uniqueName(in: dir, base: base, ext: ext)
        if FileManager.default.createFile(atPath: u.path, contents: contents.data(using: .utf8)) {
            let slot = TrashSlot()
            Undo.shared.push("New File", undo: { trashInto(slot, u); notify([dir]) },
                             redo: { restore(slot, to: u); notify([dir]) })
            notify([dir])
            return u
        }
        showError("Couldn't create the file.", in: window)
        return nil
    }

    // MARK: Rename

    @discardableResult
    static func rename(_ url: URL, to newName: String, window: NSWindow?) -> URL? {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent else { return nil }
        if name.contains("/") || name.contains(":") {
            showError("A file name can't contain any of the following characters:", info: "/  :", in: window)
            return nil
        }
        let dst = url.deletingLastPathComponent().appendingPathComponent(name)
        // Case-only renames are allowed on case-insensitive disks.
        if FS.exists(dst) && dst.path.lowercased() != url.path.lowercased() {
            showError("There is already a file with the same name in this location.", info: name, in: window)
            return nil
        }
        do {
            try FileManager.default.moveItem(at: url, to: dst)
            Icons.forget(url)
            Undo.shared.push("Rename",
                             undo: { try? FileManager.default.moveItem(at: dst, to: url); notify([url.deletingLastPathComponent()]) },
                             redo: { try? FileManager.default.moveItem(at: url, to: dst); notify([url.deletingLastPathComponent()]) })
            notify([url.deletingLastPathComponent()])
            return dst
        } catch {
            showError("Couldn't rename “\(url.lastPathComponent)”.", info: error.localizedDescription, in: window)
            return nil
        }
    }

    // MARK: Delete

    static func trash(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty else { return }
        var moved: [(URL, URL)] = []
        var failed: [URL] = []
        for u in urls {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: &result)
                if let r = result as URL? { moved.append((u, r)); RecycleBin.remember(r, from: u) }
            }
            catch { failed.append(u) }
        }
        if !moved.isEmpty {
            let slots = moved.map { ($0.0, TrashSlot($0.1)) }
            Undo.shared.push("Delete", undo: {
                for (orig, slot) in slots { restore(slot, to: orig) }
                notify(slots.map { $0.0.deletingLastPathComponent() })
            }, redo: {
                for (orig, slot) in slots { trashInto(slot, orig) }
                notify(slots.map { $0.0.deletingLastPathComponent() })
            })
        }
        notify(urls.map { $0.deletingLastPathComponent() })
        if !failed.isEmpty {
            // Network shares usually have no Trash: offer permanent delete, like Explorer does.
            let a = NSAlert()
            a.messageText = failed.count == 1 ? "“\(failed[0].lastPathComponent)” can't be moved to the Trash."
                                              : "\(failed.count) items can't be moved to the Trash."
            a.informativeText = "Do you want to permanently delete \(failed.count == 1 ? "it" : "them")? This can't be undone."
            a.addButton(withTitle: "Delete Permanently")
            a.addButton(withTitle: "Cancel")
            a.alertStyle = .critical
            if a.runModal() == .alertFirstButtonReturn { deletePermanently(failed, window: window, confirm: false) }
        }
    }

    static func deletePermanently(_ urls: [URL], window: NSWindow?, confirm: Bool = true) {
        guard !urls.isEmpty else { return }
        if confirm {
            let a = NSAlert()
            a.messageText = urls.count == 1 ? "Are you sure you want to permanently delete “\(urls[0].lastPathComponent)”?"
                                            : "Are you sure you want to permanently delete these \(urls.count) items?"
            a.informativeText = "This can't be undone."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            a.alertStyle = .critical
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        for u in urls {
            do { try FileManager.default.removeItem(at: u) }
            catch { showError("Couldn't delete “\(u.lastPathComponent)”.", info: error.localizedDescription, in: window) }
        }
        notify(urls.map { $0.deletingLastPathComponent() })
    }

    // MARK: Copy / move with progress and conflict handling

    /// Copies or moves `sources` into `dir`. Copying into the item's own folder makes "name - Copy".
    static func transfer(_ sources: [URL], to dir: URL, move: Bool, window: NSWindow?, done: (([URL]) -> Void)? = nil) {
        let fm = FileManager.default
        // Plan: decide destination names (and ask about conflicts) up front on the main thread.
        var plan: [(src: URL, dst: URL, replace: Bool)] = []
        var applyAll: ConflictChoice?
        for src in sources {
            // Compare real file identity, not path text: one folder can be spelled several ways
            // (symlinks, "//", different capitalisation). Getting this wrong would offer to
            // "replace" a file with itself, which trashes the original.
            let sameFolder = FS.sameItem(src.deletingLastPathComponent(), dir)
            if sameFolder {
                if move { continue }                         // moving onto itself does nothing
                plan.append((src, FS.copyName(for: src, in: dir), false)); continue
            }
            if FS.isInside(dir, src) {
                showError("The destination folder is a subfolder of the source folder.", info: src.lastPathComponent, in: window)
                continue
            }
            var dst = dir.appendingPathComponent(src.lastPathComponent)
            var replace = false
            if FS.sameItem(src, dst) {                        // belt and braces: never replace a file with itself
                if move { continue }
                plan.append((src, FS.copyName(for: src, in: dir), false)); continue
            }
            if fm.fileExists(atPath: dst.path) {
                let choice = applyAll ?? askConflict(name: src.lastPathComponent, dir: dir, remaining: sources.count > 1, window: window) { applyAll = $0 }
                switch choice {
                case .cancel: return
                case .skip: continue
                case .keepBoth: dst = FS.keepBothName(for: src.lastPathComponent, in: dir)
                case .replace: replace = true
                }
            }
            plan.append((src, dst, replace))
        }
        guard !plan.isEmpty else { return }

        let progress = ProgressWindow(title: move ? "Moving \(Fmt.items(plan.count))" : "Copying \(Fmt.items(plan.count))",
                                      detail: "to \(FS.displayName(dir))", total: plan.count)
        let showTimer = DispatchWorkItem { progress.show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: showTimer)

        DispatchQueue.global(qos: .userInitiated).async {
            var finished: [(URL, URL)] = []
            var errors: [String] = []
            // Byte totals let the dialog show "X of Y", speed and time left. Only measured for local
            // sources: walking a network folder twice (once to measure, once to copy) isn't worth it.
            let sizes: [Int64]? = plan.contains { FS.isNetwork($0.src) } ? nil : plan.map { CopyEngine.size(of: $0.src) }
            let total = sizes?.reduce(0, +)
            let meter = CopyMeter(total: total)
            if let total { DispatchQueue.main.async { progress.setTotalBytes(total) } }
            for (i, step) in plan.enumerated() {
                if progress.cancelled { break }
                DispatchQueue.main.async { progress.update(index: i, name: step.src.lastPathComponent) }
                var reported: Int64 = 0
                let report: (Int64) -> Bool = { bytes in
                    reported += bytes
                    meter.add(bytes) { done, rate in DispatchQueue.main.async { progress.update(bytes: done, rate: rate) } }
                    return !progress.cancelled
                }
                do {
                    if step.replace {
                        guard !FS.sameItem(step.src, step.dst) else { continue }
                        try fm.trashItem(at: step.dst, resultingItemURL: nil)
                    }
                    if move && FS.sameVolume(step.src, dir) {
                        try fm.moveItem(at: step.src, to: step.dst)          // same disk: instant rename
                        meter.add(sizes?[i] ?? 0) { d, r in DispatchQueue.main.async { progress.update(bytes: d, rate: r) } }
                    } else {
                        // Other disk (or a copy): real copy with byte progress; a move then removes the original.
                        try CopyEngine.copy(step.src, to: step.dst, progress: report)
                        // Clones (same APFS disk) copy no bytes: count the item as done in one go.
                        if let expected = sizes?[i], expected > reported { _ = report(expected - reported) }
                        if move { try fm.removeItem(at: step.src) }
                    }
                    finished.append((step.src, step.dst))
                } catch {
                    errors.append("\(step.src.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                showTimer.cancel()
                progress.close()
                if !finished.isEmpty {
                    let dirs = finished.flatMap { [$0.0.deletingLastPathComponent(), $0.1.deletingLastPathComponent()] }
                    let slots = finished.map { ($0.0, $0.1, TrashSlot()) }
                    Undo.shared.push(move ? "Move" : "Copy", undo: {
                        for (s, d, slot) in slots {
                            if move { try? fm.moveItem(at: d, to: s) } else { trashInto(slot, d) }
                        }
                        notify(dirs)
                    }, redo: {
                        for (s, d, slot) in slots {
                            if move { try? fm.moveItem(at: s, to: d) } else { restore(slot, to: d) }
                        }
                        notify(dirs)
                    })
                }
                notify([dir] + plan.map { $0.src.deletingLastPathComponent() })
                if !errors.isEmpty {
                    showError("Some items couldn't be \(move ? "moved" : "copied").", info: errors.prefix(8).joined(separator: "\n"), in: window)
                }
                done?(finished.map(\.1))
            }
        }
    }

    private static func askConflict(name: String, dir: URL, remaining: Bool, window: NSWindow?, setAll: (ConflictChoice) -> Void) -> ConflictChoice {
        let a = NSAlert()
        a.messageText = "Replace or Skip Files"
        a.informativeText = "The destination “\(FS.displayName(dir))” already has an item named “\(name)”."
        a.addButton(withTitle: "Replace the file in the destination")
        a.addButton(withTitle: "Skip this file")
        a.addButton(withTitle: "Keep both")
        a.addButton(withTitle: "Cancel")
        if remaining {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Do this for all conflicts"
        }
        let r = a.runModal()
        let choice: ConflictChoice
        switch r {
        case .alertFirstButtonReturn: choice = .replace
        case .alertSecondButtonReturn: choice = .skip
        case .alertThirdButtonReturn: choice = .keepBoth
        default: choice = .cancel
        }
        if a.suppressionButton?.state == .on && choice != .cancel { setAll(choice) }
        return choice
    }

    // MARK: Zip

    static func compress(_ urls: [URL], window: NSWindow?) {
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        let base = urls.count == 1 ? (first.deletingPathExtension().lastPathComponent) : "Archive"
        let dst = FS.uniqueName(in: dir, base: base, ext: "zip")
        let p = Process()
        p.currentDirectoryURL = dir
        if urls.count == 1 {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dst.path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.arguments = ["-r", "-y", "-q", dst.path] + urls.map(\.lastPathComponent)
        }
        run(p, what: "compress", window: window) { notify([dir]) }
    }

    static func extract(_ zip: URL, window: NSWindow?) {
        let dir = zip.deletingLastPathComponent()
        let dst = FS.uniqueName(in: dir, base: zip.deletingPathExtension().lastPathComponent)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dst.path]
        run(p, what: "extract", window: window) { notify([dir]) }
    }

    private static func run(_ p: Process, what: String, window: NSWindow?, done: @escaping () -> Void) {
        let progress = ProgressWindow(title: what == "compress" ? "Compressing…" : "Extracting…", detail: "", total: 0)
        let showTimer = DispatchWorkItem { progress.show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: showTimer)
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                showTimer.cancel(); progress.close()
                if proc.terminationStatus != 0 { showError("Couldn't \(what) the files.", in: window) }
                done()
            }
        }
        do { try p.run() } catch { showTimer.cancel(); showError("Couldn't \(what) the files.", info: error.localizedDescription, in: window) }
    }
}

// MARK: - Copy engine (copyfile with byte progress; clones instantly on the same APFS disk)

enum CopyEngine {
    struct Cancelled: LocalizedError { var errorDescription: String? { "Cancelled" } }

    private final class Context {
        let report: (Int64) -> Bool
        var lastFileBytes: Int64 = 0
        var cancelled = false
        init(_ r: @escaping (Int64) -> Bool) { report = r }
    }

    /// Copies a file or folder. `progress` gets the number of NEW bytes since the last call and
    /// returns false to cancel. A cancelled or failed copy removes the partial destination.
    static func copy(_ src: URL, to dst: URL, progress: @escaping (Int64) -> Bool) throws {
        let ctx = Context(progress)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let cb: copyfile_callback_t = { what, stage, state, _, _, raw in
            let ctx = Unmanaged<Context>.fromOpaque(raw!).takeUnretainedValue()
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                let delta = Int64(copied) - ctx.lastFileBytes
                ctx.lastFileBytes = Int64(copied)
                if delta > 0, !ctx.report(delta) { ctx.cancelled = true; return COPYFILE_QUIT }
            } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH {
                ctx.lastFileBytes = 0
            } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START {
                ctx.lastFileBytes = 0
                if !ctx.report(0) { ctx.cancelled = true; return COPYFILE_QUIT }
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeRawPointer.self))
        let raw = Unmanaged.passUnretained(ctx).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), raw)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        let r = withExtendedLifetime(ctx) { copyfile(src.path, dst.path, state, flags) }
        if r != 0 || ctx.cancelled {
            let err = errno
            try? FileManager.default.removeItem(at: dst)
            if ctx.cancelled { throw Cancelled() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }

    /// Total bytes in a file or folder (local disks only; callers skip this for network shares).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.fileSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: keys))?.fileSize ?? 0)
        }
        return total
    }
}

/// Running byte count with a smoothed transfer rate; reports at most ~8 times a second.
final class CopyMeter {
    let total: Int64?
    private var done: Int64 = 0
    private var lastReport = Date.distantPast
    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private var rate: Double = 0
    private let lock = NSLock()
    init(total: Int64?) { self.total = total }

    func add(_ bytes: Int64, report: (Int64, Double) -> Void) {
        lock.lock(); defer { lock.unlock() }
        done += bytes
        windowBytes += bytes
        let now = Date()
        let span = now.timeIntervalSince(windowStart)
        if span >= 0.5 {
            let instant = Double(windowBytes) / span
            rate = rate == 0 ? instant : rate * 0.6 + instant * 0.4
            windowStart = now; windowBytes = 0
        }
        if now.timeIntervalSince(lastReport) >= 0.12 { lastReport = now; report(done, rate) }
    }
}

// MARK: - Progress window (Explorer's copy dialog)

final class ProgressWindow: NSObject {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let total: Int
    private(set) var cancelled = false

    init(title: String, detail: String, total: Int) {
        self.total = total
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: true)
        super.init()
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false        // stays visible while you work in other apps, like Explorer's copy dialog
        titleLabel.stringValue = title + " " + detail
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = total == 0
        bar.minValue = 0; bar.maxValue = Double(max(total, 1))
        bar.style = .bar
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(doCancel))
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.widthAnchor.constraint(equalToConstant: 384).isActive = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.widthAnchor.constraint(equalToConstant: 384).isActive = true
        let stack = NSStackView(views: [titleLabel, bar, statsLabel, detailLabel, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        bar.widthAnchor.constraint(equalToConstant: 384).isActive = true
        panel.contentView = stack
    }

    func show() { panel.center(); panel.orderFrontRegardless(); if total == 0 { bar.startAnimation(nil) } }
    private var totalBytes: Int64?
    private var currentName = ""
    private let statsLabel = NSTextField(labelWithString: "")

    func setTotalBytes(_ t: Int64) {
        totalBytes = t
        bar.maxValue = Double(max(t, 1))
        bar.doubleValue = 0
    }

    func update(index: Int, name: String) {
        currentName = name
        if totalBytes == nil { bar.doubleValue = Double(index) }
        detailLabel.stringValue = "Name: " + name
    }

    func update(bytes: Int64, rate: Double) {
        guard let total = totalBytes else { return }
        bar.doubleValue = Double(bytes)
        let pct = total > 0 ? Int(Double(bytes) / Double(total) * 100) : 0
        var parts = ["\(pct)%", "\(Fmt.size(bytes)) of \(Fmt.size(total))"]
        if rate > 1 {
            parts.append("\(Fmt.size(Int64(rate)))/s")
            let left = Double(total - bytes) / rate
            if left < 60 { let n = max(1, Int(left)); parts.append("About \(n) second\(n == 1 ? "" : "s") left") }
            else { let n = Int(left / 60) + 1; parts.append("About \(n) minute\(n == 1 ? "" : "s") left") }
        }
        statsLabel.stringValue = parts.joined(separator: "  ·  ")
    }
    func close() { panel.orderOut(nil) }
    @objc private func doCancel() { cancelled = true; detailLabel.stringValue = "Cancelling…" }
}

// MARK: - Recycle Bin (the macOS Trash)

enum RecycleBin {
    static var url: URL { FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first ?? FS.home.appendingPathComponent(".Trash") }
    static func contains(_ u: URL) -> Bool { FS.isInside(u, url) }

    /// Where things we deleted came from, so "Restore" can put them back (macOS keeps its own
    /// record private to Finder, so items deleted elsewhere can't be restored from here).
    private static let key = "trashOrigins"
    static func remember(_ inTrash: URL, from original: URL) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        d[inTrash.lastPathComponent] = original.path
        UserDefaults.standard.set(d, forKey: key)
    }
    static func origin(of item: URL) -> URL? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[item.lastPathComponent].map(URL.init(fileURLWithPath:))
    }

    static func restore(_ items: [URL], window: NSWindow?) {
        var dirs: [URL] = [url]
        var failed: [String] = []
        for it in items {
            guard let orig = origin(of: it) else { failed.append(it.lastPathComponent); continue }
            let parent = orig.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let dst = FS.exists(orig) ? FS.keepBothName(for: orig.lastPathComponent, in: parent) : orig
            do { try FileManager.default.moveItem(at: it, to: dst); dirs.append(parent) }
            catch { failed.append(it.lastPathComponent) }
        }
        FileOps.notify(dirs)
        if !failed.isEmpty {
            showError("Some items couldn't be restored.",
                      info: "File Explorer only knows the original location of items it deleted itself. Use Finder's “Put Back” for these:\n" + failed.prefix(8).joined(separator: "\n"),
                      in: window)
        }
    }

    static func empty(window: NSWindow?) {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let a = NSAlert()
        a.messageText = items.isEmpty ? "Empty the Recycle Bin?" : "Are you sure you want to permanently delete these \(items.count) items?"
        a.informativeText = "This can't be undone."
        a.addButton(withTitle: "Empty Recycle Bin")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .critical
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var failed = false
        for it in items { if (try? FileManager.default.removeItem(at: it)) == nil { failed = true } }
        if items.isEmpty || failed {
            // No direct access (or locked items): ask Finder to do it.
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
            if let err { showError("Couldn't empty the Recycle Bin.", info: "\(err[NSAppleScript.errorMessage] ?? "")", in: window) }
        }
        FileOps.notify([url])
    }
}
