import AppKit
import Combine
import PictureTools
import ShotCore
import SwiftUI

enum SettingsTab: String {
    case general, capture, island, pictures, shortcuts, permissions
}

/// The settings window (one instance).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let selection = SettingsSelection()

    static func show(_ tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(selection: selection))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = L("Настройки Screenshooter")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Shown over a full-screen app too, in the Space the user is in.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.layoutIfNeeded()
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@Observable
final class SettingsSelection {
    var tab: SettingsTab = .general
}

struct SettingsView: View {
    @Bindable var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings()
                .tabItem { Label(L("Основные"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
            CaptureSettings()
                .tabItem { Label(L("Захват"), systemImage: "viewfinder") }
                .tag(SettingsTab.capture)
            IslandSettings()
                .tabItem { Label(L("Островок"), systemImage: "capsule.tophalf.filled") }
                .tag(SettingsTab.island)
            PictureSettings()
                .tabItem { Label(L("Картинки"), systemImage: "photo.on.rectangle.angled") }
                .tag(SettingsTab.pictures)
            ShortcutSettings()
                .tabItem { Label(L("Клавиши"), systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            PermissionSettings()
                .tabItem { Label(L("Разрешения"), systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

/// The tab's groups follow the family standard: the main settings (the interface language, opening at login, the sound
/// effects), the updates, then what is Screenshooter's own, the screenshots.
private struct GeneralSettings: View {
    @AppStorage(PrefKey.saveToFolder) private var saveToFolder = true
    @AppStorage(PrefKey.saveFolder) private var saveFolderPath = ""
    @AppStorage(PrefKey.imageFormat) private var format = ImageFormat.png.rawValue
    @AppStorage(PrefKey.copyToClipboard) private var copyToClipboard = true
    @AppStorage(PrefKey.soundEffects) private var soundEffects = true
    @ObservedObject private var loginItem = Updater.LoginItem.shared
    /// Read again whenever it may have changed: `needsApproval` is not published.
    @State private var needsApproval = false
    /// The interface language is the app's own `AppleLanguages`, the setting System Settings writes too: read again when
    /// the window opens and when the user comes back to the app.
    @State private var language = InterfaceLanguage.saved()
    @State private var languageNeedsRestart = InterfaceLanguage.needsRestart(running: Localization.current)

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { language }, set: { choice in
                    InterfaceLanguage.save(choice)
                    refresh()
                })) {
                    ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text(L("Язык интерфейса"))
                    Text(L("При варианте «Как в системе» Screenshooter берёт первый подходящий язык из списка в Системных настройках, раздел «Язык и регион». Новый язык включится после перезапуска"))
                }
                if languageNeedsRestart {
                    LanguageRestartRow()
                }
                Toggle(L("Запускать при входе"), isOn: Binding(get: { loginItem.isEnabled }, set: { on in
                    loginItem.set(on)
                    needsApproval = loginItem.needsApproval
                }))
                if needsApproval {
                    HStack {
                        Text(L("Выключено в Системных настройках"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Открыть «Объекты входа»")) { loginItem.openSystemSettings() }
                    }
                }
                Toggle(L("Звуковые эффекты"), isOn: $soundEffects)
                    .help(L("Звук играет при снимке, когда текст распознан, когда что-то легло на полку, скопировано или удалено, и при ошибках. Громкость та же, что у звуков предупреждений в Системных настройках, раздел «Звук»; если там выключены звуковые эффекты интерфейса, звуков нет."))
            } header: {
                Text(L("Основные"))
            }

            UpdateSection()

            Section {
                Toggle(L("Сохранять снимки в папку"), isOn: $saveToFolder)
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Prefs.saveFolder.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(folderName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L("Изменить…"), action: chooseFolder)
                    Button(L("Показать")) { NSWorkspace.shared.open(Prefs.saveFolder) }
                }
                .disabled(!saveToFolder)
                Picker(L("Формат"), selection: $format) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle(L("Копировать снимок в буфер обмена"), isOn: $copyToClipboard)
            } header: {
                Text(L("Снимки"))
            } footer: {
                Text(saveToFolder
                     ? L("По умолчанию снимки сохраняются на рабочий стол и появляются на полке у выреза экрана.")
                     : L("Снимки хранятся только на полке; оттуда их можно перетащить, скопировать или сохранить."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        // Back from System Settings, where the login item and the language are set too.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        loginItem.refresh()
        needsApproval = loginItem.needsApproval
        language = InterfaceLanguage.saved()
        languageNeedsRestart = InterfaceLanguage.needsRestart(running: Localization.current)
    }

    private var folderName: String {
        let url = Prefs.saveFolder
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if url.standardizedFileURL == desktop?.standardizedFileURL { return L("Рабочий стол") }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Prefs.saveFolder
        panel.prompt = L("Выбрать")
        if panel.runModal() == .OK, let url = panel.url {
            Prefs.setSaveFolder(url)
            saveFolderPath = url.path
        }
    }
}

extension InterfaceLanguage {
    /// A language is named in its own language, so anyone finds theirs.
    var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}

/// «Язык сменится после перезапуска» with the button that restarts Screenshooter, under the language. Not while the app is
/// busy: a restart would cut a capture off or lose edits (the same test the updater uses before it restarts the app).
private struct LanguageRestartRow: View {
    var body: some View {
        HStack {
            Text(L("Язык сменится после перезапуска"))
                .foregroundStyle(.secondary)
            Spacer()
            // Whether the app is busy is not published: the button looks again every second while the row shows.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let busy = Updater.shared.appIsBusy()
                Button(L("Перезапустить")) { restart() }
                    .disabled(busy)
                    .help(busy ? L("Пока идёт снимок, в редакторе есть несохранённые правки или что-то переносится на полку, Screenshooter не перезапускается") : "")
            }
        }
    }

    private func restart() {
        guard !Updater.shared.appIsBusy() else { return }
        InterfaceLanguage.relaunch()
    }
}

/// The version, automatic checks and installation, a check on request; the island offers what is not installed by itself.
private struct UpdateSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 })) {
                Text(L("Проверять обновления"))
                Text(L("Screenshooter смотрит, нет ли новой версии, при запуске, раз в три часа и после пробуждения Mac"))
            }
            Toggle(isOn: Binding(get: { updater.automaticInstall }, set: { updater.automaticInstall = $0 })) {
                Text(L("Обновлять автоматически"))
                Text(L("Новая версия ставится сама, когда Screenshooter ничем не занят. Если выключить, она появится в островке с кнопкой «Обновить»."))
            }
            .disabled(!updater.automaticChecks)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Версия %@", updater.currentVersion))
                    if let status {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                action
                Button(L("Проверить сейчас")) { updater.check(userInitiated: true) }
                    .disabled(busy)
            }
        } header: {
            Text(L("Обновления"))
        } footer: {
            if updater.isDevelopmentBuild {
                Text(L("Эта копия собрана из исходников и сама не обновляется."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var busy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var status: String? {
        switch updater.state {
        case .idle:
            guard let update = updater.automaticUpdate else { return nil }
            return update.ready ? L("Версия %@ установится, когда Screenshooter освободится", update.release.version)
                                : L("Скачивается версия %@", update.release.version)
        case .checking: return L("Проверка…")
        case .upToDate: return L("Установлена последняя версия")
        case .available(let release): return L("Доступна версия %@", release.version)
        case .downloading(let release, let progress):
            return L("Загрузка версии %@: %@ %%", release.version, "\(Int((progress * 100).rounded()))")
        case .installing(let release): return L("Установка версии %@", release.version)
        case .failed(let failure, _): return failure.message
        }
    }

    @ViewBuilder
    private var action: some View {
        switch updater.state {
        case .available:
            Button(L("Обновить")) { updater.install() }
        case .downloading:
            Button(L("Отмена")) { updater.cancel() }
        case .failed(let failure, let release) where release != nil || failure == .noInstaller:
            Button(failure == .cannotReplace ? L("Открыть установщик") : L("Страница загрузки")) { updater.openReleasePage() }
        default:
            EmptyView()
        }
    }
}

// MARK: - Capture

private struct CaptureSettings: View {
    @AppStorage(PrefKey.detectElements) private var detectElements = true
    @AppStorage(PrefKey.boostWebApps) private var boostWebApps = true
    @AppStorage(PrefKey.detectShapes) private var detectShapes = true
    @AppStorage(PrefKey.detectText) private var detectText = true
    @AppStorage(PrefKey.liveWindowCapture) private var liveWindowCapture = true
    @AppStorage(PrefKey.windowShadow) private var windowShadow = false
    @AppStorage(PrefKey.showHints) private var showHints = true
    @AppStorage(PrefKey.showMagnifier) private var showMagnifier = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $detectElements) {
                    Text(L("Элементы интерфейса"))
                    Text(L("Кнопки, сообщения, списки, панели — через Универсальный доступ."))
                }
                Toggle(isOn: $boostWebApps) {
                    Text(L("Элементы веб-страниц в браузерах и Electron-приложениях"))
                    Text(L("Chrome, Яндекс Браузер, Arc, Slack, Discord, VS Code и другие. Включается на время снимка."))
                }
                .disabled(!detectElements)
                Toggle(isOn: $detectShapes) {
                    Text(L("Блоки на изображении"))
                    Text(L("Пузыри сообщений, карточки, панели — там, где приложение не сообщает о своих элементах."))
                }
                Toggle(isOn: $detectText) {
                    Text(L("Абзацы текста"))
                    Text(L("Распознаются по изображению, например в PDF и на картинках."))
                }
            } header: {
                Text(L("Что подсвечивать при наведении"))
            }

            Section {
                Toggle(isOn: $liveWindowCapture) {
                    Text(L("Окно целиком — без перекрывающих окон"))
                    Text(L("Окно снимается само по себе, с прозрачными скруглёнными углами."))
                }
                Toggle(L("Тень у окна"), isOn: $windowShadow)
                    .disabled(!liveWindowCapture)
            }

            Section {
                Toggle(L("Подсказки внизу экрана"), isOn: $showHints)
                Toggle(L("Лупа при ручном выделении"), isOn: $showMagnifier)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Island

private struct IslandSettings: View {
    @AppStorage(PrefKey.islandEnabled) private var enabled = true
    @AppStorage(PrefKey.islandOpenOnHover) private var openOnHover = true
    @AppStorage(PrefKey.islandPeek) private var peek = true
    @AppStorage(PrefKey.islandScreen) private var screen = IslandScreenChoice.automatic.rawValue
    @AppStorage(PrefKey.shelfLimit) private var limit = 30

    var body: some View {
        Form {
            Section {
                Toggle(L("Полка снимков у выреза экрана"), isOn: $enabled)
                Group {
                    Toggle(L("Открывать при наведении на вырез"), isOn: $openOnHover)
                    Toggle(L("Показывать каждый новый снимок"), isOn: $peek)
                    Picker(L("Экран"), selection: $screen) {
                        ForEach(IslandScreenChoice.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Stepper(value: $limit, in: 5...100, step: 5) {
                        Text(L("Хранить на полке: %@", "\(limit)"))
                    }
                }
                .disabled(!enabled)
            } footer: {
                Text(L("Наведите указатель на вырез вверху экрана, чтобы открыть полку. Снимки можно перетаскивать в любые приложения, копировать и открывать в редакторе; файлы и текст можно класть на полку, перетащив их на вырез."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(L("Очистить полку")) {
                    Shelf.shared.clear()
                    SoundEffects.play(.removed)
                }
            } footer: {
                Text(L("Файлы на диске останутся."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Pictures

private struct PictureSettings: View {
    @AppStorage(PrefKey.moodboardBackground) private var background = Moodboard.Background.dark.rawValue
    @AppStorage(PrefKey.moodboardWidth) private var width = 2400
    @AppStorage(PrefKey.moodboardSpacing) private var spacing = 24

    var body: some View {
        Form {
            Section {
                Picker(L("Фон"), selection: $background) {
                    Text(L("Тёмный")).tag(Moodboard.Background.dark.rawValue)
                    Text(L("Светлый")).tag(Moodboard.Background.light.rawValue)
                }
                .pickerStyle(.segmented)
                Picker(L("Ширина коллажа"), selection: $width) {
                    ForEach([1600, 2400, 3200, 4800], id: \.self) { Text(L("%@ пикс.", "\($0)")).tag($0) }
                }
                Picker(L("Отступы"), selection: $spacing) {
                    ForEach([0, 8, 16, 24, 32, 48], id: \.self) { Text(L("%@ пикс.", "\($0)")).tag($0) }
                }
            } header: {
                Text(L("Мудборд из папки"))
            } footer: {
                Text(L("Перетащите папку на вырез и отпустите над «В мудборд» или выберите папку в меню Screenshooter. До 100 картинок встанут ровной сеткой с одинаковыми отступами, готовый коллаж ляжет на полку и в буфер обмена."))
                    .foregroundStyle(.secondary)
            }
            Section {
                KeyRow(keys: L("⌘-клик"), action: L("добавить карточку к выбранным или убрать"))
                KeyRow(keys: L("⇧-клик"), action: L("выбрать карточки подряд"))
                KeyRow(keys: "⌘A", action: L("выбрать все картинки"))
                KeyRow(keys: "⌘C", action: L("скопировать выбранные разом"))
            } header: {
                Text(L("Несколько картинок на полке"))
            } footer: {
                Text(L("Каждая картинка ляжет в буфер отдельно, с файлом, поэтому Figma, Pages, Keynote и мессенджеры вставят их все. Перетаскивание тоже несёт все выбранные."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Text(L("Фон убирается у картинки на полке (кнопка на карточке) или у картинки в буфере обмена (меню Screenshooter). Там же распознаётся текст. Всё работает на этом Mac, без сети."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent(L("Умный снимок")) {
                    ShortcutRecorder(key: PrefKey.shortcutSmart, defaultValue: .smartDefault)
                }
                LabeledContent(L("Весь экран")) {
                    ShortcutRecorder(key: PrefKey.shortcutFullscreen, defaultValue: .fullscreenDefault)
                }
                LabeledContent(L("Распознать текст")) {
                    ShortcutRecorder(key: PrefKey.shortcutText, defaultValue: nil)
                }
                LabeledContent(L("Открыть полку")) {
                    ShortcutRecorder(key: PrefKey.shortcutShelf, defaultValue: nil)
                }
            } footer: {
                Text(L("Чтобы назначить ⇧⌘3, ⇧⌘4 или ⇧⌘5, сначала отключите их в Системных настройках: раздел «Клавиатура», кнопка «Сочетания клавиш…», пункт «Снимки экрана»."))
                    .foregroundStyle(.secondary)
            }

            Section {
                KeyRow(keys: L("Клик"), action: L("снимок подсвеченной области"))
                KeyRow(keys: L("Перетаскивание"), action: L("своя область (⇧ — квадрат)"))
                KeyRow(keys: L("↑ ↓ или колесо"), action: L("область крупнее или мельче"))
                KeyRow(keys: L("Пробел"), action: L("окно целиком"))
                KeyRow(keys: "F", action: L("весь экран"))
                KeyRow(keys: "Esc", action: L("отмена"))
            } header: {
                Text(L("Во время снимка"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            Text(action).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @State private var screen = Permissions.screenRecording
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRows(place: .settings)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("«Разрешить…» добавляет Screenshooter в список Системных настроек. Останется включить переключатель. Когда запись экрана включена, приложение само перезапустится, чтобы она заработала."))
                        .foregroundStyle(.secondary)
                    // The app relaunches by itself; the button is there if it could not.
                    if screen && !Permissions.screenRecordingAtLaunch {
                        Button(L("Перезапустить")) { Permissions.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in screen = Permissions.screenRecording }
    }
}

/// Live status of both permissions with buttons to grant them; shared with the welcome window.
struct PermissionRows: View {
    /// Where the rows are: after a relaunch for screen recording the app opens that window again.
    let place: Permissions.Place
    @State private var screen = Permissions.screenRecording
    @State private var accessibility = Permissions.accessibility
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            PermissionRow(granted: screen, symbol: "rectangle.dashed.badge.record",
                          title: L("Запись экрана"),
                          detail: L("Нужна, чтобы делать снимки."),
                          action: { Permissions.request(.screenRecording, from: place) })
            PermissionRow(granted: accessibility, symbol: "accessibility",
                          title: L("Универсальный доступ"),
                          detail: L("Нужен, чтобы узнавать кнопки, сообщения и элементы страниц под указателем."),
                          action: { Permissions.request(.accessibility, from: place) })
        }
        .onReceive(timer) { _ in
            screen = Permissions.screenRecording
            accessibility = Permissions.accessibility
        }
    }
}

private struct PermissionRow: View {
    let granted: Bool
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label(L("Разрешено"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.system(size: 12, weight: .medium))
            } else {
                Button(L("Разрешить…"), action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
