/// Rectangles drawn by straight edges: photos and previews inside messages, video frames, bordered boxes,
/// cards with a gradient fill — shapes whose inside is not one colour, so `BoxFinder` cannot see them.
/// Long straight edge runs are collected, then a top and a bottom run of about the same extent are paired
/// and confirmed by a left and a right run, allowing rounded corners. A real object sits on a plain
/// surface (a bubble, a card, the page), so the strip just outside each side must belong to large areas
/// of one colour; rectangles that texture inside a photo happens to form fail that test.
struct EdgeRectangles {
    let edges: EdgeMaps
    let components: ComponentMap
    /// All lengths in samples.
    let minSide: Int
    let cornerMax: Int
    /// Shortest straight run kept.
    let minRun: Int
    /// Areas with at least this many samples count as plain surroundings.
    let largeArea: Int

    private struct HRun { var y: Int; var x0: Int; var x1: Int }   // x1 exclusive
    private struct VRun { var x: Int; var y0: Int; var y1: Int }   // y1 exclusive

    func find() -> [GridRect] {
        let runs = horizontalRuns()
        guard runs.count >= 2 else { return [] }
        let columns = verticalRunsByColumn()
        var found: [GridRect] = []

        for (i, t) in runs.enumerated() {
            var matches = 0
            var j = i + 1
            while j < runs.count && matches < 3 {
                let b = runs[j]
                j += 1
                let height = b.y - t.y
                guard height >= minSide else { continue }
                // Rounded and square corners shorten the straight runs differently (a photo flush with the
                // top of a rounded card): the ends may differ by up to a corner radius.
                guard abs(b.x0 - t.x0) <= cornerMax, abs(b.x1 - t.x1) <= cornerMax else { continue }
                let overlap = min(b.x1, t.x1) - max(b.x0, t.x0)
                guard Double(overlap) >= 0.8 * Double(max(b.x1 - b.x0, t.x1 - t.x0)) else { continue }
                guard let left = side(in: columns, candidates: Array(((max(t.x0, b.x0) - cornerMax - 1)...(min(t.x0, b.x0) + 1)).reversed()),
                                      top: t.y, bottom: b.y, radius: { (t.x0 - $0, b.x0 - $0) }),
                      let right = side(in: columns, candidates: Array((max(t.x1, b.x1) - 1)...(min(t.x1, b.x1) + cornerMax + 1)),
                                       top: t.y, bottom: b.y, radius: { ($0 - t.x1, $0 - b.x1) })
                else { continue }
                let rect = GridRect(minX: left, minY: t.y, maxX: right, maxY: b.y)
                guard rect.width >= minSide, surroundingsArePlain(rect) else { continue }
                found.append(rect)
                matches += 1
            }
        }
        return found
    }

    /// The first of `candidates` (ordered from the shape outward) holding a vertical run along the whole
    /// straight part of the side. How far the top and bottom runs stop short of a column gives the corner
    /// radii there, and the straight part lies between them; a square corner needs the run to reach it.
    private func side(in columns: [[VRun]], candidates: [Int], top: Int, bottom: Int,
                      radius: (Int) -> (top: Int, bottom: Int)) -> Int? {
        for x in candidates where x >= 0 && x < columns.count {
            let r = radius(x)
            let from = top + max(0, r.top) + 2, to = bottom - max(0, r.bottom) - 2
            guard to > from else { continue }
            if columns[x].contains(where: { $0.y0 <= from && $0.y1 >= to }) { return x }
        }
        return nil
    }

