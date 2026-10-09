// Renders the app icon: Resources/AppIcon.icon (the Icon Composer package that build_app.sh compiles with actool)
// and Resources/AppIcon-1024.png (the whole icon, for the README).
// Usage: swift scripts/make_icon.swift
//
// The icon is the menu bar glyph drawn large, white on the black body. Screen + shooter: the view down a rifled gun
// barrel, like the gun barrel opening of the Bond films, and only the barrel: no figure in the bore, no gun. Flat and
// strictly black and white, like the other apps of the family: a black body and white marks, with no greys, gradients
// or shadows. Two rings, the muzzle outside and the edge of the bore inside, and six logarithmic spirals running from
// one ring to the other, all of one width. The hole inside the inner ring is left black. The outer ring keeps a black
// border round the body clear.
//
// The drawing is StatusIcon's, line for line, only bigger: the same proportions of the rings and the hole, the same six
// grooves and twist, the same gentle entry into the rings (towards both ends a groove eases from 23° to the ring's
// tangent down to 12°) and the same width of line against the diameter, 4.2 %. The one addition is a light rounding of
// the tips of the black wedges between a groove and a ring: in the menu bar they are far below a pixel, here the last
// pixels of each tip would run out into a hairline.
import AppKit

let bodyColor: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0, 0, 0)

// MARK: - The mark

// These numbers must stay equal to StatusIcon's (Sources/Screenshooter/App/StatusIcon.swift), and markPaths below is a
// copy of StatusIcon.markPaths: change them together, or the icon and the menu bar glyph stop being one drawing.
let glyphDiameter: CGFloat = 14.31      // StatusIcon.diameter
let glyphLineWidth: CGFloat = 0.6       // StatusIcon.lineWidth
let glyphGrooves = 6                    // StatusIcon.grooves

/// The glyph on the flat drawing, whose body is the 824 px square at 100...924 of 1024: the outer edge of the muzzle
/// 350 px from the centre, which leaves a black border of 62 px at the sides.
let markSide: CGFloat = 0.85 * 824                                  // 700.4 px across
let markLineWidth = markSide * glyphLineWidth / glyphDiameter       // 29.4 px
/// The rounding of the wedges' tips: the radius of a morphological closing, in line widths.
let tipRounding: CGFloat = 0.15

/// StatusIcon.markPaths, line for line (without `turn`): the mark in a square of `side` points with y growing down.
/// Middle lines, to be stroked `lineWidth` wide with round caps and joins. Also returns the rings' radii and each
/// groove's points, from the muzzle to the bore, for the rounding of the tips.
func markPaths(side: CGFloat, lineWidth: CGFloat, grooves: Int = glyphGrooves)
    -> (rings: CGPath, grooves: CGPath, muzzle: CGFloat, bore: CGFloat, points: [[CGPoint]]) {
    let c = CGPoint(x: side / 2, y: side / 2)
    let muzzle = (side - lineWidth) / 2
    let bore = side / 2 * (2.8 / 7.155) + lineWidth / 2
    let twist: CGFloat = 2.4, twistAtRing = 1 / tan(12 * CGFloat.pi / 180)
    func ease(_ x: CGFloat) -> CGFloat { let t = min(max(x, 0), 1); return t * t * t * (t * (t * 6 - 15) + 10) }
    let span = log(muzzle / bore)
    let rings = CGMutablePath()
    rings.addEllipse(in: CGRect(x: c.x - muzzle, y: c.y - muzzle, width: 2 * muzzle, height: 2 * muzzle))
    rings.addEllipse(in: CGRect(x: c.x - bore, y: c.y - bore, width: 2 * bore, height: 2 * bore))
    // Logarithmic spirals from the middle of one ring to the middle of the other; their ends stay within the rings'
    // strokes.
    let lines = CGMutablePath()
    var points: [[CGPoint]] = []
    for k in 0..<grooves {
        var a = CGFloat(k) * 2 * .pi / CGFloat(grooves) - .pi / 2
        var line: [CGPoint] = []
        for i in 0...96 {
            if i > 0 {
                let t = (CGFloat(i) - 0.5) / 96
                let bend = max(1 - ease(t / 0.13), 1 - ease((1 - t) / 0.25))
                a += (twist + (twistAtRing - twist) * bend) * span / 96
            }
            let r = muzzle * exp(-span * CGFloat(i) / 96)
            let point = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if i == 0 { lines.move(to: point) } else { lines.addLine(to: point) }
            line.append(point)
        }
        points.append(line)
    }
    return (rings, lines, muzzle, bore, points)
}

