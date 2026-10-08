import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// What the drawing code needs to know about the document.
struct RenderEnvironment {
    /// Image pixels per point (2 for Retina screenshots).
    var scale: CGFloat
    /// Pixels per point of annotation styles: stroke widths, arrow heads and counters grow with it.
    var unit: CGFloat
    /// The whole image in pixels.
    var imageRect: CGRect
    /// The image pixelated as a whole; pixelate annotations show a part of it.
    var pixelated: CGImage?
}

/// Text lines laid out exactly like the inline NSTextView (TextKit 1, no padding) lays them out,
/// so the caret sits on the rendered glyphs while the text is edited.
/// Works in points of the font; the renderer scales it to image pixels.
struct TextLayout {
    let font: NSFont
    let lines: [CTLine]
    let lineHeight: CGFloat
    let baselineOffset: CGFloat
    let size: CGSize

    static func font(pointSize: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: .bold)
    }

    init(string: String, pointSize: CGFloat) {
        font = Self.font(pointSize: pointSize)
        let metrics = NSLayoutManager()
        lineHeight = metrics.defaultLineHeight(for: font)
        baselineOffset = metrics.defaultBaselineOffset(for: font)
        let normalized = string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        lines = normalized.components(separatedBy: "\n").map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        let width = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        size = CGSize(width: max(width, pointSize * 0.3), height: lineHeight * CGFloat(max(lines.count, 1)))
    }

    /// Glyph outlines with the top-left corner of the text at `origin` in a y-down space,
    /// plus runs of color glyphs (emoji) that have no outlines and are drawn as they are.
    func outlines(at origin: CGPoint) -> (path: CGPath, bitmapRuns: [(run: CTRun, baseline: CGPoint)]) {
        let path = CGMutablePath()
        var bitmapRuns: [(CTRun, CGPoint)] = []
        for (index, line) in lines.enumerated() {
            let baseline = CGPoint(x: origin.x, y: origin.y + CGFloat(index) * lineHeight + baselineOffset)
            let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = (attributes[kCTFontAttributeName] as! CTFont?) ?? (font as CTFont)
                if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) {
                    bitmapRuns.append((run, baseline))
                    continue
                }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for k in 0..<count {
                    // Glyph outlines go up from the baseline; flip them into the y-down space.
                    var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                              tx: baseline.x + positions[k].x, ty: baseline.y - positions[k].y)
                    if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[k], &t) {
                        path.addPath(glyph)
                    }
                }
            }
        }
        return (path, bitmapRuns)
    }
}

enum AnnotationRenderer {
    // MARK: Sizes derived from the stroke width

    static func arrowHead(width w: CGFloat, unit: CGFloat) -> (length: CGFloat, halfWidth: CGFloat) {
        let length = 8 * unit + w * 2.5
        return (length, length * 0.6)
    }

    static func highlighterWidth(_ w: CGFloat, unit: CGFloat) -> CGFloat {
        max(w * 3.5, 12 * unit)
    }

    static func counterRadius(_ w: CGFloat, unit: CGFloat) -> CGFloat {
        9 * unit + w * 1.2
    }

    static func cornerRadius(_ r: CGRect, width w: CGFloat) -> CGFloat {
        min(w * 0.9, min(r.width, r.height) / 4)
    }

    /// Pixelation block size for an image.
    static func pixelBlock(for imageRect: CGRect) -> CGFloat {
        max(8, (min(imageRect.width, imageRect.height) / 40).rounded())
    }

