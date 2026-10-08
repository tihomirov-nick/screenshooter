import AppKit
import ApplicationServices

/// The two permissions the app works with: screen recording (required) and accessibility
/// (recommended: it finds buttons, messages and page elements under the cursor).
enum Permissions {
    enum Kind {
        case screenRecording, accessibility

        var granted: Bool {
            switch self {
            case .screenRecording: return Permissions.screenRecording
            case .accessibility: return Permissions.accessibility
            }
        }

        /// The service as tccutil names it.
        fileprivate var service: String { self == .screenRecording ? "ScreenCapture" : "Accessibility" }
        /// Its list in System Settings → Privacy & Security.
        fileprivate var anchor: String { self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility" }
    }

    /// The window a request was made from: after a relaunch for screen recording the app opens it again.
    enum Place: String {
        case onboarding, settings
    }

    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Whether screen recording was on when this process started. Turned on later, it works only in a new process.
    @MainActor private(set) static var screenRecordingAtLaunch = true

    private static let returnKey = "permissionsReturnTo"

    /// Called once at launch: remembers whether screen recording is on and tells which window to open again when the
    /// app has just relaunched itself for it.
    @MainActor static func launched() -> Place? {
        screenRecordingAtLaunch = screenRecording
        let place = UserDefaults.standard.string(forKey: returnKey).flatMap(Place.init(rawValue:))
        UserDefaults.standard.removeObject(forKey: returnKey)
        return place
    }

    /// Asks for a permission the app does not have yet. When the app's signature changes (a new certificate, a copy
    /// signed differently), System Settings keeps its old row, and that row belongs to the old signature: turning it on
    /// does nothing for this copy. So the old row goes first (tccutil, no admin rights needed), and the system request
    /// then adds a fresh one, switched off: the user only has to turn it on. The app watches for that and carries on.
    @MainActor static func request(_ kind: Kind, from place: Place) {
        guard !kind.granted else { return }
        let forgotten = forget(kind)
        switch kind {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        // With the old row still in place the system does not ask again: the way is through System Settings.
        if !forgotten { openSettings(kind.anchor) }
        watch(kind, from: place)
    }

    /// `tccutil reset <service> <bundle id>`: removes the app's row from that list, whatever signature it was made for.
    private static func forget(_ kind: Kind) -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", kind.service, id]
        tccutil.standardOutput = FileHandle.nullDevice
        tccutil.standardError = FileHandle.nullDevice
        do { try tccutil.run() } catch { return false }
        tccutil.waitUntilExit()
        return tccutil.terminationStatus == 0
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Waiting for the switch

    @MainActor private static var waiting: [Kind: Place] = [:]
    @MainActor private static var waitUntil = Date.distantPast
    @MainActor private static var watcher: Timer?

    /// Checks twice a second, for ten minutes after the request, whether the permission has been turned on.
    /// Accessibility works at once. Screen recording turned on while the app runs works only in a new process, so the
    /// app relaunches itself and opens again the window the request came from.
    @MainActor private static func watch(_ kind: Kind, from place: Place) {
        waiting[kind] = place
        waitUntil = Date().addingTimeInterval(600)
        guard watcher == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    @MainActor private static func check() {
        for (kind, place) in waiting where kind.granted {
            waiting[kind] = nil
            if kind == .screenRecording, !screenRecordingAtLaunch {
                UserDefaults.standard.set(place.rawValue, forKey: returnKey)
                relaunch()
            }
        }
        if waiting.isEmpty || Date() > waitUntil {
            waiting.removeAll()
            watcher?.invalidate()
            watcher = nil
        }
    }

    /// Quits and starts the app again: the new copy opens once this one has quit. Quitting waits for a capture in
    /// progress and asks about unsaved edits; if it is cancelled, nothing starts (the shell gives up after a minute).
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "for i in $(seq 300); do kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$0\"; sleep 0.2; done",
                          Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        NSApp.terminate(nil)
    }
}
