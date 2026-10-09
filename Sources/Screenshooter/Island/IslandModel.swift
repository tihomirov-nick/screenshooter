import AppKit
import Observation
import ShotCore

enum IslandState: Equatable {
    /// Shrunk into the middle of the camera housing: nothing to see (on displays without one, nothing at all).
    case closed
    /// A capture just landed: its thumbnail in the wing left of the notch, a check mark in the right one.
    case peek
    /// A short message under the notch ("Текст скопирован").
    case banner
    /// The shelf.
    case open
}

/// The island's measures. Everything below the notch keeps one spacing scale (4, 8, 12, 16, 24): 16 pt from the
/// island's edge to its content, 8 pt between rows, 12 pt between cards and from the notch to the header's zones.
/// Corners are concentric: a card's radius is the island's bottom radius less the 16 pt margin.
struct IslandMetrics: Equatable {
    /// The camera housing (or a virtual one in the middle of the menu bar on displays without a notch).
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 32
    var hasNotch = false

    static let shadowMargin: CGFloat = 36
    /// From the island's edge to its content.
    static let padding: CGFloat = 16
    /// Between the rows under the header.
    static let rowGap: CGFloat = 8
    /// Between the notch and the header's zones.
    static let notchGap: CGFloat = 12
    static let cardSpacing: CGFloat = 12
    static let card = CGSize(width: 132, height: 84)
    static let captionGap: CGFloat = 8
    static let captionHeight: CGFloat = 14
    static var stripHeight: CGFloat { card.height + captionGap + captionHeight }
    /// The update row with one line of detail, and with two.
    static let updateHeight: CGFloat = 56
    static let updateTallHeight: CGFloat = 70
    /// Each side of the notch in the peek.
    static let wing: CGFloat = 48
    static let maxOpenWidth: CGFloat = 640
    static let maxBannerWidth: CGFloat = 440
    /// The text buttons of the update row and the banner.
    static let buttonHeight: CGFloat = 24
    /// Between the banner's text and its buttons.
    static let bannerButtonGap: CGFloat = 16
    /// How much the island grows while something is dragged over it: barely noticeable.
    static let dragGrowth: CGFloat = 0.025
    static let openRadius: CGFloat = 28
    static var cardRadius: CGFloat { openRadius - padding }

    /// The concave curves where the island meets the top edge, and the bottom corners.
    func radii(for state: IslandState) -> (flare: CGFloat, bottom: CGFloat) {
        switch state {
        case .closed: return (0, 0)
        case .peek: return (6, 14)
        case .banner: return (8, 20)
        case .open: return (10, Self.openRadius)
        }
    }

    /// The island in the open state at its tallest: the header, a two-line update row and the cards.
    var maxOpenHeight: CGFloat {
        notchHeight + Self.rowGap + Self.updateTallHeight + Self.rowGap + Self.stripHeight + Self.padding
    }

    /// The panel is big enough for the largest state, grown while something is dragged over it, and its shadow; it
    /// never resizes.
    var panelSize: CGSize {
        let grown = 1 + Self.dragGrowth
        return CGSize(width: ceil(Self.maxOpenWidth * grown) + 2 * Self.shadowMargin,
                      height: ceil(maxOpenHeight * grown) + Self.shadowMargin)
    }
}

/// What the island shows; the controller changes it, the SwiftUI view draws it.
@MainActor
@Observable
final class IslandModel {
    var state: IslandState = .closed {
        didSet {
            guard state != oldValue else { return }
            previousState = oldValue
            if state != .closed { lastShownState = state }
        }
    }
    /// The state before the current one.
    private(set) var previousState: IslandState = .closed
    /// The last state that was not closed: its content shrinks into the notch while the island closes.
    private(set) var lastShownState: IslandState = .open
    var metrics = IslandMetrics()
    /// The capture shown in the peek.
    var peekItemID: UUID?
    var bannerText = ""
    var bannerSymbol = "checkmark.circle.fill"
    /// Buttons after the banner's text, on the same line (a new version: "Позже", "Обновить").
    var bannerActions: [IslandUpdate.Action] = []
    /// Files or text the shelf can take are dragged over it.
    var dropTargeted = false
    /// Something is dragged over the island, into the shelf or out of it: the island grows a little.
    var dragOver = false
    /// Briefly highlights a card (the capture that just arrived).
    var highlightedItemID: UUID?
    /// The card under the pointer.
    var hoveredItemID: UUID?
    /// The card chosen with a click or the arrow keys: the shelf holds the keyboard for it.
    var selectedItemID: UUID?
    /// A short confirmation in the open shelf's header, in place of its title for a moment ("Скопировано").
    var toast: IslandToast?
    /// A new version offered, downloading, installing or failed to install: a row over the cards.
    var update: Updater.State?

