// Updates from GitHub: BugOS checks the project's latest release (github.com/Haydebug/BugOS/releases),
// and if it's newer, downloads its DMG, checks the app inside is signed with the same certificate as this
// one (so it really is BugOS, and macOS keeps its permissions), swaps it in and reopens.
//
// Checks on its own once a day (General › Updates › "Check automatically", on by default) and shows the
// page when a new version first turns up; "Check for Updates" checks right away.
import AppKit
import BugOSKit

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "Haydebug/BugOS"

    struct Release: Equatable {
        let version: String
        let notes: String
        let dmg: URL
        let page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading(Double), installing, failed(String)
    }

    @Published var state: State = .idle
    @Published var lastChecked: Date? = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date

    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateAutoCheck") }
    }
    private var timer: Timer?
    /// Called when an automatic check finds a version you haven't been shown yet.
    var onNewVersion: (() -> Void)?

    var current: String { SystemChanges.version }

    /// Automatic checks: a minute after starting, then every 24 hours.
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.automaticCheck() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { Updater.shared.automaticCheck() }
    }

    private func automaticCheck() {
        guard Self.autoCheck else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 20 * 3600 { return }
        check { [weak self] in
            guard let self, case .available(let r) = self.state,
                  UserDefaults.standard.string(forKey: "updateNotified") != r.version else { return }
            UserDefaults.standard.set(r.version, forKey: "updateNotified")
            Supervisor.shared.log("update \(r.version) available")
            self.onNewVersion?()
        }
    }

    func check(then: (() -> Void)? = nil) {
        if case .checking = state { return }
        if case .downloading = state { return }
        state = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BugOS-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishCheck(json: json, code: code, err: err)
                    then?()
                }
            }
        }.resume()
    }

    private func finishCheck(json: [String: Any]?, code: Int, err: Error?) {
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked")
        if code == 404 { state = .upToDate; return }   // no releases yet
        guard err == nil, code == 200, let json, let tag = json["tag_name"] as? String else {
            state = .failed(err?.localizedDescription ?? "GitHub didn't answer (\(code)).")
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: current) else { state = .upToDate; return }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })?["browser_download_url"] as? String,
              let dmgURL = URL(string: dmg) else {
            state = .failed("Version \(version) has no download yet.")
            return
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(Self.repo)/releases")!
        state = .available(Release(version: version, notes: json["body"] as? String ?? "", dmg: dmgURL, page: page))
    }

    /// "1.10.0" > "1.9.2"
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Installing

    private var download: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    func install() {
        guard case .available(let r) = state else { return }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: r.dmg) { file, _, err in
            // The file is deleted when this returns: move it somewhere of ours first.
            var kept: URL?
            if let file {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("BugOS-update-\(r.version).dmg")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: file, to: dest)) != nil { kept = dest }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let kept else { self.state = .failed(err?.localizedDescription ?? "The download failed."); return }
                    self.installDMG(kept, version: r.version)
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { if case .downloading = Updater.shared.state { Updater.shared.state = .downloading(f) } } }
        }
        download = task
        task.resume()
    }

    private func installDMG(_ dmg: URL, version: String) {
        state = .installing
        // Mount it, find the app, and make sure it's signed exactly like this one.
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("BugOS-update-mount")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]) == 0 else {
            state = .failed("Couldn't open the downloaded disk image."); return
        }
        let newApp = mount.appendingPathComponent("BugOS.app")
        guard FileManager.default.fileExists(atPath: newApp.path),
              Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0,
              let mine = Self.requirement(Bundle.main.bundleURL), mine == Self.requirement(newApp) else {
            Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            Supervisor.shared.log("update \(version) refused: not signed like this BugOS")
            state = .failed("The download isn't signed like this copy of BugOS, so it wasn't installed.")
            return
        }
        // Swap it in from a separate process once BugOS has quit, then open the new one.
        let here = Bundle.main.bundleURL.path
        let dest = (Bundle.main.bundleURL.deletingLastPathComponent().path as NSString).appendingPathComponent("BugOS.app")
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        rm -rf '\(here)' '\(dest)'
        ditto '\(newApp.path)' '\(dest)'
        hdiutil detach '\(mount.path)' -quiet
        rm -f '\(dmg.path)'
        xattr -dr com.apple.quarantine '\(dest)' 2>/dev/null
        '\(lsregister)' -f '\(dest)'
        open '\(dest)'
        """
        Supervisor.shared.log("installing update \(version)")
        SystemChanges.spawnDetached("/bin/bash", ["-c", script])
        Supervisor.shared.stopAll()
        NSApp.terminate(nil)
    }

    /// The app's designated requirement (it names the signing certificate).
    private static func requirement(_ app: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-d", "-r-", app.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        // "designated => identifier "com.bugos.os" and certificate leaf = H"…""
        return out.components(separatedBy: "\n").first { $0.hasPrefix("designated =>") }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
