import CoreGraphics
import Foundation

/// Groups: several things on one screen, or on the open canvas, kept together as one.
///
/// A group is a container in the design's tree. In the list the tree is lowered to
/// (`DesignContent.elements`) it is an element of the kind `.group`, on the host its members
/// are on, just in front of them. Each member says which group it belongs to with its
/// `group`, and groups nest by a group item belonging to another. The item carries the
/// group's name, lock, hide and angle; its frame is the box round its members.
///
/// What draws, exports, describes and hit-tests elements reads the design's views
/// (`screens`, `floating`), which leave group items out and give each member the lock and
/// hide of the groups above it. What shows the tree, the Layers panel, reads the list itself
/// (`children(of:)`): group items included, with each thing's own flags. What can be touched
/// on the canvas is read from the tree itself, any container standing for what it holds
/// (`TreeTargets`).
// PROJECTION: deleted in plan 6
// The list's group pointers, read by tests of the projection and by plan 6's callers (voice, Siri).
extension DesignContent {
    /// The things that belong to a group directly, back to front.
    func members(of group: DesignElement.ID) -> [DesignElement] {
        Self.members(of: group, in: elements)
    }

    /// The things in a group at any depth that aren't groups themselves, back to front.
    func leaves(of group: DesignElement.ID) -> [DesignElement] {
        Self.leaves(of: group, in: elements)
    }

    /// `members(of:)` in a list of the design's elements: the content's own, or the store's kept one.
    static func members(of group: DesignElement.ID, in elements: [DesignElement]) -> [DesignElement] {
        elements.filter { $0.group == group }
    }

    /// `leaves(of:)` in a list of the design's elements.
    static func leaves(of group: DesignElement.ID, in elements: [DesignElement]) -> [DesignElement] {
        #if DEBUG
        GroupWork.leafWalked()
        #endif
        return contents(of: group, in: elements).filter { $0.kind != .group }
    }

    /// `contents(of:)` in a list of the design's elements.
    static func contents(of group: DesignElement.ID, in elements: [DesignElement]) -> [DesignElement] {
        var inside: [DesignElement.ID: [DesignElement.ID]] = [:]
        for element in elements {
            if let parentGroup = element.group { inside[parentGroup, default: []].append(element.id) }
        }
        var found: Set<DesignElement.ID> = []
        var waiting = inside[group] ?? []
        while let next = waiting.popLast() {
            guard next != group, found.insert(next).inserted else { continue }
            waiting += inside[next] ?? []
        }
        return found.isEmpty ? [] : elements.filter { found.contains($0.id) }
    }

    /// The groups an element is in, the nearest first.
    func ancestors(of id: DesignElement.ID) -> [DesignElement.ID] {
        guard let element = element(id) else { return [] }
        return Self.groups(above: element, find: element(_:)).map(\.id)
    }

    /// Whether an element is locked: by itself, or by a group above it.
    func isLockedWithItsGroups(_ id: DesignElement.ID) -> Bool {
        guard let element = element(id) else { return false }
        return element.isLocked || Self.groups(above: element, find: element(_:)).contains(where: \.isLocked)
    }

    /// Whether an element is hidden: by itself, or by a group above it.
    func isHiddenWithItsGroups(_ id: DesignElement.ID) -> Bool {
        guard let element = element(id) else { return false }
        return element.isHidden || Self.groups(above: element, find: element(_:)).contains(where: \.isHidden)
    }

    /// The groups above an element, the nearest first, looked up with `find`. The chain
    /// ends at a group that isn't there or isn't a group item, and at one met before, so
    /// that a design whose groups loop, which only a damaged file has, can't hang it.
    static func groups(above element: DesignElement, find: (DesignElement.ID) -> DesignElement?) -> [DesignElement] {
        var found: [DesignElement] = []
        var seen: Set<DesignElement.ID> = [element.id]
        var next = element.group
        while let id = next, seen.insert(id).inserted, let group = find(id), group.kind == .group {
            found.append(group)
            next = group.group
        }
        return found
    }

    // MARK: Keeping groups sound

