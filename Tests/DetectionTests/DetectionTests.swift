import CoreGraphics
import XCTest
@testable import Detection

final class RegionChainTests: XCTestCase {
    private let display = Region(rect: CGRect(x: 0, y: 0, width: 1512, height: 982), source: .display, title: "screen")
    private let window = Region(rect: CGRect(x: 100, y: 100, width: 1000, height: 700), source: .window, title: "window",
                                windowID: 42)

    func testKeepsOnlyRegionsUnderThePointSmallestFirst() {
        let list = Region(rect: CGRect(x: 400, y: 150, width: 680, height: 600), source: .element, title: "list")
        let message = Region(rect: CGRect(x: 420, y: 300, width: 300, height: 60), source: .element, title: "message")
        let elsewhere = Region(rect: CGRect(x: 120, y: 150, width: 200, height: 600), source: .element, title: "sidebar")
        let chain = RegionChain.build(at: CGPoint(x: 500, y: 320), from: [display, window, list, message, elsewhere])
        XCTAssertEqual(chain.map(\.title), ["message", "list", "window", "screen"])
    }

    func testNearDuplicatesKeepTheMoreTellingSource() {
        // A scroll area that fills the window is the window; a pixel box under an element keeps the element's name.
        let scroll = Region(rect: window.rect.insetBy(dx: 1, dy: 1), source: .element, title: "scroll area")
        let button = Region(rect: CGRect(x: 500, y: 500, width: 120, height: 40), source: .element, title: "Кнопка «OK»")
        let box = Region(rect: CGRect(x: 501, y: 500, width: 119, height: 41), source: .visual, title: "Блок")
        let chain = RegionChain.build(at: CGPoint(x: 550, y: 520), from: [display, window, scroll, box, button])
        XCTAssertEqual(chain.map(\.title), ["Кнопка «OK»", "window", "screen"])
        XCTAssertEqual(chain[1].windowID, 42)
    }

    func testDefaultSkipsWordsAndIcons() {
        let word = Region(rect: CGRect(x: 430, y: 310, width: 60, height: 16), source: .element, title: "text")
        let icon = Region(rect: CGRect(x: 425, y: 305, width: 28, height: 28), source: .element, title: "icon")
        let row = Region(rect: CGRect(x: 400, y: 290, width: 600, height: 80), source: .element, title: "row")
        let chain = RegionChain.build(at: CGPoint(x: 440, y: 315), from: [display, window, word, icon, row])
        XCTAssertEqual(chain[RegionChain.defaultIndex(in: chain)].title, "row")
    }

    func testDefaultPrefersTheBubbleAroundATextElement() {
        let text = Region(rect: CGRect(x: 440, y: 310, width: 260, height: 40), source: .element, title: "text")
        let bubble = Region(rect: CGRect(x: 428, y: 300, width: 290, height: 62), source: .visual, title: "Блок")
        let list = Region(rect: CGRect(x: 400, y: 150, width: 680, height: 600), source: .element, title: "list")
        let chain = RegionChain.build(at: CGPoint(x: 500, y: 330), from: [display, window, list, bubble, text])
        XCTAssertEqual(chain[RegionChain.defaultIndex(in: chain)].title, "Блок")
    }

    func testDefaultFallsBackToTheLargest() {
        let chain = RegionChain.build(at: CGPoint(x: 10, y: 10), from: [display])
        XCTAssertEqual(RegionChain.defaultIndex(in: chain), 0)
        XCTAssertEqual(RegionChain.defaultIndex(in: []), 0)
    }
}

final class LabelTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(AccessibilityRegions.label(role: "AXButton", subrole: "", roleDescription: "кнопка", name: "Отправить"),
                       "Кнопка «Отправить»")
        XCTAssertEqual(AccessibilityRegions.label(role: "AXGroup", subrole: "", roleDescription: "группа", name: nil), "Группа")
        XCTAssertEqual(AccessibilityRegions.label(role: "AXStaticText", subrole: "", roleDescription: "текст",
                                                  name: "a long message text"), "Текст")
        XCTAssertEqual(AccessibilityRegions.label(role: "AXWebArea", subrole: "", roleDescription: "", name: nil), "WebArea")
        let long = AccessibilityRegions.label(role: "AXButton", subrole: "", roleDescription: "button",
                                              name: String(repeating: "x", count: 50))
        XCTAssertTrue(long.hasSuffix("…»"))
    }
}

final class DisplaySnapshotTests: XCTestCase {
    func testCropAndBackOnARetinaDisplayLeftOfTheMainOne() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let snapshot = DisplaySnapshot(displayID: 2, frame: CGRect(x: -200, y: -50, width: 200, height: 100), scale: 2,
                                       image: image)
        let rect = CGRect(x: -150, y: -40, width: 50.25, height: 20)
        let pixels = snapshot.pixelRect(of: rect)
        XCTAssertEqual(pixels, CGRect(x: 100, y: 20, width: 101, height: 40))
        XCTAssertEqual(snapshot.screenRect(ofPixels: pixels).origin, CGPoint(x: -150, y: -40))
        XCTAssertEqual(snapshot.crop(rect)?.width, 101)
        // Partly outside: clipped to the display.
        XCTAssertEqual(snapshot.pixelRect(of: CGRect(x: -20, y: 0, width: 100, height: 100)),
                       CGRect(x: 360, y: 100, width: 40, height: 100))
        XCTAssertTrue(snapshot.pixelRect(of: CGRect(x: 10, y: 10, width: 5, height: 5)).isNull)
    }
}
