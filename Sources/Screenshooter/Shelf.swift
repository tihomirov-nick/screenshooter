import AppKit
import ImageIO
import Observation
import QuickLookThumbnailing
import ShotCore
import UniformTypeIdentifiers

/// One thing on the shelf: a capture or another picture, any other file or folder, or a piece of text.
struct ShelfItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        /// A picture the editor can open: captures and images from other apps.
        case image
        /// Any other file or folder: PDF, documents, archives…
        case file
        /// Text dropped from another app, kept in a text file in the shelf's own folder.
        case text
    }

    let id: UUID
    var kind: Kind = .image
    var url: URL
    /// Finds the file again after it was renamed or moved. Only for files outside the shelf's own folder.
    var bookmark: Data?
    var date: Date
    var pixelWidth = 0
    var pixelHeight = 0
    /// The file lives in the app's own folder and goes away with the item.
    var shelfOnly = false
    /// Taken by this app, not brought from another one: its quick button sends the file to the Trash.
    var isCapture = false
    /// Bumped when the file is edited, so thumbnails refresh.
    var revision = 0

    var name: String { url.deletingPathExtension().lastPathComponent }

    /// A folder (not a package such as a Keynote document): its pictures make a moodboard.
    var isFolder: Bool {
        guard kind == .file, url.hasDirectoryPath else { return false }
        return !(UTType(filenameExtension: url.pathExtension)?.conforms(to: .package) ?? false)
    }
}

