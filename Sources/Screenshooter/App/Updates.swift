import AppKit
import Combine
import ShotCore

extension Updater {
    /// Releases of the app on GitHub.
    static let shared = Updater(repo: "tihomirov-nick/screenshooter")
}

extension Updater.Failure {
    /// One short line for the island and the settings.
    var message: String {
        switch self {
        case .offline: return L("Нет связи с GitHub")
        case .rateLimited: return L("GitHub просит подождать. Попробуйте позже")
        case .noInstaller: return L("У новой версии нет установщика")
        case .download: return L("Загрузка прервалась")
        case .damaged: return L("Скачанный файл повреждён")
        case .notTrusted: return L("Новая версия подписана чужим сертификатом")
        case .cannotReplace: return L("Отсюда приложение не заменить: перетащите его из DMG")
        }
    }
}

extension Updater.Release {
    /// What is new, in short: the first lines of the release notes, without headings and Markdown marks.
    var summary: String {
        notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*-•> ")) }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: "\n")
    }
}

extension Updater.State {
    /// The release the island offers or works on; a failed check alone shows only in the settings.
    var islandRelease: Updater.Release? {
        switch self {
        case .available(let release), .downloading(let release, _), .installing(let release), .failed(_, let release?):
            return release
        default:
            return nil
        }
    }
}

/// What the island's update card asks the updater to do.
enum UpdateCommand {
    case install, later, skip, cancel, page
}

/// Shows what the updater does: the offer in the island (a short notice when a new version turns up), the sound of a
/// failed installation.
@MainActor
enum Updates {
    private static var subscription: AnyCancellable?
    private static var shown: Updater.State = .idle

    static func start() {
        subscription = Updater.shared.$state.receive(on: RunLoop.main).sink { state in
            changed(to: state)
        }
        Updater.shared.start()
    }

    /// The new version is being put in place; the app relaunches in a moment.
    static var isInstalling: Bool {
        if case .installing = Updater.shared.state { return true }
        return false
    }

    /// From the menu: what the check finds shows in the island.
    static func checkNow() {
        Updater.shared.check(userInitiated: true)
    }

    static func perform(_ command: UpdateCommand) {
        let updater = Updater.shared
        switch command {
        case .install: updater.install()
        case .later: updater.dismiss()
        case .skip: updater.skip()
        case .cancel: updater.cancel()
        case .page: updater.openReleasePage()
        }
    }

    private static func changed(to state: Updater.State) {
        let before = shown
        shown = state
        IslandController.shared.model.update = state.islandRelease == nil ? nil : state
        let island = IslandController.shared
        switch state {
        case .available(let release):
            if before.islandRelease == nil {
                island.notify(L("Доступна версия %@", release.version), symbol: "arrow.down.circle.fill")
            }
        case .failed(_, .some):
            SoundEffects.play(.failure)
        // Only a check someone asked for ends like these.
        case .upToDate:
            island.notify(L("Установлена последняя версия"))
        case .failed(let failure, nil):
            island.notify(failure.message, symbol: "exclamationmark.triangle.fill")
        default:
            break
        }
    }
}
