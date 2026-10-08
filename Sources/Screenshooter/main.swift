import AppKit
import ShotCore

Localization.apply()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let arguments = CommandLine.arguments
    if let i = arguments.firstIndex(of: "--render-previews"), i + 1 < arguments.count {
        app.setActivationPolicy(.prohibited)
        PreviewRenderer.run(into: URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--render-windows"), i + 1 < arguments.count {
        app.setActivationPolicy(.prohibited)
        PreviewRenderer.renderWindows(into: URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--render-editor"), i + 1 < arguments.count {
        app.setActivationPolicy(.prohibited)
        PreviewRenderer.renderEditor(into: URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
