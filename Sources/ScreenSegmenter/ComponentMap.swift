/// Connected areas of similar colour on the sample grid. Equal neighbours always join; others join when
/// their colours differ by at most `tolerance` and the samples one step further out on both sides differ by
/// at most `wideTolerance`:
/// smooth gradients (wallpapers, vibrancy) stay one area, while a soft antialiased edge, which changes
/// colour in several small steps, does not let a pale field leak into the bar around it.
struct ComponentMap {
    struct Stats {
        var count: Int32
        var minX: Int32
        var minY: Int32
        var maxX: Int32
        var maxY: Int32
        /// Colour of the first sample, to compare an area with its surroundings.
        var color: UInt32
    }

    /// Component index per sample.
    let labels: [Int32]
    let stats: [Stats]

    init(grid: PixelGrid, tolerance: UInt32, wideTolerance: UInt32) {
        let w = grid.width, h = grid.height, n = w * h
        var labels = [Int32](repeating: 0, count: n)
        let parent = UnsafeMutablePointer<Int32>.allocate(capacity: max(n, 1))
        defer { parent.deallocate() }

        @inline(__always) func find(_ x: Int32) -> Int32 {
            var x = x
            while parent[Int(x)] != x {
                let p = parent[Int(parent[Int(x)])]
                parent[Int(x)] = p
                x = p
            }
            return x
        }

        var next: Int32 = 0
        grid.samples.withUnsafeBufferPointer { sp in
            labels.withUnsafeMutableBufferPointer { lp in
                let s = sp.baseAddress!, lab = lp.baseAddress!
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        let i = row + x
                        let p = s[i]
                        var l: Int32 = -1
                        // Equal colours always join (thin margins of flat fills around corners); different
                        // ones only where the colour changes smoothly over four samples.
                        if x > 0, case let d = colorDistance(p, s[i - 1]), d == 0 || (d <= tolerance
                            && (x < 2 || x + 1 >= w || colorDistance(s[i - 2], s[i + 1]) <= wideTolerance)) {
                            l = lab[i - 1]
                        }
                        if y > 0, case let d = colorDistance(p, s[i - w]), d == 0 || (d <= tolerance
                            && (y < 2 || y + 1 >= h || colorDistance(s[i - 2 * w], s[i + w]) <= wideTolerance)) {
                            let u = lab[i - w]
                            if l < 0 {
                                l = u
                            } else if l != u {
                                // Union keeping the smaller root, so every parent index is below its child.
                                let a = find(l), b = find(u)
                                if a < b { parent[Int(b)] = a; l = a } else if b < a { parent[Int(a)] = b; l = b } else { l = a }
                            }
                        }
                        if l < 0 {
                            l = next
                            parent[Int(next)] = next
                            next += 1
                        }
                        lab[i] = l
                    }
                }
            }
        }

        // Parents point to smaller indices, so one forward pass resolves every label to its root.
        let count = Int(next)
        var compact = [Int32](repeating: -1, count: count)
        var roots: Int32 = 0
        for l in 0..<count {
            let p = parent[Int(parent[l])]
            parent[l] = p
            if p == Int32(l) {
                compact[l] = roots
                roots += 1
            }
        }

        var stats = [Stats](repeating: Stats(count: 0, minX: .max, minY: .max, maxX: -1, maxY: -1, color: 0),
                            count: Int(roots))
        grid.samples.withUnsafeBufferPointer { sp in
            labels.withUnsafeMutableBufferPointer { lp in
                stats.withUnsafeMutableBufferPointer { st in
                    compact.withUnsafeBufferPointer { cp in
                        for y in 0..<h {
                            let row = y * w
                            let yy = Int32(y)
                            for x in 0..<w {
                                let i = row + x
                                let c = cp[Int(parent[Int(lp[i])])]
                                lp[i] = c
                                let xx = Int32(x)
                                if st[Int(c)].count == 0 { st[Int(c)].color = sp[i] }
                                st[Int(c)].count += 1
                                if xx < st[Int(c)].minX { st[Int(c)].minX = xx }
                                if xx > st[Int(c)].maxX { st[Int(c)].maxX = xx }
                                if yy < st[Int(c)].minY { st[Int(c)].minY = yy }
                                if yy > st[Int(c)].maxY { st[Int(c)].maxY = yy }
                            }
                        }
                    }
                }
            }
        }
        self.labels = labels
        self.stats = stats
    }
}

/// Where neighbouring samples differ clearly: `horizontal[y·w + x]` marks an edge between rows y−1 and y,
/// `vertical[y·w + x]` an edge between columns x−1 and x. Prefix sums answer "how much of row y between
/// x0 and x1 is edge" in constant time, which the panel cutter asks thousands of times.
struct EdgeMaps {
    let width: Int
    let height: Int
    let horizontal: [UInt8]
    let vertical: [UInt8]
    /// Per row: running count of horizontal edges, `width + 1` entries per row.
    private let rowSums: [Int32]
    /// Running count of vertical edges down each column, stored row by row: entry `y·w + x` counts
    /// the edges in column x above row y (`height + 1` rows).
    private let columnSums: [Int32]

    init(grid: PixelGrid, threshold: UInt32) {
        let w = grid.width, h = grid.height
        var hor = [UInt8](repeating: 0, count: w * h)
        var ver = [UInt8](repeating: 0, count: w * h)
        var rows = [Int32](repeating: 0, count: (w + 1) * h)
        var cols = [Int32](repeating: 0, count: w * (h + 1))
        grid.samples.withUnsafeBufferPointer { sp in
            hor.withUnsafeMutableBufferPointer { hp in
                ver.withUnsafeMutableBufferPointer { vp in
                    rows.withUnsafeMutableBufferPointer { rp in
                        cols.withUnsafeMutableBufferPointer { cp in
                            let s = sp.baseAddress!
                            for y in 0..<h {
                                let row = y * w
                                var running: Int32 = 0
                                let rowSum = rp.baseAddress! + y * (w + 1)
                                let colAbove = cp.baseAddress! + y * w
                                let colBelow = cp.baseAddress! + (y + 1) * w
                                for x in 0..<w {
                                    let i = row + x
                                    let p = s[i]
                                    if y > 0 && colorDistance(p, s[i - w]) > threshold {
                                        hp[i] = 1
                                        running += 1
                                    }
                                    rowSum[x + 1] = running
                                    var v: Int32 = 0
                                    if x > 0 && colorDistance(p, s[i - 1]) > threshold {
                                        vp[i] = 1
                                        v = 1
                                    }
                                    colBelow[x] = colAbove[x] + v
                                }
                            }
                        }
                    }
                }
            }
        }
        width = w
        height = h
        horizontal = hor
        vertical = ver
        rowSums = rows
        columnSums = cols
    }

    /// Horizontal edge samples in row `y` for columns `x0..<x1`.
    @inline(__always)
    func rowEdges(_ y: Int, _ x0: Int, _ x1: Int) -> Int {
        let base = y * (width + 1)
        return Int(rowSums[base + x1] - rowSums[base + x0])
    }

    /// Vertical edge samples in column `x` for rows `y0..<y1`.
    @inline(__always)
    func columnEdges(_ x: Int, _ y0: Int, _ y1: Int) -> Int {
        Int(columnSums[y1 * width + x] - columnSums[y0 * width + x])
    }
}
