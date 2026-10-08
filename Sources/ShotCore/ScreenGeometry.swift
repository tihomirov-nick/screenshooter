import AppKit

/// Two coordinate systems meet in this app:
/// - "screen space": global points with the origin at the top left of the main display and y going down.
///   CGWindowList, the accessibility API and ScreenCaptureKit use it, and so does all detection code.
/// - AppKit: global points with the origin at the bottom left of the main display and y going up
///   (`NSScreen.frame`, `NSEvent.mouseLocation`, window frames).
public enum ScreenGeometry {
    /// Height of the display that holds the menu bar; both systems flip around it.
    public static var mainDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    public static func screenPoint(fromAppKit p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }

    public static func screenRect(fromAppKit r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: mainDisplayHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The mouse position in screen space.
    public static var mouseLocation: CGPoint {
        screenPoint(fromAppKit: NSEvent.mouseLocation)
    }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The frame in screen space.
    var screenSpaceFrame: CGRect {
        CGDisplayBounds(displayID)
    }

    /// The camera housing of MacBooks with a notch, in AppKit coordinates.
    var notchFrame: NSRect? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return NSRect(x: left.maxX, y: frame.maxY - safeAreaInsets.top,
                      width: right.minX - left.maxX, height: safeAreaInsets.top)
    }

    /// Height of the menu bar on this screen.
    var menuBarHeight: CGFloat {
        let h = frame.maxY - visibleFrame.maxY
        return h > 0 ? h : max(safeAreaInsets.top, 24)
    }

    static func containing(screenPoint p: CGPoint) -> NSScreen? {
        screens.first { $0.screenSpaceFrame.contains(p) }
    }
}

public extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Intersection over union, 0…1.
    func iou(_ other: CGRect) -> CGFloat {
        let i = intersection(other)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let u = area + other.area - i.area
        return u > 0 ? i.area / u : 0
    }

    /// True when every edge of both rectangles is within `tolerance` points.
    func isClose(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(maxX - other.maxX) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }

    /// Rounded outward to whole units after scaling, for cropping pixels.
    func integralScaled(by scale: CGFloat) -> CGRect {
        CGRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale).integral
    }
}
