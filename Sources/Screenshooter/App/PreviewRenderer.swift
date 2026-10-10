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

        // The island in every state and its motion, in folders of their own.
        renderIsland(into: folder.appendingPathComponent("island", isDirectory: true))
        renderIslandMotion(into: folder.appendingPathComponent("island-motion", isDirectory: true))
        renderStatusIcon(into: folder)
    }

    /// `Screenshooter --render-status-icon DIR` draws the menu bar icon on one small sheet, in pixels: as a Retina screen
    /// and as a plain one show it, on a dark and a light menu bar (to the right), and magnified pixel by pixel with its
    /// canvas outlined (to the left), to see the margins and that the lines sit on whole pixels. Nothing is shown on
    /// screen.
    static func renderStatusIcon(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let canvas = StatusIcon.canvas, icon = StatusIcon.image()
        let dark = CGColor(gray: 0.17, alpha: 1), light = CGColor(gray: 0.93, alpha: 1)

        /// The icon as the pixels of a screen of `scale` pixels to the point, in `color` (a template image takes the
        /// colour of the menu bar it stands on).
        func pixels(_ scale: Int, _ color: NSColor) -> CGImage? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width) * scale,
                                             pixelsHigh: Int(canvas.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            // Points per pixel first: the context takes its scale from the representation.
            rep.size = canvas
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            let saved = NSGraphicsContext.current
            NSGraphicsContext.current = context
            let rect = NSRect(origin: .zero, size: canvas)
            icon.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            NSGraphicsContext.current = saved
            return rep.cgImage
        }

        // Magnified 12 times per point: 6 times a Retina pixel, 12 times a plain one.
        let pad: CGFloat = 16, pane = canvas.width * 12
        let bars = canvas.width * 2 + 2 * pad
        let width = Int(pad + pane + pad + pane + pad + bars + pad), height = Int(pad + pane + pad)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        /// A dark pane with the white icon magnified, its canvas outlined.
        func magnified(_ scale: Int, at x: CGFloat) {
            let rect = CGRect(x: x, y: pad, width: pane, height: pane)
            ctx.setFillColor(dark)
            ctx.fill(rect)
            if let image = pixels(scale, .white) { ctx.draw(image, in: rect) }
            ctx.setStrokeColor(CGColor(red: 1, green: 0.35, blue: 0.35, alpha: 1))
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
        magnified(2, at: pad)
        magnified(1, at: pad + pane + pad)

        /// A menu bar of `scale` pixels to the point (24 pt high) with the icon in it, a margin from the left.
        func bar(_ scale: Int, _ color: CGColor, ink: NSColor, at y: CGFloat) {
            let barWidth = canvas.width * CGFloat(scale) + 2 * pad
            let x = pad + pane + pad + pane + pad
            let rect = CGRect(x: x, y: y, width: barWidth, height: 24 * CGFloat(scale))
            ctx.setFillColor(color)
            ctx.fill(rect)
            guard let image = pixels(scale, ink) else { return }
            let size = CGSize(width: canvas.width * CGFloat(scale), height: canvas.height * CGFloat(scale))
            ctx.draw(image, in: CGRect(x: x + pad, y: y + (rect.height - size.height) / 2, width: size.width, height: size.height))
        }
        let top = pad + pane - 48
        bar(2, dark, ink: .white, at: top)
        bar(2, light, ink: .black, at: top - 48 - 12)
        bar(1, dark, ink: .white, at: top - 2 * (48 + 12))
        bar(1, light, ink: .black, at: top - 2 * (48 + 12) - 24 - 12)
        write(ctx.makeImage(), to: folder.appendingPathComponent("statusicon.png"))
    }

    /// The settings tabs and the welcome window, kept behind all other windows while they are drawn.
    static func renderWindows(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Prefs.registerDefaults()
        for tab in [SettingsTab.general, .capture, .island, .pictures, .shortcuts, .permissions] {
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
    static func renderSwiftUI<V: View>(_ view: V, size: CGSize) -> CGImage? {
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

    static func write(_ image: CGImage?, to url: URL) {
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
}
