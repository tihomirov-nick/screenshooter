import AppKit
import Carbon.HIToolbox
import Combine

/// The inline editor for text annotations. Its own glyphs are invisible: the canvas draws the text
/// with the final look (outline included) while this view handles typing, the caret and the selection.
final class InlineTextView: NSTextView {
    var onEnd: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            onEnd?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEnd?() }
    override func complete(_ sender: Any?) { onEnd?() }
}

/// Draws the annotations above the image, so editing a mark never redraws the image itself.
private final class AnnotationOverlayView: NSView {
    weak var canvas: EditorCanvasView?

    override var isFlipped: Bool { true }
    /// Clicks go through to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        canvas?.drawAnnotations()
    }
}

/// Shows the image with its annotations and turns mouse and keyboard input into edits.
/// Coordinates: the view is flipped and measured in points of the shown part of the image
/// (`model.displayRect`); annotations live in image pixels.
final class EditorCanvasView: NSView, NSTextViewDelegate {
    let model: EditorModel
    /// Called after the shown part of the image changes size (crop applied, crop tool on or off).
    var onDisplayRectChange: (() -> Void)?

    private enum Drag {
        case none
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case resizing(UUID, Handle, original: Annotation)
        case cropNew(start: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(Handle, original: CGRect)
    }

    private var drag = Drag.none
    private var mouseDownPoint = CGPoint.zero
    private var mouseDownViewPoint = CGPoint.zero
    private var didDrag = false
    private var textView: InlineTextView?
    /// Font size and color last applied to the text view, to restyle it only when they change.
    private var appliedTextStyle: (fontSize: CGFloat, color: RGBA)?
    private var lastDisplayRect = CGRect.null
    private let overlay = AnnotationOverlayView()
    private var cancellables = Set<AnyCancellable>()

    init(model: EditorModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: Self.viewSize(for: model)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layerContentsRedrawPolicy = .onSetNeedsDisplay
        overlay.canvas = self
        addSubview(overlay)
        lastDisplayRect = model.displayRect
        model.objectWillChange
            .sink { [weak self] _ in
                // objectWillChange fires before the new values are stored.
                DispatchQueue.main.async { self?.modelDidChange() }
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func viewSize(for model: EditorModel) -> NSSize {
        let r = model.displayRect
        return NSSize(width: max(r.width / model.scale, 1), height: max(r.height / model.scale, 1))
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func modelDidChange() {
        let rect = model.displayRect
        if rect != lastDisplayRect {
            lastDisplayRect = rect
            setFrameSize(Self.viewSize(for: model))
            needsDisplay = true
            onDisplayRectChange?()
        }
        if textView != nil {
            if model.editingTextID == nil || model.tool == .crop {
                commitTextEditing()
            } else {
                syncTextView()
            }
        }
        overlay.needsDisplay = true
    }

    /// Redraws everything, e.g. after the zoom changed (handles keep their size on screen).
    func refresh() {
        needsDisplay = true
        overlay.needsDisplay = true
    }

    // MARK: Coordinates

    private var region: CGRect { model.displayRect }

    func imagePoint(_ v: NSPoint) -> CGPoint {
        CGPoint(x: region.minX + v.x * model.scale, y: region.minY + v.y * model.scale)
    }

    func viewPoint(_ p: CGPoint) -> NSPoint {
        NSPoint(x: (p.x - region.minX) / model.scale, y: (p.y - region.minY) / model.scale)
    }

    private var magnification: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.01) }

    /// Image pixels per point on screen: hit areas and handles keep their on-screen size at any zoom.
    private var pixelsPerScreenPoint: CGFloat { model.scale / magnification }

    // MARK: Drawing

    /// The view itself shows only the image; the overlay subview draws the annotations.
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        applyImageTransform(ctx)
        // Sharp pixels when zoomed in past 1:1, smooth scaling when zoomed out.
        let backing = window?.backingScaleFactor ?? 2
        ctx.interpolationQuality = magnification * backing / model.scale > 1.5 ? .none : .high
        AnnotationRenderer.drawImage(model.baseImage, in: model.imageRect, ctx: ctx)
        ctx.restoreGState()
    }

    /// From view points to image pixels.
    private func applyImageTransform(_ ctx: CGContext) {
        ctx.scaleBy(x: 1 / model.scale, y: 1 / model.scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
    }

    fileprivate func drawAnnotations() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        applyImageTransform(ctx)
        AnnotationRenderer.draw(model.state.annotations, in: ctx, env: model.env)
        if model.tool == .crop {
            drawCropOverlay(ctx)
        } else {
            drawSelection(ctx)
        }
        ctx.restoreGState()
    }

