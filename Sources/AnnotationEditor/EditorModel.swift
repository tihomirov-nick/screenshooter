import AppKit
import Combine
import ImageIO

/// The image being edited, its annotations, the undo history and the current tool and style.
final class EditorModel: ObservableObject {
    private(set) var url: URL
    let baseImage: CGImage
    let imageRect: CGRect
    /// Image pixels per point, from the DPI written in the file (144 DPI → 2).
    let scale: CGFloat
    /// Pixels per point of annotation styles; follows the scale, and grows for very large images.
    let unit: CGFloat
    /// Written back into saved files so screenshots keep their size in points.
    let dpi: CGFloat

    @Published private(set) var state = DocState()
    @Published private(set) var savedState = DocState()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var selection: UUID?
    @Published private(set) var tool: Tool = .arrow
    @Published private(set) var color: RGBA = .red
    @Published private(set) var widthPreset: WidthPreset = .medium
    @Published private(set) var filled = false
    @Published private(set) var textSize: TextSizePreset = .medium
    /// The crop frame while the crop tool is active, in image pixels.
    @Published var pendingCrop: CGRect?
    /// The text annotation that the inline text view is editing.
    @Published var editingTextID: UUID?

    private var undoStack: [DocState] = []
    private var redoStack: [DocState] = []
    private var gestureStart: DocState?
    private var lastCoalescingKey: String?
    private var lastCoalescingTime = Date.distantPast
    private var toolBeforeCrop: Tool = .arrow

