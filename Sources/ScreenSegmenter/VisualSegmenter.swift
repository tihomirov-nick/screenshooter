import CoreGraphics

/// Splits a screenshot of a window (or of any screen area) into the regions a person sees as separate:
/// panels, solid boxes such as message bubbles and cards, and blocks of text.
///
/// API contract used by the Detection module — keep the signatures stable.
public struct VisualSegmenter: Sendable {
    public struct Options: Sendable {
        /// Regions smaller than this on either side (in points) are dropped.
        public var minSide: CGFloat = 14
        /// Upper bound of the result; when exceeded, the smallest regions go first.
        public var maxRegions: Int = 400

        public init() {}
    }

    public var options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    /// Synchronous and thread-safe; meant to run off the main thread.
    /// - Parameters:
    ///   - image: the pixels to analyse (a window or a display crop).
    ///   - pixelScale: pixels per point of that image (2 on Retina screens), so thresholds work in points.
    /// - Returns: regions in pixel coordinates of `image` (origin top left), without the whole-image rectangle.
    public func segment(_ image: CGImage, pixelScale: CGFloat) -> [VisualRegion] {
        let scale = max(pixelScale, 0.5)
        guard let grid = PixelGrid(image: image, pixelScale: scale) else { return [] }
        // Points per grid sample: 1 on Retina and on standard screens, slightly off for fractional scales.
        let pointsPerSample = CGFloat(grid.factor) / scale
        func samples(_ points: CGFloat) -> Int { max(1, Int((points / pointsPerSample).rounded())) }

        let minSide = samples(options.minSide)
        let components = ComponentMap(grid: grid, tolerance: 4, wideTolerance: 6)
        let edges = EdgeMaps(grid: grid, threshold: 10)

        var candidates: [Candidate] = []
        let boxes = BoxFinder(grid: grid, components: components, minSide: minSide,
                              cornerMax: samples(24), maxInset: samples(12), band: 3, sideCoverage: 0.85).find()
        for box in boxes {
            candidates.append(Candidate(rect: box.rect, kind: box.isPanel ? .panel : .box, rank: box.isPanel ? 2 : 0))
        }
        let framed = EdgeRectangles(edges: edges, components: components, minSide: minSide, cornerMax: samples(24),
                                    minRun: max(minSide, samples(16)), largeArea: max(150, minSide * minSide)).find()
        let imageArea = grid.width * grid.height
        for rect in framed {
            let large = Double(rect.area) >= 0.2 * Double(imageArea)
            candidates.append(Candidate(rect: rect, kind: large ? .panel : .box, rank: large ? 2 : 1))
        }
        let whole = GridRect(minX: 0, minY: 0, maxX: grid.width, maxY: grid.height)
        let panels = PanelCutter(edges: edges, minWidth: max(minSide, samples(24)), minHeight: max(minSide, samples(16)),
                                 coverage: 0.9, maxDepth: 6, maxPanels: 160).panels(in: whole)
        for rect in panels {
            candidates.append(Candidate(rect: rect, kind: .panel, rank: 3))
        }

        return finish(candidates, grid: grid, scale: scale)
    }

    private struct Candidate {
        var rect: GridRect
        var kind: VisualRegion.Kind
        /// Lower wins when two candidates describe the same area.
        var rank: Int
    }

    /// Converts to image pixels, drops what is too small or covers the whole image, merges near duplicates
    /// and caps the count.
    private func finish(_ candidates: [Candidate], grid: PixelGrid, scale: CGFloat) -> [VisualRegion] {
        let f = CGFloat(grid.factor)
        let bounds = CGRect(x: 0, y: 0, width: grid.imageWidth, height: grid.imageHeight)
        let minPixels = options.minSide * scale
        let maxArea = 0.97 * bounds.width * bounds.height

        var items: [(rect: CGRect, kind: VisualRegion.Kind, rank: Int)] = []
        for c in candidates {
            let r = CGRect(x: CGFloat(c.rect.minX) * f, y: CGFloat(c.rect.minY) * f,
                           width: CGFloat(c.rect.width) * f, height: CGFloat(c.rect.height) * f).intersection(bounds)
            guard !r.isNull, r.width >= minPixels, r.height >= minPixels, r.width * r.height < maxArea else { continue }
            items.append((r, c.kind, c.rank))
        }
        items.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }

        var kept: [VisualRegion] = []
        kept.reserveCapacity(min(items.count, options.maxRegions))
        for item in items where !kept.contains(where: { intersectionOverUnion($0.rect, item.rect) > 0.9 }) {
            kept.append(VisualRegion(rect: item.rect, kind: item.kind))
        }
        if kept.count > options.maxRegions {
            kept.sort { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            kept.removeLast(kept.count - options.maxRegions)
        }
        kept.sort { $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        return kept
    }
}

func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter)
}
