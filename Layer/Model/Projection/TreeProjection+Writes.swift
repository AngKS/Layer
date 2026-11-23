import CoreGraphics
import Foundation

// PROJECTION: deleted in plan 6
/// Today's flat writes, made on the tree. A field or geometry update goes straight to the one node it
/// names (an O(depth) path copy). A structural write lowers the host or hosts it touches, runs today's
/// list operation on that list, and lifts it back (`TreeLift`). A group pointer the tree can't hold yet
/// (to a group added later in the same change, on another host, or one that makes a loop) waits in
/// `pending`, which the change cuts when it ends.
///
/// `ListWork` counts what each writes as today's list operations did: one for an update that changes
/// anything, one for each add or move, the number removed, the slots a reorder changes, and nothing for
/// a host set whole.
extension TreeContent {
    /// W1 to W4. The node lowered raw, `body` run on it, and its identifier, host and scale restored.
    /// Written as it was, nothing is written. A changed `group` is a structural write: the host is lifted
    /// with the element in it. Otherwise each changed field is written over the node, and a changed frame
    /// or angle is put into its parent's space: under a free parent wherever it is written, and under a
    /// laid-out one by My call 20 (its size fixed, its origin taking it out to its host's top when the
    /// host's root is free, dropped otherwise). A free container's children stay where they are on screen;
    /// a laid-out one's go with it.
    mutating func projectedUpdate(_ id: UUID, pending: inout [UUID: UUID], _ body: (inout DesignElement) -> Void) {
        guard let found = found(id) else { return }
        let before = found.lowered(pending: pending)
        var element = before
        body(&element)
        element.id = before.id
        element.parent = before.parent
        element.scale = before.scale
        guard element != before else { return }
        #if DEBUG
        ListWork.wrote()
        #endif
        guard element.group == before.group else {
            let was = TreeProjection.lowerHostNodes(found.host, in: self, pending: pending)
            var list = was.map(\.element)
            if let index = list.firstIndex(where: { $0.id == id }) { list[index] = element }
            lift([Lift(host: found.host, list: list, was: was)], asKept: true, pending: &pending)
            return
        }
        write(element, over: before, at: found)
    }

    /// W5's add: `element` on top of what is on the host, placed as today's `add` places it. One that
    /// points at a group already on the host goes on top of what is in that group. Today's add put it at
    /// the end of the list, and the change's end gathered it into its group once the rest of the change
    /// (a copy put just in front of its original, the members of a group made inside another) had put
    /// things where they go; the lift gathers at once, and at the end of the host it would take its group
    /// to the top with it. Returns the element as it is kept. Nothing is added to a screen the design
    /// doesn't have.
    @discardableResult
    mutating func projectedAdd(_ element: DesignElement, to host: DesignScreen.ID?, scale: CGFloat?,
                               pending: inout [UUID: UUID]) -> DesignElement {
        let placed = [DesignElement].placed(element, on: host, scale: scale)
        let on = Self.host(host)
        guard has(on) else { return placed }
        let was = TreeProjection.lowerHostNodes(on, in: self, pending: pending)
        #if DEBUG
        ListWork.wrote()
        #endif
        var list = was.map(\.element)
        if placed.kind != .drawing, let group = placed.group,
           let item = list.firstIndex(where: { $0.id == group && $0.kind == .group }) {
            list.insert(placed, at: item)
        } else {
            list.append(placed)
        }
        lift([Lift(host: on, list: list, was: was)], asKept: true, pending: &pending)
        return placed
    }

    /// W5's remove: only the listed elements go. What they held stays where it is on screen, its
    /// pointers waiting in `pending`.
    mutating func projectedRemove(_ ids: Set<UUID>, pending: inout [UUID: UUID]) {
        guard !ids.isEmpty else { return }
        var lifts: [Lift] = []
        var removed = 0
        for host in hosts(holding: ids) {
            let was = TreeProjection.lowerHostNodes(host, in: self, pending: pending)
            let list = was.map(\.element).filter { !ids.contains($0.id) }
            removed += was.count - list.count
            lifts.append(Lift(host: host, list: list, was: was))
        }
        guard removed > 0 else { return }
        #if DEBUG
        ListWork.wrote(removed)
        #endif
        lift(lifts, asKept: true, pending: &pending)
    }

