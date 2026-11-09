import AppKit
import ScreenCaptureKit

/// Live window thumbnails via ScreenCaptureKit (Apple's public capture API, needs Screen Recording permission).
/// AX windows are matched to capturable windows per app, by stacking order + frame + title (see `windowIDs`).
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    /// Thumbnail box in points; captured at 2x for Retina.
    static let box = CGSize(width: 220, height: 130)

    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var loadingContent: Task<SCShareableContent?, Never>?
    private var cache: [String: NSImage] = [:]

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func requestPermissionIfNeeded() {
        if !hasPermission { CGRequestScreenCaptureAccess() }
    }

    func cached(_ w: TrackedWindow) -> NSImage? { cache[w.id] }

    /// The ScreenCaptureKit window for an AX window.
    ///
    /// Matching one window at a time by frame + exact title broke for apps like Chrome: two Filled
    /// windows share (almost) the same frame, and AX titles carry suffixes ("… - Google Chrome - Profile")
    /// that capture titles lack, so both fell back to the same capture window. Instead, all of the
    /// app's windows are assigned together: AX windows and on-screen CG windows are both front-to-back,
    /// frames must agree, titles break ties, and no capture window is used twice.
    func scWindow(for w: TrackedWindow, axFrame: CGRect) async -> SCWindow? {
        guard let windows = await shareableContent()?.windows else { return nil }
        guard let id = Self.windowIDs(pid: w.pid)
                .first(where: { CFEqual($0.element, w.element) })?.windowID else { return nil }
        return windows.first { $0.windowID == id }
    }

    /// Pairs every AX window of `pid` with a distinct on-screen CGWindowID (see WindowMatch).
    static func windowIDs(pid: pid_t) -> [(element: AXUIElement, windowID: CGWindowID)] {
        // Exactly the candidates WindowReader.windows(pid:onScreen:appHidden:) pairs for the hover list:
        // standard, non-minimized windows. Using every AX window let a minimized window (which keeps its
        // old full-size frame) or a helper window claim a visible same-frame window's ID, so that window
        // was listed but could never be captured or peeked.
        let axWins: [(element: AXUIElement, frame: CGRect, title: String)] =
            WindowReader.windows(pid: pid).compactMap { w in
                guard !w.isMinimized, let f = w.frame else { return nil }   // just read, in the same batch
                return (w.element, f, w.title)
            }
        let cg = WindowMatch.onScreenWindows()[pid] ?? []
        let matched = WindowMatch.assign(ax: axWins.map { ($0.frame, $0.title) }, cg: cg)
        return matched.sorted { $0.key < $1.key }.map { (axWins[$0.key].element, $0.value) }
    }

    func capture(_ w: TrackedWindow) async -> NSImage? {
        guard !w.isMinimized, hasPermission, let axFrame = AX.frame(w.element),
              let sc = await scWindow(for: w, axFrame: axFrame) else { return cache[w.id] }

        let scale = min(Self.box.width * 2 / max(sc.frame.width, 1), Self.box.height * 2 / max(sc.frame.height, 1), 2)
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(sc.frame.width * scale))
        cfg.height = max(1, Int(sc.frame.height * scale))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true

        guard let cg = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: sc), configuration: cfg) else { return cache[w.id] }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        cache[w.id] = img
        if cache.count > 200 { cache.removeAll() }
        return img
    }

    /// Full-resolution capture for the peek overlay. Returns the image and the window's current
    /// frame in global top-left-origin coordinates.
    func captureFull(_ w: TrackedWindow, scale: CGFloat) async -> (image: CGImage, frame: CGRect)? {
        guard !w.isMinimized, hasPermission, let axFrame = AX.frame(w.element),
              let sc = await scWindow(for: w, axFrame: axFrame) else { return nil }
        let s = min(scale, 6000 / max(axFrame.width, axFrame.height, 1))
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(sc.frame.width * s))
        cfg.height = max(1, Int(sc.frame.height * s))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        guard let cg = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: sc), configuration: cfg) else { return nil }
        return (cg, axFrame)
    }

    /// Window list from ScreenCaptureKit, shared by all cards for up to ~0.8s.
    private func shareableContent() async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(contentAt) < 0.8 { return content }
        if let loadingContent { return await loadingContent.value }
        let task = Task<SCShareableContent?, Never> {
            try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
        loadingContent = task
        let result = await task.value
        loadingContent = nil
        content = result
        contentAt = Date()
        return result
    }
}
