import CoreGraphics
import Foundation

/// The sketch path on the tree (spec §5): a reading becomes a node where its sketch lands, in one change, and a reading
/// is told what is already on its screen from the tree.
extension DesignStore {
    /// One change: the reading's node where it lands (§5). Nil off every screen. `adjust` finishes it in the same change.
    ///
    /// It is plan 2's `reconcile` with `SketchedNode.inserting`, so the tree's rules lay it out in the same change. Also
    /// nil, and nothing changes, when the design can't hold it: a design of 5,000 nodes already (F9).
    @discardableResult
    func addSketched(_ kind: ElementKind, from sketch: CGRect, confidence: Double, decidedBy: LayerNode.DecidedBy,
                     adjust: (inout LayerNode) -> Void = { _ in }) -> UUID? {
        guard var made = SketchedNode.make(kind, sketch: sketch, in: tree, index: index, confidence: confidence,
                                           decidedBy: decidedBy) else { return nil }
        adjust(&made.node)
        let finished = made
        guard reconcile(finished.landing.screen, { $0 = SketchedNode.inserting(finished, into: $0) }) else { return nil }
        return index[finished.node.id] != nil ? finished.node.id : nil
    }

    /// One change (call 13). A card becoming a leaf gives back what it held, where it was; a leaf becoming a card takes
    /// what it encloses. It is laid out afresh in its parent from the sketch it remembers (or `fallback`, screen points),
    /// keeping its id, place, name, lock and words, and its intent then says `.asked`, confidence 1. `adjust` finishes it
    /// in the same change. Nil when it is gone, not on a screen, or the design can't hold the result.
    @discardableResult
    func changeKind(of id: UUID, to kind: ElementKind, fallback: CGRect? = nil,
                    adjust: (inout LayerNode) -> Void = { _ in }) -> UUID? {
        guard let old = node(id), let entry = index[id], case .screen(let screenID) = entry.host,
              var made = SketchedNode.remade(old, as: kind, fallback: fallback, in: tree, index: index) else { return nil }
        adjust(&made.node)
        let finished = made
        guard reconcile(screenID, { $0 = SketchedNode.replacing(id, with: finished, in: $0) }) else { return nil }
        return index[id] != nil ? id : nil
    }

    /// The topmost screen under a sketch's centre (canvas points), drawn as its device, a design's own included.
    func screenID(under sketch: CGRect) -> TreeScreen.ID? {
        treeScreen(at: CGPoint(x: sketch.midX, y: sketch.midY))?.id
    }

    /// A reading's `existing`: the screen's leaves at their screen frames, hidden ones included, as today.
    ///
    /// Back to front, each container's leaves where its turn puts them, as the canvas poses them: an upright frame in the
    /// screen's points, centred on its turned shape's centre. Empty for a screen the design doesn't have.
    func sketchNeighbours(on screenID: TreeScreen.ID) -> [ExistingElement] {
        guard let screen = treeScreen(screenID) else { return [] }
        var neighbours: [ExistingElement] = []
        func visit(_ node: LayerNode, in space: TreeIndex.OwnSpace) {
            for child in node.children {
                let placed = space.placing(child)
                if child.isContainer {
                    visit(child, in: placed.space)
                } else {
                    neighbours.append(ExistingElement(kind: child.kind, frame: placed.frame))
                }
            }
        }
        visit(screen.root, in: TreeIndex.OwnSpace.host.placing(screen.root).space)
        return neighbours
    }
}
