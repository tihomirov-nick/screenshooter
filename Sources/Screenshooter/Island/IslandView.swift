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

struct IslandRootView: View {
    let model: IslandModel
    let shelf: Shelf
    let actions: IslandActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Dynamic Island's spring, the same as in FaceID: quick, with a little overshoot.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)

    var body: some View {
        let size = model.size
        let radii = model.metrics.radii(for: model.state)
        let shape = IslandShape(topRadius: radii.top, bottomRadius: radii.bottom)
        let animation = reduceMotion ? Animation.easeInOut(duration: 0.15) : Self.spring

        // The body grows out of the notch: pinned to the top edge, evenly to both sides of the notch's centre. The
        // content is laid out at its final size from the start and comes out of a blur a moment later, once the body
        // is opening, so nothing slides across the menu bar.
        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(model.state == .open ? 0.45 : (model.state == .closed ? 0 : 0.25)),
                        radius: model.state == .open ? 18 : 8, y: model.state == .open ? 8 : 3)
                .frame(width: size.width, height: size.height)
            content
                .mask(alignment: .top) {
                    shape.frame(width: size.width, height: size.height)
                }
        }
        // While something is dragged over it, the whole island, content included, grows a touch from the top edge.
        .scaleEffect(model.dragOver ? 1 + IslandMetrics.dragGrowth : 1, anchor: .top)
        .opacity(model.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: model.state)
        .animation(animation, value: model.metrics)
        .animation(animation, value: model.dragOver)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        let metrics = model.metrics
        switch model.state {
        case .closed:
            Color.clear.frame(width: 0, height: 0)
        case .peek:
            PeekContent(model: model, shelf: shelf)
                .frame(width: metrics.size(for: .peek).width, height: metrics.size(for: .peek).height)
                .transition(appearing)
        case .banner:
            BannerContent(model: model)
                .frame(width: metrics.size(for: .banner).width, height: metrics.size(for: .banner).height)
                .transition(appearing)
        case .open:
            OpenContent(model: model, shelf: shelf, actions: actions)
                .frame(width: metrics.size(for: .open).width, height: metrics.size(for: .open).height, alignment: .top)
                .transition(appearing)
        }
    }

    /// In: out of a blur where it stands, a moment after the body starts to grow. Out: gone at once, before the body
    /// shrinks back into the notch.
    private var appearing: AnyTransition {
        let blur = AnyTransition.modifier(active: IslandContentTransition(progress: 0),
                                          identity: IslandContentTransition(progress: 1))
        return .asymmetric(insertion: blur.animation(reduceMotion ? .easeOut(duration: 0.15) : Self.spring.delay(0.08)),
                           removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
}

/// Content appears the way the Dynamic Island shows it (and FaceID's island): out of a blur, growing from the top.
struct IslandContentTransition: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 10)
            .scaleEffect(0.85 + 0.15 * progress, anchor: .top)
    }
}

// MARK: - Peek

private struct PeekContent: View {
    let model: IslandModel
    let shelf: Shelf

    var body: some View {
        let h = model.metrics.notchHeight
        HStack(spacing: 0) {
            Group {
                if let id = model.peekItemID, let image = shelf.thumbnails[id] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "photo").foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: IslandMetrics.wing - 14, height: h - 12)
            .padding(.leading, 6 + 6)
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: model.peekItemID)
                .padding(.trailing, 6 + 10)
        }
        .frame(height: h)
    }
}

// MARK: - Banner

