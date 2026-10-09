import ShotCore
import SwiftUI

/// What the island's buttons and cards do; implemented by `IslandController`.
struct IslandActions {
    var capture: () -> Void
    var openFolder: () -> Void
    var openSettings: () -> Void
    var clear: () -> Void
    var edit: (ShelfItem) -> Void
    var open: (ShelfItem) -> Void
    var copy: (ShelfItem) -> Void
    var copyText: (ShelfItem) -> Void
    var reveal: (ShelfItem) -> Void
    var keep: (ShelfItem) -> Void
    var remove: (ShelfItem) -> Void
    var trash: (ShelfItem) -> Void
    var select: (ShelfItem) -> Void
    var update: (UpdateCommand) -> Void
}

/// The island's colours, the same in every state.
enum IslandStyle {
    /// The capture highlight's blue: the main buttons, the chosen card and the update's progress.
    static let accent = Color(red: 0.18, green: 0.52, blue: 1)
    static let secondaryText = Color.white.opacity(0.6)
    /// The plate under cards and the update row.
    static let plate = Color.white.opacity(0.07)

    /// A status symbol's colour: green for done, orange for a problem, blue for an update, white for the rest.
    static func tint(for symbol: String) -> Color {
        if symbol.contains("exclamationmark") { return .orange }
        if symbol.hasPrefix("checkmark") { return .green }
        if symbol.hasPrefix("arrow.down") { return accent }
        return .white
    }
}

struct IslandRootView: View {
    let model: IslandModel
    let shelf: Shelf
    let actions: IslandActions
    /// For `--render-previews`: Reduce Motion on or off whatever the system says.
    var reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    /// The Dynamic Island's spring, the same as in FaceID: quick, with a little overshoot.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    /// With Reduce Motion nothing grows or moves: the island and its states only fade.
    static let fade = Animation.easeInOut(duration: 0.18)

