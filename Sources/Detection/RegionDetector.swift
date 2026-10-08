import AppKit
import ShotCore

/// Finds the regions under the cursor on the frozen screen: the display, its menu bar, the window,
/// the window's accessibility elements and the boxes found in its pixels.
public final class RegionDetector: @unchecked Sendable {
    public struct Options: Sendable {
        /// Accessibility elements (needs the accessibility permission).
        public var elements = true
        /// Panels and boxes found in the pixels.
        public var shapes = true
        /// Text blocks found by Vision.
        public var text = true
        public init() {}
    }

    public let displays: [DisplaySnapshot]
    public let windows: [WindowInfo]
    public let options: Options

    /// Called on the main queue when more regions became known (pixel analysis finished for a window);
    /// the overlay asks for the chain under the cursor again.
    public var onUpdate: (() -> Void)?

    private let accessibility = AccessibilityRegions()
    private let visual: VisualRegionStore
    private let menuBars: [CGRect]
    private let queue = DispatchQueue(label: "Screenshooter.RegionDetector", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (CGPoint, (CGPoint, [Region]) -> Void)?
    private var running = false

    /// Create on the main thread (reads NSScreen).
    public init(displays: [DisplaySnapshot], windows: [WindowInfo], options: Options = .init()) {
        self.displays = displays
        self.windows = windows
        self.options = options
        var visualOptions = VisualRegionStore.Options()
        visualOptions.shapes = options.shapes
        visualOptions.text = options.text
        visual = VisualRegionStore(displays: displays, options: visualOptions)
        menuBars = NSScreen.screens.map { screen in
            let frame = screen.screenSpaceFrame
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: screen.menuBarHeight)
        }
        visual.onUpdate = { [weak self] in self?.onUpdate?() }
        visual.prepare(windows)
    }

    /// Computes the chain at `point` (screen space) in the background and calls `completion` on the main
    /// queue. A request made while another one runs replaces any request still waiting, so a fast-moving
    /// cursor only costs the latest position.
    public func chain(at point: CGPoint, completion: @escaping (CGPoint, [Region]) -> Void) {
        lock.lock()
        pending = (point, completion)
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }

    /// The same chain, computed on the calling thread.
    public func chainSync(at point: CGPoint) -> [Region] {
        queue.sync { compute(at: point) }
    }

    /// The front-most window at the point.
    public func window(at point: CGPoint) -> WindowInfo? {
        WindowList.window(at: point, in: windows)
    }

    public func cancel() {
        visual.cancel()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (point, completion) = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            let chain = compute(at: point)
            DispatchQueue.main.async { completion(point, chain) }
        }
    }

    private func compute(at point: CGPoint) -> [Region] {
        var candidates: [Region] = []
        if let display = displays.containing(point) {
            candidates.append(Region(rect: display.frame, source: .display, title: L("Весь экран")))
        }
        let menuBar = menuBars.first { $0.contains(point) }
        if let menuBar {
            candidates.append(Region(rect: menuBar, source: .menuBar, title: L("Строка меню")))
        }
        // Over the menu bar only an open menu lies above it.
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        if let window = window(at: point), menuBar == nil || window.layer > menuLevel {
            candidates.append(Region(rect: window.frame, source: .window, title: window.displayTitle,
                                     windowID: window.id))
            if options.elements {
                candidates += accessibility.regions(at: point, in: window)
            }
            candidates += visual.regions(for: window)
            visual.focus(on: window)
        }
        return RegionChain.build(at: point, from: candidates)
    }
}
