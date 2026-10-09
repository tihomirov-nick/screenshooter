import AppKit
import ShotCore
import SwiftUI
import UniformTypeIdentifiers

/// The island in every state, with a notch and without, drawn offscreen over a made-up top of the screen, plus the
/// frames of its motion. Each state is checked: what should stand in the middle stands within 1 pt of the island's
/// centre, the header's zones keep equal margins and sit in the middle of the notch's height.
@MainActor
extension PreviewRenderer {
    /// A display: the notch of a 14" MacBook Pro, or a virtual one in the middle of a menu bar.
    struct IslandDisplay {
        let key: String
        let metrics: IslandMetrics
        static let notch = IslandDisplay(key: "notch", metrics: IslandMetrics(notchWidth: 185, notchHeight: 32, hasNotch: true))
        static let plain = IslandDisplay(key: "plain", metrics: IslandMetrics(notchWidth: 190, notchHeight: 24, hasNotch: false))
    }

    struct IslandSample {
        let name: String
        /// For the sheet, in Russian whatever the interface language.
        let label: String
        let state: IslandState
        let shelf: Shelf
        var configure: (IslandModel) -> Void = { _ in }
    }

    // MARK: - States

    static func renderIsland(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        IslandProbe.isEnabled = true
        let samples = islandSamples()
        let displays = [IslandDisplay.notch, .plain]
        var cells: [[CGImage?]] = []
        var report: [String] = []
        var failures = 0
        for sample in samples {
            var row: [CGImage?] = []
            for display in displays {
                let model = IslandModel()
                model.metrics = display.metrics
                model.state = sample.state
                sample.configure(model)
                IslandProbe.frames = [:]
                let panel = model.metrics.panelSize
                let image = renderSwiftUI(IslandStage(model: model, shelf: sample.shelf, actions: noActions), size: panel)
                write(image, to: folder.appendingPathComponent("\(sample.name)-\(display.key).png"))
                row.append(image)
                let checks = checkCentering(model: model, shelf: sample.shelf, frames: IslandProbe.frames, panel: panel)
                failures += checks.filter { !$0.ok }.count
                let line = checks.map { ($0.ok ? "ok " : "BAD ") + $0.text }.joined(separator: "; ")
                report.append("\(sample.name) [\(display.key)]: \(line.isEmpty ? "nothing to check" : line)")
            }
            cells.append(row)
        }
        let language = Localization.current
        let header = language == "ru" ? ["Русский, с вырезом", "Русский, без выреза"] : ["English, notch", "English, no notch"]
        write(sheet(cells: cells, labels: samples.map(\.label), header: header, rowHeights: samples.map { rowHeight($0) }),
              to: folder.appendingPathComponent("states-\(language).png"))
        report.append(failures == 0 ? "ALL CENTRED" : "\(failures) PROBLEMS")
        try? report.joined(separator: "\n").appending("\n")
            .write(to: folder.appendingPathComponent("centering-\(language).txt"), atomically: true, encoding: .utf8)
        print(failures == 0 ? "centering: all good" : "centering: \(failures) problems, see centering-\(language).txt")
    }

    /// One row of the sheet, high enough for the state in either language and on either display.
    private static func rowHeight(_ sample: IslandSample) -> CGFloat {
        switch sample.state {
        case .closed: return 56
        case .peek: return 64
        case .banner: return 116
        case .open: return sample.name.hasPrefix("update") ? 300 : 210
        }
    }

    private static let noActions = IslandActions(
        capture: {}, openFolder: {}, openSettings: {}, clear: {}, edit: { _ in }, open: { _ in }, copy: { _ in },
        copyText: { _ in }, reveal: { _ in }, keep: { _ in }, remove: { _ in }, trash: { _ in }, select: { _ in },
        update: { _ in })

    static let sampleUpdate = Updater.Release(
        version: "1.2.3", title: "Screenshooter 1.2.3",
        notes: "## Что нового\n- Островок раскрывается из центра выреза\n- Новый знак на полке и в строке меню",
        page: URL(string: "https://github.com/tihomirov-nick/screenshooter/releases/tag/v1.2.3")!,
        dmg: URL(string: "https://example.com/Screenshooter-1.2.3.dmg")!, size: 4_200_000)

