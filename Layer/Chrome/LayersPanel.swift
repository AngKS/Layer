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
            case .layers: layers
            case .code: code
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

    // MARK: Layers

    private var layers: some View {
        let store = model.store
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.screens) { screen in
                    group(screen.name, symbol: screen.device.size.width > 600 ? "ipad" : "iphone", isSelected: model.selection == .screen(screen.id), target: .screen(screen.id)) {
                        select(.screen(screen.id))
                    }
                    // Topmost layer first, as layer lists usually read.
                    ForEach(screen.elements.reversed()) { element in
                        layerRow(element, ref: .init(host: .screen(screen.id), element: element.id))
                    }
                }
                if !store.floating.isEmpty {
                    group("Canvas", symbol: "square.dashed", isSelected: false, target: nil, action: nil)
                    ForEach(store.floating.reversed()) { floating in
                        layerRow(floating.element, ref: .init(host: .canvas, element: floating.id))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
    }

    private func select(_ selection: CanvasSelection) {
        model.tool = .select
        model.selection = selection
    }

    /// The heading for a screen's layers, or for the layers on the open canvas.
    private func group(_ name: String, symbol: String, isSelected: Bool, target: CanvasSelection?, action: (() -> Void)?) -> some View {
        Button {
            action?()
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
            .background(rowFill(isSelected: isSelected, target: target), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover(target, $0) }
        .disabled(action == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func layerRow(_ element: DesignElement, ref: DesignStore.ElementRef) -> some View {
        let isSelected = model.selection == .element(ref)
        return HStack(spacing: 0) {
            Button {
                // A hidden layer can still be picked here, its outline showing where it is.
                select(.element(ref))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: element.symbol ?? element.kind.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(element.displayName)
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
            .accessibilityLabel(element.displayName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            // A layer's lock and eye show when they are on, or when it is selected.
            if isSelected || element.isLocked {
                rowToggle(
                    element.isLocked ? "Unlock \(element.displayName)" : "Lock \(element.displayName)",
                    symbol: element.isLocked ? "lock.fill" : "lock.open",
                    isOn: element.isLocked
                ) { model.toggleLock(ref) }
            }
            if isSelected || element.isHidden {
                rowToggle(
                    element.isHidden ? "Show \(element.displayName)" : "Hide \(element.displayName)",
                    symbol: element.isHidden ? "eye.slash" : "eye",
                    isOn: element.isHidden
                ) { model.toggleHidden(ref) }
            }
            Spacer().frame(width: 4)
        }
        .opacity(element.isHidden ? 0.5 : 1)
        .background(rowFill(isSelected: isSelected, target: .element(ref)), in: .rect(cornerRadius: 10))
        .onHover { hover(.element(ref), $0) }
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

    /// A row is filled when its layer is selected, and tinted while it is hovered over,
    /// here or on the canvas.
    private func rowFill(isSelected: Bool, target: CanvasSelection?) -> Color {
        if isSelected { return Color(uiColor: .secondarySystemFill) }
        if let target, model.hovered == target { return Color.accentColor.opacity(0.10) }
        return .clear
    }

    /// Hovering over a row outlines its layer on the canvas.
    private func hover(_ target: CanvasSelection?, _ isInside: Bool) {
        guard let target else { return }
        if isInside {
            model.isHoveringList = true
            model.hovered = target
        } else if model.hovered == target {
            model.isHoveringList = false
            model.hovered = nil
        }
    }

    // MARK: Code

    @ViewBuilder
    private var code: some View {
        let screens = model.store.screens
        if let screen = screens.first(where: { $0.id == codeScreenID }) ?? screens.first {
            let source = SwiftUICodeGenerator.code(for: screen, settings: model.store.canvas.code)
            HStack {
                Menu {
                    ForEach(screens) { other in
                        Button(SwiftUICodeGenerator.fileName(for: other)) { codeScreenID = other.id }
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
                CopyButton(text: source)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            CodeView(source: source)
        }
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

/// Source code with line numbers and syntax colours. Long lines run off the edge and
/// can be scrolled to.
private struct CodeView: View {
    let source: String

    var body: some View {
        let lines = source.components(separatedBy: "\n")
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)")
                            .foregroundStyle(Theme.codeLineNumber)
                            .frame(width: 22, alignment: .trailing)
                        Text(SwiftHighlighter.attributed(line))
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
