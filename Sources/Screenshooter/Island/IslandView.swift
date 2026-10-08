import ShotCore
import SwiftUI
import UniformTypeIdentifiers

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
    var drop: ([URL]) -> Void
    var dragStarted: () -> Void
}

struct IslandRootView: View {
    @Bindable var model: IslandModel
    let shelf: Shelf
    let actions: IslandActions

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    var body: some View {
        let size = model.size
        let radii = model.metrics.radii(for: model.state)
        let shape = IslandShape(topRadius: radii.top, bottomRadius: radii.bottom)

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(model.state == .open ? 0.45 : (model.state == .closed ? 0 : 0.25)),
                        radius: model.state == .open ? 18 : 8, y: model.state == .open ? 8 : 3)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
            if model.dropTargeted {
                shape
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(1)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(model.isVisible ? 1 : 0)
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
            loadURLs(providers)
            return true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: model.state)
        .animation(spring, value: model.metrics)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .closed:
            Color.clear
        case .peek:
            PeekContent(model: model, shelf: shelf)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .banner:
            BannerContent(model: model)
                .transition(.opacity)
        case .open:
            OpenContent(model: model, shelf: shelf, actions: actions)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }

    private func loadURLs(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { actions.drop(urls) }
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
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
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
                            Text(L("Снимки"))
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

            if shelf.items.isEmpty {
                EmptyShelf()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(shelf.items) { item in
                                ShelfCard(item: item, thumbnail: shelf.thumbnails[item.id],
                                          highlighted: model.highlightedItemID == item.id, actions: actions)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, 10)
                    }
                    .onChange(of: shelf.items.first?.id) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .leading) } }
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
            Text(L("Перетащите сюда картинку, чтобы положить её на полку"))
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
    let highlighted: Bool
    let actions: IslandActions
    @State private var hovering = false

    private let cardSize = CGSize(width: 132, height: 84)

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(highlighted ? 0.9 : (hovering ? 0.45 : 0.12)),
                                  lineWidth: highlighted ? 1.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if hovering {
                    CardButton(symbol: "xmark", help: L("Убрать с полки")) { actions.remove(item) }
                        .padding(5)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if hovering {
                    HStack(spacing: 6) {
                        CardButton(symbol: "doc.on.doc", help: L("Скопировать")) { actions.copy(item) }
                        CardButton(symbol: "pencil.tip.crop.circle", help: L("Редактировать")) { actions.edit(item) }
                        CardButton(symbol: "magnifyingglass", help: L("Показать в Finder")) { actions.reveal(item) }
                    }
                    .padding(6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 8, y: 3)

            Text(caption)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.55))
                .lineLimit(1)
                .frame(width: cardSize.width)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture { actions.edit(item) }
        .onDrag {
            actions.dragStarted()
            let provider = NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
            provider.suggestedName = item.url.lastPathComponent
            return provider
        }
        .contextMenu {
            Button(L("Редактировать")) { actions.edit(item) }
            Button(L("Открыть")) { actions.open(item) }
            Divider()
            Button(L("Скопировать")) { actions.copy(item) }
            Button(L("Скопировать текст с картинки")) { actions.copyText(item) }
            Button(L("Показать в Finder")) { actions.reveal(item) }
            if item.shelfOnly {
                Button(L("Сохранить в папку снимков")) { actions.keep(item) }
            }
            Divider()
            Button(L("Убрать с полки")) { actions.remove(item) }
            Button(L("Удалить файл"), role: .destructive) { actions.trash(item) }
        }
        .help(item.url.lastPathComponent)
    }

    private var caption: String {
        let time = Calendar.current.isDateInToday(item.date)
            ? item.date.formatted(date: .omitted, time: .shortened)
            : item.date.formatted(.dateTime.day().month(.abbreviated))
        guard item.pixelWidth > 0 else { return time }
        return "\(time) · \(item.pixelWidth)×\(item.pixelHeight)"
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
