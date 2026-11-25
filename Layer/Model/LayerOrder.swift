import Foundation

/// Layer order: things brought to the front, forward, backward or sent to the back, one at a
/// time or several at once.
///
/// Order only means something among siblings: the children of one parent, which is a screen's
/// root, a container, or the open canvas's top level. A container is one of its siblings, and
/// stands among them with everything in it. The children of a row, column or grid have one
/// order, the layout's, so they aren't arranged (My call 15): their order changes by a drag,
/// the Layers panel and voice. Drawings are in no sibling set. Unlocked ink is drawn above
/// every element, so a drawing keeps its index among the canvas's nodes whatever is arranged
/// around it, and nothing steps past it or moves it (F7).
extension DesignStore {
    /// Moves what is selected up or down among its siblings: the children of its parent. A
    /// container moves whole, and steps past a sibling container whole. Things with different
    /// parents, on different screens or in different containers, each move among their own.
    /// Several things that are siblings move as one block, keeping their own order and closing
    /// the gaps between them. A screen in the selection is left as it is, and so are a drawing,
    /// anything locked, and a child of a row, column or grid. One step to undo, however many
    /// parents it reorders.
    func arrange(_ selection: CanvasSelection, _ arrangement: Arrangement) {
        let orders = arranged(selection, arrangement)
        guard !orders.isEmpty else { return }
        reorder(orders)
    }

    /// Whether arranging what is selected would change the order of anything.
    func canArrange(_ selection: CanvasSelection, _ arrangement: Arrangement) -> Bool {
        !arranged(selection, arrangement).isEmpty
    }

    /// The new order, back to front and drawings left out, of each parent whose children arranging
    /// the selection changes.
    private func arranged(_ selection: CanvasSelection, _ arrangement: Arrangement) -> [NodeParent: [UUID]] {
        // What moves, by its parent. A drawing is in no sibling set, a screen is not arranged, and a
        // locked thing stays where it is, whichever way it is asked: the popover, the Format panel, a
        // shortcut or Siri. Locked means by itself or by a container above it, so a member of a locked
        // group, gone into, stays too. The lock is checked on what is selected, not on what goes with
        // it: a selected container moves whole, everything in it with it, whatever its own locks. Read from the
        // tree: the Format panel and the popover ask on every frame of a drag.
        var moving: [NodeParent: Set<UUID>] = [:]
        for case .element(let ref) in selection.things {
            guard let placed = placed(ref), placed.node.kind != .drawing, !placed.isLocked,
                  let parent = parent(of: ref.element), !isOrderedByItsLayout(parent) else { continue }
            moving[parent, default: []].insert(ref.element)
        }
        var orders: [NodeParent: [UUID]] = [:]
        for (parent, moved) in moving {
            guard let siblings = children(of: parent)?.compactMap({ $0.kind == .drawing ? nil : $0.id }) else { continue }
            let order = Self.order(moving: moved, among: siblings, arrangement)
            if order != siblings { orders[parent] = order }
        }
        return orders
    }

    /// Whether what `parent` holds has the one order its layout gives it: a row, column or grid
    /// does; a free container, an overlay, which stacks what it holds, and the open canvas don't.
    private func isOrderedByItsLayout(_ parent: NodeParent) -> Bool {
        let layout: LayerNode.Layout?
        switch parent {
        case .canvas: return false
        case .screen(let id): layout = tree.screens.first { $0.id == id }?.root.resolvedLayout
        case .node(let id): layout = node(id)?.resolvedLayout
        }
        switch layout {
        case .stack?, .grid?: return true
        case .free?, .overlay?, nil: return false
        }
    }

    /// Siblings, back to front, with some of them moved as one block: in their own order,
    /// their gaps closed, to the front or the back, or just in front of the first sibling
    /// in front of the block's frontmost member (forward), or just behind the first sibling
    /// behind its backmost member (backward).
    private static func order(moving moved: Set<UUID>, among siblings: [UUID], _ arrangement: Arrangement) -> [UUID] {
        let block = siblings.filter(moved.contains)
        guard let backmost = siblings.firstIndex(where: moved.contains),
              let frontmost = siblings.lastIndex(where: moved.contains) else { return siblings }
        var rest = siblings.filter { !moved.contains($0) }
        let place: Int
        switch arrangement {
        case .front:
            place = rest.count
        case .back:
            place = 0
        case .forward:
            // With nothing in front of it, the block goes to the front.
            place = siblings[(frontmost + 1)...].first.flatMap(rest.firstIndex(of:)).map { $0 + 1 } ?? rest.count
        case .backward:
            // With nothing behind it, the block goes to the back.
            place = siblings[..<backmost].last.flatMap(rest.firstIndex(of:)) ?? 0
        }
        rest.insert(contentsOf: block, at: place)
        return rest
    }
}

