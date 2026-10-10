@testable import PictureTools
import AppKit
import UniformTypeIdentifiers
import XCTest

/// Several pictures on a pasteboard as items of their own, and the picture read back from one. Each test has a
/// pasteboard of its own: the clipboard is never touched.
final class PasteboardTests: XCTestCase {
    private var folder: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        folder = TestPictures.temporaryFolder()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PictureToolsTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func pictures(_ count: Int, type: UTType = .png) -> [URL] {
        (0..<count).map { i in
            let image = TestPictures.plain(width: 40 + 10 * i, height: 30, red: CGFloat(i) / CGFloat(count), green: 0.5, blue: 0.2)
            return TestPictures.write(image, to: folder.appendingPathComponent("picture \(i).\(type.preferredFilenameExtension!)"),
                                      type: type)
        }
    }

    func testEveryPictureIsAnItemWithItsFileAndPNG() throws {
        let urls = pictures(3)
        XCTAssertTrue(PasteboardBatch.write(urls.map { .picture($0) }, to: pasteboard))

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 3)
        for (item, url) in zip(items, urls) {
            XCTAssertTrue(item.types.contains(.fileURL))
            XCTAssertTrue(item.types.contains(.png))
            XCTAssertEqual(item.string(forType: .fileURL).flatMap(URL.init(string:))?.standardizedFileURL, url.standardizedFileURL)
            let png = try XCTUnwrap(item.data(forType: .png), "PNG made on request")
            XCTAssertEqual(png, try Data(contentsOf: url), "a PNG file goes as it is")
        }
        // What apps reading files or pictures get: all of them, in order.
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(files?.map(\.standardizedFileURL), urls.map(\.standardizedFileURL))
        let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]
        XCTAssertEqual(images?.count, 3)
    }

    func testOtherFormatsComeAsPNG() throws {
        let urls = pictures(2, type: .jpeg)
        PasteboardBatch.write(urls.map { .picture($0) }, to: pasteboard)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        for (index, item) in items.enumerated() {
            let png = try XCTUnwrap(item.data(forType: .png))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 40 + 10 * index)
            XCTAssertNotNil(item.data(forType: .tiff), "TIFF for older apps")
        }
    }

    func testMixedEntries() throws {
        let picture = pictures(1)[0]
        let document = folder.appendingPathComponent("notes.pdf")
        try Data("%PDF-1.4".utf8).write(to: document)
        PasteboardBatch.write([.picture(picture), .file(document), .text("Встреча в четверг")], to: pasteboard)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].types.contains(.png))
        XCTAssertEqual(items[1].types, [.fileURL], "a file that is not a picture goes as the file alone")
        XCTAssertEqual(items[2].string(forType: .string), "Встреча в четверг")
        XCTAssertFalse(PasteboardBatch.write([], to: pasteboard))
    }

    func testPictureReadBackFromData() throws {
        let image = TestPictures.plain(width: 64, height: 48, red: 0.2, green: 0.4, blue: 0.9)
        let url = TestPictures.write(image, to: folder.appendingPathComponent("blue.png"))
        pasteboard.clearContents()
        pasteboard.setData(try Data(contentsOf: url), forType: .png)
        XCTAssertTrue(PasteboardPicture.isAvailable(on: pasteboard))
        let picture = try XCTUnwrap(PasteboardPicture.read(from: pasteboard))
        XCTAssertEqual(picture.image.width, 64)
        XCTAssertNil(picture.name)
    }

    func testPictureFileCopiedInFinder() throws {
        let url = pictures(1)[0]
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        XCTAssertTrue(PasteboardPicture.isAvailable(on: pasteboard))
        let picture = try XCTUnwrap(PasteboardPicture.read(from: pasteboard))
        XCTAssertEqual(picture.image.width, 40)
        XCTAssertEqual(picture.name, "picture 0")
    }

    func testFileThatIsNotAPictureDoesNotCount() throws {
        let document = folder.appendingPathComponent("notes.pdf")
        try Data("%PDF-1.4".utf8).write(to: document)
        pasteboard.clearContents()
        // Finder puts the file's icon next to it.
        let item = NSPasteboardItem()
        item.setString(document.absoluteString, forType: .fileURL)
        item.setData(NSWorkspace.shared.icon(forFile: document.path).tiffRepresentation!, forType: .tiff)
        pasteboard.writeObjects([item])
        XCTAssertFalse(PasteboardPicture.isAvailable(on: pasteboard))
        XCTAssertNil(PasteboardPicture.read(from: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("просто текст", forType: .string)
        XCTAssertFalse(PasteboardPicture.isAvailable(on: pasteboard))
    }
}
