import Foundation

/// The popover's Group menu and its Align menu, on the tree: Group as a Row, Column, Grid or Card, and lining things
/// up in a laid-out parent by setting that parent's alignment.
extension AppModel {
    /// Wraps what is selected as `shape` and selects the new container: see `DesignStore.group(_:as:)`.
    func groupSelection(as shape: GroupShape) {
        guard let selection, let container = store.group(selection, as: shape) else { return }
        self.selection = .element(container)
    }

    /// Whether what is selected can be grouped as `shape`: see `DesignStore.canGroup(_:as:)`.
    func canGroupSelection(as shape: GroupShape) -> Bool {
        selection.map { store.canGroup($0, as: shape) } ?? false
    }

    /// What the popover's Group button offers for what is selected: the shapes it can be grouped as, in the menu's
    /// order. A tap on the button groups when Group is among them, and opens the menu otherwise, so that it never does
    /// nothing; one thing alone is offered a card.
    var groupShapesOffered: [GroupShape] {
        guard let selection else { return [] }
        return GroupShape.allCases.filter { store.canGroup(selection, as: $0) }
    }

    /// In one laid-out parent: its alignment, as one step. Otherwise today's `alignSelection`, moving only what sits in a
    /// free parent (spec §10): what a row, column, grid or overlay places stays where it is, and the rest line up with
    /// it all the same.
    ///
    /// In a laid-out parent an alignment it has no use for, such as Align Top in a column, changes nothing: the parent
    /// places what it holds, so nothing is moved on its own either.
    func lineUpSelection(_ alignment: ElementLayout.Alignment) {
        guard let selection, canLineUpSelection(alignment) else { return }
        if selection.isSeveral || store.layoutAligned(selection, alignment) != nil {
            store.lineUp(selection, alignment)
        } else {
            alignSelection(alignment)
        }
    }

    /// Whether `lineUpSelection` would line anything up: something that isn't locked or a screen is selected. In a
    /// laid-out parent the alignment is one it has, and otherwise something selected is in a free parent.
    func canLineUpSelection(_ alignment: ElementLayout.Alignment) -> Bool {
        guard let selection, !isSelectionLocked else { return false }
        if case .screen = selection { return false }
        guard store.laidOutParent(of: selection) != nil else { return store.holdsSomethingInAFreeParent(selection) }
        return store.layoutAligned(selection, alignment) != nil
    }

    /// Today's Distribute (`DesignStore.distribute`), moving only what sits in a free parent (spec §10): what a row,
    /// column, grid or overlay places stays where it is, and the rest are spaced about it all the same.
    func lineUpSelection(_ distribution: ElementLayout.Distribution) {
        guard let selection, canLineUpSelection(distribution) else { return }
        store.distributeInFreeParents(selection, distribution)
    }

    /// Whether `lineUpSelection(_:)` would space anything: today's three things or more, unlocked, not all in one
    /// row, column, grid or overlay, which spaces them itself, and something among them in a free parent.
    func canLineUpSelection(_ distribution: ElementLayout.Distribution) -> Bool {
        guard let selection, canDistributeSelection else { return false }
        return store.laidOutParent(of: selection) == nil && store.holdsSomethingInAFreeParent(selection)
    }

    /// Whether everything selected shares one row, column, grid or overlay, which places it.
    var isSelectionLaidOut: Bool {
        selection.flatMap(store.laidOutParent(of:)) != nil
    }
}
