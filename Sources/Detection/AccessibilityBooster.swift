import AppKit
import ApplicationServices

/// Chromium browsers, Electron apps (Slack, Discord, VS Code, Obsidian…) and Firefox build the
/// accessibility tree of their web content only when an assistive app asks for it. Without it the
/// overlay sees one opaque web area instead of messages, posts and page elements.
///
/// Turning it on costs those apps some CPU, so it is turned off again a while after the last capture.
/// Nothing is touched while VoiceOver runs: it relies on the same switches.
public final class AccessibilityBooster {
    public static let shared = AccessibilityBooster()

    private let queue = DispatchQueue(label: "Screenshooter.AccessibilityBooster")
    /// Attributes this class switched on, per process.
    private var switchedOn: [pid_t: [String]] = [:]
    private var tried: Set<pid_t> = []
    private var restore: DispatchWorkItem?

    private static let manual = "AXManualAccessibility"     // Electron and Chromium
    private static let enhanced = "AXEnhancedUserInterface" // what VoiceOver sets; Firefox and older Chromium

    /// Browsers that need the VoiceOver switch.
    private static let enhancedBundlePrefixes = [
        "org.mozilla.", "app.zen-browser.", "net.waterfox.", "org.torproject.", "io.gitlab.librewolf",
        "com.google.Chrome", "org.chromium.", "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.",
        "com.vivaldi.", "ru.yandex.desktop.yandex-browser", "company.thebrowser.",
    ]

    /// Switches web accessibility on in the apps that own these windows. Returns at once.
    public func boost(_ windows: [WindowInfo]) {
        let apps = Dictionary(windows.map { ($0.pid, $0.bundleID) }, uniquingKeysWith: { a, _ in a })
        queue.async { [self] in
            restore?.cancel()
            restore = nil
            guard AXIsProcessTrusted(), !NSWorkspace.shared.isVoiceOverEnabled else { return }
            for (pid, bundleID) in apps where !tried.contains(pid) {
                tried.insert(pid)
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                var switched: [String] = []
                if switchOn(Self.manual, of: app) {
                    switched.append(Self.manual)
                } else if let bundleID, Self.enhancedBundlePrefixes.contains(where: bundleID.hasPrefix),
                          switchOn(Self.enhanced, of: app) {
                    switched.append(Self.enhanced)
                }
                if !switched.isEmpty { switchedOn[pid] = switched }
            }
        }
    }

    /// Switches everything back off after `delay` unless another capture starts first.
    public func scheduleRestore(after delay: TimeInterval = 90) {
        queue.async { [self] in
            restore?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restoreNow() }
            restore = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Called on the queue.
    private func restoreNow() {
        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        for (pid, attributes) in switchedOn {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            for attribute in attributes where !(voiceOver && attribute == Self.enhanced) {
                AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanFalse)
            }
        }
        switchedOn.removeAll()
        tried.removeAll()
        restore = nil
    }

    /// True when the attribute was off and is on now.
    private func switchOn(_ attribute: String, of app: AXUIElement) -> Bool {
        var current: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, attribute as CFString, &current) == .success,
           let value = current, CFGetTypeID(value) == CFBooleanGetTypeID(), CFBooleanGetValue((value as! CFBoolean)) {
            return false // already on, someone else's switch
        }
        return AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue) == .success
    }
}
