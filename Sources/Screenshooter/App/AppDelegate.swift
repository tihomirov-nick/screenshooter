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
        Prefs.registerDefaults()
        MainMenu.install()
        WindowActivation.start()
        setUpStatusItem()

        IslandController.shared.actions = makeIslandActions()
        applySettings()
        registerShortcuts()
        ScreenCapturer.shared.warmUp()

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

        if !Permissions.screenRecording || !UserDefaults.standard.bool(forKey: PrefKey.onboardingShown) {
            OnboardingWindow.show()
        }
    }

    /// An editor with unsaved changes asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AnnotationEditor.reviewUnsavedChanges() ? .terminateNow : .terminateCancel
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshooter")
        image?.isTemplate = true
        item.button?.image = image
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
            clear: { shelf.clear() },
            edit: { item in
                island.close()
                Self.edit(item)
            },
            open: { item in NSWorkspace.shared.open(item.url) },
            copy: { item in
                CaptureOutput.copyFile(item.url)
                island.notify(L("Скопировано"))
            },
            copyText: { item in
                Task { @MainActor in
                    let text = await TextRecognizer.recognize(fileAt: item.url)
                    if text.isEmpty {
                        island.notify(L("Текст не найден"), symbol: "text.magnifyingglass")
                    } else {
                        CaptureOutput.copyText(text)
                        island.notify(L("Текст скопирован"), symbol: "text.viewfinder")
                    }
                }
            },
            reveal: { item in NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
            keep: { item in
                if shelf.keep(item) != nil { island.notify(L("Сохранено")) }
            },
            remove: { item in shelf.remove(item) },
            trash: { item in shelf.remove(item, deleteFile: true) },
            drop: { urls in shelf.addFiles(urls) },
            dragStarted: { island.shelfDragStarted() }
        )
    }

    static func edit(_ item: ShelfItem) {
        AnnotationEditor.open(url: item.url, callbacks: EditorCallbacks(
            didSave: { url in Shelf.shared.fileChanged(url) },
            didSaveCopy: { url in Shelf.shared.addFiles([url]) },
            didCopy: { IslandController.shared.notify(L("Скопировано")) }
        ))
    }
}
