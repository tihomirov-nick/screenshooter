import AppKit
import ApplicationServices
import ShotCore

/// Accessibility elements under a point, from the deepest one up to its window: a word, the message
/// that holds it, the list of messages, the chat panel… Each element's frame is clipped to its
/// ancestors, so parts scrolled out of sight are never offered.
///
/// Not thread-safe: use one instance from one serial queue. Element attributes are cached for the
/// lifetime of the instance (one capture session, while the screen is frozen).
public final class AccessibilityRegions {
    private struct Element {
        let ref: AXUIElement
        let role: String
        let subrole: String
        let roleDescription: String
        let label: String
        let frame: CGRect?
        let parent: AXUIElement?
    }

    /// AXUIElement compared by CFEqual, for caching.
    private struct Key: Hashable {
        let ref: AXUIElement
        static func == (a: Key, b: Key) -> Bool { CFEqual(a.ref, b.ref) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(ref)) }
    }

    private var applications: [pid_t: AXUIElement] = [:]
    private var cache: [Key: Element] = [:]
    /// Applications that did not answer in time; asked again only after a pause.
    private var unresponsive: [pid_t: Date] = [:]

    public init() {}

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Regions of the elements under `point` (screen space) inside `window`, smallest first.
    /// Empty without the accessibility permission or when the app does not expose its interface.
    public func regions(at point: CGPoint, in window: WindowInfo) -> [Region] {
        // The app's own windows answer on its main thread, which may be waiting for this very call.
        guard Self.isTrusted, window.pid != getpid() else { return [] }
        if let since = unresponsive[window.pid], Date().timeIntervalSince(since) < 3 { return [] }

        let app = application(window.pid)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        if error == .cannotComplete { unresponsive[window.pid] = Date() }
        guard error == .success, let leaf = hit else { return [] }

        // Walk up to the window.
        var chain: [Element] = []
        var current: AXUIElement? = leaf
        while let ref = current, chain.count < 80 {
            guard let element = element(ref) else { break }
            if element.role == kAXApplicationRole as String { break }
            chain.append(element)
            if element.role == kAXWindowRole as String { break }
            current = element.parent
        }
        guard !chain.isEmpty else { return [] }

        // The hit must belong to this window: apps answer for their own front-most window at the point,
        // which is a different one when another app's window lies in between.
        if let axWindow = chain.last, axWindow.role == kAXWindowRole as String, let frame = axWindow.frame,
           frame.iou(window.frame) < 0.6 {
            return []
        }

        // Clip each element to everything above it, starting at the window. Elements that do not
        // contain the point (some web elements report odd frames) are skipped rather than trusted.
        var regions: [Region] = []
        var visible = window.frame
        for element in chain.reversed() {
            if element.role == kAXWindowRole as String { continue }
            guard let frame = element.frame, frame.width > 0, frame.height > 0 else { continue }
            let clipped = frame.intersection(visible)
            guard !clipped.isNull, clipped.width >= 3, clipped.height >= 3, clipped.contains(point) else { continue }
            visible = clipped
            regions.append(Region(rect: clipped, source: .element, title: element.label))
        }
        return regions.reversed()
    }

    // MARK: - Elements

    private func application(_ pid: pid_t) -> AXUIElement {
        if let app = applications[pid] { return app }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        applications[pid] = app
        return app
    }

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXParentAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
    ] as CFArray

    private func element(_ ref: AXUIElement) -> Element? {
        let key = Key(ref: ref)
        if let cached = cache[key] { return cached }

        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(ref, Self.attributes, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &valuesRef) == .success,
              let values = valuesRef as? [AnyObject], values.count == 8 else { return nil }

        let role = string(values[0]) ?? ""
        let subrole = string(values[1]) ?? ""
        let roleDescription = string(values[2]) ?? ""
        var frame: CGRect?
        if let origin = point(values[3]), let size = size(values[4]) {
            frame = CGRect(origin: origin, size: size)
        }
        let parent = axElement(values[5])
        let name = [string(values[6]), string(values[7])].compactMap { $0 }.first { !$0.isEmpty }

        let element = Element(ref: ref, role: role, subrole: subrole, roleDescription: roleDescription,
                              label: Self.label(role: role, subrole: subrole, roleDescription: roleDescription, name: name),
                              frame: frame, parent: parent)
        cache[key] = element
        return element
    }

    /// "Кнопка «Отправить»", "Группа", "Веб-область".
    static func label(role: String, subrole: String, roleDescription: String, name: String?) -> String {
        var base = roleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "unknown" {
            base = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        }
        if base.isEmpty { base = L("Элемент") }
        base = base.prefix(1).uppercased() + base.dropFirst()

        // Static text carries the text itself as its title; long names only clutter the label.
        guard role != kAXStaticTextRole as String, let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return base }
        let short = name.count > 32 ? String(name.prefix(31)) + "…" : name
        return "\(base) «\(short)»"
    }

    // MARK: - Values

    private func string(_ value: AnyObject) -> String? {
        CFGetTypeID(value) == CFStringGetTypeID() ? (value as! String) : nil
    }

    private func axElement(_ value: AnyObject) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }

    private func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var p = CGPoint.zero
        return AXValueGetType(axValue) == .cgPoint && AXValueGetValue(axValue, .cgPoint, &p) ? p : nil
    }

    private func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var s = CGSize.zero
        return AXValueGetType(axValue) == .cgSize && AXValueGetValue(axValue, .cgSize, &s) ? s : nil
    }
}