    var body: some View {
        let state = model.state
        let size = model.size(for: state, shelf: shelf)
        let motion = reduceMotion ? Self.fade : Self.spring
        ZStack(alignment: .top) {
            // Keeps the stack as big as the panel whatever is in it, so nothing slides in from its middle.
            Color.clear
            if reduceMotion {
                // Each state at its own size, cross-fading with the one before.
                if state != .closed {
                    let shape = outline(state, size: size)
                    ZStack(alignment: .top) {
                        shape.fill(Color.black).shadow(color: .black.opacity(shadow(state).opacity),
                                                       radius: shadow(state).radius, y: shadow(state).y)
                        content(state, size: size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .mask { shape }
                    }
                    .id(state)
                    .transition(.opacity)
                }
            } else {
                growing(state)
            }
        }
        // While something is dragged over it, the whole island, content included, grows a touch from the top edge.
        .scaleEffect(model.dragOver && !reduceMotion ? 1 + IslandMetrics.dragGrowth : 1, anchor: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: IslandProbe.space)
        .onPreferenceChange(IslandProbeKey.self) { frames in
            MainActor.assumeIsolated { IslandProbe.frames = frames }
        }
        .animation(motion, value: state)
        .animation(motion, value: size)
        .animation(motion, value: model.dragOver)
        .environment(\.colorScheme, .dark)
    }

    /// One body that grows out of the middle of the notch, changes shape from state to state and shrinks back into
    /// that point, with the content of the shown state growing and shrinking inside it. Out of the closed island it
    /// starts at the new state's own proportions, as big as the notch still hides it, so it shows from the first frame;
    /// closing ends there as well (see `IslandSurface`).
    private func growing(_ state: IslandState) -> some View {
        let shown = state == .closed ? model.lastShownState : state
        let size = model.size(for: shown, shelf: shelf)
        let radii = model.metrics.radii(for: shown), shade = shadow(shown)
        return IslandSurface(width: size.width, height: size.height, flare: radii.flare, radius: radii.bottom,
                             growth: state == .closed ? 0 : 1, hidden: hiddenScale(size),
                             origin: model.metrics.notchHeight / 2, anchor: anchor(size), spring: Self.spring) {
            content(shown, size: size)
        } fill: { shape, growth in
            shape.fill(Color.black)
                .shadow(color: .black.opacity(shade.opacity * growth), radius: shade.radius, y: shade.y)
        }
        // Out of the closed island the body takes the new state's proportions at once, behind the notch, and only its
        // growth is animated. Between shown states its size and corners follow with the spring.
        .transaction(value: state) { transaction in
            if model.previousState == .closed { transaction.animation = nil }
        }
        .animation(Self.spring, value: size)
    }

    /// The biggest scale at which a body `size` big hides whole behind the camera housing, with a little room for the
    /// housing's rounded corners. Without a notch nothing hides it, and the island grows out of a point.
    private func hiddenScale(_ size: CGSize) -> CGFloat {
        let m = model.metrics
        guard m.hasNotch, size.width > 0, size.height > 0 else { return 0 }
        return max(0, min((m.notchWidth - 4) / size.width, (m.notchHeight - 1) / size.height, 1))
    }

    private func outline(_ state: IslandState, size: CGSize) -> IslandShape {
        let metrics = model.metrics, radii = metrics.radii(for: state)
        return IslandShape(width: size.width, height: size.height, origin: metrics.notchHeight / 2,
                           flare: radii.flare, radius: radii.bottom)
    }

    private func shadow(_ state: IslandState) -> (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch state {
        case .closed: return (0, 8, 3)
        case .open: return (0.35, 14, 6)
        case .peek, .banner: return (0.25, 8, 3)
        }
    }

    /// The middle of the notch in the content's frame.
    private func anchor(_ size: CGSize) -> UnitPoint {
        UnitPoint(x: 0.5, y: size.height > 0 ? model.metrics.notchHeight / 2 / size.height : 0)
    }

    @ViewBuilder
    private func content(_ state: IslandState, size: CGSize) -> some View {
        switch state {
        case .closed:
            Color.clear.frame(width: 0, height: 0)
        case .peek:
            PeekContent(model: model, shelf: shelf)
                .frame(width: size.width, height: size.height)
                .transition(swap(size))
        case .banner:
            BannerContent(model: model, act: actions.update)
                .frame(width: size.width, height: size.height)
                .transition(swap(size))
        case .open:
            OpenContent(model: model, shelf: shelf, actions: actions, width: size.width)
                .frame(width: size.width, height: size.height, alignment: .top)
                .transition(swap(size))
        }
    }

    /// From one shown state to another (a capture in the wings to the shelf): the new content grows out of the middle
    /// of the notch from half its size while the body changes shape, the old one goes at once. Out of the closed
    /// island the growth is the whole island's (see `growing`), so nothing more happens here.
    private func swap(_ size: CGSize) -> AnyTransition {
        let fadeOut = AnyTransition.opacity.animation(.easeOut(duration: 0.1))
        guard !reduceMotion, model.previousState != .closed, model.state != .closed else {
            return .asymmetric(insertion: .identity, removal: fadeOut)
        }
        let grow = AnyTransition.modifier(active: IslandReveal(progress: 0, anchor: anchor(size)),
                                          identity: IslandReveal(progress: 1, anchor: anchor(size)))
        return .asymmetric(insertion: grow.animation(Self.spring), removal: fadeOut)
    }
}

/// The island's body and the content of the shown state. The size and corners are the shown state's and follow it
/// from state to state with the spring; `growth` takes the body from hidden behind the notch (0) to its full size (1)
/// and back, with the spring as well (see `IslandGrowth`).
struct IslandSurface<Content: View, Fill: View>: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    var flare: CGFloat
    var radius: CGFloat
    let growth: CGFloat
    /// The body's scale at growth 0: as big as the notch still hides it, or nothing without a notch.
    let hidden: CGFloat
    let origin: CGFloat
    let anchor: UnitPoint
    let spring: Animation
    @ViewBuilder let content: () -> Content
    /// The body drawn from its outline, black, with its shadow; the second value is the growth, from 0 to 1.
    @ViewBuilder let fill: (IslandShape, CGFloat) -> Fill

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(flare, radius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            flare = newValue.second.first
            radius = newValue.second.second
        }
    }

    var body: some View {
        IslandGrowth(width: width, height: height, flare: flare, radius: radius, hidden: hidden, origin: origin,
                     anchor: anchor, growth: growth, content: content, fill: fill)
            .animation(spring, value: growth)
    }
}

