import AppKit
import ImageIO
import PictureTools
import ShotCore

/// What the shelf and the menu do with pictures: a background taken off, a moodboard made from a folder, several
/// pictures copied at once, the text read off the picture on the clipboard. All of it on this Mac, without the network.
@MainActor
enum PictureCommands {
    private static var island: IslandController { .shared }

    /// Where a picture to cut out comes from.
    private enum Source {
        case file(URL)
        case image(CGImage, scale: CGFloat)
    }

    // MARK: - Background

    /// A picture on the shelf without its background: a new card, and on the clipboard.
    static func removeBackground(of item: ShelfItem) {
        guard item.kind == .image else { return }
        cutOut(.file(item.url), name: L("%@ без фона", item.name))
    }

    /// The picture on the clipboard without its background: a new card, and back on the clipboard.
    static func removeBackgroundFromClipboard() {
        guard let picture = PasteboardPicture.read(from: .general) else { return noPicture() }
        let stamp = CaptureOutput.fileNameStamp(Date())
        let name = picture.name.map { L("%@ без фона", $0) } ?? L("Без фона %@ в %@", stamp.day, stamp.time)
        cutOut(.image(picture.image, scale: picture.scale), name: name)
    }

    private static func cutOut(_ source: Source, name: String) {
        island.notify(L("Убираю фон…"), symbol: "person.and.background.dotted", busy: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var png: Data?
            var failure = BackgroundRemover.Failure.failed
            let picture: (image: CGImage, scale: CGFloat)?
            switch source {
            case .file(let url): picture = Moodboard.image(at: url).map { ($0, scale(of: url)) }
            case .image(let image, let scale): picture = (image, scale)
            }
            if let picture {
                do {
                    png = Moodboard.png(try BackgroundRemover.removeBackground(from: picture.image), scale: picture.scale)
                } catch {
                    failure = error as? BackgroundRemover.Failure ?? .failed
                }
            }
            DispatchQueue.main.async {
                if let png {
                    shelve(png, named: name, saying: L("Скопировано без фона"), failure: L("Не удалось убрать фон"))
                } else if failure == .nothingFound {
                    island.notify(L("Объект на картинке не найден"), symbol: "person.and.background.dotted")
                    SoundEffects.play(.failure)
                } else {
                    fail(L("Не удалось убрать фон"))
                }
            }
        }
    }

    // MARK: - Moodboard

    /// One collage of the pictures in the folders (the first `Moodboard.maxPictures`), named after the first folder:
    /// a new card, and on the clipboard.
    static func moodboard(from folders: [URL]) {
        guard let first = folders.first else { return }
        let options = Prefs.moodboard
        let name = L("Мудборд %@", first.lastPathComponent)
        island.notify(L("Собираю мудборд…"), symbol: "rectangle.3.group", busy: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = folders.flatMap { Moodboard.pictures(in: $0) }
            let png = urls.isEmpty ? nil : Moodboard.render(urls, options: options).flatMap { Moodboard.png($0) }
            DispatchQueue.main.async {
                if urls.isEmpty { return emptyFolder() }
                guard let png else { return fail(L("Не удалось собрать мудборд")) }
                shelve(png, named: name, saying: L("Мудборд скопирован"), failure: L("Не удалось собрать мудборд"))
            }
        }
    }

    static func chooseFolderForMoodboard() {
        chooseFolder(prompt: L("Собрать мудборд"),
                     message: L("Картинки из папки встанут ровной сеткой в один коллаж.")) { moodboard(from: [$0]) }
    }

    // MARK: - Several pictures at once

    /// Every picture in the folder on the clipboard, each an item of its own with its file and PNG.
    static func copyPictures(in folder: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = Moodboard.pictures(in: folder)
            DispatchQueue.main.async {
                if urls.isEmpty { return emptyFolder() }
                guard PasteboardBatch.write(urls.map { .picture($0) }, to: .general) else { return fail(L("Не удалось скопировать")) }
                island.notify(L("Скопировано: %@", "\(urls.count)"))
                SoundEffects.play(.copied)
            }
        }
    }

    static func chooseFolderToCopy() {
        chooseFolder(prompt: L("Скопировать картинки"),
                     message: L("Все картинки папки лягут в буфер обмена, каждая отдельно.")) { copyPictures(in: $0) }
    }

    /// Several cards on the clipboard, each an item of its own: pictures with their files and PNG, other files, texts.
    static func copy(_ items: [ShelfItem]) -> Bool {
        let entries: [PasteboardBatch.Entry] = items.compactMap { item in
            switch item.kind {
            case .image: return .picture(item.url)
            case .file: return .file(item.url)
            case .text: return Shelf.text(of: item).map { .text($0) }
            }
        }
        return PasteboardBatch.write(entries, to: .general)
    }

    // MARK: - Text

    /// The text in the picture on the clipboard, put on the clipboard in its place.
    static func recognizeClipboardText() {
        guard let picture = PasteboardPicture.read(from: .general) else { return noPicture() }
        Task { @MainActor in
            let text = await TextRecognizer.recognize(picture.image)
            if text.isEmpty {
                island.notify(L("Текст не найден"), symbol: "text.magnifyingglass")
                SoundEffects.play(.failure)
            } else {
                CaptureOutput.copyText(text)
                island.notify(L("Текст скопирован"), symbol: "text.viewfinder")
                SoundEffects.play(.success)
            }
        }
    }

    /// A picture on the clipboard that the clipboard items of the menu can work on.
    static var clipboardHasPicture: Bool { PasteboardPicture.isAvailable(on: .general) }

    // MARK: - Private

    /// The new picture onto the shelf and the clipboard, its card lit up, `text` said.
    private static func shelve(_ png: Data, named name: String, saying text: String, failure: String) {
        Shelf.shared.addPicture(png, named: name) { item in
            guard let item, CaptureOutput.copyFile(item.url) else { return fail(failure) }
            island.present(item, saying: text)
            SoundEffects.play(.success)
        }
    }

    private static func chooseFolder(prompt: String, message: String, then action: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            action(url)
        }
    }

    private static func noPicture() {
        island.notify(L("В буфере нет картинки"), symbol: "doc.on.clipboard")
        SoundEffects.play(.failure)
    }

    private static func emptyFolder() {
        island.notify(L("В папке нет картинок"), symbol: "folder")
        SoundEffects.play(.failure)
    }

    private static func fail(_ text: String) {
        island.notify(text, symbol: "exclamationmark.triangle.fill")
        SoundEffects.play(.failure)
    }

    /// 2 for a Retina picture (144 DPI), as the file says.
    nonisolated private static func scale(of url: URL) -> CGFloat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue else { return 1 }
        return max(1, (CGFloat(dpi) / 72).rounded())
    }
}