private struct BannerContent: View {
    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.metrics.notchHeight)
            Label(model.bannerText, systemImage: model.bannerSymbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Open shelf

private struct OpenContent: View {
    let model: IslandModel
    let shelf: Shelf
    let actions: IslandActions

    private static let stripStart = "start"

    var body: some View {
        let metrics = model.metrics
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if let toast = model.toast {
                        Label(toast, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white, .green)
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 13, weight: .semibold))
                            Text(L("Полка"))
                                .font(.system(size: 13, weight: .semibold))
                            if !shelf.items.isEmpty {
                                Text("\(shelf.items.count)")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.white.opacity(0.14)))
                            }
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .transition(.opacity)
                    }
                }
                .lineLimit(1)
                .animation(.easeOut(duration: 0.2), value: model.toast)
                .padding(.leading, 30)
                Spacer(minLength: metrics.notchWidth + 24)
                HStack(spacing: 4) {
                    IslandIconButton(symbol: "camera.metering.matrix", help: L("Умный снимок"), action: actions.capture)
                    IslandIconButton(symbol: "folder", help: L("Открыть папку снимков"), action: actions.openFolder)
                    if !shelf.items.isEmpty {
                        IslandIconButton(symbol: "trash", help: L("Очистить полку (файлы останутся)"),
                                         action: actions.clear)
                    }
                    IslandIconButton(symbol: "gearshape", help: L("Настройки"), action: actions.openSettings)
                }
                .padding(.trailing, 26)
            }
            .frame(height: metrics.notchHeight)

            if shelf.items.isEmpty, model.update == nil {
                EmptyShelf()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            // The very start of the strip, margin included, so the newest card shows whole.
                            Color.clear.frame(width: 0, height: 0).id(Self.stripStart)
                            LazyHStack(spacing: 10) {
                                if let update = model.update {
                                    UpdateCard(state: update, act: actions.update)
                                }
                                ForEach(shelf.items) { item in
                                    ShelfCard(item: item, thumbnail: shelf.thumbnails[item.id], text: shelf.texts[item.id],
                                              highlighted: model.highlightedItemID == item.id,
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
                            .padding(.horizontal, 26)
                            .padding(.top, 10)
                        }
                    }
                    .onChange(of: shelf.items.first?.id) { _, id in
                        if id != nil { withAnimation { proxy.scrollTo(Self.stripStart, anchor: .leading) } }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

private struct EmptyShelf: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text(L("Здесь будут ваши снимки"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(L("Перетащите сюда файлы или текст"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }
}

private struct ShelfCard: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    /// The beginning of a text item.
    let text: String?
    let highlighted: Bool
    /// Chosen with a click, as in Finder: a lighter card and the caption on the accent colour.
    let selected: Bool
    let actions: IslandActions
    let hovered: (Bool) -> Void
    @State private var hovering = false

    private let cardSize = CGSize(width: 132, height: 84)

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.2 : 0.07))
                preview
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    .padding(5)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if hovering {
                    HStack(spacing: 6) {
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
                    .padding(6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // A capture that just arrived lifts like a card under the pointer.
            .scaleEffect(hovering || highlighted ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 8, y: 3)

            Text(caption)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(selected ? 1 : (hovering ? 0.85 : 0.55)))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .background(Capsule().fill(selected ? Color.accentColor : .clear))
                .frame(width: cardSize.width)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            hovered(inside)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: highlighted)
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
                    .padding(item.kind == .image ? 3 : 8)
            } else {
                ProgressView().controlSize(.small)
            }
        case .text:
            Text(text ?? "")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
        }
    }

    private var caption: String {
        if item.kind == .file { return item.url.lastPathComponent }
        let time = Calendar.current.isDateInToday(item.date)
            ? item.date.formatted(date: .omitted, time: .shortened)
            : item.date.formatted(.dateTime.day().month(.abbreviated))
        guard item.pixelWidth > 0 else { return time }
        return "\(time) · \(item.pixelWidth)×\(item.pixelHeight)"
    }
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
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(width: 132, height: 84)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.85)))
                .environment(\.colorScheme, .dark)
        } else if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 132, maxHeight: 84)
        }
    }
}

/// A new version in the shelf: what is new and the choice, then the download, the installation or what went wrong.
private struct UpdateCard: View {
    let state: Updater.State
    let act: (UpdateCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white, tint)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 290, height: 103, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var release: Updater.Release? { state.islandRelease }

    private var title: String {
        switch state {
        case .downloading(let release, _): return L("Загрузка версии %@", release.version)
        case .installing(let release): return L("Установка версии %@", release.version)
        case .failed: return L("Не удалось обновить")
        default: return L("Доступна версия %@", release?.version ?? "")
        }
    }

    private var symbol: String {
        if case .failed = state { return "exclamationmark.triangle.fill" }
        return "arrow.down.circle.fill"
    }

    private var tint: Color {
        if case .failed = state { return .orange }
        return Color(red: 0.18, green: 0.52, blue: 1)
    }

    private var detail: String {
        switch state {
        case .failed(let failure, _): return failure.message
        case .installing: return L("Screenshooter перезапустится сам")
        default: return release.map { $0.summary.isEmpty ? $0.title : $0.summary } ?? ""
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .downloading(_, let progress):
            HStack(spacing: 8) {
                ProgressTrack(progress: progress)
                Text("\(Int((progress * 100).rounded())) %")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                IslandTextButton(title: L("Отмена")) { act(.cancel) }
            }
        case .installing:
            ProgressTrack(progress: nil)
        case .failed(let failure, _):
            HStack(spacing: 6) {
                IslandTextButton(title: failure == .cannotReplace ? L("Открыть DMG") : L("Страница релиза"), prominent: true) {
                    act(.page)
                }
                IslandTextButton(title: L("Позже")) { act(.later) }
            }
        default:
            HStack(spacing: 6) {
                IslandTextButton(title: L("Обновить"), prominent: true) { act(.install) }
                IslandTextButton(title: L("Позже")) { act(.later) }
                IslandTextButton(title: L("Пропустить")) { act(.skip) }
            }
        }
    }
}

/// A thin bar for a download; without a value it shows that something is going on.
private struct ProgressTrack: View {
    let progress: Double?
    @State private var phase = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                if let progress {
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: max(4, proxy.size.width * progress))
                } else {
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: proxy.size.width / 3)
                        .offset(x: phase ? proxy.size.width * 2 / 3 : 0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                }
            }
        }
        .frame(height: 4)
    }
}

/// A small text button in the island: white for the main choice, translucent for the rest.
private struct IslandTextButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white.opacity(hovering ? 1 : 0.85))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.9)
                                                     : Color.white.opacity(hovering ? 0.22 : 0.14)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Round translucent button on a card.
private struct CardButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.85 : 0.6)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Icon button in the island's header.
private struct IslandIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.14 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
