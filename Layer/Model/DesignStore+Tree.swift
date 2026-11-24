import CoreGraphics
import Foundation

/// The store's verbs on the tree, which plans 3 to 6 build on. Each is one change, made through
/// `apply`: one undo step, or part of the edit it is made for (`act(for:)`), as the store's other
/// verbs are. Ids stay as they are; only a duplicate makes new ones.
///
/// What the tree can't hold is refused, and the design is left as it was: a node deeper than 32
/// (`TreeRules.maximumDepth`), a design of more than 5,000 nodes, a drawing or sticky note on a
/// screen, a drawing inside a container, an id the design already has, a node put inside itself, and
/// a screen's root moved, wrapped or taken away.
///
/// Each verb reads where things are from the store's index before its change, and changes the
/// tree in place along their paths.
extension DesignStore {
    // MARK: Reading the tree

    /// A node, wherever it is, a screen's root included.
    func node(_ id: UUID) -> LayerNode? { index.node(id, in: tree) }

    /// What holds a node. Nil for a screen's root, and for a node the design doesn't have.
    func parent(of id: UUID) -> NodeParent? {
        guard let entry = index[id] else { return nil }
        switch entry.host {
        case .canvas:
            return entry.path.count == 1 ? .canvas : entry.parent.map(NodeParent.node)
        case .screen(let screen):
            guard !entry.path.isEmpty else { return nil }
            return entry.path.count == 1 ? .screen(screen) : entry.parent.map(NodeParent.node)
        }
    }

    /// The device a screen is drawn as: a built-in, then one of the design's own. Nil when the screen is gone.
    func device(of screenID: TreeScreen.ID) -> DeviceFrame? {
        let tree = tree
        return tree.screens.first { $0.id == screenID }.map(tree.device(of:))
    }

    /// Whether a node is a container whose layout isn't free: a row, column, grid or overlay.
    func isLaidOut(_ id: UUID) -> Bool {
        guard let node = node(id) else { return false }
        return node.isContainer && node.resolvedLayout != .free
    }

    /// What a container, a screen's root or the canvas's top level holds, back to front. Nil when the design
    /// doesn't have it, or it isn't a container.
    func children(of parent: NodeParent) -> [LayerNode]? {
        locate(parent).flatMap { tree.children(on: $0.host, at: $0.path) }
    }

    /// The host a parent is on. Nil when the design doesn't have it.
    func host(of parent: NodeParent) -> TreeIndex.Host? {
        locate(parent)?.host
    }

    /// A node's own origin, in its parent's space, once it has moved `distance` in its host's points: under
    /// a turned container the distance is turned into that container's axes. Nil when the design doesn't
    /// have the node.
    func origin(of id: UUID, movedBy distance: CGSize) -> CGPoint? {
        let memo = index
        guard let entry = memo[id], let node = memo.node(id, in: tree) else { return nil }
        let turn = entry.parent.flatMap { memo[$0]?.hostShape.degrees } ?? 0
        var along = CGPoint(x: distance.width, y: distance.height)
        if Rotation.normalized(turn) != 0 { along = along.applying(CGAffineTransform(rotationAngle: -turn * .pi / 180)) }
        return CGPoint(x: node.frame.minX + along.x, y: node.frame.minY + along.y)
    }

    // MARK: Adding

    /// Adds a whole subtree, ids as given. `index` nil = in front. Refused (false) for an unknown parent,
    /// a canvas-only kind on a screen, a depth over 32, or an id already in the design.
    ///
    /// Also refused for a drawing anywhere but the canvas's top level, where the rules keep drawings. Its
    /// frame is in the parent's space. On the canvas's top level it keeps its own scale; anywhere else it has
    /// none. The rules then lay it out, in the same change.
    @discardableResult
    func add(_ node: LayerNode, to parent: NodeParent, at index: Int? = nil) -> Bool {
        guard let holder = locate(parent), accepts([node], in: holder) else { return false }
        var added = node
        if holder.node != nil { added.scale = nil }
        changeTree(writing: 1) { tree in
            tree.changeChildren(on: holder.host, at: holder.path) { $0.insert(added, at: Self.slot(index, in: $0)) }
        }
        return true
    }

