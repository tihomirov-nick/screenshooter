import CoreGraphics
import Foundation
import XCTest
@testable import ScreenSegmenter

final class ScreenSegmenterTests: XCTestCase {
    private let segmenter = VisualSegmenter()

    private func assertScene(_ scene: Scene, maxGarbage: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        let regions = segmenter.segment(scene.image, pixelScale: scene.scale)
        let report = check(scene, regions)
        for (expected, best) in report.missing {
            XCTFail("\(scene.name): \(expected.name) \(expected.rect) not found (best IoU \(String(format: "%.2f", best)))",
                    file: file, line: line)
        }
        XCTAssertLessThanOrEqual(report.garbage.count, maxGarbage,
                                 "\(scene.name): boxes on the wallpaper \(report.garbage.map(\.rect))", file: file, line: line)
        assertOutputRules(regions, image: scene.image, scale: scene.scale, file: file, line: line)
    }

    private func assertOutputRules(_ regions: [VisualRegion], image: CGImage, scale: CGFloat,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let minPixels = segmenter.options.minSide * scale
        XCTAssertLessThanOrEqual(regions.count, segmenter.options.maxRegions, file: file, line: line)
        for r in regions {
            XCTAssertTrue(bounds.contains(r.rect), "\(r.rect) outside the image", file: file, line: line)
            XCTAssertGreaterThanOrEqual(min(r.rect.width, r.rect.height), minPixels - 0.5, "\(r.rect) too small", file: file, line: line)
            XCTAssertLessThan(r.rect.width * r.rect.height, 0.97 * bounds.width * bounds.height, "whole image returned",
                              file: file, line: line)
        }
    }

    // MARK: Scenes

    func testMessengerLightPlain() { assertScene(messengerScene(dark: false, wallpaper: .plain)) }
    func testMessengerLightDoodles() { assertScene(messengerScene(dark: false, wallpaper: .doodles)) }
    func testMessengerDarkPlain() { assertScene(messengerScene(dark: true, wallpaper: .plain)) }
    func testMessengerDarkDoodles() { assertScene(messengerScene(dark: true, wallpaper: .doodles)) }
    func testWebPageLight() { assertScene(webPageScene(dark: false)) }
    func testWebPageDark() { assertScene(webPageScene(dark: true)) }
    func testSettingsLight() { assertScene(settingsScene(dark: false)) }
    func testSettingsDark() { assertScene(settingsScene(dark: true)) }

    func testStandardAndFractionalScales() {
        assertScene(messengerScene(dark: false, wallpaper: .doodles, scale: 1))
        assertScene(webPageScene(scale: 1))
        assertScene(settingsScene(dark: true, scale: 1))
        assertScene(messengerScene(dark: true, wallpaper: .plain, scale: 1.5))
    }

    /// The app passes crops of the frozen display image; a cropped CGImage shares its parent's data provider,
    /// so the segmenter must not read pixels from there.
    func testCroppedImage() throws {
        let scene = messengerScene(dark: false, wallpaper: .doodles)
        let chat = try XCTUnwrap(scene.expected.first { $0.name == "chat" }).rect
        let cropRect = pointsRect(chat, scale: scene.scale).integral
        let cropped = try XCTUnwrap(scene.image.cropping(to: cropRect))
        let regions = segmenter.segment(cropped, pixelScale: scene.scale)
        let bubbles = scene.expected.filter { $0.name.hasSuffix("bubble") }
        XCTAssertFalse(bubbles.isEmpty)
        for bubble in bubbles {
            let target = pointsRect(bubble.rect, scale: scene.scale).offsetBy(dx: -cropRect.minX, dy: -cropRect.minY)
            let best = regions.map { iou($0.rect, target) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(best, 0.85, "\(bubble.name) in the cropped chat")
        }
    }

    /// A window captured on its own: transparent rounded corners and a soft shadow margin around it.
    func testTransparentWindowImage() throws {
        let scene = settingsScene(dark: false)
        let margin: CGFloat = 40
        let w = scene.image.width + Int(2 * margin * scene.scale), h = scene.image.height + Int(2 * margin * scene.scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let frame = CGRect(x: margin * scene.scale, y: margin * scene.scale,
                           width: CGFloat(scene.image.width), height: CGFloat(scene.image.height))
        ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.clip()
        ctx.draw(scene.image, in: frame)
        let image = try XCTUnwrap(ctx.makeImage())

        let regions = segmenter.segment(image, pixelScale: scene.scale)
        assertOutputRules(regions, image: image, scale: scene.scale)
        for group in scene.expected where group.name == "group" {
            let target = pointsRect(group.rect, scale: scene.scale).offsetBy(dx: margin * scene.scale, dy: margin * scene.scale)
            let best = regions.map { iou($0.rect, target) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(best, 0.85, "settings group inside a captured window")
        }
    }

    func testDegenerateImages() throws {
        func plain(_ w: Int, _ h: Int, alpha: CGFloat = 1) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: alpha))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return try XCTUnwrap(ctx.makeImage())
        }
        for (w, h) in [(1, 1), (2, 3), (7, 5), (40, 1), (300, 200)] {
            XCTAssertTrue(segmenter.segment(try plain(w, h), pixelScale: 2).isEmpty, "\(w)x\(h)")
        }
        XCTAssertTrue(segmenter.segment(try plain(300, 200, alpha: 0), pixelScale: 2).isEmpty, "transparent")
        XCTAssertTrue(TextBlockDetector.detect(try plain(300, 200), pixelScale: 2).isEmpty)
        XCTAssertTrue(TextBlockDetector.detect(try plain(1, 1), pixelScale: 1).isEmpty)
    }

