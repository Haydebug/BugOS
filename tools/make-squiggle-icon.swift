// Draws the Squiggle app icon in the BugOS family: a black glass tile with one bold hand-drawn squiggle in a
// pink-to-orange gradient, ending at a white marker tip. All shapes are drawn here; no system artwork.
//   swift tools/make-squiggle-icon.swift <out dir>   -> <out dir>/AppIcon.iconset (then: iconutil -c icns)
import AppKit
let out = CommandLine.arguments[1]

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let cg = ctx.cgContext
    let s = CGFloat(px)
    let inset = s * 0.098
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let u = tile.width / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * u, y: tile.minY + y * u) }

    // Black glass tile (as BugOS's own icon): shadow, light rim, deep gradient, sheen.
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
    sh.shadowBlurRadius = s * 0.022
    sh.shadowOffset = NSSize(width: 0, height: -s * 0.010)
    sh.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.42), NSColor(white: 1, alpha: 0.06)])!.draw(in: path, angle: -90)
    let inner = NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.006, dy: s * 0.006), xRadius: tile.width * 0.22, yRadius: tile.width * 0.22)
    NSGradient(colors: [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.02, alpha: 1)])!.draw(in: inner, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    inner.addClip()
    let sheen = NSBezierPath(ovalIn: NSRect(x: tile.minX - tile.width * 0.25, y: tile.midY + tile.height * 0.08,
                                            width: tile.width * 1.5, height: tile.height * 0.9))
    NSGradient(colors: [NSColor(white: 1, alpha: 0.13), NSColor(white: 1, alpha: 0)])!.draw(in: sheen, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The squiggle: one loose loop-de-loop from lower left to the marker at upper right.
    let squiggle = CGMutablePath()
    squiggle.move(to: p(18, 36))
    squiggle.addCurve(to: p(36, 52), control1: p(22, 50), control2: p(28, 56))
    squiggle.addCurve(to: p(40, 36), control1: p(44, 48), control2: p(46, 36))
    squiggle.addCurve(to: p(52, 58), control1: p(34, 36), control2: p(40, 62))
    squiggle.addCurve(to: p(64, 64), control1: p(58, 56), control2: p(60, 62))
    let width = 9 * u
    // Soft glow under the stroke.
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: s * 0.05, color: NSColor(calibratedRed: 1, green: 0.3, blue: 0.4, alpha: 0.55).cgColor)
    cg.addPath(squiggle)
    cg.setLineWidth(width)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.setStrokeColor(NSColor(calibratedRed: 1, green: 0.35, blue: 0.4, alpha: 1).cgColor)
    cg.strokePath()
    cg.restoreGState()
    // The stroke itself, in a gradient along the line.
    cg.saveGState()
    cg.addPath(squiggle)
    cg.setLineWidth(width)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.replacePathWithStrokedPath()
    cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.55, alpha: 1).cgColor,
                                   NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.30, alpha: 1).cgColor,
                                   NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.25, alpha: 1).cgColor] as CFArray,
                          locations: [0, 0.55, 1])!
    cg.drawLinearGradient(grad, start: p(18, 36), end: p(64, 64), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    // The marker, its tip at the end of the line, angled up and right.
    cg.saveGState()
    cg.translateBy(x: p(64, 64).x, y: p(64, 64).y)
    cg.rotate(by: .pi / 4)   // marker space: tip at the origin, body along +x
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    // Tip (coloured like the end of the line), then the white body and a darker band.
    let tip = CGMutablePath()
    tip.move(to: CGPoint(x: -1 * u, y: 0))
    tip.addLine(to: CGPoint(x: 7 * u, y: -4.6 * u))
    tip.addLine(to: CGPoint(x: 7 * u, y: 4.6 * u))
    tip.closeSubpath()
    cg.addPath(tip)
    cg.setFillColor(NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.25, alpha: 1).cgColor)
    cg.fillPath()
    let body = CGPath(roundedRect: CGRect(x: 6.5 * u, y: -6.5 * u, width: 26 * u, height: 13 * u),
                      cornerWidth: 4 * u, cornerHeight: 4 * u, transform: nil)
    cg.addPath(body)
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillPath()
    cg.setShadow(offset: .zero, blur: 0, color: nil)
    cg.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
    cg.fill(CGRect(x: 11 * u, y: -6.5 * u, width: 2.4 * u, height: 13 * u))
    cg.restoreGState()

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
