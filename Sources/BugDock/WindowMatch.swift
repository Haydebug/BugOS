import AppKit
import ApplicationServices
import CoreGraphics

/// Pairs AX windows with on-screen CoreGraphics windows (public APIs only).
///
/// Used for two things:
/// - Spaces: `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` lists only windows on the current
///   Space(s), while AX `kAXWindows` can include an app's windows on other desktops (Chrome does).
///   A window that matches nothing on screen is on another desktop.
/// - Thumbnails/peek: the matched CGWindowID picks the right ScreenCaptureKit window.
enum WindowMatch {
    struct CGWin {
        let id: CGWindowID
        let frame: CGRect
        let name: String
    }

    /// Normal (layer 0) windows on the current Space(s), front-to-back, grouped by owner pid.
    /// One window-server call for every app.
    static func onScreenWindows() -> [pid_t: [CGWin]] {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
        var out: [pid_t: [CGWin]] = [:]
        for d in info {
            guard let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  (d[kCGWindowLayer as String] as? Int) == 0,
                  let num = d[kCGWindowNumber as String] as? UInt32,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            out[pid, default: []].append(CGWin(id: num, frame: r, name: d[kCGWindowName as String] as? String ?? ""))
        }
        return out
    }

    /// Apps with real windows that aren't on this desktop (on another desktop, or a full-screen one): named,
    /// window-sized, visible windows the window server has but isn't showing here.
    static func appsWithWindowsElsewhere() -> Set<pid_t> {
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var out = Set<pid_t>()
        for d in info {
            guard let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowIsOnscreen as String] as? Bool) != true,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let name = d[kCGWindowName as String] as? String, !name.isEmpty,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width >= 200, r.height >= 150 else { continue }
            out.insert(pid)
        }
        return out
    }

    /// Assigns AX windows (front-to-back, with frame and title) to distinct CG windows of the same app.
    /// Frames must agree (±4pt); an unambiguous title match wins first, the rest pair by stacking order.
    /// Returns AX index -> CGWindowID; unmatched AX windows are absent.
    static func assign(ax: [(frame: CGRect, title: String)], cg: [CGWin]) -> [Int: CGWindowID] {
        func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4
                && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
        }
        /// Capture titles drop app suffixes and middle-truncate with "…": every piece must appear, in order.
        func titleMatches(_ axTitle: String, _ cgName: String) -> Bool {
            let pieces = cgName.components(separatedBy: "…")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !pieces.isEmpty, !axTitle.isEmpty else { return false }
            var rest = Substring(axTitle)
            for p in pieces {
                guard let r = rest.range(of: p) else { return false }
                rest = rest[r.upperBound...]
            }
            return true
        }

        var used = Set<CGWindowID>()
        var result: [Int: CGWindowID] = [:]
        // Pass 1: unambiguous title matches (exactly one free same-frame window carries this title).
        for (i, a) in ax.enumerated() {
            let hits = cg.filter { !used.contains($0.id) && sameFrame($0.frame, a.frame) && titleMatches(a.title, $0.name) }
            if hits.count == 1 { result[i] = hits[0].id; used.insert(hits[0].id) }
        }
        // Pass 2: the rest by stacking order (both lists are front-to-back).
        for (i, a) in ax.enumerated() where result[i] == nil {
            if let c = cg.first(where: { !used.contains($0.id) && sameFrame($0.frame, a.frame) }) {
                result[i] = c.id; used.insert(c.id)
            }
        }
        return result
    }
}
