import CoreGraphics
import Foundation

/// Groups: several things on one screen, or on the open canvas, kept together as one.
///
/// A group is a container in the design's tree, holding its members as its children, and nesting
/// in another as one of its children. It carries the group's name, lock, hide and angle; a free
/// group's frame is the box round what it holds. What draws, exports, describes, hit-tests and
/// lists things reads the tree (`TreeIndex`, `TreeTargets`), any container standing for what it
/// holds until it is gone into.
extension DesignStore {
    // MARK: Selecting with containers

    /// The containers that hold something, at any depth, the nearest first: a card, row, column, grid or
    /// overlay as much as a group. A screen's root isn't one: it is the screen. Read from the index.
    func groups(holding ref: ElementRef) -> [ElementRef] {
        let memo = index
        return memo.ancestors(of: ref.element).compactMap { id in
            guard let entry = memo[id], !entry.path.isEmpty else { return nil }
            return ElementRef(host: ref.host, element: id)
        }
    }

    /// What a tap on `leaf` picks while the containers in `entered` have been gone into (something
    /// in each is selected): the outermost of it and the containers above it that hasn't been,
    /// which is `leaf` itself once all of them have. A container stands for a tap in the gap
    /// between what it holds.
    func pickTarget(for leaf: ElementRef, entered: Set<UUID>) -> ElementRef {
        groups(holding: leaf).last { !entered.contains($0.element) } ?? leaf
    }

    /// One level in from `outer` towards `leaf`: the container just inside `outer` on the way to
    /// `leaf`, or `leaf` itself. `leaf` when `outer` is `leaf`, or doesn't hold it.
    func nextLevel(in outer: ElementRef, towards leaf: ElementRef) -> ElementRef {
        let path = [leaf] + groups(holding: leaf)
        guard let index = path.firstIndex(of: outer), index > 0 else { return leaf }
        return path[index - 1]
    }

    // MARK: Moving, landing and resizing a group

    /// A container as a handle drag on it began: what each frame of the drag resizes it from, so
    /// that the frames don't compound and drift.
    struct GroupPose: Equatable, Sendable {
        /// Its box: its upright frame in its host's own points, centred on its turned shape's centre.
        var box: CGRect
        /// It and everything in it, as the drag began: what each frame scales.
        var node: LayerNode
        /// The least it can be scaled by: any less, and something in it would be smaller than its
        /// kind can be. Never more than 1: one that already is stops it shrinking.
        var smallestScale: CGFloat
        /// Whether it is a row, column, grid or overlay itself, its own one leaf: resized by its
        /// frame, with what is in it laid out by the engine.
        var isLaidOut = false
        /// Where what holds it sat: its own frame is put back as it was only while that is so. A group sized to fit
        /// moves its box, and every frame in it, as what it holds grows past its edges.
        var parentSpace: TreeIndex.OwnSpace = .host
    }

    /// A container as it is now, read from the tree: see `GroupPose`. Nil when `ref` isn't a container
    /// where the ref says. A row, column, grid or overlay in it counts as one leaf, and one resized
    /// itself is its own one leaf: what is in it is laid out by the engine, never scaled.
    func groupPose(of ref: ElementRef) -> GroupPose? {
        guard let placed = placed(ref), placed.node.isContainer,
              let parentSpace = index.posed(ref.element, in: tree)?.parentSpace else { return nil }
        let isLaidOut = placed.node.resolvedLayout != .free
        var pose = GroupPose(box: placed.frame, node: placed.node, smallestScale: 0, isLaidOut: isLaidOut, parentSpace: parentSpace)
        func consider(_ leaf: LayerNode) {
            let spec = leaf.kind.spec
            var smallest = leaf.frame.width > 0 ? spec.minimumSize.width / leaf.frame.width : 1
            if !spec.hasFixedHeight, leaf.frame.height > 0 { smallest = max(smallest, spec.minimumSize.height / leaf.frame.height) }
            pose.smallestScale = max(pose.smallestScale, min(smallest, 1))
        }
        func visit(_ node: LayerNode) {
            for child in node.children {
                if child.isContainer, child.resolvedLayout == .free { visit(child) } else { consider(child) }
            }
        }
        if isLaidOut { consider(placed.node) } else { visit(placed.node) }
        return pose
    }

    /// The most a group can be scaled to, by a frame asked for in one go.
    static let largestGroupScale: CGFloat = 100

