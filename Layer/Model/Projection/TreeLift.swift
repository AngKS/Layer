import CoreGraphics
import Foundation

// PROJECTION: deleted in plan 6
/// A host's flat list lifted back into the tree: what a structural flat write (add, remove, move,
/// reorder, a changed group pointer, a host set whole) leaves on a host, as that host's top-level
/// nodes. Today's stray and gather rules decide what holds what, and in what order; every node
/// already in the design keeps what the list doesn't say (its sizing, its sketch, its source); and
/// each element's absolute pose is put back into its new parent's space, so nothing moves on screen.
enum TreeLift {
    /// A host's flat list as its top-level nodes. Pointers it can't honour now are returned in `pending`.
    ///
    /// 1. A pointer is kept when it names a `.group` element in the list, the element isn't a
    ///    drawing, and following pointers from it never comes back to the element. Any other pointer
    ///    goes to `pending`, except a drawing's, which is dropped. A pointer the list was lowered with
    ///    from `pending` is honoured here once its group is on the host.
    /// 2. The order is `gathered` over the non-drawings, with the kept pointers alone. Each drawing
    ///    keeps its slot in the list (F10). A list with two elements of one identifier, which only a
    ///    damaged file has, keeps the order it has, as today's reorder refuses to change it.
    /// 3. Each node is `content`'s node with that identifier, or a new one, with what the element
    ///    says that differs from how it was shown written over it (F9). A list of elements as the
    ///    views show them (`asKept` false) is compared with them shown so; a list of elements as the
    ///    design keeps them, each with its own lock and hide (`asKept`), with them as kept, so that
    ///    a flag written to match a container's is still the node's own.
    /// 4. Each node goes into its group's children, in order; those in none are the top level.
    /// 5. Each pose, top down, is the element's absolute pose seen from its parent's. A canvas child
    ///    drawn at another scale than its top-level node is carried into that scale through canvas
    ///    points, so its size on the canvas stays. A node whose pose, parent and parent's pose are all
    ///    as they were keeps its own frame and angle as they are, so a host set as it is changes nothing.
    ///
    /// Containers new to the tree are free and sized to fit. My call 20 isn't applied: a laid-out
    /// child given a new frame here is laid back by the engine (F23).
    static func nodes(from elements: [DesignElement], host: TreeIndex.Host, keeping content: TreeContent)
        -> (nodes: [LayerNode], pending: [UUID: UUID]) {
        nodes(from: elements, host: host, keeping: content, lowered: [:])
    }

