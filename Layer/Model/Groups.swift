import CoreGraphics
import Foundation

/// Groups: several things on one screen, or on the open canvas, kept together as one.
///
/// A group is an element of the kind `.group` in the design's one list, on the host its
/// members are on. Each member says which group it belongs to with its `group`, and groups
/// nest by a group item belonging to another. The item carries the group's name, lock,
/// hide and angle; its frame is the box round its members.
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
        return elements.filter { found.contains($0.id) && $0.kind != .group }
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

    /// Puts right whatever a change has left unsound about the design's groups, writing only
    /// what differs. It runs at the end of every change to the design, after undo and redo,
    /// and when a design is read, so anything that builds or moves a group does all of it in
    /// one change: split over several, this would run in between and undo the half-built
    /// group. In turn:
    ///
    /// 1. A member is ungrouped when its group isn't there, isn't a group item, is on another
    ///    host, or has it inside itself; and a drawing is never in a group.
    /// 2. A group with no members goes.
    /// 3. A group of one dissolves: its member takes its place in the group above, and its
    ///    lock and hide, so that a hidden group's member doesn't reappear.
    /// 4. Each group's members are gathered into one run, in their order, ending where the
    ///    frontmost of them was, with the group item just in front. Nothing else moves, and
    ///    each drawing keeps its slot, as when things are arranged.
    /// 5. Each group's box is fitted round its members' shapes, at the group's own angle,
    ///    innermost groups first.
    mutating func keepGroupsSound() {
        ungroupStrays()
        dissolveHollowGroups()
        gatherMembers()
        fitGroupBoxes()
    }

    /// Rule 1. Only group items are looked up: a member whose group isn't one of them, there
    /// or not, is a stray either way.
    private mutating func ungroupStrays() {
        var groups = groupItemsByID
        for element in elements where element.group != nil {
            // A group item ungrouped earlier in this pass is taken as it now is.
            let member = element.kind == .group ? groups[element.id] ?? element : element
            guard let groupID = member.group, Self.isStray(member, in: groupID, groups: groups) else { continue }
            update(member.id) { $0.group = nil }
            if member.kind == .group { groups[member.id]?.group = nil }
        }
    }

    private static func isStray(_ member: DesignElement, in groupID: DesignElement.ID, groups: [DesignElement.ID: DesignElement]) -> Bool {
        guard member.kind != .drawing, let group = groups[groupID], group.parent == member.parent else { return true }
        // Inside itself: its chain of groups comes back to it. A loop above it that doesn't
        // pass through it is broken when the groups in it are seen to.
        var seen: Set<DesignElement.ID> = []
        var next: DesignElement.ID? = groupID
        while let id = next {
            if id == member.id { return true }
            guard seen.insert(id).inserted else { return false }
            next = groups[id]?.group
        }
        return false
    }

    /// Rules 2 and 3, one group at a time: one going can leave the group above it hollow.
    private mutating func dissolveHollowGroups() {
        while true {
            var counts: [DesignElement.ID: Int] = [:]
            var lastMember: [DesignElement.ID: DesignElement.ID] = [:]
            for element in elements {
                guard let group = element.group else { continue }
                counts[group, default: 0] += 1
                lastMember[group] = element.id
            }
            guard let hollow = elements.first(where: { $0.kind == .group && counts[$0.id, default: 0] < 2 }) else { return }
            if counts[hollow.id] == 1, let member = lastMember[hollow.id] {
                update(member) {
                    $0.group = hollow.group
                    $0.isLocked = $0.isLocked || hollow.isLocked
                    $0.isHidden = $0.isHidden || hollow.isHidden
                }
            }
            remove([hollow.id])
        }
    }

    /// Rule 4, host by host: written through `reorder` with the host's whole order, and only
    /// where it changes.
    private mutating func gatherMembers() {
        var hosts: [DesignScreen.ID?] = []
        for element in elements where element.kind == .group && !hosts.contains(element.parent) {
            hosts.append(element.parent)
        }
        for parent in hosts {
            let things = children(of: parent).filter { $0.kind != .drawing }
            let order = Self.gathered(things)
            guard order != things.map(\.id) else { continue }
            reorder(parent, to: rawOrder(on: parent, withDrawingsKept: order))
        }
    }

    /// Things that share a host, back to front, drawings left out, with each group's members
    /// gathered into one run, in their order, and the group item just in front of them. A
    /// run takes the place of the frontmost thing in it; everything else keeps its order.
    private static func gathered(_ things: [DesignElement]) -> [DesignElement.ID] {
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

    /// Rule 5. Each box is worked out in canvas terms and kept in the item's own points: its
    /// screen's, or on the open canvas its own scale's. Members on the open canvas can each
    /// have a scale of their own (L5), so a member drawn at another scale than the item is
    /// carried into the item's points through canvas points. One drawn at the same scale,
    /// as everything on a screen is, is taken as it is: the box round shapes moved and scaled
    /// alike is the same box moved and scaled, and the round trip through canvas points
    /// picked up rounding that changed whenever a screen moved, rewriting its groups. The
    /// group's angle is kept.
    private mutating func fitGroupBoxes() {
        var screenPlacements: [DesignScreen.ID: Placement] = [:]
        for screen in screenFrames where screenPlacements[screen.id] == nil { screenPlacements[screen.id] = screen.placement }
        func placement(of element: DesignElement) -> Placement? {
            guard let parent = element.parent else { return Placement(origin: .zero, scale: element.scale ?? 1) }
            return screenPlacements[parent]
        }
        var inside: [DesignElement.ID: [DesignElement]] = [:]
        var items: [DesignElement] = []
        for element in elements {
            if element.kind == .group { items.append(element) }
            if let group = element.group { inside[group, default: []].append(element) }
        }
        // Each group's box in its own points, innermost first.
        var boxes: [DesignElement.ID: TurnedRect] = [:]
        var visiting: Set<DesignElement.ID> = []
        func box(of group: DesignElement) -> TurnedRect? {
            if let known = boxes[group.id] { return known }
            guard visiting.insert(group.id).inserted, let own = placement(of: group), own.scale > 0 else { return nil }
            let shapes = (inside[group.id] ?? []).compactMap { member -> TurnedRect? in
                guard let theirs = placement(of: member) else { return nil }
                let shape: TurnedRect? = member.kind == .group ? box(of: member) : TurnedRect(rect: member.frame, degrees: member.resolvedRotation)
                guard let shape else { return nil }
                return theirs == own ? shape : TurnedRect(rect: own.localRect(for: theirs.canvasRect(for: shape.rect)), degrees: shape.degrees)
            }
            let found = TurnedRect.enclosing(shapes, at: group.resolvedRotation)
            boxes[group.id] = found
            return found
        }
        for item in items {
            guard let frame = box(of: item)?.rect, frame != item.frame else { continue }
            update(item.id) { $0.frame = frame }
        }
    }
}

extension DesignStore {
    /// What is on a screen, or on the open canvas, back to front, as the design's own list
    /// holds it: group items included, and each thing with its own lock and hide.
    func children(on host: ElementRef.Host) -> [DesignElement] {
        content.children(of: host.parent)
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
        element.isLocked || DesignContent.groups(above: element, find: self.element(_:)).contains(where: \.isLocked)
    }

    // MARK: Group and Ungroup

    /// Whether Group would make a group of what is selected: see `group(_:)`.
    func canGroup(_ selection: CanvasSelection) -> Bool {
        groupable(selection) != nil
    }

    /// Puts what is selected in a new group, as one step, and returns the group. Locked
    /// things and drawings are left out of it; the rest are to be two or more, on one screen
    /// or all on the open canvas, and in one group (or none), with no screen among what is
    /// selected. Nil, and nothing changes, when they aren't.
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
