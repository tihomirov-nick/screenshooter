import CoreGraphics
import CoreText
import Foundation
import ScreenSegmenter

// Synthetic interface screenshots with known geometry: a messenger (sidebar, header, chat with plain or
// doodle wallpaper, bubbles with tails, a photo, input bar), a web page with cards, and a settings form.
// Drawn at Retina scale into a BGRA bitmap like the ones ScreenCaptureKit returns.

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    init(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) {
        self.r = CGFloat(r) / 255
        self.g = CGFloat(g) / 255
        self.b = CGFloat(b) / 255
        self.a = a
    }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

struct ExpectedRegion {
    var name: String
    /// Points, origin top left.
    var rect: CGRect
}

struct Scene {
    var name: String
    var image: CGImage
    var scale: CGFloat
    var expected: [ExpectedRegion]
    /// Points; boxes found inside this area must be explained by `allowed` (wallpaper must stay quiet).
    var quietArea: CGRect?
    var allowed: [CGRect] = []
    /// Expected text blocks (points) for the Vision detector.
    var textBlocks: [ExpectedRegion] = []
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class SceneCanvas {
    let ctx: CGContext
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat

    init(width: CGFloat, height: CGFloat, scale: CGFloat) {
        self.width = width
        self.height = height
        self.scale = scale
        let pw = Int((width * scale).rounded()), ph = Int((height * scale).rounded())
        ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    func fill(_ r: CGRect, _ c: RGB) {
        ctx.setFillColor(c.cg)
        ctx.fill(r)
    }

    func fillRounded(_ r: CGRect, _ radius: CGFloat, _ c: RGB) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(c.cg)
        ctx.fillPath()
    }

    func strokeRounded(_ r: CGRect, _ radius: CGFloat, _ c: RGB, _ lineWidth: CGFloat) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(c.cg)
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
    }

    func fillEllipse(_ r: CGRect, _ c: RGB) {
        ctx.setFillColor(c.cg)
        ctx.fillEllipse(in: r)
    }

    func strokeEllipse(_ r: CGRect, _ c: RGB, _ lineWidth: CGFloat) {
        ctx.setStrokeColor(c.cg)
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: r)
    }

    func line(_ a: CGPoint, _ b: CGPoint, _ c: RGB, _ lineWidth: CGFloat) {
        ctx.setStrokeColor(c.cg)
        ctx.setLineWidth(lineWidth)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    private func makeLine(_ s: String, size: CGFloat, bold: Bool, _ c: RGB) -> CTLine {
        var font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        if bold, let b = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) { font = b }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): c.cg,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
    }

    /// Draws one line of text with its top at `y`; returns its width.
    @discardableResult
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, bold: Bool = false, _ c: RGB) -> CGFloat {
        let line = makeLine(s, size: size, bold: bold, c)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        ctx.textPosition = CGPoint(x: x, y: y + ascent)
        CTLineDraw(line, ctx)
        return CGFloat(w)
    }

    func textWidth(_ s: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(makeLine(s, size: size, bold: bold, RGB(0, 0, 0)), nil, nil, nil))
    }

    /// A photo-like picture: blurry colour noise over a gradient, a sun and hills, clipped to a rounded rect.
    func photo(_ r: CGRect, radius: CGFloat, rng: inout SplitMix64) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        let nw = max(2, Int(r.width / 3)), nh = max(2, Int(r.height / 3))
        var pixels = [UInt8](repeating: 255, count: nw * nh * 4)
        let base = (Int.random(in: 60...160, using: &rng), Int.random(in: 90...180, using: &rng), Int.random(in: 120...220, using: &rng))
        for y in 0..<nh {
            for x in 0..<nw {
                let i = (y * nw + x) * 4
                let t = Double(y) / Double(nh)
                pixels[i] = UInt8(clamping: base.0 + Int(60 * t) + Int.random(in: -35...35, using: &rng))
                pixels[i + 1] = UInt8(clamping: base.1 - Int(30 * t) + Int.random(in: -35...35, using: &rng))
                pixels[i + 2] = UInt8(clamping: base.2 - Int(70 * t) + Int.random(in: -35...35, using: &rng))
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let noise = CGImage(width: nw, height: nh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: nw * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        ctx.interpolationQuality = .high
        ctx.draw(noise, in: r)
        fillEllipse(CGRect(x: r.minX + r.width * 0.7, y: r.minY + r.height * 0.15, width: r.height * 0.22, height: r.height * 0.22),
                    RGB(255, 236, 160, 0.9))
        ctx.setFillColor(RGB(40, 90, 50, 0.75).cg)
        ctx.move(to: CGPoint(x: r.minX, y: r.maxY))
        ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.35, y: r.minY + r.height * 0.45))
        ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.7))
        ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.8, y: r.minY + r.height * 0.5))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.65))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.fillPath()
        ctx.restoreGState()
    }

    func image() -> CGImage { ctx.makeImage()! }
}