    /// `nodes(from:host:keeping:)`, given the hosts its caller has already lowered from `content` (with
    /// `TreeProjection.lowerHostNodes`, pending pointers or not), so that no host is lowered twice for one write.
    static func nodes(from elements: [DesignElement], host: TreeIndex.Host, keeping content: TreeContent,
                      lowered: [TreeIndex.Host: [TreeProjection.LoweredNode]],
                      asKept: Bool = false) -> (nodes: [LayerNode], pending: [UUID: UUID]) {
        // 1. Which pointers the tree can hold.
        var first: [UUID: Int] = [:]
        for (index, element) in elements.enumerated() where first[element.id] == nil { first[element.id] = index }
        func groupItem(_ id: UUID) -> Int? {
            first[id].flatMap { elements[$0].kind == .group ? $0 : nil }
        }
        func leadsBack(from start: UUID, to id: UUID) -> Bool {
            var seen: Set<UUID> = []
            var next: UUID? = start
            while let current = next {
                if current == id { return true }
                guard seen.insert(current).inserted, let item = groupItem(current) else { return false }
                next = elements[item].group
            }
            return false
        }
        var parent = [Int?](repeating: nil, count: elements.count)
        var pending: [UUID: UUID] = [:]
        for (index, element) in elements.enumerated() {
            guard let target = element.group, element.kind != .drawing else { continue }
            if let item = groupItem(target), !leadsBack(from: target, to: element.id) {
                parent[index] = item
            } else {
                pending[element.id] = target
            }
        }

        // 2. The order, back to front.
        var order = Array(elements.indices)
        if first.count == elements.count {
            var things: [DesignElement] = []
            for (index, element) in elements.enumerated() where element.kind != .drawing {
                var thing = element
                thing.group = parent[index].map { elements[$0].id }
                things.append(thing)
            }
            let ordered = [DesignElement].order(of: elements, withDrawingsKept: Self.gathered(things)).compactMap { first[$0] }
            if ordered.count == elements.count { order = ordered }
        }

        // 4. What holds what.
        var children = [[Int]](repeating: [], count: elements.count)
        var top: [Int] = []
        for index in order {
            if let holder = parent[index] { children[holder].append(index) } else { top.append(index) }
        }

        // 3 and 5. The nodes, posed top down.
        let known = knownNodes(elements, host: host, in: content, lowered: lowered)
        let onCanvas = host == .canvas
        func build(_ index: Int, at place: TreeProjection.Place, in parentID: UUID?, parentKept: Bool,
                   drawnAt topScale: CGFloat) -> LayerNode {
            let element = elements[index]
            var node: LayerNode
            if let found = known[index] {
                node = found.lowering.node
                node.take(element, shown: asKept ? found.lowering.element : found.lowering.shown)
            } else {
                node = LayerNode(element: element)
            }
            let isTop = parentID == nil
            node.scale = onCanvas && isTop ? element.scale : nil
            let scale = isTop ? drawnScale(element.scale) : topScale
            var frame = element.frame
            if onCanvas, !isTop, drawnScale(element.scale) != topScale {
                let canvasFrame = Placement(origin: .zero, scale: drawnScale(element.scale)).canvasRect(for: frame)
                frame = Placement(origin: .zero, scale: topScale).localRect(for: canvasFrame)
            }
            var kept = false
            if parentKept, let found = known[index], found.isOnHost {
                let was = found.lowering.element
                kept = found.lowering.holder == parentID && was.frame == element.frame && was.rotation == element.rotation
                    && (!onCanvas || was.scale == element.scale)
            }
            if !kept {
                let local = place.local(of: frame, rotation: element.rotation)
                node.frame = local.frame
                node.rotation = local.rotation
            }
            let own = place.placing(node).place
            give(children[index].map { build($0, at: own, in: element.id, parentKept: kept, drawnAt: scale) }, to: &node)
            return node
        }
        let place: TreeProjection.Place = switch host {
        case .screen(let id): content.screens.first { $0.id == id }.map { TreeProjection.Place.host.placing($0.root).place } ?? .host
        case .canvas: .host
        }
        let nodes = top.map { build($0, at: place, in: nil, parentKept: true, drawnAt: 1) }
        return (nodes, pending)
    }

    /// Gives `node` `children` in place of those it has, as `TreeEdit.give(_:to:)` does.
    static func give(_ children: [LayerNode], to node: inout LayerNode) {
        TreeEdit.give(children, to: &node)
    }

    /// How many canvas points each of an element's own is drawn as: 1 for none, or one that isn't a size.
    private static func drawnScale(_ scale: CGFloat?) -> CGFloat {
        scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
    }

    // MARK: The design as it was

    // PROJECTION: deleted in plan 6
    /// A node the design already has, for an element of the list.
    private struct Known {
        /// The node as it is in the design, and as its host's lowering lowered and showed it.
        var lowering: TreeProjection.LoweredNode
        /// Whether it is on the host being lifted, rather than come from another.
        var isOnHost: Bool
    }

