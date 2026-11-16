import SwiftUI

/// The small bar that floats over whatever is selected, as in Freeform: the things that
/// can be done to it. It sits above the selection, or below it when there is no room
/// above, and steps out of the way while the selection is being dragged.
struct SelectionActions: View {
    @Environment(AppModel.self) private var model
    @State private var size = CGSize(width: 220, height: 50)

    var body: some View {
        if !model.isAdjusting, let rect = model.selectionViewRect {
            bar
                .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
                .reportsChromeFrame("selection actions", to: model)
                .position(position(above: rect))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private var bar: some View {
        @Bindable var model = model
        let isLocked = model.isSelectionLocked
        return ToolbarPill {
            if isLocked {
                // Locked: nothing to do but unlock.
                ToolButton(symbol: "lock.open", label: "Unlock") { model.setSelectionLocked(false) }
                    .keyboardShortcut("l", modifiers: .command)
            } else {
                if let selected = model.selectedElement, selected.element.kind.hasText {
                    ToolButton(symbol: "character.cursor.ibeam", label: "Edit text", isActive: model.isEditingText) {
                        model.isEditingText = true
                    }
                    .popover(isPresented: $model.isEditingText, arrowEdge: .bottom) {
                        TextEditor(ref: selected.ref)
                    }
                }
                ToolButton(symbol: "paintbrush", label: "Format selection", isActive: model.isInspectorOpen) {
                    withAnimation(.smooth(duration: 0.3)) { model.isInspectorOpen.toggle() }
                }
                if model.canDuplicateSelection {
                    ToolButton(symbol: "plus.square.on.square", label: "Duplicate") {
                        withAnimation(.smooth(duration: 0.25)) { model.duplicateSelection() }
                    }
                    .keyboardShortcut("d", modifiers: .command)
                }
                if model.canLockSelection {
                    ToolButton(symbol: "lock", label: "Lock") { model.setSelectionLocked(true) }
                        .keyboardShortcut("l", modifiers: .command)
                }
                if case .element(let ref) = model.selection {
                    ForEach([DesignStore.Arrangement.forward, .backward], id: \.self) { arrangement in
                        ToolButton(symbol: arrangement.symbol, label: arrangement.name) {
                            withAnimation(.smooth(duration: 0.25)) { model.arrangeSelection(arrangement) }
                        }
                        .keyboardShortcut(arrangement == .forward ? "]" : "[", modifiers: .command)
                        .disabled(!model.store.canArrange(ref, arrangement))
                        .opacity(model.store.canArrange(ref, arrangement) ? 1 : 0.35)
                    }
                }
                ToolButton(symbol: "trash", label: "Delete selection") {
                    withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .animation(.smooth(duration: 0.2), value: isLocked)
    }

    /// Centred over the selection and clear of its handles, kept inside the view, below the
    /// bar across the top and out from under open panels.
    private func position(above rect: CGRect) -> CGPoint {
        let view = model.canvasSize
        let gap: CGFloat = 16
        let top = model.topBarBottom + 8
        var y = rect.minY - gap - size.height / 2
        if y - size.height / 2 < top {
            // No room above: below the selection, or failing that inside its top edge.
            y = rect.maxY + gap + size.height / 2
            if y + size.height / 2 > view.height - 100 { y = max(rect.minY, top) + gap + size.height / 2 }
        }
        // Clear of the panels beside the canvas, when they are open there rather than as sheets.
        let besideCanvas = !model.isCompactSizeClass
        let left: CGFloat = besideCanvas && model.isLayersOpen ? 20 + 300 + 12 : 12
        let right: CGFloat = view.width - (besideCanvas && model.isInspectorOpen ? 20 + 300 + 12 : 12)
        let half = size.width / 2
        let x = min(max(rect.midX, left + half), max(right - half, left + half))
        return CGPoint(x: x, y: y)
    }
}

/// Typing into the selected element. Everything typed in one sitting undoes as one step.
private struct TextEditor: View {
    @Environment(AppModel.self) private var model
    let ref: DesignStore.ElementRef

    var body: some View {
        TextField(
            model.selectedElement?.element.kind.layerName ?? "Text",
            text: Binding(
                get: { model.selectedElement?.element.text ?? "" },
                set: { text in model.store.update(ref) { $0.text = text } }
            ),
            axis: .vertical
        )
        .lineLimit(1...6)
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 320)
        .onAppear { model.store.beginEdit() }
        .onDisappear { model.store.endEdit() }
    }
}
