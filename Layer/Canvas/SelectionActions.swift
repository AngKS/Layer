import SwiftUI

/// The bar that floats above the selection, as in Freeform: the things done to an object
/// most often, a tap away, with their keyboard shortcuts.
struct SelectionActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ToolbarPill {
            if let selected = model.selectedElement {
                elementActions(selected.ref, selected.element)
            } else if model.selectedScreen != nil {
                action("Duplicate", "plus.square.on.square", shortcut: "d") { model.duplicateSelection() }
                action("Delete", "trash", shortcut: .delete) { model.deleteSelection() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Selection Actions")
    }

    @ViewBuilder
    private func elementActions(_ ref: DesignStore.ElementRef, _ element: DesignElement) -> some View {
        let store = model.store
        let isLocked = element.isLocked
        action("Duplicate", "plus.square.on.square", shortcut: "d") { model.duplicateSelection() }
        action(isLocked ? "Unlock" : "Lock", isLocked ? "lock.open" : "lock", shortcut: "l", isActive: isLocked) {
            model.toggleLockOfSelection()
        }
        action("Bring Forward", DesignStore.Arrangement.forward.symbol, shortcut: "]") { model.arrangeSelection(.forward) }
            .disabled(!store.canArrange(ref, .forward))
        action("Send Backward", DesignStore.Arrangement.backward.symbol, shortcut: "[") { model.arrangeSelection(.backward) }
            .disabled(!store.canArrange(ref, .backward))

        Menu {
            Section {
                Button(DesignStore.Arrangement.front.name, systemImage: DesignStore.Arrangement.front.symbol) { model.arrangeSelection(.front) }
                    .disabled(!store.canArrange(ref, .front))
                Button(DesignStore.Arrangement.back.name, systemImage: DesignStore.Arrangement.back.symbol) { model.arrangeSelection(.back) }
                    .disabled(!store.canArrange(ref, .back))
            }
            if case .screen = ref.host {
                Section("Align to Screen") {
                    ForEach(ElementLayout.Alignment.allCases, id: \.self) { alignment in
                        Button(alignment.name, systemImage: alignment.symbol) { model.alignSelection(alignment) }
                    }
                }
                .disabled(isLocked)
            }
            Section {
                Button("Hide", systemImage: "eye.slash") { model.toggleHidden(ref) }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
                }
                .disabled(isLocked)
            }
        } label: {
            ToolIcon(symbol: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    private func action(
        _ label: String,
        _ symbol: String,
        shortcut: KeyEquivalent,
        isActive: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { perform() }
        } label: {
            ToolIcon(symbol: symbol, isActive: isActive)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .accessibilityLabel(label)
        .help(label)
    }
}