    /// Adds a screen, with everything on it, after the others, and returns its id. Nil, and nothing is
    /// added, when the design already has the screen's id or one of its nodes', or for `add`'s other
    /// refusals: a drawing or sticky note on it, a node deeper than 32, or more than 5,000 nodes. A
    /// refused screen's id may name another screen the design has, so it is never handed back.
    @discardableResult
    func addScreen(_ screen: TreeScreen) -> TreeScreen.ID? {
        let top = Holder(host: .screen(screen.id), path: [], node: screen.root, depth: 0, toHost: .identity, degrees: 0)
        guard !tree.screens.contains(where: { $0.id == screen.id }), accepts([screen.root], in: top) else { return nil }
        changeTree(writing: 0) { $0.screens.append(screen) }
        return screen.id
    }

    /// What a container, a screen's root or the canvas's top level holds, replaced by `children`. What it
    /// held may come back among them with its ids, and what doesn't come back goes. Refused (false) as
    /// `add` is, for an id the design has anywhere else. Not counted in `ListWork`: a whole list set at once.
    @discardableResult
    func replaceChildren(of parent: NodeParent, with children: [LayerNode]) -> Bool {
        guard let holder = locate(parent), let current = tree.children(on: holder.host, at: holder.path),
              accepts(children, in: holder, replacing: current) else { return false }
        var given = children
        if holder.node != nil {
            for index in given.indices { given[index].scale = nil }
        }
        changeTree(writing: 0) { tree in
            tree.changeChildren(on: holder.host, at: holder.path) { $0 = given }
        }
        return true
    }

    // MARK: Moving

    /// Reparents within or across hosts. In a free parent it keeps its place on the canvas (own size kept,
    /// as today's move); in a laid-out one `index` decides its place. Refused into its own subtree, a
    /// canvas-only kind onto a screen, a screen root, or past depth 32.
    ///
    /// Also refused for a drawing into a container, where the rules don't keep one.
    ///
    /// `index` is its place among the parent's children once it has left where it was: nil = in front.
    /// Within its own parent it only changes place. Elsewhere in a free parent its centre stays where it is
    /// on the canvas, and its angle there, at its size in its own points; between hosts its corner goes to
    /// whole points, as a move between hosts always went. On the canvas's top level it is drawn at the
    /// scale it was drawn at.
    @discardableResult
    func move(_ id: UUID, to parent: NodeParent, at index: Int? = nil) -> Bool {
        let memo = self.index, tree = tree
        guard let entry = memo[id], let slot = entry.path.last, let node = memo.node(id, in: tree),
              let holder = locate(parent),
              !(holder.host == entry.host && holder.path.starts(with: entry.path)),
              holder.depth + TreeEdit.levels(below: node) <= TreeRules.maximumDepth, Self.fits(node, in: holder)
        else { return false }
        let from = Array(entry.path.dropLast())
        var moved = node
        if holder.host != entry.host || holder.path != from {
            let scale = drawnScale(of: entry)
            if holder.isFree { moved = keepingItsPlace(node, from: entry, into: holder, drawnAt: scale) }
            moved.scale = holder.node == nil ? scale : nil
        }
        let landing = moved
        changeTree(writing: 1) { tree in
            tree.changeChildren(on: entry.host, at: from) { $0.remove(at: slot) }
            let to = holder.host == entry.host ? TreeEdit.path(holder.path, afterRemoving: entry.path) : holder.path
            tree.changeChildren(on: holder.host, at: to) { $0.insert(landing, at: Self.slot(index, in: $0)) }
        }
        return true
    }

    /// What each parent holds put in the order given for it, back to front, all in one change: every drawing
    /// keeps its index among the nodes there (`TreeEdit.reordered`). A parent the design doesn't have, and an
    /// order that doesn't name exactly what the parent holds besides its drawings, are left as they are. Counted
    /// in `ListWork` by the places that change.
    func reorder(_ orders: [NodeParent: [UUID]]) {
        var lists: [(holder: Holder, order: [UUID])] = []
        var written = 0
        for (parent, order) in orders {
            guard let holder = locate(parent), let children = tree.children(on: holder.host, at: holder.path) else { continue }
            let moved = zip(children, TreeEdit.reordered(children, to: order)).filter { $0.id != $1.id }.count
            guard moved > 0 else { continue }
            written += moved
            lists.append((holder, order))
        }
        guard !lists.isEmpty else { return }
        // The deepest first: a list reordered doesn't move what is above it, so each path still names its parent.
        let deepestFirst = lists.sorted { $0.holder.path.count > $1.holder.path.count }
        changeTree(writing: written) { tree in
            for list in deepestFirst {
                tree.changeChildren(on: list.holder.host, at: list.holder.path) { $0 = TreeEdit.reordered($0, to: list.order) }
            }
        }
    }

