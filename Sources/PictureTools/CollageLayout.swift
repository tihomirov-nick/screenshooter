import CoreGraphics
import Foundation

/// A moodboard's grid: pictures in rows of one height, each row as wide as the canvas, with the same gap between
/// pictures, between rows and around the edge. Pictures keep their proportions and are never cropped. A last row too
/// short to fill the width keeps the usual height and stands in the middle. Frames are in whole pixels from the top
/// left corner, in the order the sizes came.
public struct CollageLayout: Equatable, Sendable {
    public var frames: [CGRect]
    public var size: CGSize

    /// `width` and `spacing` in pixels. About √n pictures to a row: 9 pictures make three rows of three.
    public init(sizes: [CGSize], width: Int, spacing: Int) {
        let gap = max(0, spacing)
        let canvas = max(width, 2 * gap + 1)
        let inner = canvas - 2 * gap
        frames = Array(repeating: .zero, count: sizes.count)
        guard !sizes.isEmpty else {
            size = CGSize(width: canvas, height: 0)
            return
        }
        let aspects = sizes.map { s -> CGFloat in
            s.width > 0 && s.height > 0 ? s.width / s.height : 1
        }
        let perRow = Int(ceil(sqrt(Double(sizes.count))))
        let average = aspects.reduce(0, +) / CGFloat(aspects.count)
        // The height of a full row of average pictures.
        let target = max(1, CGFloat(inner - (perRow - 1) * gap) / (CGFloat(perRow) * average))

        /// The height at which these pictures side by side fill the inner width.
        func fullHeight(_ row: [Int]) -> CGFloat {
            let free = CGFloat(inner - (row.count - 1) * gap)
            return max(1, free / row.map { aspects[$0] }.reduce(0, +))
        }

        var rows: [[Int]] = []
        var row: [Int] = []
        for i in aspects.indices {
            let before = row
            row.append(i)
            let height = fullHeight(row)
            guard height <= target else { continue }
            // Full: end the row with or without this picture, whichever comes nearer the target height.
            if !before.isEmpty, fullHeight(before) - target < target - height {
                rows.append(before)
                row = [i]
            } else {
                rows.append(row)
                row = []
            }
        }
        if !row.isEmpty { rows.append(row) }

        var y = gap
        for (r, row) in rows.enumerated() {
            let full = fullHeight(row)
            // The last row fills the width only when that keeps it near the others' height.
            let justified = r < rows.count - 1 || full <= target * 1.25
            let height = max(1, Int((justified ? full : target).rounded()))
            let widths: [Int]
            if justified {
                widths = Self.split(inner - (row.count - 1) * gap, by: row.map { aspects[$0] })
            } else {
                widths = row.map { max(1, Int((aspects[$0] * CGFloat(height)).rounded())) }
            }
            let used = widths.reduce(0, +) + (row.count - 1) * gap
            var x = gap + max(0, (inner - used) / 2)
            for (k, index) in row.enumerated() {
                frames[index] = CGRect(x: x, y: y, width: widths[k], height: height)
                x += widths[k] + gap
            }
            y += height + gap
        }
        size = CGSize(width: canvas, height: y)
    }

    /// `total` pixels shared in proportion to `weights`, in whole pixels that add up to it exactly (largest remainder).
    static func split(_ total: Int, by weights: [CGFloat]) -> [Int] {
        let sum = weights.reduce(0, +)
        guard sum > 0, total > 0 else { return weights.map { _ in max(0, total / max(1, weights.count)) } }
        let exact = weights.map { CGFloat(total) * $0 / sum }
        var parts = exact.map { Int($0.rounded(.down)) }
        let left = total - parts.reduce(0, +)
        let order = exact.indices.sorted { exact[$0] - CGFloat(parts[$0]) > exact[$1] - CGFloat(parts[$1]) }
        for i in order.prefix(left) { parts[i] += 1 }
        return parts.map { max(1, $0) }
    }
}
