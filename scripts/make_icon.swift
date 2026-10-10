// Renders the app icon: Resources/AppIcon.icon (the Icon Composer package that build_app.sh compiles with actool)
// and Resources/AppIcon-1024.png (the whole icon, for the README).
// Usage: swift scripts/make_icon.swift
//
// The icon is the app's mark drawn large, white on the black body: flat and strictly black and white, like the other
// apps of the family, with no greys, gradients or shadows. The mark is a selection: a frame of strokes with rounded
// corners and a plus in place of its bottom right corner, in the proportions of the user's sample. The drawing is
// StatusIcon.selectionPaths without the pixel grid, with one addition: the strokes' straight ends get slightly rounded
// corners, as on the sample. The line is a tenth of the frame's side, as on the sample. The mark's box takes 80% of the
// tile, as big as the marks of the other apps of the family, in the middle of the body and clear of its rounded corners.
import AppKit

let bodyColor: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0, 0, 0)

// MARK: - The mark

// StatusIcon.Selection, number for number, and selectionPaths below is a copy of StatusIcon.selectionPaths: change them
// together, or the icon and the menu bar glyph stop being one drawing.
let selectionArm: CGFloat = 0.283       // StatusIcon.Selection.arm
let selectionGap: CGFloat = 0.102       // StatusIcon.Selection.gap
let selectionReach: CGFloat = 0.243     // StatusIcon.Selection.reach
let selectionRadius: CGFloat = 0.107    // StatusIcon.Selection.radius
let selectionLine: CGFloat = 0.0997     // StatusIcon.Selection.line

/// The selection on the flat drawing, whose body is the 824 px square at 100...924 of 1024: its box takes `tileFill` of
/// the body, 659 px from the outer edges of the left and top lines to the plus's ends (819 px of the Icon Composer
/// tile), in lines of 50.8 px (63 px on the tile). Its box sits in the middle of the body. The frame's three corners
/// come closest to the body's rounded corners, and they stay 72 px clear of them, 9% of the body's side (measured on
/// AppIcon-1024.png).
let tileFill: CGFloat = 0.8
let selectionSide: CGFloat = tileFill * 824
let selectionLineWidth = selectionLine * selectionSide / (1 + selectionReach + selectionLine / 2)
/// The corners of the strokes' ends: rounded by an eighth of the line.
let endRounding: CGFloat = 0.125

/// StatusIcon.selectionPaths without the pixel grid, in a square of `side` pixels with y growing down,
/// the frame's strokes and the plus in one path to be filled. With `rounding`, the strokes are that much shorter at
/// each end and that much thinner on each side, to be grown back by stroking the path `2 * rounding` wide with round
/// joins: the corners of their ends come out round and everything else where it was.
func selectionPaths(side: CGFloat, lineWidth w: CGFloat, rounding e: CGFloat = 0) -> CGPath {
    let frame = (side - w / 2) / (1 + selectionReach)
    let near = w / 2, far = near + frame, armEnd = near + selectionArm * frame, dashStart = armEnd + selectionGap * frame
    let r = selectionRadius * frame, inner = near + far - armEnd
    // The frame's middle line, clockwise from the inner end of the plus's horizontal bar round to that of its vertical
    // bar, and along it one side's pattern over and over: a dash, a gap, a corner (both its arms and the bend), a gap.
    let line = CGMutablePath()
    line.move(to: CGPoint(x: inner, y: far))
    line.addArc(tangent1End: CGPoint(x: near, y: far), tangent2End: CGPoint(x: near, y: near), radius: r)
    line.addArc(tangent1End: CGPoint(x: near, y: near), tangent2End: CGPoint(x: far, y: near), radius: r)
    line.addArc(tangent1End: CGPoint(x: far, y: near), tangent2End: CGPoint(x: far, y: far), radius: r)
    line.addLine(to: CGPoint(x: far, y: inner))
    let gap = dashStart - armEnd, dash = near + far - 2 * dashStart, corner = 2 * (armEnd - near - r) + .pi / 2 * r
    let period = dash + corner + 2 * gap
    let path = CGMutablePath()
    path.addPath(line.copy(dashingWithPhase: period - gap - e, lengths: [dash - 2 * e, gap + 2 * e, corner - 2 * e, gap + 2 * e])
        .copy(strokingWithWidth: w - 2 * e, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
    path.addRect(CGRect(x: inner + e, y: far - w / 2 + e, width: side - inner - 2 * e, height: w - 2 * e))
    path.addRect(CGRect(x: far - w / 2 + e, y: inner + e, width: w - 2 * e, height: side - inner - 2 * e))
    return path
}

/// The white mark as coverage, 0...255, in a `size` × `size` grey bitmap with row 0 at the top: the mark's box
/// centred, at `scale` device pixels to a pixel of the flat drawing.
func markCoverage(size: Int, scale: CGFloat) -> [UInt8] {
    let side = selectionSide * scale, w = selectionLineWidth * scale, e = endRounding * w
    let mark = selectionPaths(side: side, lineWidth: w, rounding: e)
    var pixels = [UInt8](repeating: 0, count: size * size)
    pixels.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(size))     // y growing down, as in StatusIcon
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: (CGFloat(size) - side) / 2, y: (CGFloat(size) - side) / 2)
        ctx.setFlatness(0.05)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(mark)
        ctx.fillPath()
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(2 * e)
        ctx.setLineJoin(.round)
        ctx.addPath(mark)
        ctx.strokePath()
    }
    return pixels
}

// MARK: - The icon files (the same in every app of the family)

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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

/// A transparent 1024 × 1024 image: `draw` paints into it, then the mark at `scale` goes over it in white.
func image(markScale scale: CGFloat, _ draw: (CGContext) -> Void = { _ in }) -> CGImage {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 1024 * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    let coverage = markCoverage(size: 1024, scale: scale)
    let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: 1024 * 1024 * 4)
    for i in 0..<(1024 * 1024) where coverage[i] > 0 {
        let v = UInt16(coverage[i])
        for channel in 0..<4 {
            let o = i * 4 + channel
            pixels[o] = UInt8(v + (UInt16(pixels[o]) * (255 - v) + 127) / 255)
        }
    }
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
try writePNG(image(markScale: 1024 / 824), to: package.appendingPathComponent("Assets/mark.png"))
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
try writePNG(image(markScale: 1) { ctx in
    ctx.addPath(squircle(CGRect(x: 100, y: 100, width: 824, height: 824)))
    ctx.setFillColor(CGColor(colorSpace: space, components: [bodyColor.red, bodyColor.green, bodyColor.blue, 1])!)
    ctx.fillPath()
}, to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
print("Resources/AppIcon.icon and Resources/AppIcon-1024.png written")
