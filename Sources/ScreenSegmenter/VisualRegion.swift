import CoreGraphics

/// A region found in a screenshot by its pixels alone.
public struct VisualRegion: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// A large area set apart by separator lines or a change of background: a sidebar, a chat, a toolbar.
        case panel
        /// A solid-coloured shape that holds content: a message bubble, a card, a button, an input field.
        case box
        /// Lines of text set close together: a paragraph, a message without a bubble, a list item.
        case textBlock
    }

    /// In pixels of the analysed image, origin at the top left, y going down.
    public var rect: CGRect
    public var kind: Kind

    public init(rect: CGRect, kind: Kind) {
        self.rect = rect
        self.kind = kind
    }
}
