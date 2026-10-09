import SwiftUI

/// The island's black body, centred on the notch. It grows out of one point, the middle of the camera housing, evenly
/// in width and height: while it is lower than the notch it floats there as a pill (hidden by the housing); once it is
/// as tall as the notch it rests against the top edge of the screen and keeps growing down. Resting, it leaves the top
/// edge through small concave curves, like the housing itself, and has rounded bottom corners. Shrinking runs the same
/// way back into that point.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    /// From the top edge to the point everything grows from: half the notch's height.
    var origin: CGFloat
    /// The concave curves where the body meets the top edge.
    var flare: CGFloat
    /// The bottom corners.
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(flare, radius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            flare = newValue.second.first
            radius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(0, width), h = max(0, height)
        guard w > 0.01, h > 0.01 else { return Path() }
        let x0 = rect.midX - w / 2, x1 = rect.midX + w / 2
        let y0 = rect.minY + max(0, origin - h / 2), y1 = y0 + h
        // Over the last 6 pt before it reaches the top edge the rounded top corners square off, then the concave
        // curves grow.
        let attach = min(max((h - (2 * origin - 6)) / 6, 0), 1)
        let bottom = min(max(radius, 0), w / 2, h / 2)
        let convex = min(bottom, h - bottom) * max(0, 1 - 2 * attach)
        let curve = min(max(flare, 0) * max(0, 2 * attach - 1), w / 4, h - bottom)
        var path = Path()
        if curve > 0.01 {
            path.move(to: CGPoint(x: x0 - curve, y: y0))
            path.addQuadCurve(to: CGPoint(x: x0, y: y0 + curve), control: CGPoint(x: x0, y: y0))
        } else {
            path.move(to: CGPoint(x: x0 + convex, y: y0))
            path.addQuadCurve(to: CGPoint(x: x0, y: y0 + convex), control: CGPoint(x: x0, y: y0))
        }
        path.addLine(to: CGPoint(x: x0, y: y1 - bottom))
        path.addQuadCurve(to: CGPoint(x: x0 + bottom, y: y1), control: CGPoint(x: x0, y: y1))
        path.addLine(to: CGPoint(x: x1 - bottom, y: y1))
        path.addQuadCurve(to: CGPoint(x: x1, y: y1 - bottom), control: CGPoint(x: x1, y: y1))
        if curve > 0.01 {
            path.addLine(to: CGPoint(x: x1, y: y0 + curve))
            path.addQuadCurve(to: CGPoint(x: x1 + curve, y: y0), control: CGPoint(x: x1, y: y0))
        } else {
            path.addLine(to: CGPoint(x: x1, y: y0 + convex))
            path.addQuadCurve(to: CGPoint(x: x1 - convex, y: y0), control: CGPoint(x: x1, y: y0))
        }
        path.closeSubpath()
        return path
    }
}
