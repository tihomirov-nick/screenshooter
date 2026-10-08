import CoreGraphics
import ShotCore

/// The regions under the cursor ordered from the smallest to the largest: the levels the user moves
/// between with the scroll wheel or the arrow keys.
public enum RegionChain {
    /// Regions that contain the point, smallest first, with near-duplicates merged (the one from the
    /// more telling source stays: a window beats an element with the same frame, an element beats a
    /// pixel box because its title says what it is).
    public static func build(at point: CGPoint, from candidates: [Region]) -> [Region] {
        let containing = candidates.filter {
            !$0.rect.isNull && $0.rect.width >= 4 && $0.rect.height >= 4 && $0.rect.contains(point)
        }
        let sorted = containing.sorted { a, b in
            let da = a.rect.area, db = b.rect.area
            if abs(da - db) > 0.5 { return da < db }
            return priority(a.source) > priority(b.source)
        }
        var chain: [Region] = []
        for region in sorted {
            if let i = chain.lastIndex(where: { isSame($0.rect, region.rect) }) {
                if priority(region.source) > priority(chain[i].source) {
                    chain[i] = region
                }
                continue
            }
            chain.append(region)
        }
        return chain
    }

    /// The level highlighted first: the smallest region big enough to be what a person means to capture
    /// (not a single word or an icon), or the bubble right around it when the pixels show one.
    public static func defaultIndex(in chain: [Region]) -> Int {
        guard !chain.isEmpty else { return 0 }
        for (i, region) in chain.enumerated() where isMeaningful(region.rect) {
            if region.source != .visual, i + 1 < chain.count {
                let next = chain[i + 1]
                if next.source == .visual, next.rect.insetBy(dx: -2, dy: -2).contains(region.rect),
                   next.rect.area <= region.rect.area * 2.5 {
                    return i + 1
                }
            }
            return i
        }
        return chain.count - 1
    }

    static func isMeaningful(_ rect: CGRect) -> Bool {
        min(rect.width, rect.height) >= 18 && rect.area >= 1600
    }

    static func isSame(_ a: CGRect, _ b: CGRect) -> Bool {
        let tolerance = max(3, 0.015 * max(a.width, a.height, b.width, b.height))
        return a.isClose(to: b, tolerance: tolerance) || a.iou(b) >= 0.94
    }

    static func priority(_ source: Region.Source) -> Int {
        switch source {
        case .window: return 6
        case .display: return 5
        case .menuBar: return 4
        case .element: return 3
        case .visual: return 2
        case .text: return 1
        }
    }
}