    private func handlePoints(for a: Annotation) -> [(Handle, CGPoint)] {
        switch a.shape {
        case .arrow(let s, let e), .line(let s, let e):
            return [(.start, s), (.end, e)]
        case .rectangle(let r), .ellipse(let r), .pixelate(let r):
            return Handle.rectHandles.map { ($0, $0.point(in: r)) }
        default:
            return []
        }
    }

    private func drawHandle(_ p: CGPoint, ctx: CGContext) {
        let k = pixelsPerScreenPoint
        let r = 4.5 * k
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 * k)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.75 * k, dy: 0.75 * k))
    }

    private func drawSelection(_ ctx: CGContext) {
        let k = pixelsPerScreenPoint
        let id = model.editingTextID ?? model.selection
        guard let a = model.annotation(id) else { return }
        let handles = handlePoints(for: a)
        let editing = model.editingTextID == a.id
        if handles.isEmpty || editing {
            let box = AnnotationRenderer.bounds(of: a, env: model.env).insetBy(dx: -4 * k, dy: -4 * k)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1 * k)
            ctx.setLineDash(phase: 0, lengths: [4 * k, 3 * k])
            ctx.stroke(box)
            ctx.restoreGState()
        }
        if case .pixelate(let r) = a.shape {
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1 * k)
            ctx.stroke(r)
        }
        guard !editing else { return }
        for (_, p) in handles { drawHandle(p, ctx: ctx) }
    }

    private func drawCropOverlay(_ ctx: CGContext) {
        guard let crop = model.pendingCrop else { return }
        let k = pixelsPerScreenPoint
        ctx.saveGState()
        ctx.addRect(model.imageRect)
        ctx.addRect(crop)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(0.75 * k)
        for i in 1...2 {
            let x = crop.minX + crop.width * CGFloat(i) / 3
            let y = crop.minY + crop.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: crop.minY))
            ctx.addLine(to: CGPoint(x: x, y: crop.maxY))
            ctx.move(to: CGPoint(x: crop.minX, y: y))
            ctx.addLine(to: CGPoint(x: crop.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.5 * k)
        ctx.stroke(crop)
        ctx.restoreGState()
        for handle in Handle.rectHandles { drawHandle(handle.point(in: crop), ctx: ctx) }
    }

    // MARK: Hit testing

    private func handle(of a: Annotation, at p: CGPoint, tolerance: CGFloat) -> Handle? {
        handlePoints(for: a).first { pointDistance($0.1, p) <= tolerance + 4.5 * pixelsPerScreenPoint }?.0
    }

    private func cropHandle(at p: CGPoint, tolerance: CGFloat) -> Handle? {
        guard let crop = model.pendingCrop else { return nil }
        return Handle.rectHandles.first { pointDistance($0.point(in: crop), p) <= tolerance + 4.5 * pixelsPerScreenPoint }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textView != nil {
            // A click outside the text being edited finishes it; the next click starts something new.
            commitTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let v = convert(event.locationInWindow, from: nil)
        let p = imagePoint(v)
        mouseDownViewPoint = v
        mouseDownPoint = p
        didDrag = false
        drag = .none
        let tolerance = 4 * pixelsPerScreenPoint

        switch model.tool {
        case .crop:
            if let handle = cropHandle(at: p, tolerance: tolerance), let crop = model.pendingCrop {
                drag = .cropResize(handle, original: crop)
            } else if let crop = model.pendingCrop, crop.contains(p) {
                drag = .cropMove(last: p)
                NSCursor.closedHand.set()
            } else {
                drag = .cropNew(start: clampToImage(p))
                model.pendingCrop = nil
            }
            return
        case .text:
            if let hit = model.annotation(at: p, tolerance: tolerance, where: { $0.isText }) {
                model.select(hit.id)
                model.beginGesture()
                startEditing(hit, caretAt: v)
            } else {
                createText(at: p)
            }
            return
        default:
            break
        }

        // The selected annotation's handles come first, then any annotation under the pointer.
        if let selected = model.selectedAnnotation, let handle = handle(of: selected, at: p, tolerance: tolerance) {
            model.beginGesture()
            drag = .resizing(selected.id, handle, original: selected)
            return
        }
        if let hit = model.annotation(at: p, tolerance: tolerance, where: model.isGrabbable) {
            model.select(hit.id)
            if event.clickCount == 2, hit.isText {
                model.beginGesture()
                startEditing(hit, caretAt: v)
                return
            }
            model.beginGesture()
            drag = .moving(hit.id, last: p)
            NSCursor.closedHand.set()
            return
        }

        switch model.tool {
        case .select:
            model.select(nil)
        case .counter:
            model.beginGesture()
            let a = Annotation(shape: .counter(p, model.nextCounterNumber()), color: model.color, lineWidth: model.lineWidth)
            model.updateGesture { $0.annotations.append(a) }
            model.selection = a.id
            drag = .moving(a.id, last: p)
        default:
            guard let shape = newShape(at: p) else { return }
            model.beginGesture()
            let a = Annotation(shape: shape, color: model.color, lineWidth: model.lineWidth,
                               filled: model.filled, fontSize: model.fontSize)
            model.updateGesture { $0.annotations.append(a) }
            model.selection = a.id
            drag = .creating(a.id)
        }
    }

    private func newShape(at p: CGPoint) -> Annotation.Shape? {
        switch model.tool {
        case .arrow: return .arrow(p, p)
        case .line: return .line(p, p)
        case .rectangle: return .rectangle(CGRect(origin: p, size: .zero))
        case .ellipse: return .ellipse(CGRect(origin: p, size: .zero))
        case .pen: return .pen([p])
        case .highlighter: return .highlighter([p])
        case .pixelate: return .pixelate(CGRect(origin: p, size: .zero))
        default: return nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if !didDrag {
            // Ignore the jitter of a click.
            guard hypot(v.x - mouseDownViewPoint.x, v.y - mouseDownViewPoint.y) * magnification >= 2 else { return }
            didDrag = true
        }
        autoscroll(with: event)
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case .none:
            break
        case .creating(let id):
            guard model.isInGesture else { return }
            updateCreation(id, to: p, shift: shift)
        case .moving(let id, let last):
            guard model.isInGesture else { return }
            let dx = p.x - last.x, dy = p.y - last.y
            model.updateGesture { state in
                if let i = state.annotations.firstIndex(where: { $0.id == id }) {
                    state.annotations[i] = state.annotations[i].translated(by: dx, dy)
                }
            }
            drag = .moving(id, last: p)
        case .resizing(let id, let handle, let original):
            guard model.isInGesture else { return }
            let resized = reshape(original, handle: handle, to: p, shift: shift)
            model.updateGesture { state in
                if let i = state.annotations.firstIndex(where: { $0.id == id }) { state.annotations[i] = resized }
            }
        case .cropNew(let start):
            let end = clampToImage(shift ? squareCorner(from: start, to: p) : p)
            model.pendingCrop = rectSpanning(start, end)
        case .cropMove(let last):
            guard var crop = model.pendingCrop else { return }
            crop = crop.offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            let image = model.imageRect
            crop.origin.x = min(max(crop.minX, image.minX), image.maxX - crop.width)
            crop.origin.y = min(max(crop.minY, image.minY), image.maxY - crop.height)
            model.pendingCrop = crop
            drag = .cropMove(last: p)
        case .cropResize(let handle, let original):
            model.pendingCrop = handle.resize(original, to: clampToImage(p))
        }
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        let r = model.imageRect
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private func updateCreation(_ id: UUID, to p: CGPoint, shift: Bool) {
        let start = mouseDownPoint
        let minStep = 1.5 * pixelsPerScreenPoint
        model.updateGesture { state in
            guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            switch state.annotations[i].shape {
            case .arrow:
                state.annotations[i].shape = .arrow(start, shift ? snapAngle(from: start, to: p) : p)
            case .line:
                state.annotations[i].shape = .line(start, shift ? snapAngle(from: start, to: p) : p)
            case .rectangle:
                state.annotations[i].shape = .rectangle(rectSpanning(start, shift ? squareCorner(from: start, to: p) : p))
            case .ellipse:
                state.annotations[i].shape = .ellipse(rectSpanning(start, shift ? squareCorner(from: start, to: p) : p))
            case .pixelate:
                let end = clampToImage(shift ? squareCorner(from: start, to: p) : p)
                state.annotations[i].shape = .pixelate(rectSpanning(clampToImage(start), end))
            case .pen(var points):
                if shift {
                    points = [start, snapAngle(from: start, to: p)]
                } else if let last = points.last, pointDistance(last, p) >= minStep {
                    points.append(p)
                }
                state.annotations[i].shape = .pen(points)
            case .highlighter(var points):
                if shift {
                    points = [start, snapAngle(from: start, to: p)]
                } else if let last = points.last, pointDistance(last, p) >= minStep {
                    points.append(p)
                }
                state.annotations[i].shape = .highlighter(points)
            default:
                break
            }
        }
    }

    private func reshape(_ original: Annotation, handle: Handle, to p: CGPoint, shift: Bool) -> Annotation {
        var a = original
        switch original.shape {
        case .arrow(let s, let e):
            a.shape = handle == .start ? .arrow(shift ? snapAngle(from: e, to: p) : p, e)
                : .arrow(s, shift ? snapAngle(from: s, to: p) : p)
        case .line(let s, let e):
            a.shape = handle == .start ? .line(shift ? snapAngle(from: e, to: p) : p, e)
                : .line(s, shift ? snapAngle(from: s, to: p) : p)
        case .rectangle(let r):
            a.shape = .rectangle(handle.resize(r, to: p))
        case .ellipse(let r):
            a.shape = .ellipse(handle.resize(r, to: p))
        case .pixelate(let r):
            a.shape = .pixelate(handle.resize(r, to: clampToImage(p)))
        default:
            break
        }
        return a
    }

    /// Shapes too small to see after a drag.
    private func isDegenerate(_ a: Annotation) -> Bool {
        switch a.shape {
        case .arrow(let s, let e), .line(let s, let e):
            return pointDistance(s, e) < 2
        case .rectangle(let r), .ellipse(let r), .pixelate(let r):
            return r.isNull || r.width < 2 || r.height < 2
        case .highlighter(let points):
            return points.count < 2
        default:
            return false
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        switch finished {
        case .creating(let id):
            if let a = model.annotation(id) {
                let isDot: Bool = { if case .pen = a.shape { return true } else { return false } }()
                if (!didDrag && !isDot) || isDegenerate(a) {
                    // A click without a drag draws nothing (except a dot with the pen).
                    model.updateGesture { $0.annotations.removeAll { $0.id == id } }
                    model.selection = nil
                }
            }
            model.endGesture()
            if model.annotation(id) != nil { model.select(id) }
        case .moving, .resizing:
            model.endGesture()
        case .cropNew, .cropMove, .cropResize:
            if let crop = model.pendingCrop, crop.width < 4 || crop.height < 4 { model.pendingCrop = nil }
        case .none:
            break
        }
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    // MARK: Cursor

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    private func cursor(at v: NSPoint) -> NSCursor {
        let p = imagePoint(v)
        let tolerance = 4 * pixelsPerScreenPoint
        switch model.tool {
        case .crop:
            if let handle = cropHandle(at: p, tolerance: tolerance) { return handle.cursor }
            if let crop = model.pendingCrop, crop.contains(p) { return .openHand }
            return .crosshair
        case .text:
            return .iBeam
        default:
            if let selected = model.selectedAnnotation, let handle = handle(of: selected, at: p, tolerance: tolerance) {
                return handle.cursor
            }
            if model.annotation(at: p, tolerance: tolerance, where: model.isGrabbable) != nil { return .openHand }
            return model.tool == .select ? .arrow : .crosshair
        }
    }

    // MARK: Keyboard (plain keys; ⌘ shortcuts are handled by the window)

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let step: CGFloat = shift ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.tool == .crop {
                model.cancelCrop()
            } else {
                model.select(nil)
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if model.tool == .crop {
                // Return with no frame leaves the crop as it was; "Сбросить" removes it.
                if model.pendingCrop != nil { model.applyCrop() } else { model.cancelCrop() }
                return true
            }
            if let a = model.selectedAnnotation, a.isText {
                model.beginGesture()
                startEditing(a, caretAt: nil)
                return true
            }
            return false
        case kVK_Delete, kVK_ForwardDelete:
            if model.tool != .crop { model.deleteSelection() }
            return true
        case kVK_LeftArrow:
            model.nudgeSelection(dx: -step, dy: 0)
            return true
        case kVK_RightArrow:
            model.nudgeSelection(dx: step, dy: 0)
            return true
        case kVK_UpArrow:
            model.nudgeSelection(dx: 0, dy: -step)
            return true
        case kVK_DownArrow:
            model.nudgeSelection(dx: 0, dy: step)
            return true
        default:
            if let tool = Tool.allCases.first(where: { $0.keyCode == Int(event.keyCode) }) {
                model.setTool(tool)
                return true
            }
            return false
        }
    }

    // MARK: Text editing

    var isEditingText: Bool { textView != nil }

    private func createText(at p: CGPoint) {
        model.beginGesture()
        let fontSize = model.fontSize
        let lineHeight = TextLayout(string: "", pointSize: fontSize / model.scale).lineHeight * model.scale
        let a = Annotation(shape: .text(CGPoint(x: p.x, y: p.y - lineHeight / 2), ""), color: model.color,
                           lineWidth: model.lineWidth, fontSize: fontSize)
        model.updateGesture { $0.annotations.append(a) }
        model.selection = a.id
        startEditing(a, caretAt: nil)
    }

    /// Opens the inline text view over a text annotation; the caller has begun a gesture.
    private func startEditing(_ a: Annotation, caretAt click: NSPoint?) {
        guard case .text(_, let string) = a.shape, textView == nil else { return }
        model.editingTextID = a.id

        // TextKit 1 with no padding: the same line metrics TextLayout uses for rendering.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let tv = InlineTextView(frame: NSRect(x: 0, y: 0, width: 20, height: 20), textContainer: container)
        tv.textContainerInset = .zero
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.usesFindBar = false
        tv.focusRingType = .none
        tv.onEnd = { [weak self] in self?.commitTextEditing() }
        textView = tv
        applyTextStyle(to: tv, annotation: a)
        tv.string = string
        tv.delegate = self
        addSubview(tv)
        layoutTextView()
        window?.makeFirstResponder(tv)
        if let click {
            let index = tv.characterIndexForInsertion(at: tv.convert(click, from: self))
            tv.setSelectedRange(NSRange(location: min(index, (string as NSString).length), length: 0))
        } else {
            tv.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
        overlay.needsDisplay = true
    }

    private func applyTextStyle(to tv: NSTextView, annotation a: Annotation) {
        appliedTextStyle = (a.fontSize, a.color)
        let font = TextLayout.font(pointSize: a.fontSize / model.scale)
        tv.font = font
        tv.textColor = .clear
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor.clear]
        if let storage = tv.textStorage, storage.length > 0 {
            storage.addAttributes([.font: font, .foregroundColor: NSColor.clear],
                                  range: NSRange(location: 0, length: storage.length))
        }
        let caret = a.color.luminance > 0.9 ? NSColor.controlAccentColor : a.color.nsColor
        tv.insertionPointColor = caret
    }

    /// Follows color and size changes made while typing, and keeps the view around the text.
    private func syncTextView() {
        guard let tv = textView, let a = model.annotation(model.editingTextID) else { return }
        if appliedTextStyle?.fontSize != a.fontSize || appliedTextStyle?.color != a.color {
            applyTextStyle(to: tv, annotation: a)
        }
        layoutTextView()
    }

    private func layoutTextView() {
        guard let tv = textView, let a = model.annotation(model.editingTextID),
              case .text(let origin, let string) = a.shape else { return }
        let layout = TextLayout(string: string, pointSize: a.fontSize / model.scale)
        let caretRoom = layout.font.pointSize * 0.75
        tv.frame = NSRect(origin: viewPoint(origin),
                          size: NSSize(width: layout.size.width + caretRoom, height: layout.size.height))
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = model.editingTextID else { return }
        let string = tv.string
        model.updateGesture { state in
            if let i = state.annotations.firstIndex(where: { $0.id == id }), case .text(let origin, _) = state.annotations[i].shape {
                state.annotations[i].shape = .text(origin, string)
            }
        }
    }

    /// Finishes text editing; empty text is removed.
    func commitTextEditing() {
        guard let tv = textView else { return }
        textView = nil
        appliedTextStyle = nil
        tv.delegate = nil
        tv.onEnd = nil
        let wasFirstResponder = window?.firstResponder === tv
        // Typing undo belongs to the text view; the finished edit is one step of the editor's own history.
        tv.undoManager?.removeAllActions()
        tv.removeFromSuperview()
        if let id = model.editingTextID {
            model.editingTextID = nil
            if let a = model.annotation(id), (a.textString ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.updateGesture { $0.annotations.removeAll { $0.id == id } }
                model.selection = nil
            }
        }
        model.endGesture()
        if wasFirstResponder || window?.firstResponder == nil { window?.makeFirstResponder(self) }
        overlay.needsDisplay = true
    }
}