// MARK: Moving a layer

/// A list of layers the Layers panel shows, in which a row can be dropped: what a parent holds,
/// a screen's top level, the open canvas's, or what is in one group.
typealias LayerList = NodeParent

extension NodeParent {
    /// A screen's top level, or the open canvas's, as the Layers panel names it.
    static func host(_ host: DesignStore.ElementRef.Host) -> NodeParent {
        switch host {
        case .screen(let id): .screen(id)
        case .canvas: .canvas
        }
    }

    /// What is in a group, or in any other container.
    static func group(_ id: UUID) -> NodeParent {
        .node(id)
    }
}

extension DesignStore {
    /// Moves a thing to a list on its own host: into a group, or out of one, or to another
    /// place in the list it is in. `before` is the row it lands above in the panel, so it
    /// lands just in front of that thing in the list; nil is the bottom of the list, the back.
    /// Moved into another list it keeps its place on the canvas (`move(_:to:at:)`), and a group
    /// it leaves with one thing in it dissolves. One step to undo.
    ///
    /// Refused, returning false and changing nothing: a drawing, which keeps its place; a
    /// locked thing (by itself or by a group above it), as when it is arranged; a list on
    /// another host, or one that is locked; a move into the thing itself or into what is in
    /// it; and a `before` that isn't in the list. Each drawing in the list keeps its index
    /// among the nodes there (`TreeEdit.reordered`).
    @discardableResult
    func moveLayer(_ id: UUID, to list: LayerList, before: UUID?) -> Bool {
        moveLayer(id, to: list, landing: before.map(Landing.above) ?? .bottom)
    }

    /// Moves a thing to the top of a list: above every row in it, which is the front.
    @discardableResult
    func moveLayerToTop(_ id: UUID, of list: LayerList) -> Bool {
        moveLayer(id, to: list, landing: .top)
    }

    /// Where a moved row lands in a list, as the panel shows it.
    private enum Landing {
        case above(UUID)
        case top
        case bottom
    }

    /// Read from the tree and its index: a drop in the Layers panel lowers nothing.
    private func moveLayer(_ id: UUID, to list: NodeParent, landing: Landing) -> Bool {
        guard let thing = placed(id), thing.node.kind != .drawing, !thing.isLocked,
              let from = parent(of: id), let host = index[id]?.host, host == self.host(of: list),
              let held = children(of: list) else { return false }
        if case .node(let groupID) = list {
            guard groupID != id, !index.ancestors(of: groupID).contains(id),
                  let group = placed(groupID), group.node.isContainer, !group.isLocked else { return false }
        }
        let siblings = held.compactMap { $0.kind == .drawing ? nil : $0.id }
        var order = siblings.filter { $0 != id }
        switch landing {
        case .above(let row):
            guard row != id, let place = order.firstIndex(of: row) else { return false }
            order.insert(id, at: place + 1)
        case .top:
            order.append(id)
        case .bottom:
            order.insert(id, at: 0)
        }
        guard list != from else {
            reorder([list: order])
            return true
        }
        // Into another list: in front of what is there first, which moves no drawing there, then to its
        // place. A group it leaves with one thing in it dissolves into its slot, and in this list that
        // thing takes the group's place in the order.
        var moved = false
        asOneStep {
            moved = move(id, to: list)
            guard moved, let now = children(of: list)?.compactMap({ $0.kind == .drawing ? nil : $0.id }),
                  now.count == siblings.count + 1, now.last == id else { return }
            let place = Dictionary(siblings.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            reorder([list: order.compactMap { $0 == id ? id : place[$0].map { now[$0] } }])
        }
        return moved
    }
}
