// Draws the BugOS app icon: a red ladybug on a dark blue squircle tile.
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

    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.80, alpha: 1),
                        NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.36, alpha: 1)])!.draw(in: path, angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: tile.width * 0.62, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor(calibratedRed: 0.95, green: 0.22, blue: 0.20, alpha: 1)]))
    if let bug = NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = bug.size
        let r = NSRect(x: tile.midX - sz.width / 2, y: tile.midY - sz.height / 2, width: sz.width, height: sz.height)
        bug.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
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
