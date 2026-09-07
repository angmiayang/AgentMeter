// Renders AppIcon.iconset for AgentMeter: a white dial gauge with a needle on a
// slate-to-teal squircle. Same mark as the menu-bar glyph, in colour.
import AppKit
import ImageIO
import UniformTypeIdentifiers

func render(_ S: CGFloat) -> CGImage? {
    let px = Int(S)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Squircle plate, inset like a standard macOS icon.
    let inset = S * 0.098
    let plate = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let radius = plate.width * 0.225
    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                      transform: nil)

    // Solid fill first, purely to cast the shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.022,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.22, blue: 0.30, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient over the plate: deep slate at the top into teal at the base.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let top = CGColor(srgbRed: 0.11, green: 0.20, blue: 0.29, alpha: 1)
    let bot = CGColor(srgbRed: 0.06, green: 0.51, blue: 0.44, alpha: 1)
    let grad = CGGradient(colorsSpace: cs, colors: [top, bot] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY), options: [])
    // Soft top highlight so it is not visually dead flat.
    let hi = CGGradient(colorsSpace: cs,
                        colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
                                 CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.midY), options: [])
    ctx.restoreGState()

    // Dial: a 240-degree arc sitting slightly below centre, with a needle at ~72%
    // of sweep, so the mark reads as a meter under load rather than at rest.
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let c = CGPoint(x: plate.midX, y: plate.midY - plate.height * 0.055)
    let r = plate.width * 0.285
    let lw = plate.width * 0.088

    // Sweep runs anticlockwise from 210 to -30 degrees in CoreGraphics terms.
    let a0 = CGFloat.pi * 210 / 180
    let a1 = CGFloat.pi * -30 / 180

    ctx.setLineCap(.round)
    ctx.setLineWidth(lw)

    // Track, then the live portion drawn over it at full opacity.
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30))
    ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
    ctx.strokePath()

    let frac: CGFloat = 0.72
    ctx.setStrokeColor(white)
    ctx.addArc(center: c, radius: r, startAngle: a0,
               endAngle: a0 - (a0 - a1) * frac, clockwise: true)
    ctx.strokePath()

    // Needle, from just above the hub to inside the arc.
    let na = a0 - (a0 - a1) * frac
    ctx.setLineWidth(lw * 0.62)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(white)
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + cos(na) * r * 0.66,
                            y: c.y + sin(na) * r * 0.66))
    ctx.strokePath()

    // Hub.
    ctx.setFillColor(white)
    ctx.addArc(center: c, radius: lw * 0.46, startAngle: 0, endAngle: .pi * 2,
               clockwise: false)
    ctx.fillPath()

    return ctx.makeImage()
}

func write(_ img: CGImage, to url: URL) {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("destination") }
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let set = URL(fileURLWithPath: outDir)
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    guard let img = render(size) else { fatalError("render \(name)") }
    write(img, to: set.appendingPathComponent("\(name).png"))
}
print("iconset written: \(variants.count) images")
