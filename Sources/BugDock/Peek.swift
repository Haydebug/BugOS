import AppKit
import ImageIO
import QuartzCore

/// Windows-style "Aero Peek": hovering a thumbnail card shows that window full size in its real
/// spot, with everything else faded to the (dimmed) wallpaper.
///
/// This is purely a BugDock overlay: a click-through panel showing the wallpaper plus a live
/// ScreenCaptureKit capture of the window. Other apps' windows are never moved, reordered or changed.
@MainActor
final class PeekController {
    private unowned let bar: TaskbarController
    private let panel = FloatingPanel(level: .peek)
    private let root = NSView()
    private let backdrop = CALayer()          // faded "everything else": fallback fill + wallpaper + light dim
    private let wallpaperLayer = CALayer()
    private let dimLayer = CALayer()
    private let windowLayer = CALayer()

    /// How much the other windows are hidden during a peek (0.3 light ... 1.0 full wallpaper).
    static var strength: Double {
        get { (UserDefaults.standard.object(forKey: "peekStrength") as? Double) ?? 0.5 }
        set { UserDefaults.standard.set(newValue, forKey: "peekStrength") }
    }

    private var pendingID: String?     // card the mouse is on
    private var currentID: String?     // window being peeked
    private var showWork: DispatchWorkItem?
    private var endWork: DispatchWorkItem?
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var wallpaperKey: String?

    private static let hoverDelay = 0.3
    private static let fade = 0.15
    private static let refresh: Duration = .milliseconds(200)

    init(bar: TaskbarController) {
        self.bar = bar
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0

        root.wantsLayer = true
        let base = root.layer!
        base.backgroundColor = NSColor.clear.cgColor
        backdrop.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor   // fallback if no wallpaper
        wallpaperLayer.contentsGravity = .resizeAspectFill
        wallpaperLayer.masksToBounds = true
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        backdrop.addSublayer(wallpaperLayer)
        backdrop.addSublayer(dimLayer)
        windowLayer.contentsGravity = .resize
        windowLayer.shadowColor = NSColor.black.cgColor
        windowLayer.shadowOpacity = 0.55
        windowLayer.shadowRadius = 24
        windowLayer.shadowOffset = CGSize(width: 0, height: -8)
        base.addSublayer(backdrop)
        base.addSublayer(windowLayer)
        panel.contentView = root
    }

    private var canPeek: Bool {
        !bar.menuOpen && !bar.isDragging && !bar.startMenu.isVisible && Thumbnails.shared.hasPermission
    }

    // MARK: Hover events from WindowCard

    func hoverBegan(_ w: TrackedWindow) {
        endWork?.cancel()
        showWork?.cancel()
        guard canPeek, !w.isMinimized else { end(); return }
        pendingID = w.id
        loadWallpaper(screen(for: w))
        if currentID != nil {            // already peeking: switch instantly
            start(w)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.start(w) }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    func hoverEnded(_ w: TrackedWindow) {
        guard pendingID == w.id else { return }
        showWork?.cancel()
        // Short grace period so sliding onto the neighbouring card switches instead of flickering out.
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.end() }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Fade out and stop capturing. Safe to call any time.
    func end() {
        showWork?.cancel()
        endWork?.cancel()
        loop?.cancel()
        loop = nil
        pendingID = nil
        guard currentID != nil else { return }
        currentID = nil
        generation += 1
        let gen = generation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fade
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade + 0.02) { [weak self] in
            guard let self, self.generation == gen else { return }   // a new peek started meanwhile
            self.panel.orderOut(nil)
            self.setWindowImage(nil, frame: .zero)
        }
    }

    // MARK: Peek

    private func start(_ w: TrackedWindow) {
        guard canPeek, pendingID == w.id else { return }
        if currentID == w.id, loop != nil { return }
        loop?.cancel()
        let switching = currentID != nil
        currentID = w.id
        generation += 1
        let gen = generation
        let screen = screen(for: w)
        fitToScreen(screen)
        loadWallpaper(screen)
        if switching { setWindowImage(nil, frame: .zero) }   // don't show the previous window while the new one loads

        let scale = screen.backingScaleFactor
        loop = Task { [weak self] in
            var shown = false
            while !Task.isCancelled {
                let result = await Thumbnails.shared.captureFull(w, scale: scale)
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                if let result {
                    self.setWindowImage(result.image, frame: result.frame)
                    if !shown { shown = true; self.fadeIn() }
                } else if !shown {
                    self.end()          // couldn't capture this window: no peek
                    return
                }
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    /// The display the window is on (most overlap), so windows on a second display peek there too.
    private func screen(for w: TrackedWindow) -> NSScreen {
        guard let f = AX.frame(w.element) else { return bar.screen }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKit = CGRect(x: f.minX, y: primaryHeight - f.minY - f.height, width: f.width, height: f.height)
        func overlap(_ s: NSScreen) -> CGFloat {
            let r = s.frame.intersection(appKit)
            return r.isNull ? 0 : r.width * r.height
        }
        return NSScreen.screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? bar.screen
    }

    /// Covers the window's display; on the taskbar's display it leaves the bar strip alone, so the bar
    /// looks exactly the same while peeking.
    private func fitToScreen(_ s: NSScreen) {
        let screen = s.frame
        let strip = TaskbarSet.hasBar(s) ? Metrics.barHeight : 0
        let frame = NSRect(x: screen.minX, y: screen.minY + strip,
                           width: screen.width, height: screen.height - strip)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = root.bounds
        backdrop.opacity = Float(min(1, max(0.1, Self.strength)))
        // Lay the wallpaper out over the whole screen (as the desktop does), then let the panel clip the bar strip.
        wallpaperLayer.frame = CGRect(x: 0, y: -strip, width: screen.width, height: screen.height)
        dimLayer.frame = backdrop.bounds
        CATransaction.commit()
    }

    private func fadeIn() {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fade
            panel.animator().alphaValue = 1
        }
    }

    /// `frame` is in global top-left-origin coordinates (AX / ScreenCaptureKit space).
    private func setWindowImage(_ image: CGImage?, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowLayer.contents = image
        if image != nil {
            // Global top-left -> global AppKit (bottom-left, primary screen = menu-bar screen) -> panel-local.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKit = CGRect(x: frame.minX, y: primaryHeight - frame.minY - frame.height,
                                width: frame.width, height: frame.height)
            let local = appKit.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            windowLayer.frame = local
            windowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: local.size),
                                            cornerWidth: 10, cornerHeight: 10, transform: nil)
        }
        windowLayer.isHidden = image == nil
        CATransaction.commit()
    }

    // MARK: Wallpaper

    private func loadWallpaper(_ screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            wallpaperKey = nil
            wallpaperLayer.contents = nil
            return
        }
        let key = url.path + "@" + NSStringFromRect(screen.frame)
        guard key != wallpaperKey else { return }
        wallpaperKey = key
        let maxPixels = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = Self.loadImage(url, maxPixels: maxPixels)
            await self?.applyWallpaper(image, key: key)
        }
    }

    private func applyWallpaper(_ image: CGImage?, key: String) {
        guard wallpaperKey == key else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperLayer.contents = image     // nil -> plain dark fallback shows through
        CATransaction.commit()
    }

    nonisolated private static func loadImage(_ url: URL, maxPixels: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
