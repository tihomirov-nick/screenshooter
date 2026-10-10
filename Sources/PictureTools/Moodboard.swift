import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures of a folder in one collage (see `CollageLayout`), on a dark or a light background. Made on this Mac.
public enum Moodboard {
    public enum Background: String, CaseIterable, Sendable {
        case dark, light

        public var color: CGColor {
            switch self {
            case .dark: return CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            case .light: return CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
            }
        }
    }

    public struct Options: Equatable, Sendable {
        /// The collage's width in pixels; its height follows from the pictures.
        public var width: Int
        /// Between pictures, between rows and around the edge, in pixels.
        public var spacing: Int
        public var background: Background

        public init(width: Int = 2400, spacing: Int = 24, background: Background = .dark) {
            self.width = width
            self.spacing = spacing
            self.background = background
        }
    }

    /// No more pictures go into one collage: past that each one would be too small to make out.
    public static let maxPictures = 100

    /// The pictures directly in a folder, sorted by name as Finder sorts them. Hidden files, subfolders and files that
    /// ImageIO cannot read are left out.
    public static func pictures(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return urls
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image) else { return false }
                return pixelSize(of: url) != nil
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The collage of these pictures (the first `maxPictures` of them), or nil when none could be read.
    public static func render(_ urls: [URL], options: Options) -> CGImage? {
        let pictures = urls.prefix(maxPictures).compactMap { url in pixelSize(of: url).map { (url, $0) } }
        guard !pictures.isEmpty else { return nil }
        let layout = CollageLayout(sizes: pictures.map(\.1), width: options.width, spacing: options.spacing)
        let width = Int(layout.size.width), height = Int(layout.size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(options.background.color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, picture) in pictures.enumerated() {
            let frame = layout.frames[index]
            guard let image = image(at: picture.0, maxPixels: max(frame.width, frame.height)) else { continue }
            // The layout counts from the top, Core Graphics from the bottom.
            context.draw(image, in: CGRect(x: frame.minX, y: CGFloat(height) - frame.maxY, width: frame.width, height: frame.height))
        }
        return context.makeImage()
    }

    /// The size a picture shows at, its orientation applied (a portrait photo taken on its side stands upright).
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// The picture upright, no larger than `maxPixels` on its long side (the full size when that is smaller).
    public static func image(at url: URL, maxPixels: CGFloat? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = pixelSize(of: url) else { return nil }
        let longSide = max(size.width, size.height)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(min(longSide, maxPixels ?? longSide).rounded(.up)),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// PNG data, with the DPI that makes a Retina picture (`scale` 2) open at its size on screen.
    public static func png(_ image: CGImage, scale: CGFloat = 1) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
