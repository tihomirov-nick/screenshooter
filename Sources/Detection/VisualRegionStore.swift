import CoreGraphics
import Foundation
import ScreenSegmenter
import ShotCore

/// Pixel analysis of the windows of the frozen screen, started as soon as the capture starts: shapes for
/// the front windows, text blocks (Vision) for the first few and for any window the cursor visits.
/// Results arrive in the background and `onUpdate` tells the overlay to ask again.
public final class VisualRegionStore: @unchecked Sendable {
    public struct Options: Sendable {
        public var shapes = true
        public var text = true
        public init() {}
    }

    /// Called on the main queue when regions of some window became available.
    public var onUpdate: (() -> Void)?

    private let displays: [DisplaySnapshot]
    private let options: Options
    private let lock = NSLock()
    private var found: [CGWindowID: [Region]] = [:]
    private var started: Set<String> = []
    private var cancelled = false
    private let shapeQueue = DispatchQueue(label: "Screenshooter.VisualRegions", qos: .userInitiated,
                                          attributes: .concurrent)
    private let textQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    public init(displays: [DisplaySnapshot], options: Options = .init()) {
        self.displays = displays
        self.options = options
    }

    /// Starts the analysis of the front-most windows: shapes for many, text for the first few.
    public func prepare(_ windows: [WindowInfo]) {
        let candidates = windows.filter { $0.frame.width >= 60 && $0.frame.height >= 40 }
        if options.shapes {
            candidates.prefix(16).forEach { analyze($0, text: false) }
        }
        if options.text {
            candidates.prefix(4).forEach { analyze($0, text: true) }
        }
    }

    /// Starts text analysis of a window the cursor is over (no-op when started already).
    public func focus(on window: WindowInfo) {
        guard options.text else { return }
        analyze(window, text: true)
    }

    /// Regions found so far in the window, in screen space.
    public func regions(for window: WindowInfo) -> [Region] {
        lock.lock(); defer { lock.unlock() }
        return found[window.id] ?? []
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        textQueue.cancelAllOperations()
    }

    private func analyze(_ window: WindowInfo, text: Bool) {
        let key = "\(window.id)-\(text)"
        lock.lock()
        let fresh = started.insert(key).inserted && !cancelled
        lock.unlock()
        guard fresh, let display = displays.best(for: window.frame) else { return }

        let visible = window.frame.intersection(display.frame)
        let pixels = display.pixelRect(of: visible)
        guard !pixels.isNull, pixels.width >= 32, pixels.height >= 32,
              let crop = display.image.cropping(to: pixels) else { return }
        let scale = display.scale

        let work = { [weak self] in
            let raw = text ? TextBlockDetector.detect(crop, pixelScale: scale)
                           : VisualSegmenter().segment(crop, pixelScale: scale)
            let regions = raw.map { region -> Region in
                let rect = display.screenRect(ofPixels: region.rect.offsetBy(dx: pixels.minX, dy: pixels.minY))
                return Region(rect: rect.intersection(visible), source: text ? .text : .visual,
                              title: Self.title(region.kind))
            }
            self?.store(regions, for: window.id)
        }
        if text {
            textQueue.addOperation(work)
        } else {
            shapeQueue.async(execute: work)
        }
    }

    private func store(_ regions: [Region], for windowID: CGWindowID) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        found[windowID, default: []].append(contentsOf: regions)
        lock.unlock()
        guard !regions.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    }

    static func title(_ kind: VisualRegion.Kind) -> String {
        switch kind {
        case .panel: return L("Панель")
        case .box: return L("Блок")
        case .textBlock: return L("Текст")
        }
    }
}
