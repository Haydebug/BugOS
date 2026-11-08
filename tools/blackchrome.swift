import AppKit
// Recolor Chrome's white tile to black, leaving the logo (outer colored ring and everything inside it) untouched.
let N = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1024")!
let u = Double(N) / 1024   // margins below are tuned at 1024px
func render(_ path: String) -> NSBitmapImageRep {
    let img = NSWorkspace.shared.icon(forFile: path)
    img.size = NSSize(width: N, height: N)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: N, pixelsHigh: N, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: N * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: N, height: N))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let rep = render("/Applications/Google Chrome.app")
let p = rep.bitmapData!
// Donor for the dark tile: Spotify's icon (same macOS 26 shape, dark tile, real Liquid Glass rim + shading).
let donor = render("/Applications/Spotify.app")
let q = donor.bitmapData!
func px(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
    let i = (y * N + x) * 4
    return (Double(p[i]) / 255, Double(p[i+1]) / 255, Double(p[i+2]) / 255, Double(p[i+3]) / 255)
}
func sat(_ c: (Double, Double, Double, Double)) -> Double {
    guard c.3 > 0.05 else { return 0 }
    let r = c.0 / c.3, g = c.1 / c.3, b = c.2 / c.3
    return max(r, g, b) - min(r, g, b)
}
// Logo centre = centroid of saturated pixels; logo radius = farthest saturated pixel along 72 rays.
var sx = 0.0, sy = 0.0, n = 0.0
for y in 0..<N { for x in 0..<N where sat(px(x, y)) > 0.35 { sx += Double(x); sy += Double(y); n += 1 } }
let cx = sx / n, cy = sy / n
var radii: [Double] = []
for k in 0..<72 {
    let a = Double(k) * .pi * 2 / 72
    var last = 0.0
    var r = 0.0
    while r < Double(N) / 2 {
        let x = Int(cx + cos(a) * r), y = Int(cy + sin(a) * r)
        if x < 0 || y < 0 || x >= N || y >= N { break }
        if sat(px(x, y)) > 0.35 { last = r }
        r += 0.5 * max(u, 0.25)
    }
    radii.append(last)
}
let R = radii.sorted()[radii.count / 2] + 3 * u   // median, plus a little anti-alias margin
print("logo centre", Int(cx), Int(cy), "radius", Int(R))
// Outside the logo's core: anything colorless (the white tile, and the logo's thin light rim) becomes the
// dark tile; colored ring pixels are kept. Blend by saturation so the ring keeps clean anti-aliased edges.
let core = R - 20 * u
// Spotify's logo must sit inside Chrome's, or its green would show through.
var spR = 0.0
for y in 0..<N { for x in 0..<N {
    let i = (y * N + x) * 4
    let a = Double(q[i+3]) / 255
    guard a > 0.5 else { continue }
    let g = Double(q[i+1]) / 255 / a, r = Double(q[i]) / 255 / a, b = Double(q[i+2]) / 255 / a
    if g - max(r, b) > 0.25 { spR = max(spR, hypot(Double(x) - cx, Double(y) - cy)) }
}}
print("spotify logo radius", Int(spR), "chrome core", Int(core))
// Only copy Spotify's pixels beyond its own logo (plus 1.5px of anti-aliasing); the gap in between is plain black.
let donorFrom = max(R + 4 * u, spR + 1.5)
for y in 0..<N { for x in 0..<N {
    let c = px(x, y)
    guard c.3 > 0 || q[(y * N + x) * 4 + 3] > 0 else { continue }
    let d = hypot(Double(x) - cx, Double(y) - cy)
    guard d > core else { continue }
    let s = sat(c)
    var k = min(max((0.30 - s) / 0.18, 0), 1)        // sat <= 0.12 -> 1 (recolor), sat >= 0.30 -> 0 (keep)
    if d > R + 4 * u || d > donorFrom { k = 1 }                            // well outside the logo: all tile
    guard k > 0 else { continue }
    let i = (y * N + x) * 4
    // Outside Chrome's logo: Spotify's own pixel (its black tile, Liquid Glass rim, rounded edge and shadow).
    // In the thin band at the logo's edge: Spotify's tile black, keeping Chrome's alpha.
    let fromDonor = d > donorFrom
    for ch in 0..<4 {
        let orig = Double(p[i + ch])
        let target: Double = fromDonor ? Double(q[i + ch]) : (ch == 3 ? orig : 0)
        p[i + ch] = UInt8(max(0, min(255, orig * (1 - k) + target * k)))
    }
}}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
