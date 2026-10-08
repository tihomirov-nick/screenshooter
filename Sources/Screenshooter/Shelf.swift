import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One image on the shelf.
struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    var url: URL
    var date: Date
    var pixelWidth: Int
    var pixelHeight: Int
    /// The file lives in the app's own folder and goes away with the item.
    var shelfOnly: Bool
    /// Bumped when the file is edited, so thumbnails refresh.
    var revision = 0

    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Recent captures and images dropped onto the notch, newest first. Survives restarts.
@MainActor
@Observable
final class Shelf {
    static let shared = Shelf()

    private(set) var items: [ShelfItem] = []
    private(set) var thumbnails: [UUID: NSImage] = [:]

    @ObservationIgnored private let storeURL = AppFolders.support.appendingPathComponent("shelf.json")
    /// False for the preview renderer's shelf, which never touches the disk.
    @ObservationIgnored private var persistent = true
    @ObservationIgnored private let thumbnailQueue = DispatchQueue(label: "Screenshooter.Thumbnails", qos: .userInitiated)

    private init() {
        load()
    }

    /// A shelf with the given items that never reads or writes the store.
    init(preview items: [ShelfItem], thumbnails: [UUID: NSImage]) {
        persistent = false
        self.items = items
        self.thumbnails = thumbnails
    }

    /// Adds a fresh capture; `image` gives the thumbnail without reading the file back.
    @discardableResult
    func addCapture(url: URL, image: CGImage, shelfOnly: Bool) -> ShelfItem {
        let item = ShelfItem(id: UUID(), url: url, date: Date(), pixelWidth: image.width, pixelHeight: image.height,
                             shelfOnly: shelfOnly)
        thumbnails[item.id] = Self.thumbnail(of: image)
        insert(item)
        return item
    }

    /// Adds image files dropped onto the shelf (the files stay where they are).
    func addFiles(_ urls: [URL]) {
        for url in urls where Self.isImage(url) {
            if let i = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                let existing = items.remove(at: i)
                items.insert(existing, at: 0)
                continue
            }
            let size = Self.pixelSize(of: url)
            let item = ShelfItem(id: UUID(), url: url, date: Date(), pixelWidth: size.width, pixelHeight: size.height,
                                 shelfOnly: false)
            insert(item)
            makeThumbnail(for: item)
        }
        save()
    }

    func remove(_ item: ShelfItem, deleteFile: Bool = false) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        if deleteFile || item.shelfOnly {
            if item.shelfOnly {
                try? FileManager.default.removeItem(at: item.url)
            } else {
                NSWorkspace.shared.recycle([item.url])
            }
        }
        save()
    }

    func clear() {
        for item in items where item.shelfOnly {
            try? FileManager.default.removeItem(at: item.url)
        }
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    /// The editor wrote new pixels into the file.
    func fileChanged(_ url: URL) {
        guard let i = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        items[i].revision += 1
        let size = Self.pixelSize(of: url)
        items[i].pixelWidth = size.width
        items[i].pixelHeight = size.height
        makeThumbnail(for: items[i])
        save()
    }

    /// Moves a shelf-only capture to the save folder (the Desktop by default).
    func keep(_ item: ShelfItem) -> URL? {
        guard item.shelfOnly, let i = items.firstIndex(where: { $0.id == item.id }) else { return item.url }
        let folder = Prefs.saveFolder
        var target = folder.appendingPathComponent(item.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            target = CaptureOutput.newFileURL(in: folder, format: item.url.pathExtension == "jpg" ? .jpeg : .png,
                                              date: item.date)
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
        } catch {
            return nil
        }
        items[i].url = target
        items[i].shelfOnly = false
        save()
        return target
    }

    /// Drops items whose files were deleted or moved away.
    func pruneMissing() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if items.count != before { save() }
    }

    // MARK: - Private

    private func insert(_ item: ShelfItem) {
        items.insert(item, at: 0)
        let limit = Prefs.shelfLimit
        while items.count > limit, let last = items.last {
            items.removeLast()
            thumbnails[last.id] = nil
            if last.shelfOnly { try? FileManager.default.removeItem(at: last.url) }
        }
        save()
    }

    private func makeThumbnail(for item: ShelfItem) {
        let url = item.url
        thumbnailQueue.async { [weak self] in
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async {
                guard let self, self.items.contains(where: { $0.id == item.id }) else { return }
                self.thumbnails[item.id] = image
            }
        }
    }

    private func save() {
        guard persistent else { return }
        let snapshot = items
        let url = storeURL
        thumbnailQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = stored.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        items.forEach(makeThumbnail)
    }

    static func thumbnail(of image: CGImage, maxPixels: CGFloat = 480) -> NSImage {
        let scale = min(1, maxPixels / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard scale < 1,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let small = context.makeImage() ?? image
        return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static func pixelSize(of url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (0, 0) }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (w, h)
    }
}
