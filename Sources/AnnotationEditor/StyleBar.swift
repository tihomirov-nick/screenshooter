import ShotCore
import SwiftUI

/// Window state shown in the style bar besides the document itself.
final class EditorChrome: ObservableObject {
    @Published var magnification: CGFloat = 1
    /// A short confirmation such as "Скопировано", cleared after a moment.
    @Published var message: String?
}

struct StyleBarActions {
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var fit: () -> Void
    var applyCrop: () -> Void
    var cancelCrop: () -> Void
    var resetCrop: () -> Void
}

/// The bar under the toolbar: colors, widths, fill, text size (or the crop controls), file info and zoom.
struct StyleBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var chrome: EditorChrome
    let actions: StyleBarActions

    /// Controls follow the selected annotation when there is one, otherwise the tool.
    private var selected: Annotation? {
        model.annotation(model.editingTextID) ?? model.selectedAnnotation
    }

    private func isPixelate(_ a: Annotation) -> Bool {
        if case .pixelate = a.shape { return true }
        return false
    }

    private var showsColors: Bool {
        if let a = selected { return !isPixelate(a) }
        return model.tool != .pixelate
    }

    private var showsWidths: Bool {
        if let a = selected { return !a.isText && !isPixelate(a) }
        return model.tool != .text && model.tool != .pixelate
    }

    private var fillShape: String? {
        if let a = selected {
            switch a.shape {
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            default: return nil
            }
        }
        switch model.tool {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        default: return nil
        }
    }

    private var showsTextSize: Bool {
        selected?.isText ?? (model.tool == .text)
    }

    private var showsPixelateHint: Bool {
        selected.map(isPixelate) ?? (model.tool == .pixelate)
    }

    var body: some View {
        HStack(spacing: 10) {
            if model.tool == .crop {
                cropControls
            } else {
                styleControls
            }
            Spacer(minLength: 8)
            if let message = chrome.message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Text(info)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            zoomControls
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: chrome.message)
    }

    private var info: String {
        let size = model.tool == .crop ? (model.pendingCrop?.integral.size ?? model.imageRect.size) : model.outputSize
        return "\(model.url.lastPathComponent) · \(Int(size.width)) × \(Int(size.height))"
    }

    // MARK: Style

    @ViewBuilder private var styleControls: some View {
        if showsColors {
            HStack(spacing: 2) {
                ForEach(RGBA.palette, id: \.self) { color in
                    ColorSwatch(color: color, selected: model.color == color) { model.setColor(color) }
                }
                ColorPicker(L("Свой цвет"), selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30)
                    .help(L("Свой цвет"))
            }
            Divider().frame(height: 18)
        }
        if showsWidths {
            HStack(spacing: 2) {
                ForEach(WidthPreset.allCases) { preset in
                    BarButton(selected: model.widthPreset == preset, help: preset.title) {
                        model.setWidth(preset)
                    } label: {
                        Capsule()
                            .frame(width: 16, height: [1.5, 3, 5][preset.rawValue])
                    }
                }
            }
        }
        if let shape = fillShape {
            Divider().frame(height: 18)
            HStack(spacing: 2) {
                BarButton(selected: !model.filled, help: L("Контур")) { model.setFilled(false) } label: {
                    Image(systemName: shape)
                }
                BarButton(selected: model.filled, help: L("Заливка")) { model.setFilled(true) } label: {
                    Image(systemName: shape + ".fill")
                }
            }
        }
        if showsTextSize {
            HStack(spacing: 2) {
                ForEach(TextSizePreset.allCases) { preset in
                    BarButton(selected: model.textSize == preset, help: preset.title) {
                        model.setTextSize(preset)
                    } label: {
                        Text(preset.shortTitle)
                            .font(.system(size: [10, 12, 15][preset.rawValue], weight: .bold, design: .rounded))
                    }
                }
            }
        }
        if model.editingTextID != nil {
            Text(L("Esc — закончить ввод"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if showsPixelateHint {
            Text(L("Выделите область, которую нужно скрыть"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: model.color.nsColor) },
            set: { model.setColor(RGBA(NSColor($0))) }
        )
    }

    // MARK: Crop

    @ViewBuilder private var cropControls: some View {
        Image(systemName: "crop")
            .foregroundStyle(.secondary)
        Text(model.pendingCrop == nil ? L("Выделите область, которую нужно оставить") : L("Перетащите края рамки или нажмите Return"))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        Button(L("Сбросить"), action: actions.resetCrop)
            .disabled(model.state.crop == nil && model.pendingCrop == nil)
        Button(L("Отмена"), action: actions.cancelCrop)
        Button(L("Применить"), action: actions.applyCrop)
            .buttonStyle(.borderedProminent)
            .disabled(model.pendingCrop == nil)
    }

    // MARK: Zoom

    private var zoomControls: some View {
        HStack(spacing: 0) {
            BarButton(help: L("Уменьшить (⌘−)"), action: actions.zoomOut) {
                Image(systemName: "minus.magnifyingglass")
            }
            Text("\(Int((chrome.magnification * 100).rounded())) %")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
            BarButton(help: L("Увеличить (⌘+)"), action: actions.zoomIn) {
                Image(systemName: "plus.magnifyingglass")
            }
            BarButton(help: L("Вписать в окно (⌘0)"), action: actions.fit) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
        }
    }
}

/// A small borderless button with hover and selected states.
struct BarButton<Label: View>: View {
    var selected = false
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct ColorSwatch: View {
    let color: RGBA
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(nsColor: color.nsColor))
                Circle().strokeBorder(Color.primary.opacity(color.luminance > 0.85 ? 0.35 : 0.12), lineWidth: 1)
            }
            .frame(width: 16, height: 16)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.paletteName)
    }
}