    /// Many cells: the result stays within the cap and keeps the largest regions.
    func testRegionCap() throws {
        let c = SceneCanvas(width: 800, height: 600, scale: 2)
        c.fill(CGRect(x: 0, y: 0, width: 800, height: 600), RGB(255, 255, 255))
        var y: CGFloat = 0
        while y < 600 { c.fill(CGRect(x: 0, y: y, width: 800, height: 0.5), RGB(210, 212, 216)); y += 21 }
        var x: CGFloat = 0
        while x < 800 { c.fill(CGRect(x: x, y: 0, width: 0.5, height: 600), RGB(210, 212, 216)); x += 61 }
        var options = VisualSegmenter.Options()
        options.maxRegions = 50
        let regions = VisualSegmenter(options: options).segment(c.image(), pixelScale: 2)
        XCTAssertEqual(regions.count, 50)
    }

    func testConcurrentCallsGiveSameResults() {
        let scenes = [messengerScene(dark: false, wallpaper: .doodles), webPageScene(), settingsScene(dark: true),
                      messengerScene(dark: true, wallpaper: .plain)]
        let sequential = scenes.map { segmenter.segment($0.image, pixelScale: $0.scale) }
        var parallel = [[VisualRegion]](repeating: [], count: scenes.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: scenes.count * 2) { i in
            let k = i % scenes.count
            let r = segmenter.segment(scenes[k].image, pixelScale: scenes[k].scale)
            lock.lock()
            parallel[k] = r
            lock.unlock()
        }
        XCTAssertEqual(sequential, parallel)
    }

    // MARK: Text blocks

    func testTextBlocks() {
        let scenes = [messengerScene(dark: false, wallpaper: .doodles), messengerScene(dark: true, wallpaper: .plain),
                      webPageScene()]
        var found = 0, total = 0
        for scene in scenes {
            let blocks = TextBlockDetector.detect(scene.image, pixelScale: scene.scale)
            XCTAssertTrue(blocks.allSatisfy { $0.kind == .textBlock })
            let report = check(Scene(name: scene.name, image: scene.image, scale: scene.scale, expected: scene.textBlocks),
                               blocks, threshold: 0.6)
            found += report.found.count
            total += scene.textBlocks.count
            for (e, best) in report.missing { print("text block missed in \(scene.name): \(e.rect) best IoU \(best)") }
            if let quiet = scene.quietArea {
                let area = pointsRect(quiet, scale: scene.scale)
                let allowed = scene.allowed.map { pointsRect($0, scale: scene.scale) }
                let stray = blocks.filter { b in area.contains(b.rect) && !allowed.contains { $0.intersects(b.rect) } }
                XCTAssertLessThanOrEqual(stray.count, 1, "\(scene.name): text found in the wallpaper \(stray.map(\.rect))")
            }
        }
        XCTAssertGreaterThanOrEqual(Double(found), 0.9 * Double(total), "text blocks found: \(found) of \(total)")
    }

    func testLineGrouping() {
        let lineHeight: CGFloat = 32
        // A three-line paragraph, a message with its time stamp on the same line, and a separate paragraph
        // after a big gap.
        let lines = [
            CGRect(x: 100, y: 100, width: 600, height: lineHeight),
            CGRect(x: 100, y: 140, width: 560, height: lineHeight),
            CGRect(x: 100, y: 180, width: 300, height: lineHeight),
            CGRect(x: 100, y: 400, width: 300, height: lineHeight),
            CGRect(x: 420, y: 404, width: 60, height: 24),
            CGRect(x: 100, y: 600, width: 500, height: lineHeight),
        ]
        let blocks = TextBlockDetector.groupLines(lines)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks.contains(CGRect(x: 100, y: 100, width: 600, height: 112)))
        XCTAssertTrue(blocks.contains(CGRect(x: 100, y: 400, width: 380, height: lineHeight)))
    }

    // MARK: Timing (printed, not asserted: debug builds are much slower than the app's release build)

    func testTiming() {
        let scene = messengerScene(dark: false, wallpaper: .doodles, width: 1512, height: 982)
        let t0 = Date()
        _ = segmenter.segment(scene.image, pixelScale: 2)
        let t1 = Date()
        _ = TextBlockDetector.detect(scene.image, pixelScale: 2)
        let t2 = Date()
        print(String(format: "3024×1964 segment %.0f ms, text %.0f ms (this build)",
                     t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000))
    }
}
