/// Panels of a window: recursive XY cuts along lines that cross a whole area — separators, and the edge
/// where one background meets another. The sidebar | chat split comes first, then the chat's header,
/// message area and input bar, and so on down to `maxDepth` levels.
struct PanelCutter {
    let edges: EdgeMaps
    /// All lengths in samples.
    let minWidth: Int
    let minHeight: Int
    /// Share of a row (column) that must be edge for it to cut the area.
    let coverage: Double
    let maxDepth: Int
    let maxPanels: Int

    func panels(in root: GridRect) -> [GridRect] {
        var out: [GridRect] = []
        split(root, depth: 0, into: &out)
        return out
    }

    /// A run of neighbouring cutting rows (or columns): `lo...hi` are edge positions, the line lies between.
    private struct Band { var lo: Int; var hi: Int; var strength: Double }

    private func split(_ r: GridRect, depth: Int, into out: inout [GridRect]) {
        guard depth < maxDepth, out.count < maxPanels, r.width >= minWidth, r.height >= minHeight else { return }
        let rows = bands(count: r.height, start: r.minY, across: r.width) { edges.rowEdges($0, r.minX, r.maxX) }
        let cols = bands(count: r.width, start: r.minX, across: r.height) { edges.columnEdges($0, r.minY, r.maxY) }
        guard !rows.isEmpty || !cols.isEmpty else { return }

        let rowStrength = rows.map(\.strength).max() ?? 0
        let colStrength = cols.map(\.strength).max() ?? 0
        let horizontal = !rows.isEmpty && (cols.isEmpty || rowStrength > colStrength)
        let cuts = horizontal ? rows : cols

        var children: [GridRect] = []
        var start = horizontal ? r.minY : r.minX
        for band in cuts {
            children.append(horizontal ? GridRect(minX: r.minX, minY: start, maxX: r.maxX, maxY: band.lo)
                                       : GridRect(minX: start, minY: r.minY, maxX: band.lo, maxY: r.maxY))
            start = band.hi
        }
        children.append(horizontal ? GridRect(minX: r.minX, minY: start, maxX: r.maxX, maxY: r.maxY)
                                   : GridRect(minX: start, minY: r.minY, maxX: r.maxX, maxY: r.maxY))

        for child in children where child.width >= minWidth && child.height >= minHeight {
            guard out.count < maxPanels else { return }
            out.append(child)
            split(child, depth: depth + 1, into: &out)
        }
    }

    /// Cutting lines across an area of `count` rows starting at `start`, each `across` samples long.
    /// Lines within two samples of the area's own border are its outline, not a cut.
    private func bands(count: Int, start: Int, across: Int, edgesAt: (Int) -> Int) -> [Band] {
        guard count > 6, across > 0 else { return [] }
        var result: [Band] = []
        let need = Int((Double(across) * coverage).rounded(.up))
        var p = start + 2
        let end = start + count - 2
        while p < end {
            let e = edgesAt(p)
            guard e >= need else { p += 1; continue }
            var band = Band(lo: p, hi: p, strength: Double(e) / Double(across))
            p += 1
            while p < end {
                let next = edgesAt(p)
                guard next >= need else { break }
                band.hi = p
                band.strength = max(band.strength, Double(next) / Double(across))
                p += 1
            }
            // Thick runs are areas full of edges (a textured picture), not lines.
            if band.hi - band.lo <= 4 { result.append(band) }
        }
        return result
    }
}