/// The body at `growth` and the content in it, worked out together on every frame from the same animated value, so
/// the content keeps its place relative to the body. The body scales evenly about the middle of the notch, from
/// `hidden` to 1. The content grows out of the same point from about a fifth of its size, comes out of a blur and fades
/// in a little behind the body; on the way out it goes the same way back a little ahead of it, so it never spills over
/// the body's edge.
private struct IslandGrowth<Content: View, Fill: View>: View, Animatable {
    let width: CGFloat
    let height: CGFloat
    let flare: CGFloat
    let radius: CGFloat
    let hidden: CGFloat
    let origin: CGFloat
    let anchor: UnitPoint
    var growth: CGFloat
    let content: () -> Content
    let fill: (IslandShape, CGFloat) -> Fill

    var animatableData: CGFloat {
        get { growth }
        set { growth = newValue }
    }

    var body: some View {
        let scale = hidden + (1 - hidden) * growth
        let shape = IslandShape(width: width * scale, height: height * scale, origin: origin, flare: flare,
                                radius: radius * scale)
        let out = min(max(growth, 0), 1)
        let opacity = min(max((growth - 0.12) / 0.5, 0), 1)
        ZStack(alignment: .top) {
            fill(shape, out)
            // Closed, the content is not there at all: nothing to draw, hover or hit.
            if growth > 0.001 {
                content()
                    .scaleEffect(scale * (0.8 + 0.2 * out), anchor: anchor)
                    .blur(radius: (1 - opacity) * 6)
                    .opacity(opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .mask { shape }
            }
        }
    }
}

/// The content of a state that takes over from another shown state: scaled about the middle of the notch, blurred and
/// faded, as FaceID's island shows its content.
struct IslandReveal: ViewModifier {
    let progress: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        // The body it grows in is already there, at the size of the state before: from half the size, and seen by
        // halfway.
        let seen = min(max(progress * 2, 0), 1)
        content
            .scaleEffect(0.5 + 0.5 * progress, anchor: anchor)
            .blur(radius: (1 - seen) * 6)
            .opacity(seen)
    }
}

/// The app's mark in lines, drawn by the same code as the menu bar icon: the frame of strokes and the plus, on whole
/// pixels of the screen it is on.
struct MarkGlyph: View {
    var side: CGFloat
    var lineWidth: CGFloat = IslandMark.lineWidth
    @Environment(\.displayScale) private var scale

    var body: some View {
        MarkShape(lineWidth: lineWidth, scale: scale)
            .fill()
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

private struct MarkShape: Shape {
    let lineWidth: CGFloat
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        return Path(StatusIcon.markOutline(side: side, lineWidth: lineWidth, scale: scale))
            .offsetBy(dx: rect.midX - side / 2, dy: rect.midY - side / 2)
    }
}

// MARK: - Peek

/// The capture that just arrived, in the wings of the notch: its picture on the left, a check mark on the right, each
/// in the middle of its wing and of the notch's height.
private struct PeekContent: View {
    let model: IslandModel
    let shelf: Shelf

    var body: some View {
        let m = model.metrics, wing = IslandMetrics.wing
        let item = model.peekItemID.flatMap { id in shelf.items.first { $0.id == id } }
        HStack(spacing: 0) {
            PeekPreview(item: item, thumbnail: model.peekItemID.flatMap { shelf.thumbnails[$0] },
                        box: CGSize(width: wing - 16, height: max(12, m.notchHeight - 10)))
                .islandProbe("peek.left")
                .frame(width: wing)
            Spacer(minLength: m.notchWidth)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: model.peekItemID)
                .islandProbe("peek.right")
                .frame(width: wing)
        }
        .frame(height: m.notchHeight)
    }
}

/// A picture as big as the wing allows, between portrait and wide (a very tall or very wide one is cropped to that),
/// with a hairline edge so a dark picture does not melt into the island; a file's icon; a symbol for a text.
private struct PeekPreview: View {
    let item: ShelfItem?
    let thumbnail: NSImage?
    let box: CGSize

    var body: some View {
        if item?.kind == .text {
            Image(systemName: "text.alignleft")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        } else if let thumbnail, item?.kind == .file {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: box.height, height: box.height)
        } else if let thumbnail {
            let size = frame(for: thumbnail)
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                }
        } else {
            Image(systemName: "photo")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func frame(for image: NSImage) -> CGSize {
        let pixels = item.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) } ?? .zero
        let source = pixels.width > 0 && pixels.height > 0 ? pixels : image.size
        let aspect = min(max(source.width / max(source.height, 1), 0.75), 1.6)
        if aspect >= box.width / box.height { return CGSize(width: box.width, height: (box.width / aspect).rounded()) }
        return CGSize(width: (box.height * aspect).rounded(), height: box.height)
    }
}

