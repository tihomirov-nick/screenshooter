// Renders the app icon: Resources/AppIcon.icon (the Icon Composer package that build_app.sh compiles with actool)
// and Resources/AppIcon-1024.png (the whole icon, for the README).
// Usage: swift scripts/make_icon.swift
//
// Screen + shooter: the view down a rifled gun barrel, like the gun barrel opening of the Bond films, and only the
// barrel: no figure in the bore, no gun. Flat and strictly black and white, like the other apps of the family: a black
// body and white marks, with no greys, gradients or shadows. Two white rings, the muzzle outside and the edge of the bore
// inside, and six spiral lines running from one ring to the other, all of one width. The hole inside the inner ring is
// left black. The lines are logarithmic spirals, so the gaps between them close in towards the bore as down a tunnel:
// that is all the perspective there is. The outer ring keeps a black border round the body clear.
//
// Where a line meets a ring it branches off it instead of cutting into it. Over the last part of its length at each end
// the line turns from 23° to the ring's tangent to 12°, smoothly, so the bend at the join is mild. Then the whole white
// shape gets a morphological closing with a disc of 10 px (0.3 of the line width) on a 4096 grid: the narrow tip of the
// black wedge between a line and a ring becomes round, nothing else changes. Bigger discs fill whole ends of the black
// spaces between the lines.
import AppKit

let bodyColor: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0, 0, 0)

/// Sizes in half-bodies (412 px of the 1024 icon) from the centre.
let barrelWidth = 0.08              // 33 px for the rings and the lines alike: lines stay apart in a 32 px icon
let barrelMouth = 0.85              // outer edge of the outer ring, leaving a black border of 62 px at the sides
let barrelHole = 0.34               // inner edge of the inner ring: the black hole
let barrelGrid = 4096               // pixels across the body for the closing

/// The middle line of one spiral, from the outer ring's middle to the inner one's. In the middle the spiral keeps the
/// angle of a logarithmic spiral (67° to the radius, as when it wound 0.35 of a turn from the mouth to the hole); towards
/// both ends the angle to the ring's tangent eases down to 12° along a smootherstep, over about 18 % of the length.
func barrelSpiral(start: Double, steps: Int = 2000) -> [(Double, Double)] {
    let outer = barrelMouth - barrelWidth / 2, inner = barrelHole + barrelWidth / 2
    let kMid = 0.35 * 2 * .pi / log(barrelMouth / barrelHole), kEnd = 1 / tan(12 * Double.pi / 180)
    let zoneOut = 0.13, zoneIn = 0.25       // shares of the log radius: each about 18 % of the length
    func ease(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * t * (t * (t * 6 - 15) + 10) }
    let span = log(outer / inner)
    var theta = start + kMid * log(barrelMouth / outer)
    var points = [(outer * cos(theta), outer * sin(theta))]
    for i in 1...steps {
        let t = (Double(i) - 0.5) / Double(steps)
        let bend = max(1 - ease(t / zoneOut), 1 - ease((1 - t) / zoneIn))
        theta += (kMid + (kEnd - kMid) * bend) * span / Double(steps)
        let r = outer * exp(-span * Double(i) / Double(steps))
        points.append((r * cos(theta), r * sin(theta)))
    }
    return points
}

/// Squared Euclidean distance transform of an n × n grid in place (Felzenszwalb and Huttenlocher): 0 at the feature
/// pixels, a huge value elsewhere on input; the squared distance to the nearest feature pixel on output.
func distanceTransform(_ grid: UnsafeMutableBufferPointer<Double>, _ n: Int) {
    let f = UnsafeMutableBufferPointer<Double>.allocate(capacity: n), d = UnsafeMutableBufferPointer<Double>.allocate(capacity: n)
    let v = UnsafeMutableBufferPointer<Int>.allocate(capacity: n), z = UnsafeMutableBufferPointer<Double>.allocate(capacity: n + 1)
    defer { f.deallocate(); d.deallocate(); v.deallocate(); z.deallocate() }
    func pass() {
        var k = 0
        v[0] = 0; z[0] = -1e20; z[1] = 1e20
        for q in 1..<n {
            var s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * (q - v[k]))
            while s <= z[k] {
                k -= 1
                s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * (q - v[k]))
            }
            k += 1
            v[k] = q; z[k] = s; z[k + 1] = 1e20
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            d[q] = Double((q - v[k]) * (q - v[k])) + f[v[k]]
        }
    }
    for x in 0..<n {
        for y in 0..<n { f[y] = grid[y * n + x] }
        pass()
        for y in 0..<n { grid[y * n + x] = d[y] }
    }
    for y in 0..<n {
        for x in 0..<n { f[x] = grid[y * n + x] }
        pass()
        for x in 0..<n { grid[y * n + x] = d[x] }
    }
}

