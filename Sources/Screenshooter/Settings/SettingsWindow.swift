import AppKit
import Combine
import ServiceManagement
import ShotCore
import SwiftUI

enum SettingsTab: String {
    case general, capture, island, shortcuts, permissions
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

private struct GeneralSettings: View {
    @AppStorage(PrefKey.saveToFolder) private var saveToFolder = true
    @AppStorage(PrefKey.saveFolder) private var saveFolderPath = ""
    @AppStorage(PrefKey.imageFormat) private var format = ImageFormat.png.rawValue
    @AppStorage(PrefKey.copyToClipboard) private var copyToClipboard = true
    @AppStorage(PrefKey.playSound) private var playSound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = Localization.selected

    var body: some View {
        Form {
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
            } footer: {
                Text(saveToFolder
                     ? L("По умолчанию снимки сохраняются на рабочий стол и появляются на полке у выреза экрана.")
                     : L("Снимки хранятся только на полке; оттуда их можно перетащить, скопировать или сохранить."))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("Копировать снимок в буфер обмена"), isOn: $copyToClipboard)
                Toggle(L("Звук затвора"), isOn: $playSound)
            }

            Section {
                Toggle(L("Запускать при входе в систему"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Picker(L("Язык"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, value in Localization.select(value) }
            } footer: {
                if language.code != Localization.current {
                    HStack {
                        Text(L("Язык сменится после перезапуска."))
                            .foregroundStyle(.secondary)
                        Button(L("Перезапустить")) { Permissions.relaunch() }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
                Text(L("Наведите указатель на вырез вверху экрана, чтобы открыть полку. Снимки можно перетаскивать в любые приложения, копировать и открывать в редакторе; картинки можно класть на полку, перетащив их на вырез."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(L("Очистить полку")) { Shelf.shared.clear() }
            } footer: {
                Text(L("Файлы на диске останутся."))
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
                Text(L("Чтобы назначить ⇧⌘3, ⇧⌘4 или ⇧⌘5, сначала отключите их в Системных настройках → Клавиатура → Сочетания клавиш → Снимки экрана."))
                    .foregroundStyle(.secondary)
            }

            Section {
                KeyRow(keys: L("Клик"), action: L("снять подсвеченную область"))
                KeyRow(keys: L("Перетаскивание"), action: L("выделить область вручную (⇧ — квадрат)"))
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
    var body: some View {
        Form {
            Section {
                PermissionRows()
            } footer: {
                Text(L("После выдачи разрешения на запись экрана macOS может попросить перезапустить приложение."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Live status of both permissions with buttons to grant them; shared with the welcome window.
struct PermissionRows: View {
    @State private var screen = Permissions.screenRecording
    @State private var accessibility = Permissions.accessibility
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            PermissionRow(granted: screen, symbol: "rectangle.dashed.badge.record",
                          title: L("Запись экрана"),
                          detail: L("Нужна, чтобы делать снимки."),
                          action: Permissions.requestScreenRecording)
            PermissionRow(granted: accessibility, symbol: "accessibility",
                          title: L("Универсальный доступ"),
                          detail: L("Нужен, чтобы узнавать кнопки, сообщения и элементы страниц под указателем."),
                          action: Permissions.requestAccessibility)
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
