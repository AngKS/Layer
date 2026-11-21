import SwiftUI
import UIKit

/// The panel that opens from the left: the design's layers, or its generated SwiftUI.
struct LayersPanel: View {
    @Environment(AppModel.self) private var model
    /// The screen whose code is shown; the first screen until another is picked.
    @State private var codeScreenID: DesignScreen.ID?
    /// In a narrow window the panel fills a sheet rather than floating beside the canvas.
    var isSheet = false
    /// The room there is for the floating panel.
    var maxHeight: CGFloat = 560

    var body: some View {
        let content = VStack(spacing: 0) {
            tabs
                .padding(12)
            switch model.panelTab {
            case .layers: LayersList()
            case .code: CodePane(screenID: $codeScreenID)
            }
        }
        if isSheet {
            content
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            content
                .frame(width: 300)
                .frame(maxHeight: min(560, maxHeight), alignment: .top)
                .background(.background, in: .rect(cornerRadius: 26, style: .continuous))
                .clipShape(.rect(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 22, y: 8)
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tab("Layers", .layers)
            tab("Code", .code)
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
    }

    private func tab(_ title: String, _ tab: AppModel.PanelTab) -> some View {
        let isActive = model.panelTab == tab
        return Button {
            withAnimation(.snappy(duration: 0.2)) { model.panelTab = tab }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isActive ? Color.white : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: Layers

/// The design's layers, topmost first under each screen, then those on the open canvas. Only
/// this reads the design, the selection and the hover, which change on every frame of a drag
/// and every move of the pencil: each row is given what it shows, and is built again only
/// when that changes.
private struct LayersList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let selection = model.selection
        let hovered = model.hovered
        ScrollView {
            // Not lazy: a lazy stack built every row in view again on every change to the
            // design, whether or not what the row shows had changed.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.screens) { screen in
                    let target = CanvasSelection.screen(screen.id)
                    LayerGroupRow(
                        model: model, name: screen.name, symbol: screen.device.size.width > 600 ? "ipad" : "iphone", target: target,
                        isSelected: selection?.contains(target) == true, isHovered: hovered == target
                    )
                    .equatable()
                    // Topmost layer first, as layer lists usually read.
                    ForEach(screen.elements.reversed()) { element in
                        row(element, ref: .init(host: .screen(screen.id), element: element.id), selection: selection, hovered: hovered)
                    }
                }
                if !store.floating.isEmpty {
                    LayerGroupRow(model: model, name: "Canvas", symbol: "square.dashed", target: nil, isSelected: false, isHovered: false)
                        .equatable()
                    ForEach(store.floating.reversed()) { floating in
                        row(floating.element, ref: .init(host: .canvas, element: floating.id), selection: selection, hovered: hovered)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
    }

    private func row(_ element: DesignElement, ref: DesignStore.ElementRef, selection: CanvasSelection?, hovered: CanvasSelection?) -> some View {
        let target = CanvasSelection.element(ref)
        return LayerRow(
            model: model, ref: ref, symbol: element.symbol ?? element.kind.symbol, name: element.displayName,
            isLocked: element.isLocked, isHidden: element.isHidden,
            isSelected: selection?.contains(target) == true, isHovered: hovered == target
        )
        .equatable()
    }
}

/// What picking a layer in the list does: selects it, with the palette put away.
@MainActor
private func pickLayer(_ selection: CanvasSelection, in model: AppModel) {
    model.tool = .select
    model.selection = selection
}

/// Hovering over a row outlines its layer on the canvas.
@MainActor
private func hoverLayer(_ target: CanvasSelection?, _ isInside: Bool, in model: AppModel) {
    guard let target else { return }
    if isInside {
        model.isHoveringList = true
        model.hovered = target
    } else if model.hovered == target {
        model.isHoveringList = false
        model.hovered = nil
    }
}

/// A row is filled when its layer is selected, and tinted while it is hovered over, here
/// or on the canvas.
private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
    if isSelected { return Color(uiColor: .secondarySystemFill) }
    if isHovered { return Color.accentColor.opacity(0.10) }
    return .clear
}

/// The heading for a screen's layers, which selects the screen, or for the layers on the
/// open canvas. Like a layer's row, it is built from what it shows alone (see `LayerRow`).
private struct LayerGroupRow: View, Equatable {
    /// For what a tap and hover do; not part of what the heading shows.
    let model: AppModel
    let name: String
    let symbol: String
    /// What the heading picks: its screen, or nothing for the open canvas.
    let target: CanvasSelection?
    let isSelected: Bool
    let isHovered: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.symbol == b.symbol && a.target == b.target && a.isSelected == b.isSelected && a.isHovered == b.isHovered
    }

    var body: some View {
        #if DEBUG
        let _ = LayersPanelWork.rowBuilt()
        #endif
        Button {
            if let target { pickLayer(target, in: model) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(rowFill(isSelected: isSelected, isHovered: isHovered), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hoverLayer(target, $0, in: model) }
        .disabled(target == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One layer's row, with its lock and eye. It is given what it shows, and compared by that
/// alone, so that it is built again only when that changes: not for a change elsewhere in the
/// design, such as each frame of a drag, nor for the hover moving between other rows. It
/// reads nothing from the model or the environment that would build it again otherwise.
private struct LayerRow: View, Equatable {
    /// For what a tap, the lock, the eye and hover do; not part of what the row shows.
    let model: AppModel
    let ref: DesignStore.ElementRef
    let symbol: String
    let name: String
    let isLocked: Bool
    let isHidden: Bool
    let isSelected: Bool
    let isHovered: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.ref == b.ref && a.symbol == b.symbol && a.name == b.name && a.isLocked == b.isLocked
            && a.isHidden == b.isHidden && a.isSelected == b.isSelected && a.isHovered == b.isHovered
    }

    var body: some View {
        #if DEBUG
        let _ = LayersPanelWork.rowBuilt()
        #endif
        HStack(spacing: 0) {
            Button {
                // A hidden layer can still be picked here, its outline showing where it is.
                pickLayer(.element(ref), in: model)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(name)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 12)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            // A layer's lock and eye show when they are on, or when it is selected.
            if isSelected || isLocked {
                rowToggle(
                    isLocked ? "Unlock \(name)" : "Lock \(name)",
                    symbol: isLocked ? "lock.fill" : "lock.open",
                    isOn: isLocked
                ) { model.toggleLock(ref) }
            }
            if isSelected || isHidden {
                rowToggle(
                    isHidden ? "Show \(name)" : "Hide \(name)",
                    symbol: isHidden ? "eye.slash" : "eye",
                    isOn: isHidden
                ) { model.toggleHidden(ref) }
            }
            Spacer().frame(width: 4)
        }
        .opacity(isHidden ? 0.5 : 1)
        .background(rowFill(isSelected: isSelected, isHovered: isHovered), in: .rect(cornerRadius: 10))
        .onHover { hoverLayer(.element(ref), $0, in: model) }
    }

    /// A lock or eye on a layer's row.
    private func rowToggle(_ label: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: Code

/// The Code tab: a screen's SwiftUI, made once the screen has stopped changing rather than on
/// every frame of a drag, and coloured once for each time it is made.
private struct CodePane: View {
    @Environment(AppModel.self) private var model
    /// The screen whose code is shown; the first screen until another is picked.
    @Binding var screenID: DesignScreen.ID?
    @State private var preview = CodePreview()

    var body: some View {
        let screens = model.store.screens
        if let screen = screens.first(where: { $0.id == screenID }) ?? screens.first {
            let shown = CodePreview.Shown(screen: screen, settings: model.store.canvas.code)
            HStack {
                Menu {
                    ForEach(screens) { other in
                        Button(SwiftUICodeGenerator.fileName(for: other)) { screenID = other.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(SwiftUICodeGenerator.fileName(for: screen))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                CodeOptionsMenu()
                CopyButton(text: preview.source)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            CodeView(lines: preview.lines)
                // Each change to the screen starts this again, which cancels the wait before.
                .task(id: shown) { await preview.show(shown) }
        }
    }
}

/// A screen's code as the Code tab shows it, and its lines coloured.
@MainActor @Observable
private final class CodePreview {
    /// What the code is made from.
    struct Shown: Equatable {
        var screen: DesignScreen
        var settings: CodeSettings
    }

    /// How long a screen has to stay as it is before its code is made again.
    static let settle: Duration = .milliseconds(300)

    private(set) var source = ""
    private(set) var lines: [AttributedString] = []
    @ObservationIgnored private var shown: Shown?

    /// Makes the code for a screen. A new screen's shows at once; a change to the one shown,
    /// once it has stayed as it is for `settle`. Called again meanwhile, the wait is cancelled.
    func show(_ wanted: Shown) async {
        guard wanted != shown else { return }
        if shown?.screen.id == wanted.screen.id {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
        }
        shown = wanted
        source = SwiftUICodeGenerator.code(for: wanted.screen, settings: wanted.settings)
        lines = source.components(separatedBy: "\n").map(SwiftHighlighter.attributed)
        #if DEBUG
        LayersPanelWork.codeMade()
        #endif
    }
}

/// The code's settings, beside the code they change.
private struct CodeOptionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.store.canvas.code
        Menu {
            Picker("Layout", selection: binding(\.layout, settings.layout)) {
                ForEach(CodeSettings.Layout.allCases, id: \.self) { layout in
                    Text(layout.name).tag(layout)
                }
            }
            Toggle("Include Preview", isOn: binding(\.includesPreview, settings.includesPreview))
            Toggle("Title as Navigation Title", isOn: binding(\.usesNavigationTitle, settings.usesNavigationTitle))
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .accessibilityLabel("Code Options")
        .padding(.trailing, 6)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CodeSettings, Value>, _ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { new in model.store.updateCanvas { $0.code[keyPath: keyPath] = new } })
    }
}

private struct CopyButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Source code with line numbers and syntax colours, a line at a time. Long lines run off
/// the edge and can be scrolled to.
private struct CodeView: View {
    let lines: [AttributedString]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)")
                            .foregroundStyle(Theme.codeLineNumber)
                            .frame(width: 22, alignment: .trailing)
                        Text(line)
                    }
                    .lineLimit(1)
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }
}

#if DEBUG
/// How often the panel builds a layer's row and generates a screen's code: for the tests
/// that hold it to doing so only when what it shows has changed.
@MainActor
enum LayersPanelWork {
    static var rows = 0
    static var codes = 0

    static func rowBuilt() { rows += 1 }
    static func codeMade() { codes += 1 }

    static func reset() {
        rows = 0
        codes = 0
    }
}
#endif
