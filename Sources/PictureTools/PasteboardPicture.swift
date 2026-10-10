import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The picture on a pasteboard: an image file copied in Finder, or a picture copied in an app.
public struct PasteboardPicture {
    public let image: CGImage
    /// 2 for a Retina screenshot (144 DPI), 1 when the picture does not say.
    public let scale: CGFloat
    /// The file's name without its extension, for a file.
    public let name: String?

    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// Whether `read` would find a picture, without reading it.
    public static func isAvailable(on pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions) { return true }
        // Files that are not pictures come with their icons: those do not count.
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return false }
        return NSImage.canInit(with: pasteboard)
    }

    /// An image file first (the file itself, not the icon Finder adds), then PNG, TIFF and whatever else NSImage reads.
    public static func read(from pasteboard: NSPasteboard) -> PasteboardPicture? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL] {
            for url in urls {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = Moodboard.image(at: url) else { continue }
                return PasteboardPicture(image: image, scale: scale(of: source), name: url.deletingPathExtension().lastPathComponent)
            }
        }
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return nil }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let picture = picture(from: data) { return picture }
        }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            return picture(from: tiff)
        }
        return nil
    }

    private static func picture(from data: Data) -> PasteboardPicture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PasteboardPicture(image: image, scale: scale(of: source), name: nil)
    }

    private static func scale(of source: CGImageSource) -> CGFloat {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return max(1, (CGFloat(dpi) / 72).rounded())
    }
}