// MARK: - Messenger

enum Wallpaper { case plain, doodles }

struct MessengerTheme {
    var sidebar, rowText, rowSecondary, selectedRow, selectedText, separator, header, headerText: RGB
    var chatPlain, gradientTop, gradientBottom, doodle: RGB
    var incoming, outgoing, messageText, time, inputBar, inputField, placeholder, accent, search, icon: RGB

    static let light = MessengerTheme(
        sidebar: RGB(255, 255, 255), rowText: RGB(20, 20, 20), rowSecondary: RGB(130, 130, 135),
        selectedRow: RGB(64, 140, 230), selectedText: RGB(255, 255, 255), separator: RGB(205, 205, 210),
        header: RGB(255, 255, 255), headerText: RGB(20, 20, 20),
        chatPlain: RGB(222, 230, 238), gradientTop: RGB(206, 226, 178), gradientBottom: RGB(160, 202, 168),
        doodle: RGB(0, 0, 0, 0.11),
        incoming: RGB(255, 255, 255), outgoing: RGB(232, 252, 214), messageText: RGB(15, 15, 15),
        time: RGB(140, 150, 140), inputBar: RGB(255, 255, 255), inputField: RGB(242, 242, 245),
        placeholder: RGB(150, 150, 155), accent: RGB(64, 140, 230), search: RGB(238, 238, 241), icon: RGB(150, 150, 155))

    static let dark = MessengerTheme(
        sidebar: RGB(28, 29, 33), rowText: RGB(240, 240, 240), rowSecondary: RGB(140, 142, 150),
        selectedRow: RGB(52, 104, 180), selectedText: RGB(255, 255, 255), separator: RGB(10, 10, 12),
        header: RGB(36, 37, 42), headerText: RGB(240, 240, 240),
        chatPlain: RGB(17, 18, 22), gradientTop: RGB(48, 56, 82), gradientBottom: RGB(28, 34, 52),
        doodle: RGB(255, 255, 255, 0.07),
        incoming: RGB(44, 46, 52), outgoing: RGB(64, 92, 140), messageText: RGB(236, 236, 236),
        time: RGB(150, 155, 165), inputBar: RGB(36, 37, 42), inputField: RGB(52, 54, 60),
        placeholder: RGB(130, 132, 140), accent: RGB(80, 150, 240), search: RGB(46, 48, 54), icon: RGB(130, 132, 140))
}

private struct Message {
    var outgoing: Bool
    var lines: [String]
    var tail: Bool
    var photo: Bool = false
    var groupBreak: Bool = false
}