    /// Changes a node in place: any field but its id and what it holds, which stay as they were.
    /// Its kind changes only to another of the same sort, a container's to a container's and a leaf's
    /// to a leaf's: a leaf made a group would be an empty group, which the rules take away, and a
    /// container made a leaf would hold what a leaf can't. Wrapping and unwrapping (`wrap`, `unwrap`)
    /// make and take away containers. `body` runs inside the change, so it mustn't read the store.
    func update(_ id: UUID, _ body: (inout LayerNode) -> Void) {
        guard let entry = index[id] else { return }
        changeTree(writing: 1) { tree in
            tree.changeNode(on: entry.host, at: entry.path) { node in
                let kept = (id: node.id, kind: node.kind, isContainer: node.isContainer, children: node.children,
                            unread: node.unreadChildren)
                body(&node)
                (node.id, node.children, node.unreadChildren) = (kept.id, kept.children, kept.unread)
                if node.isContainer != kept.isContainer { node.kind = kept.kind }
            }
        }
    }

    // MARK: Containers

    /// Siblings of one parent, wrapped in the frontmost one's slot. Free: nothing moves, the container fits on both
    /// axes. Stack or grid: reading order, each child fixed at its size (My calls 15, 16). A card pads by the
    /// design's tokens. On the canvas the container takes the frontmost one's scale. Nil when not one parent or < 1.
    ///
    /// Also nil for a kind that isn't a container, a drawing among them, a screen's root, or past depth 32 or
    /// 5,000 nodes; and when the rules take the container away again, as they dissolve a free group of one.
    /// The container is sized to fit on both axes, at the box round what it holds (and its padding), and
    /// what it holds keeps its order unless it is laid out. A thing drawn on the canvas at another scale than
    /// the frontmost is carried into that scale through canvas points, so it stays where it is, as large.
    @discardableResult
    func wrap(_ ids: [UUID], in kind: ElementKind, layout: LayerNode.Layout) -> UUID? {
        let memo = index, tree = tree
        var wrapper = LayerNode(kind: kind)
        let entries = ids.compactMap { memo[$0] }
        guard wrapper.isContainer, let first = entries.first, entries.count == ids.count,
              entries.allSatisfy({ !$0.path.isEmpty && $0.host == first.host && $0.path.dropLast() == first.path.dropLast() })
        else { return nil }
        let parentPath = Array(first.path.dropLast())
        let slots = Set(entries.compactMap(\.path.last)).sorted()
        guard let siblings = tree.children(on: first.host, at: parentPath), let front = slots.last,
              slots.allSatisfy({ siblings.indices.contains($0) }) else { return nil }
        var members = slots.map { siblings[$0] }
        guard !members.contains(where: { $0.kind == .drawing }),
              first.depth + 1 + (members.map(TreeEdit.levels(below:)).max() ?? 0) <= TreeRules.maximumDepth,
              memo.count < TreeRules.maximumNodes else { return nil }

        if first.host == .canvas, parentPath.isEmpty {
            wrapper.scale = siblings[front].scale
            members = Self.held(members, drawnAt: siblings[front].scale)
        }
        if layout != .free {
            members = TreeEdit.readingOrder(members, for: layout)
            for index in members.indices {
                members[index].width = LayerNode.Sizing(.fixed)
                members[index].height = LayerNode.Sizing(.fixed)
            }
        }
        wrapper.layout = layout == .free ? nil : layout
        wrapper.width = LayerNode.Sizing(.fit)
        wrapper.height = LayerNode.Sizing(.fit)
        if kind == .card { wrapper.padding = LayerNode.Padding(all: tree.settings.tokens.card.padding) }
        let box = TreeEdit.shapesBox(of: members) ?? .zero, padding = wrapper.padding
        wrapper.frame = CGRect(x: box.minX - padding.leading, y: box.minY - padding.top,
                               width: box.width + padding.leading + padding.trailing,
                               height: box.height + padding.top + padding.bottom)
        for index in members.indices {
            members[index].frame.origin.x -= wrapper.frame.minX
            members[index].frame.origin.y -= wrapper.frame.minY
        }
        wrapper.children = members
        let made = wrapper
        changeTree(writing: members.count + 1) { tree in
            tree.changeChildren(on: first.host, at: parentPath) { children in
                for slot in slots.reversed() { children.remove(at: slot) }
                children.insert(made, at: front - (slots.count - 1))
            }
        }
        return index[made.id] != nil ? made.id : nil
    }

