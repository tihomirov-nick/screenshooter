import AppKit
import Carbon.HIToolbox
import ShotCore
import SwiftUI

/// The panel at the top of the screen that grows out of the notch: it shows each new capture for a
/// moment, opens into the shelf when the pointer comes to the notch, and takes files and text dropped onto it.
@MainActor
final class IslandController: IslandDropTarget {
    static let shared = IslandController()

    let model = IslandModel()
    var actions: IslandActions?

    private var panel: IslandPanel?
    /// Holds the keyboard while a card is chosen with a click (⌘C, ⌫).
    private var keyPanel: IslandKeyPanel?
    private var screen: NSScreen?
    /// Horizontal centre of the notch, AppKit coordinates.
    private var centerX: CGFloat = 0
    private var top: CGFloat = 0
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var stateWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var menuTracking = false
    private var draggingFromShelf = false
    /// Drops whose files or text are still being copied onto the shelf.
    private var receiving = 0
    /// The drag pasteboard's change count at the last mouse down. A drag that started since then wrote to
    /// it; a window or a text selection being dragged did not.
    private var dragCountAtMouseDown = 0
    /// The card under the pointer at the last mouse down on the panel, and that mouse down.
    private var pressedCard: (item: ShelfItem, event: NSEvent)?
    /// The folders the drag over the shelf brings (when it brings only folders), looked up once per drag.
    private var dragFolders: (sequence: Int, folders: [URL]) = (-1, [])
    private let dragSource = ShelfDragSource()
    /// Opened from the menu or a shortcut: stays until the pointer has been over it (or a click elsewhere).
    private var waitingForPointer = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    /// The panel's window, left out of captures.
    var windowIDs: Set<CGWindowID> {
        guard let number = panel?.windowNumber, number > 0 else { return [] }
        return [CGWindowID(number)]
    }

    /// The island is on screen (switched on in the settings).
    var isRunning: Bool { panel != nil }

    /// Something is being dragged onto the shelf or out of it, or a drop is still being copied in. A drag holds a mouse
    /// button down: a flag left behind by a drag whose end never reached the island does not count.
    var isMovingItems: Bool {
        receiving > 0
            || (NSEvent.pressedMouseButtons != 0 && (draggingFromShelf || model.dragOver || model.dropTargeted))
    }

    // MARK: - Lifecycle