    /// The update row's texts and buttons.
    var updateRow: IslandUpdate? { update.flatMap(IslandUpdate.init) }

    /// The island's size in `state`, the same for the view and for the pointer: the black body without the concave
    /// curves at the top. The open shelf and the banner hug their content.
    func size(for state: IslandState, shelf: Shelf) -> CGSize {
        let m = metrics, p = IslandMetrics.padding
        switch state {
        case .closed:
            return .zero
        case .peek:
            return CGSize(width: m.notchWidth + 2 * IslandMetrics.wing, height: m.notchHeight)
        case .banner:
            let layout = bannerLayout
            return CGSize(width: layout.width, height: m.notchHeight + IslandMetrics.rowGap + layout.textHeight + p)
        case .open:
            let width = openWidth(shelf: shelf)
            var height = m.notchHeight + IslandMetrics.rowGap + IslandMetrics.stripHeight + p
            if let row = updateRow { height += row.height(width: width - 2 * p) + IslandMetrics.rowGap }
            return CGSize(width: width, height: height)
        }
    }

    /// The size on screen: grown a touch while something is dragged over the island.
    func shapeSize(shelf: Shelf) -> CGSize {
        let size = size(for: state, shelf: shelf)
        guard dragOver else { return size }
        let k = 1 + IslandMetrics.dragGrowth
        return CGSize(width: size.width * k, height: size.height * k)
    }

    /// Wide enough for the header (equal zones either side of the notch), the cards, the update row and the empty
    /// shelf's text; no wider than `maxOpenWidth`, past which the cards scroll.
    func openWidth(shelf: Shelf) -> CGFloat {
        let p = IslandMetrics.padding
        let count = shelf.items.count
        let zone = max(headerTitleWidth(count: count), headerButtonsWidth(empty: count == 0), toast?.width ?? 0)
        var width = metrics.notchWidth + 2 * (IslandMetrics.notchGap + zone + p)
        if count > 0 {
            width = max(width, stripWidth(count: count) + 2 * p)
        } else {
            width = max(width, IslandText.width(L("Перетащите сюда файлы или текст"), size: 11) + 2 * p,
                        IslandText.width(L("Здесь будут ваши снимки"), size: 13, weight: .medium) + 2 * p)
        }
        if let row = updateRow { width = max(width, row.width + 2 * p) }
        return min(IslandMetrics.maxOpenWidth, ceil(width))
    }

    /// The cards side by side, without margins.
    func stripWidth(count: Int) -> CGFloat {
        let n = CGFloat(count)
        return n * IslandMetrics.card.width + max(0, n - 1) * IslandMetrics.cardSpacing
    }

    /// The mark, "Полка" and the number of cards.
    func headerTitleWidth(count: Int) -> CGFloat {
        var width = IslandMark.titleSide + 6 + IslandText.width(L("Полка"), size: 13, weight: .semibold)
        if count > 0 {
            width += 6 + IslandText.width("\(count)", size: 11, weight: .semibold, monospacedDigits: true) + 12
        }
        return ceil(width)
    }

    /// Capture, folder, (clear,) settings.
    func headerButtonsWidth(empty: Bool) -> CGFloat {
        let buttons: CGFloat = empty ? 3 : 4
        return buttons * 28 + (buttons - 1) * 4
    }

