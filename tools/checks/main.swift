// BugExplorer checks: compiled together with the app's Util/Model/FileOps sources by tools/run-checks.sh.
// Exercises the real file-operation code against a scratch folder and reports PASS/FAIL per check.
import AppKit

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])        // scratch folder (wiped and recreated)
let shots = URL(fileURLWithPath: args[2])       // where UI screenshots go
let bigVolume = args.count > 3 ? URL(fileURLWithPath: args[3]) : nil   // a second volume for the progress test
let fm = FileManager.default
var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail))
    if !ok { failures += 1 }
}
func spin(_ secs: Double = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: secs)) }
func waitFor(_ timeout: Double, _ cond: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while Date() < end { if cond() { return true }; spin() }
    return cond()
}
func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
/// Screenshot of one of our own windows only (never the rest of the screen).
func shot(_ name: String, window: NSWindow?) {
    guard let window else { print("  (no window to capture for \(name))"); return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", shots.appendingPathComponent(name).path]; try? p.run(); p.waitUntilExit()
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
NSApp.finishLaunching()

func runChecks() {
try? fm.removeItem(at: root)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
try! fm.createDirectory(at: a, withIntermediateDirectories: true)
try! fm.createDirectory(at: b, withIntermediateDirectories: true)

// MARK: Formatting and address-bar parsing
check("kb 0", Fmt.kb(0) == "0 KB", Fmt.kb(0))
check("kb 1 byte rounds up", Fmt.kb(1) == "1 KB", Fmt.kb(1))
check("kb grouping", Fmt.kb(1_263_000) == "1,234 KB", Fmt.kb(1_263_000))
check("size MB", Fmt.size(1_258_291) == "1.20 MB", Fmt.size(1_258_291))
let home = FS.home.path
check("resolve ~", FS.resolve(typed: "~/Desktop", relativeTo: nil)?.path == home + "/Desktop")
check("resolve quoted", FS.resolve(typed: "\"/tmp\"", relativeTo: nil)?.path == "/tmp")
check("resolve shell-escaped", FS.resolve(typed: "/Users/x/My\\ Folder", relativeTo: nil)?.path == "/Users/x/My Folder")
check("resolve shortcut", FS.resolve(typed: "Downloads", relativeTo: nil)?.path == home + "/Downloads")
check("resolve file URL", FS.resolve(typed: "file:///tmp/", relativeTo: nil)?.path == "/tmp")
check("resolve relative", FS.resolve(typed: "B", relativeTo: a.deletingLastPathComponent()).map { FS.sameItem($0, b) } ?? false)

// MARK: New / rename / undo
let n1 = FileOps.newFolder(in: a, window: nil), n2 = FileOps.newFolder(in: a, window: nil)
check("new folder names", n1?.lastPathComponent == "New folder" && n2?.lastPathComponent == "New folder (2)", "\(names(a))")
Undo.shared.undo()
check("undo new folder", !exists(a.appendingPathComponent("New folder (2)")))
Undo.shared.redo()
check("redo new folder", exists(a.appendingPathComponent("New folder (2)")))
Undo.shared.undo()
let txt = FileOps.newFile(in: a, base: "New Text Document", ext: "txt", window: nil)!
try! "hello".write(to: txt, atomically: true, encoding: .utf8)
let renamed = FileOps.rename(txt, to: "notes.txt", window: nil)
check("rename", renamed?.lastPathComponent == "notes.txt" && !exists(txt))
Undo.shared.undo()
check("undo rename", exists(txt) && !exists(a.appendingPathComponent("notes.txt")))
Undo.shared.redo()
check("redo rename", exists(a.appendingPathComponent("notes.txt")) && !exists(txt))
Undo.shared.undo()
let notes = FileOps.rename(txt, to: "notes.txt", window: nil)!

// MARK: Copy / move / undo
var done = false
FileOps.transfer([notes], to: b, move: false, window: nil) { _ in done = true }
check("copy to other folder", waitFor(5) { done } && exists(b.appendingPathComponent("notes.txt")) && exists(notes))
done = false
FileOps.transfer([notes], to: a, move: false, window: nil) { _ in done = true }
_ = waitFor(5) { done }
done = false
FileOps.transfer([notes], to: a, move: false, window: nil) { _ in done = true }
_ = waitFor(5) { done }
check("paste into same folder makes '- Copy'", exists(a.appendingPathComponent("notes - Copy.txt")) && exists(a.appendingPathComponent("notes - Copy (2).txt")), "\(names(a))")
let mover = a.appendingPathComponent("notes - Copy (2).txt")
done = false
FileOps.transfer([mover], to: b, move: true, window: nil) { _ in done = true }
check("move", waitFor(5) { done } && exists(b.appendingPathComponent("notes - Copy (2).txt")) && !exists(mover))
Undo.shared.undo()
check("undo move", waitFor(2) { exists(mover) } && !exists(b.appendingPathComponent("notes - Copy (2).txt")))
Undo.shared.redo()
check("redo move", exists(b.appendingPathComponent("notes - Copy (2).txt")) && !exists(mover))
Undo.shared.undo()
let sub = a.appendingPathComponent("New folder")
check("folder-into-itself detected", FS.isInside(sub, a) && FS.isInside(a, a) && !FS.isInside(b, a) && !FS.isInside(a, sub))

// Regression: the same folder spelled differently (extra slash) must still make "- Copy", never replace.
let oddA = URL(fileURLWithPath: a.path.replacingOccurrences(of: "/A", with: "//A"))
done = false
FileOps.transfer([notes], to: oddA, move: false, window: nil) { _ in done = true }
check("same folder via odd path makes a copy", waitFor(5) { done } && exists(notes) && exists(a.appendingPathComponent("notes - Copy (3).txt")), "\(names(a))")

// MARK: Trash + undo
FileOps.trash([mover], window: nil)
check("delete to Trash", !exists(mover))
Undo.shared.undo()
check("undo delete (put back)", waitFor(2) { exists(mover) })
Undo.shared.redo()
check("redo delete", !exists(mover))
Undo.shared.undo()
check("undo again after redo", exists(mover))
FileOps.trash([mover], window: nil)
let inTrash = try? fm.contentsOfDirectory(at: RecycleBin.url, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("notes - Copy (2)") }
check("Recycle Bin remembers where it came from", inTrash == nil || RecycleBin.origin(of: inTrash!)?.path == mover.path,
      inTrash == nil ? "(Trash not readable without Full Disk Access; skipped)" : "")
Undo.shared.undo()

// MARK: Zip
FileOps.compress([b], window: nil)
let zip = root.appendingPathComponent("B.zip")
check("compress to ZIP", waitFor(10) { exists(zip) })
spin(0.5)
FileOps.extract(zip, window: nil)
let extracted = root.appendingPathComponent("B (2)")
check("extract all", waitFor(10) { exists(extracted.appendingPathComponent("B/notes.txt")) || exists(extracted.appendingPathComponent("notes.txt")) }, "\(names(root)) \(names(extracted))")

// MARK: Conflict dialog ("Replace or Skip Files") — screenshot it, then choose Keep both
var dialogShot = false
let t = Timer(timeInterval: 0.8, repeats: false) { _ in
    shot("conflict-dialog.png", window: NSApp.modalWindow); dialogShot = NSApp.modalWindow != nil
    NSApp.stopModal(withCode: .alertThirdButtonReturn)     // "Keep both"
}
RunLoop.current.add(t, forMode: .modalPanel)
done = false
FileOps.transfer([notes], to: b, move: false, window: nil) { _ in done = true }
check("conflict dialog shown", dialogShot)
check("keep both makes 'notes (2).txt'", waitFor(5) { done } && exists(b.appendingPathComponent("notes (2).txt")), "\(names(b))")

// MARK: Network safety
check("home is local", !FS.isNetwork(FS.home))
let share = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BUGOS_TEST_SHARE"] ?? "/Volumes/Share")   // a network share to test, if mounted
if exists(share) {
    check("PC share detected as network", FS.isNetwork(share))
    // Open ONE known folder on the share the way the app does (list + icons) and make sure no new
    // mounts appear. Never walks into subfolders.
    func mountCount() -> Int {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/sbin/mount"); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
    }
    let desk = share.appendingPathComponent("Desktop")
    let before = mountCount()
    let m = DirectoryModel(url: desk)
    var loaded = false
    m.onChange = { loaded = true }
    m.load()
    _ = waitFor(20) { loaded }
    let icons = m.items.prefix(60).map { $0.icon(size: 16) }
    check("network folder lists", loaded && !m.items.isEmpty, "\(m.items.count) items, \(icons.count) icons")
    check("no new mounts after listing a share folder", mountCount() == before, "before \(before), after \(mountCount())")
} else {
    print("SKIP network checks (PC share not mounted)")
}

// MARK: Progress window: copy a big file to another volume so it takes a while
if let vol = bigVolume {
    let big = root.appendingPathComponent("big.bin")
    fm.createFile(atPath: big.path, contents: nil)
    let h = try! FileHandle(forWritingTo: big)
    let chunk = Data((0..<(8 << 20)).map { _ in UInt8.random(in: 0...255) })
    for _ in 0..<40 { h.write(chunk) }      // 320 MB of random data (can't be cloned or compressed away)
    try? h.close()
    // Clones are instant on the same disk; three of them make a ~1 GB real copy to the other volume.
    let big2 = root.appendingPathComponent("big2.bin"), big3 = root.appendingPathComponent("big3.bin")
    try? fm.copyItem(at: big, to: big2); try? fm.copyItem(at: big, to: big3)
    var progressShot = false
    done = false
    let t0 = Date()
    FileOps.transfer([big, big2, big3], to: vol, move: false, window: nil) { _ in done = true }
    let pt = Timer(timeInterval: 0.8, repeats: false) { _ in
        let w = NSApp.windows.first { $0 is NSPanel && $0.isVisible }
        shot("progress.png", window: w); progressShot = w != nil
    }
    RunLoop.current.add(pt, forMode: .common)
    check("big cross-volume copy finishes", waitFor(120) { done } && exists(vol.appendingPathComponent("big.bin")),
          String(format: "%.1fs", Date().timeIntervalSince(t0)))
    check("progress screenshot taken", progressShot)
    check("copied data identical", fm.contentsEqual(atPath: big3.path, andPath: vol.appendingPathComponent("big3.bin").path))
    // A folder with nested files across volumes.
    let tree = root.appendingPathComponent("Tree/Inner")
    try! fm.createDirectory(at: tree, withIntermediateDirectories: true)
    try! "x".write(to: tree.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
    done = false
    FileOps.transfer([root.appendingPathComponent("Tree")], to: vol, move: true, window: nil) { _ in done = true }
    check("move folder to other disk", waitFor(10) { done } && exists(vol.appendingPathComponent("Tree/Inner/deep.txt")) && !exists(root.appendingPathComponent("Tree")))
    try? fm.removeItem(at: vol.appendingPathComponent("Tree"))
    try? fm.removeItem(at: vol.appendingPathComponent("big2.bin")); try? fm.removeItem(at: vol.appendingPathComponent("big3.bin"))
    // Cancelling a copy removes the half-written file.
    var calls = 0
    do {
        try CopyEngine.copy(big, to: vol.appendingPathComponent("cancel.bin")) { _ in calls += 1; return calls < 3 }
        check("cancel stops the copy", false)
    } catch {
        check("cancel stops the copy and cleans up", !exists(vol.appendingPathComponent("cancel.bin")), "\(error.localizedDescription)")
    }
    try? fm.removeItem(at: big)
    try? fm.removeItem(at: vol.appendingPathComponent("big.bin"))
}

// MARK: Recent files (Home page)
let q = NSMetadataQuery()
q.searchScopes = [NSMetadataQueryUserHomeScope]
q.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@", Date().addingTimeInterval(-30 * 86400) as NSDate)
var gathered = false
let obs = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: nil) { _ in gathered = true }
q.start()
check("Recent query returns files", waitFor(15) { gathered } && q.resultCount > 0, "\(q.resultCount) results")
q.stop(); NotificationCenter.default.removeObserver(obs)

try? fm.removeItem(at: root)
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
}
RunLoop.main.add(Timer(timeInterval: 0, repeats: false) { _ in runChecks() }, forMode: .common)
NSApp.run()
