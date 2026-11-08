import AppKit
import NetFS

/// Typing smb://server/share (or a Windows path like \\server\share) in the address bar connects to it.
enum ServerConnect {
    static func url(fromTyped raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\\\\") {                    // \\server\share\folder  ->  smb://server/share/folder
            s = "smb://" + s.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        }
        guard let u = URL(string: s.replacingOccurrences(of: " ", with: "%20")),
              let scheme = u.scheme?.lowercased(), ["smb", "afp", "nfs", "cifs", "ftp"].contains(scheme) else { return nil }
        return u
    }

    /// Mounts the share (macOS shows its own sign-in box if needed) and calls back with the folder to open.
    static func connect(_ url: URL, window: NSWindow?, done: @escaping (URL) -> Void) {
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionAllowUI
        var req: AsyncRequestID?
        let share = url.pathComponents.dropFirst().first ?? url.host ?? ""
        let rest = Array(url.pathComponents.dropFirst(2))
        NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, nil, &req, DispatchQueue.main) { status, _, mounts in
            var mountPoint = (mounts as? [String])?.first.map(URL.init(fileURLWithPath:))
            if status == EEXIST || mountPoint == nil {
                // Already connected: find it among the mounted volumes.
                mountPoint = Places.networkVolumes.first { $0.lastPathComponent.caseInsensitiveCompare(share) == .orderedSame }
            }
            guard status == 0 || status == EEXIST, var target = mountPoint else {
                if status != Int32(ECANCELED) && status != -128 {
                    showError("Couldn't connect to “\(url.absoluteString)”.", info: "Error \(status). Check the address and that the server is reachable.", in: window)
                }
                return
            }
            for c in rest { target.appendPathComponent(c) }
            done(FS.exists(target) ? target : mountPoint!)
        }
    }
}