func messengerScene(dark: Bool, wallpaper: Wallpaper, width: CGFloat = 1200, height: CGFloat = 800,
                    scale: CGFloat = 2) -> Scene {
    let t = dark ? MessengerTheme.dark : MessengerTheme.light
    let c = SceneCanvas(width: width, height: height, scale: scale)
    var rng = SplitMix64(state: dark ? 7 : 3)
    var expected: [ExpectedRegion] = []
    var allowed: [CGRect] = []
    var textBlocks: [ExpectedRegion] = []

    // Sidebar
    let sidebarWidth: CGFloat = 320
    c.fill(CGRect(x: 0, y: 0, width: sidebarWidth, height: height), t.sidebar)
    expected.append(ExpectedRegion(name: "sidebar", rect: CGRect(x: 0, y: 0, width: sidebarWidth, height: height)))
    let search = CGRect(x: 12, y: 12, width: 296, height: 30)
    c.fillRounded(search, 8, t.search)
    c.text("Поиск", 40, 19, size: 13, t.placeholder)
    c.strokeEllipse(CGRect(x: 21, y: 21, width: 11, height: 11), t.placeholder, 1.5)
    expected.append(ExpectedRegion(name: "search", rect: search))

    let names = ["Анна Смирнова", "Рабочий чат", "Дмитрий", "Мама", "Проект «Север»", "Илья Петров",
                 "Доставка", "Кира", "Telegram", "Борис", "Семья"]
    let previews = ["Окей, созвонимся вечером", "Олег: макеты готовы, смотрите", "Скинь скриншот переписки",
                    "Ты поел?", "Встреча перенесена на четверг", "Спасибо!", "Ваш заказ передан курьеру",
                    "😂😂", "Код подтверждения: 48213", "Документы в почте", "Фото"]
    let avatarColors = [RGB(230, 120, 100), RGB(110, 170, 230), RGB(140, 200, 120), RGB(220, 170, 90),
                        RGB(170, 130, 220), RGB(100, 200, 200), RGB(240, 140, 180)]
    var y: CGFloat = 54
    for i in 0..<names.count where y + 66 <= height {
        let selected = i == 2
        let row = CGRect(x: 6, y: y + 2, width: 308, height: 62)
        if selected {
            c.fillRounded(row, 10, t.selectedRow)
            expected.append(ExpectedRegion(name: "selected row", rect: row))
        }
        c.fillEllipse(CGRect(x: 14, y: y + 10, width: 46, height: 46), avatarColors[i % avatarColors.count])
        let initials = String(names[i].prefix(1))
        c.text(initials, 31, y + 23, size: 18, bold: true, RGB(255, 255, 255))
        c.text(names[i], 70, y + 13, size: 14, bold: true, selected ? t.selectedText : t.rowText)
        c.text(previews[i], 70, y + 35, size: 13, selected ? t.selectedText : t.rowSecondary)
        let time = ["12:41", "11:05", "10:58", "вчера", "пн"][i % 5]
        let tw = c.textWidth(time, size: 12)
        c.text(time, 300 - tw, y + 14, size: 12, selected ? t.selectedText : t.rowSecondary)
        y += 66
    }

    // Hairline between sidebar and chat
    c.fill(CGRect(x: sidebarWidth, y: 0, width: 0.5, height: height), t.separator)
    let chatX = sidebarWidth + 0.5
    let chatWidth = width - chatX

    // Header
    let header = CGRect(x: chatX, y: 0, width: chatWidth, height: 56)
    c.fill(header, t.header)
    c.text("Дмитрий", chatX + 20, 10, size: 15, bold: true, t.headerText)
    c.text("был(а) недавно", chatX + 20, 31, size: 12, t.rowSecondary)
    for k in 0..<3 {
        c.strokeEllipse(CGRect(x: width - 40 - CGFloat(k) * 36, y: 18, width: 20, height: 20), t.icon, 1.6)
    }
    c.fill(CGRect(x: chatX, y: 56, width: chatWidth, height: 0.5), t.separator)
    expected.append(ExpectedRegion(name: "header", rect: header))

    // Chat area
    let inputTop: CGFloat = height - 52
    let chat = CGRect(x: chatX, y: 56.5, width: chatWidth, height: inputTop - 0.5 - 56.5)
    switch wallpaper {
    case .plain:
        c.fill(chat, t.chatPlain)
    case .doodles:
        c.ctx.saveGState()
        c.ctx.clip(to: chat)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [t.gradientTop.cg, t.gradientBottom.cg] as CFArray, locations: [0, 1])!
        c.ctx.drawLinearGradient(gradient, start: CGPoint(x: chat.minX, y: chat.minY),
                                 end: CGPoint(x: chat.maxX, y: chat.maxY), options: [])
        drawDoodles(c, in: chat, color: t.doodle, rng: &rng)
        c.ctx.restoreGState()
    }
    expected.append(ExpectedRegion(name: "chat", rect: chat))

    // Messages
    let messages: [Message] = [
        Message(outgoing: false, lines: ["Привет! Ты уже дома?"], tail: false),
        Message(outgoing: false, lines: ["Скинь, пожалуйста, скриншот переписки", "с менеджером, хочу посмотреть детали"], tail: true),
        Message(outgoing: true, lines: ["Да, сейчас найду"], tail: false, groupBreak: true),
        Message(outgoing: true, lines: ["Вот, держи. Там всё про доставку и оплату."], tail: true),
        Message(outgoing: false, lines: ["Смотри, что нашёл"], tail: false, photo: true, groupBreak: true),
        Message(outgoing: false, lines: ["Кстати, завтра встреча в 11:00,", "не забудь взять ноутбук и зарядку.", "Адрес скину позже."], tail: true),
        Message(outgoing: true, lines: ["Ок, договорились"], tail: true, groupBreak: true),
    ]
    var my = chat.minY + 18
    for m in messages {
        if m.groupBreak { my += 8 }
        let textWidth = m.lines.map { c.textWidth($0, size: 14) }.max() ?? 0
        let timeText = "12:4\(Int.random(in: 0...9, using: &rng))"
        let timeWidth = c.textWidth(timeText, size: 11)
        var bubbleWidth = textWidth + 24 + timeWidth + 10
        var bubbleHeight = 8 + CGFloat(m.lines.count) * 18 + 8
        let photoHeight: CGFloat = 170
        if m.photo {
            bubbleWidth = 280
            bubbleHeight += 3 + photoHeight
        }
        let x = m.outgoing ? width - 20 - bubbleWidth : chatX + 20
        let bubble = CGRect(x: x, y: my, width: bubbleWidth, height: bubbleHeight)
        let fill = m.outgoing ? t.outgoing : t.incoming
        c.fillRounded(bubble, 16, fill)
        var bounds = bubble
        if m.tail {
            // A tail at the bottom corner, like Telegram's last bubble of a group.
            c.ctx.setFillColor(fill.cg)
            if m.outgoing {
                c.fill(CGRect(x: bubble.maxX - 16, y: bubble.maxY - 16, width: 16, height: 16), fill)
                c.ctx.move(to: CGPoint(x: bubble.maxX, y: bubble.maxY - 14))
                c.ctx.addQuadCurve(to: CGPoint(x: bubble.maxX + 7, y: bubble.maxY), control: CGPoint(x: bubble.maxX, y: bubble.maxY - 2))
                c.ctx.addLine(to: CGPoint(x: bubble.maxX - 12, y: bubble.maxY))
                c.ctx.closePath()
                c.ctx.fillPath()
                bounds.size.width += 7
            } else {
                c.fill(CGRect(x: bubble.minX, y: bubble.maxY - 16, width: 16, height: 16), fill)
                c.ctx.move(to: CGPoint(x: bubble.minX, y: bubble.maxY - 14))
                c.ctx.addQuadCurve(to: CGPoint(x: bubble.minX - 7, y: bubble.maxY), control: CGPoint(x: bubble.minX, y: bubble.maxY - 2))
                c.ctx.addLine(to: CGPoint(x: bubble.minX + 12, y: bubble.maxY))
                c.ctx.closePath()
                c.ctx.fillPath()
                bounds.origin.x -= 7
                bounds.size.width += 7
            }
        }
        var ty = bubble.minY + 8
        if m.photo {
            let photo = CGRect(x: bubble.minX + 3, y: bubble.minY + 3, width: bubble.width - 6, height: photoHeight)
            c.photo(photo, radius: 13, rng: &rng)
            expected.append(ExpectedRegion(name: "photo", rect: photo))
            allowed.append(photo)
            ty = photo.maxY + 8
        }
        let textTop = ty
        for line in m.lines {
            c.text(line, bubble.minX + 12, ty, size: 14, t.messageText)
            ty += 18
        }
        c.text(timeText, bubble.maxX - 12 - timeWidth, bubble.maxY - 8 - 13, size: 11, t.time)
        textBlocks.append(ExpectedRegion(name: "message text", rect: CGRect(x: bubble.minX + 12, y: textTop,
                                                                             width: textWidth, height: ty - textTop)))
        expected.append(ExpectedRegion(name: m.outgoing ? "outgoing bubble" : "incoming bubble", rect: bounds))
        allowed.append(bounds)
        my = bubble.maxY + 6
    }
    precondition(my < chat.maxY, "messages overflow the chat")

    // Input bar
    c.fill(CGRect(x: chatX, y: inputTop - 0.5, width: chatWidth, height: 0.5), t.separator)
    let inputBar = CGRect(x: chatX, y: inputTop, width: chatWidth, height: 52)
    c.fill(inputBar, t.inputBar)
    expected.append(ExpectedRegion(name: "input bar", rect: inputBar))
    c.strokeEllipse(CGRect(x: chatX + 16, y: inputTop + 14, width: 24, height: 24), t.icon, 1.6)
    let field = CGRect(x: chatX + 52, y: inputTop + 8, width: chatWidth - 52 - 60, height: 36)
    c.fillRounded(field, 18, t.inputField)
    c.text("Сообщение", field.minX + 16, field.minY + 9, size: 14, t.placeholder)
    expected.append(ExpectedRegion(name: "input field", rect: field))
    let send = CGRect(x: width - 46, y: inputTop + 10, width: 32, height: 32)
    c.fillEllipse(send, t.accent)
    c.line(CGPoint(x: send.midX, y: send.minY + 9), CGPoint(x: send.midX, y: send.maxY - 9), RGB(255, 255, 255), 2.2)
    expected.append(ExpectedRegion(name: "send button", rect: send))

    let name = "messenger-\(dark ? "dark" : "light")-\(wallpaper == .plain ? "plain" : "doodles")"
    return Scene(name: name, image: c.image(), scale: scale, expected: expected, quietArea: chat, allowed: allowed,
                 textBlocks: textBlocks)
}

