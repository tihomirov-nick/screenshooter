import AppKit
import Carbon.HIToolbox
import Detection
import ShotCore

/// What the user picked on the frozen screen.
struct CaptureSelection {
    /// Screen space.
    var rect: CGRect
    /// Nil when the rectangle was dragged by hand.
    var region: Region?
}

/// One capture on the frozen screen: the overlays, the highlighted region under the pointer, levels
/// (scroll wheel, ↑ ↓), a hand-drawn rectangle as an alternative, and the final click.
@MainActor
final class CaptureSession {
    enum Mode {
        case image
        /// Recognise text in the selection instead of saving a picture.
        case text
    }

    let mode: Mode
    let displays: [DisplaySnapshot]
    let detector: RegionDetector
    var onFinish: ((CaptureSelection?) -> Void)?

    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    private var monitors: [Any] = []
    private var finished = false

    /// Regions under the pointer, smallest first, and the highlighted one.
    private var chain: [Region] = []
    private var level = 0
    /// A level the user chose by hand stays while it is still under the pointer.
    private var stickyRect: CGRect?
    private var chainPoint: CGPoint?
    private var pointer: CGPoint = .zero
    private var pointerDisplay: CGDirectDisplayID?

    private var dragOrigin: CGPoint?
    private var dragRect: CGRect?
    private var scrollAccumulator: CGFloat = 0

    init(mode: Mode, displays: [DisplaySnapshot], detector: RegionDetector) {
        self.mode = mode
        self.displays = displays
        self.detector = detector
    }

    private var current: Region? { chain.indices.contains(level) ? chain[level] : nil }

    // MARK: - Start and end