    /// Most of the strip two samples outside each side (corners aside) belongs to large plain areas.
    private func surroundingsArePlain(_ r: GridRect) -> Bool {
        let w = edges.width, h = edges.height
        let labels = components.labels, stats = components.stats
        func plain(_ x: Int, _ y: Int) -> Bool? {
            guard x >= 0, y >= 0, x < w, y < h else { return nil }
            return Int(stats[Int(labels[y * w + x])].count) >= largeArea
        }
        func share(_ points: [(Int, Int)]) -> Double {
            var hits = 0, total = 0
            for (x, y) in points {
                guard let p = plain(x, y) else { continue }
                total += 1
                if p { hits += 1 }
            }
            // A side on the image border has nothing outside: take it as plain.
            return total == 0 ? 1 : Double(hits) / Double(total)
        }
        let insetX = min(cornerMax, r.width / 4), insetY = min(cornerMax, r.height / 4)
        let xs = Array(stride(from: r.minX + insetX, to: r.maxX - insetX, by: max(1, (r.width - 2 * insetX) / 40)))
        let ys = Array(stride(from: r.minY + insetY, to: r.maxY - insetY, by: max(1, (r.height - 2 * insetY) / 40)))
        let shares = [
            share(xs.map { ($0, r.minY - 2) }),
            share(xs.map { ($0, r.maxY + 1) }),
            share(ys.map { (r.minX - 2, $0) }),
            share(ys.map { (r.maxX + 1, $0) }),
        ]
        return shares.allSatisfy { $0 >= 0.5 } && shares.reduce(0, +) / 4 >= 0.7
    }

    /// Runs of horizontal edges along rows, sorted by row; a run continues over gaps of up to two samples.
    /// A run directly under an equal run of the previous row is the same antialiased edge and is skipped.
    private func horizontalRuns() -> [HRun] {
        let w = edges.width, h = edges.height
        var runs: [HRun] = []
        var previous: [HRun] = []
        var current: [HRun] = []
        edges.horizontal.withUnsafeBufferPointer { buffer in
            let e = buffer.baseAddress!
            for y in 1..<max(1, h) {
                current.removeAll(keepingCapacity: true)
                let row = e + y * w
                var x = 0
                while x < w {
                    if row[x] == 0 { x += 1; continue }
                    let start = x
                    var last = x
                    x += 1
                    while x < w {
                        if row[x] != 0 { last = x } else if x - last > 2 { break }
                        x += 1
                    }
                    if last - start + 1 >= minRun {
                        current.append(HRun(y: y, x0: start, x1: last + 1))
                    }
                    x = last + 1
                }
                for run in current where !previous.contains(where: { sameSpan($0.x0, $0.x1, run.x0, run.x1) }) {
                    runs.append(run)
                }
                swap(&previous, &current)
            }
        }
        return runs
    }

    /// Runs of vertical edges for every column (index = column), found row by row to stay cache friendly.
    private func verticalRunsByColumn() -> [[VRun]] {
        let w = edges.width, h = edges.height
        var columns = [[VRun]](repeating: [], count: w)
        var start = [Int](repeating: -1, count: w)
        var last = [Int](repeating: -1, count: w)
        edges.vertical.withUnsafeBufferPointer { buffer in
            let e = buffer.baseAddress!
            for y in 0..<h {
                let row = e + y * w
                for x in 1..<max(1, w) {
                    if row[x] != 0 {
                        if start[x] < 0 { start[x] = y }
                        last[x] = y
                    } else if start[x] >= 0 && y - last[x] > 2 {
                        if last[x] - start[x] + 1 >= minRun {
                            columns[x].append(VRun(x: x, y0: start[x], y1: last[x] + 1))
                        }
                        start[x] = -1
                    }
                }
            }
        }
        for x in 0..<w where start[x] >= 0 && last[x] - start[x] + 1 >= minRun {
            columns[x].append(VRun(x: x, y0: start[x], y1: last[x] + 1))
        }
        // The same antialiased edge flagged in two neighbouring columns: keep the left one.
        if w > 1 {
            for x in stride(from: w - 1, to: 0, by: -1) where !columns[x].isEmpty && !columns[x - 1].isEmpty {
                let left = columns[x - 1]
                columns[x].removeAll { run in left.contains { sameSpan($0.y0, $0.y1, run.y0, run.y1) } }
            }
        }
        return columns
    }

    /// The same edge spread over two rows (columns) by antialiasing: both ends within a sample. A frame
    /// just inside another (a photo inset in its bubble) has its ends further in and is kept.
    private func sameSpan(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Bool {
        abs(a0 - b0) <= 1 && abs(a1 - b1) <= 1
    }
}
