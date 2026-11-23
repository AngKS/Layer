import Foundation

/// Layer order: things brought to the front, forward, backward or sent to the back, one at
/// a time or several at once.
///
/// Order only means something among siblings: the things that share a screen, or the open
/// canvas, and a group, or no group (see `SiblingLists`). A group is one of its siblings, and
/// stands among them for its whole block: itself and everything in it. Drawings are in no
/// sibling set. Unlocked ink is drawn above every element, so a drawing keeps the place it
/// has in the list whatever is arranged around it, and nothing steps past it or moves it (F7).
extension DesignContent {
    /// The whole order of what is on a screen, or on the open canvas when `parent` is nil,
    /// back to front, with every drawing there in the slot it holds now and the other slots
    /// filled, in turn, by `order`: the new back-to-front order of the things there that
    /// aren't drawings. What `reorder(_:to:)` is given whenever things are put in a new
    /// order, so that it is worked out in this one place.
    ///
    /// `order` is to hold every one of those things once. Given anything else, the result
    /// doesn't hold exactly what is there, and `reorder` leaves the order as it is.
    func rawOrder(on parent: DesignScreen.ID?, withDrawingsKept order: [DesignElement.ID]) -> [DesignElement.ID] {
        [DesignElement].order(of: children(of: parent), withDrawingsKept: order)
    }
}

extension [DesignElement] {
    /// The identifiers of what shares a host, `list`, back to front, with every drawing in the slot
    /// it holds and the other slots filled, in turn, by `order`. Shared with the projection's lift,
    /// whose drawings keep their slots by this same rule (F10, F15).
    static func order(of list: [DesignElement], withDrawingsKept order: [DesignElement.ID]) -> [DesignElement.ID] {
        var next = order.makeIterator()
        return list.compactMap { element in
            element.kind == .drawing ? element.id : next.next()
        }
    }
}

extension DesignStore {
    /// Moves what is selected up or down among its siblings: the things it shares its screen,
    /// or the open canvas, and its group with. A group moves as its whole block, and steps
    /// past a sibling group whole. Things on different screens each move among their own, and
    /// so do things in different groups. Several things that are siblings move as one block,
    /// keeping their own order and closing the gaps between them. A screen in the selection is
    /// left as it is, and so are a drawing and anything locked. One step to undo, however many
    /// screens it reorders.
    func arrange(_ selection: CanvasSelection, _ arrangement: Arrangement) {
        let orders = arranged(selection, arrangement)
        guard !orders.isEmpty else { return }
        apply { content in
            for (parent, order) in orders {
                content.reorder(parent, to: content.rawOrder(on: parent, withDrawingsKept: order))
            }
        }
    }

    /// Whether arranging what is selected would change the order of anything.
    func canArrange(_ selection: CanvasSelection, _ arrangement: Arrangement) -> Bool {
        !arranged(selection, arrangement).isEmpty
    }

    /// The new order, back to front and drawings left out, of each screen (or the open
    /// canvas, nil) whose order arranging the selection changes.
    private func arranged(_ selection: CanvasSelection, _ arrangement: Arrangement) -> [DesignScreen.ID?: [DesignElement.ID]] {
        // What moves, by the screen it is on, or the open canvas. A drawing is in no sibling
        // set, a screen is not arranged, and a locked thing stays where it is, whichever way
        // it is asked: the popover, the Format panel, a shortcut or Siri. Locked means by
        // itself or by a group above it, so a member of a locked group, gone into, stays too.
        // The lock is checked on what is selected, not on what goes with it: a selected group
        // moves as its whole block, and every member goes with it, whether locked on its own
        // or only by a group inside it, as when the group is moved.
        var moving: [DesignScreen.ID?: Set<DesignElement.ID>] = [:]
        for case .element(let ref) in selection.things {
            guard let (element, _) = resolve(ref), element.kind != .drawing, !isLocked(.element(ref)) else { continue }
            moving[element.parent, default: []].insert(element.id)
        }
        var orders: [DesignScreen.ID?: [DesignElement.ID]] = [:]
        for (parent, moved) in moving {
            let things = content.children(of: parent)
            var siblings = SiblingLists(things)
            // Each sibling set its things are in moves on its own: the screen's top level and
            // the inside of a group, say, both in this one step.
            for (list, ids) in Dictionary(grouping: moved, by: siblings.list(of:)) {
                siblings.lists[list] = Self.order(moving: Set(ids), among: siblings.lists[list] ?? [], arrangement)
            }
            let order = siblings.order
            if order != things.compactMap({ $0.kind == .drawing ? nil : $0.id }) { orders[parent] = order }
        }
        return orders
    }