// MARK: - Banner

/// A short message under the notch, in the middle; a long one wraps onto a second line. A new version has its buttons
/// on the same line, after the text.
private struct BannerContent: View {
    let model: IslandModel
    let act: (UpdateCommand) -> Void

    var body: some View {
        let m = model.metrics, layout = model.bannerLayout
        VStack(spacing: 0) {
            Color.clear.frame(height: m.notchHeight + IslandMetrics.rowGap)
            HStack(spacing: IslandMetrics.bannerButtonGap) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: model.bannerSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IslandStyle.tint(for: model.bannerSymbol))
                    Text(model.bannerText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(model.bannerActions.isEmpty ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.bannerActions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(model.bannerActions, id: \.title) { action in
                            Button(action.title) { act(action.command) }
                                .buttonStyle(IslandButtonStyle(kind: action.kind))
                                .help(action.help ?? "")
                        }
                    }
                    .fixedSize()
                }
            }
            .islandProbe("banner")
            .frame(height: layout.textHeight)
            .padding(.horizontal, IslandMetrics.padding)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Open shelf

private struct OpenContent: View {
    let model: IslandModel
    let shelf: Shelf
    let actions: IslandActions
    let width: CGFloat

    var body: some View {
        let m = model.metrics, p = IslandMetrics.padding
        VStack(spacing: 0) {
            ShelfHeader(count: shelf.items.count, toast: model.toast, notchWidth: m.notchWidth, actions: actions)
                .frame(width: width, height: m.notchHeight)
            Color.clear.frame(height: IslandMetrics.rowGap)
            if let row = model.updateRow {
                UpdateRow(row: row, width: width - 2 * p, act: actions.update)
                    .islandProbe("update")
                    .frame(width: width - 2 * p, height: row.height(width: width - 2 * p))
                    .transition(.opacity)
                Color.clear.frame(height: IslandMetrics.rowGap)
            }
            ZStack {
                if shelf.items.isEmpty {
                    EmptyShelf()
                        .opacity(model.dropTargeted ? 0 : 1)
                } else {
                    // Under the drop target the cards step back, so its words stand clear.
                    ShelfStrip(model: model, shelf: shelf, actions: actions, width: width)
                        .opacity(model.dropTargeted ? 0.15 : 1)
                }
                if model.dropTargeted {
                    DropTarget()
                        .islandProbe("drop")
                        .padding(.horizontal, p)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: IslandMetrics.stripHeight)
            .animation(.easeOut(duration: 0.15), value: model.dropTargeted)
            Spacer(minLength: 0)
        }
        .animation(IslandRootView.spring, value: model.updateRow)
    }
}

/// The row at the notch's height: the mark, "Полка" and the number of cards on the left, the buttons on the right,
/// both 16 pt from the island's edge, clear of the notch and in the middle of its height. A short confirmation takes
/// the title's place for a moment.
private struct ShelfHeader: View {
    let count: Int
    let toast: IslandToast?
    let notchWidth: CGFloat
    let actions: IslandActions

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if let toast {
                    HStack(spacing: 6) {
                        Image(systemName: toast.symbol)
                            .foregroundStyle(IslandStyle.tint(for: toast.symbol))
                        Text(toast.text)
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .transition(.opacity)
                } else {
                    HStack(spacing: 6) {
                        MarkGlyph(side: IslandMark.titleSide)
                        Text(L("Полка"))
                            .font(.system(size: 13, weight: .semibold))
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .transition(.opacity)
                }
            }
            .lineLimit(1)
            .islandProbe("header.left")
            .animation(.easeOut(duration: 0.2), value: toast)
            Spacer(minLength: notchWidth + 2 * IslandMetrics.notchGap)
            HStack(spacing: 4) {
                HeaderButton(help: L("Умный снимок"), action: actions.capture) {
                    MarkGlyph(side: IslandMark.buttonSide)
                }
                HeaderButton(help: L("Открыть папку снимков"), action: actions.openFolder) {
                    Image(systemName: "folder")
                }
                if count > 0 {
                    HeaderButton(help: L("Очистить полку (файлы останутся)"), action: actions.clear) {
                        Image(systemName: "trash")
                    }
                }
                HeaderButton(help: L("Настройки"), action: actions.openSettings) {
                    Image(systemName: "gearshape")
                }
            }
            .islandProbe("header.right")
        }
        .padding(.horizontal, IslandMetrics.padding)
    }
}

/// The cards: in the middle while they fit, otherwise a strip that scrolls from the left margin and fades out at both
/// edges.
private struct ShelfStrip: View {
    let model: IslandModel
    let shelf: Shelf
    let actions: IslandActions
    let width: CGFloat