/// Telegram-like pattern: thin line drawings scattered over the whole area.
private func drawDoodles(_ c: SceneCanvas, in area: CGRect, color: RGB, rng: inout SplitMix64) {
    let cell: CGFloat = 38
    c.ctx.setStrokeColor(color.cg)
    c.ctx.setFillColor(color.cg)
    c.ctx.setLineWidth(1.6)
    c.ctx.setLineCap(.round)
    var y = area.minY - 10
    while y < area.maxY {
        var x = area.minX - 10
        while x < area.maxX {
            let cx = x + CGFloat.random(in: 6...32, using: &rng)
            let cy = y + CGFloat.random(in: 6...32, using: &rng)
            let s = CGFloat.random(in: 7...15, using: &rng)
            switch Int.random(in: 0..<6, using: &rng) {
            case 0:
                c.ctx.strokeEllipse(in: CGRect(x: cx - s, y: cy - s, width: 2 * s, height: 2 * s))
            case 1:
                // Star
                for k in 0..<5 {
                    let a = CGFloat(k) * 4 * .pi / 5 - .pi / 2
                    let p = CGPoint(x: cx + s * cos(a), y: cy + s * sin(a))
                    if k == 0 { c.ctx.move(to: p) } else { c.ctx.addLine(to: p) }
                }
                c.ctx.closePath()
                c.ctx.strokePath()
            case 2:
                // Squiggle
                c.ctx.move(to: CGPoint(x: cx - s, y: cy))
                for k in 1...8 {
                    c.ctx.addLine(to: CGPoint(x: cx - s + CGFloat(k) * s / 4, y: cy + (k % 2 == 0 ? -s / 3 : s / 3)))
                }
                c.ctx.strokePath()
            case 3:
                // Heart made of two arcs and a point
                c.ctx.move(to: CGPoint(x: cx, y: cy + s))
                c.ctx.addCurve(to: CGPoint(x: cx, y: cy - s / 3), control1: CGPoint(x: cx - 1.4 * s, y: cy),
                               control2: CGPoint(x: cx - s / 2, y: cy - 1.2 * s))
                c.ctx.addCurve(to: CGPoint(x: cx, y: cy + s), control1: CGPoint(x: cx + s / 2, y: cy - 1.2 * s),
                               control2: CGPoint(x: cx + 1.4 * s, y: cy))
                c.ctx.strokePath()
            case 4:
                c.ctx.fillEllipse(in: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6))
                c.ctx.strokeEllipse(in: CGRect(x: cx + 6, y: cy - 8, width: 9, height: 9))
            default:
                // Little planet: circle with a ring
                c.ctx.strokeEllipse(in: CGRect(x: cx - s * 0.6, y: cy - s * 0.6, width: 1.2 * s, height: 1.2 * s))
                c.ctx.strokeEllipse(in: CGRect(x: cx - s * 1.2, y: cy - s * 0.3, width: 2.4 * s, height: 0.6 * s))
            }
            x += cell
        }
        y += cell
    }
}

