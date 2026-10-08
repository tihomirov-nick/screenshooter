import AppKit
import Carbon.HIToolbox
import ShotCore
import SwiftUI

extension Notification.Name {
    /// A global shortcut was changed in Settings (or recording one started or ended).
    static let shortcutsChanged = Notification.Name("ScreenshooterShortcutsChanged")
}

/// A button that records the next key combination as a global shortcut.
struct ShortcutRecorder: View {
    let key: String
    let defaultValue: Shortcut?

    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? L("Нажмите сочетание…") : (shortcut?.display ?? L("Не задано")))
                    .font(.system(size: 12.5, weight: shortcut == nil && !recording ? .regular : .medium).monospacedDigit())
                    .foregroundStyle(recording ? Color.accentColor : (shortcut == nil ? .secondary : .primary))
                    .frame(minWidth: 128)
            }
            .buttonStyle(.bordered)
            .help(L("Нажмите и введите новое сочетание. Esc — отмена, ⌫ — удалить."))

            if shortcut != nil, !recording {
                Button { set(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Удалить сочетание"))
            }
            if let defaultValue, shortcut != defaultValue, !recording {
                Button(L("Вернуть %@", defaultValue.display)) { set(defaultValue) }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
        }
        .onAppear { shortcut = Shortcut.load(key, default: defaultValue) }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        // Free the current combinations, so pressing one of them records it instead of starting a capture.
        HotKeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                set(nil)
                stop()
            default:
                if let new = Shortcut(event: event) {
                    set(new)
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    private func set(_ value: Shortcut?) {
        shortcut = value
        Shortcut.save(value, for: key)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}