    private static func islandSamples() -> [IslandSample] {
        let s = SampleShelf()
        let one = s.shelf([s.captures[0]])
        let two = s.shelf([s.captures[0], s.note])
        let three = s.shelf([s.captures[0], s.note, s.pdf])
        let five = s.shelf([s.captures[0], s.note, s.pdf, s.archive, s.captures[1]])
        let twelve = s.shelf(s.captures + [s.note, s.pdf, s.archive, s.longName, s.keynote])
        let files = s.shelf([s.longName, s.keynote, s.pdf, s.note])
        let empty = s.shelf([])
        let failure = Updater.State.failed(.offline, sampleUpdate)
        return [
            IslandSample(name: "closed", label: "Закрыт", state: .closed, shelf: five),
            IslandSample(name: "peek-landscape", label: "Крылья: горизонтальный снимок", state: .peek, shelf: five) {
                $0.peekItemID = s.captures[0].id
            },
            IslandSample(name: "peek-portrait", label: "Крылья: вертикальный снимок", state: .peek, shelf: twelve) {
                $0.peekItemID = s.captures[3].id
            },
            IslandSample(name: "peek-dark", label: "Крылья: тёмный снимок", state: .peek, shelf: twelve) {
                $0.peekItemID = s.captures[5].id
            },
            IslandSample(name: "peek-file", label: "Крылья: файл", state: .peek, shelf: five) { $0.peekItemID = s.pdf.id },
            IslandSample(name: "peek-text", label: "Крылья: текст", state: .peek, shelf: five) { $0.peekItemID = s.note.id },
            IslandSample(name: "banner-text", label: "Баннер: короткий, текст распознан", state: .banner, shelf: five) {
                $0.bannerText = L("Текст скопирован"); $0.bannerSymbol = "text.viewfinder"
            },
            IslandSample(name: "banner-ok", label: "Баннер: успех", state: .banner, shelf: five) {
                $0.bannerText = L("Установлена последняя версия"); $0.bannerSymbol = "checkmark.circle.fill"
            },
            IslandSample(name: "banner-update", label: "Баннер: новая версия", state: .banner, shelf: five) {
                $0.bannerText = L("Доступна версия %@", "1.2.3"); $0.bannerSymbol = "arrow.down.circle.fill"
            },
            IslandSample(name: "banner-error", label: "Баннер: короткая ошибка", state: .banner, shelf: five) {
                $0.bannerText = L("Окно уже закрыто"); $0.bannerSymbol = "exclamationmark.triangle.fill"
            },
            IslandSample(name: "banner-error-capture", label: "Баннер: ошибка снимка", state: .banner, shelf: five) {
                $0.bannerText = CaptureFailure.other.message ?? ""; $0.bannerSymbol = "exclamationmark.triangle.fill"
            },
            IslandSample(name: "banner-error-long", label: "Баннер: длинная ошибка", state: .banner, shelf: five) {
                $0.bannerText = L("Папка снимков недоступна, снимок остался на полке. Выберите папку в настройках")
                $0.bannerSymbol = "exclamationmark.triangle.fill"
            },
            IslandSample(name: "open-empty", label: "Полка: пустая", state: .open, shelf: empty),
            IslandSample(name: "open-1", label: "Полка: 1 карточка", state: .open, shelf: one),
            IslandSample(name: "open-2", label: "Полка: 2 карточки", state: .open, shelf: two),
            IslandSample(name: "open-3", label: "Полка: 3 карточки", state: .open, shelf: three),
            IslandSample(name: "open-5", label: "Полка: 5 карточек, новая подсвечена", state: .open, shelf: five) {
                $0.highlightedItemID = s.captures[0].id
            },
            IslandSample(name: "open-12", label: "Полка: 12 карточек", state: .open, shelf: twelve),
            IslandSample(name: "open-files", label: "Полка: файлы, текст, длинные имена", state: .open, shelf: files),
            IslandSample(name: "open-hover", label: "Карточка под указателем", state: .open, shelf: three) {
                $0.hoveredItemID = s.note.id
            },
            IslandSample(name: "open-selected", label: "Выбранная карточка", state: .open, shelf: five) {
                $0.selectedItemID = s.note.id
            },
            IslandSample(name: "open-toast", label: "Тост «Скопировано» в заголовке", state: .open, shelf: five) {
                $0.selectedItemID = s.note.id; $0.toast = IslandToast(text: L("Скопировано"), symbol: "checkmark.circle.fill")
            },
            IslandSample(name: "open-drop-empty", label: "Перетаскивание на пустую полку", state: .open, shelf: empty) {
                $0.dragOver = true; $0.dropTargeted = true
            },
            IslandSample(name: "open-drop", label: "Перетаскивание в полку", state: .open, shelf: five) {
                $0.dragOver = true; $0.dropTargeted = true
            },
            IslandSample(name: "open-drag-out", label: "Карточка уходит с полки", state: .open, shelf: three) {
                $0.dragOver = true
            },
            IslandSample(name: "update-offer", label: "Обновление: предложение", state: .open, shelf: two) {
                $0.update = .available(sampleUpdate)
            },
            IslandSample(name: "update-download", label: "Обновление: скачивание", state: .open, shelf: two) {
                $0.update = .downloading(sampleUpdate, progress: 0.42)
            },
            IslandSample(name: "update-install", label: "Обновление: установка", state: .open, shelf: two) {
                $0.update = .installing(sampleUpdate)
            },
            IslandSample(name: "update-failed", label: "Обновление: ошибка", state: .open, shelf: two) {
                $0.update = failure
            },
            IslandSample(name: "update-failed-long", label: "Обновление: ошибка с длинным советом", state: .open,
                         shelf: twelve) { $0.update = .failed(.notTrusted, sampleUpdate) },
            IslandSample(name: "update-failed-installer", label: "Обновление: заменить не вышло, установщик", state: .open,
                         shelf: two) { $0.update = .failed(.cannotReplace, sampleUpdate) },
            IslandSample(name: "update-empty", label: "Обновление на пустой полке", state: .open, shelf: empty) {
                $0.update = .available(sampleUpdate)
            },
        ]
    }