// MARK: - Web page

func webPageScene(dark: Bool = false, width: CGFloat = 1280, height: CGFloat = 860, scale: CGFloat = 2) -> Scene {
    let c = SceneCanvas(width: width, height: height, scale: scale)
    var rng = SplitMix64(state: 11)
    var expected: [ExpectedRegion] = []
    var textBlocks: [ExpectedRegion] = []
    let page = dark ? RGB(18, 19, 22) : RGB(246, 247, 249)
    let cardFill = dark ? RGB(34, 36, 41) : RGB(255, 255, 255)
    let body = dark ? RGB(170, 172, 180) : RGB(80, 84, 92)
    let titleColor = dark ? RGB(240, 240, 240) : RGB(20, 22, 26)
    let accent = RGB(30, 110, 230)
    c.fill(CGRect(x: 0, y: 0, width: width, height: height), page)

    let header = CGRect(x: 0, y: 0, width: width, height: 64)
    c.fill(header, RGB(22, 27, 34))
    c.text("Новости", 24, 20, size: 20, bold: true, RGB(255, 255, 255))
    for (i, item) in ["Главная", "Технологии", "Наука", "Спорт"].enumerated() {
        c.text(item, 200 + CGFloat(i) * 110, 23, size: 14, RGB(200, 205, 212))
    }
    let searchBox = CGRect(x: width - 300, y: 16, width: 260, height: 32)
    c.fillRounded(searchBox, 8, RGB(48, 54, 61))
    c.text("Поиск по сайту", searchBox.minX + 12, searchBox.minY + 8, size: 13, RGB(150, 156, 165))
    expected.append(ExpectedRegion(name: "header", rect: header))
    expected.append(ExpectedRegion(name: "search box", rect: searchBox))

    c.text("Главные события недели", 40, 92, size: 28, bold: true, titleColor)
    let paragraph = ["Мы собрали самое важное за последние семь дней: запуски, исследования и неожиданные",
                     "открытия. Каждая карточка ниже ведёт к подробному материалу с фотографиями, цифрами",
                     "и комментариями экспертов. Подписывайтесь, чтобы не пропустить следующий выпуск."]
    var py: CGFloat = 140
    var pw: CGFloat = 0
    for line in paragraph {
        pw = max(pw, c.text(line, 40, py, size: 15, body))
        py += 22
    }
    textBlocks.append(ExpectedRegion(name: "intro paragraph", rect: CGRect(x: 40, y: 140, width: pw, height: py - 140)))

    let titles = ["Новый телескоп", "Батареи на натрии", "Марафон в горах", "ИИ в медицине", "Город без пробок", "Финал сезона"]
    for row in 0..<2 {
        for col in 0..<3 {
            let card = CGRect(x: 40 + CGFloat(col) * 410, y: 236 + CGFloat(row) * 320, width: 380, height: 296)
            c.ctx.saveGState()
            c.ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 16, color: CGColor(gray: 0, alpha: dark ? 0.5 : 0.14))
            c.fillRounded(card, 12, cardFill)
            c.ctx.restoreGState()
            let photo = CGRect(x: card.minX, y: card.minY, width: card.width, height: 150)
            c.ctx.saveGState()
            c.ctx.addPath(CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12, transform: nil))
            c.ctx.clip()
            c.photo(photo, radius: 0, rng: &rng)
            c.ctx.restoreGState()
            c.text(titles[row * 3 + col], card.minX + 16, photo.maxY + 14, size: 17, bold: true, titleColor)
            c.text("Коротко о главном: что произошло,", card.minX + 16, photo.maxY + 42, size: 14, body)
            c.text("почему это важно и что будет дальше.", card.minX + 16, photo.maxY + 62, size: 14, body)
            let button = CGRect(x: card.minX + 16, y: card.maxY - 48, width: 120, height: 32)
            c.fillRounded(button, 8, accent)
            c.text("Читать", button.minX + 34, button.minY + 8, size: 14, bold: true, RGB(255, 255, 255))
            expected.append(ExpectedRegion(name: "card", rect: card))
            expected.append(ExpectedRegion(name: "card photo", rect: photo))
            expected.append(ExpectedRegion(name: "card button", rect: button))
        }
    }
    return Scene(name: "web-\(dark ? "dark" : "light")", image: c.image(), scale: scale, expected: expected,
                 textBlocks: textBlocks)
}