    func start() {
        guard panel == nil, Prefs.islandEnabled, let actions else { return }
        let panel = IslandPanel()
        panel.mouseFilter = { [weak self] event in self?.panelMouse(event) ?? false }
        dragSource.onEnd = { [weak self] in
            self?.draggingFromShelf = false
            self?.evaluate()
        }
        let root = IslandRootView(model: model, shelf: Shelf.shared, actions: actions)
        let hosting = IslandHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.dropTarget = self
        hosting.registerForDraggedTypes(Shelf.dropTypes)
        panel.contentView = hosting
        self.panel = panel
        layout()
        panel.orderFrontRegardless()
        ScreenCapturer.shared.warmUp()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
            return event
        }) {
            monitors.append(local)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuTracking = false
                self?.evaluate()
            }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        keyPanel?.orderOut(nil)
        panel?.orderOut(nil)
        panel = nil
        model.state = .closed
    }

    /// Picks the display and places the panel over its notch.
    func layout() {
        guard let panel else { return }
        let screens = NSScreen.screens
        let chosen: NSScreen?
        switch Prefs.islandScreen {
        case .automatic: chosen = screens.first { $0.notchFrame != nil } ?? screens.first
        case .main: chosen = screens.first
        }
        guard let screen = chosen else { return }
        self.screen = screen

        var metrics = IslandMetrics()
        if let notch = screen.notchFrame {
            metrics.notchWidth = notch.width
            metrics.notchHeight = notch.height
            metrics.hasNotch = true
            centerX = notch.midX
        } else {
            metrics.notchWidth = 190
            metrics.notchHeight = max(24, screen.menuBarHeight)
            metrics.hasNotch = false
            centerX = screen.frame.midX
        }
        top = screen.frame.maxY
        if model.metrics != metrics { model.metrics = metrics }

        let size = metrics.panelSize
        panel.setFrame(NSRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }

    /// After a change of displays or of Space, and after sleep: the panel back over the notch and in front,
    /// and a look at the pointer, which may already be resting at the notch (no mouse events arrive while
    /// Spaces slide).
    private func refresh() {
        layout()
        panel?.orderFrontRegardless()
        evaluate()
    }

    // MARK: - Showing things

    /// A capture landed on the shelf.
    func showCapture(_ item: ShelfItem) {
        guard panel != nil else { return }
        if model.state == .open {
            flashCard(item.id)
            return
        }
        guard Prefs.islandPeek else { return }
        model.peekItemID = item.id
        setState(.peek, revertAfter: 2.8)
    }

    /// A short confirmation: in the header of the open shelf, or under the notch. `busy`: work under way ("Убираю
    /// фон…"), with a spinner; it stays until the next message brings the result.
    func notify(_ text: String, symbol: String = "checkmark.circle.fill", busy: Bool = false) {
        guard panel != nil else { return }
        if model.state == .open {
            model.toast = IslandToast(text: text, symbol: symbol, busy: busy)
            toastWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.model.toast = nil }
            toastWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (busy ? 30 : 1.6), execute: work)
            return
        }
        // Work begun in the open shelf and finished after it closed: its spinner must not greet the shelf next time.
        if model.toast?.busy == true { model.toast = nil }
        model.bannerText = text
        model.bannerSymbol = symbol
        model.bannerActions = []
        model.bannerBusy = busy
        setState(.banner, revertAfter: busy ? 30 : 1.9)
    }

    /// A picture made here (a cut-out, a moodboard) landed on the shelf: its card lights up in the open shelf and the
    /// message takes the header; otherwise the message shows under the notch.
    func present(_ item: ShelfItem, saying text: String, symbol: String = "checkmark.circle.fill") {
        guard panel != nil else { return }
        if model.state == .open { flashCard(item.id) }
        notify(text, symbol: symbol)
    }

    /// A new version under the notch with its buttons. It stays a few seconds, and as long as the pointer is over it;
    /// the open shelf shows the offer in its update row instead.
    func offer(_ text: String, symbol: String, actions: [IslandUpdate.Action]) {
        guard panel != nil, model.state != .open else { return }
        model.bannerText = text
        model.bannerSymbol = symbol
        model.bannerActions = actions
        model.bannerBusy = false
        setState(.banner, revertAfter: 8)
    }

    /// The offer under the notch is gone (installed, put off, skipped): so is its banner.
    func withdrawOffer() {
        if offersChoice { close() }
    }

    /// A banner with buttons is shown: pointing at it or clicking it does not open the shelf.
    private var offersChoice: Bool { model.state == .banner && !model.bannerActions.isEmpty }

    func toggle() {
        model.state == .open ? close() : open(explicitly: true)
    }

    /// `explicitly`: from the menu or a shortcut, not by pointing at the notch.
    func open(explicitly: Bool = false) {
        guard panel != nil else { return }
        openWork?.cancel()
        openWork = nil
        Shelf.shared.pruneMissing()
        waitingForPointer = explicitly && !isPointerOverIsland
        // Cards report the pointer again as they appear.
        model.hoveredItemID = nil
        setState(.open)
        startPolling()
        evaluate()
    }

    func close() {
        closeWork?.cancel()
        closeWork = nil
        waitingForPointer = false
        setState(.closed)
        model.dropTargeted = false
        model.dragOver = false
        model.hoveredItemID = nil
        deselect()
        evaluate()
    }

    private func setState(_ state: IslandState, revertAfter delay: TimeInterval? = nil) {
        stateWork?.cancel()
        model.state = state
        if state != .closed { startPolling() }
        if let delay {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.state == state else { return }
                if !self.isPointerOverIsland {
                    self.setState(.closed)
                } else if self.offersChoice {
                    // The pointer is on its way to a button.
                    self.setState(state, revertAfter: 2)
                } else {
                    self.open()
                }
            }
            stateWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        updateMouseHandling(NSEvent.mouseLocation)
    }

    private func flashCard(_ id: UUID) {
        model.highlightedItemID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.model.highlightedItemID == id { self?.model.highlightedItemID = nil }
        }
    }

    // MARK: - Pointer

    // A pointer pushed against the top of the screen sits exactly on its edge, y == top, and
    // `NSRect.contains` leaves the top edge out. So the rectangles below reach a point above the screen;
    // otherwise the most natural way to reach the notch, flinging the pointer up, would not open it.

    /// The island's outline in the given state (grown while something is dragged over it), AppKit coordinates.
    private func shapeRect(_ state: IslandState) -> NSRect {
        let shelf = Shelf.shared
        let size = state == model.state ? model.shapeSize(shelf: shelf) : model.size(for: state, shelf: shelf)
        return NSRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height + 1)
    }

    /// Where the pointer opens the closed island: the camera housing (or the middle of the menu bar).
    private var hotRect: NSRect {
        let m = model.metrics
        return NSRect(x: centerX - m.notchWidth / 2 - 8, y: top - m.notchHeight - 3,
                      width: m.notchWidth + 16, height: m.notchHeight + 4)
    }

    /// Where pointing or clicking opens the shelf: the camera housing, and what the island shows under it, except a
    /// banner with buttons, which are there to be pressed.
    private func opensShelf(at point: NSPoint) -> Bool {
        if hotRect.contains(point) { return true }
        guard model.state != .closed, !offersChoice else { return false }
        return shapeRect(model.state).contains(point)
    }

    /// Over the island, or over the camera housing while the island is closed in it.
    private var isPointerOverIsland: Bool {
        let mouse = NSEvent.mouseLocation
        if model.state == .closed { return hotRect.contains(mouse) }
        return shapeRect(model.state).insetBy(dx: -4, dy: -4).contains(mouse)
    }

    private func mouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            draggingFromShelf = false
        case .leftMouseDown, .rightMouseDown:
            if event.type == .leftMouseDown { dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount }
            let mouse = NSEvent.mouseLocation
            if model.state == .open {
                // A click anywhere else puts the open shelf away.
                if !shapeRect(.open).contains(mouse), !menuTracking { close() }
            } else if event.type == .leftMouseDown, opensShelf(at: mouse) {
                // A click on the notch or on a capture shown in it opens the shelf.
                open()
            }
            return
        default:
            break
        }
        evaluate(dragging: event.type == .leftMouseDragged)
    }

    private func evaluate(dragging: Bool = false) {
        guard panel != nil else { return }
        let mouse = NSEvent.mouseLocation
        updateMouseHandling(mouse)

        switch model.state {
        case .closed, .peek, .banner:
            guard opensShelf(at: mouse) else {
                openWork?.cancel()
                openWork = nil
                return
            }
            if dragging {
                if isExternalDrag { open() }
            } else if Prefs.islandOpenOnHover, openWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openWork = nil
                    if self.opensShelf(at: NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0 { self.open() }
                }
                openWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        case .open:
            // The chosen card left the shelf (its button, the menu, the shelf cleared): nothing holds the keyboard.
            if !model.selectedItemIDs.isEmpty { pruneSelection() }
            // The end of a drag does not always reach the island (the mouse up that ends a card's way out of
            // the shelf never gets to the monitors): no button held, no drag.
            if NSEvent.pressedMouseButtons == 0 {
                draggingFromShelf = false
                if model.dragOver { model.dragOver = false }
                if model.dropTargeted { model.dropTargeted = false }
            }
            let keep = shapeRect(.open).insetBy(dx: -18, dy: -18).contains(mouse)
            if keep { waitingForPointer = false }
            let busy = menuTracking || draggingFromShelf || model.dropTargeted || waitingForPointer
                || (NSEvent.pressedMouseButtons != 0 && keep)
            if keep || busy {
                closeWork?.cancel()
                closeWork = nil
            } else if closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    if !self.menuTracking, !self.draggingFromShelf,
                       !self.shapeRect(.open).insetBy(dx: -18, dy: -18).contains(NSEvent.mouseLocation) {
                        self.close()
                    }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }
    }

    /// Mouse events reach the panel only over the island itself; everywhere else they go to the windows
    /// below, as if the panel were not there.
    private func updateMouseHandling(_ mouse: NSPoint) {
        guard let panel else { return }
        let active: Bool
        switch model.state {
        case .closed: active = !Prefs.islandOpenOnHover && hotRect.contains(mouse)
        default: active = shapeRect(model.state).insetBy(dx: -2, dy: -2).contains(mouse)
        }
        if panel.ignoresMouseEvents == active { panel.ignoresMouseEvents = !active }
    }

    /// Files, text or a picture from another app are being dragged; not a shelf card, a window or a selection.
    private var isExternalDrag: Bool {
        guard !draggingFromShelf else { return false }
        let pasteboard = NSPasteboard(name: .drag)
        return pasteboard.changeCount != dragCountAtMouseDown && Shelf.canTake(pasteboard)
    }

    // MARK: - Dragging out

    /// The panel's mouse events, before SwiftUI sees them: a card pressed and moved a few points leaves the
    /// shelf as an AppKit drag. SwiftUI's own drag would hand other apps a copy of a file from its cache;
    /// this one gives them the file itself (or the text) and says when the drag is over.
    private func panelMouse(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            pressedCard = model.hoveredItemID.flatMap { id in Shelf.shared.items.first { $0.id == id } }.map { ($0, event) }
            // A click on the island off the cards lets go of the chosen one, and of the keyboard.
            if pressedCard == nil { deselect() }
        case .leftMouseDragged:
            guard let pressed = pressedCard else { return false }
            let a = pressed.event.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) >= 4 else { return false }
            pressedCard = nil
            beginDrag(pressed.item, from: pressed.event)
            return true
        case .leftMouseUp:
            pressedCard = nil
        default:
            break
        }
        return false
    }

    /// A card chosen together with others takes them all along: the pressed one under the pointer, two more fanned out
    /// behind it, the rest without a picture of their own.
    private func beginDrag(_ item: ShelfItem, from event: NSEvent) {
        guard let view = panel?.contentView else { return }
        let cards = [item] + batch(for: item).filter { $0.id != item.id }
        let point = view.convert(event.locationInWindow, from: nil)
        var draggingItems: [NSDraggingItem] = []
        var frame = NSRect.zero
        for card in cards {
            let writer: NSPasteboardWriting
            if card.kind == .text {
                guard let text = Shelf.text(of: card) else { continue }
                writer = text as NSString
            } else {
                writer = card.url as NSURL
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let shown = draggingItems.count
            if shown < 3 {
                let renderer = ImageRenderer(content: ShelfDragPreview(item: card, thumbnail: Shelf.shared.thumbnails[card.id],
                                                                       text: Shelf.shared.texts[card.id]))
                renderer.scale = view.window?.backingScaleFactor ?? 2
                let image = renderer.nsImage ?? NSWorkspace.shared.icon(forFile: card.url.path)
                let step = CGFloat(shown) * 8
                frame = NSRect(x: point.x - image.size.width / 2 + step, y: point.y - image.size.height / 2 - step,
                               width: image.size.width, height: image.size.height)
                draggingItem.setDraggingFrame(frame, contents: image)
            } else {
                draggingItem.setDraggingFrame(frame, contents: nil)
            }
            draggingItems.append(draggingItem)
        }
        guard !draggingItems.isEmpty else { return }
        draggingFromShelf = true
        // The card is on its way into another app: the keyboard goes back there too.
        deselect()
        view.beginDraggingSession(with: draggingItems, event: event, source: dragSource)
    }

    /// While the island is not closed, checks the pointer a few times a second: over the panel itself the
    /// global monitor sees nothing.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.state == .closed {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    return
                }
                self.evaluate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Keyboard

    // The island panel never becomes key: it stays on screen, so it would keep the keyboard after the shelf
    // closes. A separate invisible panel takes it, and only after a click on a card: pointing at the shelf, or
    // leaving the pointer there, never takes the keyboard from the app being typed in. Esc, a click elsewhere
    // or the shelf closing order the panel out, which hands the keyboard back to that app.

    /// A click on a card chooses it alone. With ⌘ it joins the chosen cards or leaves them; with ⇧ the cards from the
    /// one chosen last up to it join, as in Finder.
    func select(_ item: ShelfItem) {
        let items = Shelf.shared.items
        let flags = NSEvent.modifierFlags.intersection([.command, .shift])
        if flags.contains(.shift), let anchor = model.selectedItemID,
           let from = items.firstIndex(where: { $0.id == anchor }), let to = items.firstIndex(where: { $0.id == item.id }) {
            model.selectedItemIDs.formUnion(items[min(from, to)...max(from, to)].map(\.id))
        } else if flags.contains(.command), model.isSelected(item.id) {
            model.selectedItemIDs.remove(item.id)
            pruneSelection()
            return
        } else if flags.contains(.command) {
            model.selectedItemIDs.insert(item.id)
            model.selectedItemID = item.id
        } else {
            model.selectedItemIDs = [item.id]
            model.selectedItemID = item.id
        }
        takeKeyboard()
    }

    /// Every picture on the shelf, chosen together (⌘A, the card's menu).
    func selectAllPictures() {
        let pictures = Shelf.shared.items.filter { $0.kind == .image }
        guard let first = pictures.first else { return }
        model.selectedItemIDs = Set(pictures.map(\.id))
        if !pictures.contains(where: { $0.id == model.selectedItemID }) { model.selectedItemID = first.id }
        takeKeyboard()
    }

    /// The chosen cards in the shelf's order when `item` is one of several chosen; otherwise `item` alone.
    func batch(for item: ShelfItem) -> [ShelfItem] {
        guard model.selectedItemIDs.count > 1, model.isSelected(item.id) else { return [item] }
        return Shelf.shared.items.filter { model.isSelected($0.id) }
    }

    /// Cards that left the shelf (their button, the menu, the shelf cleared) are no longer chosen; with none left,
    /// nothing holds the keyboard.
    private func pruneSelection() {
        let items = Shelf.shared.items
        let kept = model.selectedItemIDs.intersection(items.map(\.id))
        guard let first = items.first(where: { kept.contains($0.id) }) else {
            deselect()
            return
        }
        if kept != model.selectedItemIDs { model.selectedItemIDs = kept }
        if let id = model.selectedItemID, kept.contains(id) { return }
        model.selectedItemID = first.id
    }

    private func takeKeyboard() {
        let keyPanel = self.keyPanel ?? IslandKeyPanel()
        keyPanel.onKey = { [weak self] event in self?.key(event) ?? true }
        // Another app took the keyboard (⌘⇥, a click into its window): the card is no longer chosen.
        keyPanel.onResignKey = { [weak self] in
            guard let self, self.model.selectedItemID != nil else { return }
            self.deselect()
        }
        self.keyPanel = keyPanel
        keyPanel.setFrameOrigin(NSPoint(x: centerX, y: top - 1))
        keyPanel.orderFrontRegardless()
        keyPanel.makeKey()
    }

    private func deselect() {
        model.selectedItemID = nil
        model.selectedItemIDs = []
        keyPanel?.orderOut(nil)
    }

    /// ⌘C copies the chosen cards, ⌘A chooses every picture, ⌫ takes the chosen cards away the way their quick buttons
    /// do, the arrows choose the card next to the last one, Return opens it as a double click does, Esc lets go. Every
    /// other key is swallowed: ⌘Q or ⌘W must not reach this app's menu.
    private func key(_ event: NSEvent) -> Bool {
        let items = Shelf.shared.items
        guard let id = model.selectedItemID, let index = items.firstIndex(where: { $0.id == id }) else {
            deselect()
            return true
        }
        let item = items[index]
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(event.keyCode)
        if flags == .command, Self.isKey(event, "c", kVK_ANSI_C) {
            actions?.copy(item)
        } else if flags == .command, Self.isKey(event, "a", kVK_ANSI_A) {
            selectAllPictures()
        } else if flags.isEmpty, code == kVK_Delete || code == kVK_ForwardDelete {
            let chosen = batch(for: item)
            deselect()
            for card in chosen {
                if card.isCapture { actions?.trash(card) } else { actions?.remove(card) }
            }
        } else if flags.isEmpty, code == kVK_LeftArrow || code == kVK_RightArrow {
            let next = index + (code == kVK_LeftArrow ? -1 : 1)
            if items.indices.contains(next) {
                model.selectedItemID = items[next].id
                model.selectedItemIDs = [items[next].id]
            }
        } else if flags.isEmpty, code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            deselect()
            if item.kind == .image { actions?.edit(item) } else { actions?.open(item) }
        } else if flags.isEmpty, code == kVK_Escape {
            deselect()
        }
        return true
    }

    /// A letter key: by its letter, or by its place with a non-Latin layout.
    private static func isKey(_ event: NSEvent, _ letter: String, _ code: Int) -> Bool {
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.unicodeScalars.allSatisfy(\.isASCII) {
            return chars == letter
        }
        return Int(event.keyCode) == code
    }

    // MARK: - Dropping

    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let takes = !draggingFromShelf && Shelf.canTake(info.draggingPasteboard)
        if takes, model.state != .open { open() }
        if model.dropTargeted != takes { model.dropTargeted = takes }
        // A folder: onto the shelf left of the notch's middle, into a moodboard right of it.
        let folder = takes && !folders(in: info).isEmpty
        if model.dropFolder != folder { model.dropFolder = folder }
        if folder {
            let zone: IslandDropZone = NSEvent.mouseLocation.x < centerX ? .shelf : .moodboard
            if model.dropZone != zone { model.dropZone = zone }
        }
        // In or out: a card on its way out of the shelf grows the island too, until it leaves.
        if !model.dragOver { model.dragOver = true }
        return takes ? .copy : []
    }

    func dragExited() {
        if model.dropTargeted { model.dropTargeted = false }
        if model.dropFolder { model.dropFolder = false }
        if model.dragOver { model.dragOver = false }
    }

    func drop(_ info: NSDraggingInfo) -> Bool {
        let moodboard = model.dropFolder && model.dropZone == .moodboard
        model.dropTargeted = false
        model.dragOver = false
        model.dropFolder = false
        guard !draggingFromShelf, Shelf.canTake(info.draggingPasteboard) else { return false }
        if moodboard {
            let folders = folders(in: info)
            if !folders.isEmpty {
                actions?.moodboard(folders)
                return true
            }
        }
        receiving += 1
        Shelf.shared.add(from: info.draggingPasteboard) { [weak self] items in
            guard let self else { return }
            self.receiving -= 1
            if let first = items.first {
                SoundEffects.play(.added)
                self.flashCard(first.id)
            } else {
                SoundEffects.play(.failure)
                self.notify(L("Не удалось положить на полку"), symbol: "exclamationmark.triangle.fill")
            }
        }
        return true
    }
}

