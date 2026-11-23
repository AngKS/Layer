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
/// hide of the groups above it. What shows the tree, the Layers panel and the canvas
/// targets, reads the list itself (`children(of:)`): group items included, with each
/// thing's own flags.
extension DesignContent {
    /// Whether any element is a group item or says it belongs to a group: a member left
    /// pointing at a group that has gone still needs `keepGroupsSound()`. One scan of the
    /// list, so that a design without groups costs no more than that.
    var hasGroups: Bool {
        elements.contains { $0.kind == .group || $0.group != nil }
    }

    /// The things that belong to a group directly, back to front.
    func members(of group: DesignElement.ID) -> [DesignElement] {
        elements.filter { $0.group == group }
    }

    /// The things in a group at any depth that aren't groups themselves, back to front.
    func leaves(of group: DesignElement.ID) -> [DesignElement] {
        #if DEBUG
        GroupWork.leafWalked()
        #endif
        return contents(of: group).filter { $0.kind != .group }
    }

    /// Everything in a group at any depth, the groups inside it included, back to front.
    func contents(of group: DesignElement.ID) -> [DesignElement] {
        let elements = elements
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

    // MARK: Selecting with groups

    /// The groups above an element on its host, the nearest first, looked up in the store's
    /// index rather than the list.
    private func groups(above element: DesignElement) -> [DesignElement] {
        Array(DesignContent.groups(above: element, find: self.element(_:)).prefix { $0.parent == element.parent })
    }

    /// The groups that hold something, at any depth, the nearest first.
    func groups(holding ref: ElementRef) -> [ElementRef] {
        guard let element = element(ref.element) else { return [] }
        return groups(above: element).map { ElementRef(host: ref.host, element: $0.id) }
    }

    /// What a tap on `leaf` picks while the groups in `entered` have been gone into (something
    /// in each is selected): the outermost of it and the groups above it that hasn't been,
    /// which is `leaf` itself once all of them have. A group item stands for a tap in the gap
    /// between its members.
    func pickTarget(for leaf: ElementRef, entered: Set<DesignElement.ID>) -> ElementRef {
        groups(holding: leaf).last { !entered.contains($0.element) } ?? leaf
    }

    /// One level in from `outer` towards `leaf`: the group just inside `outer` on the way to
    /// `leaf`, or `leaf` itself. `leaf` when `outer` is `leaf`, or doesn't hold it.
    func nextLevel(in outer: ElementRef, towards leaf: ElementRef) -> ElementRef {
        let path = [leaf] + groups(holding: leaf)
        guard let index = path.firstIndex(of: outer), index > 0 else { return leaf }
        return path[index - 1]
    }

    /// The topmost thing in a group, at any depth, that isn't a group itself and is shown,
    /// whose turned frame holds a point on the canvas: what a tap on the group's target there
    /// is on. Nil in a gap between its members.
    ///
    /// Only the group's own block is looked at. Kept sound, a group's members, and theirs,
    /// are one run just behind its item among the things on its host, drawings apart, so the
    /// block is read from the item back, front to back, to the first thing on the host that
    /// isn't in the group.
    func leaf(at point: CGPoint, in group: DesignElement.ID) -> ElementRef? {
        guard let item = groupItem(group), let end = indexInList(of: group) else { return nil }
        let host: ElementRef.Host = item.parent.map { .screen($0) } ?? .canvas
        let onScreen = item.parent.flatMap { screen($0)?.placement }
        let elements = projection.elements
        for element in elements[..<end].reversed() where element.parent == item.parent && element.kind != .drawing {
            let above = groups(above: element)
            guard above.contains(where: { $0.id == group }) else { break }
            guard element.kind != .group, !element.isHidden, !above.contains(where: \.isHidden),
                  let placement = onScreen ?? (element.parent == nil ? Placement(origin: .zero, scale: element.scale ?? 1) : nil),
                  TurnedRect(rect: placement.canvasRect(for: element.frame), degrees: element.resolvedRotation).contains(point)
            else { continue }
            return ElementRef(host: host, element: element.id)
        }
        return nil
    }

    /// What can be touched on a screen, or on the open canvas, back to front as it is drawn,
    /// while the groups in `entered` have been gone into:
    /// - each thing that isn't in a group, or is only in groups gone into;
    /// - each group that hasn't been gone into but whose groups above it have, in its block's
    ///   place, standing for its members, which have none of their own.
    ///
    /// What is hidden, by itself or with a group above it, has none. Nor has a drawing that
    /// isn't locked: its ink is picked, not its frame.
    ///
    /// On the open canvas a locked drawing comes after the other floating things, as the canvas
    /// draws it above them (C3, L10): hit order is draw order. This is the one place that
    /// order lives, and what is built from the targets, and hover, follow it.
    func targets(on host: ElementRef.Host, entered: Set<DesignElement.ID>) -> [ElementRef] {
        let showing = groupsWithSomethingShowing()
        var found = children(on: host).filter { isTarget($0, entered: entered, showing: showing) }
        if host == .canvas { found = Self.drawnOrder(found) }
        return found.map { ElementRef(host: host, element: $0.id) }
    }

    /// Floating things as the canvas draws them, back to front: a drawing, which can only be
    /// touched while it is locked, above everything else on the open canvas.
    private static func drawnOrder(_ things: [DesignElement]) -> [DesignElement] {
        guard things.contains(where: { $0.kind == .drawing }) else { return things }
        return things.filter { $0.kind != .drawing } + things.filter { $0.kind == .drawing }
    }

    /// `targets(on:entered:)` for every screen and the open canvas at once, as the elements
    /// themselves, each with its own lock and hide: one pass over the list, where a pass for
    /// each host went over all of it once a screen. Kept until the content changes, or other
    /// groups are gone into: hover asks on every move of the pen.
    func targetElements(entered: Set<DesignElement.ID>) -> [ElementRef.Host: [DesignElement]] {
        keptTargets(entered: entered) {
            #if DEBUG
            CanvasWork.targetPasses += 1
            #endif
            var found: [ElementRef.Host: [DesignElement]] = [:]
            let showing = groupsWithSomethingShowing()
            for element in projection.elements where isTarget(element, entered: entered, showing: showing) {
                found[element.parent.map { .screen($0) } ?? .canvas, default: []].append(element)
            }
            if let floating = found[.canvas] { found[.canvas] = Self.drawnOrder(floating) }
            return found
        }
    }

    /// The groups that have something showing in them, at any depth: a member that isn't a
    /// group, hidden neither by itself nor by a group above it. One pass over the list, the
    /// groups above each member that shows marked as it goes, where asking each group for its
    /// leaves went over the list for every group.
    private func groupsWithSomethingShowing() -> Set<DesignElement.ID> {
        // A design without groups costs one scan, and no dictionary.
        let elements = projection.elements
        guard elements.contains(where: { $0.kind == .group }) else { return [] }
        var byID: [DesignElement.ID: DesignElement] = [:]
        for element in elements where byID[element.id] == nil { byID[element.id] = element }
        var showing: Set<DesignElement.ID> = []
        for leaf in elements where leaf.kind != .group && leaf.group != nil && !leaf.isHidden {
            guard !DesignContent.groups(above: leaf, find: { byID[$0] }).contains(where: \.isHidden) else { continue }
            // Up the chain of groups it says it is in; what is above one already marked is too.
            var seen: Set<DesignElement.ID> = [leaf.id]
            var next = leaf.group
            while let id = next, seen.insert(id).inserted, showing.insert(id).inserted {
                next = byID[id]?.group
            }
        }
        return showing
    }

    private func isTarget(_ element: DesignElement, entered: Set<DesignElement.ID>, showing: Set<DesignElement.ID>) -> Bool {
        guard !element.isHidden, element.isPickedByItsFrame else { return false }
        // A group with nothing showing in it has nothing to touch.
        if element.kind == .group, !showing.contains(element.id) { return false }
        if element.group != nil {
            guard groups(above: element).allSatisfy({ entered.contains($0.id) && !$0.isHidden }) else { return false }
        }
        // A group gone into is stood for by what is in it.
        return element.kind != .group || !entered.contains(element.id)
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
    }

    /// A group as it is now: see `GroupPose`. Nil when `ref` isn't a group.
    func groupPose(of ref: ElementRef) -> GroupPose? {
        guard let item = resolve(ref)?.element, item.kind == .group else { return nil }
        var pose = GroupPose(box: item.frame, leaves: [:], keepingHeight: [], smallestScale: 0)
        for element in content.contents(of: item.id) where element.kind != .group {
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
    /// box is then fitted round them again (`keepGroupsSound()`). Made smaller than something in
    /// it can be, it is scaled only as far as that can go, about the same point. Nothing happens
    /// to a group that is locked, by itself or by a group above it.
    func resizeGroup(_ ref: ElementRef, to frame: CGRect, from start: GroupPose? = nil) {
        guard let (item, placement) = resolve(ref), item.kind == .group, !isLocked(.element(ref)),
              let pose = start ?? groupPose(of: ref), pose.box.width > 0, pose.box.height > 0, frame.width > 0, frame.height > 0
        else { return }
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
        if frame == pose.box {
            // Back where it began: exactly as it was, with no arithmetic to round.
            frames = pose.leaves
        } else {
            let degrees = item.resolvedRotation
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
            for (id, start) in pose.leaves {
                guard let leaf = element(id), let own = self.placement(of: leaf) else { continue }
                let centre = moved(CGPoint(x: start.midX, y: start.midY), in: own)
                let size = CGSize(width: start.width * scale, height: pose.keepingHeight.contains(id) ? start.height : start.height * scale)
                frames[id] = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
            }
        }
        apply { content in
            for (id, frame) in frames { content.update(id) { $0.frame = frame } }
        }
    }

    /// Gives a group to whatever the middle of its box now lies on, as after a drag: the
    /// screen there, or the open canvas when there is none. Everything in it, at any depth,
    /// goes there in one change, back to front, so that it lands whole and stacked as it was,
    /// on top of what is there; built over several, the groups would be put right in between
    /// and come apart. It lands as one element does, keeping its middle where it is on the
    /// canvas and its size in points: each thing in it keeps its size in its own points, and
    /// its distance from the box's middle in them, so that on a screen drawn at another scale
    /// the group arrives whole, scaled about its middle, rather than with its members spaced
    /// as they were on the canvas, overlapping or apart. A group holding something that
    /// doesn't go on screens, a sticky note, stays where it is instead of landing on a screen.
    /// Returns where the group now lives.
    @discardableResult
    func rehostGroup(_ ref: ElementRef) -> ElementRef {
        guard let (item, placement) = resolve(ref), item.kind == .group else { return ref }
        // Worked out as a turn under way works it out (`TurnSession.rehosted`), to the last bit.
        let middle = placement.canvasPoint(for: CGPoint(x: item.frame.midX, y: item.frame.midY))
        let target = screen(at: middle)
        let host: ElementRef.Host = target.map { .screen($0.id) } ?? .canvas
        guard host != ref.host else { return ref }
        let inside = content.contents(of: item.id)
        if target != nil, inside.contains(where: { $0.kind != .group && !$0.kind.belongsOnScreens }) { return ref }
        let moving = Set(inside.map(\.id) + [item.id])
        var moves: [(id: DesignElement.ID, scale: CGFloat, frame: CGRect)] = []
        for element in projection.elements where moving.contains(element.id) {
            guard let own = self.placement(of: element) else { return ref }
            // Off a screen it keeps the scale it was drawn at, so it doesn't change size.
            let landing = target?.placement ?? Placement(origin: .zero, scale: own.scale)
            let onCanvas = own.canvasPoint(for: CGPoint(x: element.frame.midX, y: element.frame.midY))
            let centre = landing.localPoint(for: Self.landedMiddle(of: onCanvas, about: middle, from: own, to: landing))
            var origin = CGPoint(x: centre.x - element.frame.width / 2, y: centre.y - element.frame.height / 2)
            // A group's box is fitted round its members once they have landed.
            if element.kind != .group, element.kind != .drawing { origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded()) }
            moves.append((element.id, landing.scale, CGRect(origin: origin, size: element.frame.size)))
        }
        apply { content in
            for move in moves { content.move(move.id, to: target?.id, scale: move.scale, frame: move.frame) }
        }
        let landed = ElementRef(host: host, element: item.id)
        return resolve(landed) != nil ? landed : ref
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
        groupable(selection) != nil
    }

    /// Puts what is selected in a new group, as one step, and returns the group. Locked
    /// things and drawings are left out of it; the rest are to be two or more, on one screen
    /// or all on the open canvas, and in one group (or none) without being all of that group,
    /// with no screen among what is selected. Nil, and nothing changes, when they aren't.
    ///
    /// The group is made in the group its members are in, and is built whole in one change:
    /// an item added on its own, with no members, would be taken away at the end of that
    /// change (see `DesignContent.keepGroupsSound()`), which also gathers the members, from
    /// wherever they were, just behind the item, where the frontmost of them was, and fits
    /// the item's box round them. On the open canvas the item is drawn at its frontmost
    /// member's scale; members drawn at others are boxed in canvas points (L5). It is named
    /// as its kind until it is renamed.
    @discardableResult
    func group(_ selection: CanvasSelection) -> ElementRef? {
        guard let members = groupable(selection), let front = members.last else { return nil }
        var item = Self.newElement(.group)
        item.group = front.element.group
        let made = item
        apply { content in
            content.add(made, to: front.element.parent, scale: front.element.scale)
            for member in members { content.update(member.element.id) { $0.group = made.id } }
        }
        let ref = ElementRef(host: front.ref.host, element: made.id)
        return resolve(ref) != nil ? ref : nil
    }

    /// The things Group puts in a group, back to front, or nil when it can't: see `group(_:)`.
    private func groupable(_ selection: CanvasSelection) -> [(ref: ElementRef, element: DesignElement)]? {
        var members: [(ref: ElementRef, element: DesignElement)] = []
        for thing in things(in: selection) {
            guard case .element(let ref) = thing else { return nil }
            guard let element = resolve(ref)?.element, element.kind != .drawing, !isLocked(thing) else { continue }
            members.append((ref, element))
        }
        guard members.count > 1, let first = members.first,
              members.allSatisfy({ $0.ref.host == first.ref.host && $0.element.group == first.element.group })
        else { return nil }
        // Every member of the group they are in would make that group again under a new id:
        // left with one member, the old group would dissolve into the new, and its name and
        // angle with it. A locked member, left out, keeps the rest from being all of it.
        if let shared = first.element.group, content.members(of: shared).count == members.count { return nil }
        return members
    }

    /// Takes a group apart, as one step, and returns its members as a selection. They go to
    /// the group the group was in (or to none), where they are in the order, and take on its
    /// lock and hide, so that a hidden group's members don't reappear. Not its members'
    /// groups: those stay whole. Nil, and nothing changes, when `ref` isn't a group.
    @discardableResult
    func ungroup(_ ref: ElementRef) -> CanvasSelection? {
        guard let item = resolve(ref)?.element, item.kind == .group else { return nil }
        let members = content.members(of: item.id)
        apply { content in
            for member in members {
                content.update(member.id) {
                    $0.group = item.group
                    $0.isLocked = $0.isLocked || item.isLocked
                    $0.isHidden = $0.isHidden || item.isHidden
                }
            }
            content.remove([item.id])
        }
        return CanvasSelection(members.map { .element(ElementRef(host: ref.host, element: $0.id)) })
    }

    /// Unlocks what is selected and, so that it is unlocked, every locked group above it, as
    /// one step. A thing locked only by its group would otherwise stay locked (conflict D).
    func unlock(_ selection: CanvasSelection) {
        let present = things(in: selection)
        var groups: [DesignElement.ID] = []
        for case .element(let ref) in present {
            guard let element = resolve(ref)?.element else { continue }
            groups += DesignContent.groups(above: element, find: self.element(_:)).filter(\.isLocked).map(\.id)
        }
        apply { content in
            for thing in present {
                switch thing {
                case .element(let ref):
                    content.update(ref.element) { $0.isLocked = false }
                case .screen(let id):
                    content.updateScreen(id) { $0.isLocked = nil }
                case .several:
                    continue
                }
            }
            for id in groups { content.update(id) { $0.isLocked = false } }
        }
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

#if DEBUG
/// How much of the design the groups' own questions walk: for the tests that hold working out
/// what can be touched to a pass over the list. Counted on the main thread alone, where the
/// store works it out. The count only grows: a test measures the difference it makes.
enum GroupWork {
    nonisolated(unsafe) private(set) static var leafWalks = 0

    static func leafWalked() {
        guard Thread.isMainThread else { return }
        leafWalks += 1
    }
}
#endif
