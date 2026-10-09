import AppKit
import Detection
import ScreenCaptureKit
import ShotCore

enum CaptureError: Error {
    case permissionDenied
    case nothingCaptured
    case windowGone
}

/// A failed capture in the user's words: what happened and what to do, in the interface language. The error itself,
/// with its domain and code, goes to the log.
enum CaptureFailure: Equatable {
    /// Screen recording is not allowed: the welcome window explains how to allow it.
    case permission
    case windowGone
    /// The file could not be written for want of space.
    case diskFull
    /// The file could not be written for another reason.
    case notSaved
    /// Anything else: ScreenCaptureKit failing, an empty picture.
    case other

    init(_ error: Error) {
        switch error {
        case CaptureError.permissionDenied: self = .permission
        case CaptureError.windowGone: self = .windowGone
        case let error as SCStreamError where error.code == .userDeclined: self = .permission
        case let error as CocoaError where error.code == .fileWriteOutOfSpace: self = .diskFull
        case let error as POSIXError where error.code == .ENOSPC: self = .diskFull
        // Foundation's file errors take codes 0–1023.
        case let error as CocoaError where (0...1023).contains(error.code.rawValue): self = .notSaved
        default: self = .other
        }
    }

    /// For the island; nothing for a missing permission, which opens the welcome window instead.
    var message: String? {
        switch self {
        case .permission: return nil
        case .windowGone: return L("Окно уже закрыто")
        case .diskFull: return L("Не удалось сохранить снимок. Освободите место на диске и попробуйте ещё раз")
        case .notSaved: return L("Не удалось сохранить снимок, попробуйте ещё раз")
        case .other: return L("Не удалось снять экран, попробуйте ещё раз")
        }
    }
}

/// ScreenCaptureKit wrapper. The notch shelf never gets into captures; the app's ordinary windows (the
/// editor, the settings) can be captured like any other.
@MainActor
final class ScreenCapturer {
    static let shared = ScreenCapturer()

    /// The list of displays and apps, fetched ahead of time: asking for it takes tens of milliseconds
    /// that would otherwise delay the freeze after the shortcut.
    private var content: SCShareableContent?

    nonisolated static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Refreshes the cached list in the background (at launch, after captures, when displays change).
    func warmUp() {
        guard Self.hasPermission else { return }
        Task { _ = try? await self.fetchContent() }
    }

    @discardableResult
    private func fetchContent() async throws -> SCShareableContent {
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        content = fresh
        return fresh
    }

    /// Every display as it looks right now, without the windows listed (the notch shelf): they must be
    /// in the fetched list to be left out, so a stale list is refreshed first.
    func freezeDisplays(excluding hidden: Set<CGWindowID> = []) async throws -> [DisplaySnapshot] {
        guard Self.hasPermission else { throw CaptureError.permissionDenied }
        var current = try await cachedOrFresh()
        // Displays could have been plugged in or out since the list was fetched.
        let live = Set(NSScreen.screens.map(\.displayID))
        if Set(current.displays.map(\.displayID)) != live
            || !hidden.isSubset(of: Set(current.windows.map(\.windowID))) {
            current = try await fetchContent()
        }
        let excluded = current.windows.filter { hidden.contains($0.windowID) }
        let shots = try await withThrowingTaskGroup(of: DisplaySnapshot.self) { group in
            for display in current.displays where live.contains(display.displayID) {
                group.addTask { try await Self.capture(display, excluding: excluded) }
            }
            var result: [DisplaySnapshot] = []
            for try await shot in group { result.append(shot) }
            return result
        }
        guard !shots.isEmpty else { throw CaptureError.nothingCaptured }
        return shots
    }

    /// One window by itself, as if nothing covered it, with transparent rounded corners.
    func captureWindow(_ windowID: CGWindowID, shadow: Bool) async throws -> (CGImage, CGFloat) {
        guard Self.hasPermission else { throw CaptureError.permissionDenied }
        var window = try await cachedOrFresh().windows.first { $0.windowID == windowID }
        if window == nil {
            window = try await fetchContent().windows.first { $0.windowID == windowID }
        }
        guard let window else { throw CaptureError.windowGone }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = !shadow
        config.showsCursor = false
        config.captureResolution = .best
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    private func cachedOrFresh() async throws -> SCShareableContent {
        if let content { return content }
        return try await fetchContent()
    }

    nonisolated private static func capture(_ display: SCDisplay, excluding windows: [SCWindow]) async throws
        -> DisplaySnapshot {
        let filter = SCContentFilter(display: display, excludingWindows: windows)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return DisplaySnapshot(displayID: display.displayID, frame: display.frame, scale: scale, image: image)
    }
}
