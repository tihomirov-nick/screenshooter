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
    if let i = arguments.firstIndex(of: "--render-island"), i + 1 < arguments.count {
        app.setActivationPolicy(.prohibited)
        // --only pic- : just the states whose names start with it, on a sheet of their own.
        let only = arguments.firstIndex(of: "--only").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        PreviewRenderer.renderIsland(into: URL(fileURLWithPath: arguments[i + 1], isDirectory: true), only: only)
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--render-island-motion"), i + 1 < arguments.count {
        app.setActivationPolicy(.prohibited)
        PreviewRenderer.renderIslandMotion(into: URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--render-status-icon"), i + 1 < arguments.count {
        app.setActivationPolicy(.prohibited)
        PreviewRenderer.renderStatusIcon(into: URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
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