    /// Siblings, back to front, with some of them moved as one block: in their own order,
    /// their gaps closed, to the front or the back, or just in front of the first sibling
    /// in front of the block's frontmost member (forward), or just behind the first sibling
    /// behind its backmost member (backward).
    private static func order(moving moved: Set<DesignElement.ID>, among siblings: [DesignElement.ID], _ arrangement: Arrangement) -> [DesignElement.ID] {
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

/// What is on one screen, or on the open canvas, as layers: the things at its top level, and
/// those in each group, each list back to front. In a list a group stands for its whole
/// block, the group's own list then the item, which is how the design keeps them once its
/// groups are sound: each group's members gathered into one run, the item just in front.
/// Drawings are in no list (F7).
struct SiblingLists {
    /// Each list's things, back to front: the top level's under nil, a group's under its id.
    var lists: [DesignElement.ID?: [DesignElement.ID]] = [:]
    private var groups: Set<DesignElement.ID> = []
    private var listOf: [DesignElement.ID: DesignElement.ID?] = [:]

    /// The lists of things that share a host, given back to front. A thing whose group isn't
    /// among them, which only a design not yet put right has, is taken as at the top level.
    init(_ things: [DesignElement]) {
        let things = things.filter { $0.kind != .drawing }
        for thing in things where thing.kind == .group { groups.insert(thing.id) }
        for thing in things where listOf[thing.id] == nil {
            let list = thing.group.flatMap { groups.contains($0) ? $0 : nil }
            listOf[thing.id] = list
            lists[list, default: []].append(thing.id)
        }
    }

    /// The list a thing is in: its group, or nil for the top level.
    func list(of id: DesignElement.ID) -> DesignElement.ID? {
        listOf[id] ?? nil
    }

    /// Everything in the lists, back to front: each list in its order, with each group's
    /// block in its place in its list.
    var order: [DesignElement.ID] {
        var written: Set<DesignElement.ID> = []
        func block(_ id: DesignElement.ID) -> [DesignElement.ID] {
            guard written.insert(id).inserted else { return [] }
            guard groups.contains(id) else { return [id] }
            return (lists[id] ?? []).flatMap(block) + [id]
        }
        return (lists[nil] ?? []).flatMap(block)
    }
}

// MARK: Moving a layer

/// A list of layers the Layers panel shows, in which a row can be dropped: a screen's top
/// level, or the open canvas's (`host`), or what is in one group.
enum LayerList: Hashable, Sendable {
    case host(DesignStore.ElementRef.Host)
    case group(DesignElement.ID)
}

extension DesignStore {
    /// Moves a thing to a list on its own host: into a group, or out of one, or to another
    /// place in the list it is in. `before` is the row it lands above in the panel, so it
    /// lands just in front of that thing in the list; nil is the bottom of the list, the back.
    /// The thing's `group` becomes the list's group, or none. One step to undo, and a group
    /// left with one member dissolves in that same change.
    ///
    /// Refused, returning false and changing nothing: a drawing, which keeps its place; a
    /// locked thing (by itself or by a group above it), as when it is arranged; a list on
    /// another host, or one that is locked; a move into the thing itself or into what is in
    /// it; and a `before` that isn't in the list. The order is written through
    /// `rawOrder(on:withDrawingsKept:)`, so drawings keep their slots here too.
    @discardableResult
    func moveLayer(_ id: DesignElement.ID, to list: LayerList, before: DesignElement.ID?) -> Bool {
        moveLayer(id, to: list, landing: before.map(Landing.above) ?? .bottom)
    }

    /// Moves a thing to the top of a list: above every row in it, which is the front.
    @discardableResult
    func moveLayerToTop(_ id: DesignElement.ID, of list: LayerList) -> Bool {
        moveLayer(id, to: list, landing: .top)
    }

    /// Where a moved row lands in a list, as the panel shows it.
    private enum Landing {
        case above(DesignElement.ID)
        case top
        case bottom
    }

    private func moveLayer(_ id: DesignElement.ID, to list: LayerList, landing: Landing) -> Bool {
        guard let element = element(id), element.kind != .drawing, !isLockedWithItsGroups(element) else { return false }
        let newGroup: DesignElement.ID?
        switch list {
        case .host(let host):
            guard host.parent == element.parent else { return false }
            newGroup = nil
        case .group(let groupID):
            guard let group = groupItem(groupID), group.parent == element.parent, groupID != id,
                  !content.ancestors(of: groupID).contains(id), !isLockedWithItsGroups(group)
            else { return false }
            newGroup = groupID
        }
        var siblings = SiblingLists(content.children(of: element.parent))
        let oldGroup = siblings.list(of: id)
        siblings.lists[oldGroup]?.removeAll { $0 == id }
        var target = siblings.lists[newGroup] ?? []
        switch landing {
        case .above(let row):
            guard row != id, let index = target.firstIndex(of: row) else { return false }
            target.insert(id, at: index + 1)
        case .top:
            target.append(id)
        case .bottom:
            target.insert(id, at: 0)
        }
        siblings.lists[newGroup] = target
        let order = siblings.order
        let parent = element.parent
        apply { content in
            if element.group != newGroup { content.update(id) { $0.group = newGroup } }
            content.reorder(parent, to: content.rawOrder(on: parent, withDrawingsKept: order))
        }
        return true
    }
}