    /// Children into the container's slot, places on the canvas kept with its turn baked in, its lock and hide
    /// passed down; joining the parent at that slot if the parent is laid out. Returns their ids.
    ///
    /// Empty, and nothing changes, for a node that isn't a container, a screen's root, and a container
    /// holding something this build couldn't read, which has no place to go.
    @discardableResult
    func unwrap(_ id: UUID) -> [UUID] {
        let index = index
        guard let entry = index[id], let slot = entry.path.last, let container = index.node(id, in: tree),
              container.isContainer, container.unreadChildren.isEmpty else { return [] }
        let released = container.children.map { TreeRules.released($0, from: container) }
        changeTree(writing: released.count + 1) { tree in
            tree.changeChildren(on: entry.host, at: Array(entry.path.dropLast())) { children in
                children.replaceSubrange(slot...slot, with: released)
            }
        }
        return released.map(\.id)
    }

    /// On a container or a screen root. Free → stack or grid: reading order first, children fixed at their size.
    /// Laid out → free: frames kept.
    ///
    /// Free to an overlay fixes the children at their size too, in their order. One layout to another
    /// leaves the children as they are.
    func setLayout(_ id: UUID, _ layout: LayerNode.Layout) {
        let memo = index
        guard let entry = memo[id], let node = memo.node(id, in: tree), node.isContainer,
              node.resolvedLayout != layout else { return }
        let fromFree = node.resolvedLayout == .free
        changeTree(writing: 1 + (fromFree ? node.children.count : 0)) { tree in
            tree.changeNode(on: entry.host, at: entry.path) { node in
                if fromFree {
                    node.children = TreeEdit.readingOrder(node.children, for: layout)
                    for index in node.children.indices {
                        node.children[index].width = LayerNode.Sizing(.fixed)
                        node.children[index].height = LayerNode.Sizing(.fixed)
                    }
                }
                node.layout = layout == .free ? nil : layout
            }
        }
    }

    // MARK: Writing a screen whole

    /// The point a reconciler commits through: one change, one rules pass. False when the screen is gone.
    ///
    /// Also false, and nothing changes, when the root `body` leaves is more than the tree can hold: a node
    /// deeper than 32, or a design of more than 5,000 nodes. `body` is given a copy of the screen's root
    /// before the change is made, so it may read the store, and may change anything in it. The root keeps
    /// its id. A node below it whose id the design uses elsewhere, or that one before it in the root has,
    /// is given a new one, so that no id is held twice. Not counted in `ListWork`: a whole host set at once.
    @discardableResult
    func reconcile(_ screenID: TreeScreen.ID, _ body: (inout LayerNode) -> Void) -> Bool {
        let index = index
        guard let old = tree.screens.first(where: { $0.id == screenID })?.root else { return false }
        var root = old
        body(&root)
        root.id = old.id
        TreeEdit.renewIDs(below: &root) { id in index[id].map { $0.host != .screen(screenID) } ?? false }
        guard TreeEdit.levels(below: root) <= TreeRules.maximumDepth,
              index.count - Set(TreeEdit.ids(in: old)).count + TreeEdit.count(of: root) <= TreeRules.maximumNodes
        else { return false }
        let made = root
        changeTree(writing: 0) { tree in
            guard let screen = tree.screens.firstIndex(where: { $0.id == screenID }) else { return }
            tree.screens[screen].root = made
        }
        return true
    }

    // MARK: Deleting and duplicating

    /// Subtrees removed; screen roots never. The reading log is told once.
    ///
    /// The log is told every id that went, those inside the containers deleted included.
    func delete(nodes ids: Set<UUID>) {
        let index = index, tree = tree
        func isDeletable(_ id: UUID) -> Bool { index[id].map { !$0.path.isEmpty } ?? false }
        var going: [TreeIndex.Entry] = []
        var removed: Set<UUID> = []
        for id in ids where isDeletable(id) {
            // What is inside another that goes, goes with it.
            guard let entry = index[id], !index.ancestors(of: id).contains(where: { ids.contains($0) && isDeletable($0) }),
                  let node = index.node(id, in: tree) else { continue }
            going.append(entry)
            removed.formUnion(TreeEdit.ids(in: node))
        }
        guard !going.isEmpty else { return }
        // Last first, so that each path still names its node when that is taken out (`TreeEdit.path(_:afterRemoving:)`).
        let order = going.sorted { $1.path.lexicographicallyPrecedes($0.path) }
        changeTree(writing: removed.count) { tree in
            for entry in order {
                tree.changeChildren(on: entry.host, at: Array(entry.path.dropLast())) { $0.remove(at: entry.path[entry.path.count - 1]) }
            }
        }
        tellTheReadingLogOfDeleted(removed)
    }

