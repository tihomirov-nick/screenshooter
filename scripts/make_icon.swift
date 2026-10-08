// Renders the app icon: Resources/AppIcon.icon (the Icon Composer package that build_app.sh compiles with actool)
// and Resources/AppIcon-1024.png (the whole icon, for the README).
// Usage: swift scripts/make_icon.swift
//
// Screen + shooter: the view straight down a gun barrel, the rifling turning inside it, like the gun barrel opening of
// the Bond films. Only the muzzle and the rifling, no gun. Flat, black and white, like the other apps of the family:
// a pure black body and white marks, flat fills only, with no gradients, glass or shadows. The one grey (white at
// 45 % over the black body) gives depth. The mark is the muzzle ring, about as heavy as the family's marks (80 px; the
// pills of the other icons are 84), rings of the bore in grey shrinking into the dark, and five grooves turning in
// across them. The grooves are logarithmic spirals that narrow with depth, as down a tunnel; they leave the muzzle
// from under the ring and end short of the centre, which stays dark.
import AppKit

let bodyColor: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0, 0, 0)

/// The mark, drawn with the current (white) colours in the flat drawing's coordinates: a 1024 square whose body is the
/// squircle at 100...924, y growing upwards.
func drawMark(_ ctx: CGContext) {
    let center = CGPoint(x: 512, y: 512)
    func ring(radius: CGFloat, width: CGFloat) {
        ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        ctx.setLineWidth(width)
        ctx.strokePath()
    }
    /// A groove: a logarithmic spiral from radius `outer` in to `inner`, turning by `twist` radians on the way, its
    /// width shrinking with the radius as if seen down a tunnel; filled, with a round inner end.
    func groove(start: CGFloat, outer: CGFloat, inner: CGFloat, twist: CGFloat, width: CGFloat) {
        func point(_ f: CGFloat) -> (CGPoint, CGFloat) {
            let r = outer * pow(inner / outer, f), a = start + twist * f
            return (CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)), r)
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        let steps = 120
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let (p, r) = point(f)
            let (ahead, _) = point(min(1, f + 0.001)), (behind, _) = point(max(0, f - 0.001))
            let length = hypot(ahead.x - behind.x, ahead.y - behind.y)
            let normal = CGPoint(x: -(ahead.y - behind.y) / length, y: (ahead.x - behind.x) / length)
            let half = width * r / outer / 2
            left.append(CGPoint(x: p.x + normal.x * half, y: p.y + normal.y * half))
            right.append(CGPoint(x: p.x - normal.x * half, y: p.y - normal.y * half))
        }
        ctx.move(to: left[0])
        for p in left.dropFirst() + right.reversed() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.fillPath()
        let (end, r) = point(1)
        let half = width * r / outer / 2
        ctx.fillEllipse(in: CGRect(x: end.x - half, y: end.y - half, width: 2 * half, height: 2 * half))
    }

    // The muzzle takes about three quarters of the body, as wide as the other icons' marks look.
    ring(radius: 262, width: 80)
    // The bore in perspective: rings closer and thinner the deeper they are, in grey.
    ctx.saveGState()
    ctx.setAlpha(0.45)
    for (radius, width) in [(176.0, 26.0), (112.0, 18.0), (72.0, 12.0)] { ring(radius: radius, width: width) }
    ctx.restoreGState()
    // Five grooves, broad enough to show at 32 px.
    for k in 0..<5 {
        groove(start: CGFloat(k) * 2 * .pi / 5 + 0.2, outer: 262, inner: 30, twist: 2.0, width: 84)
    }
}

// MARK: - The icon files (the same in every app of the family)

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let white = CGColor(colorSpace: space, components: [1, 1, 1, 1])!

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

/// A transparent 1024 × 1024 image, drawn into with white as the colour.
func image(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(white)
    ctx.setStrokeColor(white)
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

// Resources/AppIcon.icon. In the Icon Composer format the 1024 canvas is the whole tile: the system cuts the squircle and
// leaves the margins itself. So the mark, laid out on the body of the flat drawing (824 of 1024 from 100), is scaled by
// 1024 / 824 to take the same part of the tile. One layer, the white mark on transparent; a solid fill in the body's
// colour; no glass, shadow, translucency or specular highlights, so the icon stays flat. On macOS 26 such an icon shows
// without the grey plate that the system puts around plain .icns icons.
let package = root.appendingPathComponent("Resources/AppIcon.icon")
try? FileManager.default.removeItem(at: package)
try FileManager.default.createDirectory(at: package.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try writePNG(image { ctx in
    ctx.scaleBy(x: 1024 / 824, y: 1024 / 824)
    ctx.translateBy(x: -100, y: -100)
    drawMark(ctx)
}, to: package.appendingPathComponent("Assets/mark.png"))
let fill = String(format: "srgb:%.5f,%.5f,%.5f,1.00000", bodyColor.red, bodyColor.green, bodyColor.blue)
try Data("""
{
  "fill" : {
    "solid" : "\(fill)"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "mark.png",
          "name" : "mark"
        }
      ],
      "shadow" : {
        "kind" : "none",
        "opacity" : 0
      },
      "specular" : false,
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

""".utf8).write(to: package.appendingPathComponent("icon.json"))

// Resources/AppIcon-1024.png: the whole icon, the body in the squircle with the mark, for the README.
try writePNG(image { ctx in
    ctx.addPath(squircle(CGRect(x: 100, y: 100, width: 824, height: 824)))
    ctx.setFillColor(CGColor(colorSpace: space, components: [bodyColor.red, bodyColor.green, bodyColor.blue, 1])!)
    ctx.fillPath()
    ctx.setFillColor(white)
    drawMark(ctx)
}, to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
print("Resources/AppIcon.icon and Resources/AppIcon-1024.png written")
