import ImagePlayground
import SwiftUI
import UIKit

/// The small bar that floats over whatever is selected, as in Freeform: the things that
/// can be done to it. It sits above the selection, or below it when there is no room
/// above, and steps out of the way while the selection is being dragged.
struct SelectionActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var size = CGSize(width: 220, height: 50)
    /// What is typed about a selected drawing, to say what it should become.
    @State private var prompt = ""
    @FocusState private var isTypingPrompt: Bool
    /// The top of the on-screen keyboard in the canvas's coordinates, while it is up.
    @State private var keyboardTop: CGFloat?

    var body: some View {
        if !model.isAdjusting, let rect = model.selectionViewRect {
            bar
                .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
                .reportsChromeFrame("selection actions", to: model)
                .position(position(above: rect))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .animation(.smooth(duration: 0.25), value: keyboardTop)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                    keyboardTop = Self.keyboardTop(note)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    keyboardTop = nil
                }
        }
    }

    /// Where the keyboard a notification is about begins, in the window, or nil when it
    /// covers none of it, as a hardware keyboard's bar or a floating keyboard may not.
    private static func keyboardTop(_ note: Notification) -> CGFloat? {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap(\.windows)
                  .first(where: \.isKeyWindow)
        else { return nil }
        let local = window.convert(frame, from: window.screen.coordinateSpace)
        guard local.minY < window.bounds.maxY, local.width >= window.bounds.width * 0.5 else { return nil }
        return local.minY
    }

    private var bar: some View {
        @Bindable var model = model
        let isLocked = model.isSelectionLocked
        return ToolbarPill {
            if isLocked {
                // Locked: nothing to do but unlock.
                ToolButton(symbol: "lock.open", label: "Unlock") { model.setSelectionLocked(false) }
                    .keyboardShortcut("l", modifiers: .command)
            } else if model.selectedElement?.element.kind == .drawing {
                drawingActions
            } else if model.selection?.isSeveral == true {
                severalActions
            } else {
                if let selected = model.selectedElement, selected.element.kind.hasText {
                    ToolButton(symbol: "character.cursor.ibeam", label: "Edit text", isActive: model.isEditingText) {
                        model.isEditingText = true
                    }
                    .popover(isPresented: $model.isEditingText, arrowEdge: .bottom) {
                        TextEditor(ref: selected.ref)
                    }
                }
                if supportsImagePlayground, let selected = model.selectedElement, selected.element.kind == .image {
                    ToolButton(symbol: "apple.image.playground", label: "Make a new picture in Image Playground") {
                        model.remakeImageWithPlayground(selected.ref)
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
                if case .element = model.selection {
                    arrangeMenu
                }
                ToolButton(symbol: "trash", label: "Delete selection") {
                    withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .animation(.smooth(duration: 0.2), value: isLocked)
        .onChange(of: model.selection) { prompt = "" }
    }

    /// For a drawing: a line to say what it should be and the sparkle that has it read as
    /// a sketch and turned into that; then what any element can have done to it.
    @ViewBuilder private var drawingActions: some View {
        TextField("What should this be?", text: $prompt)
            .font(.system(size: 15))
            .textFieldStyle(.plain)
            .submitLabel(.go)
            .focused($isTypingPrompt)
            .onSubmit(convert)
            .padding(.horizontal, 12)
            .frame(width: 240, height: 44)
            .accessibilityLabel("Prompt")
        ToolButton(symbol: "sparkles", label: "Convert drawing") { convert() }
        ToolButton(symbol: "plus.square.on.square", label: "Duplicate") {
            withAnimation(.smooth(duration: 0.25)) { model.duplicateSelection() }
        }
        .keyboardShortcut("d", modifiers: .command)
        ToolButton(symbol: "lock", label: "Lock") { model.setSelectionLocked(true) }
            .keyboardShortcut("l", modifiers: .command)
        ToolButton(symbol: "trash", label: "Delete selection") {
            withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    /// For several things at once: their settings, lining them up with one another, and
    /// what any selection can have done to it.
    @ViewBuilder private var severalActions: some View {
        ToolButton(symbol: "paintbrush", label: "Format selection", isActive: model.isInspectorOpen) {
            withAnimation(.smooth(duration: 0.3)) { model.isInspectorOpen.toggle() }
        }
        Menu {
            ForEach(ElementLayout.Alignment.allCases, id: \.self) { alignment in
                Button(alignment.name, systemImage: alignment.symbol) {
                    withAnimation(.smooth(duration: 0.25)) { model.alignSelection(alignment) }
                }
            }
            Divider()
            ForEach(ElementLayout.Distribution.allCases, id: \.self) { distribution in
                Button(distribution.name, systemImage: distribution.symbol) {
                    withAnimation(.smooth(duration: 0.25)) { model.distributeSelection(distribution) }
                }
                .disabled(!model.canDistributeSelection)
            }
        } label: {
            ToolIcon(symbol: "align.horizontal.left")
        }
        // In the order written, even when the menu opens upwards.
        .menuOrder(.fixed)
        .accessibilityLabel("Align")
        ToolButton(symbol: "plus.square.on.square", label: "Duplicate") {
            withAnimation(.smooth(duration: 0.25)) { model.duplicateSelection() }
        }
        .keyboardShortcut("d", modifiers: .command)
        ToolButton(symbol: "lock", label: "Lock") { model.setSelectionLocked(true) }
            .keyboardShortcut("l", modifiers: .command)
        arrangeMenu
        ToolButton(symbol: "trash", label: "Delete selection") {
            withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    /// Bring to Front, Bring Forward, Send Backward and Send to Back, for one thing or
    /// several, each with its Keynote and Pages shortcut. A command that would change
    /// nothing is off.
    private var arrangeMenu: some View {
        ZStack {
            // The shortcuts. On a closed menu's items they don't fire on iPadOS (tried in
            // the simulator), so they are on buttons of their own behind it, hidden and
            // taking no room. Made see-through instead, accessibility still found them.
            // They are never off: one switched on by the change before was at times still
            // off for the next key press, and arranging changes nothing when there is
            // nothing to do.
            ForEach(DesignStore.Arrangement.allCases, id: \.self) { arrangement in
                Button(arrangement.name) { arrange(arrangement) }
                    .keyboardShortcut(arrangement.shortcut)
            }
            .hidden()
            .frame(width: 0, height: 0)
            Menu {
                ForEach(DesignStore.Arrangement.allCases, id: \.self) { arrangement in
                    Button(arrangement.name, systemImage: arrangement.symbol) { arrange(arrangement) }
                        .disabled(!model.canArrangeSelection(arrangement))
                }
            } label: {
                ToolIcon(symbol: "square.3.layers.3d")
            }
            // Front at the top and back at the bottom, even when the menu opens upwards.
            .menuOrder(.fixed)
            .accessibilityLabel("Arrange")
        }
    }

    private func arrange(_ arrangement: DesignStore.Arrangement) {
        withAnimation(.smooth(duration: 0.25)) { model.arrangeSelection(arrangement) }
    }

    private func convert() {
        isTypingPrompt = false
        model.convertSelection(prompt: prompt)
        prompt = ""
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
        // Above the keyboard while one is up, so that what is typed can be seen.
        if let keyboardTop, y + size.height / 2 > keyboardTop - 12 {
            y = max(keyboardTop - 12 - size.height / 2, top + size.height / 2)
        }
        let half = size.width / 2
        let x = min(max(rect.midX, left + half), max(right - half, left + half))
        return CGPoint(x: x, y: y)
    }
}

/// Typing into the selected element. Everything typed in one sitting undoes as one step.
private struct TextEditor: View {
    @Environment(AppModel.self) private var model
    let ref: DesignStore.ElementRef
    /// The sitting's own step: see `DesignStore.Edit`.
    @State private var edit: DesignStore.Edit?

    var body: some View {
        TextField(
            model.selectedElement?.element.kind.layerName ?? "Text",
            text: Binding(
                get: { model.selectedElement?.element.text ?? "" },
                set: { text in model.store.act(for: edit) { model.store.update(ref) { $0.text = text } } }
            ),
            axis: .vertical
        )
        .lineLimit(1...6)
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 320)
        .onAppear {
            guard edit?.isOpen != true else { return }
            edit = model.store.beginEdit()
            model.store.name(edit, String(localized: "Typing"))
        }
        .onDisappear {
            if let edit { model.store.endEdit(edit) }
            edit = nil
        }
    }
}

private extension DesignStore.Arrangement {
    /// The Keynote and Pages shortcuts: ⇧⌘] Bring to Front, ⌘] Bring Forward, ⌘[ Send
    /// Backward and ⇧⌘[ Send to Back.
    var shortcut: KeyboardShortcut {
        switch self {
        case .front: KeyboardShortcut("]", modifiers: [.command, .shift])
        case .forward: KeyboardShortcut("]", modifiers: .command)
        case .backward: KeyboardShortcut("[", modifiers: .command)
        case .back: KeyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
