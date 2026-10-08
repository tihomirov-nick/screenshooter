import AppKit
import ShotCore

/// A thumbnail in the toolbar that drags the edited image out as a file.
final class DragOutView: NSView, NSDraggingSource {
    var thumbnail: NSImage? {
        didSet { needsDisplay = true }
    }
    /// Writes the current image to a file and returns it; called when a drag starts.
    var fileProvider: (() -> URL?)?
    private var mouseDownEvent: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = L("Перетащите снимок в другое приложение или в Finder")
        setAccessibilityLabel(L("Перетащить снимок"))
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 28) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var imageRect: NSRect {
        let box = bounds.insetBy(dx: 4, dy: 3)
        guard let size = thumbnail?.size, size.width > 0, size.height > 0 else { return box }
        let k = min(box.width / size.width, box.height / size.height)
        let w = size.width * k, h = size.height * k
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = imageRect
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let thumbnail {
            // The canvas colour: transparent corners and a window shadow stay off the light toolbar.
            NSColor(white: 0.13, alpha: 1).setFill()
            rect.fill()
            thumbnail.draw(in: rect)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        mouseDownEvent = nil
        guard let url = fileProvider?() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageRect, contents: thumbnail)
        beginDraggingSession(with: [item], event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
