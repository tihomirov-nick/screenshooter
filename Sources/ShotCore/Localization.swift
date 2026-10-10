import Foundation

/// Interface language. "Automatic" is the first macOS language the app speaks, in the order of System Settings (as macOS
/// picks the language of any app): Russian for "ru-RU, en-US" and for "de-DE, ru-RU", English for "en-US, ru-RU", and
/// English when the app speaks none of them.
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
    public var code: String { code(systemLanguages: Localization.systemLanguages) }

    /// "ru" or "en" with these macOS languages, first choice first.
    func code(systemLanguages: [String]) -> String {
        switch self {
        case .russian: return "ru"
        case .english: return "en"
        case .automatic: return Bundle.preferredLocalizations(from: ["ru", "en"], forPreferences: systemLanguages).first ?? "en"
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
    public static var selected: AppLanguage { selected(in: .standard) }

    static func selected(in defaults: UserDefaults) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: key) ?? "") ?? .automatic
    }

    /// "ru" or "en" for this launch; a new choice applies after a restart.
    public static let current: String = {
        // Only an app bundle has its own defaults domain; a command line tool would write into the terminal's language
        // settings otherwise.
        guard let domain = Bundle.main.bundleIdentifier else { return selected.code }
        return launch(defaults: .standard, domain: domain, systemLanguages: systemLanguages)
    }()

    /// The language of a launch, from the app's defaults (`domain` is their persistent domain) and the macOS languages.
    /// A language chosen for the app in System Settings is taken over first. Then the app's own `AppleLanguages` is
    /// written, so that menus and system panels speak the same language; with "Automatic" this also puts right what an
    /// earlier launch wrote there for another order of the macOS languages, or by the old rule that took Russian from
    /// anywhere in the list.
    static func launch(defaults: UserDefaults, domain: String, systemLanguages: [String]) -> String {
        adoptSystemSettingsChoice(defaults: defaults, domain: domain)
        let code = selected(in: defaults).code(systemLanguages: systemLanguages)
        writeAppleLanguages(code, defaults: defaults)
        return code
    }

    /// Languages chosen in macOS, first choice first: the user's, or else those the Mac was set up with. Never the
    /// override the app keeps for itself, which `Locale.preferredLanguages` would give, so that is the last resort.
    static var systemLanguages: [String] {
        if let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
            as? [String], !languages.isEmpty {
            return languages
        }
        if let languages = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                                  kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? [String],
           !languages.isEmpty {
            return languages
        }
        return Locale.preferredLanguages
    }

    public static func select(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        guard Bundle.main.bundleIdentifier != nil else { return }
        writeAppleLanguages(language.code, defaults: .standard)
    }

    /// Call as early as possible at launch so menus and panels use the same language as the app.
    public static func apply() {
        _ = current
    }

    private static func writeAppleLanguages(_ code: String, defaults: UserDefaults) {
        defaults.set([code], forKey: "AppleLanguages")
        defaults.set(code, forKey: appliedKey)
    }

    /// System Settings → Language & Region → Applications writes `AppleLanguages` for the app
    /// (or removes it for "System Language"); such a change wins over the earlier choice in the app.
    /// What the app wrote there itself (the same as `appliedKey`) is no choice and changes nothing.
    private static func adoptSystemSettingsChoice(defaults: UserDefaults, domain: String) {
        guard let values = defaults.persistentDomain(forName: domain) else { return }
        let written = (values["AppleLanguages"] as? [String])?.first
        let applied = values[appliedKey] as? String
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