/// The signed distance, in grid pixels and positive inside, to the edge of the white shape after the closing; the grid
/// covers the body square, row 0 at the top. Made once.
let barrelField: [Double] = {
    let n = barrelGrid, unit = Double(n) / 2
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    func point(_ p: (Double, Double)) -> CGPoint { CGPoint(x: unit + unit * p.0, y: unit + unit * p.1) }
    let path = CGMutablePath()
    for r in [barrelMouth - barrelWidth / 2, barrelHole + barrelWidth / 2] {
        path.addEllipse(in: CGRect(x: unit - unit * r, y: unit - unit * r, width: 2 * unit * r, height: 2 * unit * r))
    }
    // The lines' flat ends lie within the rings' strokes.
    for line in 0..<6 {
        let points = barrelSpiral(start: Double(line) * .pi / 3 + .pi / 2)
        path.move(to: point(points[0]))
        for p in points.dropFirst() { path.addLine(to: point(p)) }
    }
    ctx.addPath(path)
    ctx.setStrokeColor(gray: 1, alpha: 1)
    ctx.setLineWidth(barrelWidth * unit)
    ctx.setLineCap(.butt)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n)
    let radius = 0.3 * barrelWidth * unit
    // Dilation: everything within the radius of the white. Erosion of that: what stays the radius away from its outside.
    let toWhite = UnsafeMutableBufferPointer<Double>.allocate(capacity: n * n)
    let toOutside = UnsafeMutableBufferPointer<Double>.allocate(capacity: n * n)
    defer { toWhite.deallocate(); toOutside.deallocate() }
    for i in 0..<(n * n) { toWhite[i] = pixels[i] >= 128 ? 0 : 1e20 }
    distanceTransform(toWhite, n)
    for i in 0..<(n * n) { toOutside[i] = toWhite[i] <= radius * radius ? 1e20 : 0 }
    distanceTransform(toOutside, n)
    var field = [Double](repeating: 0, count: n * n)
    for i in 0..<(n * n) {
        field[i] = toOutside[i] > 0 ? toOutside[i].squareRoot() - radius : -toWhite[i].squareRoot()
    }
    return field
}()

/// The mark, drawn with the current (white) colours in the flat drawing's coordinates: a 1024 square whose body is the
/// squircle at 100...924, y growing upwards. The edge comes from the distance field, sampled once per device pixel.
func drawMark(_ ctx: CGContext) {
    let n = barrelGrid
    let side = Int((824 * ctx.ctm.a).rounded())                 // device pixels across the body
    let gridPerPixel = Double(n) / Double(side)
    var rgba = [UInt8](repeating: 0, count: side * side * 4)
    for j in 0..<side {
        for i in 0..<side {
            // Bilinear sample of the field at the pixel's centre.
            let gx = min(max((Double(i) + 0.5) * gridPerPixel - 0.5, 0), Double(n - 1))
            let gy = min(max((Double(j) + 0.5) * gridPerPixel - 0.5, 0), Double(n - 1))
            let x0 = Int(gx), y0 = Int(gy), x1 = min(x0 + 1, n - 1), y1 = min(y0 + 1, n - 1)
            let ax = gx - Double(x0), ay = gy - Double(y0)
            let top = barrelField[y0 * n + x0] * (1 - ax) + barrelField[y0 * n + x1] * ax
            let bottom = barrelField[y1 * n + x0] * (1 - ax) + barrelField[y1 * n + x1] * ax
            let coverage = min(max(0.5 + (top * (1 - ay) + bottom * ay) / gridPerPixel, 0), 1)
            let value = UInt8(coverage * 255 + 0.5)
            let o = (j * side + i) * 4
            rgba[o] = value; rgba[o + 1] = value; rgba[o + 2] = value; rgba[o + 3] = value
        }
    }
    let bitmap = CGContext(data: &rgba, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(bitmap.makeImage()!, in: CGRect(x: 100, y: 100, width: 824, height: 824))
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
