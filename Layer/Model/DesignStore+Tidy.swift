import CoreGraphics
import Foundation

/// Voice's "tidy up" (spec §5, plan 5's call 10): the structure pass in its tidy mode, its structures built as the pass
/// after a batch builds them (`build(_:)`), a container's all in one change, so that the engine lays out what it makes,
/// and the person's own containers, locked, hidden and turned things are left as they are.
extension DesignStore {
    /// Voice's "tidy up" (§5, call 10): the pass in tidy mode over the screen's free root and its sketched free cards,
    /// every arrangeable child new, every container the pass made growing; each structure built. Inside the caller's
    /// step, or a step of its own when there is none. Returns what it built: each row, column and grid, and a card whose
    /// column it built, by the card's id; none when nothing qualified.
    ///
    /// Inside out, as the pass after a batch goes: a card's column is built before the root it lies on is looked at.
    /// What the tidy builds keeps where it lies: a column starts where its first member is, so a screen tidied keeps its
    /// top where it was rather than moving it to a margin of its own. What rides on a member, a caption on its picture,
    /// goes where the member goes (plan 5's final review, A5), and keeps its placement intent: only the person's own
    /// placing rewrites one (A4).
    @discardableResult func tidy(_ screenID: TreeScreen.ID) -> [UUID] {
        let tokens = tree.settings.tokens
        var built: [UUID] = []
        asOwnStep { keepingPlacementIntents {
            for id in tidiedContainers(on: screenID) {
                guard let parent = node(id), let depth = index[id]?.depth else { continue }
                // Every container the pass made may grow (call 10); `infer` takes those still a row, column or grid.
                let made = Set(parent.children.filter { $0.sketch?.decidedBy == .structure }.map(\.id))
                let decisions = StructureInference.infer(in: parent, new: [], grows: made, tokens: tokens, mode: .tidy,
                                                         depth: depth)
                let sure = decisions.compactMap { decision in
                    if case .apply(let structure) = decision { structure } else { nil }
                }
                built += build(sure, carryingRiders: true)
            }
        } }
        return built
    }

    /// The containers a tidy looks in, inside out: each card sketched on the screen that is free, then its root when
    /// that is free. One locked or hidden, itself or through what holds it, is left alone: what is in it can't be moved.
    private func tidiedContainers(on screenID: TreeScreen.ID) -> [UUID] {
        let index = index
        guard let root = tree.screens.first(where: { $0.id == screenID })?.root else { return [] }
        var found: [(id: UUID, depth: Int)] = []
        func look(at node: LayerNode) {
            if let entry = index[node.id], !entry.isLockedWithAncestors, !entry.isHiddenWithAncestors,
               node.resolvedLayout == .free, entry.path.isEmpty || (node.kind == .card && node.sketch != nil) {
                found.append((node.id, entry.depth))
            }
            node.children.forEach(look)
        }
        look(at: root)
        // Deepest first; of one depth, in the order they lie in the tree.
        return found.enumerated().sorted { (-$0.element.depth, $0.offset) < (-$1.element.depth, $1.offset) }.map(\.element.id)
    }
}
