import AnnotationEditor
import AppKit
import ShotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var shortcutItems: [String: NSMenuItem] = [:]
    private var islandRunning = false
    private var settingsWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let returning = Permissions.launched()
        Prefs.registerDefaults()
        MainMenu.install()
        WindowActivation.start()
        setUpStatusItem()

        IslandController.shared.actions = makeIslandActions()
        applySettings()
        registerShortcuts()
        ScreenCapturer.shared.warmUp()
        Updates.start()

        let center = NotificationCenter.default
        center.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerShortcuts() }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenCapturer.shared.warmUp() }
        }

        // Back from a relaunch made for screen recording: the window the permission was asked from, open again.
        if returning == .settings {
            SettingsWindow.show(.permissions)
        } else if returning == .onboarding || !Permissions.screenRecording
                    || !UserDefaults.standard.bool(forKey: PrefKey.onboardingShown) {
            OnboardingWindow.show()
        }
    }

    /// An editor with unsaved changes asks first. A capture in progress (an update relaunching the app, say) is
    /// finished and saved before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AnnotationEditor.reviewUnsavedChanges() else { return .terminateCancel }
        guard CaptureController.shared.isBusy else { return .terminateNow }
        CaptureController.shared.whenIdle { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Opening the app again (from Finder or Spotlight) while it runs shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindow.show() }
        return true
    }

    /// screenshooter://capture, //text, //fullscreen, //shelf, //settings — for Shortcuts, Raycast, Alfred…
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "screenshooter" {
            switch url.host?.lowercased() {
            case "capture", "smart": CaptureController.shared.startSmart()
            case "text": CaptureController.shared.startSmart(mode: .text)
            case "fullscreen": CaptureController.shared.captureFullScreen()
            case "shelf": IslandController.shared.toggle()
            case "settings": SettingsWindow.show()
            case "diagnostics": writeDiagnostics()
            default: break
            }
        }
    }

    /// screenshooter://diagnostics writes what the app sees into Application Support/diagnostics.txt.
    private func writeDiagnostics() {
        var lines = [
            "version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")",
            "screen recording: \(Permissions.screenRecording)",
            "accessibility: \(Permissions.accessibility)",
            "island: \(Prefs.islandEnabled) state \(IslandController.shared.model.state) metrics \(IslandController.shared.model.metrics)",
            "save folder: \(Prefs.saveToFolder ? Prefs.saveFolder.path : "shelf only")",
            "shelf items: \(Shelf.shared.items.count)",
        ]
        for screen in NSScreen.screens {
            lines.append("screen \(screen.displayID): frame \(screen.frame) scale \(screen.backingScaleFactor) "
                + "notch \(screen.notchFrame.map { "\($0)" } ?? "none") menu bar \(screen.menuBarHeight)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: AppFolders.support.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Settings

    private func settingsChanged() {
        settingsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applySettings() }
        settingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func applySettings() {
        if Prefs.islandEnabled != islandRunning {
            islandRunning = Prefs.islandEnabled
            if islandRunning { IslandController.shared.start() } else { IslandController.shared.stop() }
        }
        IslandController.shared.layout()
    }

    private func registerShortcuts() {
        let hotKeys = HotKeyCenter.shared
        hotKeys.unregisterAll()
        func add(_ key: String, _ fallback: Shortcut?, _ action: @escaping () -> Void) {
            let shortcut = Shortcut.load(key, default: fallback)
            if let shortcut { hotKeys.register(shortcut, action: action) }
            if let item = shortcutItems[key] { Self.show(shortcut, on: item) }
        }
        add(PrefKey.shortcutSmart, .smartDefault) { CaptureController.shared.startSmart() }
        add(PrefKey.shortcutFullscreen, .fullscreenDefault) { CaptureController.shared.captureFullScreen() }
        add(PrefKey.shortcutText, nil) { CaptureController.shared.startSmart(mode: .text) }
        add(PrefKey.shortcutShelf, nil) { IslandController.shared.toggle() }
    }

    // MARK: - Menu bar icon

    private func setUpStatusItem() {
        // A square item, like FaceID's: the two icons stand level and as far apart as the others.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button { StatusIcon.shared.attach(to: button) }
        item.button?.toolTip = "Screenshooter"

        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector, shortcutKey: String? = nil) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menu.addItem(menuItem)
            if let shortcutKey { shortcutItems[shortcutKey] = menuItem }
        }
        add(L("Умный снимок"), #selector(smartCapture), shortcutKey: PrefKey.shortcutSmart)
        add(L("Весь экран"), #selector(fullscreenCapture), shortcutKey: PrefKey.shortcutFullscreen)
        add(L("Распознать текст"), #selector(textCapture), shortcutKey: PrefKey.shortcutText)
        menu.addItem(.separator())
        add(L("Показать полку"), #selector(toggleShelf), shortcutKey: PrefKey.shortcutShelf)
        add(L("Открыть папку снимков"), #selector(openFolder))
        menu.addItem(.separator())
        add(L("Настройки…"), #selector(showSettings))
        add(L("О программе Screenshooter"), #selector(showAbout))
        add(L("Проверить обновления…"), #selector(checkForUpdates))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    /// Shows a global shortcut next to a menu item (only as a reminder; the menu does not handle it).
    private static func show(_ shortcut: Shortcut?, on item: NSMenuItem) {
        guard let shortcut else {
            item.keyEquivalent = ""
            return
        }
        let name = Shortcut.keyName(shortcut.keyCode)
        item.keyEquivalent = name.count == 1 ? name.lowercased() : ""
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers & 256 != 0 { mask.insert(.command) }
        if shortcut.modifiers & 512 != 0 { mask.insert(.shift) }
        if shortcut.modifiers & 2048 != 0 { mask.insert(.option) }
        if shortcut.modifiers & 4096 != 0 { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let shelfItem = shortcutItems[PrefKey.shortcutShelf] {
            shelfItem.title = IslandController.shared.model.state == .open ? L("Скрыть полку") : L("Показать полку")
            shelfItem.isHidden = !Prefs.islandEnabled
        }
    }

    @objc private func smartCapture() { afterMenuCloses { CaptureController.shared.startSmart() } }
    @objc private func fullscreenCapture() { afterMenuCloses { CaptureController.shared.captureFullScreen() } }
    @objc private func textCapture() { afterMenuCloses { CaptureController.shared.startSmart(mode: .text) } }
    @objc private func toggleShelf() { afterMenuCloses { IslandController.shared.toggle() } }
    @objc private func openFolder() { NSWorkspace.shared.open(Prefs.saveToFolder ? Prefs.saveFolder : AppFolders.shelfFiles) }
    @objc func showSettings() { SettingsWindow.show() }
    @objc private func checkForUpdates() { Updates.checkNow() }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: L("Умные скриншоты с полкой у выреза экрана."),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    /// The menu must be gone before the screen is frozen, or it ends up in the capture.
    private func afterMenuCloses(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            action()
        }
    }

    // MARK: - Island actions

    private func makeIslandActions() -> IslandActions {
        let island = IslandController.shared
        let shelf = Shelf.shared
        return IslandActions(
            capture: {
                island.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { CaptureController.shared.startSmart() }
            },
            openFolder: { NSWorkspace.shared.open(Prefs.saveToFolder ? Prefs.saveFolder : AppFolders.shelfFiles) },
            openSettings: {
                island.close()
                SettingsWindow.show()
            },
            clear: {
                shelf.clear()
                SoundEffects.play(.removed)
            },
            edit: { item in
                island.close()
                Self.edit(item)
            },
            open: { item in NSWorkspace.shared.open(item.url) },
            copy: { item in
                if Self.copy(item) {
                    island.notify(L("Скопировано"))
                    SoundEffects.play(.copied)
                } else {
                    SoundEffects.play(.failure)
                }
            },
            copyText: { item in
                Task { @MainActor in
                    let text = await TextRecognizer.recognize(fileAt: item.url)
                    if text.isEmpty {
                        island.notify(L("Текст не найден"), symbol: "text.magnifyingglass")
                        SoundEffects.play(.failure)
                    } else {
                        CaptureOutput.copyText(text)
                        island.notify(L("Текст скопирован"), symbol: "text.viewfinder")
                        SoundEffects.play(.success)
                    }
                }
            },
            reveal: { item in NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
            keep: { item in
                if shelf.keep(item) != nil {
                    island.notify(L("Сохранено"))
                    SoundEffects.play(.sent)
                } else {
                    SoundEffects.play(.failure)
                }
            },
            remove: { item in
                // The shelf's own copy goes with the item: not while an editor holds unsaved changes to it.
                guard !item.shelfOnly || Self.closeEditor(of: item) else { return }
                shelf.remove(item)
                SoundEffects.play(.removed)
            },
            trash: { item in
                guard Self.closeEditor(of: item) else { return }
                shelf.remove(item, deleteFile: true)
                SoundEffects.play(.removed)
            },
            select: { item in island.select(item) },
            update: { command in Updates.perform(command) }
        )
    }

    /// Before an item's file is deleted: its editor closes, or, with unsaved changes, comes to the front and
    /// the file stays.
    private static func closeEditor(of item: ShelfItem) -> Bool {
        if AnnotationEditor.closeUnlessModified(url: item.url) { return true }
        IslandController.shared.notify(L("Снимок открыт в редакторе"), symbol: "pencil.tip.crop.circle")
        SoundEffects.play(.failure)
        return false
    }

    /// Puts an item on the clipboard the way it came: the picture, the file itself, the text.
    private static func copy(_ item: ShelfItem) -> Bool {
        switch item.kind {
        case .image:
            return CaptureOutput.copyFile(item.url)
        case .file:
            CaptureOutput.copyFileItself(item.url)
            return true
        case .text:
            guard let text = Shelf.text(of: item) else { return false }
            CaptureOutput.copyText(text)
            return true
        }
    }

    static func edit(_ item: ShelfItem) {
        AnnotationEditor.open(url: item.url, callbacks: EditorCallbacks(
            didSave: { url in
                Shelf.shared.fileChanged(url)
                SoundEffects.play(.sent)
            },
            didSaveCopy: { url in
                Shelf.shared.addFiles([url])
                SoundEffects.play(.sent)
            },
            didCopy: {
                IslandController.shared.notify(L("Скопировано"))
                SoundEffects.play(.copied)
            }
        ))
    }
}
