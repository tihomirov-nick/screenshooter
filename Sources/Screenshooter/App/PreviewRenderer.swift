import AnnotationEditor
import AppKit
import Detection
import ShotCore
import SwiftUI
import UniformTypeIdentifiers

/// `Screenshooter --render-previews DIR` draws the overlay and every island state with made-up content
/// into PNG files and quits — for checking the look without touching the screen.
@MainActor
enum PreviewRenderer {
    static func run(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshot = DisplaySnapshot(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2,
                                       image: fakeScreen())
        let view = OverlayView(snapshot: snapshot, backingScale: 2)

        var state = OverlayState()
        state.pointer = CGPoint(x: 900, y: 430)
        state.highlight = CGRect(x: 700, y: 396, width: 420, height: 64)
        state.title = L("Блок")
        state.detail = "420 × 64"
        state.level = "2/6"
        state.hint = L("Клик — снимок  ·  Перетаскивание — своя область  ·  ↑ ↓ или колесо — меньше/больше  ·  Пробел — окно  ·  Esc — отмена")
        view.update(state, animated: false)
        write(render(view.layer!, size: view.bounds.size, scale: 2), to: folder.appendingPathComponent("overlay-region.png"))

        state.highlight = CGRect(x: 430, y: 160, width: 900, height: 640)
        state.title = "Group"
        state.detail = "900 × 640"
        state.level = "4/6"
        view.update(state, animated: false)
        write(render(view.layer!, size: view.bounds.size, scale: 2), to: folder.appendingPathComponent("overlay-panel.png"))

        var manual = OverlayState()
        manual.pointer = CGPoint(x: 1010, y: 610)
        manual.highlight = CGRect(x: 640, y: 380, width: 370, height: 230)
        manual.manual = true
        manual.detail = "370 × 230"
        manual.showLoupe = true
        view.update(manual, animated: false)
        write(render(view.layer!, size: view.bounds.size, scale: 2), to: folder.appendingPathComponent("overlay-manual.png"))

        // The island in each state, on a light menu bar. The shelf holds captures, a text and two files.
        var items = (0..<5).map { i in
            ShelfItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/preview-\(i).png"),
                      date: Date().addingTimeInterval(-Double(i) * 600), pixelWidth: [1672, 840, 2400, 600, 1200][i],
                      pixelHeight: [1246, 220, 1500, 1776, 800][i], shelfOnly: false, isCapture: true)
        }
        var thumbs: [UUID: NSImage] = [:]
        for (i, item) in items.enumerated() {
            thumbs[item.id] = Shelf.thumbnail(of: fakeThumbnail(i, width: item.pixelWidth, height: item.pixelHeight))
        }
        let note = ShelfItem(id: UUID(), kind: .text, url: URL(fileURLWithPath: "/tmp/preview.txt"),
                             date: Date().addingTimeInterval(-300), shelfOnly: true)
        let pdf = ShelfItem(id: UUID(), kind: .file, url: URL(fileURLWithPath: "/tmp/Договор поставки.pdf"),
                            date: Date().addingTimeInterval(-400))
        let archive = ShelfItem(id: UUID(), kind: .file, url: URL(fileURLWithPath: "/tmp/Макеты.zip"),
                                date: Date().addingTimeInterval(-500))
        items.insert(contentsOf: [note, pdf, archive], at: 1)
        thumbs[pdf.id] = NSWorkspace.shared.icon(for: .pdf)
        thumbs[archive.id] = NSWorkspace.shared.icon(for: .zip)
        let texts = [note.id: "Встреча в четверг в 15:00. Обсудить сроки по второму этапу, бюджет на дизайн и кто готовит презентацию для клиента."]
        let shelf = Shelf(preview: items, thumbnails: thumbs, texts: texts)
        let actions = IslandActions(capture: {}, openFolder: {}, openSettings: {}, clear: {}, edit: { _ in },
                                    open: { _ in }, copy: { _ in }, copyText: { _ in }, reveal: { _ in }, keep: { _ in },
                                    remove: { _ in }, trash: { _ in }, select: { _ in }, update: { _ in })
        let states: [(String, IslandState, (IslandModel) -> Void)] = [
            ("closed", .closed, { _ in }),
            ("peek", .peek, { $0.peekItemID = items[0].id }),
            ("banner", .banner, { $0.bannerText = L("Текст скопирован"); $0.bannerSymbol = "text.viewfinder" }),
            ("open", .open, { $0.highlightedItemID = items[0].id }),
            ("open-toast", .open, { $0.toast = L("Скопировано") }),
            ("open-selected", .open, { $0.selectedItemID = items[0].id }),
            ("open-drop", .open, { $0.dropTargeted = true }),
            ("open-update", .open, { $0.update = .available(sampleRelease) }),
            ("open-downloading", .open, { $0.update = .downloading(sampleRelease, progress: 0.42) }),
            ("open-update-failed", .open, { $0.update = .failed(.notTrusted, sampleRelease) }),
        ]
        for (name, islandState, configure) in states {
            let model = IslandModel()
            model.metrics = IslandMetrics(notchWidth: 185, notchHeight: 32, hasNotch: true)
            model.state = islandState
            configure(model)
            let size = model.metrics.panelSize
            let content = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.93), Color(white: 0.80)], startPoint: .top, endPoint: .bottom)
                IslandRootView(model: model, shelf: shelf, actions: actions)
            }
            .frame(width: size.width, height: size.height)
            write(renderSwiftUI(content, size: size), to: folder.appendingPathComponent("island-\(name).png"))
        }
        writeStatusIconFrames(into: folder)

        let empty = IslandModel()
        empty.metrics = IslandMetrics(notchWidth: 185, notchHeight: 32, hasNotch: true)
        empty.state = .open
        let emptyShelf = Shelf(preview: [], thumbnails: [:])
        let size = empty.metrics.panelSize
        let emptyContent = ZStack(alignment: .top) {
            Color(white: 0.9)
            IslandRootView(model: empty, shelf: emptyShelf, actions: actions)
        }
        .frame(width: size.width, height: size.height)
        write(renderSwiftUI(emptyContent, size: size), to: folder.appendingPathComponent("island-empty.png"))
    }

    private static let sampleRelease = Updater.Release(
        version: "1.1.0", title: "Screenshooter 1.1.0",
        notes: "## Что нового\n- На полку можно класть любые файлы и текст\n- Островок раскрывается из выреза",
        page: URL(string: "https://github.com/tihomirov-nick/screenshooter/releases/tag/v1.1.0")!,
        dmg: URL(string: "https://example.com/Screenshooter-1.1.0.dmg")!, size: 4_000_000)

    /// The menu bar icon at rest and through each of its motions, white on a dark menu bar, one strip each.
    private static func writeStatusIconFrames(into folder: URL) {
        let strips: [(String, [NSImage])] = [
            ("rest", [StatusIcon.image()]),
            ("turn", stride(from: 0.0, through: 1.0, by: 0.125).map { StatusIcon.image(turn: StatusIcon.turn($0)) }),
            ("bounce", stride(from: 0.0, through: 1.0, by: 0.125).map { StatusIcon.image(lift: StatusIcon.bounce($0)) }),
            ("pulse", stride(from: 0.0, through: 1.2, by: 0.15).map { StatusIcon.image(rifling: StatusIcon.pulse($0)) }),
        ]
        for (name, frames) in strips {
            let size = NSSize(width: CGFloat(frames.count) * 28, height: 28)
            let strip = NSImage(size: size, flipped: false) { _ in
                NSColor(white: 0.17, alpha: 1).setFill()
                NSRect(origin: .zero, size: size).fill()
                for (i, frame) in frames.enumerated() {
                    let white = NSImage(size: frame.size, flipped: false) { rect in
                        frame.draw(in: rect)
                        NSColor.white.set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    white.draw(in: NSRect(x: CGFloat(i) * 28 + 5, y: 5, width: 18, height: 18))
                }
                return true
            }
            var rect = NSRect(origin: .zero, size: size)
            if let cg = strip.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: 2)]) {
                write(cg, to: folder.appendingPathComponent("statusicon-\(name).png"))
            }
        }
    }

    /// The settings tabs and the welcome window, kept behind all other windows while they are drawn.
    static func renderWindows(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Prefs.registerDefaults()
        for tab in [SettingsTab.general, .capture, .island, .shortcuts, .permissions] {
            SettingsWindow.show(tab)
            snapshotFrontWindow(titled: L("Настройки Screenshooter"), to: folder.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        OnboardingWindow.show(askingForFolderAccess: false)
        snapshotFrontWindow(titled: "Screenshooter", to: folder.appendingPathComponent("onboarding.png"))
    }

    private static func snapshotFrontWindow(titled title: String, to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else {
            print("no window \(title)")
            return
        }
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            write(rep.cgImage, to: url)
        }
    }

    /// The editor window with a made-up capture, kept behind all other windows while it is drawn.
    static func renderEditor(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sample = folder.appendingPathComponent("sample.png")
        guard let data = CaptureOutput.encode(fakeScreen(), scale: 2, format: .png) else { return }
        try? data.write(to: sample)
        AnnotationEditor.open(url: sample)
        guard let window = NSApp.windows.first(where: { $0.title.contains("sample") }) else {
            print("no editor window")
            return
        }
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if let frame = window.contentView?.superview,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            write(rep.cgImage, to: folder.appendingPathComponent("editor.png"))
        }
        print("window \(window.windowNumber)")
        RunLoop.main.run(until: Date().addingTimeInterval(4))
    }

    private static func render(_ layer: CALayer, size: CGSize, scale: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.layoutIfNeeded()
        layer.render(in: context)
        return context.makeImage()
    }

    /// Through a real hosting view in a window that is never shown (ImageRenderer skips scroll views).
    private static func renderSwiftUI<V: View>(_ view: V, size: CGSize) -> CGImage? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image, let data = CaptureOutput.encode(image, scale: 2, format: .png) else {
            print("failed: \(url.lastPathComponent)")
            return
        }
        try? data.write(to: url)
        print("wrote \(url.path)")
    }

    /// A desktop with a messenger-like window.
    private static func fakeScreen() -> CGImage {
        let w = 3024, h = 1964
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        // Wallpaper.
        let colors = [CGColor(red: 0.20, green: 0.35, blue: 0.62, alpha: 1), CGColor(red: 0.55, green: 0.30, blue: 0.55, alpha: 1)]
        ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!,
                               start: .zero, end: CGPoint(x: 1512, y: 982), options: [])
        // Window (drawing with y up: screen y = 982 - y).
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x, y: 982 - y - h, width: w, height: h)
        }
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.addPath(CGPath(roundedRect: rect(120, 110, 1260, 760), cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 0.91, alpha: 1))
        ctx.fill(rect(120, 110, 310, 760))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.92, blue: 1, alpha: 1))
        ctx.fill(rect(430, 160, 900, 640))
        for (i, (x, wid, light)) in [(460.0, 360.0, true), (700.0, 420.0, false), (460.0, 300.0, true),
                                     (820.0, 300.0, false)].enumerated() {
            ctx.setFillColor(light ? CGColor(gray: 1, alpha: 1) : CGColor(red: 0.86, green: 0.97, blue: 0.80, alpha: 1))
            let bubble = rect(x, 220 + CGFloat(i) * 88, wid, 64)
            ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
            ctx.fill(CGRect(x: bubble.minX + 16, y: bubble.midY + 4, width: bubble.width - 60, height: 8))
            ctx.fill(CGRect(x: bubble.minX + 16, y: bubble.midY - 14, width: bubble.width * 0.5, height: 8))
        }
        for i in 0..<9 {
            ctx.setFillColor(CGColor(gray: i == 2 ? 0.80 : 0.86, alpha: 1))
            ctx.fill(rect(136, 170 + CGFloat(i) * 72, 278, 60))
        }
        return ctx.makeImage()!
    }

    private static func fakeThumbnail(_ i: Int, width: Int, height: Int) -> CGImage {
        let w = max(1, width / 4), h = max(1, height / 4)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hues: [CGFloat] = [0.58, 0.33, 0.08, 0.75, 0.95]
        let base = NSColor(hue: hues[i % hues.count], saturation: 0.35, brightness: 0.95, alpha: 1).cgColor
        ctx.setFillColor(base)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        for row in 0..<max(1, h / 30) {
            ctx.fill(CGRect(x: 10, y: CGFloat(row * 30 + 10), width: CGFloat(w) * (row % 2 == 0 ? 0.6 : 0.4), height: 14))
        }
        return ctx.makeImage()!
    }
}
