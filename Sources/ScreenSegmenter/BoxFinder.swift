/// Solid shapes: areas of one colour (or a smooth gradient) whose outline is a rectangle, possibly with
/// rounded corners and a small tail — message bubbles, cards, buttons, fields, highlighted rows — and,
/// when large, the backgrounds of panels. Text and pictures inside are holes and do not matter: only the
/// border of the shape is checked, by walking each side inward until the area covers it.
///
/// A side with the same colour on its outside (the inside of a bordered field, or a patch of wallpaper
/// fenced off by doodles) must be straight and square to the corner; only sides against another colour
/// may be rounded or start a little inside (bubble tails, antialiasing).
struct BoxFinder {
    let grid: PixelGrid
    let components: ComponentMap
    /// All lengths in samples.
    let minSide: Int
    /// Rounded corners up to this radius are skipped when checking a side.
    let cornerMax: Int
    /// How far inside the bounding box a straight side may start (tails of bubbles, antialiasing).
    let maxInset: Int
    /// Depth of the strip in which a side counts as covered, to ride over thin patterns and noise.
    let band: Int
    /// Share of a side that must belong to the area.
    let sideCoverage: Double

    struct Found {
        var rect: GridRect
        var isPanel: Bool
    }

    private enum Side: CaseIterable { case top, bottom, left, right }

    func find() -> [Found] {
        let w = grid.width, h = grid.height
        let imageArea = w * h
        var found: [Found] = []
        components.labels.withUnsafeBufferPointer { labelsBuffer in
            grid.samples.withUnsafeBufferPointer { samplesBuffer in
                let labels = labelsBuffer.baseAddress!, samples = samplesBuffer.baseAddress!
                for (index, s) in components.stats.enumerated() {
                    let box = GridRect(minX: Int(s.minX), minY: Int(s.minY), maxX: Int(s.maxX) + 1, maxY: Int(s.maxY) + 1)
                    guard box.width >= minSide, box.height >= minSide else { continue }
                    guard Double(box.area) < 0.97 * Double(imageArea) else { continue }
                    // At least half the outline's worth of samples: drops sparse specks spread over a big box.
                    guard Int(s.count) >= box.width + box.height else { continue }
                    // Thin outlines (doodles, glyphs like "О", icon rings) hold all their sides to the strict test.
                    let thin = Double(s.count) < 0.35 * Double(box.area)
                    let c = Int32(index)
                    let ok = Side.allCases.allSatisfy { side in
                        let strict = thin || outsideMatches(side, of: box, color: s.color, samples: samples)
                        return covered(side, of: box, label: c, labels: labels, strict: strict)
                    }
                    guard ok else { continue }

                    let share = Double(box.area) / Double(imageArea)
                    let touching = (box.minX <= 1 ? 1 : 0) + (box.minY <= 1 ? 1 : 0)
                        + (box.maxX >= w - 1 ? 1 : 0) + (box.maxY >= h - 1 ? 1 : 0)
                    let isPanel = share >= 0.25 || (touching >= 2 && share >= 0.05) || (touching >= 1 && share >= 0.12)
                    found.append(Found(rect: box, isPanel: isPanel))
                }
            }
        }
        return found
    }

    /// Most of five probes a few samples beyond the side have the area's own colour.
    private func outsideMatches(_ side: Side, of box: GridRect, color: UInt32, samples: UnsafePointer<UInt32>) -> Bool {
        let w = grid.width, h = grid.height
        let gap = 4
        var similar = 0, total = 0
        for k in 1...5 {
            let x: Int, y: Int
            switch side {
            case .top: x = box.minX + box.width * k / 6; y = box.minY - gap
            case .bottom: x = box.minX + box.width * k / 6; y = box.maxY - 1 + gap
            case .left: x = box.minX - gap; y = box.minY + box.height * k / 6
            case .right: x = box.maxX - 1 + gap; y = box.minY + box.height * k / 6
            }
            guard x >= 0, y >= 0, x < w, y < h else { continue }
            total += 1
            if colorDistance(samples[y * w + x], color) <= 8 { similar += 1 }
        }
        return total > 0 && similar * 2 > total
    }

    /// The side, corners aside, is covered by the area within a strip starting at most a few samples
    /// inside the bounding box. Strict: a one-sample strip right at the edge, small corners only.
    private func covered(_ side: Side, of box: GridRect, label c: Int32, labels: UnsafePointer<Int32>, strict: Bool) -> Bool {
        let w = grid.width, h = grid.height
        let depth = strict ? 1 : band
        let horizontal = side == .top || side == .bottom
        let length = horizontal ? box.width : box.height
        let across = horizontal ? box.height : box.width
        let corner = strict ? min(cornerMax, 6, length / 8) : min(cornerMax, length / 4)
        let maxShift = strict ? 1 : min(maxInset, max(0, across / 3 - depth))
        let from = (horizontal ? box.minX : box.minY) + corner
        let to = (horizontal ? box.maxX : box.maxY) - 1 - corner
        guard to >= from else { return false }
        let stride = max(1, (to - from + 1) / 160)
        let count = (to - from + stride) / stride
        let needed = Int((Double(count) * sideCoverage).rounded(.up))

        for shift in 0...maxShift {
            var hits = 0, seen = 0
            var p = from
            while p <= to {
                seen += 1
                for j in 0..<depth {
                    let q = shift + j
                    let x: Int, y: Int
                    switch side {
                    case .top: x = p; y = box.minY + q
                    case .bottom: x = p; y = box.maxY - 1 - q
                    case .left: x = box.minX + q; y = p
                    case .right: x = box.maxX - 1 - q; y = p
                    }
                    if x >= 0, y >= 0, x < w, y < h, labels[y * w + x] == c { hits += 1; break }
                }
                // Give up on this shift as soon as the target cannot be reached.
                if hits + (count - seen) < needed { break }
                p += stride
            }
            if hits >= needed { return true }
        }
        return false
    }
}