    // MARK: Paths

    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        switch points.count {
        case 1:
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        case 2:
            path.addLine(to: points[1])
        default:
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    /// A filled arrow: a shaft that widens towards a swept-back head, with a round tail.
    static func arrowPaths(from s: CGPoint, to e: CGPoint, width w: CGFloat, unit: CGFloat) -> (shaft: CGPath, head: CGPath) {
        let dx = e.x - s.x, dy = e.y - s.y
        let length = hypot(dx, dy)
        let shaft = CGMutablePath()
        let head = CGMutablePath()
        guard length > 0.5 else {
            shaft.addEllipse(in: CGRect(x: s.x - w / 2, y: s.y - w / 2, width: w, height: w))
            return (shaft, head)
        }
        let d = CGPoint(x: dx / length, y: dy / length)
        let n = CGPoint(x: -d.y, y: d.x)
        var (headLength, headHalf) = arrowHead(width: w, unit: unit)
        if headLength > length * 0.75 {
            let k = length * 0.75 / headLength
            headLength *= k
            headHalf *= k
        }
        func at(_ base: CGPoint, along: CGFloat, across: CGFloat) -> CGPoint {
            CGPoint(x: base.x + d.x * along + n.x * across, y: base.y + d.y * along + n.y * across)
        }
        let tailHalf = max(w * 0.3, 0.75)
        let neckHalf = min(w * 0.62, headHalf * 0.55)
        let neck = at(e, along: -headLength * 0.62, across: 0)
        shaft.move(to: at(s, along: 0, across: tailHalf))
        shaft.addLine(to: at(neck, along: 0, across: neckHalf))
        shaft.addLine(to: at(neck, along: 0, across: -neckHalf))
        shaft.addLine(to: at(s, along: 0, across: -tailHalf))
        let angle = atan2(n.y, n.x)
        // Round tail: half a circle around the start point, on the side away from the head.
        // From -n to +n through -d: decreasing angles, since n is d turned by +90°.
        shaft.addArc(center: s, radius: tailHalf, startAngle: angle + .pi, endAngle: angle, clockwise: true)
        shaft.closeSubpath()

        head.move(to: e)
        head.addLine(to: at(e, along: -headLength, across: headHalf))
        head.addLine(to: at(e, along: -headLength * 0.78, across: 0))
        head.addLine(to: at(e, along: -headLength, across: -headHalf))
        head.closeSubpath()
        return (shaft, head)
    }

    static func rectanglePath(_ r: CGRect, width w: CGFloat) -> CGPath {
        let radius = cornerRadius(r, width: w)
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // MARK: Geometry for selection

    static func bounds(of a: Annotation, env: RenderEnvironment) -> CGRect {
        switch a.shape {
        case .arrow(let s, let e):
            let head = arrowHead(width: a.lineWidth, unit: env.unit)
            return rectSpanning(s, e).insetBy(dx: -head.halfWidth, dy: -head.halfWidth)
        case .line(let s, let e):
            return rectSpanning(s, e).insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        case .rectangle(let r), .ellipse(let r):
            return r.insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        case .pen(let points):
            return smoothPath(points).boundingBoxOfPath.insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        case .highlighter(let points):
            let w = highlighterWidth(a.lineWidth, unit: env.unit)
            return smoothPath(points).boundingBoxOfPath.insetBy(dx: -w / 2, dy: -w / 2)
        case .text(let origin, let string):
            let layout = TextLayout(string: string, pointSize: a.fontSize / env.scale)
            return CGRect(origin: origin, size: CGSize(width: layout.size.width * env.scale,
                                                       height: layout.size.height * env.scale))
        case .counter(let c, _):
            let r = counterRadius(a.lineWidth, unit: env.unit)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .pixelate(let r):
            return r
        }
    }

    static func hitTest(_ a: Annotation, at p: CGPoint, tolerance tol: CGFloat, env: RenderEnvironment) -> Bool {
        func stroked(_ path: CGPath, _ width: CGFloat) -> Bool {
            path.copy(strokingWithWidth: width + 2 * tol, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
        }
        switch a.shape {
        case .arrow(let s, let e):
            let paths = arrowPaths(from: s, to: e, width: a.lineWidth, unit: env.unit)
            let line = CGMutablePath()
            line.move(to: s)
            line.addLine(to: e)
            return stroked(line, a.lineWidth) || paths.head.contains(p)
        case .line(let s, let e):
            let line = CGMutablePath()
            line.move(to: s)
            line.addLine(to: e)
            return stroked(line, a.lineWidth)
        case .rectangle(let r):
            return a.filled ? r.insetBy(dx: -tol, dy: -tol).contains(p) : stroked(rectanglePath(r, width: a.lineWidth), a.lineWidth)
        case .ellipse(let r):
            let path = CGPath(ellipseIn: r, transform: nil)
            return a.filled ? path.contains(p) || stroked(path, 0) : stroked(path, a.lineWidth)
        case .pen(let points):
            return stroked(smoothPath(points), a.lineWidth)
        case .highlighter(let points):
            return stroked(smoothPath(points), highlighterWidth(a.lineWidth, unit: env.unit))
        case .text, .pixelate:
            return bounds(of: a, env: env).insetBy(dx: -tol, dy: -tol).contains(p)
        case .counter(let c, _):
            return pointDistance(c, p) <= counterRadius(a.lineWidth, unit: env.unit) + tol
        }
    }

    // MARK: Drawing (contexts are y-down, in image pixels)

    /// Draws a CGImage upright into a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Pixelated areas go first so every other mark stays visible on top of them.
    static func draw(_ annotations: [Annotation], in ctx: CGContext, env: RenderEnvironment) {
        for a in annotations {
            if case .pixelate = a.shape { draw(a, in: ctx, env: env) }
        }
        for a in annotations {
            if case .pixelate = a.shape { continue }
            draw(a, in: ctx, env: env)
        }
    }

    /// Shadows are set in device space; this keeps them the same size relative to the image at any zoom.
    private static func setSoftShadow(_ ctx: CGContext, unit: CGFloat, strength: CGFloat = 1) {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let k = hypot(t.a, t.b)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.75 * unit * k), blur: 2.5 * unit * k,
                      color: CGColor(gray: 0, alpha: 0.33 * strength))
    }

    static func draw(_ a: Annotation, in ctx: CGContext, env: RenderEnvironment) {
        let color = a.color.cgColor
        let w = a.lineWidth
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.shape {
        case .arrow(let s, let e):
            let paths = arrowPaths(from: s, to: e, width: w, unit: env.unit)
            setSoftShadow(ctx, unit: env.unit)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(color)
            ctx.addPath(paths.shaft)
            ctx.fillPath()
            ctx.addPath(paths.head)
            ctx.fillPath()
            // A thin stroke in the same color rounds the corners of the head.
            ctx.addPath(paths.head)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(max(w * 0.3, 1))
            ctx.strokePath()
            ctx.endTransparencyLayer()

        case .line(let s, let e):
            setSoftShadow(ctx, unit: env.unit)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.move(to: s)
            ctx.addLine(to: e)
            ctx.strokePath()

        case .rectangle(let r):
            setSoftShadow(ctx, unit: env.unit)
            ctx.addPath(rectanglePath(r, width: w))
            if a.filled {
                ctx.setFillColor(color)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(w)
                ctx.strokePath()
            }

        case .ellipse(let r):
            setSoftShadow(ctx, unit: env.unit)
            ctx.addEllipse(in: r)
            if a.filled {
                ctx.setFillColor(color)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(w)
                ctx.strokePath()
            }

        case .pen(let points):
            setSoftShadow(ctx, unit: env.unit, strength: 0.8)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.addPath(smoothPath(points))
            ctx.strokePath()

        case .highlighter(let points):
            // Multiply keeps text under the marker readable on light backgrounds; a faint normal
            // layer on top keeps the stroke visible on dark ones.
            let path = smoothPath(points)
            let width = highlighterWidth(w, unit: env.unit)
            ctx.setLineCap(.butt)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(a.color.withAlpha(0.5).cgColor)
            ctx.setLineWidth(width)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setBlendMode(.normal)
            ctx.setStrokeColor(a.color.withAlpha(0.16).cgColor)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.endTransparencyLayer()

        case .text(let origin, let string):
            drawText(string, at: origin, annotation: a, in: ctx, env: env)

        case .counter(let c, let number):
            let r = counterRadius(w, unit: env.unit)
            let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.saveGState()
            setSoftShadow(ctx, unit: env.unit, strength: 1.2)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            let ring = max(r * 0.11, 1)
            ctx.setStrokeColor(a.color.luminance > 0.85 ? CGColor(gray: 0, alpha: 0.25) : CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(ring)
            ctx.strokeEllipse(in: circle.insetBy(dx: ring / 2, dy: ring / 2))
            drawCentered(String(number), in: circle, color: a.color.contrasting.cgColor, ctx: ctx)

        case .pixelate(let r):
            guard let pixelated = env.pixelated else { return }
            ctx.clip(to: r.intersection(env.imageRect))
            drawImage(pixelated, in: env.imageRect, ctx: ctx)
        }
    }

    private static func drawText(_ string: String, at origin: CGPoint, annotation a: Annotation,
                                 in ctx: CGContext, env: RenderEnvironment) {
        let layout = TextLayout(string: string, pointSize: a.fontSize / env.scale)
        let outlines = layout.outlines(at: .zero)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Lay the text out in points like the text view does, then scale to pixels.
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: env.scale, y: env.scale)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(outlines.path)
        ctx.setStrokeColor(a.color.contrasting.withAlpha(0.92).cgColor)
        ctx.setLineWidth(layout.font.pointSize * 0.17)
        ctx.strokePath()
        ctx.addPath(outlines.path)
        ctx.setFillColor(a.color.cgColor)
        ctx.fillPath()
        for (run, baseline) in outlines.bitmapRuns {
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: baseline.x, y: baseline.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
            ctx.restoreGState()
        }
    }

    /// Draws a short label centered on its glyphs (not on the line box) inside `rect`.
    private static func drawCentered(_ text: String, in rect: CGRect, color: CGColor, ctx: CGContext) {
        let factor: CGFloat = text.count <= 1 ? 1.12 : (text.count == 2 ? 0.92 : 0.72)
        let font = NSFont.systemFont(ofSize: rect.height / 2 * factor, weight: .heavy)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: rounded]))
        let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.textMatrix = .identity
        // Baseline position that puts the glyph box in the middle of the rect (y-down space).
        ctx.translateBy(x: rect.midX - glyphBounds.midX, y: rect.midY + glyphBounds.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(color)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: rounded,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let colored = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = .zero
        CTLineDraw(colored, ctx)
        ctx.restoreGState()
    }

    // MARK: Export

    static func outputColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// The final image: the base, every annotation, cut to the crop.
    static func render(base: CGImage, state: DocState, env: RenderEnvironment) -> CGImage? {
        let full = env.imageRect
        let crop = (state.crop ?? full).intersection(full).integral
        guard crop.width >= 1, crop.height >= 1,
              let ctx = CGContext(data: nil, width: Int(crop.width), height: Int(crop.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: outputColorSpace(for: base),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: crop.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.interpolationQuality = .high
        drawImage(base, in: full, ctx: ctx)
        draw(state.annotations, in: ctx, env: env)
        return ctx.makeImage()
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func pixelated(_ image: CGImage, block: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(block)
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8,
                                       colorSpace: outputColorSpace(for: image))
    }
}
