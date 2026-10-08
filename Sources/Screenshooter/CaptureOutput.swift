import AppKit
import ImageIO
import ShotCore
import UniformTypeIdentifiers

/// Files and the clipboard for finished captures and the shelf.
enum CaptureOutput {
    /// Encoded file data, with the DPI that makes Retina captures open at their on-screen size.
    static func encode(_ image: CGImage, scale: CGFloat, format: ImageFormat) -> Data? {
        let data = NSMutableData()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// "Скриншот 2026-10-08 в 14.32.10.png", with " (2)" when the name is taken.
    static func newFileURL(in folder: URL, format: ImageFormat, date: Date = Date()) -> URL {
        let stamp = fileNameStamp(date)
        let base = L("Скриншот %@ в %@", stamp.day, stamp.time)
        var url = folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(format.fileExtension)
            n += 1
        }
        return url
    }

    /// "2026-10-08" and "14.32.10", for file names.
    static func fileNameStamp(_ date: Date) -> (day: String, time: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        return (day, formatter.string(from: date))
    }

    /// Saves to the chosen folder (the Desktop by default) or, with saving turned off, to the shelf's
    /// own folder, so the capture can still be dragged and opened. Returns the file and whether it is
    /// kept only for the shelf.
    static func save(_ image: CGImage, scale: CGFloat) throws -> (url: URL, shelfOnly: Bool, png: Data?) {
        let format = Prefs.imageFormat
        guard let data = encode(image, scale: scale, format: format) else { throw CaptureError.nothingCaptured }
        let shelfOnly = !Prefs.saveToFolder
        var folder = shelfOnly ? AppFolders.shelfFiles : Prefs.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = newFileURL(in: folder, format: format)
        do {
            try data.write(to: url, options: .atomic)
        } catch where !shelfOnly {
            // The chosen folder is gone or read-only: keep the capture anyway.
            folder = AppFolders.shelfFiles
            url = newFileURL(in: folder, format: format)
            try data.write(to: url, options: .atomic)
            return (url, true, format == .png ? data : nil)
        }
        return (url, shelfOnly, format == .png ? data : nil)
    }

    // MARK: Clipboard

    /// Keeps the lazy TIFF provider alive while the clipboard holds it.
    private static var provider: ImageDataProvider?

    /// PNG right away; TIFF (some older apps want it) only when someone pastes it.
    static func copy(_ image: CGImage, scale: CGFloat, png: Data? = nil) {
        guard let pngData = png ?? encode(image, scale: scale, format: .png) else { return }
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        let lazy = ImageDataProvider(image: image, scale: scale)
        item.setDataProvider(lazy, forTypes: [.tiff])
        provider = lazy
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Copies the picture in an image file from the shelf. False when the file cannot be read.
    @discardableResult
    static func copyFile(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        copy(image, scale: max(1, CGFloat(dpi) / 72), png: isPNG ? try? Data(contentsOf: url) : nil)
        return true
    }

    /// Copies a file itself: Finder pastes the file, mail and messengers attach it.
    static func copyFileItself(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class ImageDataProvider: NSObject, NSPasteboardItemDataProvider {
    let image: CGImage
    let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let tiff = rep.tiffRepresentation(using: .lzw, factor: 0) {
            item.setData(tiff, forType: .tiff)
        }
    }
}
