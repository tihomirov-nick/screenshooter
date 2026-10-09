import AppKit
import ShotCore

/// What the editor reports back to the app.
public struct EditorCallbacks {
    /// The original file was overwritten with the edited image.
    public var didSave: (URL) -> Void
    /// A new file was written (Save As…).
    public var didSaveCopy: (URL) -> Void
    /// The edited image was put on the clipboard.
    public var didCopy: () -> Void

    public init(didSave: @escaping (URL) -> Void = { _ in },
                didSaveCopy: @escaping (URL) -> Void = { _ in },
                didCopy: @escaping () -> Void = {}) {
        self.didSave = didSave
        self.didSaveCopy = didSaveCopy
        self.didCopy = didCopy
    }
}

/// API contract used by the app — keep the signatures stable.
@MainActor
public enum AnnotationEditor {
    /// Open editor windows by the file they edit.
    private static var controllers: [URL: EditorWindowController] = [:]

    /// Opens an editor window for the image file, or brings an already open one for the same file to the front.
    public static func open(url: URL, callbacks: EditorCallbacks = EditorCallbacks()) {
        let key = url.standardizedFileURL
        if let existing = controllers[key] {
            existing.callbacks = callbacks
            existing.present()
            return
        }
        guard let model = EditorModel(url: key) else {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Не удалось открыть изображение «%@».", key.lastPathComponent)
            alert.informativeText = FileManager.default.fileExists(atPath: key.path)
                ? L("Файл повреждён или его формат не поддерживается.")
                : L("Файл перемещён или удалён.")
            alert.runModal()
            return
        }
        let controller = EditorWindowController(model: model, callbacks: callbacks)
        controller.onClose = { closed in
            controllers = controllers.filter { $0.value !== closed }
        }
        controller.onURLChange = { moved, old, new in
            controllers[old.standardizedFileURL] = nil
            controllers[new.standardizedFileURL] = moved
        }
        controllers[key] = controller
        controller.present()
    }

    /// Before the file goes away: closes its editor window and returns true, or, when the window has
    /// unsaved changes, brings it to the front and returns false (nothing is closed). True when no editor
    /// has the file open.
    public static func closeUnlessModified(url: URL) -> Bool {
        guard let controller = controllers[url.standardizedFileURL] else { return true }
        if controller.model.isModified {
            controller.present()
            return false
        }
        controller.window?.close()
        return true
    }

    /// Some editor window has unsaved changes. Asks nothing and shows nothing (an update that installs itself waits
    /// while this is true).
    public static var hasUnsavedChanges: Bool {
        controllers.values.contains { $0.model.isModified }
    }

    /// For the app's quit handler: true when no editor window has unsaved changes. Otherwise brings the
    /// first such window to the front with its "save changes?" sheet and returns false; the app should
    /// cancel this quit (the person quits again after answering).
    public static func reviewUnsavedChanges() -> Bool {
        guard let controller = controllers.values.first(where: { $0.model.isModified }) else { return true }
        controller.present()
        controller.window?.performClose(nil)
        return false
    }
}