    // MARK: - Checks

    struct Check {
        let ok: Bool
        let text: String
    }

    /// Centred parts within 1 pt of the island's centre; the header's zones 16 pt from its edges, clear of the notch,
    /// in the middle of the notch's height; a scrolling strip starting at the left margin.
    static func checkCentering(model: IslandModel, shelf: Shelf, frames: [String: CGRect], panel: CGSize) -> [Check] {
        guard model.state != .closed else { return [] }
        let cx = panel.width / 2, m = model.metrics
        let k = model.dragOver ? 1 + IslandMetrics.dragGrowth : 1
        let size = model.size(for: model.state, shelf: shelf)
        let left = cx - size.width * k / 2, right = cx + size.width * k / 2
        var checks: [Check] = []
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        func f(_ x: CGFloat) -> String { String(format: "%.1f", x) }
        for name in ["banner", "empty", "update", "drop"] {
            guard let frame = frames[name] else { continue }
            checks.append(Check(ok: near(frame.midX, cx), text: "\(name) Δx \(f(frame.midX - cx))"))
        }
        if let a = frames["peek.left"], let b = frames["peek.right"] {
            let mid = (a.midX + b.midX) / 2
            checks.append(Check(ok: near(mid, cx), text: "wings Δx \(f(mid - cx))"))
            let y = m.notchHeight / 2
            checks.append(Check(ok: near(a.midY, y) && near(b.midY, y),
                                text: "wings Δy \(f(a.midY - y))/\(f(b.midY - y))"))
        }
        if let cards = frames["cards"] {
            if model.stripWidth(count: shelf.items.count) <= size.width - 2 * IslandMetrics.padding + 0.5 {
                checks.append(Check(ok: near(cards.midX, cx), text: "cards Δx \(f(cards.midX - cx))"))
            } else {
                let start = cards.minX - left
                checks.append(Check(ok: near(start, IslandMetrics.padding * k), text: "strip starts \(f(start)) from the edge"))
            }
        }
        if let a = frames["header.left"], let b = frames["header.right"] {
            let lm = a.minX - left, rm = right - b.maxX
            checks.append(Check(ok: near(lm, rm) && near(lm, IslandMetrics.padding * k),
                                text: "header margins \(f(lm))/\(f(rm))"))
            let y = m.notchHeight / 2 * k
            checks.append(Check(ok: near(a.midY, y) && near(b.midY, y), text: "header Δy \(f(a.midY - y))/\(f(b.midY - y))"))
            let notchLeft = cx - m.notchWidth * k / 2, notchRight = cx + m.notchWidth * k / 2
            let clear = a.maxX <= notchLeft - IslandMetrics.notchGap + 0.5 && b.minX >= notchRight + IslandMetrics.notchGap - 0.5
            checks.append(Check(ok: clear, text: "clear of the notch \(f(notchLeft - a.maxX))/\(f(b.minX - notchRight))"))
        }
        return checks
    }

