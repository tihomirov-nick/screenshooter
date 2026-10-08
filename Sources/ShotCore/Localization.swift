import Foundation

/// Interface language. "Automatic" is Russian when Russian is one of the macOS languages, otherwise English.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case russian = "ru"
    case english = "en"

    public var id: String { rawValue }

    /// Language names are written in their own language, so anyone can find theirs.
    public var title: String {
        switch self {
        case .automatic: return L("Автоматически")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }

    /// "ru" or "en".
    public var code: String {
        switch self {
        case .russian: return "ru"
        case .english: return "en"
        case .automatic: return Localization.systemLanguages.contains { $0.hasPrefix("ru") } ? "ru" : "en"
        }
    }
}

/// Strings are written in Russian in the code; English comes from en.lproj/Localizable.strings.
/// Menus and system panels follow through the app's own `AppleLanguages` setting, the same one
/// macOS writes when a language is chosen for the app in System Settings → Language & Region.
public enum Localization {
    private static let key = "ScreenshooterLanguage"
    /// The language last written to `AppleLanguages`, to notice a choice made in System Settings.
    private static let appliedKey = "ScreenshooterAppliedLanguage"

    /// The choice in Settings.
    public static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic
    }

    /// "ru" or "en" for this launch; a new choice applies after a restart.
    public static let current: String = {
        adoptSystemSettingsChoice()
        let code = selected.code
        writeAppleLanguages(code)
        return code
    }()

    /// Languages chosen in macOS (not the override the app keeps for itself).
    static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
    }

    public static func select(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        writeAppleLanguages(language.code)
    }

    /// Call as early as possible at launch so menus and panels use the same language as the app.
    public static func apply() {
        _ = current
    }

    private static func writeAppleLanguages(_ code: String) {
        // Only an app bundle has its own defaults domain; a command line tool would write into the
        // terminal's language settings otherwise.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.set(code, forKey: appliedKey)
    }

    /// System Settings → Language & Region → Applications writes `AppleLanguages` for the app
    /// (or removes it for "System Language"); such a change wins over the earlier choice in the app.
    private static func adoptSystemSettingsChoice() {
        let defaults = UserDefaults.standard
        guard let domain = Bundle.main.bundleIdentifier.flatMap(defaults.persistentDomain(forName:)) else { return }
        let written = (domain["AppleLanguages"] as? [String])?.first
        let applied = domain[appliedKey] as? String
        switch (written, applied) {
        case (nil, nil):
            return
        case (nil, _?):
            defaults.set(AppLanguage.automatic.rawValue, forKey: key)
        case (let written?, let applied):
            guard applied.map({ !written.hasPrefix($0) }) ?? true else { return }
            defaults.set((written.hasPrefix("ru") ? AppLanguage.russian : .english).rawValue, forKey: key)
        }
    }

    /// Number style of the interface language ("1,08 ГБ" in Russian, "1.08 GB" in English).
    public static let numberLocale = Locale(identifier: current == "ru" ? "ru_RU" : "en_US")

    static func string(_ key: String) -> String {
        bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    private static let bundle: Bundle? = {
        guard current != "ru", let path = Bundle.main.path(forResource: current, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()
}

/// Localized string. `key` is the Russian text; `%@` placeholders are filled with `args`.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let text = Localization.string(key)
    return args.isEmpty ? text : String(format: text, arguments: args)
}