    /// The banner's width and the height of its line: as wide as its one line of text, up to `maxBannerWidth`; a longer
    /// text wraps onto a second line. Buttons follow the text on its line, 16 pt after it, and the line is as high as they
    /// are.
    var bannerLayout: (width: CGFloat, textHeight: CGFloat, lines: Int) {
        let p = IslandMetrics.padding
        let icon = IslandText.symbolWidth(bannerSymbol, size: 13, weight: .semibold) + 6
        let text = IslandText.width(bannerText, size: 13, weight: .medium)
        let lineHeight: CGFloat = 16
        let minimum = metrics.notchWidth + 2 * 24
        if !bannerActions.isEmpty {
            let buttons = bannerActions.map(IslandUpdate.buttonWidth).reduce(0, +) + CGFloat(bannerActions.count - 1) * 8
            let width = icon + text + IslandMetrics.bannerButtonGap + buttons + 2 * p
            return (min(IslandMetrics.maxBannerWidth, max(minimum, ceil(width))), IslandMetrics.buttonHeight, 1)
        }
        let room = IslandMetrics.maxBannerWidth - 2 * p - icon
        if text <= room {
            return (max(minimum, ceil(text + icon + 2 * p)), lineHeight, 1)
        }
        return (IslandMetrics.maxBannerWidth, 2 * lineHeight, 2)
    }
}

/// A short confirmation in the open shelf's header: a symbol tinted by what it says and the text.
struct IslandToast: Equatable {
    var text: String
    var symbol: String

    var width: CGFloat {
        ceil(IslandText.symbolWidth(symbol, size: 13, weight: .semibold) + 6 + IslandText.width(text, size: 13, weight: .semibold))
    }
}

/// The app's mark in the island: the menu bar glyph, in lines that hold their own next to 13 pt semibold text and
/// symbols.
enum IslandMark {
    /// Before "Полка" in the header.
    static let titleSide: CGFloat = 16
    /// On the smart capture button, the size of the symbols beside it.
    static let buttonSide: CGFloat = 16
    static let lineWidth: CGFloat = 1.4
}

/// The update row: the state of the new version on the left, what can be done about it on the right. Worked out once
/// from the updater's state, for the row and for the island's size.
struct IslandUpdate: Equatable {
    enum Detail: Equatable {
        case text(String)
        case progress(Double)
    }

    enum Kind: Equatable {
        /// Blue: the main choice.
        case primary
        /// Translucent: the second one.
        case secondary
        /// Bare text: the least.
        case plain
    }

    struct Action: Equatable {
        var title: String
        var command: UpdateCommand
        var kind: Kind
        var help: String?
    }

    var symbol: String
    var failed: Bool
    var title: String
    var detail: Detail
    var actions: [Action]
    /// Installing: a spinner instead of buttons.
    var busy: Bool
    /// The release: its offer sets the row's width for every step of the update, so the island does not jump.
    var release: Updater.Release

    init?(_ state: Updater.State) {
        guard let release = state.islandRelease else { return nil }
        self.release = release
        let offerTitle = L("Доступна версия %@", release.version)
        let summary = (release.summary.isEmpty ? release.title : release.summary).replacingOccurrences(of: "\n", with: " ")
        symbol = "arrow.down.circle.fill"
        failed = false
        busy = false
        switch state {
        case .downloading(_, let progress):
            title = L("Загрузка версии %@", release.version)
            detail = .progress(progress)
            actions = [Action(title: L("Отмена"), command: .cancel, kind: .secondary)]
        case .installing:
            title = L("Установка версии %@", release.version)
            detail = .text(L("Screenshooter перезапустится сам"))
            actions = []
            busy = true
        case .failed(let failure, _):
            symbol = "exclamationmark.triangle.fill"
            failed = true
            title = failure.islandTitle
            detail = .text(failure.islandAdvice)
            let main: Action
            if failure.retries {
                main = Action(title: L("Попробовать снова"), command: .install, kind: .primary)
            } else if failure == .cannotReplace {
                main = Action(title: L("Открыть установщик"), command: .page, kind: .primary)
            } else {
                main = Action(title: L("Страница загрузки"), command: .page, kind: .primary)
            }
            actions = [Action(title: L("Позже"), command: .later, kind: .secondary), main]
        default:
            title = offerTitle
            detail = .text(summary)
            actions = [Action(title: L("Пропустить"), command: .skip, kind: .plain, help: L("Больше не предлагать эту версию")),
                       Action(title: L("Позже"), command: .later, kind: .secondary),
                       Action(title: L("Обновить"), command: .install, kind: .primary)]
        }
    }