    private lazy var pixelatedImage: CGImage? =
        AnnotationRenderer.pixelated(baseImage, block: AnnotationRenderer.pixelBlock(for: imageRect))

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var image: CGImage?
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation != 1 {
            // Photos taken sideways: let ImageIO apply the EXIF rotation once, so the editor works upright.
            let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            ] as CFDictionary)
        }
        if image == nil { image = CGImageSourceCreateImageAtIndex(source, 0, nil) }
        guard let image, image.width > 0, image.height > 0 else { return nil }

        self.url = url
        baseImage = image
        imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let fileDPI = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        dpi = fileDPI > 0 ? CGFloat(fileDPI) : 72
        scale = min(max((dpi / 72 * 2).rounded() / 2, 1), 4)
        unit = max(scale, min(imageRect.width, imageRect.height) / 1000)
        restoreStyle()
    }

    // MARK: Derived values

    var env: RenderEnvironment {
        RenderEnvironment(scale: scale, unit: unit, imageRect: imageRect, pixelated: hasPixelate ? pixelatedImage : nil)
    }

    var hasPixelate: Bool {
        state.annotations.contains { if case .pixelate = $0.shape { return true } else { return false } }
    }

    var isModified: Bool { state != savedState }

    /// The part of the image the canvas shows: everything while cropping, otherwise the crop.
    var displayRect: CGRect { tool == .crop ? imageRect : (state.crop ?? imageRect) }

    /// Size of the result in pixels.
    var outputSize: CGSize { (state.crop ?? imageRect).size }

    var lineWidth: CGFloat { widthPreset.points * unit }
    var fontSize: CGFloat { textSize.points * unit }

    var isInGesture: Bool { gestureStart != nil }

    func annotation(_ id: UUID?) -> Annotation? {
        guard let id else { return nil }
        return state.annotations.first { $0.id == id }
    }

    var selectedAnnotation: Annotation? { annotation(selection) }

    /// The topmost annotation under `p` that `include` accepts.
    /// Pixelated areas lie under everything else, so they come last.
    func annotation(at p: CGPoint, tolerance: CGFloat, where include: (Annotation) -> Bool = { _ in true }) -> Annotation? {
        let env = self.env
        let isPixelate = { (a: Annotation) -> Bool in if case .pixelate = a.shape { return true } else { return false } }
        for a in state.annotations.reversed() where !isPixelate(a) && include(a) {
            if AnnotationRenderer.hitTest(a, at: p, tolerance: tolerance, env: env) { return a }
        }
        for a in state.annotations.reversed() where isPixelate(a) && include(a) {
            if AnnotationRenderer.hitTest(a, at: p, tolerance: tolerance, env: env) { return a }
        }
        return nil
    }

    /// Annotations the current tool can grab and move. The select tool takes anything; a drawing tool
    /// takes the selected annotation and its own kind, so new marks can still be drawn over other ones
    /// (a counter right at the edge of a rectangle, an arrow starting inside a pixelated area).
    func isGrabbable(_ a: Annotation) -> Bool {
        if tool == .select || a.id == selection { return true }
        switch (a.shape, tool) {
        case (.arrow, .arrow), (.line, .line), (.rectangle, .rectangle), (.ellipse, .ellipse), (.pen, .pen),
             (.highlighter, .highlighter), (.text, .text), (.counter, .counter), (.pixelate, .pixelate):
            return true
        default:
            return false
        }
    }

    func nextCounterNumber() -> Int {
        let numbers = state.annotations.compactMap { a -> Int? in
            if case .counter(_, let n) = a.shape { return n } else { return nil }
        }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: Changes with undo

    /// One undoable change. Changes with the same key in quick succession (a color dragged in the
    /// color panel, nudging with arrow keys) undo together.
    func perform(coalescing key: String? = nil, _ change: (inout DocState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        let now = Date()
        let coalesce = key != nil && key == lastCoalescingKey && now.timeIntervalSince(lastCoalescingTime) < 1.5
        if !coalesce {
            undoStack.append(state)
            redoStack.removeAll()
        }
        lastCoalescingKey = key
        lastCoalescingTime = now
        state = next
        syncHistoryFlags()
    }

    /// A drag or a text edit: many updates, one undo step.
    func beginGesture() {
        if gestureStart == nil { gestureStart = state }
        lastCoalescingKey = nil
    }

    func updateGesture(_ change: (inout DocState) -> Void) {
        change(&state)
    }

    func endGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        if start != state {
            undoStack.append(start)
            redoStack.removeAll()
            syncHistoryFlags()
        }
    }

    func undo() {
        endGesture()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        afterHistoryJump()
    }

    func redo() {
        endGesture()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        afterHistoryJump()
    }

    private func afterHistoryJump() {
        lastCoalescingKey = nil
        if annotation(selection) == nil { selection = nil }
        syncHistoryFlags()
    }

    private func syncHistoryFlags() {
        if canUndo != !undoStack.isEmpty { canUndo = !undoStack.isEmpty }
        if canRedo != !redoStack.isEmpty { canRedo = !redoStack.isEmpty }
    }

    func markSaved() {
        savedState = state
    }

    func retarget(to newURL: URL) {
        url = newURL
        savedState = state
    }

    func deleteSelection() {
        guard let id = selection else { return }
        perform { $0.annotations.removeAll { $0.id == id } }
        selection = nil
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let id = selection else { return }
        perform(coalescing: "nudge-\(id)") { state in
            if let i = state.annotations.firstIndex(where: { $0.id == id }) {
                state.annotations[i] = state.annotations[i].translated(by: dx, dy)
            }
        }
    }

    // MARK: Tool and style

    func select(_ id: UUID?) {
        selection = id
        guard let a = annotation(id) else { return }
        // Show the selected mark's style in the controls without changing anything.
        if case .pixelate = a.shape { return }
        color = a.color
        if let preset = WidthPreset.allCases.first(where: { abs($0.points * unit - a.lineWidth) < 0.5 }) {
            widthPreset = preset
        }
        if a.supportsFill { filled = a.filled }
        if a.isText, let preset = TextSizePreset.allCases.first(where: { abs($0.points * unit - a.fontSize) < 0.5 }) {
            textSize = preset
        }
    }

    func setTool(_ newTool: Tool) {
        guard newTool != tool else { return }
        if tool == .crop { pendingCrop = nil }
        if newTool == .crop {
            toolBeforeCrop = tool
            pendingCrop = state.crop
            selection = nil
        }
        tool = newTool
        saveStyle()
    }

    func setColor(_ c: RGBA) {
        color = c
        saveStyle()
        applyToSelection(key: "color") { $0.color = c }
    }

    func setWidth(_ preset: WidthPreset) {
        widthPreset = preset
        saveStyle()
        let w = preset.points * unit
        applyToSelection(key: "width") { $0.lineWidth = w }
    }

    func setFilled(_ value: Bool) {
        filled = value
        saveStyle()
        applyToSelection(key: "fill") { if $0.supportsFill { $0.filled = value } }
    }

    func setTextSize(_ preset: TextSizePreset) {
        textSize = preset
        saveStyle()
        let size = preset.points * unit
        applyToSelection(key: "textSize") { if $0.isText { $0.fontSize = size } }
    }

    private func applyToSelection(key: String, _ change: (inout Annotation) -> Void) {
        guard let id = selection, let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        if editingTextID == id || isInGesture {
            // Part of the text edit (or drag) in progress; it becomes one undo step with it.
            change(&state.annotations[index])
            return
        }
        perform(coalescing: "\(key)-\(id)") { change(&$0.annotations[index]) }
    }

    // MARK: Crop

    func applyCrop() {
        let kept = pendingCrop.map { $0.intersection(imageRect).integral }
        perform { state in
            if let kept, kept.width >= 4, kept.height >= 4, kept != imageRect {
                state.crop = kept
            } else {
                state.crop = nil
            }
        }
        pendingCrop = nil
        tool = toolBeforeCrop == .crop ? .arrow : toolBeforeCrop
    }

    func cancelCrop() {
        pendingCrop = nil
        tool = toolBeforeCrop == .crop ? .arrow : toolBeforeCrop
    }

    func resetCrop() {
        pendingCrop = nil
        perform { $0.crop = nil }
    }

    // MARK: Output

    func renderImage() -> CGImage? {
        AnnotationRenderer.render(base: baseImage, state: state, env: env)
    }

    // MARK: Remembered style

    private enum Keys {
        static let tool = "EditorTool"
        static let color = "EditorColor"
        static let width = "EditorWidth"
        static let filled = "EditorFilled"
        static let textSize = "EditorTextSize"
    }

    private func restoreStyle() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Keys.tool).flatMap(Tool.init(rawValue:)), saved != .crop {
            tool = saved
        }
        if let c = defaults.array(forKey: Keys.color) as? [Double], c.count == 3 {
            color = RGBA(CGFloat(c[0]), CGFloat(c[1]), CGFloat(c[2]))
        }
        if let w = WidthPreset(rawValue: defaults.object(forKey: Keys.width) as? Int ?? -1) { widthPreset = w }
        filled = defaults.bool(forKey: Keys.filled)
        if let t = TextSizePreset(rawValue: defaults.object(forKey: Keys.textSize) as? Int ?? -1) { textSize = t }
    }

    private func saveStyle() {
        let defaults = UserDefaults.standard
        if tool != .crop { defaults.set(tool.rawValue, forKey: Keys.tool) }
        defaults.set([Double(color.r), Double(color.g), Double(color.b)], forKey: Keys.color)
        defaults.set(widthPreset.rawValue, forKey: Keys.width)
        defaults.set(filled, forKey: Keys.filled)
        defaults.set(textSize.rawValue, forKey: Keys.textSize)
    }
}
