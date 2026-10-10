import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Pictures made for the tests, and a temporary folder for their files.
enum TestPictures {
    static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// A flat colour.
    static func plain(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A product shot: a shaded red ball with a highlight and a soft shadow on a pale studio backdrop. `ball` is where
    /// it stands, from the bottom left corner.
    static func studioScene(width: Int = 640, height: Int = 480) -> (image: CGImage, ball: CGRect) {
        let ctx = context(width: width, height: height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // The backdrop: a soft gradient from the floor up.
        let backdrop = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.80, green: 0.80, blue: 0.78, alpha: 1),
                                                                CGColor(srgbRed: 0.95, green: 0.95, blue: 0.93, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(backdrop, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        let side = CGFloat(min(width, height)) * 0.5
        let ball = CGRect(x: (CGFloat(width) - side) / 2, y: CGFloat(height) * 0.22, width: side, height: side)
        // Its shadow on the floor.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 0.6))
        ctx.fillEllipse(in: CGRect(x: ball.minX + side * 0.1, y: ball.minY - side * 0.08, width: side * 0.8, height: side * 0.16))
        ctx.restoreGState()
        // The ball, lit from the top left.
        ctx.saveGState()
        ctx.addEllipse(in: ball)
        ctx.clip()
        let shading = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1.0, green: 0.55, blue: 0.5, alpha: 1),
                                                               CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1),
                                                               CGColor(srgbRed: 0.35, green: 0.02, blue: 0.04, alpha: 1)] as CFArray,
                                 locations: [0, 0.45, 1])!
        let light = CGPoint(x: ball.minX + side * 0.35, y: ball.minY + side * 0.68)
        ctx.drawRadialGradient(shading, startCenter: light, startRadius: 0, endCenter: CGPoint(x: ball.midX, y: ball.midY),
                               endRadius: side * 0.62, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        return (ctx.makeImage()!, ball)
    }

    /// Alpha of a pixel, counted from the top left corner.
    static func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        let ctx = context(width: 1, height: 1)
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return ctx.data!.assumingMemoryBound(to: UInt8.self)[3]
    }

    /// The colour of a pixel as 0–255 RGBA, counted from the top left corner.
    static func pixel(of image: CGImage, x: Int, y: Int) -> [UInt8] {
        let ctx = context(width: 1, height: 1)
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return [p[0], p[1], p[2], p[3]]
    }

    static func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PictureToolsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType = .png) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return url
    }
}
