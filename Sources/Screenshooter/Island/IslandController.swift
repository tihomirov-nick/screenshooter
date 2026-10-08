import AppKit
import ShotCore
import SwiftUI

/// The panel at the top of the screen that grows out of the notch: it shows each new capture for a
/// moment, opens into the shelf when the pointer comes to the notch, and takes images dropped onto it.
@MainActor
final class IslandController {
    static let shared = IslandController()

    let model = IslandModel()
    var actions: IslandActions?

    private var panel: IslandPanel?
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

    // MARK: - Lifecycle

    func start() {
        guard panel == nil, Prefs.islandEnabled, let actions else { return }
        let panel = IslandPanel()
        let root = IslandRootView(model: model, shelf: Shelf.shared, actions: actions)
        let hosting = IslandHostingView(rootView: root)
        hosting.sizingOptions = []
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
            MainActor.assumeIsolated { self?.layout() }
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
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.orderFrontRegardless() }
        })
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

    /// A short confirmation: in the header of the open shelf, or under the notch.
    func notify(_ text: String, symbol: String = "checkmark.circle.fill") {
        guard panel != nil else { return }
        if model.state == .open {
            model.toast = text
            toastWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.model.toast = nil }
            toastWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
            return
        }
        model.bannerText = text
        model.bannerSymbol = symbol
        setState(.banner, revertAfter: 1.9)
    }

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
        evaluate()
    }

    private func setState(_ state: IslandState, revertAfter delay: TimeInterval? = nil) {
        stateWork?.cancel()
        model.state = state
        if state != .closed { startPolling() }
        if let delay {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.state == state else { return }
                if self.isPointerOverIsland { self.open() } else { self.setState(.closed) }
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

    /// The island's outline in the given state, AppKit coordinates.
    private func shapeRect(_ state: IslandState) -> NSRect {
        let size = model.metrics.size(for: state)
        return NSRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    /// Where the pointer opens the closed island: the camera housing (or the middle of the menu bar).
    private var hotRect: NSRect {
        let m = model.metrics
        return NSRect(x: centerX - m.notchWidth / 2 - 8, y: top - m.notchHeight - 3,
                      width: m.notchWidth + 16, height: m.notchHeight + 3)
    }

    private var isPointerOverIsland: Bool {
        shapeRect(model.state).insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    private func mouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            draggingFromShelf = false
        case .leftMouseDown, .rightMouseDown:
            let mouse = NSEvent.mouseLocation
            if model.state == .open {
                // A click anywhere else puts the open shelf away.
                if !shapeRect(.open).contains(mouse), !menuTracking { close() }
            } else if event.type == .leftMouseDown,
                      hotRect.contains(mouse) || (model.state != .closed && shapeRect(model.state).contains(mouse)) {
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
            let inside = hotRect.contains(mouse) || (model.state != .closed && shapeRect(model.state).contains(mouse))
            guard inside else {
                openWork?.cancel()
                openWork = nil
                return
            }
            if dragging {
                if isFileDrag { open() }
            } else if Prefs.islandOpenOnHover, openWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openWork = nil
                    let still = self.hotRect.contains(NSEvent.mouseLocation)
                        || self.shapeRect(self.model.state).contains(NSEvent.mouseLocation)
                    if still, NSEvent.pressedMouseButtons == 0 { self.open() }
                }
                openWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        case .open:
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

    /// Files from Finder (or any app) are being dragged, not one of the shelf's own cards.
    private var isFileDrag: Bool {
        guard !draggingFromShelf else { return false }
        let types = NSPasteboard(name: .drag).types ?? []
        return types.contains(.fileURL)
    }

    func shelfDragStarted() {
        draggingFromShelf = true
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
}

/// Borderless panel above the menu bar that never takes focus from the app being worked in.
final class IslandPanel: NSPanel {
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
}

/// Clicks work at once although the panel is never the key window.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
