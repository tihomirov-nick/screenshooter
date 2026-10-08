import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Writing the edited image to files and to the clipboard.
enum ImageFiles {
    /// The format to keep when overwriting a file, from its extension.
    static func contentType(for url: URL) -> UTType {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        default: return .png
        }
    }

    static func encode(_ image: CGImage, as type: UTType, dpi: CGFloat) -> Data? {
        // JPEG has no alpha: transparent window corners would turn black, so they go on white.
        let source = type == .jpeg || type == .bmp ? flattened(image) : image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if type == .jpeg || type == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL, dpi: CGFloat) throws {
        guard let data = encode(image, as: contentType(for: url), dpi: dpi) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try data.write(to: url, options: .atomic)
    }

    /// PNG for apps that take it, TIFF for the rest; the point size keeps Retina images at their size.
    static func copyToPasteboard(_ image: CGImage, scale: CGFloat, dpi: CGFloat) {
        let item = NSPasteboardItem()
        if let png = encode(image, as: .png, dpi: dpi) {
            item.setData(png, forType: .png)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let tiff = rep.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private static func flattened(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: AnnotationRenderer.outputColorSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// A folder of its own for every drag, so a file another app is still reading is never replaced.
    static func temporaryFileURL(named name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Screenshooter Drag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder.appendingPathComponent(name)
    }
}