    // PROJECTION: deleted in plan 6
    /// Puts right whatever a change has left unsound about the design's groups. It runs at the
    /// end of every change to the design, after undo and redo, and when a design is read, so
    /// anything that builds or moves a group does all of it in one change: split over several,
    /// this would run in between and undo the half-built group.
    ///
    /// The tree holds what the list could get wrong, so of today's rules:
    /// 1. a member whose group isn't there, isn't a group, is on another host or has it inside
    ///    itself, and a drawing in a group, are pointers the lift couldn't honour: they wait in
    ///    `pendingPointers`, and are cut here, leaving each where it is;
    /// 2. a group with no members goes, and 3. a group of one dissolves into the group above,
    ///    with its lock and hide: `TreeRules`;
    /// 4. a group's members are one run with the group in front of them: the lift nests them;
    /// 5. each group's box is fitted round its members, at its angle: `TreeRules` lays out a
    ///    free group that fits what it holds.
    mutating func keepGroupsSound() {
        pendingPointers = [:]
        TreeRules.apply(to: &tree, after: nil)
    }
}

// PROJECTION: deleted in plan 6
// The list's groups read from the store's kept projection: for `AppModel.selectedLeaves` (voice) and the tests of
// the projection's groups. The canvas and panels read the tree.
extension DesignStore {
    /// What is on a screen, or on the open canvas, back to front, as the design's own list
    /// holds it: group items included, and each thing with its own lock and hide.
    func children(on host: ElementRef.Host) -> [DesignElement] {
        projection.children(of: host.parent)
    }

    /// The things in a group at any depth that aren't groups themselves, read from the design as it is kept for this
    /// version (`projection`) rather than lowered again: see `DesignContent.leaves(of:)`.
    func leaves(of group: DesignElement.ID) -> [DesignElement] {
        DesignContent.leaves(of: group, in: projection.elements)
    }

    /// The group items on a screen, or on the open canvas, back to front.
    func groupItems(on host: ElementRef.Host) -> [DesignElement] {
        children(on: host).filter { $0.kind == .group }
    }

    /// A group item, or nil when there is none by that identifier.
    func groupItem(_ id: DesignElement.ID) -> DesignElement? {
        element(id).flatMap { $0.kind == .group ? $0 : nil }
    }

    /// Whether an element is locked: by itself, or by a group above it.
    func isLockedWithItsGroups(_ element: DesignElement) -> Bool {
        element.isLocked || element.group != nil && DesignContent.groups(above: element, find: self.element(_:)).contains(where: \.isLocked)
    }
}

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
    func pickTarget(for leaf: ElementRef, entered: Set<DesignElement.ID>) -> ElementRef {
        groups(holding: leaf).last { !entered.contains($0.element) } ?? leaf
    }

    /// One level in from `outer` towards `leaf`: the container just inside `outer` on the way to
    /// `leaf`, or `leaf` itself. `leaf` when `outer` is `leaf`, or doesn't hold it.
    func nextLevel(in outer: ElementRef, towards leaf: ElementRef) -> ElementRef {
        let path = [leaf] + groups(holding: leaf)
        guard let index = path.firstIndex(of: outer), index > 0 else { return leaf }
        return path[index - 1]
    }

    /// What can be touched on each screen and the open canvas while the containers in `entered` have been
    /// gone into: see `TreeTargets`. Memoised per design version and entered set: hover asks on every move
    /// of the pen. `CanvasWork.targetPasses` counts each build.
    func treeTargets(entered: Set<UUID>) -> TreeTargets {
        keptTargets(entered: entered) {
            #if DEBUG
            CanvasWork.targetPasses += 1
            #endif
            return TreeTargets(tree, index: index, entered: entered)
        }
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
    @discardableResult
    func ungroup(_ ref: ElementRef) -> CanvasSelection? {
        guard let item = placed(ref), item.node.isContainer else { return nil }
        return CanvasSelection(unwrap(ref.element).map { .element(ElementRef(host: ref.host, element: $0)) })
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
    var parent: DesignScreen.ID? {
        if case .screen(let id) = self { id } else { nil }
    }
}
