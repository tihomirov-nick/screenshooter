@testable import PictureTools
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Background removal on a made-up product shot, and a moodboard drawn from a folder.
final class PictureMakingTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = TestPictures.temporaryFolder()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testBackgroundComesOffAroundTheObject() throws {
        let scene = TestPictures.studioScene()
        let cut = try BackgroundRemover.removeBackground(from: scene.image)
        // Cropped to the ball (its shadow may come along), far smaller than the scene.
        XCTAssertLessThan(cut.width, scene.image.width * 3 / 4, "cropped: \(cut.width)×\(cut.height)")
        XCTAssertLessThan(cut.height, scene.image.height * 3 / 4)
        XCTAssertGreaterThan(cut.width, Int(scene.ball.width * 0.8))
        XCTAssertGreaterThan(cut.height, Int(scene.ball.height * 0.8))
        XCTAssertTrue([.premultipliedLast, .premultipliedFirst, .last, .first].contains(cut.alphaInfo), "has alpha")
        // The middle of the ball stays, opaque and red; the backdrop around it goes.
        let middle = TestPictures.pixel(of: cut, x: cut.width / 2, y: cut.height / 2)
        XCTAssertGreaterThan(middle[3], 240, "the ball is opaque: \(middle)")
        XCTAssertGreaterThan(Int(middle[0]), Int(middle[1]) + 60, "and red: \(middle)")
        for (x, y) in [(1, 1), (cut.width - 2, 1)] {
            XCTAssertLessThan(TestPictures.alpha(of: cut, x: x, y: y), 20, "the backdrop is transparent at \(x),\(y)")
        }
        let data = try XCTUnwrap(Moodboard.png(cut))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyHasAlpha] as? Bool, true, "the PNG keeps transparency")
    }

    func testNothingToCutOutOfAFlatPicture() {
        let flat = TestPictures.plain(width: 320, height: 240, red: 0.5, green: 0.5, blue: 0.5)
        XCTAssertThrowsError(try BackgroundRemover.removeBackground(from: flat)) { error in
            XCTAssertEqual(error as? BackgroundRemover.Failure, .nothingFound)
        }
    }

    func testMoodboardFromAFolder() throws {
        let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.2, 0.2), (0.2, 0.7, 0.3), (0.2, 0.3, 0.9), (0.9, 0.8, 0.1), (0.6, 0.2, 0.8)]
        for (i, c) in colours.enumerated() {
            let image = TestPictures.plain(width: i % 2 == 0 ? 400 : 300, height: i % 2 == 0 ? 300 : 400, red: c.0, green: c.1, blue: c.2)
            TestPictures.write(image, to: folder.appendingPathComponent("\(i + 1).png"))
        }
        try Data("not a picture".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        try Data([0, 1, 2]).write(to: folder.appendingPathComponent("broken.png"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        TestPictures.write(TestPictures.plain(width: 10, height: 10, red: 0, green: 0, blue: 0),
                           to: folder.appendingPathComponent("inner/skip.png"))
        TestPictures.write(TestPictures.plain(width: 10, height: 10, red: 0, green: 0, blue: 0),
                           to: folder.appendingPathComponent("10.png"))

        let urls = Moodboard.pictures(in: folder)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["1.png", "2.png", "3.png", "4.png", "5.png", "10.png"],
                       "pictures only, sorted as Finder sorts them")

        let options = Moodboard.Options(width: 1200, spacing: 30, background: .light)
        let image = try XCTUnwrap(Moodboard.render(Array(urls.prefix(5)), options: options))
        XCTAssertEqual(image.width, 1200)
        let layout = CollageLayout(sizes: try urls.prefix(5).map { try XCTUnwrap(Moodboard.pixelSize(of: $0)) },
                                   width: 1200, spacing: 30)
        XCTAssertEqual(image.height, Int(layout.size.height))
        // The margin is the background; the middle of each cell is its picture.
        XCTAssertEqual(TestPictures.pixel(of: image, x: 10, y: 10), [245, 245, 247, 255])
        for (frame, c) in zip(layout.frames, colours) {
            let p = TestPictures.pixel(of: image, x: Int(frame.midX), y: Int(frame.midY))
            XCTAssertEqual(Double(p[0]), Double(c.0 * 255), accuracy: 3)
            XCTAssertEqual(Double(p[2]), Double(c.2 * 255), accuracy: 3)
        }
        XCTAssertNil(Moodboard.render([folder.appendingPathComponent("readme.txt")], options: options))
    }
}
