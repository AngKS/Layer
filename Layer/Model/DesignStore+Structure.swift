import CoreGraphics
import Foundation

/// The structure pass's writes (spec §5, plan 5's calls 1, 2 and 11): a structure built in one change, and the marks
/// that keep the pass off what the person declined.
extension DesignStore {
    /// One step's worth of change: `StructureInference.applying` committed through `reconcile`, with the container's
    /// SketchIntent (its frame on the screen as bounds, `.structure`, the structure's confidence) in place of the one it
    /// was proposed with. The intent goes in the same change, so that the container and its parent are laid out once
    /// (F7). A card's column keeps the card's own intent: the card is the person's drawing. Returns the container's id;
    /// nil, and nothing changes, when it can't be built: a member is gone or no longer one the pass may take, the
    /// parent isn't on a screen, the container's id is the design's already, or the result would pass depth 32 or 5,000
    /// nodes.
    @discardableResult
    func build(_ structure: StructureInference.Structure) -> UUID? {
        build([structure]).first
    }

    /// `build(_:)` for structures proposed in one parent, in order, in one change: each is built on what those before
    /// it built, so that a column holds a row built just before it, and one that can't be built is left out. One change
    /// lays the parent out once, where a change each laid it out once each: tidying a container of hundreds of things
    /// builds dozens (Task 10). Returns the containers built: none when the parent isn't on a screen or the result
    /// would pass depth 32 or 5,000 nodes. A structure proposed in another parent than the first's is left out.
    @discardableResult
    func build(_ structures: [StructureInference.Structure]) -> [UUID] {
        guard let parentID = structures.first?.parent else { return [] }
        let index = index, tree = tree
        guard let entry = index[parentID], case .screen(let screenID) = entry.host,
              let screen = tree.screens.first(where: { $0.id == screenID }),
              var parent = index.node(parentID, in: tree) else { return [] }
        let device = tree.device(of: screen)
        var ids: [UUID] = []
        for structure in structures where structure.parent == parentID {
            guard var built = StructureInference.applying(structure, to: parent) else { continue }
            let id = structure.container.id
            if structure.kind != .cardColumn {
                guard index[id] == nil, let slot = built.children.firstIndex(where: { $0.id == id }) else { continue }
                // The parent's own space to the screen's: through a card it lies in, turned or not.
                built.children[slot].sketch = LayerNode.SketchIntent(
                    sketched: structure.container.frame.applying(entry.toHost), on: device.size, margin: device.margin,
                    confidence: structure.confidence, decidedBy: .structure)
            }
            parent = built
            ids.append(id)
        }
        let made = parent
        guard !ids.isEmpty, reconcile(screenID, { $0.replaceNode(at: entry.path[...], with: made) }) else { return [] }
        return ids.filter { self.index[$0] != nil }
    }

    /// Marks the pass's refusal on each (call 11): `structureDeclined`, so that it never takes them again. One with no
    /// intent gets one that carries the mark: its frame on the screen as its bounds, `.structure`, its placement read
    /// from there. A container the person made has no intent and is never taken anyway, so it is left as it is. Not an
    /// undo step, as a suggested title isn't one (`setTitle(undoable: false)`): undo never takes a decline back.
    func declineStructure(_ ids: [UUID]) {
        guard markDeclinedOutsideTheHistory(ids) else { return }
        markNeedsSaving()
    }

    // MARK: - Worked out from the tree

    /// `tree` with each of `ids` declined, as `declineStructure(_:)` marks them. The same tree when none changes.
    static func declining(_ ids: Set<UUID>, in tree: TreeContent) -> TreeContent {
        guard !ids.isEmpty else { return tree }
        let index = TreeIndex(tree)
        var marked = tree
        for id in ids {
            guard let entry = index[id], !entry.path.isEmpty, let node = index.node(id, in: tree),
                  node.sketch?.structureDeclined != true, !(node.isContainer && node.sketch == nil) else { continue }
            var intent: LayerNode.SketchIntent
            if let sketch = node.sketch {
                intent = sketch
            } else {
                let screen: CGSize?, margin: CGFloat
                switch entry.host {
                case .screen(let screenID):
                    let device = tree.screens.first { $0.id == screenID }.map(tree.device(of:))
                    (screen, margin) = (device?.size, device?.margin ?? 0)
                case .canvas:
                    (screen, margin) = (nil, 0)
                }
                intent = LayerNode.SketchIntent(sketched: entry.hostShape.rect, on: screen, margin: margin, confidence: 1,
                                                decidedBy: .structure)
            }
            intent.structureDeclined = true
            let declined = intent
            marked.changeNode(on: entry.host, at: entry.path) { $0.sketch = declined }
        }
        return marked
    }

    /// The nodes a change took out of a container the pass made into another parent, that container still being there
    /// (call 11, F4). One the change deleted, or whose container went (grown into another, undone, ungrouped), isn't
    /// among them. Only the hosts the change touched are looked into.
    static func takenOutOfStructures(from before: TreeContent, to after: TreeContent) -> [UUID] {
        var was: [LayerNode] = [], now: [LayerNode] = []
        let screensAfter = Dictionary(after.screens.map { ($0.id, $0.root) }, uniquingKeysWith: { first, _ in first })
        let screensBefore = Set(before.screens.map(\.id))
        for screen in before.screens {
            let root = screensAfter[screen.id]
            guard root != screen.root else { continue }
            was.append(screen.root)
            if let root { now.append(root) }
        }
        now += after.screens.filter { !screensBefore.contains($0.id) }.map(\.root)
        if before.canvas != after.canvas {
            was += before.canvas
            now += after.canvas
        }

        // Each member of a container the pass made, by the container it was in.
        var held: [UUID: UUID] = [:]
        func holdings(_ node: LayerNode) {
            if node.kind == .group, node.sketch?.decidedBy == .structure {
                for child in node.children where held[child.id] == nil { held[child.id] = node.id }
            }
            node.children.forEach(holdings)
        }
        was.forEach(holdings)
        guard !held.isEmpty else { return [] }

        // Where each is now, and which of those containers are still there.
        let containers = Set(held.values)
        var standing: Set<UUID> = [], present: Set<UUID> = [], parents: [UUID: UUID] = [:]
        func visit(_ node: LayerNode, in parent: UUID?) {
            if containers.contains(node.id) { standing.insert(node.id) }
            if held[node.id] != nil, present.insert(node.id).inserted, let parent { parents[node.id] = parent }
            for child in node.children { visit(child, in: node.id) }
        }
        now.forEach { visit($0, in: nil) }
        return held.compactMap { member, container in
            standing.contains(container) && present.contains(member) && parents[member] != container ? member : nil
        }
    }
}

private extension LayerNode {
    /// The node at `path` below this one (this one at []) replaced by `node`.
    mutating func replaceNode(at path: ArraySlice<Int>, with node: LayerNode) {
        guard let first = path.first else {
            self = node
            return
        }
        guard children.indices.contains(first) else { return }
        children[first].replaceNode(at: path.dropFirst(), with: node)
    }
}
