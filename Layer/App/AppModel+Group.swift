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

    /// In one laid-out parent: its alignment, as one step. Otherwise today's `alignSelection`.
    ///
    /// In a laid-out parent an alignment it has no use for, such as Align Top in a column, changes nothing: the parent
    /// places what it holds, so nothing is moved on its own either.
    func lineUpSelection(_ alignment: ElementLayout.Alignment) {
        guard let selection, !isSelectionLocked else { return }
        guard store.laidOutParent(of: selection) != nil else { return alignSelection(alignment) }
        guard let aligned = store.layoutAligned(selection, alignment) else { return }
        store.update(aligned.parent) { $0.layout = aligned.layout }
    }

    /// Whether `lineUpSelection` would line anything up: something that isn't locked or a screen is selected, and in a
    /// laid-out parent the alignment is one it has.
    func canLineUpSelection(_ alignment: ElementLayout.Alignment) -> Bool {
        guard let selection, !isSelectionLocked else { return false }
        if case .screen = selection { return false }
        guard store.laidOutParent(of: selection) != nil else { return true }
        return store.layoutAligned(selection, alignment) != nil
    }

    /// Whether everything selected shares one row, column, grid or overlay, which places it: Distribute is off then.
    var isSelectionLaidOut: Bool {
        selection.flatMap(store.laidOutParent(of:)) != nil
    }
}