    private static let stripStart = "start"
    /// Room above and below the cards inside the scrolling strip for a card that lifts under the pointer.
    private static let lift: CGFloat = 8

    var body: some View {
        let p = IslandMetrics.padding, spacing = IslandMetrics.cardSpacing
        if model.stripWidth(count: shelf.items.count) <= width - 2 * p + 0.5 {
            HStack(spacing: spacing) { cards }
                .islandProbe("cards")
                .frame(width: width, height: IslandMetrics.stripHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        // The very start of the strip, margin included, so the newest card shows whole.
                        Color.clear.frame(width: 0, height: 0).id(Self.stripStart)
                        HStack(spacing: spacing) { cards }
                            .islandProbe("cards")
                            .padding(.horizontal, p)
                            .padding(.vertical, Self.lift)
                    }
                }
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: p / width),
                                           .init(color: .black, location: 1 - p / width), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .onChange(of: shelf.items.first?.id) { _, id in
                    if id != nil { withAnimation { proxy.scrollTo(Self.stripStart, anchor: .leading) } }
                }
                .onChange(of: model.selectedItemID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
                }
            }
            .frame(width: width, height: IslandMetrics.stripHeight + 2 * Self.lift)
            .padding(.vertical, -Self.lift)
        }
    }

    private var cards: some View {
        ForEach(shelf.items) { item in
            ShelfCard(item: item, thumbnail: shelf.thumbnails[item.id], text: shelf.texts[item.id],
                      hovering: model.hoveredItemID == item.id, highlighted: model.highlightedItemID == item.id,
                      selected: model.selectedItemID == item.id, actions: actions) { inside in
                if inside {
                    model.hoveredItemID = item.id
                } else if model.hoveredItemID == item.id {
                    model.hoveredItemID = nil
                }
            }
            .id(item.id)
        }
    }
}

private struct EmptyShelf: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 4)
            Text(L("Здесь будут ваши снимки"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(L("Перетащите сюда файлы или текст"))
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)
        }
        .lineLimit(1)
        .islandProbe("empty")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Files or text are dragged over the shelf: where they will go.
