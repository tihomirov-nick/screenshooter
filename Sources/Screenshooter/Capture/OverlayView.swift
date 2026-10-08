import AppKit
import Detection
import QuartzCore
import ShotCore

/// What every overlay draws; each one draws the part that falls on its display.
struct OverlayState {
    /// Screen space. Nil before the first region is known.
    var highlight: CGRect?
    var title = ""
    /// "420 × 86"
    var detail = ""
    /// "2/5": the level in the chain.
    var level = ""
    /// A rectangle is being dragged by hand.
    var manual = false
    var pointer: CGPoint = .zero
    var showLoupe = false
    var hint = ""
}

/// Full-screen panel over one display during a capture. It shows the frozen screen, so what the user
/// selects is exactly what gets saved.
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    weak var session: CaptureSession?
    let snapshot: DisplaySnapshot

    private let root = CALayer()
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let labelLayer = CALayer()
    private let labelText = CATextLayer()
    private let hintLayer = CALayer()
    private let hintText = CATextLayer()
    private let loupeLayer = CALayer()
    private let loupeImage = CALayer()
    private let loupeCross = CAShapeLayer()
    private let loupeRing = CAShapeLayer()

    private var lastHole: CGRect?

    private static let accent = NSColor(srgbRed: 0.18, green: 0.52, blue: 1, alpha: 1).cgColor
    private static let loupeSize: CGFloat = 120
    private static let loupeZoom: CGFloat = 8

    init(snapshot: DisplaySnapshot, backingScale: CGFloat) {
        self.snapshot = snapshot
        super.init(frame: NSRect(origin: .zero, size: snapshot.frame.size))
        layer = root
        wantsLayer = true
        root.frame = bounds
        root.backgroundColor = .black

        for l in [root, imageLayer, dimLayer, borderLayer, labelLayer, labelText, hintLayer, hintText, loupeLayer,
                  loupeImage, loupeCross, loupeRing] {
            l.contentsScale = backingScale
        }

        imageLayer.frame = bounds
        imageLayer.contents = snapshot.image
        imageLayer.contentsGravity = .resize
        root.addSublayer(imageLayer)

        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        dimLayer.path = dimPath(hole: nil)
        root.addSublayer(dimLayer)

        borderLayer.frame = bounds
        borderLayer.fillColor = nil
        borderLayer.strokeColor = Self.accent
        borderLayer.lineWidth = 2
        borderLayer.shadowColor = Self.accent
        borderLayer.shadowOpacity = 0.7
        borderLayer.shadowRadius = 5
        borderLayer.shadowOffset = .zero
        borderLayer.opacity = 0
        root.addSublayer(borderLayer)

        labelLayer.backgroundColor = Self.accent
        labelLayer.cornerRadius = 6
        labelLayer.cornerCurve = .continuous
        labelLayer.opacity = 0
        labelLayer.shadowOpacity = 0.25
        labelLayer.shadowRadius = 3
        labelLayer.shadowOffset = CGSize(width: 0, height: -1)
        labelText.truncationMode = .end
        labelText.isWrapped = false
        labelLayer.addSublayer(labelText)
        root.addSublayer(labelLayer)

        hintLayer.backgroundColor = NSColor(white: 0.08, alpha: 0.78).cgColor
        hintLayer.cornerRadius = 10
        hintLayer.cornerCurve = .continuous
        hintLayer.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        hintLayer.borderWidth = 0.5
        hintLayer.opacity = 0
        hintText.alignmentMode = .center
        hintLayer.addSublayer(hintText)
        root.addSublayer(hintLayer)

        let size = Self.loupeSize
        loupeLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        loupeLayer.cornerRadius = size / 2
        loupeLayer.masksToBounds = true
        loupeLayer.backgroundColor = .black
        loupeLayer.opacity = 0
        loupeImage.contents = snapshot.image
        loupeImage.contentsGravity = .resize
        loupeImage.magnificationFilter = .nearest
        loupeImage.bounds = CGRect(x: 0, y: 0, width: bounds.width * Self.loupeZoom, height: bounds.height * Self.loupeZoom)
        loupeImage.anchorPoint = .zero
        loupeLayer.addSublayer(loupeImage)
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: size / 2, y: 0)); cross.addLine(to: CGPoint(x: size / 2, y: size))
        cross.move(to: CGPoint(x: 0, y: size / 2)); cross.addLine(to: CGPoint(x: size, y: size / 2))
        loupeCross.path = cross
        loupeCross.strokeColor = NSColor(srgbRed: 0.18, green: 0.52, blue: 1, alpha: 0.75).cgColor
        loupeCross.lineWidth = 1
        loupeCross.frame = loupeLayer.bounds
        loupeLayer.addSublayer(loupeCross)
        loupeRing.path = CGPath(ellipseIn: loupeLayer.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        loupeRing.fillColor = nil
        loupeRing.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        loupeRing.lineWidth = 2
        loupeRing.frame = loupeLayer.bounds
        loupeLayer.addSublayer(loupeRing)
        root.addSublayer(loupeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { session?.pointerMoved() }
    override func mouseDown(with event: NSEvent) { session?.pointerDown(event) }
    override func mouseDragged(with event: NSEvent) { session?.pointerDragged(event) }
    override func mouseUp(with event: NSEvent) { session?.pointerUp(event) }
    override func rightMouseDown(with event: NSEvent) { session?.cancel() }
    override func scrollWheel(with event: NSEvent) { session?.scroll(event) }
    override func keyDown(with event: NSEvent) {
        if session?.key(event) != true { super.keyDown(with: event) }
    }

    // MARK: - Drawing

    /// Screen-space rectangle in this view's layer coordinates (origin at the bottom left).
    private func local(_ r: CGRect) -> CGRect {
        let f = snapshot.frame
        return CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - snapshot.frame.minX, y: snapshot.frame.maxY - p.y)
    }

    private func dimPath(hole: CGRect?) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(hole ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0))
        return path
    }

    func update(_ state: OverlayState, animated: Bool) {
        let pointerHere = snapshot.frame.contains(state.pointer)
        let localHole = state.highlight.map { local($0).intersection(bounds) }
        let hole = (localHole?.isNull ?? true) ? nil : localHole

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        CATransaction.setDisableActions(!animated)

        // Dimming with a hole where the capture is; the hole only glides between two places on this display.
        setPath(dimPath(hole: hole), on: dimLayer, animated: animated && hole != nil && lastHole != nil)
        lastHole = hole

        // Border just outside the hole, kept inside the display when the hole touches its edges.
        if let hole {
            var ring = hole.insetBy(dx: -1.5, dy: -1.5)
            ring = ring.intersection(bounds.insetBy(dx: 1, dy: 1))
            let radius = min(4, ring.width / 2, ring.height / 2)
            setPath(CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil),
                    on: borderLayer, animated: animated && borderLayer.opacity > 0)
            borderLayer.opacity = 1
            borderLayer.lineDashPattern = state.manual ? [6, 4] : nil
        } else {
            borderLayer.opacity = 0
        }

        // Label at the top left corner of the highlight, on the display with the pointer.
        if let hole, pointerHere, !state.title.isEmpty || !state.detail.isEmpty {
            let text = labelString(state)
            let textSize = text.size()
            let size = CGSize(width: min(ceil(textSize.width) + 16, bounds.width - 12), height: ceil(textSize.height) + 8)
            var origin = CGPoint(x: hole.minX, y: hole.maxY + 6)
            if origin.y + size.height > bounds.maxY - 4 { origin.y = hole.minY - size.height - 6 }
            if origin.y < 4 { origin.y = min(hole.maxY, bounds.maxY) - size.height - 6 }
            origin.x = min(max(origin.x, 6), bounds.maxX - size.width - 6)
            labelLayer.frame = CGRect(origin: origin, size: size)
            labelText.string = text
            labelText.frame = CGRect(x: 8, y: 4, width: size.width - 16, height: ceil(textSize.height))
            labelLayer.opacity = 1
        } else {
            labelLayer.opacity = 0
        }

        // Hint at the bottom of the display with the pointer.
        if pointerHere, !state.hint.isEmpty, !state.manual {
            let text = NSAttributedString(string: state.hint, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ])
            let textSize = text.size()
            let size = CGSize(width: ceil(textSize.width) + 28, height: ceil(textSize.height) + 14)
            hintLayer.frame = CGRect(x: (bounds.width - size.width) / 2, y: 36, width: size.width, height: size.height)
            hintText.string = text
            hintText.frame = CGRect(x: 14, y: 7, width: size.width - 28, height: ceil(textSize.height))
            hintLayer.opacity = 1
        } else {
            hintLayer.opacity = 0
        }

        // Magnifier for precise manual selection.
        if pointerHere, state.showLoupe {
            CATransaction.setDisableActions(true)
            let p = local(state.pointer)
            let size = Self.loupeSize
            var center = CGPoint(x: p.x + 26 + size / 2, y: p.y - 26 - size / 2)
            if center.x + size / 2 > bounds.maxX - 4 { center.x = p.x - 26 - size / 2 }
            if center.y - size / 2 < 4 { center.y = p.y + 26 + size / 2 }
            loupeLayer.position = center
            loupeImage.position = CGPoint(x: size / 2 - p.x * Self.loupeZoom, y: size / 2 - p.y * Self.loupeZoom)
            loupeLayer.opacity = 1
        } else {
            loupeLayer.opacity = 0
        }

        CATransaction.commit()
    }

    private func setPath(_ path: CGPath, on layer: CAShapeLayer, animated: Bool) {
        if animated, let from = layer.presentation()?.path ?? layer.path {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = from
            animation.toValue = path
            animation.duration = 0.16
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.add(animation, forKey: "path")
        } else {
            layer.removeAnimation(forKey: "path")
        }
        layer.path = path
    }

    private func labelString(_ state: OverlayState) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let light = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        if !state.title.isEmpty {
            result.append(NSAttributedString(string: state.title, attributes: [.font: font, .foregroundColor: NSColor.white]))
        }
        if !state.detail.isEmpty {
            let separator = result.length > 0 ? "   " : ""
            result.append(NSAttributedString(string: separator + state.detail, attributes: [
                .font: light, .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]))
        }
        if !state.level.isEmpty {
            result.append(NSAttributedString(string: "   " + state.level, attributes: [
                .font: light, .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            ]))
        }
        return result
    }
}
