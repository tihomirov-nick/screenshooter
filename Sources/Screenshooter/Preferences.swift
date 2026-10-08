import AppKit
import ShotCore

/// Settings keys. Views bind to them with `@AppStorage`; the rest of the app reads `Prefs`.
enum PrefKey {
    static let saveToFolder = "saveToFolder"
    static let saveFolder = "saveFolder"
    static let copyToClipboard = "copyToClipboard"
    static let soundEffects = "soundEffects"
    /// The shutter sound switch of earlier versions; its value moved to `soundEffects`.
    static let oldShutterSound = "playSound"
    static let imageFormat = "imageFormat"
    static let liveWindowCapture = "liveWindowCapture"
    static let windowShadow = "windowShadow"
    static let detectElements = "detectElements"
    static let detectShapes = "detectShapes"
    static let detectText = "detectText"
    static let boostWebApps = "boostWebApps"
    static let showHints = "showHints"
    static let showMagnifier = "showMagnifier"
    static let islandEnabled = "islandEnabled"
    static let islandOpenOnHover = "islandOpenOnHover"
    static let islandPeek = "islandPeek"
    static let islandScreen = "islandScreen"
    static let shelfLimit = "shelfLimit"
    static let onboardingShown = "onboardingShown"
    static let shortcutSmart = "shortcut.smart"
    static let shortcutFullscreen = "shortcut.fullscreen"
    static let shortcutText = "shortcut.text"
    static let shortcutShelf = "shortcut.shelf"
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var title: String { self == .png ? "PNG" : "JPEG" }
}

enum IslandScreenChoice: String, CaseIterable, Identifiable {
    /// The built-in display with the notch when there is one, otherwise the main display.
    case automatic
    /// The display with the menu bar.
    case main
    var id: String { rawValue }
    var title: String { self == .automatic ? L("С вырезом (если есть)") : L("Основной экран") }
}

enum Prefs {
    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        // "Звук затвора" became "Звуковые эффекты": whoever turned the shutter off starts with all sounds off.
        if defaults.object(forKey: PrefKey.soundEffects) == nil,
           let shutter = defaults.object(forKey: PrefKey.oldShutterSound) as? Bool {
            defaults.set(shutter, forKey: PrefKey.soundEffects)
        }
        defaults.removeObject(forKey: PrefKey.oldShutterSound)

        defaults.register(defaults: [
            PrefKey.saveToFolder: true,
            PrefKey.copyToClipboard: true,
            PrefKey.soundEffects: true,
            PrefKey.imageFormat: ImageFormat.png.rawValue,
            PrefKey.liveWindowCapture: true,
            PrefKey.windowShadow: false,
            PrefKey.detectElements: true,
            PrefKey.detectShapes: true,
            PrefKey.detectText: true,
            PrefKey.boostWebApps: true,
            PrefKey.showHints: true,
            PrefKey.showMagnifier: true,
            PrefKey.islandEnabled: true,
            PrefKey.islandOpenOnHover: true,
            PrefKey.islandPeek: true,
            PrefKey.islandScreen: IslandScreenChoice.automatic.rawValue,
            PrefKey.shelfLimit: 30,
        ])
    }

    static var saveToFolder: Bool { defaults.bool(forKey: PrefKey.saveToFolder) }
    static var copyToClipboard: Bool { defaults.bool(forKey: PrefKey.copyToClipboard) }
    static var soundEffects: Bool { defaults.bool(forKey: PrefKey.soundEffects) }
    static var liveWindowCapture: Bool { defaults.bool(forKey: PrefKey.liveWindowCapture) }
    static var windowShadow: Bool { defaults.bool(forKey: PrefKey.windowShadow) }
    static var detectElements: Bool { defaults.bool(forKey: PrefKey.detectElements) }
    static var detectShapes: Bool { defaults.bool(forKey: PrefKey.detectShapes) }
    static var detectText: Bool { defaults.bool(forKey: PrefKey.detectText) }
    static var boostWebApps: Bool { defaults.bool(forKey: PrefKey.boostWebApps) }
    static var showHints: Bool { defaults.bool(forKey: PrefKey.showHints) }
    static var showMagnifier: Bool { defaults.bool(forKey: PrefKey.showMagnifier) }
    static var islandEnabled: Bool { defaults.bool(forKey: PrefKey.islandEnabled) }
    static var islandOpenOnHover: Bool { defaults.bool(forKey: PrefKey.islandOpenOnHover) }
    static var islandPeek: Bool { defaults.bool(forKey: PrefKey.islandPeek) }
    static var shelfLimit: Int { max(5, defaults.integer(forKey: PrefKey.shelfLimit)) }

    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: defaults.string(forKey: PrefKey.imageFormat) ?? "") ?? .png
    }

    static var islandScreen: IslandScreenChoice {
        IslandScreenChoice(rawValue: defaults.string(forKey: PrefKey.islandScreen) ?? "") ?? .automatic
    }

    /// Where captures are saved: the chosen folder, the Desktop by default.
    static var saveFolder: URL {
        if let path = defaults.string(forKey: PrefKey.saveFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    static func setSaveFolder(_ url: URL?) {
        defaults.set(url?.path, forKey: PrefKey.saveFolder)
    }
}

/// The app's own folder in Application Support.
enum AppFolders {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Screenshooter", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What the shelf keeps itself: captures when saving to a folder is off, dropped text, and dropped files
    /// that would not last where they came from.
    static var shelfFiles: URL {
        let url = support.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
