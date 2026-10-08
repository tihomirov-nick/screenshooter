import AppKit
import Carbon.HIToolbox
import Combine
import ShotCore
import SwiftUI
import UniformTypeIdentifiers

/// Routes keys so the editor works without the app's main menu:
/// ⌘ shortcuts go to the controller (or to the inline text view while typing), plain keys to the canvas.
final class EditorWindow: NSWindow {
    var commandHandler: ((NSEvent) -> Bool)?
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let textView = firstResponder as? NSTextView,
           Self.handleTextShortcut(event, textView) {
            return true
        }
        // Other ⌘ shortcuts (save, zoom, close) work while typing too; they finish the text first.
        if event.type == .keyDown, commandHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !(firstResponder is NSText), keyHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }

    /// The letter of a shortcut; with a non-Latin keyboard layout, from the physical key.
    static func shortcutKey(_ event: NSEvent) -> String? {
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
           chars.unicodeScalars.allSatisfy(\.isASCII) {
            return chars
        }
        switch Int(event.keyCode) {
        case kVK_ANSI_Z: return "z"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        default: return nil
        }
    }

    private static func handleTextShortcut(_ event: NSEvent, _ textView: NSTextView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift] else { return false }
        let shift = flags.contains(.shift)
        switch shortcutKey(event) {
        case "c" where !shift: textView.copy(nil)
        case "x" where !shift: textView.cut(nil)
        case "v" where !shift: textView.pasteAsPlainText(nil)
        case "a" where !shift: textView.selectAll(nil)
        case "z":
            if shift { textView.undoManager?.redo() } else { textView.undoManager?.undo() }
        default:
            return false
        }
        return true
    }
}

/// Keeps the image in the middle of the window when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = frame.midX - rect.width / 2 }
        if rect.height > frame.height { rect.origin.y = frame.midY - rect.height / 2 }
        return rect
    }
}

private extension NSToolbarItem.Identifier {
    static let editorUndo = NSToolbarItem.Identifier("editor.undo")
    static let editorRedo = NSToolbarItem.Identifier("editor.redo")
    static let editorTools = NSToolbarItem.Identifier("editor.tools")
    static let editorDrag = NSToolbarItem.Identifier("editor.drag")
    static let editorCopy = NSToolbarItem.Identifier("editor.copy")
    static let editorSave = NSToolbarItem.Identifier("editor.save")
    static let editorMore = NSToolbarItem.Identifier("editor.more")
    static let editorDone = NSToolbarItem.Identifier("editor.done")
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let model: EditorModel
    var callbacks: EditorCallbacks
    var onClose: ((EditorWindowController) -> Void)?
    /// Called after Save As… moved the window to another file: (controller, old URL, new URL).
    var onURLChange: ((EditorWindowController, URL, URL) -> Void)?

    private let canvas: EditorCanvasView
    private let scrollView = NSScrollView()
    private let chrome = EditorChrome()
    private let dragView = DragOutView(frame: NSRect(x: 0, y: 0, width: 36, height: 28))
    private weak var toolGroup: NSToolbarItemGroup?
    private weak var undoItem: NSToolbarItem?
    private weak var redoItem: NSToolbarItem?
    private var fitMode = true
    private var closeApproved = false
    private var messageTask: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(model: EditorModel, callbacks: EditorCallbacks) {
        self.model = model
        self.callbacks = callbacks
        canvas = EditorCanvasView(model: model)
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        super.init(window: window)
        configureWindow(window)
        buildContent(in: window)
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func configureWindow(_ window: EditorWindow) {
        window.title = model.url.lastPathComponent
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 460)
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.commandHandler = { [weak self] in self?.handleCommand($0) ?? false }
        window.keyHandler = { [weak self] in self?.canvas.handleKeyDown($0) ?? false }

        let toolbar = NSToolbar(identifier: "AnnotationEditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.editorTools]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()

        let actions = StyleBarActions(
            zoomIn: { [weak self] in self?.zoom(by: 1.25) },
            zoomOut: { [weak self] in self?.zoom(by: 0.8) },
            fit: { [weak self] in self?.fitToWindow() },
            applyCrop: { [weak self] in self?.model.applyCrop() },
            cancelCrop: { [weak self] in self?.model.cancelCrop() },
            resetCrop: { [weak self] in self?.model.resetCrop() }
        )
        let bar = NSHostingView(rootView: StyleBar(model: model, chrome: chrome, actions: actions))
        bar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.88, alpha: 1)
        }
        scrollView.postsFrameChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        canvas.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        canvas.onDisplayRectChange = { [weak self] in
            self?.updateThumbnail()
            self?.fitToWindow()
        }