    /// W5's move: the element taken off its host and put on top of what is on `host`, at `frame` there,
    /// placed as today's `move` places it. Nothing moves to a screen the design doesn't have.
    mutating func projectedMove(_ id: UUID, to host: DesignScreen.ID?, scale: CGFloat?, frame: CGRect,
                                pending: inout [UUID: UUID]) {
        let to = Self.host(host)
        guard has(to), let from = hosts(holding: [id]).first else { return }
        let was = TreeProjection.lowerHostNodes(from, in: self, pending: pending)
        var list = was.map(\.element)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        var element = [DesignElement].placed(list.remove(at: index), on: host, scale: scale)
        element.frame = frame
        #if DEBUG
        ListWork.wrote()
        #endif
        if to == from {
            lift([Lift(host: from, list: list + [element], was: was)], asKept: true, pending: &pending)
        } else {
            let there = TreeProjection.lowerHostNodes(to, in: self, pending: pending)
            lift([Lift(host: from, list: list, was: was), Lift(host: to, list: there.map(\.element) + [element], was: there)],
                 asKept: true, pending: &pending)
        }
    }

    /// W5's reorder: what is on the host put in `order`, back to front, by today's slot rule. An order
    /// that doesn't hold exactly what is there changes nothing.
    mutating func projectedReorder(_ host: DesignScreen.ID?, to order: [UUID], pending: inout [UUID: UUID]) {
        let on = Self.host(host)
        guard has(on) else { return }
        let was = TreeProjection.lowerHostNodes(on, in: self, pending: pending)
        var list = was.map(\.element)
        guard [DesignElement].reorder(&list, slots: Array(list.indices), to: order) > 0 else { return }
        lift([Lift(host: on, list: list, was: was)], asKept: true, pending: &pending)
    }

    /// W5's host set whole: what is on the host becomes `elements`, lifted. Not counted, as today's bulk
    /// rewrites aren't. A laid-out child given a new frame this way is laid back by the engine (F23).
    ///
    /// `elements` are as the views show them (`screens`, `floating`), each member locked or hidden with its
    /// containers, unless `asKept` says they are as the design keeps them (`children(of:)`), each with its
    /// own flags: a flag is written where it differs from how the node is shown that way.
    mutating func projectedSetHost(_ host: DesignScreen.ID?, to elements: [DesignElement], asKept: Bool = false,
                                   pending: inout [UUID: UUID]) {
        projectedSetHosts([(host: host, elements: elements)], asKept: asKept, pending: &pending)
    }

    /// W5's host set whole, for several hosts in one write: each is lifted against the design as it was
    /// before any of them is set, so that a node moved from one to another is found where it was and keeps
    /// what only the tree knows, whichever is given first. Hosts the design doesn't have, and a host given
    /// twice after the first time, are left out. Not counted. `asKept` is as in `projectedSetHost`.
    mutating func projectedSetHosts(_ lists: [(host: DesignScreen.ID?, elements: [DesignElement])], asKept: Bool = false,
                                    pending: inout [UUID: UUID]) {
        var lifts: [Lift] = []
        for (host, elements) in lists {
            let on = Self.host(host)
            guard has(on), !lifts.contains(where: { $0.host == on }) else { continue }
            lifts.append(Lift(host: on, list: elements, was: TreeProjection.lowerHostNodes(on, in: self, pending: pending)))
        }
        guard !lifts.isEmpty else { return }
        lift(lifts, asKept: asKept, pending: &pending)
    }

    /// One element as `lowerHost` lowers it, found by its identifier alone without lowering anything else:
    /// the first node with it in reading order, as `TreeProjection.pose(of:in:)` finds it. Nil for an
    /// identifier the design doesn't have, and for a screen's root, which isn't lowered.
    func projectedElement(_ id: UUID, pending: [UUID: UUID]) -> DesignElement? {
        found(id)?.lowered(pending: pending)
    }
}

// MARK: - One node

// PROJECTION: deleted in plan 6
private extension TreeContent {
    // PROJECTION: deleted in plan 6
    /// A node found for writing: where it is, what holds it, and where they place it.
    struct Found {
        var host: TreeIndex.Host
        /// Child indices from the host's top: on a screen from its root, on the canvas starting with
        /// its index among the canvas's nodes.
        var path: [Int]
        var node: LayerNode
        /// What holds it: a container, or a screen's root. Nil at the canvas's top level.
        var parent: LayerNode?
        var parentIsScreenRoot: Bool
        /// Where its parent places it.
        var parentPlace: TreeProjection.Place
        /// Where the host's top places what is on it: the screen's root, or the canvas.
        var topPlace: TreeProjection.Place
        /// The screen root's layout; free on the canvas.
        var rootLayout: LayerNode.Layout
        /// On the canvas, its top-level node's scale.
        var scale: CGFloat?

