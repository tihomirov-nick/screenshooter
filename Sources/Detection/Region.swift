import CoreGraphics
import ShotCore

/// A part of the screen that can be captured as one piece.
public struct Region: Hashable, Sendable {
    public enum Source: String, Sendable {
        /// An accessibility element: a button, a message, a list, a web page element.
        case element
        /// Found in the pixels: a panel, a bubble, a card.
        case visual
        /// A block of text found by Vision.
        case text
        /// A whole window.
        case window
        /// The menu bar of a display.
        case menuBar
        /// A whole display.
        case display
    }

    /// Screen space: points, origin at the top left of the main display.
    public var rect: CGRect
    public var source: Source
    /// Shown next to the highlight, e.g. "Кнопка «Отправить»".
    public var title: String
    /// Set when the region is a whole window.
    public var windowID: CGWindowID?

    public init(rect: CGRect, source: Source, title: String, windowID: CGWindowID? = nil) {
        self.rect = rect
        self.source = source
        self.title = title
        self.windowID = windowID
    }
}
