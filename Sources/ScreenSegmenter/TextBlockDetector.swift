import CoreGraphics
import Vision

/// Text lines found by Vision and grouped into blocks (paragraphs, messages, list items).
public enum TextBlockDetector {
    /// Synchronous and thread-safe; slower than `VisualSegmenter.segment` (Vision runs a neural network).
    /// - Returns: `.textBlock` regions in pixel coordinates of `image` (origin top left).
    public static func detect(_ image: CGImage, pixelScale: CGFloat) -> [VisualRegion] {
        let scale = max(pixelScale, 0.5)
        // The recogniser at one pixel per point finds the most lines but sometimes only pieces of pale text
        // on a coloured bubble; the text-rectangle detector at full resolution completes those pieces. Its
        // own finds count only where they touch a recognised line: alone it also sees "text" in doodles.
        let recognized = textLines(in: image, pixelScale: scale, engine: .recognize)
        guard !recognized.isEmpty else { return [] }
        let completing = textLines(in: image, pixelScale: scale, engine: .rectangles, onePixelPerPoint: false)
            .filter { r in recognized.contains { $0.intersects(r) } }
        let lines = recognized + completing
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pad = 3 * scale
        let minSide = 8 * scale
        var blocks: [VisualRegion] = groupLines(lines).compactMap { block in
            let r = block.insetBy(dx: -pad, dy: -pad).intersection(bounds).integral
            guard !r.isNull, r.width >= minSide, r.height >= minSide else { return nil }
            return VisualRegion(rect: r, kind: .textBlock)
        }
        // A spreadsheet gives one block per cell; keep the biggest when there are very many.
        if blocks.count > maxBlocks {
            blocks.sort { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            blocks.removeLast(blocks.count - maxBlocks)
        }
        return blocks
    }

    static let maxBlocks = 800

    enum Engine { case recognize, rectangles }

    /// Line boxes in image pixels (origin top left).
    static func textLines(in image: CGImage, pixelScale: CGFloat, engine: Engine = .recognize,
                          onePixelPerPoint: Bool = true) -> [CGRect] {
        let factor = onePixelPerPoint ? max(1, Int(pixelScale.rounded())) : 1
        let input = factor > 1 ? downscaled(image, by: factor) ?? image : image
        let request: VNImageBasedRequest
        switch engine {
        case .recognize:
            let r = VNRecognizeTextRequest()
            r.recognitionLevel = .fast
            r.usesLanguageCorrection = false
            // The default skips text under 1/32 of the image height, which is most interface text.
            r.minimumTextHeight = Float(min(1, 6.0 * Double(pixelScale) / Double(factor) / Double(max(1, input.height))))
            request = r
        case .rectangles:
            let r = VNDetectTextRectanglesRequest()
            r.reportCharacterBoxes = false
            request = r
        }
        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let boxes: [CGRect] = (request.results ?? []).compactMap { ($0 as? VNDetectedObjectObservation)?.boundingBox }
        return boxes.map { b in
            CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
    }

    /// Joins words of one line and lines of one paragraph. Lines stack into a block when the gap between
    /// them is under ~0.8 of a line height and they overlap or share a left edge; pieces of one line join
    /// over gaps up to 1.5 line heights (a message and its time stamp).
    static func groupLines(_ lines: [CGRect]) -> [CGRect] {
        let sorted = lines.filter { $0.width > 0 && $0.height > 0 }.sorted { $0.minY < $1.minY }
        let n = sorted.count
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        let tallest = sorted.map(\.height).max() ?? 0
        for i in 0..<n {
            let a = sorted[i]
            for j in (i + 1)..<max(i + 1, n) {
                let b = sorted[j]
                if b.minY > a.maxY + tallest { break }
                let small = min(a.height, b.height), large = max(a.height, b.height)
                guard large <= 2.2 * small else { continue }
                let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                if verticalOverlap >= 0.5 * small {
                    let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    if gap <= 1.5 * large { union(i, j) }
                } else {
                    let gap = b.minY - a.maxY
                    guard gap <= 0.8 * small, gap >= -0.5 * small else { continue }
                    let horizontalOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                    if horizontalOverlap > 0 || abs(a.minX - b.minX) <= 1.5 * small { union(i, j) }
                }
            }
        }

        var blocks: [Int: CGRect] = [:]
        for i in 0..<n {
            let root = find(i)
            blocks[root] = blocks[root].map { $0.union(sorted[i]) } ?? sorted[i]
        }
        return blocks.keys.sorted().compactMap { blocks[$0] }
    }

    private static func downscaled(_ image: CGImage, by factor: Int) -> CGImage? {
        let w = max(1, image.width / factor), h = max(1, image.height / factor)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