private struct DropTarget: View {
    var body: some View {
        // Nearly opaque, so the cards it covers do not show through its words.
        RoundedRectangle(cornerRadius: IslandMetrics.cardRadius, style: .continuous)
            .fill(Color(white: 0.07).opacity(0.94))
            .overlay {
                RoundedRectangle(cornerRadius: IslandMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .overlay {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text(L("Отпустите, чтобы положить на полку"))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            }
    }
}

private struct ShelfCard: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    /// The beginning of a text item.
    let text: String?
    /// Under the pointer: lifted, with its quick buttons.
    let hovering: Bool
    /// Just arrived: lifted for a moment.
    let highlighted: Bool
    /// Chosen with a click or the arrow keys, as in Finder: a lighter card with a blue ring, the caption on blue.
    let selected: Bool
    let actions: IslandActions
    let hovered: (Bool) -> Void
    @GestureState private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let card = IslandMetrics.card
    private let radius = IslandMetrics.cardRadius

    var body: some View {
        VStack(spacing: IslandMetrics.captionGap) {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.16) : IslandStyle.plate)
                preview
                if hovering {
                    // Shade under the quick buttons, so they sit clear of a picture or a text.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 36)
                        Spacer(minLength: 0)
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.85), location: 0.6),
                                               .init(color: .black.opacity(0.85), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 46)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: card.width, height: card.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(IslandStyle.accent, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    // A capture of this app goes to the Trash; anything brought from elsewhere only leaves the shelf.
                    Group {
                        if item.isCapture {
                            CardButton(symbol: "trash", help: L("Удалить снимок (в Корзину)")) { actions.trash(item) }
                        } else {
                            CardButton(symbol: "xmark", help: L("Убрать с полки")) { actions.remove(item) }
                        }
                    }
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if hovering {
                    HStack(spacing: 8) {
                        CardButton(symbol: "doc.on.doc", help: L("Скопировать")) { actions.copy(item) }
                        switch item.kind {
                        case .image:
                            CardButton(symbol: "pencil.tip.crop.circle", help: L("Редактировать")) { actions.edit(item) }
                        case .file, .text:
                            CardButton(symbol: "arrow.up.forward.app", help: L("Открыть")) { actions.open(item) }
                        }
                        if item.kind != .text {
                            CardButton(symbol: "magnifyingglass", help: L("Показать в Finder")) { actions.reveal(item) }
                        }
                    }
                    .padding(8)
                    .transition(.opacity)
                }
            }
            // A capture that just arrived lifts like a card under the pointer; a pressed card sinks a little.
            .scaleEffect(reduceMotion ? 1 : (pressed && hovering ? 0.97 : (hovering || highlighted ? 1.03 : 1)))
            .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 8, y: 3)

            Text(caption)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(selected ? 1 : (hovering ? 0.85 : 0.6)))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .frame(height: IslandMetrics.captionHeight)
                .background(Capsule().fill(selected ? IslandStyle.accent : .clear))
                .frame(width: card.width)
        }
        .contentShape(Rectangle())
        .onHover { inside in hovered(inside) }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: highlighted)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: pressed)
        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
        // A click chooses the card (and gives the shelf the keyboard), a double click opens it.
        .onTapGesture { actions.select(item) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if item.kind == .image { actions.edit(item) } else { actions.open(item) }
        })
        .contextMenu {
            switch item.kind {
            case .image:
                Button(L("Редактировать")) { actions.edit(item) }
                Button(L("Открыть")) { actions.open(item) }
                Divider()
                Button(L("Скопировать")) { actions.copy(item) }
                Button(L("Скопировать текст с картинки")) { actions.copyText(item) }
                Button(L("Показать в Finder")) { actions.reveal(item) }
                if item.shelfOnly {
                    Button(L("Сохранить в папку снимков")) { actions.keep(item) }
                }
            case .file:
                Button(L("Открыть")) { actions.open(item) }
                Divider()
                Button(L("Скопировать")) { actions.copy(item) }
                Button(L("Показать в Finder")) { actions.reveal(item) }
            case .text:
                Button(L("Открыть")) { actions.open(item) }
                Divider()
                Button(L("Скопировать")) { actions.copy(item) }
            }
            Divider()
            Button(L("Убрать с полки")) { actions.remove(item) }
            if item.kind != .text {
                Button(L("Удалить файл"), role: .destructive) { actions.trash(item) }
            }
        }
        .help(item.kind == .text ? String((text ?? "").prefix(300)) : item.url.lastPathComponent)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .image, .file:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    // Icons of folders and archives would fill the card edge to edge.
                    .padding(item.kind == .image ? 4 : 12)
            } else {
                ProgressView().controlSize(.small)
            }
        case .text:
            Text(text ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var caption: String {
        if item.kind == .file { return item.url.lastPathComponent }
        let time = Calendar.current.isDateInToday(item.date)
            ? item.date.formatted(date: .omitted, time: .shortened)
            : item.date.formatted(.dateTime.day().month(.abbreviated))
        guard item.pixelWidth > 0, Self.captionHasSize else { return time }
        return "\(time) · \(item.pixelWidth)×\(item.pixelHeight)"
    }

    /// Whether a capture's caption has room for its size after the time. With a 12-hour clock ("10:21 AM") it has
    /// not, and then no card shows the size, so the captions stay alike.
    private static let captionHasSize: Bool = {
        let late = Calendar.current.date(bySettingHour: 12, minute: 58, second: 0, of: Date()) ?? Date()
        let sample = "\(late.formatted(date: .omitted, time: .shortened)) · 8888×8888"
        return IslandText.width(sample, size: 11, monospacedDigits: true) <= IslandMetrics.card.width - 12
    }()
}