    func begin() {
        for snapshot in displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == snapshot.displayID }) else { continue }
            let panel = OverlayPanel(frame: screen.frame)
            let view = OverlayView(snapshot: snapshot, backingScale: screen.backingScaleFactor)
            view.session = self
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }
        guard !panels.isEmpty else {
            end(nil)
            return
        }
        detector.onUpdate = { [weak self] in self?.requestChain() }

        pointer = ScreenGeometry.mouseLocation
        pointerDisplay = displays.containing(pointer)?.displayID
        render(animated: false)
        panels.forEach { $0.orderFrontRegardless() }
        let keyPanel = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels[0]
        keyPanel.makeKey()
        keyPanel.makeFirstResponder(keyPanel.contentView)
        CursorControl.allowInBackground()
        NSCursor.crosshair.set()
        installKeyMonitors()
        requestChain()
        Log.capture.info("begin: \(self.panels.count) overlays, key \(keyPanel.isKeyWindow), app active \(NSApp.isActive)")
    }

    func cancel() {
        end(nil)
    }

    private func finish(_ selection: CaptureSelection) {
        end(selection)
    }

    private func end(_ selection: CaptureSelection?) {
        guard !finished else { return }
        finished = true
        Log.capture.info("end: \(selection.map { "\($0.rect) \($0.region?.source.rawValue ?? "manual")" } ?? "cancelled", privacy: .public)")
        detector.onUpdate = nil
        detector.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panels.forEach { $0.orderOut(nil) }
        NSCursor.arrow.set()
        let callback = onFinish
        onFinish = nil
        callback?(selection)
        // Let AppKit finish with the events in flight before the views go away.
        DispatchQueue.main.async { [panels, views] in _ = (panels, views) }
        panels.removeAll()
        views.removeAll()
    }

    /// Keys reach the overlay when it is the key window; the global monitor (it needs the accessibility
    /// permission) covers the case when macOS keeps the keyboard with the app underneath.
    private func installKeyMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.key(event) } ? nil : event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.key(event) }
        }) {
            monitors.append(global)
        }
    }

    // MARK: - Pointer

    func pointerMoved() {
        guard !finished else { return }
        pointer = ScreenGeometry.mouseLocation
        NSCursor.crosshair.set()
        guard dragOrigin == nil else { return }
        let display = displays.containing(pointer)?.displayID
        if display != pointerDisplay {
            pointerDisplay = display
            render(animated: false)
        }
        requestChain()
    }

    func pointerDown(_ event: NSEvent) {
        pointer = ScreenGeometry.mouseLocation
        Log.capture.debug("down at \(self.pointer.x), \(self.pointer.y)")
        dragOrigin = pointer
        dragRect = nil
    }

    func pointerDragged(_ event: NSEvent) {
        guard let origin = dragOrigin, !finished else { return }
        pointer = ScreenGeometry.mouseLocation
        if dragRect == nil, hypot(pointer.x - origin.x, pointer.y - origin.y) < 4 { return }

        var p = pointer
        let display = displays.containing(origin)
        if let frame = display?.frame {
            p.x = min(max(p.x, frame.minX), frame.maxX)
            p.y = min(max(p.y, frame.minY), frame.maxY)
        }
        var w = abs(p.x - origin.x), h = abs(p.y - origin.y)
        if event.modifierFlags.contains(.shift) {
            w = max(w, h)
            h = w
        }
        var rect = CGRect(x: p.x < origin.x ? origin.x - w : origin.x, y: p.y < origin.y ? origin.y - h : origin.y,
                          width: w, height: h)
        // Whole pixels, so the saved image has exactly the size shown.
        let scale = display?.scale ?? 2
        rect = CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
                      width: (rect.width * scale).rounded() / scale, height: (rect.height * scale).rounded() / scale)
        if let frame = display?.frame { rect = rect.intersection(frame) }
        dragRect = rect
        render(animated: false)
    }

    func pointerUp(_ event: NSEvent) {
        defer { dragOrigin = nil }
        if let rect = dragRect {
            if rect.width >= 3, rect.height >= 3 {
                finish(CaptureSelection(rect: rect, region: nil))
            } else {
                dragRect = nil
                render(animated: false)
            }
            return
        }
        captureHighlighted()
    }

    func scroll(_ event: NSEvent) {
        Log.capture.debug("scroll \(event.scrollingDeltaY) precise \(event.hasPreciseScrollingDeltas) phase \(event.phase.rawValue) momentum \(event.momentumPhase.rawValue)")
        guard dragRect == nil, event.momentumPhase.isEmpty else { return }
        var delta = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }
        // A mouse wheel: every notch is one level.
        if !event.hasPreciseScrollingDeltas {
            if delta != 0 { changeLevel(by: delta > 0 ? 1 : -1) }
            return
        }
        // A trackpad: a level per stretch of the swipe.
        if event.phase == .began { scrollAccumulator = 0 }
        scrollAccumulator += delta
        let step: CGFloat = 18
        while scrollAccumulator >= step {
            scrollAccumulator -= step
            changeLevel(by: 1)
        }
        while scrollAccumulator <= -step {
            scrollAccumulator += step
            changeLevel(by: -1)
        }
    }

    /// True when the key was used.
    func key(_ event: NSEvent) -> Bool {
        guard !finished else { return false }
        Log.capture.info("key \(event.keyCode)")
        switch Int(event.keyCode) {
        case kVK_Escape:
            if dragRect != nil {
                dragRect = nil
                dragOrigin = nil
                render(animated: false)
            } else {
                cancel()
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let rect = dragRect {
                finish(CaptureSelection(rect: rect, region: nil))
            } else {
                captureHighlighted()
            }
        case kVK_UpArrow:
            changeLevel(by: 1)
        case kVK_DownArrow:
            changeLevel(by: -1)
        case kVK_Space:
            if let window = chain.firstIndex(where: { $0.source == .window }) {
                select(level == window ? RegionChain.defaultIndex(in: chain) : window)
            }
        case kVK_ANSI_F:
            if let display = chain.firstIndex(where: { $0.source == .display }) { select(display) }
        default:
            return false
        }
        return true
    }

    // MARK: - Regions

    private func requestChain() {
        guard !finished else { return }
        detector.chain(at: pointer) { [weak self] point, chain in
            self?.apply(chain, at: point)
        }
    }

    private func apply(_ newChain: [Region], at point: CGPoint) {
        guard !finished, dragRect == nil else { return }
        let before = current
        let beforeCount = chain.count
        chain = newChain
        chainPoint = point
        if let sticky = stickyRect,
           let i = newChain.firstIndex(where: { $0.rect.isClose(to: sticky, tolerance: 4) || $0.rect.iou(sticky) > 0.92 }) {
            level = i
        } else {
            stickyRect = nil
            level = RegionChain.defaultIndex(in: newChain)
        }
        if let current {
            Log.capture.debug("chain at \(point.x), \(point.y): \(self.level + 1)/\(newChain.count) \(current.source.rawValue, privacy: .public) \(current.rect.debugDescription, privacy: .public)")
        }
        if current?.rect != before?.rect || current?.title != before?.title {
            render(animated: before != nil)
        } else if chain.count != beforeCount {
            render(animated: false)
        }
    }

    private func changeLevel(by delta: Int) {
        guard !chain.isEmpty else { return }
        select(min(max(level + delta, 0), chain.count - 1))
    }

    private func select(_ index: Int) {
        Log.capture.debug("select \(index) of \(self.chain.count), now \(self.level)")
        guard chain.indices.contains(index), index != level else { return }
        level = index
        stickyRect = chain[index].rect
        render(animated: true)
    }

    private func captureHighlighted() {
        // The pointer moved since the chain was computed (or nothing is known yet): ask right now.
        if current == nil || chainPoint.map({ hypot($0.x - pointer.x, $0.y - pointer.y) > 24 }) ?? true {
            apply(detector.chainSync(at: pointer), at: pointer)
        }
        guard let region = current else {
            cancel()
            return
        }
        finish(CaptureSelection(rect: region.rect, region: region))
    }

    // MARK: - Drawing

    private func render(animated: Bool) {
        var state = OverlayState()
        state.pointer = pointer
        if let rect = dragRect {
            state.highlight = rect
            state.manual = true
            state.detail = Self.sizeText(rect)
            state.showLoupe = Prefs.showMagnifier
        } else if let region = current {
            state.highlight = region.rect
            state.title = region.title
            state.detail = Self.sizeText(region.rect.intersection(displays.best(for: region.rect)?.frame ?? region.rect))
            state.level = chain.count > 1 ? "\(level + 1)/\(chain.count)" : ""
        }
        if Prefs.showHints {
            state.hint = mode == .text
                ? L("Распознать текст: клик по области или выделение  ·  ↑ ↓ или колесо — уровень  ·  Esc — отмена")
                : L("Клик — снимок  ·  Перетащите — своя область  ·  ↑ ↓ или колесо — меньше/больше  ·  Пробел — окно  ·  Esc — отмена")
        }
        views.forEach { $0.update(state, animated: animated) }
    }

    static func sizeText(_ rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }
}

/// Lets the crosshair stay while another app is active (the overlay never activates this app).
enum CursorControl {
    private static var done = false

    static func allowInBackground() {
        guard !done else { return }
        done = true
        typealias ConnectionFunction = @convention(c) () -> Int32
        typealias SetPropertyFunction = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connectionSymbol = dlsym(everywhere, "_CGSDefaultConnection"),
              let setSymbol = dlsym(everywhere, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connectionSymbol, to: ConnectionFunction.self)()
        _ = unsafeBitCast(setSymbol, to: SetPropertyFunction.self)(connection, connection,
                                                                  "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