    /// Copy with new ids, offset 16 of its own points, on top at the host's top level, else just in front of
    /// the original; unlocked; drawings get strokes of their own. Nil when it is gone or is a screen root.
    ///
    /// The offset is down and to the right on the canvas, whatever the turn of what holds it. Also nil when
    /// the copy would take the design past 5,000 nodes. What is inside the copy keeps its own lock and hide.
    @discardableResult
    func duplicate(node id: UUID) -> UUID? {
        let index = index
        guard let entry = index[id], let slot = entry.path.last, let original = index.node(id, in: tree),
              index.count + TreeEdit.count(of: original) <= TreeRules.maximumNodes else { return nil }
        var copy = Self.withStrokesOfTheirOwn(TreeEdit.copyWithNewIDs(original))
        copy.isLocked = false
        let turn = entry.parent.flatMap { index[$0]?.hostShape.degrees } ?? 0
        let shift = Rotation.normalized(turn) == 0 ? CGPoint(x: 16, y: 16)
            : CGPoint(x: 16, y: 16).applying(CGAffineTransform(rotationAngle: -turn * .pi / 180))
        copy.frame.origin.x += shift.x
        copy.frame.origin.y += shift.y
        let made = copy, isOnTop = entry.path.count == 1
        changeTree(writing: 1) { tree in
            tree.changeChildren(on: entry.host, at: Array(entry.path.dropLast())) { children in
                children.insert(made, at: isOnTop ? children.count : slot + 1)
            }
        }
        return made.id
    }

    // MARK: - How the verbs work

    /// A list of children a verb puts things in: a container's, a screen root's, or the canvas's top level.
    private struct Holder {
        var host: TreeIndex.Host
        /// The holding node's path from its host's top; on the canvas, [] is the top level itself.
        var path: [Int]
        /// The holding node: nil for the canvas's top level.
        var node: LayerNode?
        /// The depth of what it holds.
        var depth: Int
        /// Its own space to its host's: nil for the canvas's top level, where each node has a scale of its own.
        var toHost: CGAffineTransform?
        /// Its angle in its host, its ancestors' included.
        var degrees: Double

        var isFree: Bool { (node?.resolvedLayout ?? .free) == .free }
    }

    /// Where `parent` is, or nil when the design doesn't have it or it isn't a container.
    private func locate(_ parent: NodeParent) -> Holder? {
        switch parent {
        case .canvas:
            return Holder(host: .canvas, path: [], node: nil, depth: 0, toHost: nil, degrees: 0)
        case .screen(let id):
            // The rules keep a root at the screen's origin, upright.
            guard let screen = tree.screens.first(where: { $0.id == id }) else { return nil }
            return Holder(host: .screen(id), path: [], node: screen.root, depth: 1, toHost: .identity, degrees: 0)
        case .node(let id):
            let index = index
            guard let entry = index[id], let node = index.node(id, in: tree), node.isContainer else { return nil }
            return Holder(host: entry.host, path: entry.path, node: node, depth: entry.depth + 1, toHost: entry.toHost,
                          degrees: entry.hostShape.degrees)
        }
    }

    /// Whether `nodes` can go in `holder`: each where it `fits`, none deeper than 32, no id given twice or that
    /// the design has (besides those in `replacing`, which go), and no more than 5,000 nodes in the design after.
    private func accepts(_ nodes: [LayerNode], in holder: Holder, replacing: [LayerNode] = []) -> Bool {
        let index = index
        let going = Set(replacing.flatMap(TreeEdit.ids(in:)))
        var seen: Set<UUID> = []
        for node in nodes {
            guard holder.depth + TreeEdit.levels(below: node) <= TreeRules.maximumDepth, Self.fits(node, in: holder) else { return false }
            for id in TreeEdit.ids(in: node) {
                guard seen.insert(id).inserted, index[id] == nil || going.contains(id) else { return false }
            }
        }
        return index.count - going.count + seen.count <= TreeRules.maximumNodes
    }

