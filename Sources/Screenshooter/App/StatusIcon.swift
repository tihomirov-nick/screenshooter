import AppKit
import QuartzCore

/// The menu bar icon: the app's mark as a template image. It stands level with FaceID's icon next to it: the same kind
/// of status item (`variableLength`, as wide as the 15 pt image plus the menu bar's own margins) and a glyph as big as
/// FaceID's, 14.5 pt across on a Retina screen, with its top where FaceID's is. The island draws the same mark with the
/// same code (`MarkGlyph`), and scripts/make_icon.swift draws it large on the app icon with a copy of it.
///
/// The mark is a selection: a frame of strokes with rounded corners, the kind a screenshot tool draws round what it is
/// about to capture, and a plus in place of its bottom right corner, the crosshair that draws it. Its proportions are
/// the user's sample's. It moves only at moments that matter and for well under a second: when a capture is taken the
/// frame's strokes run once round it, like the marching ants of a selection, coming out of the plus and going back into
/// it; when something lands on the shelf the icon bounces lightly; while a capture is in progress the frame pulses
/// softly. Frames are drawn only while it moves; with Reduce Motion it never does.
@MainActor
final class StatusIcon {
    static let shared = StatusIcon()

    /// The canvas: 15 pt across, the width of the menu bar icons of all four apps of the family, so the gaps between
    /// them are the same; higher than the glyph, with room above it for the bounce.
    nonisolated static let canvas = NSSize(width: 15, height: 18)
    /// The glyph's line, a little over a tenth of the frame's side as on the sample, and as thick as the corners of
    /// FaceID's glyph.
    nonisolated static let lineWidth: CGFloat = 1.18
    /// The square the glyph fills: 29 pixels on a Retina screen, as FaceID's glyph.
    nonisolated static let side: CGFloat = 14.5
    /// The glyph's top on the canvas, level with the top of FaceID's glyph.
    nonisolated static let top: CGFloat = 2

    /// One frame of the icon; `Frame()` is the icon at rest.
    struct Frame {
        /// How far the frame's strokes have run round it when a capture is taken, 0...1.
        var shot: CGFloat = 0
        /// How high the icon is lifted, in points.
        var lift: CGFloat = 0
        /// The opacity of the frame; the plus stays solid.
        var detail: CGFloat = 1
    }

    enum Motion {
        /// A capture is taken.
        case shot
        /// Something has landed on the shelf: the icon hops and lands.
        case bounce

        var duration: CFTimeInterval {
            switch self {
            case .shot: return 0.6
            case .bounce: return 0.55
            }
        }
    }

    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var motion: (kind: Motion, start: CFTimeInterval)?
    private var pulseStart: CFTimeInterval?

    private init() {}

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.image = Self.image()
    }

    func play(_ kind: Motion) {
        guard !Self.reduceMotion else { return }
        motion = (kind, CACurrentMediaTime())
        run()
    }

    /// The frame pulses while a capture is in progress.
    var capturing = false {
        didSet {
            guard capturing != oldValue else { return }
            pulseStart = capturing && !Self.reduceMotion ? CACurrentMediaTime() : nil
            if pulseStart != nil { run() } else { tick() }
        }
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func run() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var frame = Frame()
        if let pulseStart {
            frame.detail = Self.pulse(now - pulseStart)
        }
        if let motion {
            let t = (now - motion.start) / motion.kind.duration
            if t >= 1 {
                self.motion = nil
            } else {
                switch motion.kind {
                case .shot: frame.shot = Self.ease(t)
                case .bounce: frame.lift = Self.bounce(t)
                }
            }
        }
        button?.image = Self.image(frame)
        if motion == nil, pulseStart == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Slow at both ends, so a motion starts and stops on the icon at rest.
    static func ease(_ t: Double) -> CGFloat {
        CGFloat(t * t * (3 - 2 * t))
    }

    /// How opaque the frame is while a capture is in progress: down to under half and back, every 0.9 s.
    static func pulse(_ seconds: Double) -> CGFloat {
        1 - 0.275 * (1 - cos(2 * .pi * seconds / 0.9))
    }

    /// How high the icon is over the bounce: a hop and a small second one, within the canvas.
    static func bounce(_ t: Double) -> CGFloat {
        if t < 0.6 { return 1.0 * sin(.pi * t / 0.6) }
        if t < 0.9 { return 0.3 * sin(.pi * (t - 0.6) / 0.3) }
        return 0
    }

    /// The icon for `frame` as a template image, in black as template images want it: the square on whole pixels as
    /// near the middle of the canvas as they allow, the frame at the frame's opacity, the plus solid.
    static func image(_ frame: Frame = Frame()) -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Drawn once for each pixel density, so the lines can keep to whole pixels at 1x and at 2x.
            let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.a))
            let mark = selectionPaths(side: side, lineWidth: lineWidth, scale: scale, shot: frame.shot)
            ctx.translateBy(x: ((canvas.width - side) / 2 * scale).rounded() / scale, y: top - frame.lift)
            ctx.setFillColor(CGColor(gray: 0, alpha: frame.detail))
            ctx.addPath(mark.frame)
            ctx.fillPath()
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(mark.plus)
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
    /// plus, `lineWidth` thick with straight ends. `scale` keeps them on whole pixels (see `selectionLayout`). `shot`
    /// runs the frame's strokes clockwise along it by that part of the way from one corner to the next: out of the
    /// plus's horizontal bar, round the frame and into its vertical bar. At 0 and at 1 they are where they rest.
    nonisolated static func selectionPaths(side: CGFloat, lineWidth: CGFloat, scale: CGFloat? = nil, shot: CGFloat = 0)
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
        // Along it one side's pattern over and over: a dash, a gap, a corner (both its arms and the bend), a gap. At
        // rest the line starts with a gap.
        let gap = l.dashStart - l.armEnd, dash = l.mirrored(l.dashStart) - l.dashStart
        let corner = 2 * (l.armEnd - l.near - r) + .pi / 2 * r
        let period = dash + corner + 2 * gap
        var phase = (period - gap - shot * period).truncatingRemainder(dividingBy: period)
        if phase < 0 { phase += period }
        let frame = line.copy(dashingWithPhase: phase, lengths: [dash, gap, corner, gap])
            .copy(strokingWithWidth: lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        let plus = CGMutablePath()
        plus.addRect(CGRect(x: inner, y: l.far - lineWidth / 2, width: l.plusEnd - inner, height: lineWidth))
        plus.addRect(CGRect(x: l.far - lineWidth / 2, y: inner, width: lineWidth, height: l.plusEnd - inner))
        return (frame, plus)
    }
}
