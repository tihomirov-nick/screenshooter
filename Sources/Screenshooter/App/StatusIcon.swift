import AppKit

/// The menu bar icon: the app's mark as a template image, as big as the menu bar's items allow. The status item is
/// `variableLength`, as wide as the image plus the menu bar's own margins, and the image is the height of the items
/// there (22 pt, `NSStatusBar.system.thickness`): the mark is 20 pt across on a 22 pt canvas, a point of room on each
/// side, like the marks of the other apps of the family. The island draws the same mark with the same code
/// (`markOutline`), and scripts/make_icon.swift draws it large on the app icon with a copy of it.
///
/// The mark is a selection: a frame of strokes with rounded corners, the kind a screenshot tool draws round what it is
/// about to capture, and a plus in place of its bottom right corner, the crosshair that draws it. Its proportions are
/// the user's sample's. The icon never moves: a capture, something landing on the shelf, a capture in progress change
/// nothing in it (only Tomato and Coal move in the menu bar).
@MainActor
enum StatusIcon {
    /// The canvas: as high as the menu bar's items and as wide as the mark and its margin ask, the glyph square.
    nonisolated static let canvas = NSSize(width: 22, height: 22)
    /// The glyph's line, the same part of its side as before the icon grew (1.18 pt on 14.5): a little under a tenth of
    /// the frame's side, the sample's being a tenth. It is drawn as 3 whole pixels on a Retina screen and 2 on a plain
    /// one.
    nonisolated static let lineWidth: CGFloat = 1.63
    /// The square the glyph fills: 40 pixels on a Retina screen.
    nonisolated static let side: CGFloat = 20
    /// The glyph's top on the canvas, the same room above it as below.
    nonisolated static let top: CGFloat = 1

    /// Puts the icon on the status item's button.
    static func attach(to button: NSStatusBarButton) {
        button.image = image()
    }