// MARK: - Settings form

func settingsScene(dark: Bool, width: CGFloat = 900, height: CGFloat = 640, scale: CGFloat = 2) -> Scene {
    let c = SceneCanvas(width: width, height: height, scale: scale)
    var expected: [ExpectedRegion] = []
    let bg = dark ? RGB(30, 30, 32) : RGB(236, 236, 238)
    let group = dark ? RGB(44, 44, 47) : RGB(255, 255, 255)
    let text = dark ? RGB(235, 235, 235) : RGB(25, 25, 25)
    let secondary = dark ? RGB(150, 150, 155) : RGB(120, 120, 125)
    let separator = dark ? RGB(62, 62, 66) : RGB(222, 222, 226)
    let popupFill = dark ? RGB(66, 66, 70) : RGB(238, 238, 241)
    let toggleOff = dark ? RGB(80, 80, 84) : RGB(222, 222, 226)
    c.fill(CGRect(x: 0, y: 0, width: width, height: height), bg)
    c.text("Основные", 40, 28, size: 22, bold: true, text)

    func drawGroup(top: CGFloat, rows: [(String, Int)]) -> CGFloat {
        let rowHeight: CGFloat = 44
        let box = CGRect(x: 40, y: top, width: width - 80, height: rowHeight * CGFloat(rows.count))
        c.fillRounded(box, 10, group)
        expected.append(ExpectedRegion(name: "group", rect: box))
        for (i, row) in rows.enumerated() {
            let y = top + CGFloat(i) * rowHeight
            if i > 0 { c.fill(CGRect(x: box.minX + 16, y: y, width: box.width - 16, height: 0.5), separator) }
            c.text(row.0, box.minX + 16, y + 13, size: 14, text)
            switch row.1 {
            case 0, 1:
                let toggle = CGRect(x: box.maxX - 16 - 42, y: y + 10, width: 42, height: 24)
                c.fillRounded(toggle, 12, row.1 == 1 ? RGB(52, 199, 89) : toggleOff)
                let knobX = row.1 == 1 ? toggle.maxX - 22 : toggle.minX + 2
                c.fillEllipse(CGRect(x: knobX, y: toggle.minY + 2, width: 20, height: 20), RGB(255, 255, 255))
                // Not expected: the 2 pt ring around the knob breaks up under antialiasing, so a switch
                // is found as its knob at best.
            default:
                let popup = CGRect(x: box.maxX - 16 - 160, y: y + 9, width: 160, height: 26)
                c.fillRounded(popup, 6, popupFill)
                c.text("Автоматически", popup.minX + 10, popup.minY + 5, size: 13, text)
                c.line(CGPoint(x: popup.maxX - 18, y: popup.midY - 2), CGPoint(x: popup.maxX - 14, y: popup.midY + 2), secondary, 1.5)
                c.line(CGPoint(x: popup.maxX - 14, y: popup.midY + 2), CGPoint(x: popup.maxX - 10, y: popup.midY - 2), secondary, 1.5)
                expected.append(ExpectedRegion(name: "popup", rect: popup))
            }
        }
        return box.maxY
    }

    var y = drawGroup(top: 76, rows: [("Запускать при входе в систему", 1), ("Звук затвора", 0),
                                      ("Язык интерфейса", 2), ("Копировать в буфер обмена", 1)])
    c.text("Снимки сохраняются в папку, выбранную ниже.", 56, y + 8, size: 12, secondary)
    y = drawGroup(top: y + 40, rows: [("Формат файла", 2), ("Показывать тень окна", 0), ("Распознавать текст", 1)])

    let cancel = CGRect(x: width - 40 - 220, y: height - 60, width: 100, height: 30)
    c.fillRounded(cancel, 7, group)
    c.strokeRounded(cancel.insetBy(dx: 0.25, dy: 0.25), 7, separator, 0.5)
    c.text("Отмена", cancel.minX + 25, cancel.minY + 7, size: 13, text)
    let save = CGRect(x: width - 40 - 100, y: height - 60, width: 100, height: 30)
    c.fillRounded(save, 7, RGB(30, 120, 240))
    c.text("Сохранить", save.minX + 16, save.minY + 7, size: 13, bold: true, RGB(255, 255, 255))
    expected.append(ExpectedRegion(name: "cancel button", rect: cancel))
    expected.append(ExpectedRegion(name: "save button", rect: save))
    return Scene(name: "settings-\(dark ? "dark" : "light")", image: c.image(), scale: scale, expected: expected)
}

