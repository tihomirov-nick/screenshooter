@testable import PictureTools
import XCTest

/// The moodboard's grid: equal gaps everywhere, rows exactly as wide as the canvas, proportions kept, a short last row
/// in the middle.
final class CollageLayoutTests: XCTestCase {
    private func rows(_ layout: CollageLayout) -> [[CGRect]] {
        Dictionary(grouping: layout.frames, by: \.minY).sorted { $0.key < $1.key }.map { $0.value.sorted { $0.minX < $1.minX } }
    }

    /// Every row: the gap between pictures, the same height; rows apart by the gap, the canvas ending a gap below.
    private func assertEvenGaps(_ layout: CollageLayout, spacing: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let grid = rows(layout)
        XCTAssertEqual(grid.first?.first?.minY, spacing, "top margin", file: file, line: line)
        for (r, row) in grid.enumerated() {
            XCTAssertEqual(Set(row.map(\.height)).count, 1, "row \(r) has one height", file: file, line: line)
            for (a, b) in zip(row, row.dropFirst()) {
                XCTAssertEqual(b.minX - a.maxX, spacing, "gap in row \(r)", file: file, line: line)
            }
            if r > 0 {
                XCTAssertEqual(row[0].minY - grid[r - 1][0].maxY, spacing, "gap above row \(r)", file: file, line: line)
            }
        }
        XCTAssertEqual(layout.size.height - (grid.last?.first?.maxY ?? 0), spacing, "bottom margin", file: file, line: line)
    }

    func testSameShapesMakeASquareGrid() {
        let sizes = Array(repeating: CGSize(width: 1600, height: 1000), count: 9)
        let layout = CollageLayout(sizes: sizes, width: 2400, spacing: 24)
        let grid = rows(layout)
        XCTAssertEqual(grid.map(\.count), [3, 3, 3])
        XCTAssertTrue(layout.frames.allSatisfy { $0.size == layout.frames[0].size }, "all cells alike")
        assertEvenGaps(layout, spacing: 24)
        for row in grid {
            XCTAssertEqual(row.first?.minX, 24)
            XCTAssertEqual(row.last?.maxX, 2400 - 24)
        }
        XCTAssertEqual(layout.frames[0].width / layout.frames[0].height, 1.6, accuracy: 0.01)
    }

    func testMixedShapesKeepProportionsAndFillRows() {
        let sizes = [CGSize(width: 1200, height: 800), CGSize(width: 600, height: 1776), CGSize(width: 2400, height: 1500),
                     CGSize(width: 840, height: 220), CGSize(width: 1000, height: 1000), CGSize(width: 980, height: 640),
                     CGSize(width: 3024, height: 4032), CGSize(width: 1512, height: 982), CGSize(width: 500, height: 900),
                     CGSize(width: 1920, height: 1080), CGSize(width: 700, height: 700)]
        let layout = CollageLayout(sizes: sizes, width: 3200, spacing: 32)
        XCTAssertEqual(layout.frames.count, sizes.count)
        assertEvenGaps(layout, spacing: 32)
        let grid = rows(layout)
        XCTAssertGreaterThan(grid.count, 1)
        for row in grid.dropLast() {
            XCTAssertEqual(row.first?.minX, 32, "full rows start at the margin")
            XCTAssertEqual(row.last?.maxX, 3200 - 32, "and end at the margin")
        }
        for (size, frame) in zip(sizes, layout.frames) {
            let want = size.width / size.height, got = frame.width / frame.height
            XCTAssertEqual(got / want, 1, accuracy: 0.03, "proportions of \(size)")
        }
        // Reading order: row by row, left to right, as the pictures came.
        let ordered = layout.frames.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        XCTAssertEqual(ordered, layout.frames)
        let canvas = CGRect(origin: .zero, size: layout.size)
        XCTAssertTrue(layout.frames.allSatisfy { canvas.contains($0) })
    }

    func testShortLastRowStandsInTheMiddle() {
        let sizes = Array(repeating: CGSize(width: 1000, height: 1000), count: 5)
        let layout = CollageLayout(sizes: sizes, width: 2000, spacing: 20)
        let grid = rows(layout)
        XCTAssertEqual(grid.map(\.count), [3, 2])
        let last = grid[1]
        XCTAssertEqual(last[0].height, grid[0][0].height, "the last row keeps the others' height")
        let left = last[0].minX, right = 2000 - last[1].maxX
        XCTAssertLessThanOrEqual(abs(left - right), 1, "in the middle: \(left) / \(right)")
        assertEvenGaps(layout, spacing: 20)
    }

    func testOnePictureFillsTheWidth() {
        let layout = CollageLayout(sizes: [CGSize(width: 800, height: 600)], width: 1600, spacing: 16)
        XCTAssertEqual(layout.frames, [CGRect(x: 16, y: 16, width: 1568, height: 1176)])
        XCTAssertEqual(layout.size, CGSize(width: 1600, height: 1176 + 32))
    }

    func testNoGapsAndNoPictures() {
        let tight = CollageLayout(sizes: Array(repeating: CGSize(width: 400, height: 300), count: 4), width: 1200, spacing: 0)
        assertEvenGaps(tight, spacing: 0)
        XCTAssertEqual(tight.frames.first?.origin, .zero)
        let empty = CollageLayout(sizes: [], width: 1200, spacing: 24)
        XCTAssertTrue(empty.frames.isEmpty)
        XCTAssertEqual(empty.size.height, 0)
    }

    func testSplitAddsUpExactly() {
        let parts = CollageLayout.split(1001, by: [1, 1, 1])
        XCTAssertEqual(parts.reduce(0, +), 1001)
        XCTAssertEqual(Set(parts), [333, 334])
    }
}
