// Renders the app icon into Resources/AppIcon.icns
// Usage: swift scripts/make_icon.swift
//
// A chat on a graphite body in the Liquid Glass manner of macOS 26–27: three message bubbles, the middle
// one picked out by a blue highlight with viewfinder corners and the pointer on it, and the black island
// of the notch shelf at the top.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshooter.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Apple-style continuous corners (superellipse).
func squircle(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Linear or radial gradient from (location, r, g, b, a) stops.
func gradient(_ stops: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)]) -> CGGradient {
    let colors = stops.map { CGColor(colorSpace: space, components: [$0.1, $0.2, $0.3, $0.4])! }
    return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops.map { $0.0 })!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let blue = (r: CGFloat(0.20), g: CGFloat(0.55), b: CGFloat(1.0))

/// A glossy bubble: soft shadow, vertical volume gradient, light top edge.
func bubble(_ ctx: CGContext, _ rect: CGRect, light: Bool) {
    let path = rounded(rect, rect.height / 2.6)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.55))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: light ? 1 : 0.3, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let stops: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = light
        ? [(0, 1, 1, 1, 1), (0.6, 0.94, 0.95, 0.97, 1), (1, 0.80, 0.82, 0.87, 1)]
        : [(0, 0.40, 0.41, 0.45, 1), (1, 0.24, 0.25, 0.28, 1)]
    ctx.drawLinearGradient(gradient(stops), start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    // Text lines inside the bubble.
    let ink = light ? CGColor(red: 0.55, green: 0.58, blue: 0.66, alpha: 0.55) : CGColor(gray: 1, alpha: 0.28)
    ctx.setFillColor(ink)
    let lineHeight: CGFloat = 22
    let inset = rect.height / 3.4
    ctx.addPath(rounded(CGRect(x: rect.minX + inset, y: rect.midY + 6, width: rect.width - 2 * inset, height: lineHeight),
                        lineHeight / 2))
    ctx.addPath(rounded(CGRect(x: rect.minX + inset, y: rect.midY - lineHeight - 10,
                               width: (rect.width - 2 * inset) * 0.62, height: lineHeight), lineHeight / 2))
    ctx.fillPath()
    // Light along the top edge.
    ctx.addPath(rounded(rect.insetBy(dx: 1.5, dy: 1.5), rect.height / 2.6 - 1.5))
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, 1, 1, 1, light ? 0.95 : 0.45), (0.5, 1, 1, 1, 0), (1, 0, 0, 0, 0.25)]),
                           start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Body with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Deep graphite to black, lit from above, with a faint blue glow behind the highlight.
    ctx.drawLinearGradient(gradient([(0, 0.21, 0.22, 0.25, 1), (0.55, 0.08, 0.08, 0.09, 1), (1, 0.02, 0.02, 0.025, 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(gradient([(0, blue.r, blue.g, blue.b, 0.22), (1, blue.r, blue.g, blue.b, 0)]),
                           startCenter: CGPoint(x: 560, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 560, y: 470), endRadius: 420, options: [])

    // The island hanging from the top edge.
    let island = CGRect(x: 512 - 150, y: 924 - 92, width: 300, height: 120)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(rounded(island, 46))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // A tiny thumbnail and a check mark in the island.
    ctx.setFillColor(CGColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 0.9))
    ctx.addPath(rounded(CGRect(x: island.minX + 34, y: island.minY + 22, width: 46, height: 30), 7))
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 0.20, green: 0.84, blue: 0.42, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: island.maxX - 34 - 30, y: island.minY + 22, width: 30, height: 30))

    // Glass rim: bright along the top, faint along the bottom.
    ctx.addPath(squircle(body.insetBy(dx: 2, dy: 2)))
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, 1, 1, 1, 0.42), (0.35, 1, 1, 1, 0.06), (0.7, 1, 1, 1, 0.03), (1, 1, 1, 1, 0.14)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Three bubbles of a chat; the middle one is the capture.
    let incoming1 = CGRect(x: 196, y: 590, width: 400, height: 132)
    let picked = CGRect(x: 392, y: 404, width: 436, height: 140)
    let incoming2 = CGRect(x: 196, y: 214, width: 340, height: 132)
    ctx.saveGState()
    ctx.setAlpha(0.55)
    bubble(ctx, incoming1, light: false)
    bubble(ctx, incoming2, light: false)
    ctx.restoreGState()
    bubble(ctx, picked, light: true)

    // The highlight: a glowing blue outline and viewfinder corners around the picked bubble.
    let ring = picked.insetBy(dx: -22, dy: -22)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: CGColor(red: blue.r, green: blue.g, blue: blue.b, alpha: 0.95))
    ctx.addPath(rounded(ring, 30))
    ctx.setStrokeColor(CGColor(red: blue.r, green: blue.g, blue: blue.b, alpha: 1))
    ctx.setLineWidth(9)
    ctx.strokePath()
    ctx.restoreGState()

    let corner = ring.insetBy(dx: -26, dy: -26)
    let arm: CGFloat = 58
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    ctx.setLineWidth(12)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (x, y, dx, dy) in [(corner.minX, corner.minY, 1.0, 1.0), (corner.maxX, corner.minY, -1.0, 1.0),
                           (corner.minX, corner.maxY, 1.0, -1.0), (corner.maxX, corner.maxY, -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: x, y: y + dy * arm))
        ctx.addLine(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + dx * arm, y: y))
    }
    ctx.strokePath()

    // The pointer resting on the bubble.
    let tip = CGPoint(x: picked.maxX - 110, y: picked.minY + 46)
    let arrow = CGMutablePath()
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -150), (36, -116), (64, -178), (92, -166), (64, -106), (112, -106)]
    arrow.move(to: CGPoint(x: tip.x + pts[0].0, y: tip.y + pts[0].1))
    for p in pts.dropFirst() { arrow.addLine(to: CGPoint(x: tip.x + p.0, y: tip.y + p.1)) }
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(arrow)
    ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(arrow)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(10)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.addPath(arrow)
    ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
    ctx.fillPath()

    return ctx.makeImage()!
}

func png(size: Int) -> Data {
    NSBitmapImageRep(cgImage: render(size: size)).representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    try png(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}
try png(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Resources/AppIcon.icns written" : "iconutil failed")