extension ShelfItem {
    /// Shelves saved before files and text could be dropped have no `kind`, `bookmark` or `isCapture`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .image
        url = try container.decode(URL.self, forKey: .url)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        date = try container.decode(Date.self, forKey: .date)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        shelfOnly = try container.decodeIfPresent(Bool.self, forKey: .shelfOnly) ?? false
        isCapture = try container.decodeIfPresent(Bool.self, forKey: .isCapture) ?? Self.looksLikeCapture(url)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }

    /// For items stored before the shelf told its own captures apart: a file in the save folder (or the
    /// shelf's own folder) named the way the app names captures is one.
    static func looksLikeCapture(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        guard ["png", "jpg"].contains(url.pathExtension.lowercased()),
              [Prefs.saveFolder, AppFolders.shelfFiles].contains(where: { $0.standardizedFileURL.path == folder })
        else { return false }
        let pattern = #"^(Скриншот|Screenshot) \d{4}-\d{2}-\d{2} (в|at) \d{2}\.\d{2}\.\d{2}( \(\d+\))?$"#
        return url.deletingPathExtension().lastPathComponent.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Recent captures and whatever was dropped onto the notch, newest first. Survives restarts.
///
/// Files dropped from Finder or any app stay where they are: the shelf keeps a bookmark and follows them
/// when they are renamed or moved, and drops them when they are deleted. What would not last is copied
/// into the app's own folder instead: text, files that apps only promise (Mail, Photos, browsers), image
/// data, and files in temporary folders and app caches, which their apps clean up.
@MainActor
@Observable
final class Shelf {
    static let shared = Shelf()

    private(set) var items: [ShelfItem] = []
    /// Image thumbnails, and Quick Look previews (or Finder icons) of other files.
    private(set) var thumbnails: [UUID: NSImage] = [:]
    /// The beginning of each text.
    private(set) var texts: [UUID: String] = [:]

    @ObservationIgnored private let storeURL = AppFolders.support.appendingPathComponent("shelf.json")
    /// False for the preview renderer's shelf, which never touches the disk.
    @ObservationIgnored private var persistent = true
    @ObservationIgnored private let thumbnailQueue = DispatchQueue(label: "Screenshooter.Thumbnails", qos: .userInitiated)
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private init() {
        load()
    }

    /// A shelf with the given items that never reads or writes the store.
    init(preview items: [ShelfItem], thumbnails: [UUID: NSImage], texts: [UUID: String] = [:]) {
        persistent = false
        self.items = items
        self.thumbnails = thumbnails
        self.texts = texts
    }

    // MARK: - Adding

    /// Adds a fresh capture; `image` gives the thumbnail without reading the file back.
    @discardableResult
    func addCapture(url: URL, image: CGImage, shelfOnly: Bool) -> ShelfItem {
        let item = ShelfItem(id: UUID(), url: url, bookmark: shelfOnly ? nil : Self.bookmark(for: url), date: Date(),
                             pixelWidth: image.width, pixelHeight: image.height, shelfOnly: shelfOnly, isCapture: true)
        thumbnails[item.id] = Self.thumbnail(of: image)
        insert([item])
        return item
    }

    /// What a drag can bring: files, files promised by apps, text, pictures.
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .string, .png, .tiff]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func canTake(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(where: dropTypes.contains)
    }

    /// Puts what was dropped on the shelf: files if there are any, otherwise promised files, text or a
    /// picture. `done` gets the new items, or none when nothing could be kept.
    func add(from pasteboard: NSPasteboard, done: @escaping ([ShelfItem]) -> Void) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addFiles(urls, done: done)
            return
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            receive(promises, done: done)
            return
        }
        let text = pasteboard.string(forType: .string)
        let hasText = text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        // A selection of rich text may bring its pictures along; the text is what was meant.
        let types = pasteboard.types ?? []
        let selection = hasText && (types.contains(.rtf) || types.contains(.rtfd) || types.contains(.html))
        if let image, !selection {
            addImage(image, done: done)
        } else if let text, hasText {
            addText(text, done: done)
        } else {
            done([])
        }
    }

    /// Adds files and folders (dropped onto the shelf or saved from the editor). Ones already on the shelf
    /// move to the front.
    func addFiles(_ urls: [URL], done: (([ShelfItem]) -> Void)? = nil) {
        let known = urls.compactMap { url in items.first { $0.url.standardizedFileURL == url.standardizedFileURL } }
        let knownURLs = Set(known.map(\.url.standardizedFileURL))
        let fresh = urls.filter { !knownURLs.contains($0.standardizedFileURL) }
        if !known.isEmpty {
            let ids = Set(known.map(\.id))
            items.removeAll { ids.contains($0.id) }
            items.insert(contentsOf: known, at: 0)
            save()
        }
        let folder = AppFolders.shelfFiles
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = fresh.compactMap { Self.prepare($0, folder: folder) }
            DispatchQueue.main.async {
                self.insert(prepared)
                done?(prepared + known)
            }
        }
    }

    /// Keeps a text in a file of its own in the shelf's folder, named after its first words.
    func addText(_ text: String, done: @escaping ([ShelfItem]) -> Void) {
        let folder = AppFolders.shelfFiles
        let name = Self.fileName(for: text) + ".txt"
        DispatchQueue.global(qos: .userInitiated).async {
            let url = Self.uniqueURL(in: folder, name: name)
            let saved = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
            DispatchQueue.main.async {
                guard saved else { return done([]) }
                let item = ShelfItem(id: UUID(), kind: .text, url: url, date: Date(), shelfOnly: true)
                self.texts[item.id] = Self.preview(of: text)
                self.insert([item])
                done([item])
            }
        }
    }

    /// A picture that came as data rather than as a file, kept as PNG in the shelf's folder.
    private func addImage(_ data: Data, done: @escaping ([ShelfItem]) -> Void) {
        let folder = AppFolders.shelfFiles
        let stamp = CaptureOutput.fileNameStamp(Date())
        let name = L("Картинка %@ в %@", stamp.day, stamp.time) + ".png"
        DispatchQueue.global(qos: .userInitiated).async {
            var item: ShelfItem?
            let url = Self.uniqueURL(in: folder, name: name)
            if let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]),
               (try? png.write(to: url, options: .atomic)) != nil {
                item = Self.prepare(url, folder: folder)
            }
            DispatchQueue.main.async {
                guard let item else { return done([]) }
                self.insert([item])
                done([item])
            }
        }
    }

    /// A picture made here (a cut-out, a moodboard): its PNG in the shelf's folder under `name`, in front of the shelf.
    func addPicture(_ png: Data, named name: String, done: @escaping (ShelfItem?) -> Void) {
        let folder = AppFolders.shelfFiles
        DispatchQueue.global(qos: .userInitiated).async {
            let url = Self.uniqueURL(in: folder, name: Self.safeName(name) + ".png")
            let item = (try? png.write(to: url, options: .atomic)) != nil ? Self.prepare(url, folder: folder) : nil
            DispatchQueue.main.async {
                if let item { self.insert([item]) }
                done(item)
            }
        }
    }

    /// Without the characters a file name cannot have.
    nonisolated private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(120))
    }

    /// Files that apps write only on request (attachments from Mail, photos from Photos, pictures from
    /// browsers) arrive in a folder of their own and then move into the shelf's folder.
    private func receive(_ promises: [NSFilePromiseReceiver], done: @escaping ([ShelfItem]) -> Void) {
        let incoming = AppFolders.support.appendingPathComponent("Incoming", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let folder = AppFolders.shelfFiles
        let group = DispatchGroup()
        let arrived = ArrivedItems()
        for promise in promises {
            // The reader below is called once for every promised file.
            for _ in 0..<max(1, promise.fileTypes.count) { group.enter() }
            promise.receivePromisedFiles(atDestination: incoming, options: [:], operationQueue: promiseQueue) { url, error in
                let item = error == nil ? Self.prepare(url, folder: folder, moving: true) : nil
                DispatchQueue.main.async {
                    if let item {
                        self.insert([item])
                        arrived.items.insert(item, at: 0)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            try? FileManager.default.removeItem(at: incoming)
            done(arrived.items)
        }
    }

    // MARK: - Changing

    /// `deleteFile` moves the file to the Trash; otherwise only the shelf's own copy is deleted.
    func remove(_ item: ShelfItem, deleteFile: Bool = false) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        texts[item.id] = nil
        if deleteFile {
            NSWorkspace.shared.recycle([item.url])
        } else if item.shelfOnly {
            try? FileManager.default.removeItem(at: item.url)
        }
        save()
    }

    func clear() {
        for item in items where item.shelfOnly {
            try? FileManager.default.removeItem(at: item.url)
        }
        items.removeAll()
        thumbnails.removeAll()
        texts.removeAll()
        save()
    }

    /// The editor wrote new pixels into the file.
    func fileChanged(_ url: URL) {
        guard let i = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        items[i].revision += 1
        let size = Self.pixelSize(of: url)
        items[i].pixelWidth = size.width
        items[i].pixelHeight = size.height
        makePreview(for: items[i])
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
        items[i].bookmark = Self.bookmark(for: target)
        items[i].shelfOnly = false
        save()
        return target
    }

    /// Follows files that were renamed or moved and drops the ones that are gone.
    func pruneMissing() {
        let found = items.compactMap(Self.located)
        guard found != items else { return }
        let kept = Set(found.map(\.id))
        for item in items where !kept.contains(item.id) {
            thumbnails[item.id] = nil
            texts[item.id] = nil
        }
        items = found
        save()
    }

    /// The whole text of a text item.
    static func text(of item: ShelfItem) -> String? {
        try? String(contentsOf: item.url, encoding: .utf8)
    }

    // MARK: - Private

    /// New items go to the front, in the order given; the oldest ones beyond the limit leave the shelf.
    private func insert(_ new: [ShelfItem]) {
        guard !new.isEmpty else { return }
        items.insert(contentsOf: new, at: 0)
        let limit = Prefs.shelfLimit
        while items.count > limit, let last = items.last {
            items.removeLast()
            thumbnails[last.id] = nil
            texts[last.id] = nil
            if last.shelfOnly { try? FileManager.default.removeItem(at: last.url) }
        }
        // Captures and texts come with their preview.
        for item in new where thumbnails[item.id] == nil && texts[item.id] == nil {
            makePreview(for: item)
        }
        save()
    }

    private func makePreview(for item: ShelfItem) {
        let url = item.url
        switch item.kind {
        case .image:
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
        case .file:
            // The Finder icon at once. A page of a PDF or a document, the picture of a video, replaces it
            // when Quick Look has one; folders and archives keep their icon.
            thumbnails[item.id] = NSWorkspace.shared.icon(forFile: url.path)
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 132, height: 84), scale: 2,
                                                       representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let image = representation?.nsImage else { return }
                DispatchQueue.main.async {
                    guard let self, self.items.contains(where: { $0.id == item.id }) else { return }
                    self.thumbnails[item.id] = image
                }
            }
        case .text:
            thumbnailQueue.async { [weak self] in
                let head = Self.head(of: url)
                DispatchQueue.main.async {
                    guard let self, self.items.contains(where: { $0.id == item.id }) else { return }
                    self.texts[item.id] = head
                }
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
        items = stored.compactMap(Self.located)
        items.forEach(makePreview)
        if items != stored { save() }
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

    nonisolated static func pixelSize(of url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (0, 0) }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (w, h)
    }

    /// A new item for a file. It is copied (or, for promised files, moved) into the shelf's folder when it
    /// would not last where it is, and stays in place with a bookmark otherwise. Runs off the main thread.
    nonisolated private static func prepare(_ source: URL, folder: URL, moving: Bool = false) -> ShelfItem? {
        let manager = FileManager.default
        var url = source
        var shelfOnly = isInside(source, folder)
        if !shelfOnly, moving || isTransient(source) {
            let target = uniqueURL(in: folder, name: source.lastPathComponent)
            do {
                if moving {
                    try manager.moveItem(at: source, to: target)
                } else {
                    try manager.copyItem(at: source, to: target)
                }
            } catch {
                return nil
            }
            url = target
            shelfOnly = true
        }
        guard manager.fileExists(atPath: url.path) else { return nil }
        // A picture the editor can open; anything else, SVG and PDF included, is a file.
        var size: (width: Int, height: Int)?
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            let pixels = pixelSize(of: url)
            if pixels.width > 0, pixels.height > 0 { size = pixels }
        }
        return ShelfItem(id: UUID(), kind: size == nil ? .file : .image, url: url,
                         bookmark: shelfOnly ? nil : bookmark(for: url), date: Date(),
                         pixelWidth: size?.width ?? 0, pixelHeight: size?.height ?? 0, shelfOnly: shelfOnly)
    }

    /// Temporary folders and app caches (messengers keep their attachments there) are cleaned up by macOS
    /// and by the apps. iCloud Drive and other cloud folders live in ~/Library too, but hold the user's own files.
    nonisolated private static func isTransient(_ url: URL) -> Bool {
        // Resolving symlinks turns /private/tmp into /tmp and /private/var into /var; both spellings count.
        let path = url.resolvingSymlinksInPath().path
        let temporary = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]
        if temporary.contains(where: path.hasPrefix) { return true }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/"
        return path.hasPrefix(library) && !path.hasPrefix(library + "Mobile Documents/")
            && !path.hasPrefix(library + "CloudStorage/")
    }

    nonisolated private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    /// "name.ext", or "name (2).ext" when that is taken.
    nonisolated private static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    nonisolated private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The item with its file found again: in place, or where the bookmark leads after a rename or a move.
    /// Nil when the file is gone: deleted, in the Trash, or on a disk that is not connected.
    nonisolated private static func located(_ item: ShelfItem) -> ShelfItem? {
        if FileManager.default.fileExists(atPath: item.url.path) { return item }
        guard let data = item.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path),
              !url.path.contains("/.Trash/"), !url.path.contains("/.Trashes/") else { return nil }
        var moved = item
        moved.url = url
        if stale { moved.bookmark = bookmark(for: url) ?? data }
        return moved
    }

    /// The first words of a text, for its file name.
    private static func fileName(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var name = String(line.prefix(40)).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? L("Текст") : name
    }

    /// What a text card shows.
    nonisolated private static func preview(of text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
    }

    /// The beginning of a text file, without reading all of a long one.
    nonisolated private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // A character cut in half at the end of the chunk.
        if text.hasSuffix("\u{FFFD}") { text.removeLast() }
        return preview(of: text)
    }
}

/// Promised files of one drop as they arrive (touched on the main queue only).
private final class ArrivedItems {
    var items: [ShelfItem] = []
}
