import AppKit
import Observation

enum IslandState: Equatable {
    /// Hidden behind the camera housing (or invisible on displays without one).
    case closed
    /// A capture just landed: its thumbnail on the left of the notch, a check mark on the right.
    case peek
    /// A short message under the notch ("Текст скопирован").
    case banner
    /// The shelf.
    case open
}

/// Sizes of the island in each state, derived from the notch of the display it lives on.
struct IslandMetrics: Equatable {
    /// The camera housing (or a virtual one on displays without a notch).
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 32
    var hasNotch = false

    static let shadowMargin: CGFloat = 36
    static let openWidth: CGFloat = 640
    static let shelfHeight: CGFloat = 132
    static let wing: CGFloat = 46

    func size(for state: IslandState) -> CGSize {
        switch state {
        case .closed:
            // A bit smaller than the housing so no black edge peeks out around it.
            return hasNotch ? CGSize(width: notchWidth - 6, height: notchHeight - 2)
                            : CGSize(width: notchWidth, height: notchHeight)
        case .peek:
            return CGSize(width: notchWidth + 2 * Self.wing, height: notchHeight)
        case .banner:
            return CGSize(width: max(notchWidth + 2 * 84, 340), height: notchHeight + 34)
        case .open:
            return CGSize(width: max(Self.openWidth, notchWidth + 380), height: notchHeight + Self.shelfHeight)
        }
    }

    func radii(for state: IslandState) -> (top: CGFloat, bottom: CGFloat) {
        switch state {
        case .closed, .peek: return (6, 14)
        case .banner: return (8, 20)
        case .open: return (12, 28)
        }
    }

    /// The panel is big enough for the open state and its shadow; it never resizes.
    var panelSize: CGSize {
        let open = size(for: .open)
        return CGSize(width: open.width + 2 * Self.shadowMargin + 24, height: open.height + Self.shadowMargin)
    }
}

/// What the island shows; the controller changes it, the SwiftUI view draws it.
@MainActor
@Observable
final class IslandModel {
    var state: IslandState = .closed
    var metrics = IslandMetrics()
    /// The capture shown in the peek.
    var peekItemID: UUID?
    var bannerText = ""
    var bannerSymbol = "checkmark.circle.fill"
    /// A file is dragged over the open shelf.
    var dropTargeted = false
    /// Briefly highlights a card (the capture that just arrived).
    var highlightedItemID: UUID?
    /// A short confirmation in the open shelf's header ("Скопировано").
    var toast: String?

    var size: CGSize { metrics.size(for: state) }

    /// On displays without a notch nothing is drawn while closed.
    var isVisible: Bool { state != .closed || metrics.hasNotch }
}
