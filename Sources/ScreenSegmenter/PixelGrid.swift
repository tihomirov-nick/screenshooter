import CoreGraphics

/// The image reduced to about one sample per point by averaging blocks of pixels, so thresholds can be
/// written in points and a 1-pixel hairline on a Retina screen still shows up (at half contrast).
///
/// Samples are packed as 0xAABBGGRR words with A = 0 for opaque samples and A = 0xFF for transparent ones
/// (rounded window corners, shadows), so a transparent sample never looks similar to an opaque one.
struct PixelGrid {
    let width: Int
    let height: Int
    /// Image pixels per sample along each axis.
    let factor: Int
    let imageWidth: Int
    let imageHeight: Int
    let samples: [UInt32]

    static let transparent: UInt32 = 0xFF00_0000

    init?(image: CGImage, pixelScale: CGFloat) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let f = max(1, min(4, Int(pixelScale.rounded())))
        guard let rgba = PixelGrid.rgbaPixels(of: image) else { return nil }

        let gw = (w + f - 1) / f, gh = (h + f - 1) / f
        var out = [UInt32](repeating: 0, count: gw * gh)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                if f == 1 {
                    for i in 0..<(w * h) { dst[i] = PixelGrid.pack(src[i]) }
                } else if f == 2 {
                    PixelGrid.average2x2(src: src.baseAddress!, w: w, h: h, dst: dst.baseAddress!, gw: gw, gh: gh)
                } else {
                    PixelGrid.averageBlocks(src: src.baseAddress!, w: w, h: h, f: f, dst: dst.baseAddress!, gw: gw, gh: gh)
                }
            }
        }
        width = gw
        height = gh
        factor = f
        imageWidth = w
        imageHeight = h
        samples = out
    }

    /// Opaque colour of an RGBA word (memory order R, G, B, A), or the transparent marker.
    @inline(__always)
    static func pack(_ p: UInt32) -> UInt32 {
        (p >> 24) < 128 ? transparent : (p & 0x00FF_FFFF)
    }

    /// Exact 2×2 box average with four lanes per word: two 16-bit sums hold R+B and G+A.
    private static func average2x2(src: UnsafePointer<UInt32>, w: Int, h: Int,
                                   dst: UnsafeMutablePointer<UInt32>, gw: Int, gh: Int) {
        let mask: UInt32 = 0x00FF_00FF
        for gy in 0..<gh {
            let y0 = gy * 2
            let y1 = min(y0 + 1, h - 1)
            let r0 = src + y0 * w, r1 = src + y1 * w
            let out = dst + gy * gw
            for gx in 0..<gw {
                let x0 = gx * 2
                let x1 = min(x0 + 1, w - 1)
                let a = r0[x0], b = r0[x1], c = r1[x0], d = r1[x1]
                if a == b && a == c && a == d {
                    out[gx] = pack(a)
                    continue
                }
                let lo = (a & mask) + (b & mask) + (c & mask) + (d & mask)
                let hi = ((a >> 8) & mask) + ((b >> 8) & mask) + ((c >> 8) & mask) + ((d >> 8) & mask)
                let avg = ((lo >> 2) & mask) | (((hi >> 2) & mask) << 8)
                out[gx] = pack(avg)
            }
        }
    }

    private static func averageBlocks(src: UnsafePointer<UInt32>, w: Int, h: Int, f: Int,
                                      dst: UnsafeMutablePointer<UInt32>, gw: Int, gh: Int) {
        for gy in 0..<gh {
            let y0 = gy * f, y1 = min(y0 + f, h)
            for gx in 0..<gw {
                let x0 = gx * f, x1 = min(x0 + f, w)
                var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 0
                for y in y0..<y1 {
                    let row = src + y * w
                    for x in x0..<x1 {
                        let p = row[x]
                        r += p & 0xFF
                        g += (p >> 8) & 0xFF
                        b += (p >> 16) & 0xFF
                        a += p >> 24
                    }
                }
                let n = UInt32((y1 - y0) * (x1 - x0))
                dst[gy * gw + gx] = pack((r / n) | ((g / n) << 8) | ((b / n) << 16) | ((a / n) << 24))
            }
        }
    }

    /// Pixels as RGBA words in memory order R, G, B, A, top row first. Drawn into a bitmap of the image's
    /// own RGB colour space when possible, so no colour matching runs (and cropped images work, unlike
    /// reading the data provider directly).
    private static func rgbaPixels(of image: CGImage) -> [UInt32]? {
        let w = image.width, h = image.height
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var spaces: [CGColorSpace] = []
        if let own = image.colorSpace, own.model == .rgb { spaces.append(own) }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { spaces.append(srgb) }

        var pixels = [UInt32](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            for space in spaces {
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space, bitmapInfo: info) else { continue }
                ctx.interpolationQuality = .none
                ctx.setBlendMode(.copy)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return false
        }
        // Words are read little-endian: memory R,G,B,A becomes 0xAABBGGRR, as `pack` expects.
        return drawn ? pixels : nil
    }
}

/// Largest difference of the four bytes of two packed samples.
@inline(__always)
func colorDistance(_ a: UInt32, _ b: UInt32) -> UInt32 {
    if a == b { return 0 }
    let r = a & 0xFF, r2 = b & 0xFF
    let g = (a >> 8) & 0xFF, g2 = (b >> 8) & 0xFF
    let bl = (a >> 16) & 0xFF, bl2 = (b >> 16) & 0xFF
    let t = a >> 24, t2 = b >> 24
    let dr = r > r2 ? r - r2 : r2 - r
    let dg = g > g2 ? g - g2 : g2 - g
    let db = bl > bl2 ? bl - bl2 : bl2 - bl
    let dt = t > t2 ? t - t2 : t2 - t
    return max(max(dr, dg), max(db, dt))
}

/// Integer rectangle on the sample grid; `maxX`/`maxY` are exclusive.
struct GridRect: Hashable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
    var area: Int { width * height }
}
