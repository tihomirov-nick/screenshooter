@testable import ShotCore
import XCTest

/// The interface language: "Automatic" against the order of the macOS languages, and what a launch reads and writes.
/// The launches run on defaults of their own, never on the app's domain com.screenshooter.app: a suite named by an
/// absolute path keeps its file there, in a temporary folder, and nothing lands in ~/Library/Preferences.
final class LanguageTests: XCTestCase {
    private var folder: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShotCoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = folder.appendingPathComponent("defaults").path
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - Automatic

    func testAutomaticTakesTheFirstMacOSLanguageTheAppSpeaks() {
        let cases: [([String], String)] = [
            (["en-US", "ru-US"], "en"),
            (["ru-RU", "en-US"], "ru"),
            (["de-DE", "ru-RU"], "ru"),
            (["de-DE"], "en"),
            (["uk-UA", "ru-RU", "en"], "ru"),
        ]
        for (languages, expected) in cases {
            XCTAssertEqual(AppLanguage.automatic.code(systemLanguages: languages), expected, "\(languages)")
        }
    }

    func testAChosenLanguageIgnoresMacOS() {
        XCTAssertEqual(AppLanguage.russian.code(systemLanguages: ["en-US", "ru-US"]), "ru")
        XCTAssertEqual(AppLanguage.english.code(systemLanguages: ["ru-RU", "en-US"]), "en")
    }

    // MARK: - Launch

    private func launch(_ languages: [String]) -> String {
        Localization.launch(defaults: defaults, domain: suite, systemLanguages: languages)
    }

    private func stored(_ key: String) -> Any? { defaults.persistentDomain(forName: suite)?[key] }

    /// The old rule wrote Russian for "en-US, ru-US" because Russian was in the list: the next launch follows macOS,
    /// menus and system panels included, and the choice stays "Automatic".
    func testAutomaticPutsRightWhatAnEarlierLaunchWrote() {
        defaults.set(["ru"], forKey: "AppleLanguages")
        defaults.set("ru", forKey: "ScreenshooterAppliedLanguage")
        XCTAssertEqual(launch(["en-US", "ru-US"]), "en")
        XCTAssertEqual(stored("AppleLanguages") as? [String], ["en"])
        XCTAssertEqual(stored("ScreenshooterAppliedLanguage") as? String, "en")
        XCTAssertNil(stored("ScreenshooterLanguage"))
    }

    func testFirstLaunchFollowsMacOS() {
        XCTAssertEqual(launch(["ru-RU", "en-US"]), "ru")
        XCTAssertEqual(stored("AppleLanguages") as? [String], ["ru"])
    }

    /// Russian chosen for the app in System Settings → Language & Region stays, launch after launch.
    func testLanguageChosenInSystemSettingsStays() {
        defaults.set(["ru"], forKey: "AppleLanguages")
        defaults.set("en", forKey: "ScreenshooterAppliedLanguage")
        XCTAssertEqual(launch(["en-US", "ru-US"]), "ru")
        XCTAssertEqual(stored("ScreenshooterLanguage") as? String, "ru")
        XCTAssertEqual(launch(["en-US", "ru-US"]), "ru")
        XCTAssertEqual(stored("AppleLanguages") as? [String], ["ru"])
    }

    /// "System Language" for the app in System Settings removes the override: back to "Automatic".
    func testSystemLanguageInSystemSettingsMeansAutomatic() {
        defaults.set("ru", forKey: "ScreenshooterLanguage")
        defaults.set("ru", forKey: "ScreenshooterAppliedLanguage")
        XCTAssertEqual(launch(["en-US", "ru-US"]), "en")
        XCTAssertEqual(stored("ScreenshooterLanguage") as? String, AppLanguage.automatic.rawValue)
    }

    /// A language chosen in the app's settings works as before, whatever macOS says.
    func testLanguageChosenInTheAppStays() {
        defaults.set("ru", forKey: "ScreenshooterLanguage")
        XCTAssertEqual(launch(["en-US", "ru-US"]), "ru")
        XCTAssertEqual(launch(["en-US", "ru-US"]), "ru")
        defaults.set("en", forKey: "ScreenshooterLanguage")
        XCTAssertEqual(launch(["ru-RU", "en-US"]), "en")
        XCTAssertEqual(stored("AppleLanguages") as? [String], ["en"])
    }
}
