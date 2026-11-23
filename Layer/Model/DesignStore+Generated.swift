import CoreGraphics
import Foundation

/// The store's verbs for whole roots made off the main actor: a generator's update of a screen, and screens made
/// whole, as an import makes them. Each is one change, so one undo step, or part of the edit it is made for
/// (`act(for:)`), as the store's other verbs are. A root laid out ahead with `TreeRules.laidOut` is committed as it
/// is: the rules lay nothing out for it (plan 3, calls 1 and 6).
extension DesignStore {
    /// A screen's root, as the store holds it. Nil when the screen is gone.
    func root(of screenID: TreeScreen.ID) -> LayerNode? {
        tree.screens.first { $0.id == screenID }?.root
    }

    /// A generator's one write: `root` becomes the screen's root in one change, through `reconcile(_:_:)`. When the
    /// screen's root is still `base`, `root` was laid out from it off the main actor, and the rules lay nothing out
    /// there. False when the screen is gone.
    ///
    /// Also false, and nothing changes, for what `reconcile` refuses: a node deeper than 32, or a design of more
    /// than 5,000 nodes. The root keeps the screen's root's id, and a node whose id the design holds elsewhere is
    /// given a new one, which the rules then lay out.
    @discardableResult
    func commitGenerated(_ root: LayerNode, on screenID: TreeScreen.ID, laidOutOver base: LayerNode?) -> Bool {
        guard let current = self.root(of: screenID) else { return false }
        var landing = root
        landing.id = current.id
        let made = landing
        let isLaidOut = base.map { $0 == current } ?? false
        let committed = withLaidOutAhead(isLaidOut ? [screenID: made] : [:]) {
            reconcile(screenID) { $0 = made }
        }
        #if DEBUG
        if committed { GenerationWork.committed(on: screenID) }
        #endif
        return committed
    }

    /// New screens whose roots were laid out off the main actor, added in one change after the others. The rules lay
    /// nothing out for them. Returns the ids of those added.
    ///
    /// A screen is left out, as `addScreen(_:)` refuses one, when the design already has its id or one of its nodes'
    /// (or a screen before it does), when it holds a drawing or a sticky note, a node deeper than 32, or would take
    /// the design past 5,000 nodes.
    @discardableResult
    func addLaidOutScreens(_ screens: [TreeScreen]) -> [TreeScreen.ID] {
        let index = index
        var screenIDs = Set(tree.screens.map(\.id))
        var taken: Set<UUID> = []
        var count = index.count
        var added: [TreeScreen] = []
        for screen in screens {
            let ids = TreeEdit.ids(in: screen.root)
            let fresh = Set(ids)
            guard !screenIDs.contains(screen.id), fresh.count == ids.count,
                  fresh.allSatisfy({ index[$0] == nil }), taken.isDisjoint(with: fresh),
                  TreeEdit.levels(below: screen.root) <= TreeRules.maximumDepth,
                  !TreeEdit.holds(screen.root, where: { !$0.kind.belongsOnScreens }),
                  count + ids.count <= TreeRules.maximumNodes else { continue }
            screenIDs.insert(screen.id)
            taken.formUnion(fresh)
            count += ids.count
            added.append(screen)
        }
        guard !added.isEmpty else { return [] }
        let made = added
        withLaidOutAhead(Dictionary(made.map { ($0.id, $0.root) }, uniquingKeysWith: { first, _ in first })) {
            apply { $0.tree.screens += made }
        }
        #if DEBUG
        for screen in made { GenerationWork.committed(on: screen.id) }
        #endif
        return made.map(\.id)
    }
}
