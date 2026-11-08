// Draws the File Explorer app icon: macOS's own blue folder on a light squircle tile.
//   swift tools/make-explorer-icon.swift <out dir> [dark]
// "dark": a black glass tile with a white folder (used while File Explorer is dark).
import AppKit
let out = CommandLine.arguments[1]
let dark = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "dark"
let folder = NSWorkspace.shared.icon(for: .folder)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let s = CGFloat(px)
    // Apple's icon grid: the tile is ~80% of the canvas, corner radius ~22.5% of the tile.
    let inset = s * 0.098
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

    // Soft drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
    sh.shadowBlurRadius = s * 0.022
    sh.shadowOffset = NSSize(width: 0, height: -s * 0.010)
    sh.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    if dark {
        // Black glass: deep gradient, a soft sheen across the top, a light rim.
        NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.03, alpha: 1)])!.draw(in: path, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let sheen = NSBezierPath(ovalIn: NSRect(x: tile.minX - tile.width * 0.25, y: tile.midY + tile.height * 0.05,
                                                width: tile.width * 1.5, height: tile.height * 0.9))
        NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0.0)])!.draw(in: sheen, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(white: 1, alpha: 0.45), NSColor(white: 1, alpha: 0.08)])!.draw(in: path, angle: -90)
        let inner = NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.006, dy: s * 0.006),
                                 xRadius: tile.width * 0.22, yRadius: tile.width * 0.22)
        NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.03, alpha: 1)])!.draw(in: inner, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        inner.addClip()
        NSGradient(colors: [NSColor(white: 1, alpha: 0.14), NSColor(white: 1, alpha: 0.0)])!.draw(in: sheen, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    } else {
        // Light, slightly cool gradient tile.
        NSGradient(colors: [NSColor(calibratedRed: 0.99, green: 0.995, blue: 1.0, alpha: 1),
                            NSColor(calibratedRed: 0.86, green: 0.90, blue: 0.96, alpha: 1)])!.draw(in: path, angle: -90)
        NSColor.black.withAlphaComponent(0.06).setStroke()
        path.lineWidth = max(1, s * 0.002)
        path.stroke()
    }

    if dark {
        // A white folder glyph with a gentle top-to-bottom shade.
        let cfg = NSImage.SymbolConfiguration(pointSize: tile.width * 0.46, weight: .regular)
        if let sym = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let w = sym.size.width, h = sym.size.height
            let r = NSRect(x: tile.midX - w / 2, y: tile.midY - h / 2 - tile.height * 0.01, width: w, height: h)
            let tinted = NSImage(size: sym.size, flipped: false) { b in
                sym.draw(in: b)
                NSGradient(colors: [NSColor.white, NSColor(white: 0.82, alpha: 1)])!.draw(in: b, angle: -90)
                return true
            }
            // Draw the gradient only where the symbol is.
            let masked = NSImage(size: sym.size, flipped: false) { b in
                tinted.draw(in: b)
                sym.draw(in: b, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
            NSGraphicsContext.saveGraphicsState()
            let gsh = NSShadow()
            gsh.shadowColor = NSColor.black.withAlphaComponent(0.5)
            gsh.shadowBlurRadius = s * 0.02
            gsh.shadowOffset = NSSize(width: 0, height: -s * 0.01)
            gsh.set()
            masked.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    // The system folder, large and centred (its artwork has empty margins, so draw it bigger than the tile area).
    let f = tile.width * 0.80
    let fr = NSRect(x: tile.midX - f / 2, y: tile.midY - f / 2 - tile.height * 0.01, width: f, height: f)
    NSGraphicsContext.saveGraphicsState()
    let fsh = NSShadow()
    fsh.shadowColor = NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.55, alpha: 0.25)
    fsh.shadowBlurRadius = s * 0.02
    fsh.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    fsh.set()
    folder.draw(in: fr, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

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
