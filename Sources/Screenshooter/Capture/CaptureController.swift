import AppKit
import Detection
import ShotCore

/// Starts captures and delivers the results: the file (on the Desktop by default), the clipboard,
/// the shelf in the notch.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var session: CaptureSession?
    private var starting = false
    /// The app that was in front when the capture started; it gets the keyboard back afterwards.
    private var previousApp: NSRunningApplication?

    var isCapturing: Bool { session != nil || starting }

    private init() {}

    // MARK: - Starting

    /// The smart capture: freeze the screen, highlight what is under the pointer, capture on click.
    func startSmart(mode: CaptureSession.Mode = .image) {
        guard !isCapturing else { return }
        guard Permissions.screenRecording else {
            OnboardingWindow.show()
            return
        }
        starting = true
        IslandController.shared.close()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front

        let hidden = IslandController.shared.windowIDs
        let windows = WindowList.snapshot(excluding: hidden)
        if Prefs.detectElements, Prefs.boostWebApps {
            AccessibilityBooster.shared.boost(windows)
        }
        Task { @MainActor in
            defer { starting = false }
            do {
                let displays = try await ScreenCapturer.shared.freezeDisplays(excluding: hidden)
                var options = RegionDetector.Options()
                options.elements = Prefs.detectElements
                options.shapes = Prefs.detectShapes
                options.text = Prefs.detectText
                let detector = RegionDetector(displays: displays, windows: windows, options: options)
                let session = CaptureSession(mode: mode, displays: displays, detector: detector)
                session.onFinish = { selection in
                    self.sessionEnded(selection, displays: displays, mode: mode)
                }
                self.session = session
                session.begin()
            } catch {
                report(error)
            }
        }
    }

    /// The whole display under the pointer, saved at once.
    func captureFullScreen() {
        guard !isCapturing else { return }
        guard Permissions.screenRecording else {
            OnboardingWindow.show()
            return
        }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            do {
                let displays = try await ScreenCapturer.shared.freezeDisplays(excluding: IslandController.shared.windowIDs)
                guard let display = displays.containing(ScreenGeometry.mouseLocation) ?? displays.first else { return }
                deliver(display.image, scale: display.scale)
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Results

    private func sessionEnded(_ selection: CaptureSelection?, displays: [DisplaySnapshot], mode: CaptureSession.Mode) {
        session = nil
        AccessibilityBooster.shared.scheduleRestore()
        ScreenCapturer.shared.warmUp()
        returnFocus()
        guard let selection else { return }

        Task { @MainActor in
            switch mode {
            case .image:
                if let (image, scale) = await self.image(for: selection, displays: displays) {
                    self.deliver(image, scale: scale)
                } else {
                    self.report(CaptureError.nothingCaptured)
                }
            case .text:
                guard let display = displays.best(for: selection.rect), let image = display.crop(selection.rect) else { return }
                let text = await TextRecognizer.recognize(image)
                if text.isEmpty {
                    IslandController.shared.notify(L("Текст не найден"), symbol: "text.magnifyingglass")
                } else {
                    CaptureOutput.copyText(text)
                    IslandController.shared.notify(L("Текст скопирован"), symbol: "text.viewfinder")
                }
            }
        }
    }

    /// Whole windows are captured by themselves (nothing covering them, transparent corners);
    /// everything else comes from the frozen screen, exactly as it was shown.
    private func image(for selection: CaptureSelection, displays: [DisplaySnapshot]) async -> (CGImage, CGFloat)? {
        if let region = selection.region, region.source == .window, let id = region.windowID, Prefs.liveWindowCapture,
           let shot = try? await ScreenCapturer.shared.captureWindow(id, shadow: Prefs.windowShadow) {
            return shot
        }
        guard let display = displays.best(for: selection.rect), let image = display.crop(selection.rect) else { return nil }
        return (image, display.scale)
    }

    /// Saves, copies and puts the capture on the shelf. Encoding runs off the main thread.
    func deliver(_ image: CGImage, scale: CGFloat) {
        CaptureOutput.playShutter()
        let copy = Prefs.copyToClipboard
        Task.detached(priority: .userInitiated) {
            do {
                let saved = try CaptureOutput.save(image, scale: scale)
                await MainActor.run {
                    if copy { CaptureOutput.copy(image, scale: scale, png: saved.png) }
                    let item = Shelf.shared.addCapture(url: saved.url, image: image, shelfOnly: saved.shelfOnly)
                    IslandController.shared.showCapture(item)
                }
            } catch {
                await MainActor.run { self.report(error) }
            }
        }
    }

    /// Started from the menu or a link, the capture made this app active; with no window of its own to
    /// show, it hands the keyboard back to the app the user was working in.
    private func returnFocus() {
        let app = previousApp
        previousApp = nil
        guard NSApp.isActive, let app, !app.isTerminated,
              !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) })
        else { return }
        app.activate()
    }

    private func report(_ error: Error) {
        if case CaptureError.permissionDenied = error {
            OnboardingWindow.show()
            return
        }
        IslandController.shared.notify(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        NSSound.beep()
    }
}