    /// Resizes a container to `frame`, in its host's own points, as one change on the tree: from
    /// `start`, the container as a handle drag on it began, or from where it is now. With s the new
    /// box's width over the start's, the middle of each thing in it goes where it was in the start
    /// box, read along the box's own axes, in the new one; and each one's frame is s times as large,
    /// apart from the height of a kind that keeps its height, a divider. Their angles, and their
    /// text's size, stay as they are, so that a turned member is never sheared. A frame in
    /// proportion with the box, as the handles and the fields give, scales everything alike; a
    /// container that fits what it holds is then fitted round it again by the tree's rules. Made
    /// smaller than something in it can be, it is scaled only as far as that can go, about the same
    /// point. Nothing happens to a container that is locked, by itself or by one above it.
    ///
    /// A row, column, grid or overlay in it is one leaf, scaled as one and fixed at its new size,
    /// and what is in it is laid out again. One resized itself takes `frame` as it is: it is fixed
    /// on each axis whose size changed, and the engine lays out what is in it.
    func resizeGroup(_ ref: ElementRef, to frame: CGRect, from start: GroupPose? = nil) {
        // Read from the tree, as every frame of a handle's drag reads it, so that a frame builds the store's
        // index and never lowers the design to its list (clause (m)).
        guard let group = placed(ref), group.node.isContainer, !group.isLocked,
              let pose = start ?? groupPose(of: ref), pose.box.width > 0, pose.box.height > 0, frame.width > 0, frame.height > 0
        else { return }
        // A typed number can be anything Double reads, infinity included: finite, and at most a
        // hundred times the box it began as, or what is in it goes non-finite and the design can't be saved.
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        var frame = frame
        frame.size.width = min(frame.width, pose.box.width * Self.largestGroupScale)
        frame.size.height = min(frame.height, pose.box.height * Self.largestGroupScale)
        var scale = frame.width / pose.box.width
        if scale < pose.smallestScale {
            // The point the frame asked for is scaled about stays where it is: the corner across
            // from a handle, or the top-left for the fields.
            let from = CGPoint(x: pose.box.midX, y: pose.box.midY), to = CGPoint(x: frame.midX, y: frame.midY)
            let fixed = CGPoint(x: (to.x - scale * from.x) / (1 - scale), y: (to.y - scale * from.y) / (1 - scale))
            scale = pose.smallestScale
            let size = CGSize(width: pose.box.width * scale, height: pose.box.height * scale)
            let centre = CGPoint(x: fixed.x + (from.x - fixed.x) * scale, y: fixed.y + (from.y - fixed.y) * scale)
            frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        }
        guard let entry = index[ref.element], let posed = index.posed(ref.element, in: tree) else { return }
        // Read from the pose, not the design: each frame of a handle's drag scales what was there as it began.
        var resized = posed.node
        // Back where it began, in a parent where it was, exactly as it was, with no arithmetic to round.
        resized.frame = frame == pose.box && posed.parentSpace == pose.parentSpace ? pose.node.frame : posed.parentSpace.local(of: frame)
        if pose.isLaidOut {
            (resized.width, resized.height) = (pose.node.width, pose.node.height)
            Self.fix(&resized, from: pose.node.frame.size, to: frame.size)
        } else {
            let across = CGSize(width: frame.width / pose.box.width, height: frame.height / pose.box.height)
            resized = Self.scaling(resized, from: pose.node, across: across, by: scale)
        }
        guard resized != posed.node else { return }
        let written = resized
        changeTree(writing: 1) { tree in
            tree.changeNode(on: entry.host, at: entry.path) { $0 = written }
        }
    }

