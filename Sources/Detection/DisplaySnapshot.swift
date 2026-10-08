import CoreGraphics
import ShotCore

/// One display frozen at the moment the capture started.
public struct DisplaySnapshot: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    /// Screen space.
    public let frame: CGRect
    /// Pixels per point.
    public let scale: CGFloat
    /// The whole display, `frame.size * scale` pixels.
    public let image: CGImage

    public init(displayID: CGDirectDisplayID, frame: CGRect, scale: CGFloat, image: CGImage) {
        self.displayID = displayID
        self.frame = frame
        self.scale = scale
        self.image = image
    }

    /// Pixel rectangle of a screen-space rectangle inside this display's image.
    public func pixelRect(of rect: CGRect) -> CGRect {
        let local = rect.intersection(frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
        guard !local.isNull else { return .null }
        return local.integralScaled(by: scale)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// Screen-space rectangle of a pixel rectangle of this display's image.
    public func screenRect(ofPixels rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX / scale, y: frame.minY + rect.minY / scale,
               width: rect.width / scale, height: rect.height / scale)
    }

    /// The pixels of a screen-space rectangle (clipped to this display).
    public func crop(_ rect: CGRect) -> CGImage? {
        let pixels = pixelRect(of: rect)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        return image.cropping(to: pixels)
    }
}

public extension Array where Element == DisplaySnapshot {
    /// The display that shows the largest part of the rectangle.
    func best(for rect: CGRect) -> DisplaySnapshot? {
        self.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
            .flatMap { $0.frame.intersects(rect) ? $0 : nil }
    }

    func containing(_ point: CGPoint) -> DisplaySnapshot? {
        first { $0.frame.contains(point) }
    }
}
