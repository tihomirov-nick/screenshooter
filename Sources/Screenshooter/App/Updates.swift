import AnnotationEditor
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
        case .offline: return L("Нет связи с сервером обновлений")
        case .rateLimited: return L("Сервер просит подождать. Попробуйте позже")
        case .noInstaller: return L("У новой версии нет установщика")
        case .download: return L("Загрузка прервалась")
        case .damaged: return L("Скачанный файл повреждён")
        case .notTrusted: return L("Новая версия подписана чужим сертификатом")
        case .cannotReplace: return L("Отсюда приложение не заменить. Перетащите Screenshooter в папку «Программы»")
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

/// Shows what the updater does: a new version offered in the island (a banner with its buttons, the row over the cards),
/// a word before the app restarts as the new version, the sound of a failed installation.
@MainActor
enum Updates {
    private static var subscriptions: Set<AnyCancellable> = []
    private static var shown: Updater.State = .idle
    /// When the island said that the app is restarting as the new version.
    private static var restartShownAt: Date?
    /// How long it says so before the app quits.
    private static let restartNotice: TimeInterval = 1.5

    static func start() {
        let updater = Updater.shared
        // An update that installs itself restarts the app when nothing is lost: no capture on screen or being saved, no
        // unsaved changes in the editor, nothing on its way onto the shelf or off it. An island merely open is no reason
        // to wait.
        updater.appIsBusy = {
            CaptureController.shared.isBusy || AnnotationEditor.hasUnsavedChanges || IslandController.shared.isMovingItems
        }
        updater.$state.receive(on: RunLoop.main).sink { state in
            changed(to: state)
        }.store(in: &subscriptions)
        updater.$freshOffer.receive(on: RunLoop.main).sink { release in
            guard let release else { return }
            updater.offerShown()
            offer(release)
        }.store(in: &subscriptions)
        // Posted right before the quit, which follows at once: the island has to hear of it now.
        NotificationCenter.default.addObserver(forName: Updater.willRestart, object: updater, queue: nil) { note in
            let version = (note.userInfo?["release"] as? Updater.Release)?.version
            MainActor.assumeIsolated { restarting(to: version) }
        }
        updater.start()
    }

    /// The new version is being put in place; the app relaunches in a moment.
    static var isInstalling: Bool {
        if case .installing = Updater.shared.state { return true }
        return false
    }

    /// For the quit that restarts the app as the new version: what is left of the moment the island needs to say so.
    static var restartPause: TimeInterval {
        guard isInstalling, let shownAt = restartShownAt else { return 0 }
        return max(0, restartNotice - Date().timeIntervalSince(shownAt))
    }

    /// From the menu: what the check finds shows in the island.
    static func checkNow() {
        Updater.shared.check(userInitiated: true)
    }

    static func perform(_ command: UpdateCommand) {
        let updater = Updater.shared
        let island = IslandController.shared
        // From the banner: "Обновить" opens the shelf, whose row follows the download; "Позже" puts the banner away.
        let fromBanner = island.model.state == .banner
        switch command {
        case .install:
            updater.install()
            if fromBanner { island.open() }
        case .later:
            updater.dismiss()
            if fromBanner { island.close() }
        case .skip: updater.skip()
        case .cancel: updater.cancel()
        case .page: updater.openReleasePage()
        }
    }

    private static func changed(to state: Updater.State) {
        let before = shown
        shown = state
        let island = IslandController.shared
        island.model.update = state.islandRelease == nil ? nil : state
        switch state {
        case .available(let release):
            // What a check the user asked for found; an automatic check offers through `freshOffer`.
            if before == .checking { offer(release) }
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
        if case .available = state {} else { island.withdrawOffer() }
    }

    /// A new version under the notch, with "Позже" and "Обновить". Never over a capture: it comes once the capture is
    /// saved and its thumbnail has left the notch. The open shelf already has it in its row.
    private static func offer(_ release: Updater.Release) {
        let capture = CaptureController.shared, island = IslandController.shared
        if capture.isBusy || island.model.state == .peek {
            capture.whenIdle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { offer(release) }
            }
            return
        }
        guard case .available(let offered) = Updater.shared.state, offered == release else { return }
        island.offer(L("Доступна версия %@", release.version), symbol: "arrow.down.circle.fill", actions: [
            IslandUpdate.Action(title: L("Позже"), command: .later, kind: .secondary),
            IslandUpdate.Action(title: L("Обновить"), command: .install, kind: .primary),
        ])
    }

    /// The app quits in a moment and comes back as the new version: a banner under the notch says so (the open shelf's
    /// row says it already), and the quit waits for it a little (see `restartPause`).
    private static func restarting(to version: String?) {
        guard let version else { return }
        let island = IslandController.shared
        guard island.isRunning else { return }
        island.model.update = Updater.shared.state
        if island.model.state != .open {
            island.notify(L("Обновляюсь до версии %@…", version), symbol: "arrow.down.circle.fill")
        }
        restartShownAt = Date()
    }
}