    /// Whether a subtree can be in `holder` as the rules keep the tree (their 2 and 3): no drawing or sticky
    /// note on a screen, and a drawing only on the canvas's top level, never inside a container.
    private static func fits(_ node: LayerNode, in holder: Holder) -> Bool {
        if case .screen = holder.host, TreeEdit.holds(node, where: { !$0.kind.belongsOnScreens }) { return false }
        let inside = holder.node == nil ? node.children : [node]
        return !inside.contains { TreeEdit.holds($0, where: { $0.kind == .drawing }) }
    }

    /// `node` in `holder`'s space where it is now on the canvas: its centre and its angle there kept, its size
    /// in its own points kept. A holder on another host is reached through the canvas, and the corner put on
    /// whole points. `scale` is what the canvas's top level draws it at.
    private func keepingItsPlace(_ node: LayerNode, from entry: TreeIndex.Entry, into holder: Holder, drawnAt scale: CGFloat) -> LayerNode {
        let size = node.frame.size
        var centre = CGPoint(x: size.width / 2, y: size.height / 2).applying(entry.toHost)
        var into = holder.toHost ?? CGAffineTransform(scaleX: scale, y: scale)
        let isAcross = holder.host != entry.host
        if isAcross {
            centre = centre.applying(hostToCanvas(entry.host))
            into = into.concatenating(hostToCanvas(holder.host))
        }
        let local = centre.applying(into.inverted())
        var origin = CGPoint(x: local.x - size.width / 2, y: local.y - size.height / 2)
        if isAcross { origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded()) }
        var placed = node
        placed.frame.origin = origin
        placed.rotation = Rotation.kept(entry.hostShape.degrees - holder.degrees)
        return placed
    }

    /// A host's space, as `TreeIndex` has it, to the canvas's: a screen's through its placement.
    private func hostToCanvas(_ host: TreeIndex.Host) -> CGAffineTransform {
        guard case .screen(let id) = host, let screen = tree.screens.first(where: { $0.id == id }) else { return .identity }
        let scale = Self.drawn(screen.scale)
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: screen.origin.x, y: screen.origin.y))
    }

    /// How many canvas points each of a node's own is drawn as: its screen's scale, or its top-level canvas node's.
    private func drawnScale(of entry: TreeIndex.Entry) -> CGFloat {
        let tree = tree
        switch entry.host {
        case .screen(let id):
            return Self.drawn(tree.screens.first { $0.id == id }?.scale)
        case .canvas:
            guard let top = entry.path.first, tree.canvas.indices.contains(top) else { return 1 }
            return Self.drawn(tree.canvas[top].scale)
        }
    }

    /// Nodes from the canvas's top level as a container drawn at `scale` holds them, which is how `wrap` holds them: each
    /// drawn at another scale is carried into it through canvas points, so it stays where it is, as large, and none keeps
    /// a scale of its own.
    static func held(_ nodes: [LayerNode], drawnAt scale: CGFloat?) -> [LayerNode] {
        let scale = drawn(scale)
        return nodes.map { node in
            var held = node
            let own = drawn(node.scale)
            if own != scale {
                let onCanvas = Placement(origin: .zero, scale: own).canvasRect(for: node.frame)
                held.frame = Placement(origin: .zero, scale: scale).localRect(for: onCanvas)
            }
            held.scale = nil
            return held
        }
    }

    /// A scale as it is drawn: 1 for none, or one that isn't a size.
    private static func drawn(_ scale: CGFloat?) -> CGFloat {
        scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
    }

    /// Where `index` puts a node among `children`: in front when nil, and within them.
    private static func slot(_ index: Int?, in children: [LayerNode]) -> Int {
        min(max(index ?? children.count, 0), children.count)
    }

    /// A copy whose drawings have strokes of their own, so that the ink canvas doesn't take them for the original's.
    private static func withStrokesOfTheirOwn(_ node: LayerNode) -> LayerNode {
        var copy = node.withStrokesOfItsOwn()
        copy.children = copy.children.map(withStrokesOfTheirOwn)
        return copy
    }

    /// One change to the tree, one step; `written` nodes counted in `ListWork` when it changed anything.
    func changeTree(writing written: Int, _ body: (inout TreeContent) -> Void) {
        #if DEBUG
        let version = contentVersion
        #endif
        apply { body(&$0.tree) }
        #if DEBUG
        if contentVersion != version { ListWork.wrote(written) }
        #endif
    }
}