    // The row: 12 pt inside, the 24 pt symbol, 12 pt, the texts, at least 12 pt, the buttons, 12 pt.
    static let inset: CGFloat = 12
    static let symbolBox: CGFloat = 24
    static let progressWidth: CGFloat = 220
    /// The release notes' summary stops widening the island here; past it the line is cut short.
    static let summaryWidth: CGFloat = 240

    static func buttonWidth(_ action: Action) -> CGFloat {
        let text = IslandText.width(action.title, size: 12, weight: action.kind == .primary ? .semibold : .medium)
        return text + (action.kind == .plain ? 8 : 24)
    }

    var controlsWidth: CGFloat {
        if busy { return 20 }
        let buttons = actions.map(Self.buttonWidth).reduce(0, +)
        return buttons + CGFloat(max(0, actions.count - 1)) * 8
    }

    private var fixedWidth: CGFloat { 2 * Self.inset + Self.symbolBox + 12 + 12 + controlsWidth }

    private func textWidth(title: String, detail: Detail, capDetail: Bool) -> CGFloat {
        let titleWidth = IslandText.width(title, size: 13, weight: .semibold)
        switch detail {
        case .progress:
            return max(titleWidth, Self.progressWidth)
        case .text(let text):
            let width = IslandText.width(text, size: 11)
            return max(titleWidth, capDetail ? min(width, Self.summaryWidth) : width)
        }
    }

    /// The width the row would like with its texts on one line each (the offer's summary only up to `summaryWidth`).
    private var ownWidth: CGFloat { fixedWidth + textWidth(title: title, detail: detail, capDetail: !failed) }

    /// The width the row would like, never narrower than the offer of the same release.
    var width: CGFloat {
        let offer = IslandUpdate(.available(release))?.ownWidth ?? 0
        return ceil(max(ownWidth, offer))
    }

    /// Room for the texts in a row `width` wide.
    func textRoom(width: CGFloat) -> CGFloat { width - fixedWidth }

    /// Lines the detail takes in a row `width` wide: the offer's summary is cut to one, advice wraps onto two.
    func detailLines(width: CGFloat) -> Int {
        guard failed, case .text(let text) = detail else { return 1 }
        return IslandText.width(text, size: 11) > textRoom(width: width) ? 2 : 1
    }

    func height(width: CGFloat) -> CGFloat {
        detailLines(width: width) > 1 ? IslandMetrics.updateTallHeight : IslandMetrics.updateHeight
    }
}

private extension Updater.Failure {
    /// What happened, in the update row's title.
    var islandTitle: String {
        switch self {
        case .offline: return L("Нет связи с сервером обновлений")
        case .rateLimited: return L("Сервер просит подождать")
        case .noInstaller: return L("У новой версии нет установщика")
        case .download: return L("Загрузка прервалась")
        case .damaged: return L("Скачанный файл повреждён")
        case .notTrusted: return L("Новая версия подписана чужим сертификатом")
        case .cannotReplace: return L("Отсюда приложение не заменить")
        }
    }

    /// What to do about it, under the title.
    var islandAdvice: String {
        switch self {
        case .offline, .download: return L("Проверьте интернет и попробуйте снова")
        case .rateLimited: return L("Попробуйте через час или скачайте версию вручную")
        case .noInstaller: return L("Загляните на страницу загрузки позже")
        case .damaged: return L("Скачайте версию ещё раз")
        case .notTrusted: return L("Поэтому она не установлена. Её можно скачать вручную")
        case .cannotReplace: return L("Перетащите Screenshooter в папку «Программы»")
        }
    }

    /// Another download may help.
    var retries: Bool {
        switch self {
        case .offline, .download, .damaged: return true
        default: return false
        }
    }
}

/// Text measured the way the island draws it, for sizes worked out before layout.
enum IslandText {
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> CGFloat {
        let font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                                    : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    /// An SF Symbol drawn at a text size.
    static func symbolWidth(_ name: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        return ceil(image?.size.width ?? size)
    }
}