extension IslandController {
    /// The folders a drag brings when it brings nothing else (packages such as Keynote documents are files).
    fileprivate func folders(in info: NSDraggingInfo) -> [URL] {
        if dragFolders.sequence == info.draggingSequenceNumber { return dragFolders.folders }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let folders = !urls.isEmpty && urls.allSatisfy(Self.isFolder) ? urls : []
        dragFolders = (info.draggingSequenceNumber, folders)
        return folders
    }

    nonisolated static func isFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }
}

/// What the island's hosting view asks while something is dragged over it.
@MainActor
protocol IslandDropTarget: AnyObject {
    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation
    func dragExited()
    func drop(_ info: NSDraggingInfo) -> Bool
}

/// Borderless panel above the menu bar that never takes focus from the app being worked in.
final class IslandPanel: NSPanel {
    /// Sees the panel's mouse events first; true for the ones it handled.
    var mouseFilter: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if mouseFilter?(event) == true { return }
        super.sendEvent(event)
    }
}

/// A card's way out of the shelf. Copy only: a move would take a file away from where the shelf keeps it.
final class ShelfDragSource: NSObject, NSDraggingSource {
    var onEnd: (() -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd?()
    }
}

/// Invisible, and key only while a shelf card is chosen (see `IslandController.select`). Being a non-activating
/// panel, it takes the keyboard without bringing this app to the front.
final class IslandKeyPanel: NSPanel {
    /// Gets every key pressed while the panel is key; returns whether it was handled.
    var onKey: ((NSEvent) -> Bool)?
    /// The keyboard went elsewhere.
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKey?(event) ?? super.performKeyEquivalent(with: event)
    }

    /// Keys go to `onKey` and no further: a key window with no one to take a key would beep.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown: _ = onKey?(event)
        case .keyUp: break
        default: super.sendEvent(event)
        }
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Clicks work at once although the panel is never the key window. Files, text and pictures dragged from
/// other apps are dropped onto it.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    weak var dropTarget: IslandDropTarget?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget?.dragExited()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropTarget?.dragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.drop(sender) ?? false
    }
}
