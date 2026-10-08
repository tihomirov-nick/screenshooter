import AppKit
import Combine
import ShotCore
import SwiftUI

/// The welcome window: what the app does and the two permissions it needs.
@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show(askingForFolderAccess: Bool = true) {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(close: { OnboardingWindow.close() }))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Screenshooter"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // Shown over a full-screen app too, in the Space the user is in.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.layoutIfNeeded()
            window.center()
            self.window = window
        }
        UserDefaults.standard.set(true, forKey: PrefKey.onboardingShown)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if askingForFolderAccess { askForSaveFolderAccess() }
    }

    /// macOS asks before an app may write to the Desktop; better now, next to the other permissions,
    /// than in the middle of the first capture.
    private static func askForSaveFolderAccess() {
        guard Prefs.saveToFolder else { return }
        let folder = Prefs.saveFolder
        DispatchQueue.global(qos: .utility).async {
            _ = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        }
    }

    static func close() {
        window?.close()
    }
}

private struct OnboardingView: View {
    let close: () -> Void
    @State private var screenGranted = Permissions.screenRecording
    @State private var grantedAtLaunch = Permissions.screenRecording
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.top, 26)
            VStack(spacing: 6) {
                Text(L("Добро пожаловать в Screenshooter"))
                    .font(.system(size: 20, weight: .bold))
                Text(L("Наведите указатель — приложение само найдёт окно, панель, сообщение или элемент страницы. Клик — и снимок готов: он сохранится на рабочий стол и появится на полке у выреза экрана."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)

            VStack(spacing: 0) {
                PermissionRows()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 24)

            HStack(spacing: 6) {
                Text(L("Умный снимок:"))
                Text(Shortcut.load(PrefKey.shortcutSmart, default: .smartDefault)?.display ?? "—")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                Text(L("· значок в строке меню"))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)

            HStack {
                if screenGranted && !grantedAtLaunch {
                    Button(L("Перезапустить")) { Permissions.relaunch() }
                        .help(L("Запись экрана начнёт работать после перезапуска"))
                }
                Spacer()
                Button(L("Готово"), action: close)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .frame(width: 520)
        .onReceive(timer) { _ in screenGranted = Permissions.screenRecording }
    }
}
