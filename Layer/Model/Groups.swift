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
extension DesignContent {
    /// Whether any element is a group item or says it belongs to a group: a member left
    /// pointing at a group that has gone still needs `keepGroupsSound()`. One scan of the
    /// list, so that a design without groups costs no more than that.
    var hasGroups: Bool {
        elements.contains { $0.kind == .group || $0.group != nil }
    }

    /// The things that belong to a group directly, back to front.
    func members(of group: DesignElement.ID) -> [DesignElement] {
        Self.members(of: group, in: elements)
    }

    /// The things in a group at any depth that aren't groups themselves, back to front.
    func leaves(of group: DesignElement.ID) -> [DesignElement] {
        Self.leaves(of: group, in: elements)
    }

    /// Everything in a group at any depth, the groups inside it included, back to front.
    func contents(of group: DesignElement.ID) -> [DesignElement] {
        Self.contents(of: group, in: elements)
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

    // MARK: The views

    /// The group items, by identifier: where the views look up the groups above a member.
    /// Empty for a design without groups.
    var groupItemsByID: [DesignElement.ID: DesignElement] {
        var items: [DesignElement.ID: DesignElement] = [:]
        for element in elements where element.kind == .group && items[element.id] == nil {
            items[element.id] = element
        }
        return items
    }

    /// An element as the views show it: locked when it or a group above it is, and hidden
    /// likewise, so that what reads the views, unaware of groups, leaves it alone or out.
    static func shown(_ element: DesignElement, groups: [DesignElement.ID: DesignElement]) -> DesignElement {
        guard element.group != nil, !groups.isEmpty, !(element.isLocked && element.isHidden) else { return element }
        var shown = element
        for group in Self.groups(above: element, find: { groups[$0] }) {
            shown.isLocked = shown.isLocked || group.isLocked
            shown.isHidden = shown.isHidden || group.isHidden
        }
        return shown
    }

    /// An element given to a view's setter, as it is to be kept. A lock or hide that is as
    /// the view showed it (`shown`) keeps the element's own flag, so that writing a view
    /// back as it was read changes nothing; one that differs is written.
    static func written(_ given: DesignElement, over stored: DesignElement?, groups: [DesignElement.ID: DesignElement]) -> DesignElement {
        guard let stored, !groups.isEmpty else { return given }
        let shown = shown(stored, groups: groups)
        var written = given
        if given.isLocked == shown.isLocked { written.isLocked = stored.isLocked }
        if given.isHidden == shown.isHidden { written.isHidden = stored.isHidden }
        return written
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

extension DesignStore {
    /// What is on a screen, or on the open canvas, back to front, as the design's own list
    /// holds it: group items included, and each thing with its own lock and hide.
    func children(on host: ElementRef.Host) -> [DesignElement] {
        projection.children(of: host.parent)
    }

    /// The things that belong to a group directly, back to front, read from the design as it is
    /// kept for this version (`projection`) rather than lowered again: see `DesignContent.members(of:)`.
    func members(of group: DesignElement.ID) -> [DesignElement] {
        DesignContent.members(of: group, in: projection.elements)
    }

    /// The things in a group at any depth that aren't groups themselves, as `members(of:)` reads them.
    func leaves(of group: DesignElement.ID) -> [DesignElement] {
        DesignContent.leaves(of: group, in: projection.elements)
    }

    /// Everything in a group at any depth, the groups inside it included, as `members(of:)` reads them.
    func contents(of group: DesignElement.ID) -> [DesignElement] {
        DesignContent.contents(of: group, in: projection.elements)
    }

    /// What is in a group, at any depth, that moves, turns and is resized with it as a part of
    /// its own, back to front: everything in it, but a row, column, grid or overlay in it is one
    /// part without what it holds, which the engine lays out in it. Empty for a group that is laid
    /// out itself, which is one rigid part.
    func parts(of group: DesignElement.ID) -> [DesignElement] {
        guard let node = node(group), node.resolvedLayout == .free else { return [] }
        var ids: Set<UUID> = []
        func collect(_ node: LayerNode) {
            for child in node.children {
                ids.insert(child.id)
                if child.isContainer, child.resolvedLayout == .free { collect(child) }
            }
        }
        collect(node)
        return contents(of: group).filter { ids.contains($0.id) }
    }

    /// The group items on a screen, or on the open canvas, back to front.
    func groupItems(on host: ElementRef.Host) -> [DesignElement] {
        children(on: host).filter { $0.kind == .group }
    }

    /// A group item, or nil when there is none by that identifier.
    func groupItem(_ id: DesignElement.ID) -> DesignElement? {
        element(id).flatMap { $0.kind == .group ? $0 : nil }
    }

    /// Whether an element is locked: by itself, or by a group above it. Looked up in the
    /// store's index rather than the list.
    func isLockedWithItsGroups(_ element: DesignElement) -> Bool {
        element.isLocked || element.group != nil && DesignContent.groups(above: element, find: self.element(_:)).contains(where: \.isLocked)
    }

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

    /// What turns an element's frame into canvas points, where it is: its screen's placement,
    /// or on the open canvas its own scale. Nil when its screen is gone.
    func placement(of element: DesignElement) -> Placement? {
        guard let parent = element.parent else { return Placement(origin: .zero, scale: element.scale ?? 1) }
        return screen(parent)?.placement
    }

    /// A group as a handle drag on it began: what each frame of the drag resizes it from, so
    /// that the frames don't compound and drift.
    struct GroupPose: Equatable, Sendable {
        /// Its box: the group item's frame, in its own points.
        var box: CGRect
        /// The frame of each thing in it, at any depth, that isn't a group.
        var leaves: [DesignElement.ID: CGRect]
        /// Those of them whose kind keeps its height when it is resized, a divider: only their
        /// width is scaled.
        var keepingHeight: Set<DesignElement.ID>
        /// The least the group can be scaled by: any less, and something in it would be smaller
        /// than its kind can be. Never more than 1: one that already is stops it shrinking.
        var smallestScale: CGFloat
        /// Whether it is a row, column, grid or overlay itself, its own one leaf: resized by its
        /// frame, with what is in it laid out by the engine.
        var isLaidOut = false
    }

    /// A group as it is now: see `GroupPose`. Nil when `ref` isn't a group. A row, column, grid or
    /// overlay in it counts as one leaf, and one resized itself is its own one leaf: what is in it
    /// is laid out by the engine, never scaled (`parts(of:)`).
    func groupPose(of ref: ElementRef) -> GroupPose? {
        guard let item = resolve(ref)?.element, item.kind == .group else { return nil }
        var pose = GroupPose(box: item.frame, leaves: [:], keepingHeight: [], smallestScale: 0, isLaidOut: isLaidOut(item.id))
        let leaves = pose.isLaidOut ? [item] : parts(of: item.id).filter { $0.kind != .group || isLaidOut($0.id) }
        for element in leaves {
            pose.leaves[element.id] = element.frame
            let spec = element.kind.spec
            if spec.hasFixedHeight { pose.keepingHeight.insert(element.id) }
            var smallest = element.frame.width > 0 ? spec.minimumSize.width / element.frame.width : 1
            if !spec.hasFixedHeight, element.frame.height > 0 { smallest = max(smallest, spec.minimumSize.height / element.frame.height) }
            pose.smallestScale = max(pose.smallestScale, min(smallest, 1))
        }
        return pose
    }

    /// The most a group can be scaled to, by a frame asked for in one go.
    static let largestGroupScale: CGFloat = 100

    /// Resizes a group to `frame`, in its own points, as one change: from `start`, the group as
    /// a handle drag on it began, or from where it is now. With s the new box's width over the
    /// start's, the middle of each thing in it, at any depth, goes where it was in the start box,
    /// read along the box's own axes, in the new one; and each one's frame is s times as large,
    /// apart from the height of a kind that keeps its height, a divider. Their angles, and their
    /// text's size, stay as they are, so that a turned member is never sheared. A frame in
    /// proportion with the box, as the handles and the fields give, scales everything alike; the
    /// box is then fitted round them again by the tree's rules. Made smaller than something in it
    /// can be, it is scaled only as far as that can go, about the same point. Nothing happens to a
    /// group that is locked, by itself or by a group above it.
    ///
    /// A row, column, grid or overlay in it is one leaf, scaled as one and fixed at its new size,
    /// and what is in it is laid out again. One resized itself takes `frame` as it is: it is fixed
    /// at that size, and the engine lays out what is in it.
    func resizeGroup(_ ref: ElementRef, to frame: CGRect, from start: GroupPose? = nil) {
        // Read from the tree, as every frame of a handle's drag reads it, so that a frame builds the store's
        // index and never lowers the design to its list (clause (m)).
        guard let group = placed(ref), group.node.isContainer, !group.isLocked,
              let pose = start ?? groupPose(of: ref), pose.box.width > 0, pose.box.height > 0, frame.width > 0, frame.height > 0
        else { return }
        let placement = group.placement
        // A typed number can be anything Double reads, infinity included: finite, and at most a
        // hundred times the box it began as, or its members go non-finite and the design can't be saved.
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
        var frames: [DesignElement.ID: CGRect] = [:]
        // Read from the pose, not the design: on every frame of a handle's drag that would walk the whole tree.
        if pose.isLaidOut {
            frames[ref.element] = frame
        } else if frame == pose.box {
            // Back where it began: exactly as it was, with no arithmetic to round.
            frames = pose.leaves
        } else {
            let degrees = group.degrees
            let across = CGSize(width: frame.width / pose.box.width, height: frame.height / pose.box.height)
            /// Where a point in the start box goes in the new one, both in the points of `own`.
            func moved(_ point: CGPoint, in own: Placement) -> CGPoint {
                let from = own == placement ? pose.box : own.localRect(for: placement.canvasRect(for: pose.box))
                let to = own == placement ? frame : own.localRect(for: placement.canvasRect(for: frame))
                let upright = Rotation.normalized(degrees) == 0
                let along = upright ? point : Rotation.rotate(point, about: CGPoint(x: from.midX, y: from.midY), by: -degrees)
                let placed = CGPoint(x: to.minX + (along.x - from.minX) * across.width, y: to.minY + (along.y - from.minY) * across.height)
                return upright ? placed : Rotation.rotate(placed, about: CGPoint(x: to.midX, y: to.midY), by: degrees)
            }
            let memo = index, tree = tree
            for (id, start) in pose.leaves {
                guard let own = memo.placement(of: id, in: tree) else { continue }
                let centre = moved(CGPoint(x: start.midX, y: start.midY), in: own)
                let size = CGSize(width: start.width * scale, height: pose.keepingHeight.contains(id) ? start.height : start.height * scale)
                frames[id] = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
            }
        }
        apply { content in
            for (id, frame) in frames { content.update(id) { $0.frame = frame } }
        }
    }

    /// Where the middle of something in a group lands on the canvas, given at `point`, as the
    /// group lands with its box's middle at `middle`: as far from it in the points of
    /// `landing`, the placement it lands in, as it was in those of `own`, where it was.
    nonisolated static func landedMiddle(of point: CGPoint, about middle: CGPoint, from own: Placement, to landing: Placement) -> CGPoint {
        guard own.scale > 0, landing.scale != own.scale else { return point }
        let ratio = landing.scale / own.scale
        return CGPoint(x: middle.x + (point.x - middle.x) * ratio, y: middle.y + (point.y - middle.y) * ratio)
    }

    // MARK: Group and Ungroup

    /// Whether Group would make a group of what is selected: see `group(_:)`.
    func canGroup(_ selection: CanvasSelection) -> Bool {
        groupable(selection, minimum: 2, refusingAllOfAFreeGroup: true) != nil
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
    /// is named as its kind until it is renamed.
    @discardableResult
    func group(_ selection: CanvasSelection) -> ElementRef? {
        guard let members = groupable(selection, minimum: 2, refusingAllOfAFreeGroup: true),
              let host = members.last.flatMap(ref(of:))?.host,
              let made = wrap(members, in: .group, layout: .free) else { return nil }
        return ElementRef(host: host, element: made)
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
    /// changes, when `ref` isn't a group, or holds something this build couldn't read.
    @discardableResult
    func ungroup(_ ref: ElementRef) -> CanvasSelection? {
        guard let item = resolve(ref)?.element, item.kind == .group else { return nil }
        return CanvasSelection(unwrap(item.id).map { .element(ElementRef(host: ref.host, element: $0)) })
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

// MARK: The Layers tree

/// One row of the Layers panel's tree: a thing and what is in it, with the lock and hide it
/// has through the groups above it. Never given to a row itself: a frame changes on every
/// frame of a drag.
struct LayerListNode: Identifiable {
    var element: DesignElement
    var ref: DesignStore.ElementRef
    /// What is in it, topmost first: empty for anything but a group.
    var children: [LayerListNode]
    /// Hidden by its own flag or a group above it.
    var isHiddenWithItsGroups: Bool
    /// Locked by its own flag or a group above it.
    var isLockedWithItsGroups = false

    var id: DesignElement.ID { element.id }
}

extension DesignStore {
    /// What is on a screen, or on the open canvas, as the Layers panel shows it: the things at
    /// the top level, topmost first, each group's members under it, topmost first, and no
    /// drawings (see `drawings`). Built from `SiblingLists`, which holds the rule for which
    /// list a thing is in. Each node has its own flags for the toggles, and the effective
    /// ones, worked down from the top once, not looked up for each row.
    func layerTree(on host: ElementRef.Host) -> [LayerListNode] {
        let things = children(on: host)
        let lists = SiblingLists(things).lists
        let byID = Dictionary(things.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<DesignElement.ID> = []
        func nodes(in list: DesignElement.ID?, hidden: Bool, locked: Bool) -> [LayerListNode] {
            (lists[list] ?? []).reversed().compactMap { id in
                guard let element = byID[id], seen.insert(id).inserted else { return nil }
                let isHidden = hidden || element.isHidden
                let isLocked = locked || element.isLocked
                return LayerListNode(
                    element: element, ref: ElementRef(host: host, element: id),
                    children: element.kind == .group ? nodes(in: id, hidden: isHidden, locked: isLocked) : [],
                    isHiddenWithItsGroups: isHidden, isLockedWithItsGroups: isLocked
                )
            }
        }
        return nodes(in: nil, hidden: false, locked: false)
    }

    /// The drawings on the open canvas, topmost first: listed in a section of their own.
    var drawings: [ElementRef] {
        children(on: .canvas).filter { $0.kind == .drawing }.reversed().map { ElementRef(host: .canvas, element: $0.id) }
    }
}