// MARK: - Checking and debugging

struct SceneReport {
    var missing: [(ExpectedRegion, CGFloat)] = []
    var garbage: [VisualRegion] = []
    var found: [(ExpectedRegion, VisualRegion, CGFloat)] = []
}

func pointsRect(_ r: CGRect, scale: CGFloat) -> CGRect {
    CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
}

func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
    return i.width * i.height / (a.width * a.height + b.width * b.height - i.width * i.height)
}

func check(_ scene: Scene, _ regions: [VisualRegion], threshold: CGFloat = 0.85) -> SceneReport {
    var report = SceneReport()
    for e in scene.expected {
        let target = pointsRect(e.rect, scale: scene.scale)
        let best = regions.map { ($0, iou($0.rect, target)) }.max { $0.1 < $1.1 }
        if let best, best.1 >= threshold {
            report.found.append((e, best.0, best.1))
        } else {
            report.missing.append((e, best?.1 ?? 0))
        }
    }
    if let quiet = scene.quietArea {
        let area = pointsRect(quiet, scale: scene.scale)
        let allowed = scene.allowed.map { pointsRect($0, scale: scene.scale) }
        for r in regions where r.kind == .box && area.contains(r.rect.insetBy(dx: 2, dy: 2)) {
            let explained = allowed.contains { a in
                iou(a, r.rect) > 0.5 || a.insetBy(dx: -4, dy: -4).contains(r.rect) || r.rect.contains(a)
            }
            if !explained { report.garbage.append(r) }
        }
    }
    return report
}