        /// The node lowered alone, as `TreeProjection.lowerHost` lowers it.
        func lowered(pending: [UUID: UUID]) -> DesignElement {
            let pose = parentPlace.placing(node)
            let screen: DesignScreen.ID? = if case .screen(let id) = host { id } else { nil }
            let group = parentIsScreenRoot ? nil : parent?.id
            return DesignElement(node: node, frame: pose.frame, rotation: pose.rotation, parent: screen, scale: scale,
                                 group: pending[node.id] ?? group)
        }
    }

    /// The first node with `id` in reading order, screens first, as `TreeProjection.pose(of:in:)` finds it.
    /// A screen's root isn't one: it isn't lowered.
    func found(_ id: UUID) -> Found? {
        for screen in screens {
            guard let path = TreeProjection.path(to: id, in: screen.root), let last = path.last else { continue }
            let top = TreeProjection.Place.host.placing(screen.root).place
            var parent = screen.root, place = top
            for index in path.dropLast() {
                parent = parent.children[index]
                place = place.placing(parent).place
            }
            return Found(host: .screen(screen.id), path: path, node: parent.children[last], parent: parent,
                         parentIsScreenRoot: path.count == 1, parentPlace: place, topPlace: top,
                         rootLayout: screen.root.resolvedLayout, scale: nil)
        }
        for (index, top) in canvas.enumerated() {
            guard let rest = TreeProjection.path(to: id, in: top) else { continue }
            guard let last = rest.last else {
                return Found(host: .canvas, path: [index], node: top, parent: nil, parentIsScreenRoot: false,
                             parentPlace: .host, topPlace: .host, rootLayout: .free, scale: top.scale)
            }
            var parent = top, place = TreeProjection.Place.host.placing(top).place
            for child in rest.dropLast() {
                parent = parent.children[child]
                place = place.placing(parent).place
            }
            return Found(host: .canvas, path: [index] + rest, node: parent.children[last], parent: parent,
                         parentIsScreenRoot: false, parentPlace: place, topPlace: .host, rootLayout: .free,
                         scale: top.scale)
        }
        return nil
    }

    /// W1 to W3: `element`'s fields and pose written over the node `before` was lowered from.
    mutating func write(_ element: DesignElement, over before: DesignElement, at found: Found) {
        var node = found.node
        node.take(element, shown: before)
        let moved = element.frame != before.frame, turned = element.rotation != before.rotation
        guard moved || turned else { return change(at: found) { $0 = node } }

        var place = found.parentPlace
        var takenOut = false
        if found.parent?.resolvedLayout ?? .free == .free {
            // W2: wherever it is written, in its parent's space.
            let local = place.local(of: element.frame, rotation: element.rotation)
            if moved { node.frame = local.frame }
            if turned { node.rotation = local.rotation }
            if node.isContainer, node.resolvedLayout != .free { Self.fix(&node, from: before.frame.size, to: element.frame.size) }
        } else if element.frame.origin != before.frame.origin, found.rootLayout == .free, !found.parentIsScreenRoot {
            // W3: out to the end of the host's top, where it was written, fixed both ways.
            takenOut = true
            place = found.topPlace
            let local = place.local(of: element.frame, rotation: element.rotation)
            node.frame = local.frame
            node.rotation = local.rotation
            node.width.mode = .fixed
            node.height.mode = .fixed
            node.scale = found.host == .canvas ? found.scale : nil
        } else {
            // W3: the origin dropped for the engine to lay it back; the size fixed on each axis it changed.
            Self.fix(&node, from: before.frame.size, to: element.frame.size)
            node.frame.size = element.frame.size
            if turned { node.rotation = place.local(of: element.frame, rotation: element.rotation).rotation }
        }

        // A free container's children stay where they are on screen; a laid-out one's go with it. They
        // are put back only when the place it gives them has moved or turned, so a resize at the same
        // upright origin, or one that only changes how it is held, leaves their frames exactly as they are.
        if node.isContainer, node.resolvedLayout == .free {
            let was = found.parentPlace.placing(found.node).place
            let now = place.placing(node).place
            let turnedToo = was.degrees != now.degrees
            let movedToo = turnedToo || (was.isUpright && now.isUpright ? was.origin != now.origin : was.toHost != now.toHost)
            for index in node.children.indices where movedToo {
                let pose = was.placing(node.children[index])
                let local = now.local(of: pose.frame, rotation: pose.rotation)
                node.children[index].frame = local.frame
                if turnedToo { node.children[index].rotation = local.rotation }
            }
        }

        guard takenOut else { return change(at: found) { $0 = node } }
        let index = found.path[found.path.count - 1]
        changeParent(of: found) { parent in
            var children = parent.children
            children.remove(at: index)
            TreeLift.give(children, to: &parent)
        }
        switch found.host {
        case .screen(let id):
            if let screen = screens.firstIndex(where: { $0.id == id }) { screens[screen].root.children.append(node) }
        case .canvas:
            canvas.append(node)
        }
    }