        content.addSubview(bar)
        content.addSubview(separator)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        dragView.fileProvider = { [weak self] in self?.fileForDragging() }
        updateThumbnail()

        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: scrollView)
            .sink { [weak self] _ in
                guard let self, self.fitMode else { return }
                self.fitToWindow()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
            .sink { [weak self] _ in self?.fitMode = false }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
            .sink { [weak self] _ in self?.magnificationChanged() }
            .store(in: &cancellables)
    }

    private func observeModel() {
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncChrome() }
            }
            .store(in: &cancellables)
    }

    private func syncChrome() {
        guard let window else { return }
        if let group = toolGroup, let index = Tool.allCases.firstIndex(of: model.tool), group.selectedIndex != index {
            group.selectedIndex = index
        }
        undoItem?.isEnabled = model.canUndo && !canvas.isEditingText
        redoItem?.isEnabled = model.canRedo && !canvas.isEditingText
        if window.isDocumentEdited != model.isModified { window.isDocumentEdited = model.isModified }
    }

    // MARK: Showing

    func present() {
        guard let window else { return }
        if !window.isVisible {
            placeWindow(window)
        }
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        syncChrome()
        DispatchQueue.main.async { [weak self] in self?.fitToWindow() }
    }

    /// Sizes the window to the image at its natural size, within 85 % of the screen with the mouse.
    private func placeWindow(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let imageSize = canvas.frame.size
        let margin: CGFloat = 28
        let barHeight: CGFloat = 41
        // Content size wanted for the image at 100 %.
        var width = imageSize.width + 2 * margin
        var height = imageSize.height + 2 * margin + barHeight
        window.setContentSize(NSSize(width: width, height: height))
        // The toolbar and title bar take the rest of the frame.
        let chromeHeight = window.frame.height - height
        let maxWidth = visible.width * 0.85
        let maxHeight = visible.height * 0.85 - chromeHeight
        if width > maxWidth || height > maxHeight {
            let k = min((maxWidth - 2 * margin) / imageSize.width, (maxHeight - 2 * margin - barHeight) / imageSize.height)
            width = imageSize.width * k + 2 * margin
            height = imageSize.height * k + 2 * margin + barHeight
        }
        width = max(width, window.minSize.width)
        height = max(height, window.minSize.height - chromeHeight)
        window.setContentSize(NSSize(width: width.rounded(), height: height.rounded()))
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: (visible.midX - frame.width / 2).rounded(),
                                      y: (visible.midY - frame.height / 2).rounded()))
    }

    // MARK: Zoom

    func fitToWindow() {
        fitMode = true
        let available = scrollView.contentView.frame.size
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return }
        let margin: CGFloat = 28
        let fit = min(1, (available.width - 2 * margin) / size.width, (available.height - 2 * margin) / size.height)
        scrollView.magnification = max(fit, scrollView.minMagnification)
        magnificationChanged()
    }

    private func zoom(by factor: CGFloat) {
        fitMode = false
        let visible = scrollView.contentView.documentVisibleRect
        let center = NSPoint(x: visible.midX, y: visible.midY)
        let target = min(max(scrollView.magnification * factor, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(target, centeredAt: center)
        magnificationChanged()
    }

    private func zoomToActualSize() {
        fitMode = false
        let visible = scrollView.contentView.documentVisibleRect
        scrollView.setMagnification(1, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        magnificationChanged()
    }

    private func magnificationChanged() {
        chrome.magnification = scrollView.magnification
        // The shadow lives in the magnified space; keep it the same size on screen.
        canvas.shadow?.shadowBlurRadius = 10 / max(scrollView.magnification, 0.05)
        canvas.shadow = canvas.shadow
        canvas.refresh()
    }

    // MARK: Commands

    private func handleCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let shift = flags.contains(.shift)
        switch EditorWindow.shortcutKey(event) {
        case "z":
            if shift { redo(nil) } else { undo(nil) }
        case "c" where !shift:
            copyImage(nil)
        case "s":
            if shift { saveAs(nil) } else { save(nil) }
        case "w" where !shift:
            window?.performClose(nil)
        case "=", "+":
            zoom(by: 1.25)
        case "-":
            zoom(by: 0.8)
        case "0":
            fitToWindow()
        case "1":
            zoomToActualSize()
        default:
            return false
        }
        return true
    }

    @objc private func undo(_ sender: Any?) {
        canvas.commitTextEditing()
        model.undo()
    }

    @objc private func redo(_ sender: Any?) {
        canvas.commitTextEditing()
        model.redo()
    }

    @objc private func toolPicked(_ sender: NSToolbarItemGroup) {
        let index = sender.selectedIndex
        guard Tool.allCases.indices.contains(index) else { return }
        canvas.commitTextEditing()
        model.setTool(Tool.allCases[index])
        window?.makeFirstResponder(canvas)
    }

    @objc private func copyImage(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let image = model.renderImage() else { return }
        ImageFiles.copyToPasteboard(image, scale: model.scale, dpi: model.dpi)
        callbacks.didCopy()
        showMessage(L("Скопировано"))
    }

    @objc private func save(_ sender: Any?) {
        _ = saveToFile()
    }

    /// Overwrites the original file. Returns false when writing failed (an alert is already shown).
    private func saveToFile() -> Bool {
        canvas.commitTextEditing()
        guard let image = model.renderImage() else { return false }
        do {
            try ImageFiles.write(image, to: model.url, dpi: model.dpi)
        } catch {
            showError(error)
            return false
        }
        model.markSaved()
        callbacks.didSave(model.url)
        showMessage(L("Сохранено"))
        return true
    }

    @objc private func saveAs(_ sender: Any?) {
        guard let window else { return }
        canvas.commitTextEditing()
        let panel = NSSavePanel()
        let original = model.url
        let ext = original.pathExtension.isEmpty ? "png" : original.pathExtension
        panel.directoryURL = original.deletingLastPathComponent()
        panel.nameFieldStringValue = L("%@ (изменено)", original.deletingPathExtension().lastPathComponent) + "." + ext
        panel.allowedContentTypes = [ImageFiles.contentType(for: original), .png, .jpeg, .heic, .tiff]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let image = self.model.renderImage() else { return }
            do {
                try ImageFiles.write(image, to: url, dpi: self.model.dpi)
            } catch {
                self.showError(error)
                return
            }
            // The window now edits the new file, like Save As… in any document app.
            self.model.retarget(to: url)
            window.title = url.lastPathComponent
            self.onURLChange?(self, original, url)
            self.callbacks.didSaveCopy(url)
            self.syncChrome()
            self.showMessage(L("Сохранено"))
        }
    }

    @objc private func showInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([model.url])
    }

    @objc private func done(_ sender: Any?) {
        canvas.commitTextEditing()
        if model.isModified, !saveToFile() { return }
        closeApproved = true
        window?.close()
    }

    private func fileForDragging() -> URL? {
        canvas.commitTextEditing()
        if !model.isModified { return model.url }
        guard let image = model.renderImage(),
              let url = ImageFiles.temporaryFileURL(named: model.url.lastPathComponent) else { return nil }
        do {
            try ImageFiles.write(image, to: url, dpi: model.dpi)
            return url
        } catch {
            return nil
        }
    }

    private func updateThumbnail() {
        let crop = model.state.crop ?? model.imageRect
        guard let image = model.baseImage.cropping(to: crop) else { return }
        dragView.thumbnail = NSImage(cgImage: image, size: NSSize(width: crop.width / model.scale, height: crop.height / model.scale))
    }

    private func showMessage(_ text: String) {
        messageTask?.cancel()
        chrome.message = text
        let task = DispatchWorkItem { [weak self] in self?.chrome.message = nil }
        messageTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: task)
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Не удалось сохранить «%@».", model.url.lastPathComponent)
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitTextEditing()
        if closeApproved || !model.isModified { return true }
        let alert = NSAlert()
        alert.messageText = L("Сохранить изменения в файле «%@»?", model.url.lastPathComponent)
        alert.informativeText = L("Если не сохранить, правки будут потеряны.")
        alert.addButton(withTitle: L("Сохранить"))
        let discard = alert.addButton(withTitle: L("Не сохранять"))
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: L("Отмена"))
        cancel.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.saveToFile() {
                    self.closeApproved = true
                    sender.close()
                }
            case .alertSecondButtonReturn:
                self.closeApproved = true
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        canvas.commitTextEditing()
        cancellables.removeAll()
        messageTask?.cancel()
        onClose?(self)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.editorUndo, .editorRedo, .flexibleSpace, .editorTools, .flexibleSpace,
         .editorDrag, .editorCopy, .editorSave, .editorMore, .editorDone]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    private func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .editorUndo, .editorRedo:
            let isUndo = itemIdentifier == .editorUndo
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = isUndo ? L("Отменить") : L("Повторить")
            item.toolTip = isUndo ? L("Отменить (⌘Z)") : L("Повторить (⇧⌘Z)")
            item.image = symbol(isUndo ? "arrow.uturn.backward" : "arrow.uturn.forward", item.label)
            item.isBordered = true
            item.autovalidates = false
            item.target = self
            item.action = isUndo ? #selector(undo(_:)) : #selector(redo(_:))
            item.isEnabled = false
            if isUndo { undoItem = item } else { redoItem = item }
            return item

        case .editorTools:
            let tools = Tool.allCases
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier,
                                           images: tools.map { symbol($0.symbol, $0.title) },
                                           selectionMode: .selectOne,
                                           labels: tools.map(\.title),
                                           target: self,
                                           action: #selector(toolPicked(_:)))
            group.label = L("Инструменты")
            for (subitem, tool) in zip(group.subitems, tools) {
                subitem.toolTip = "\(tool.title) (\(tool.letter))"
            }
            group.selectedIndex = tools.firstIndex(of: model.tool) ?? 0
            toolGroup = group
            return group

        case .editorDrag:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("Перетащить")
            item.toolTip = L("Перетащите снимок в другую программу или в Finder")
            item.view = dragView
            return item

        case .editorCopy:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("Скопировать")
            item.toolTip = L("Скопировать изображение (⌘C)")
            item.image = symbol("doc.on.doc", item.label)
            item.isBordered = true
            item.target = self
            item.action = #selector(copyImage(_:))
            return item

        case .editorSave:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("Сохранить")
            item.toolTip = L("Сохранить в исходный файл (⌘S)")
            item.image = symbol("square.and.arrow.down", item.label)
            item.isBordered = true
            item.target = self
            item.action = #selector(save(_:))
            return item

        case .editorMore:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("Ещё")
            item.toolTip = L("Ещё")
            item.image = symbol("ellipsis.circle", item.label)
            item.showsIndicator = false
            let menu = NSMenu()
            let saveAs = menu.addItem(withTitle: L("Сохранить как…"), action: #selector(saveAs(_:)), keyEquivalent: "s")
            saveAs.keyEquivalentModifierMask = [.command, .shift]
            saveAs.target = self
            menu.addItem(withTitle: L("Показать в Finder"), action: #selector(showInFinder(_:)), keyEquivalent: "").target = self
            item.menu = menu
            return item

        case .editorDone:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("Готово")
            item.title = L("Готово")
            item.toolTip = L("Сохранить и закрыть")
            item.isBordered = true
            item.target = self
            item.action = #selector(done(_:))
            if #available(macOS 26.0, *) {
                item.style = .prominent
            }
            return item

        default:
            return nil
        }
    }
}
