// Draws the BugOS app icon: a white ladybug with red accents on a black glass squircle tile.
// swift make-icon.swift <outdir>   -> <outdir>/AppIcon.iconset (then: iconutil -c icns)
import AppKit
let out = CommandLine.arguments[1]

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let s = CGFloat(px)
    let inset = s * 0.098
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
    sh.shadowBlurRadius = s * 0.022
    sh.shadowOffset = NSSize(width: 0, height: -s * 0.010)
    sh.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Black glass: deep gradient, a light rim, and a soft sheen across the top (like File Explorer's dark icon).
    NSGradient(colors: [NSColor(white: 1, alpha: 0.42), NSColor(white: 1, alpha: 0.06)])!.draw(in: path, angle: -90)
    let inner = NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.006, dy: s * 0.006), xRadius: tile.width * 0.22, yRadius: tile.width * 0.22)
    NSGradient(colors: [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.02, alpha: 1)])!.draw(in: inner, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    inner.addClip()
    let sheen = NSBezierPath(ovalIn: NSRect(x: tile.minX - tile.width * 0.25, y: tile.midY + tile.height * 0.08,
                                            width: tile.width * 1.5, height: tile.height * 0.9))
    NSGradient(colors: [NSColor(white: 1, alpha: 0.13), NSColor(white: 1, alpha: 0)])!.draw(in: sheen, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let cfg = NSImage.SymbolConfiguration(pointSize: tile.width * 0.56, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.97, alpha: 1), NSColor(calibratedRed: 0.96, green: 0.20, blue: 0.20, alpha: 1)]))
    if let bug = NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = bug.size
        let r = NSRect(x: tile.midX - sz.width / 2, y: tile.midY - sz.height / 2, width: sz.width, height: sz.height)
        NSGraphicsContext.saveGraphicsState()
        let bsh = NSShadow()
        bsh.shadowColor = NSColor.black.withAlphaComponent(0.6)
        bsh.shadowBlurRadius = s * 0.025
        bsh.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        bsh.set()
        // Red under the shell, so the spots (cut out of the symbol) show red.
        let shell = NSRect(x: r.midX - r.width * 0.25, y: r.minY + r.height * 0.10, width: r.width * 0.50, height: r.height * 0.52)
        NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.28, alpha: 1),
                            NSColor(calibratedRed: 0.78, green: 0.06, blue: 0.08, alpha: 1)])!.draw(in: NSBezierPath(ovalIn: shell), angle: -90)
        bug.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let set = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
