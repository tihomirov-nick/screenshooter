import AppKit
import UniformTypeIdentifiers

/// Several things on a pasteboard at once, each an item of its own: Figma, Pages, Keynote and messengers paste them
/// all, where one item with several pictures would give them only the first.
public enum PasteboardBatch {
    public enum Entry: Equatable {
        /// The file and its pixels as PNG (and TIFF for older apps), made only when an app asks for them.
        case picture(URL)
        /// The file itself.
        case file(URL)
        case text(String)
    }

    /// The objects that make each pasteboard's pictures on request, kept while it holds them.
    private static var providers: [NSPasteboard.Name: [PictureDataProvider]] = [:]

    /// One pasteboard item per entry, and the objects that make their pictures' data: keep those alive as long as the
    /// pasteboard (or a drag) holds the items.
    public static func items(for entries: [Entry]) -> (items: [NSPasteboardItem], providers: [AnyObject]) {
        var items: [NSPasteboardItem] = []
        var made: [AnyObject] = []
        for entry in entries {
            let item = NSPasteboardItem()
            switch entry {
            case .picture(let url):
                item.setString(url.absoluteString, forType: .fileURL)
                let provider = PictureDataProvider(url: url)
                item.setDataProvider(provider, forTypes: [.png, .tiff])
                made.append(provider)
            case .file(let url):
                item.setString(url.absoluteString, forType: .fileURL)
            case .text(let text):
                item.setString(text, forType: .string)
            }
            items.append(item)
        }
        return (items, made)
    }

    /// Replaces what the pasteboard holds with the entries. False when there is nothing to write or it refused them.
    @discardableResult
    public static func write(_ entries: [Entry], to pasteboard: NSPasteboard) -> Bool {
        guard !entries.isEmpty else { return false }
        let batch = items(for: entries)
        pasteboard.clearContents()
        let written = pasteboard.writeObjects(batch.items)
        providers[pasteboard.name] = batch.providers.compactMap { $0 as? PictureDataProvider }
        return written
    }
}

/// A picture's PNG or TIFF, read from its file when an app pastes it. A PNG file goes as it is.
final class PictureDataProvider: NSObject, NSPasteboardItemDataProvider {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .png, let data = png() {
            item.setData(data, forType: .png)
        } else if type == .tiff, let image = Moodboard.image(at: url) {
            let rep = NSBitmapImageRep(cgImage: image)
            if let tiff = rep.tiffRepresentation(using: .lzw, factor: 0) { item.setData(tiff, forType: .tiff) }
        }
    }

    private func png() -> Data? {
        if (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType == .png,
           let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return data
        }
        return Moodboard.image(at: url).flatMap { Moodboard.png($0) }
    }
}