    /// The node each element names, by its place in the list: looked for on the host first, then on
    /// the others, for an element moved from one. Two elements of one identifier take its nodes in turn.
    /// Each host is read from its own lowering: from `lowered` when the caller has it, or lowered here,
    /// another host only once it is seen to hold one of the elements.
    private static func knownNodes(_ elements: [DesignElement], host: TreeIndex.Host, in content: TreeContent,
                                   lowered: [TreeIndex.Host: [TreeProjection.LoweredNode]]) -> [Known?] {
        var wanted: [UUID: [Int]] = [:]
        for (index, element) in elements.enumerated() { wanted[element.id, default: []].append(index) }
        var known = [Known?](repeating: nil, count: elements.count)
        let others: [TreeIndex.Host] = content.screens.map { .screen($0.id) } + [.canvas]
        for candidate in [host] + others.filter({ $0 != host }) {
            guard !wanted.isEmpty else { break }
            let entries: [TreeProjection.LoweredNode]
            if let given = lowered[candidate] {
                entries = given
            } else {
                func holds(_ node: LayerNode) -> Bool { wanted[node.id] != nil || node.children.contains(where: holds) }
                guard candidate == host || topLevel(of: candidate, in: content).contains(where: holds) else { continue }
                entries = TreeProjection.lowerHostNodes(candidate, in: content)
            }
            for entry in entries {
                precondition(entry.node.id == entry.element.id, "a lowered element is paired with the node it came from")
                guard var indices = wanted[entry.node.id] else { continue }
                let index = indices.removeFirst()
                wanted[entry.node.id] = indices.isEmpty ? nil : indices
                known[index] = Known(lowering: entry, isOnHost: candidate == host)
            }
        }
        return known
    }

    /// What is on a host: a screen's root's children, or the canvas's nodes.
    private static func topLevel(of host: TreeIndex.Host, in content: TreeContent) -> [LayerNode] {
        switch host {
        case .screen(let id): content.screens.first { $0.id == id }?.root.children ?? []
        case .canvas: content.canvas
        }
    }

    /// Things that share a host, back to front, drawings left out, with each group's members
    /// gathered into one run, in their order, and the group item just in front of them. A
    /// run takes the place of the frontmost thing in it; everything else keeps its order.
    ///
    /// Today's gather (`keepGroupsSound()`'s rule 4), moved unchanged. It is given the non-drawings, as today.
    static func gathered(_ things: [DesignElement]) -> [DesignElement.ID] {
        var place: [DesignElement.ID: Int] = [:]
        for (index, thing) in things.enumerated() where place[thing.id] == nil { place[thing.id] = index }
        var inside: [DesignElement.ID: [DesignElement.ID]] = [:]
        var outermost: [DesignElement.ID] = []
        for thing in things {
            if let group = thing.group, place[group] != nil {
                inside[group, default: []].append(thing.id)
            } else {
                outermost.append(thing.id)
            }
        }
        // Where each thing's run goes: where its frontmost leaf is.
        var anchors: [DesignElement.ID: Int] = [:]
        var visiting: Set<DesignElement.ID> = []
        func anchor(_ id: DesignElement.ID) -> Int {
            if let known = anchors[id] { return known }
            let own = place[id] ?? 0
            guard let members = inside[id], visiting.insert(id).inserted else { return own }
            let found = members.map(anchor).max() ?? own
            anchors[id] = found
            return found
        }
        var written: Set<DesignElement.ID> = []
        func run(_ id: DesignElement.ID) -> [DesignElement.ID] {
            guard written.insert(id).inserted else { return [] }
            guard let members = inside[id] else { return [id] }
            return members.sorted { anchor($0) < anchor($1) }.flatMap(run) + [id]
        }
        return outermost.sorted { anchor($0) < anchor($1) }.flatMap(run)
    }
}

// PROJECTION: deleted in plan 6
extension TreeProjection.Place {
    /// A pose in the host's points, as the lowering gives it, seen from this place: the frame and angle a
    /// child placed here takes to be lowered at that pose. Under upright nodes the origins are taken
    /// away, so whole numbers stay exact; under a turned one the centre goes back through the turns.
    /// The size is kept, and the angle is the pose's less this place's summed angle.
    func local(of frame: CGRect, rotation: Double?) -> (frame: CGRect, rotation: Double?) {
        let size = frame.size
        let origin: CGPoint
        if isUpright {
            origin = CGPoint(x: frame.origin.x - self.origin.x, y: frame.origin.y - self.origin.y)
        } else {
            let centre = CGPoint(x: frame.origin.x + size.width / 2, y: frame.origin.y + size.height / 2)
                .applying(toHost.inverted())
            origin = CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
        }
        let angle = rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return (CGRect(origin: origin, size: size), Rotation.kept(angle - degrees))
    }
}
