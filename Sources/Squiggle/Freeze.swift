// The screen as it was the instant you pressed the snip key (Windows Snipping Tool style): menus, hover
// effects and tooltips are still there, because the picture is taken before Squiggle takes focus. The
// selection overlay shows this frozen picture, and the snip is cut from it.
import AppKit
import ScreenCaptureKit

/// One frozen picture per screen (CGImage at full pixel size).
struct FrozenScreens {
    var images: [CGDirectDisplayID: CGImage] = [:]

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
    func image(for s: NSScreen) -> CGImage? { images[Self.displayID(s)] }

    /// Take every screen at once; calls back on the main thread (empty if capture isn't allowed).
    static func capture(_ done: @escaping (FrozenScreens) -> Void) {
        let scales = Dictionary(NSScreen.screens.map { (displayID($0), $0.backingScaleFactor) }, uniquingKeysWith: { a, _ in a })
        Task.detached(priority: .userInitiated) {
            var out = FrozenScreens()
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                await withTaskGroup(of: (CGDirectDisplayID, CGImage?).self) { group in
                    for d in content.displays {
                        group.addTask {
                            let cfg = SCStreamConfiguration()
                            let scale = scales[d.displayID] ?? 2
                            cfg.width = Int(CGFloat(d.width) * scale)
                            cfg.height = Int(CGFloat(d.height) * scale)
                            cfg.showsCursor = false
                            cfg.captureResolution = .best
                            let filter = SCContentFilter(display: d, excludingWindows: [])
                            return (d.displayID, try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg))
                        }
                    }
                    for await (id, img) in group { if let img { out.images[id] = img } }
                }
            }
            let result = out
            await MainActor.run { done(result) }
        }
    }

    /// A rect in global Cocoa coordinates, cut out of its screen's frozen picture.
    func crop(_ r: NSRect, on screen: NSScreen) -> CGImage? {
        guard let img = image(for: screen) else { return nil }
        let f = screen.frame
        let sx = CGFloat(img.width) / f.width, sy = CGFloat(img.height) / f.height
        let local = r.offsetBy(dx: -f.minX, dy: -f.minY).intersection(NSRect(origin: .zero, size: f.size))
        guard !local.isEmpty else { return nil }
        // CGImage rows go top to bottom.
        let px = CGRect(x: local.minX * sx, y: (f.height - local.maxY) * sy, width: local.width * sx, height: local.height * sy).integral
        return img.cropping(to: px)
    }
}