/// The tip of the black wedge between one end of a groove and its ring, filled the way a morphological closing with a
/// disc of `radius` fills it: up to the arc of that radius which touches both edges. The shape reaches back into the
/// white of both lines, as far as their middle lines, so that its only edge on the black is the arc. `line` runs from
/// the muzzle to the bore; `outer` takes its end at the muzzle, of radius `ring` round `c`.
func tipFill(line: [CGPoint], center c: CGPoint, ring: CGFloat, lineWidth w: CGFloat, radius: CGFloat,
             outer: Bool) -> CGPath {
    func closest(_ p: CGPoint) -> (point: CGPoint, distance: CGFloat, segment: Int) {
        var best = (point: line[0], distance: CGFloat.infinity, segment: 0)
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy), 0), 1)
            let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = hypot(p.x - q.x, p.y - q.y)
            if d < best.distance { best = (q, d, i) }
        }
        return best
    }
    func onCircle(_ r: CGFloat, _ phi: CGFloat) -> CGPoint { CGPoint(x: c.x + r * cos(phi), y: c.y + r * sin(phi)) }
    let end = outer ? line[0] : line[line.count - 1]
    let endAngle = atan2(end.y - c.y, end.x - c.x)
    // The disc keeps `radius` off the ring's edge and off the groove's, so its centre lies on the circle `rho`, where
    // it is w / 2 + radius from the groove's middle line. From the groove's end the wedge opens along the groove: away
    // from the muzzle the groove turns with growing angle, towards the bore against it.
    let rho = outer ? ring - w / 2 - radius : ring + w / 2 + radius
    let way: CGFloat = outer ? 1 : -1
    func gap(_ phi: CGFloat) -> CGFloat { closest(onCircle(rho, phi)).distance - (w / 2 + radius) }
    var near = endAngle, far = endAngle
    repeat { near = far; far += way * 0.002 } while gap(far) < 0
    for _ in 0..<60 {
        let mid = (near + far) / 2
        if gap(mid) < 0 { near = mid } else { far = mid }
    }
    let centre = onCircle(rho, far)
    let foot = closest(centre)
    let onGroove = CGPoint(x: foot.point.x + (centre.x - foot.point.x) * w / 2 / foot.distance,
                           y: foot.point.y + (centre.y - foot.point.y) * w / 2 / foot.distance)
    let onRing = onCircle(outer ? ring - w / 2 : ring + w / 2, far)
    // The arc between the two points of contact on the side facing the tip.
    let from = atan2(onGroove.y - centre.y, onGroove.x - centre.x), to = atan2(onRing.y - centre.y, onRing.x - centre.x)
    var sweep = (to - from).remainder(dividingBy: 2 * .pi)
    let middle = CGPoint(x: centre.x + radius * cos(from + sweep / 2), y: centre.y + radius * sin(from + sweep / 2))
    let opposite = CGPoint(x: 2 * centre.x - middle.x, y: 2 * centre.y - middle.y)
    if hypot(opposite.x - end.x, opposite.y - end.y) < hypot(middle.x - end.x, middle.y - end.y) {
        sweep -= (sweep < 0 ? -2 : 2) * .pi
    }
    let path = CGMutablePath()
    path.move(to: onGroove)
    for j in 1...48 {
        let a = from + sweep * CGFloat(j) / 48
        path.addLine(to: CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a)))
    }
    // Back through the white: out to the ring's middle line, along it to the groove's end and back along the groove's.
    for j in 0...64 { path.addLine(to: onCircle(ring, far + (endAngle - far) * CGFloat(j) / 64)) }
    let back = outer ? Array(line[1..<(foot.segment + 1)])
                     : Array(line[(foot.segment + 1)..<(line.count - 1)].reversed())
    for p in back { path.addLine(to: p) }
    path.addLine(to: foot.point)
    path.closeSubpath()
    return path
}

/// The white mark as coverage, 0...255, in a `size` × `size` grey bitmap with row 0 at the top: the glyph centred, at
/// `scale` device pixels to a pixel of the flat drawing.
func markCoverage(size: Int, scale: CGFloat) -> [UInt8] {
    let side = markSide * scale, w = markLineWidth * scale
    let mark = markPaths(side: side, lineWidth: w)
    let c = CGPoint(x: side / 2, y: side / 2)
    let tips = CGMutablePath(), radius = tipRounding * w
    if radius > 0 {
        for line in mark.points {
            tips.addPath(tipFill(line: line, center: c, ring: mark.muzzle, lineWidth: w, radius: radius, outer: true))
            tips.addPath(tipFill(line: line, center: c, ring: mark.bore, lineWidth: w, radius: radius, outer: false))
        }
    }
    // The rings, the grooves and the tips each in a layer of its own, put together by keeping the lighter pixel: where
    // the edges of two of them run together, laying one over the other would add up their antialiasing into a bump.
    func layer(_ draw: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(size))     // y growing down, as in StatusIcon
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: (CGFloat(size) - side) / 2, y: (CGFloat(size) - side) / 2)
            ctx.setFlatness(0.05)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            draw(ctx)
        }
        return pixels
    }
    let rings = layer { $0.addPath(mark.rings); $0.strokePath() }
    let grooves = layer { $0.addPath(mark.grooves); $0.strokePath() }
    let filled = layer { $0.addPath(tips); $0.fillPath() }
    return (0..<(size * size)).map { max(rings[$0], grooves[$0], filled[$0]) }
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