    // MARK: - Motion

    /// Frames of each appearance and disappearance, 0–600 ms every 40 ms, as they run in real time, and sheets of them.
    static func renderIslandMotion(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let s = SampleShelf()
        let five = s.shelf([s.captures[0], s.note, s.pdf, s.archive, s.captures[1]])
        let two = s.shelf([s.captures[0], s.note])
        let sequences: [(name: String, display: IslandDisplay, state: IslandState, shelf: Shelf, reduce: Bool,
                         configure: (IslandModel) -> Void)] = [
            ("shelf", .notch, .open, five, false, { _ in }),
            ("peek", .notch, .peek, five, false, { $0.peekItemID = s.captures[0].id }),
            ("banner", .notch, .banner, five, false, { $0.bannerText = L("Текст скопирован"); $0.bannerSymbol = "text.viewfinder" }),
            ("update", .notch, .open, two, false, { $0.update = .available(sampleUpdate) }),
            ("shelf-no-notch", .plain, .open, five, false, { _ in }),
            ("shelf-reduce-motion", .notch, .open, five, true, { _ in }),
            // Pointing at a capture in the wings opens the shelf.
            ("peek-to-shelf", .notch, .open, five, false, { $0.peekItemID = s.captures[0].id; $0.state = .peek }),
        ]
        for sequence in sequences {
            let model = IslandModel()
            model.metrics = sequence.display.metrics
            sequence.configure(model)
            let initial = model.state
            let panel = model.metrics.panelSize
            let stage = IslandStage(model: model, shelf: sequence.shelf, actions: noActions,
                                    reduceMotion: sequence.reduce, keepDrawing: true)
            let hosting = NSHostingView(rootView: stage.frame(width: panel.width, height: panel.height))
            hosting.frame = CGRect(origin: .zero, size: panel)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let height = min(panel.height, model.size(for: sequence.state, shelf: sequence.shelf).height + 34)
            let crop = CGRect(x: (panel.width - 700) / 2, y: 0, width: 700, height: height)
            var sheets: [(String, [(TimeInterval, CGImage)])] = []
            for (direction, from, to) in [("open", initial, sequence.state), ("close", sequence.state, IslandState.closed)] {
                var frames: [(TimeInterval, CGImage)] = []
                for step in 0...15 {
                    // Each frame comes from a run of its own: drawing a picture holds the main thread up, and earlier
                    // pictures in the same run would make SwiftUI's frames fall behind the clock.
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) { model.state = from }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                    let start = Date()
                    model.state = to
                    // SwiftUI takes the change in on the next turn of the run loop, as it does in the app.
                    RunLoop.main.run(until: start.addingTimeInterval(max(Double(step) * 0.04, 0.012)))
                    let before = Date().timeIntervalSince(start)
                    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    // The moment the frame was drawn: between asking for it and getting it.
                    let t = (before + Date().timeIntervalSince(start)) / 2
                    if let image = rep.cgImage, let cropped = image.cropping(to: scaled(crop, 2)) {
                        frames.append((t, cropped))
                        write(cropped, to: folder.appendingPathComponent(String(format: "%@-%@-%03d.png", sequence.name, direction, step)))
                    }
                }
                sheets.append((direction, frames))
            }
            window.contentView = nil
            for (direction, frames) in sheets {
                write(motionSheet(frames, cell: crop.size), to: folder.appendingPathComponent("\(sequence.name)-\(direction).png"))
            }
        }
    }

    private static func scaled(_ rect: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
    }

    // MARK: - Sheets

    /// States in rows, displays in columns, with labels; drawn at 1x from the 2x pictures.
    private static func sheet(cells: [[CGImage?]], labels: [String], header: [String], rowHeights: [CGFloat]) -> CGImage? {
        let labelWidth: CGFloat = 230, cellWidth: CGFloat = 700, headerHeight: CGFloat = 36, gap: CGFloat = 8
        let columns = cells.first?.count ?? 0
        let width = labelWidth + CGFloat(columns) * (cellWidth + gap)
        let height = headerHeight + rowHeights.reduce(0) { $0 + $1 + gap }
        return drawSheet(size: CGSize(width: width, height: height)) { ctx in
            for (c, title) in header.enumerated() {
                drawText(title, at: CGPoint(x: labelWidth + CGFloat(c) * (cellWidth + gap) + 4, y: 10), size: 15, weight: .semibold)
            }
            var y = headerHeight
            for (r, row) in cells.enumerated() {
                drawText(labels[r], at: CGPoint(x: 12, y: y + 8), size: 13, weight: .medium, width: labelWidth - 20)
                for (c, image) in row.enumerated() {
                    guard let image else { continue }
                    let x = labelWidth + CGFloat(c) * (cellWidth + gap)
                    let source = CGRect(x: (CGFloat(image.width) - 2 * cellWidth) / 2, y: 0, width: 2 * cellWidth,
                                        height: min(CGFloat(image.height), 2 * rowHeights[r]))
                    if let part = image.cropping(to: source) {
                        ctx.drawUpright(part, in: CGRect(x: x, y: y, width: cellWidth, height: source.height / 2))
                    }
                }
                y += rowHeights[r] + gap
            }
        }
    }

    /// Frames in rows of four, each with its time.
    private static func motionSheet(_ frames: [(TimeInterval, CGImage)], cell: CGSize) -> CGImage? {
        let columns = 4, gap: CGFloat = 6, label: CGFloat = 22
        let rows = (frames.count + columns - 1) / columns
        let size = CGSize(width: CGFloat(columns) * (cell.width + gap) + gap,
                          height: CGFloat(rows) * (cell.height + label + gap) + gap)
        return drawSheet(size: size) { ctx in
            for (i, (t, image)) in frames.enumerated() {
                let x = gap + CGFloat(i % columns) * (cell.width + gap)
                let y = gap + CGFloat(i / columns) * (cell.height + label + gap)
                drawText("\(Int((t * 1000).rounded())) ms", at: CGPoint(x: x + 2, y: y + 2), size: 12, weight: .semibold)
                ctx.drawUpright(image, in: CGRect(x: x, y: y + label, width: cell.width, height: cell.height))
            }
        }
    }

    /// A 1x picture drawn with y going down.
    private static func drawSheet(size: CGSize, draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(ctx)
        NSGraphicsContext.current = previous
        return ctx.makeImage()
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight,
                                 width: CGFloat = 1000) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        NSAttributedString(string: text, attributes: attributes)
            .draw(with: CGRect(x: point.x, y: point.y, width: width, height: 60),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

private extension CGContext {
    /// Draws `image` upright into `rect` of a context whose y goes down (flipped for text).
    func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}

/// The island over a made-up top of the screen: a wallpaper, the menu bar and, in front of everything, the camera
/// housing, which hides whatever is under it as the real one does.
struct IslandStage: View {
    let model: IslandModel
    let shelf: Shelf
    let actions: IslandActions
    var reduceMotion = false
    /// Keeps SwiftUI drawing every frame, as a window on screen does once it moves, so an animation starts on the next
    /// frame and not when an idle offscreen window gets round to drawing again.
    var keepDrawing = false

    var body: some View {
        let m = model.metrics
        ZStack(alignment: .top) {
            if keepDrawing { KeepDrawing() }
            LinearGradient(colors: [Color(red: 0.74, green: 0.80, blue: 0.90), Color(red: 0.86, green: 0.82, blue: 0.90)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            MenuBarMock(height: m.notchHeight)
            IslandRootView(model: model, shelf: shelf, actions: actions, reduceMotionOverride: reduceMotion ? true : nil)
            if m.hasNotch {
                IslandShape(width: m.notchWidth, height: m.notchHeight, origin: m.notchHeight / 2, flare: 4, radius: 9)
                    .fill(Color.black)
            }
        }
    }
}

/// A speck that never stops changing shape, worked out by SwiftUI on every frame.
private struct KeepDrawing: View {
    @State private var on = false

    var body: some View {
        Circle()
            .trim(from: 0, to: on ? 1 : 0.5)
            .fill(Color.white.opacity(0.02))
            .frame(width: 2, height: 2)
            .animation(.linear(duration: 1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Menu titles on the left and status icons on the right, as grey marks.
private struct MenuBarMock: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.45))
            HStack(spacing: 14) {
                ForEach(Array([30, 34, 28, 40, 36].enumerated()), id: \.offset) { _, width in
                    Capsule().fill(Color.black.opacity(0.28)).frame(width: CGFloat(width), height: 7)
                }
                Spacer()
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.28)).frame(width: 14, height: 12)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: height)
    }
}

/// Made-up shelf content: captures of different shapes (one dark), a text, files with short and long names.
@MainActor
struct SampleShelf {
    var captures: [ShelfItem] = []
    let note: ShelfItem
    let pdf: ShelfItem
    let archive: ShelfItem
    let longName: ShelfItem
    let keynote: ShelfItem
    var thumbnails: [UUID: NSImage] = [:]
    let texts: [UUID: String]

    init() {
        let base = Calendar.current.date(bySettingHour: 10, minute: 21, second: 0, of: Date()) ?? Date()
        let sizes = [(1672, 1246), (840, 220), (2400, 1500), (600, 1776), (1200, 800), (1512, 982), (980, 640)]
        for (i, size) in sizes.enumerated() {
            let item = ShelfItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/preview-\(i).png"),
                                 date: base.addingTimeInterval(-Double(i) * 420), pixelWidth: size.0, pixelHeight: size.1,
                                 shelfOnly: false, isCapture: true)
            captures.append(item)
            thumbnails[item.id] = Shelf.thumbnail(of: SampleShelf.picture(i, width: size.0, height: size.1, dark: i == 5))
        }
        note = ShelfItem(id: UUID(), kind: .text, url: URL(fileURLWithPath: "/tmp/preview.txt"),
                         date: base.addingTimeInterval(-300), shelfOnly: true)
        pdf = ShelfItem(id: UUID(), kind: .file, url: URL(fileURLWithPath: "/tmp/Договор поставки.pdf"),
                        date: base.addingTimeInterval(-400))
        archive = ShelfItem(id: UUID(), kind: .file, url: URL(fileURLWithPath: "/tmp/Макеты.zip"),
                            date: base.addingTimeInterval(-500))
        longName = ShelfItem(id: UUID(), kind: .file,
                             url: URL(fileURLWithPath: "/tmp/Коммерческое предложение для ООО «Северный ветер» (финальная версия).pdf"),
                             date: base.addingTimeInterval(-600))
        keynote = ShelfItem(id: UUID(), kind: .file, url: URL(fileURLWithPath: "/tmp/Презентация квартального отчёта.key"),
                            date: base.addingTimeInterval(-700))
        thumbnails[pdf.id] = NSWorkspace.shared.icon(for: .pdf)
        thumbnails[archive.id] = NSWorkspace.shared.icon(for: .zip)
        thumbnails[longName.id] = NSWorkspace.shared.icon(for: .pdf)
        thumbnails[keynote.id] = NSWorkspace.shared.icon(for: UTType(filenameExtension: "key") ?? .presentation)
        texts = [note.id: "Встреча в четверг в 15:00. Обсудить сроки по второму этапу, бюджет на дизайн и кто готовит презентацию для клиента."]
    }

    func shelf(_ items: [ShelfItem]) -> Shelf {
        Shelf(preview: items, thumbnails: thumbnails, texts: texts)
    }

    /// A window-like picture: a title bar, a sidebar and lines of text, light or dark.
    static func picture(_ i: Int, width: Int, height: Int, dark: Bool) -> CGImage {
        let w = max(1, width / 4), h = max(1, height / 4)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hues: [CGFloat] = [0.58, 0.33, 0.08, 0.75, 0.95, 0.6, 0.12]
        let hue = hues[i % hues.count]
        ctx.setFillColor(dark ? CGColor(gray: 0.11, alpha: 1)
                              : NSColor(hue: hue, saturation: 0.18, brightness: 0.98, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let bar = max(6, h / 12)
        ctx.setFillColor(dark ? CGColor(gray: 0.18, alpha: 1) : NSColor(hue: hue, saturation: 0.35, brightness: 0.9, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: h - bar, width: w, height: bar))
        if w > h {
            ctx.setFillColor(dark ? CGColor(gray: 0.15, alpha: 1) : CGColor(gray: 1, alpha: 0.6))
            ctx.fill(CGRect(x: 0, y: 0, width: w / 4, height: h - bar))
        }
        ctx.setFillColor(dark ? CGColor(gray: 0.45, alpha: 1) : NSColor(hue: hue, saturation: 0.5, brightness: 0.55, alpha: 0.55).cgColor)
        let left = w > h ? w / 4 + 8 : 8
        var y = h - bar - 14
        var row = 0
        while y > 6 {
            let length = CGFloat(w - left - 8) * (row % 3 == 2 ? 0.45 : (row % 2 == 0 ? 0.85 : 0.7))
            ctx.fill(CGRect(x: CGFloat(left), y: CGFloat(y), width: length, height: 5))
            y -= 12
            row += 1
        }
        return ctx.makeImage()!
    }
}