    /// The icon as a template image, in black as template images want it: the square on whole pixels as near the middle
    /// of the canvas as they allow. It is drawn once for each pixel density, so the lines can keep to whole pixels at 1x
    /// and at 2x.
    nonisolated static func image() -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.a))
            // The line covers whole pixels, as many as its width rounds to: the layout counts on it (see
            // `selectionLayout`), and a line a fraction of a pixel wider would blur at its edges.
            let line = max(1, (lineWidth * scale).rounded()) / scale
            ctx.translateBy(x: ((canvas.width - side) / 2 * scale).rounded() / scale, y: top)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(markOutline(side: side, lineWidth: line, scale: scale))
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Screenshooter"
        return image
    }

    /// The mark as one filled shape in a square of `side` points with y growing down, `lineWidth` thick, for the island.
    /// `scale`, device pixels per point, keeps the lines on whole pixels when the square's corner is on one.
    nonisolated static func markOutline(side: CGFloat, lineWidth: CGFloat, scale: CGFloat? = nil) -> CGPath {
        let mark = selectionPaths(side: side, lineWidth: lineWidth, scale: scale)
        let path = CGMutablePath()
        path.addPath(mark.frame)
        path.addPath(mark.plus)
        return path
    }

    // MARK: - The drawing

    /// The selection's proportions, measured on the user's sample, in parts of the frame's side between the middles of
    /// its lines. Each side has a corner's arm, a gap, a dash, a gap and an arm again, the gaps about as wide as the
    /// line. The bottom right corner is the plus: its bars go on along the right and the bottom line, inwards as far as
    /// an arm and outwards a dash's length, and cross where the two lines would meet.
    enum Selection {
        /// From a corner's point, where the middle lines meet, to the arm's end; the plus's bars reach as far inwards.
        static let arm: CGFloat = 0.283
        static let gap: CGFloat = 0.102
        /// The dash in the middle of a side: what the arms and the gaps leave of it.
        static var dash: CGFloat { 1 - 2 * arm - 2 * gap }
        /// The plus beyond the corner's point.
        static let reach: CGFloat = 0.243
        /// The corners' radius, on the middle line.
        static let radius: CGFloat = 0.107
        /// The sample's line, a tenth of the side: the app icon's.
        static let line: CGFloat = 0.0997
    }

    /// The selection laid out in a square, the same on both axes: the middle of the near lines (left and top) and of
    /// the far ones (right and bottom, where the plus's bars run), where the near corners' arms end and the near
    /// halves' dashes start, the plus's outer ends and the corners' radius. The far half of a side mirrors the near one
    /// about the frame's middle: the dash ends at `mirrored(dashStart)`, the far arms (the plus's inner ends) start at
    /// `mirrored(armEnd)`.
    struct SelectionLayout {
        var near: CGFloat
        var far: CGFloat
        var armEnd: CGFloat
        var dashStart: CGFloat
        var plusEnd: CGFloat
        var radius: CGFloat

        func mirrored(_ position: CGFloat) -> CGFloat { near + far - position }
    }

    /// The selection in a square of `side` points with its corner at 0, the outer edges of the near lines on the
    /// square's near sides and the plus's ends on its far sides. With `scale`, device pixels per point (1 to 3, where
    /// a pixel still shows), the layout keeps to whole pixels, provided the square's corner is on one: the lines cover
    /// as many whole pixels as their width rounds to, every end falls between two pixels, and of such layouts within a
    /// pixel of the ideal size the one closest to the sample's proportions wins.
    nonisolated static func selectionLayout(side: CGFloat, lineWidth: CGFloat, scale: CGFloat? = nil) -> SelectionLayout {
        let p = Selection.self
        let ideal = (side - lineWidth / 2) / (1 + p.reach)
        let near = lineWidth / 2, armEnd = near + p.arm * ideal
        let exact = SelectionLayout(near: near, far: near + ideal, armEnd: armEnd, dashStart: armEnd + p.gap * ideal,
                                    plusEnd: side, radius: p.radius * ideal)
        guard let scale, scale >= 1, scale <= 3 else { return exact }
        // In pixels from here on.
        func square(_ x: CGFloat) -> CGFloat { x * x }
        let middle = max(1, (lineWidth * scale).rounded()) / 2, target = ideal * scale
        let room = (side * scale + 0.001).rounded(.down)
        var best: (cost: CGFloat, layout: SelectionLayout)?
        for frame in stride(from: max(6, (target - 1).rounded(.down)), through: (target + 1).rounded(.up), by: 1) {
            let far = middle + frame, half = middle + frame / 2
            for armEnd in stride(from: (middle + 1).rounded(.up), through: half - 1.5, by: 1) {
                for dashStart in stride(from: armEnd + 1, through: half - 0.5, by: 1) {
                    let dash = 2 * (half - dashStart)
                    for plusEnd in stride(from: (far + 1).rounded(.up), through: room, by: 1) {
                        let cost = square((armEnd - middle) / frame - p.arm) + square((dashStart - armEnd) / frame - p.gap)
                            + square(dash / frame - p.dash) + square((plusEnd - far) / frame - p.reach)
                            + square(frame / target - 1) / 2
                        guard cost < best?.cost ?? .infinity else { continue }
                        best = (cost, SelectionLayout(near: middle / scale, far: far / scale, armEnd: armEnd / scale,
                                                      dashStart: dashStart / scale, plusEnd: plusEnd / scale,
                                                      radius: p.radius * frame / scale))
                    }
                }
            }
        }
        return best?.layout ?? exact
    }

    /// The selection in a square of `side` points with y growing down, as filled shapes: the frame's strokes and the
    /// plus, `lineWidth` thick with straight ends. `scale` keeps them on whole pixels (see `selectionLayout`).
    nonisolated static func selectionPaths(side: CGFloat, lineWidth: CGFloat, scale: CGFloat? = nil)
        -> (frame: CGPath, plus: CGPath) {
        let l = selectionLayout(side: side, lineWidth: lineWidth, scale: scale)
        let r = l.radius, inner = l.mirrored(l.armEnd)
        // The frame's middle line, clockwise from the inner end of the plus's horizontal bar round to that of its
        // vertical bar.
        let line = CGMutablePath()
        line.move(to: CGPoint(x: inner, y: l.far))
        line.addArc(tangent1End: CGPoint(x: l.near, y: l.far), tangent2End: CGPoint(x: l.near, y: l.near), radius: r)
        line.addArc(tangent1End: CGPoint(x: l.near, y: l.near), tangent2End: CGPoint(x: l.far, y: l.near), radius: r)
        line.addArc(tangent1End: CGPoint(x: l.far, y: l.near), tangent2End: CGPoint(x: l.far, y: l.far), radius: r)
        line.addLine(to: CGPoint(x: l.far, y: inner))
        // Along it one side's pattern over and over: a dash, a gap, a corner (both its arms and the bend), a gap. The
        // line starts with a gap.
        let gap = l.dashStart - l.armEnd, dash = l.mirrored(l.dashStart) - l.dashStart
        let corner = 2 * (l.armEnd - l.near - r) + .pi / 2 * r
        let period = dash + corner + 2 * gap
        let frame = line.copy(dashingWithPhase: period - gap, lengths: [dash, gap, corner, gap])
            .copy(strokingWithWidth: lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        let plus = CGMutablePath()
        plus.addRect(CGRect(x: inner, y: l.far - lineWidth / 2, width: l.plusEnd - inner, height: lineWidth))
        plus.addRect(CGRect(x: l.far - lineWidth / 2, y: inner, width: lineWidth, height: l.plusEnd - inner))
        return (frame, plus)
    }
}
