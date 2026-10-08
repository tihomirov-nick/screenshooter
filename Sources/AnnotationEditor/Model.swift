import AppKit
import Carbon.HIToolbox
import ShotCore

/// Colors are kept as sRGB components so annotations compare, copy and undo as plain values.
struct RGBA: Hashable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
        self.init(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func withAlpha(_ alpha: CGFloat) -> RGBA { RGBA(r, g, b, alpha) }

    /// Perceived brightness, 0 (black) … 1 (white).
    var luminance: CGFloat { 0.299 * r + 0.587 * g + 0.114 * b }

    /// Black or white, whichever stands out against this color.
    var contrasting: RGBA { luminance > 0.62 ? RGBA(0, 0, 0) : RGBA(1, 1, 1) }

    static let red = RGBA(1.00, 0.23, 0.19)
    static let orange = RGBA(1.00, 0.58, 0.00)
    static let yellow = RGBA(1.00, 0.80, 0.00)
    static let green = RGBA(0.20, 0.78, 0.35)
    static let blue = RGBA(0.00, 0.48, 1.00)
    static let purple = RGBA(0.69, 0.32, 0.87)
    static let black = RGBA(0.08, 0.08, 0.09)
    static let white = RGBA(1, 1, 1)

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    var paletteName: String {
        switch self {
        case .red: return L("Красный")
        case .orange: return L("Оранжевый")
        case .yellow: return L("Жёлтый")
        case .green: return L("Зелёный")
        case .blue: return L("Синий")
        case .purple: return L("Фиолетовый")
        case .black: return L("Чёрный")
        case .white: return L("Белый")
        default: return L("Свой цвет")
        }
    }
}

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, counter, pixelate, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble.variable"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "checkerboard.rectangle"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .select: return L("Выбор")
        case .arrow: return L("Стрелка")
        case .line: return L("Линия")
        case .rectangle: return L("Прямоугольник")
        case .ellipse: return L("Эллипс")
        case .pen: return L("Карандаш")
        case .highlighter: return L("Маркер")
        case .text: return L("Текст")
        case .counter: return L("Нумерация")
        case .pixelate: return L("Пикселизация")
        case .crop: return L("Обрезка")
        }
    }

    /// The letter shown in tooltips; tools are switched by physical key so any keyboard layout works.
    var letter: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .line: return "L"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .pen: return "P"
        case .highlighter: return "H"
        case .text: return "T"
        case .counter: return "N"
        case .pixelate: return "B"
        case .crop: return "C"
        }
    }

    var keyCode: Int {
        switch self {
        case .select: return kVK_ANSI_V
        case .arrow: return kVK_ANSI_A
        case .line: return kVK_ANSI_L
        case .rectangle: return kVK_ANSI_R
        case .ellipse: return kVK_ANSI_O
        case .pen: return kVK_ANSI_P
        case .highlighter: return kVK_ANSI_H
        case .text: return kVK_ANSI_T
        case .counter: return kVK_ANSI_N
        case .pixelate: return kVK_ANSI_B
        case .crop: return kVK_ANSI_C
        }
    }

    /// Tools that draw new annotations by dragging.
    var drawsShapes: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .pixelate: return true
        default: return false
        }
    }
}

/// Stroke widths in points of the image; multiplied by the document's style unit.
enum WidthPreset: Int, CaseIterable, Identifiable {
    case thin, medium, thick

    var id: Int { rawValue }

    var points: CGFloat {
        switch self {
        case .thin: return 2
        case .medium: return 4
        case .thick: return 7
        }
    }

    var title: String {
        switch self {
        case .thin: return L("Тонкая линия")
        case .medium: return L("Средняя линия")
        case .thick: return L("Толстая линия")
        }
    }
}

/// Text sizes in points of the image; multiplied by the document's style unit.
enum TextSizePreset: Int, CaseIterable, Identifiable {
    case small, medium, large

    var id: Int { rawValue }

    var points: CGFloat {
        switch self {
        case .small: return 14
        case .medium: return 20
        case .large: return 30
        }
    }

    var shortTitle: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    var title: String {
        switch self {
        case .small: return L("Мелкий текст")
        case .medium: return L("Средний текст")
        case .large: return L("Крупный текст")
        }
    }
}

/// One mark on the image. All geometry is in pixels of the original image, origin at the top left.
struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case arrow(CGPoint, CGPoint)
        case line(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        case highlighter([CGPoint])
        /// Top-left corner of the text box and the text.
        case text(CGPoint, String)
        case counter(CGPoint, Int)
        case pixelate(CGRect)
    }

    var id = UUID()
    var shape: Shape
    var color: RGBA
    var lineWidth: CGFloat
    var filled = false
    var fontSize: CGFloat = 40

    var isText: Bool {
        if case .text = shape { return true }
        return false
    }

    var textString: String? {
        if case .text(_, let s) = shape { return s }
        return nil
    }

    var supportsFill: Bool {
        switch shape {
        case .rectangle, .ellipse: return true
        default: return false
        }
    }

    func translated(by dx: CGFloat, _ dy: CGFloat) -> Annotation {
        var copy = self
        let move = { (p: CGPoint) in CGPoint(x: p.x + dx, y: p.y + dy) }
        switch shape {
        case .arrow(let a, let b): copy.shape = .arrow(move(a), move(b))
        case .line(let a, let b): copy.shape = .line(move(a), move(b))
        case .rectangle(let r): copy.shape = .rectangle(r.offsetBy(dx: dx, dy: dy))
        case .ellipse(let r): copy.shape = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case .pen(let pts): copy.shape = .pen(pts.map(move))
        case .highlighter(let pts): copy.shape = .highlighter(pts.map(move))
        case .text(let o, let s): copy.shape = .text(move(o), s)
        case .counter(let c, let n): copy.shape = .counter(move(c), n)
        case .pixelate(let r): copy.shape = .pixelate(r.offsetBy(dx: dx, dy: dy))
        }
        return copy
    }
}

/// Everything that undo and redo restore.
struct DocState: Equatable {
    var annotations: [Annotation] = []
    /// The part of the image that is kept, in image pixels; nil keeps all of it.
    var crop: CGRect?
}

/// Points where a selected annotation (or the crop frame) can be grabbed and reshaped.
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end

    static let rectHandles: [Handle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        case .start, .end: return CGPoint(x: r.midX, y: r.midY)
        }
    }

    /// The rectangle after dragging this handle to `p`; may come out with negative size until standardized.
    func resize(_ r: CGRect, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch self {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        case .start, .end: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            case .start, .end: return .crosshair
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default: return .crosshair
        }
    }
}

func pointDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

/// A rectangle spanned by two corner points.
func rectSpanning(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

/// Snaps the vector from `a` to `b` to the nearest multiple of 45°.
func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = hypot(dx, dy)
    guard length > 0 else { return b }
    let step = CGFloat.pi / 4
    let angle = (atan2(dy, dx) / step).rounded() * step
    return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
}

/// Moves `b` so that the rectangle from `a` to `b` is a square.
func squareCorner(from a: CGPoint, to b: CGPoint) -> CGPoint {
    let dx = b.x - a.x, dy = b.y - a.y
    let side = max(abs(dx), abs(dy))
    return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
}