    /// `.fixed` on each axis whose size changed.
    static func fix(_ node: inout LayerNode, from old: CGSize, to new: CGSize) {
        if new.width != old.width { node.width.mode = .fixed }
        if new.height != old.height { node.height.mode = .fixed }
    }

    /// Changes the node found in place: only the nodes on its path are copied.
    mutating func change(at found: Found, _ body: (inout LayerNode) -> Void) {
        change(found.host, at: found.path[...], body)
    }

    /// Changes what holds the node found: a container, or a screen's root.
    mutating func changeParent(of found: Found, _ body: (inout LayerNode) -> Void) {
        change(found.host, at: found.path.dropLast(), body)
    }

    mutating func change(_ host: TreeIndex.Host, at path: ArraySlice<Int>, _ body: (inout LayerNode) -> Void) {
        switch host {
        case .screen(let id):
            guard let screen = screens.firstIndex(where: { $0.id == id }) else { return }
            screens[screen].root.change(at: path, body)
        case .canvas:
            guard let first = path.first else { return }
            canvas[first].change(at: path.dropFirst(), body)
        }
    }
}

// PROJECTION: deleted in plan 6
private extension LayerNode {
    /// Changes the node at `path` below this one, in place.
    mutating func change(at path: ArraySlice<Int>, _ body: (inout LayerNode) -> Void) {
        guard let first = path.first else { return body(&self) }
        children[first].change(at: path.dropFirst(), body)
    }
}

// MARK: - Hosts lifted

// PROJECTION: deleted in plan 6
private extension TreeContent {
    // PROJECTION: deleted in plan 6
    /// A host's new list, and its lowering before the write: what the lift reads each node from.
    struct Lift {
        var host: TreeIndex.Host
        var list: [DesignElement]
        var was: [TreeProjection.LoweredNode]
    }

    /// W6 for each host, every one against the design as it was and from the lowerings the write made,
    /// so that a node moved between them keeps what only the tree knows and no host is lowered twice.
    /// Then `pending` holds, for every element of those hosts, the pointer the lift couldn't honour, and
    /// nothing for the rest. `asKept`: the lists are as the design keeps them, not as the views show them.
    mutating func lift(_ lifts: [Lift], asKept: Bool, pending: inout [UUID: UUID]) {
        let lowered = Dictionary(lifts.map { ($0.host, $0.was) }, uniquingKeysWith: { first, _ in first })
        let lifted = lifts.map { TreeLift.nodes(from: $0.list, host: $0.host, keeping: self, lowered: lowered, asKept: asKept) }
        for (lift, result) in zip(lifts, lifted) {
            switch lift.host {
            case .screen(let id):
                if let screen = screens.firstIndex(where: { $0.id == id }) { TreeLift.give(result.nodes, to: &screens[screen].root) }
            case .canvas:
                canvas = result.nodes
            }
            for entry in lift.was { pending[entry.element.id] = nil }
            for element in lift.list { pending[element.id] = nil }
        }
        for result in lifted { pending.merge(result.pending) { _, new in new } }
    }

    static func host(_ screen: DesignScreen.ID?) -> TreeIndex.Host {
        screen.map { .screen($0) } ?? .canvas
    }

    func has(_ host: TreeIndex.Host) -> Bool {
        guard case .screen(let id) = host else { return true }
        return screens.contains { $0.id == id }
    }

    /// The hosts with any of `ids` on them, below a screen's root or among the canvas's nodes.
    func hosts(holding ids: Set<UUID>) -> [TreeIndex.Host] {
        func holds(_ node: LayerNode) -> Bool { ids.contains(node.id) || node.children.contains(where: holds) }
        var hosts: [TreeIndex.Host] = []
        for screen in screens where !hosts.contains(.screen(screen.id)) && screen.root.children.contains(where: holds) {
            hosts.append(.screen(screen.id))
        }
        if canvas.contains(where: holds) { hosts.append(.canvas) }
        return hosts
    }
}