/// What follows the pointer while a card is dragged out (see `IslandController.beginDrag`): the picture
/// alone, its transparent corners and window shadow left transparent, or a dark card with the beginning of
/// a text. No card plate, caption or buttons.
struct ShelfDragPreview: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    let text: String?

    var body: some View {
        if item.kind == .text {
            Text(text ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: IslandMetrics.card.width, height: IslandMetrics.card.height)
                .background(RoundedRectangle(cornerRadius: IslandMetrics.cardRadius, style: .continuous).fill(Color.black.opacity(0.85)))
                .environment(\.colorScheme, .dark)
        } else if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: IslandMetrics.card.width, maxHeight: IslandMetrics.card.height)
        }
    }
}

// MARK: - Update

/// A new version, across the shelf above the cards: what it is on the left, the choice on the right. Then the download
/// with its progress, the installation, or what went wrong and what to do about it.
private struct UpdateRow: View {
    let row: IslandUpdate
    let width: CGFloat
    let act: (UpdateCommand) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(row.failed ? Color.orange : IslandStyle.accent)
                .frame(width: IslandUpdate.symbolBox)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .padding(.horizontal, IslandUpdate.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: IslandMetrics.cardRadius, style: .continuous).fill(IslandStyle.plate))
    }

    @ViewBuilder
    private var detail: some View {
        switch row.detail {
        case .progress(let progress):
            HStack(spacing: 8) {
                ProgressBar(value: progress)
                Text("\(Int((progress * 100).rounded())) %")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(IslandStyle.secondaryText)
                    .frame(width: 36, alignment: .trailing)
            }
            .frame(height: 15)
        case .text(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)
                .lineLimit(row.detailLines(width: width))
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if row.busy {
            IslandSpinner()
                .frame(width: 20)
        } else {
            HStack(spacing: 8) {
                ForEach(row.actions, id: \.title) { action in
                    Button(action.title) { act(action.command) }
                        .buttonStyle(IslandButtonStyle(kind: action.kind))
                        .help(action.help ?? "")
                }
            }
            .fixedSize()
        }
    }
}

/// A ring turning while the new version is put in place.
private struct IslandSpinner: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.8)
            .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// A thin bar for a download.
private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(IslandStyle.accent)
                    .frame(width: max(4, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

// MARK: - Buttons

/// Text buttons in the island: blue for the main choice, translucent for the second, bare text for the least.
private struct IslandButtonStyle: ButtonStyle {
    let kind: IslandUpdate.Kind

    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(kind: kind, configuration: configuration)
    }
}

private struct IslandButtonBody: View {
    let kind: IslandUpdate.Kind
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 12, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .plain ? 4 : 12)
            .frame(height: IslandMetrics.buttonHeight)
            .background(Capsule().fill(background(pressed: pressed)))
            .contentShape(Capsule())
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.95 : 1))
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .white.opacity(0.92)
        case .plain: return .white.opacity(hovering ? 0.92 : 0.6)
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return IslandStyle.accent.opacity(pressed ? 0.75 : (hovering ? 1 : 0.9))
        case .secondary: return Color.white.opacity(pressed ? 0.26 : (hovering ? 0.2 : 0.14))
        case .plain: return Color.white.opacity(pressed ? 0.14 : 0)
        }
    }
}

/// An icon button in the header.
private struct HeaderButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) { label() }
            .buttonStyle(HeaderButtonStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderButtonBody(configuration: configuration)
    }
}

private struct HeaderButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(hovering || pressed ? 1 : 0.75))
            .frame(width: 28, height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(pressed ? 0.22 : (hovering ? 0.14 : 0))))
            .contentShape(Rectangle())
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.92 : 1))
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A round translucent button on a card.
private struct CardButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(CardButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration)
    }
}

private struct CardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.black.opacity(pressed ? 0.95 : (hovering ? 0.85 : 0.6))))
            .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.4 : 0.25), lineWidth: 0.5))
            .contentShape(Circle())
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.9 : 1))
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Probe

/// Where the island's parts end up, for `--render-previews` to check that what should be centred is. Off in the app.
@MainActor
enum IslandProbe {
    static var isEnabled = false
    static var frames: [String: CGRect] = [:]
    static let space = "island"
}

struct IslandProbeKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view's frame in the island under `name` while `IslandProbe.isEnabled`.
    @MainActor @ViewBuilder
    func islandProbe(_ name: String) -> some View {
        if IslandProbe.isEnabled {
            background(GeometryReader { proxy in
                Color.clear.preference(key: IslandProbeKey.self, value: [name: proxy.frame(in: .named(IslandProbe.space))])
            })
        } else {
            self
        }
    }
}