    /// `node` with what it holds scaled from `start`, as it was when a resize began: matched by id, each
    /// child's middle at its own across `across` from the box's top-left, where its own space starts,
    /// and its frame `scale` times as large, a divider's height kept. A free container in it is scaled
    /// the same way through, its own space as much larger as it is; a row, column, grid or overlay is
    /// fixed at its new size on each axis that changed, for the engine to lay out what it holds.
    private static func scaling(_ node: LayerNode, from start: LayerNode, across: CGSize, by scale: CGFloat) -> LayerNode {
        var node = node
        let was = Dictionary(start.children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in node.children.indices {
            guard let before = was[node.children[index].id] else { continue }
            var child = node.children[index]
            let keepsHeight = !before.isContainer && before.kind.spec.hasFixedHeight
            let size = CGSize(width: before.frame.width * scale, height: keepsHeight ? before.frame.height : before.frame.height * scale)
            child.frame = CGRect(x: before.frame.minX * across.width + (before.frame.width * across.width - size.width) / 2,
                                 y: before.frame.minY * across.height + (before.frame.height * across.height - size.height) / 2,
                                 width: size.width, height: size.height)
            if before.isContainer, before.resolvedLayout == .free {
                child = scaling(child, from: before, across: CGSize(width: scale, height: scale), by: scale)
            } else if before.isContainer {
                (child.width, child.height) = (before.width, before.height)
                fix(&child, from: before.frame.size, to: size)
            }
            node.children[index] = child
        }
        return node
    }

    /// `.fixed` on each axis whose size changed.
    private static func fix(_ node: inout LayerNode, from old: CGSize, to new: CGSize) {
        if new.width != old.width { node.width.mode = .fixed }
        if new.height != old.height { node.height.mode = .fixed }
    }

    // MARK: Group and Ungroup

    /// Whether Group would make a group of what is selected: see `group(_:)`.
    func canGroup(_ selection: CanvasSelection) -> Bool {
        canGroup(selection, as: .group)
    }

    /// Puts what is selected in a new group, as one step, and returns the group. Locked
    /// things and drawings are left out of it; the rest are to be two or more, on one screen
    /// or all on the open canvas, and in one container (or none) without being all of it,
    /// with no screen among what is selected. Nil, and nothing changes, when they aren't.
    ///
    /// The group is a free one, wrapped round them in the container they are in, in the slot
    /// of the frontmost of them, which a row or a column then lays out as one thing (`wrap`).
    /// It fits round them on both axes, so nothing moves. On the open canvas it is drawn at its
    /// frontmost member's scale; members drawn at others are boxed in canvas points (L5). It
    /// is named as its kind until it is renamed. Group as a group (`group(_:as:)`), which also refuses a wrap past the
    /// store's depth and node limits (F15).
    @discardableResult
    func group(_ selection: CanvasSelection) -> ElementRef? {
        group(selection, as: .group)
    }

    /// Today's Group rules, on node ids (F4): the unlocked things selected, with no drawings or screens, sharing one
    /// parent, at least `minimum` of them, back to front. All of a free group is refused when
    /// `refusingAllOfAFreeGroup`. Nil when they can't be grouped.
    ///
    /// A thing locked by itself or a container above it, a drawing, and a thing that is gone or no longer where the
    /// selection says are left out; a screen among them refuses them all. One parent is one container, one screen's
    /// root, or the canvas's top level. Every child of a free group, grouped, would make that group again under a new
    /// id: left with one child, the old group would dissolve into the new, and its name and angle with it. A locked
    /// child, left out, keeps the rest from being all of it. A row, column, grid or card doesn't dissolve, so all of
    /// what one holds can be wrapped.
    func groupable(_ selection: CanvasSelection, minimum: Int, refusingAllOfAFreeGroup: Bool) -> [UUID]? {
        var members: [UUID] = []
        for thing in things(in: selection) {
            guard case .element(let ref) = thing else { return nil }
            guard let placed = placed(ref), placed.node.kind != .drawing, !placed.isLocked else { continue }
            members.append(ref.element)
        }
        guard members.count >= max(minimum, 1), let first = members.first, let shared = parent(of: first),
              members.allSatisfy({ parent(of: $0) == shared }) else { return nil }
        if refusingAllOfAFreeGroup, case .node(let id) = shared, let group = node(id), group.kind == .group,
           group.resolvedLayout == .free, group.children.count == members.count {
            return nil
        }
        return members
    }

    /// Takes a group apart, as one step, and returns its members as a selection. They go to
    /// the container the group was in (or to none), in the group's slot, so that a row they
    /// join lays them out there (`unwrap`). Each stays where it is on screen, its turn and the
    /// group's added up, and takes on the group's lock and hide, so that a hidden group's
    /// members don't reappear. Not its members' groups: those stay whole. Nil, and nothing
    /// changes, when `ref` isn't a container where it says, or holds something this build couldn't read. A card, row,
    /// column, grid or overlay is taken apart as a group is. Read from the tree.
    ///
    /// Taking apart a row, column or grid the structure pass made declines what it held, so
    /// that the pass never puts it back (plan 5, call 11). The marks are part of the step
    /// (plan 5's final review, A9): undoing it puts the container back with nothing declined.
    @discardableResult
    func ungroup(_ ref: ElementRef) -> CanvasSelection? {
        guard let item = placed(ref), item.node.isContainer else { return nil }
        let wasThePasses = item.node.sketch?.decidedBy == .structure
        var members: [UUID] = []
        asOneStep {
            members = unwrap(ref.element)
            if wasThePasses { apply { $0.tree = Self.declining(Set(members), in: $0.tree) } }
        }
        return CanvasSelection(members.map { .element(ElementRef(host: ref.host, element: $0)) })
    }

    /// Unlocks what is selected and, so that it is unlocked, every locked container above it, as
    /// one step: a thing locked only by its container would otherwise stay locked (Ruling D). Each
    /// one's own flag is written; the containers are found through the index.
    func unlock(_ selection: CanvasSelection) {
        let memo = index, tree = tree
        var nodes: [UUID] = []
        var screens: [TreeScreen.ID] = []
        for thing in things(in: selection) {
            switch thing {
            case .element(let ref):
                nodes.append(ref.element)
                nodes += memo.ancestors(of: ref.element).filter { id in
                    memo[id].map { !$0.path.isEmpty } == true && memo.node(id, in: tree)?.isLocked == true
                }
            case .screen(let id):
                screens.append(id)
            case .several:
                continue
            }
        }
        setOwnLocks(false, nodes: nodes, screens: screens)
    }
}

extension DesignStore.ElementRef.Host {
    /// The screen it is, or nil for the open canvas: what an element there has as its `parent`.
    var parent: TreeScreen.ID? {
        if case .screen(let id) = self { id } else { nil }
    }
}
