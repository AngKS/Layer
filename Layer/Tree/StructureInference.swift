import CoreGraphics
import CryptoKit
import Foundation
import os

/// The structure pass (spec §5): the grids, rows and columns among what a batch drew and its neighbours, and a new
/// card's column, each with how sure it is, the spacing it takes, and how far it moves anything. Pure and
/// deterministic, with no UIKit and no SwiftUI, so it builds on macOS and runs off the main actor. Its numbers are
/// `StructureConventions`', and the spacing comes from the design's own rhythm (§14).
///
/// A new card's inside is a column or nothing. Elsewhere grids come first, then rows, then columns, in which a row or
/// grid just applied is one item: one level of nesting per pass, inner first (call 3). A structure the pass made that
/// may grow is read as its members by a structure that may take its place, which then holds all of them (call 2).
/// Each proposal is laid out by the engine with its members `.fixed` at their sizes (My call 16), and its movement is
/// measured on exactly what the engine gives (call 5).
enum StructureInference {
    enum Mode: Sendable {
        /// After a batch of readings: the 0.8 bar and nothing moved more than 8 pt, or an offer.
        case sketch
        /// Voice's tidy (call 10): every arrangeable child new, the 0.5 bar, no limit, and a column's gaps needn't be
        /// regular.
        case tidy
    }

    struct Structure: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case row, column, grid(columns: Int), cardColumn }
        var kind: Kind
        /// The receiving container, a screen's root included; for `.cardColumn`, the card.
        var parent: UUID
        /// In reading order (My call 15). A row or grid proposed just before, by its container's id, may be one.
        var members: [UUID]
        /// Containers the pass made that this one takes the place of (call 2). `applying` opens them first.
        var replacing: [UUID] = []
        /// What would be built: its layout and padding, its frame in the parent's space, and both sizings `.fit`,
        /// with the members inside at their laid-out frames, each `.fixed` (My call 16) but for a row or column the
        /// pass built, which keeps fitting along its own axis. It carries an intent decided by `.structure`, so that a
        /// structure proposed after it may take it (a container without one is the person's); the store writes its
        /// real one when it builds it. For `.cardColumn` it is the card itself, with its new layout and padding.
        var container: LayerNode
        var confidence: Double
        /// The furthest any member, or anything in one, moves, as proposed. Members are upright and keep their sizes, so
        /// every corner moves as the origin does; what a row proposed just before holds counts from where it is now, and
        /// what a build earlier in the step moved (`infer`'s `started`) from where it lay when the step began.
        var movement: CGFloat

        var title: String {
            switch kind {
            case .row: "Make a row?"
            case .column, .cardColumn: "Make a column?"
            case .grid: "Make a grid?"
            }
        }
    }

    enum Decision: Equatable, Sendable { case apply(Structure), offer(Structure) }
    enum Outcome: Equatable, Sendable { case applyRhythm, applyMedian, offer }

    /// Pure and deterministic. `parent` as it is now; `new` the batch's nodes in it (a new card's: all it holds);
    /// `grows` the containers the pass made that may grow (call 2); `depth` how deep `parent` sits, as `TreeIndex`
    /// counts it (a screen's root is 0), so that nothing is built past depth 32 (F9). `started` is where nodes inside
    /// `parent`'s children that a build earlier in the step may have moved lay when the step began, each one's own
    /// origin in `parent`'s space: the 8 pt limit is on the furthest anything moves in the step, a card's column and the
    /// row the card then goes into together (plan 5's final review, A1). Tidying, every arrangeable child counts as new,
    /// whatever `new` says. In the order to apply: inner structures first.
    static func infer(in parent: LayerNode, new: Set<UUID>, grows: Set<UUID> = [], tokens: DesignTokens,
                      mode: Mode = .sketch, measure: TextMeasure = .shared, depth: Int = 0,
                      started: [UUID: CGPoint] = [:]) -> [Decision] {
        guard parent.isContainer, parent.resolvedLayout == .free else { return [] }
        let new = mode == .tidy ? Set(parent.children.filter(\.isArrangeable).map(\.id)) : new
        let near = neighbourhood(of: parent, new: new)
        #if DEBUG
        record(near.count, for: parent.id)
        #endif
        guard !near.isEmpty else { return [] }
        return Pass(parent: parent, new: new, grows: grows, tokens: tokens, mode: mode, measure: measure, depth: depth,
                    started: started)
            .decisions(near)
    }

    /// My call 16: the rhythm's spacing, else the exact median, else an offer. Nil: nothing.
    static func decide(confidence: Double, rhythmMove: CGFloat, medianMove: CGFloat, mode: Mode) -> Outcome? {
        typealias C = StructureConventions
        switch mode {
        case .tidy:
            return confidence >= C.tidyAutomatic ? .applyRhythm : nil
        case .sketch:
            if confidence >= C.automatic, rhythmMove <= C.furthestAutomaticMove { return .applyRhythm }
            if confidence >= C.automatic, medianMove <= C.furthestAutomaticMove { return .applyMedian }
            return confidence >= C.offered ? .offer : nil
        }
    }

    /// `parent` with `structure` built in it. The containers it replaces are opened first, their members where they
    /// are on screen. Then its members, as they are now, each `.fixed` at its size and at the proposed frame, go
    /// inside the proposed container (its id kept), at the frontmost member's slot where that hides nothing seen
    /// (`slot`). With `carryingRiders` (voice's tidy), what lies on a member goes where it goes (`riders`). For
    /// `.cardColumn`, `parent` is the card, which takes the proposed layout and padding and holds its children in the
    /// proposed order and frames. Nil when a member is gone, no longer `parent`'s child, or not arrangeable, when a
    /// container it replaces isn't there or holds something the structure doesn't take, or when the container is
    /// already there.
    static func applying(_ structure: Structure, to parent: LayerNode, carryingRiders: Bool = false) -> LayerNode? {
        if structure.kind == .cardColumn { return applyingInside(structure, card: parent) }
        var parent = parent
        let members = structure.members
        let taken = Set(members)
        for id in structure.replacing {
            guard let place = parent.children.firstIndex(where: { $0.id == id }), open(place, in: &parent, takenBy: taken)
            else { return nil }
        }
        guard !members.isEmpty, taken.count == members.count,
              !parent.children.contains(where: { $0.id == structure.container.id }) else { return nil }
        var places: [Int] = []
        for id in members {
            guard let place = parent.children.firstIndex(where: { $0.id == id }), parent.children[place].isArrangeable
            else { return nil }
            places.append(place)
        }
        let proposed = origins(in: structure.container)
        var container = structure.container
        container.children = zip(members, places).map { id, place in
            var member = fixedInPlace(parent.children[place])
            member.frame.origin = proposed[id] ?? member.frame.origin
            return member
        }
        // Where each member goes in the parent's space: the container is upright.
        let corner = container.frame.origin
        let laid = Dictionary(zip(places, container.children.map { $0.frame.offsetBy(dx: corner.x, dy: corner.y) }),
                              uniquingKeysWith: { first, _ in first })
        var children = parent.children
        if carryingRiders {
            for (rider, member) in riders(of: places, in: children) {
                let from = children[member].frame.origin, to = laid[member]?.origin ?? from
                children[rider].frame = children[rider].frame.offsetBy(dx: to.x - from.x, dy: to.y - from.y)
            }
        }
        let goesAt = slot(for: places, laidAt: laid, among: parent.children, now: children)
        // A child this build couldn't read keeps its place among those that stay.
        let front = places.max() ?? 0
        let isMember = Set(places)
        let staying = children.indices.filter { !isMember.contains($0) }
        var result = parent
        if goesAt == staying.count(where: { $0 < front }) {
            // The container takes the frontmost member's place, and the others go.
            let others = places.filter { $0 != front }
            TreeRules.keepUnreadPlaces(in: &result, removing: others)
            children[front] = container
            for place in others.sorted(by: >) { children.remove(at: place) }
            result.children = children
        } else {
            TreeRules.keepUnreadPlaces(in: &result, removing: places)
            makeRoomForUnread(in: &result, beforeRead: goesAt)
            result.children = staying.map { children[$0] }
            result.children.insert(container, at: goesAt)
        }
        return result
    }

    /// Where a container holding the children at `members` goes among those that stay (0: behind them all; their count:
    /// in front), as a sketched card goes (plan 5's Task 5, round 5; final review A2): at the frontmost member's slot,
    /// moved as little as needed among the slots where nothing seen is wholly hidden by one thing. It goes in front of
    /// what would hide whole a member that was seen, and behind what a member would hide whole that was seen. Where no
    /// slot does that, the frontmost member's stands. `before` is the children as they were, `now` as they are once
    /// riders have moved, and `laid` where each member goes. Each counts as the box round its turned shape; a hidden
    /// one counts for nothing. The container draws nothing of its own.
    private static func slot(for members: [Int], laidAt laid: [Int: CGRect], among before: [LayerNode],
                             now: [LayerNode]) -> Int {
        let was = before.map(shapeBox)
        let shape = now.indices.map { laid[$0] ?? shapeBox(now[$0]) }
        let front = members.max() ?? 0
        let isMember = Set(members)
        let staying = before.indices.filter { !isMember.contains($0) }
        // Only what meets the members can cover one or be covered by one: the rest are passed over at once.
        let span = members.reduce(CGRect.null) { $0.union(shape[$1]) }
        func isDrawn(_ at: Int) -> Bool { !before[at].isHidden }
        /// Seen before it was built: drawn, and not wholly under one drawn thing in front of it.
        var wasSeen = TreeEdit.Seen(shapes: was, drawn: before.map { !$0.isHidden })
        let ruled = staying.count { $0 < front }
        let lowest = 1 + (staying.lastIndex { at in
            isDrawn(at) && meets(shape[at], span) && members.contains { shape[at].contains(shape[$0]) && wasSeen($0) }
        } ?? -1)
        let highest = staying.firstIndex { at in
            meets(shape[at], span) && members.contains { member in isDrawn(member) && shape[member].contains(shape[at]) }
                && wasSeen(at)
        } ?? staying.count
        return TreeEdit.slot(ruled, movedInto: lowest, highest)
    }

    /// What rides on a member (plan 5's final review, A5): each child that stays, the pass may move, and lies at least
    /// `StructureConventions.enclosedShare` of its area on a member's shape, with the smallest such member, by place.
    private static func riders(of members: [Int], in children: [LayerNode]) -> [(rider: Int, member: Int)] {
        func area(_ box: CGRect) -> CGFloat { box.isNull ? 0 : box.width * box.height }
        let shapes = children.map(shapeBox)
        let isMember = Set(members)
        let span = members.reduce(CGRect.null) { $0.union(shapes[$1]) }
        return children.indices.compactMap { at -> (rider: Int, member: Int)? in
            guard !isMember.contains(at), meets(shapes[at], span), children[at].isArrangeable else { return nil }
            let own = area(shapes[at])
            guard own > 0 else { return nil }
            let hosts = members.filter {
                !children[$0].isHidden && area(shapes[$0].intersection(shapes[at])) >= own * StructureConventions.enclosedShare
            }
            return hosts.min { area(shapes[$0]) < area(shapes[$1]) }.map { (rider: at, member: $0) }
        }
    }

    /// Each child this build couldn't read at or after the place of the read one at `slot` moves on by one, for a node put
    /// in just before that one (after them all, at their count).
    private static func makeRoomForUnread(in node: inout LayerNode, beforeRead slot: Int) {
        guard !node.unreadChildren.isEmpty else { return }
        let unread = Set(node.unreadChildren.map(\.index))
        var at = 0, read = 0
        while unread.contains(at) || read < slot {
            if !unread.contains(at) { read += 1 }
            at += 1
        }
        for index in node.unreadChildren.indices where node.unreadChildren[index].index >= at {
            node.unreadChildren[index].index += 1
        }
    }

    /// The card with its column built: nil unless it holds exactly the members, every one arrangeable, and is free.
    private static func applyingInside(_ structure: Structure, card: LayerNode) -> LayerNode? {
        let members = structure.members
        guard card.id == structure.container.id, card.isContainer, card.resolvedLayout == .free,
              card.children.count == members.count, Set(card.children.map(\.id)) == Set(members),
              card.children.allSatisfy(\.isArrangeable) else { return nil }
        let proposed = origins(in: structure.container)
        let held = Dictionary(card.children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = card
        result.layout = structure.container.layout
        result.padding = structure.container.padding
        result.children = members.compactMap { held[$0] }.map { child in
            var member = fixedInPlace(child)
            member.frame.origin = proposed[child.id] ?? member.frame.origin
            return member
        }
        return result
    }

    /// Opens the container the pass made at `place`, for a structure that takes `taken`: its members take its slot where
    /// they are on screen, and a child this build couldn't read keeps its place among the rest. False when it isn't one
    /// the pass made, holds something this build couldn't read, or holds something the structure doesn't take, which
    /// would go loose (Task 6 m1): a thing put in it since it was offered.
    private static func open(_ place: Int, in parent: inout LayerNode, takenBy taken: Set<UUID>) -> Bool {
        let container = parent.children[place]
        guard container.kind == .group, container.sketch?.decidedBy == .structure, container.unreadChildren.isEmpty,
              container.children.allSatisfy({ taken.contains($0.id) })
        else { return false }
        let members = container.children.map { TreeRules.released($0, from: container) }
        if !parent.unreadChildren.isEmpty {
            // Its place among all the children, read and unread: those after it move on by what it held, less itself.
            let unread = Set(parent.unreadChildren.map(\.index))
            var at = 0, read = 0
            while unread.contains(at) || read < place {
                if !unread.contains(at) { read += 1 }
                at += 1
            }
            for index in parent.unreadChildren.indices where parent.unreadChildren[index].index > at {
                parent.unreadChildren[index].index += members.count - 1
            }
        }
        parent.children.replaceSubrange(place...place, with: members)
        return true
    }

    /// A member as a structure holds it: fixed at its size (My call 16), except that a row or column the pass built
    /// keeps fitting along its own axis, so that it still grows with what it holds.
    private static func fixedInPlace(_ node: LayerNode) -> LayerNode {
        var node = node
        let axis: LayerNode.Axis? = if node.kind == .group, node.sketch?.decidedBy == .structure,
                                       case .stack(let stack) = node.resolvedLayout { stack.axis } else { nil }
        if axis != .horizontal || node.width.mode != .fit { node.width.mode = .fixed }
        if axis != .vertical || node.height.mode != .fit { node.height.mode = .fixed }
        return node
    }

    /// Where each child of `container` is proposed to be, in its space.
    private static func origins(in container: LayerNode) -> [UUID: CGPoint] {
        Dictionary(container.children.map { ($0.id, $0.frame.origin) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - The neighbourhood

    /// The new nodes the pass may take, then every arrangeable child whose frame, grown by `reach`, meets one already
    /// in it, until nothing joins: in the parent's order, as places among its children. One that holds the one it joined
    /// by lies under it, as a background does, and brings in nothing more: what it lies under isn't near (plan 5's
    /// final review, follow-up to A5).
    private static func neighbourhood(of parent: LayerNode, new: Set<UUID>) -> [Int] {
        let reach = StructureConventions.reach
        let arrangeable = parent.children.indices.filter { parent.children[$0].isArrangeable }
        var inside = arrangeable.filter { new.contains(parent.children[$0].id) }
        var outside = arrangeable.filter { !new.contains(parent.children[$0].id) }
        var under: Set<Int> = []
        var next = 0
        while next < inside.count, !outside.isEmpty {
            defer { next += 1 }
            guard !under.contains(inside[next]) else { continue }
            let frame = parent.children[inside[next]].frame
            let joining = outside.filter { meets(parent.children[$0].frame.insetBy(dx: -reach, dy: -reach), frame) }
            inside += joining
            outside.removeAll { joining.contains($0) }
            under.formUnion(joining.filter { parent.children[$0].frame.contains(frame) })
        }
        return inside.sorted()
    }

    /// Whether two boxes touch or overlap.
    private static func meets(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }

    /// The box round a node's turned shape, as `TreeEdit.shapesBox(of:)` gives it for one.
    private static func shapeBox(_ node: LayerNode) -> CGRect {
        let degrees = node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return Rotation.normalized(degrees) == 0 ? node.frame : TurnedRect(rect: node.frame, degrees: degrees).bounds
    }

    // MARK: - One pass

    /// Something a structure may take: a child of the parent as it is now, a member of a container that may grow
    /// read where it is on screen, or a row or grid proposed just before, as one.
    private struct Item {
        var node: LayerNode
        /// New, or a row or grid holding a new one.
        var isNew: Bool
        /// Its place among the parent's children; a member read from its container takes the container's, and a
        /// structure proposed just before its frontmost member's.
        var place: Int
        /// The container that may grow it was read from.
        var grower: UUID?
        var frame: CGRect { node.frame }
    }

    /// Something that may lie between members: a visible child's turned shape, or a structure proposed just before. One
    /// that holds what it would lie between, both neighbours or a grid's whole box, lies under them instead, as a
    /// full-screen background does, locked or not (plan 5's final review, follow-up to A5): `Obstacles.meet` passes it by.
    private struct Obstacle {
        var id: UUID
        var shape: CGRect

        init(id: UUID, shape: CGRect) {
            self.id = id
            self.shape = shape
        }

        init(_ node: LayerNode) {
            self.init(id: node.id, shape: TreeEdit.shapesBox(of: [node]) ?? node.frame)
        }
    }

    /// The obstacles, sorted by where they lie (`ShapeBuckets`) when there are many, so that asking what lies in a box
    /// looks only near it. A batch's handful is looked through whole, which is quicker.
    private struct Obstacles {
        let all: [Obstacle]
        private let buckets: ShapeBuckets?

        init(_ all: [Obstacle]) {
            self.all = all
            buckets = all.count < fewestSorted ? nil : ShapeBuckets(all.map { $0.shape })
        }

        /// Whether one that `ignoring` doesn't name shares some area with `box`, the space between what `under` holds,
        /// and doesn't lie under all of `under`.
        func meet(_ box: CGRect, under: [CGRect], ignoring: (UUID) -> Bool) -> Bool {
            func isIn(_ obstacle: Obstacle) -> Bool {
                overlaps(obstacle.shape, box) && !ignoring(obstacle.id) && !under.allSatisfy(obstacle.shape.contains)
            }
            guard let buckets else { return all.contains(where: isIn) }
            return buckets.contains(near: box) { isIn(all[$0]) }
        }
    }

    /// A run that qualifies: its items in reading order, the line they share, and its gaps.
    private struct Candidate {
        var items: [Int]
        var line: Line
        var gaps: [CGFloat]
        var confidence: Double
        var replacing: [UUID]
    }

    /// What the search reads of each item again and again, read once: copying an item copies its whole node, which
    /// unoptimised was most of a large tidy's time.
    private struct Fact {
        let frame: CGRect
        let place: Int
        let id: UUID
        let isNew: Bool
        let grower: UUID?

        init(_ item: Item) {
            (frame, place, id, isNew, grower) = (item.node.frame, item.place, item.node.id, item.isNew, item.grower)
        }
    }

    private typealias Facts = [Fact]

    /// A grid that qualifies: its items row by row, its first column's leading edge and first row's top (medians),
    /// and the gaps between its columns and between its rows.
    private struct GridCandidate {
        var items: [Int]
        var columns: Int
        var leading: CGFloat
        var top: CGFloat
        var columnGaps: [CGFloat]
        var rowGaps: [CGFloat]
        var confidence: Double
        var replacing: [UUID]
    }

    /// A container the pass made that may grow: what it is, and what it holds.
    private struct Growing {
        var kind: Structure.Kind
        var members: [UUID]
    }

    private struct Pass {
        let parent: LayerNode
        let new: Set<UUID>
        let tokens: DesignTokens
        let mode: Mode
        let measure: TextMeasure
        let depth: Int
        /// Where what a build earlier in the step may have moved lay when the step began: see `infer`.
        let started: [UUID: CGPoint]
        /// The children in `grows` that are still a row, column or grid the pass made, holding only what it may take.
        let growing: [UUID: Growing]
        /// Where each of the parent's children, and each member of a container that may grow, is now on screen.
        let origins: [UUID: CGPoint]
        /// Their places among the parent's children: a member's is its container's.
        let places: [UUID: Int]

        init(parent: LayerNode, new: Set<UUID>, grows: Set<UUID>, tokens: DesignTokens, mode: Mode,
             measure: TextMeasure, depth: Int, started: [UUID: CGPoint]) {
            self.parent = parent
            self.new = new
            self.tokens = tokens
            self.mode = mode
            self.measure = measure
            self.depth = depth
            self.started = started
            var growing: [UUID: Growing] = [:], origins: [UUID: CGPoint] = [:], places: [UUID: Int] = [:]
            for (place, child) in parent.children.enumerated() {
                if origins[child.id] == nil {
                    origins[child.id] = child.frame.origin
                    places[child.id] = place
                }
                guard grows.contains(child.id), child.kind == .group, child.sketch?.decidedBy == .structure,
                      child.isArrangeable, child.unreadChildren.isEmpty, !child.children.isEmpty,
                      child.children.allSatisfy(\.isArrangeable), let kind = Self.kind(of: child) else { continue }
                growing[child.id] = Growing(kind: kind, members: child.children.map(\.id))
                for member in child.children where origins[member.id] == nil {
                    origins[member.id] = TreeRules.released(member, from: child).frame.origin
                    places[member.id] = place
                }
            }
            self.growing = growing
            self.origins = origins
            self.places = places
        }

        private static func kind(of container: LayerNode) -> Structure.Kind? {
            switch container.resolvedLayout {
            case .stack(let stack): stack.axis == .horizontal ? .row : .column
            case .grid(let grid): .grid(columns: grid.columns)
            case .free, .overlay: nil
            }
        }

        /// A new card's column; else grids, rows, then columns over the rows and grids applied and the rest.
        func decisions(_ near: [Int]) -> [Decision] {
            if parent.kind == .card, !parent.children.isEmpty, parent.children.allSatisfy({ new.contains($0.id) }) {
                return parent.isArrangeable ? inside() : []
            }
            let base = near.map { Item(node: parent.children[$0], isNew: new.contains(parent.children[$0].id), place: $0) }

            // Grids, with every container that may grow read as its members. A grid offered keeps what it holds from
            // rows and columns too, so that a grid is never split into rows (call 3).
            let gridItems = expanding(base) { _ in true }
            let grids = gridCandidates(among: gridItems, obstacles: Obstacles(obstacles(gridItems))).compactMap {
                decision(for: $0, among: gridItems)
            }
            let inGrids = Set(grids.flatMap { $0.structure.members + $0.structure.replacing })
            let rest = base.filter { !inGrids.contains($0.node.id) }

            // Rows, with the rows that may grow read as their members.
            let rowItems = expanding(rest) { $0 == .row }
            let rows = candidates(among: rowItems, rule: .row, obstacles: Obstacles(obstacles(rowItems))).compactMap {
                decision(for: $0, among: rowItems, rule: .row)
            }

            // Columns, over the rows and grids just applied, each one item, and the rest, with the columns that may
            // grow read as their members.
            let applied = (grids + rows).compactMap(\.applied)
            let inApplied = Set(applied.flatMap { $0.members + $0.replacing })
            let columnItems = applied.map { built in
                Item(node: built.container, isNew: built.members.contains(where: new.contains),
                     place: built.members.compactMap { places[$0] }.max() ?? 0)
            } + expanding(rest.filter { !inApplied.contains($0.node.id) }) { $0 == .column }
            let columnObstacles = Obstacles(obstacles(columnItems, leaving: inApplied)
                + applied.map { Obstacle(id: $0.container.id, shape: $0.container.frame) })
            let columnRule = Rule.column(mode)
            let columns = candidates(among: columnItems, rule: columnRule, obstacles: columnObstacles).compactMap {
                decision(for: $0, among: columnItems, rule: columnRule)
            }

            // A row offered that a column now holds, or whose container that may grow a column holds, couldn't be
            // built after it.
            let taken = Set(columns.compactMap(\.applied).flatMap { $0.members + $0.replacing })
            let kept = rows.filter { decision in
                if case .offer(let row) = decision { taken.isDisjoint(with: row.members + row.replacing) } else { true }
            }
            return grids + kept + columns
        }

        /// `items` with each container that may grow, of a kind `reads` takes, read as its members where they are on
        /// screen: a structure that may take its place (call 2).
        private func expanding(_ items: [Item], _ reads: (Structure.Kind) -> Bool) -> [Item] {
            items.flatMap { item -> [Item] in
                guard let growing = growing[item.node.id], reads(growing.kind) else { return [item] }
                return item.node.children.map { member in
                    Item(node: TreeRules.released(member, from: item.node), isNew: new.contains(member.id),
                         place: item.place, grower: item.node.id)
                }
            }
        }

        /// Every visible child's turned shape but those `gone`, with a container `items` reads as its members shown
        /// as its members.
        private func obstacles(_ items: [Item], leaving gone: Set<UUID> = []) -> [Obstacle] {
            let read = Set(items.compactMap(\.grower))
            return parent.children.filter { !$0.isHidden && !gone.contains($0.id) }.flatMap { child -> [Obstacle] in
                guard read.contains(child.id) else { return [Obstacle(child)] }
                return child.children.filter { !$0.isHidden }.map { Obstacle(TreeRules.released($0, from: child)) }
            }
        }

        /// Call 2: holding any member of a container that may grow, a structure holds all of them and a new node
        /// besides, and is bigger: more members, or a grid over a row or column. The containers it takes the place
        /// of, in reading order; nil when it may not be built.
        private func replacing(_ members: [Int], _ facts: Facts, kind: Structure.Kind) -> [UUID]? {
            let ids = Set(members.map { facts[$0].id })
            var replaced: [UUID] = []
            for case let container? in members.map({ facts[$0].grower }) where !replaced.contains(container) {
                guard let growing = growing[container] else { return nil }
                let held = Set(growing.members)
                guard held.isSubset(of: ids), members.contains(where: { facts[$0].isNew && !held.contains(facts[$0].id) }),
                      members.count > held.count || (kind.isGrid && !growing.kind.isGrid) else { return nil }
                replaced.append(container)
            }
            return replaced
        }

        // MARK: A new card's inside

        /// Everything a new card holds, as a column that is the card's own layout; else nothing.
        private func inside() -> [Decision] {
            let items = parent.children.indices.map { Item(node: parent.children[$0], isNew: true, place: $0) }
            let rule = Rule.column(mode)
            guard items.allSatisfy({ $0.node.isArrangeable }),
                  let column = candidates(among: items, rule: rule, obstacles: Obstacles([])).first, column.items.count == items.count
            else { return [] }
            let gap = median(column.gaps)
            let rhythm = cardProposal(column, among: items, spacing: tokens.spacing(nearest: gap))
            let exact = spacing(of: rhythm) == gap.rounded() ? rhythm : cardProposal(column, among: items, spacing: gap.rounded())
            return decision(confidence: column.confidence, rhythm: rhythm, exact: exact).map { [$0] } ?? []
        }

        /// The card laid out as the column. Its padding is the design's card padding where that moves nothing more
        /// than 8 pt, measured on the members as the engine places them; else its leading and top insets are kept as
        /// drawn. Tidying, it is always the card's. Its trailing and bottom padding are the card's.
        private func cardProposal(_ candidate: Candidate, among items: [Item], spacing: CGFloat) -> Structure {
            let padded = cardProposal(candidate, among: items, spacing: spacing,
                                      padding: LayerNode.Padding(all: tokens.card.padding))
            guard mode == .sketch, padded.movement > StructureConventions.furthestAutomaticMove else { return padded }
            let drawn = insetsAsDrawn(candidate, among: items)
            return drawn == padded.container.padding
                ? padded : cardProposal(candidate, among: items, spacing: spacing, padding: drawn)
        }

        /// The card's padding with its leading and top insets as drawn: its top where the column starts, and its leading
        /// inset where it keeps the shared line where it was drawn. A trailing line keeps the card's.
        private func insetsAsDrawn(_ candidate: Candidate, among items: [Item]) -> LayerNode.Padding {
            let frames = candidate.items.map { items[$0].frame }
            let cardPadding = tokens.card.padding, width = parent.frame.width
            let edge = median(frames.map(candidate.line.position))
            var padding = LayerNode.Padding(all: cardPadding)
            padding.top = max(0, snap(frames.map(\.minY).min() ?? cardPadding))
            switch candidate.line {
            case .leading: padding.leading = max(0, snap(edge))
            // Centred in what the card's trailing padding leaves.
            case .middles: padding.leading = max(0, snap(2 * edge - width + cardPadding))
            default: break
            }
            return padding
        }

        /// The card laid out as the column with `padding`, and how far that moves what it holds.
        private func cardProposal(_ candidate: Candidate, among items: [Item], spacing: CGFloat,
                                  padding: LayerNode.Padding) -> Structure {
            let members = candidate.items.map { items[$0].node }
            var template = LayerNode(kind: .group)
            template.frame.size = parent.frame.size
            (template.width, template.height) = (parent.width, parent.height)
            template.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: spacing, alignment: candidate.line.alignment))
            template.padding = padding
            let laid = laidOut(template, holding: members)
            var proposed = parent
            (proposed.layout, proposed.padding, proposed.children) = (laid.layout, laid.padding, laid.children)
            proposed.frame.size = laid.frame.size
            let movement = laid.children.map { moved($0, to: $0.frame.origin) }.max() ?? 0
            return Structure(kind: .cardColumn, parent: parent.id, members: members.map(\.id), container: proposed,
                             confidence: candidate.confidence, movement: movement)
        }

        // MARK: Finding runs

        /// The runs that qualify, taken greedily: most members, then most sure, then first in reading order (call 3).
        /// Each item is in one at most. The run from each item is found once, and found again only when one it held is
        /// taken: a run passes over what isn't in it, and stops at a place along the axis, so taking anything else
        /// leaves it as it was.
        private func candidates(among items: [Item], rule: Rule, obstacles: Obstacles) -> [Candidate] {
            let facts = items.map(Fact.init)
            let order = items.indices.filter { mayHold(items[$0], rule) }.sorted { a, b in
                let (x, y) = (facts[a].frame, facts[b].frame)
                return precedes(rule.start(x), rule.startAcross(x), facts[a].place, a, rule.start(y), rule.startAcross(y), facts[b].place, b)
            }
            let partners = Self.partners(in: order, facts: facts, rule: rule)
            // By item: not yet taken by a run chosen.
            var available = [Bool](repeating: true, count: items.count)
            var runs: [[Int]?] = order.indices.map { _ in nil }, found: [Candidate?] = runs.map { _ in nil }
            for start in order.indices {
                (runs[start], found[start]) = run(from: start, in: order, partners: partners, available: available,
                                                  facts: facts, rule: rule, obstacles: obstacles)
            }
            var chosen: [Candidate] = []
            while let best = found.lazy.compactMap({ $0 }).min(by: {
                ranks($0.items, $0.confidence, before: $1.items, $1.confidence, facts)
            }) {
                chosen.append(best)
                for index in best.items { available[index] = false }
                for start in order.indices {
                    guard let held = runs[start] else { continue }
                    if !available[order[start]] {
                        (runs[start], found[start]) = (nil, nil)
                    } else if held.contains(where: { !available[$0] }) {
                        (runs[start], found[start]) = run(from: start, in: order, partners: partners, available: available,
                                                          facts: facts, rule: rule, obstacles: obstacles)
                    }
                }
            }
            return chosen
        }

        /// The run that starts at `order[start]`: each next one along the axis joins while it is past the last, shares
        /// a line with the whole run, keeps the run's sizes and gaps, and nothing else lies between them. Only those
        /// that share a line with the first can join (`partners`); the rest are passed over, as are those taken.
        private func run(from start: Int, in order: [Int], partners: [[Int]], available: [Bool], facts: Facts, rule: Rule,
                         obstacles: Obstacles) -> (held: [Int], candidate: Candidate?) {
            let first = order[start], lines = rule.lines
            var run = [first], gaps: [CGFloat] = [], last = facts[first].frame
            // The lines it still shares, a bit each, and what it spans on each, across the axis, and in its gaps.
            var shared = (1 << lines.count) - 1
            var spans = lines.map { (low: $0.position(last), high: $0.position(last)) }
            var across = (low: rule.across(last), high: rule.across(last))
            var gapSpan = (low: CGFloat.infinity, high: -CGFloat.infinity)
            for place in partners[start] where available[order[place]] {
                let next = order[place], frame = facts[next].frame
                let gap = rule.start(frame) - rule.end(last)
                if gap < 0 { continue }
                // Sorted along the axis, what comes after is further still.
                if let largest = rule.largestGap, gap > largest { break }
                if let ratio = rule.sizeRatio {
                    let size = rule.across(frame)
                    if !isWithin(ratio, low: min(across.low, size), high: max(across.high, size)) { continue }
                }
                var fitting = 0
                for bit in lines.indices where shared & (1 << bit) != 0 {
                    let position = lines[bit].position(frame)
                    if max(spans[bit].high, position) - min(spans[bit].low, position) <= lines[bit].tolerance { fitting |= 1 << bit }
                }
                if fitting == 0 { continue }
                if let variation = rule.gapVariation, max(gapSpan.high, gap) - min(gapSpan.low, gap) > variation { continue }
                let id = facts[next].id
                let between = rule.space(between: last, and: frame)
                if obstacles.meet(between, under: [last, frame],
                                  ignoring: { other in other == id || run.contains { facts[$0].id == other } }) { continue }
                run.append(next)
                gaps.append(gap)
                last = frame
                shared = fitting
                for bit in lines.indices {
                    let position = lines[bit].position(frame)
                    spans[bit] = (min(spans[bit].low, position), max(spans[bit].high, position))
                }
                across = (min(across.low, rule.across(frame)), max(across.high, rule.across(frame)))
                gapSpan = (min(gapSpan.low, gap), max(gapSpan.high, gap))
            }
            guard run.count >= rule.least, run.contains(where: { facts[$0].isNew }),
                  let replaced = self.replacing(run, facts, kind: rule.kind) else { return (run, nil) }
            let memberFrames = run.map { facts[$0].frame }
            let still = lines.indices.filter { shared & (1 << $0) != 0 }.map { lines[$0] }
            // The line that fits best against its tolerance; ties go to the first (a row's centres, a column's leading).
            guard let line = still.enumerated().min(by: { a, b in
                (error(memberFrames.map(a.element.position)) / a.element.tolerance, a.offset)
                    < (error(memberFrames.map(b.element.position)) / b.element.tolerance, b.offset)
            })?.element else { return (run, nil) }
            return (run, Candidate(
                items: run, line: line, gaps: gaps, confidence: confidence(memberFrames, line: line, gaps: gaps, rule: rule),
                replacing: replaced))
        }

        /// For each place in `order`, the later places whose item shares one of the rule's lines with that place's item
        /// within the line's tolerance, in order: only those can join a run that starts there. Among a batch's handful,
        /// every later place, which is quicker than sorting them.
        private static func partners(in order: [Int], facts: Facts, rule: Rule) -> [[Int]] {
            guard order.count >= fewestSorted else { return order.indices.map { Array(($0 + 1)..<order.count) } }
            var partners = [[Int]](repeating: [], count: order.count)
            for line in rule.lines {
                let positions = order.map { line.position(facts[$0].frame) }
                let sorted = order.indices.filter { positions[$0].isFinite }.sorted { positions[$0] < positions[$1] }
                for (rank, place) in sorted.enumerated() {
                    // A point's leeway for rounding; the test that decides is the run's own.
                    for other in sorted[(rank + 1)...] {
                        let (a, b) = (positions[place], positions[other])
                        if b - a > line.tolerance + 1 { break }
                        if max(a, b) - min(a, b) <= line.tolerance { partners[min(place, other)].append(max(place, other)) }
                    }
                }
            }
            return partners.map { Array(Set($0)).sorted() }
        }

        /// Never a row holding a row or a column holding a column (F5), nor a member's subtree past depth 32 (F9):
        /// inside the new container a member sits two below the parent.
        private func mayHold(_ item: Item, _ rule: Rule) -> Bool {
            if item.node.kind == .group, case .stack(let stack) = item.node.resolvedLayout, stack.axis == rule.axis { return false }
            return depth + 2 + TreeEdit.levels(below: item.node) <= TreeRules.maximumDepth
        }

        /// Most members first, then most sure, then first in reading order.
        private func ranks(_ a: [Int], _ aSure: Double, before b: [Int], _ bSure: Double, _ facts: Facts) -> Bool {
            if a.count != b.count { return a.count > b.count }
            if aSure != bSure { return aSure > bSure }
            let (x, y) = (facts[a[0]].frame, facts[b[0]].frame)
            return precedes(x.minY, x.minX, facts[a[0]].place, a[0], y.minY, y.minX, facts[b[0]].place, b[0])
        }

        /// Call 4: alignment × gaps × sizes, each `clamp(1 − e / (2 · limit), 0.5, 1)`.
        private func confidence(_ frames: [CGRect], line: Line, gaps: [CGFloat], rule: Rule) -> Double {
            let alignment = factor(error(frames.map(line.position)), limit: line.tolerance)
            let gapFactor = rule.gapLimit.map { factor(spread(gaps), limit: $0) } ?? 1
            let sizes = frames.map(rule.across)
            let smallest = sizes.min() ?? 0, largest = sizes.max() ?? 0
            let sizeError = smallest > 0 ? largest / smallest - 1 : (largest > 0 ? .infinity : 0)
            return alignment * gapFactor * factor(sizeError, limit: 1)
        }

        // MARK: Finding grids

        /// The grids that qualify, taken greedily as runs are. Each item is in one at most. Among more things than
        /// `StructureConventions.gridSearchedTogether`, a grid is looked for in one band of them at a time (`bands`).
        private func gridCandidates(among items: [Item], obstacles: Obstacles) -> [GridCandidate] {
            let facts = items.map(Fact.init)
            return Self.bands(of: items.indices.filter { mayHoldInGrid(items[$0]) }, facts).flatMap { band in
                var available = band
                var chosen: [GridCandidate] = []
                while true {
                    guard let best = bestBlock(of: available, facts, obstacles: obstacles) else { break }
                    chosen.append(best)
                    available.removeAll { best.items.contains($0) }
                }
                return chosen
            }
        }

        /// `indices` as one band, or, when there are more than `StructureConventions.gridSearchedTogether`, in bands
        /// across the container from the top, each of that many at most: a band ends there, or once it is half full
        /// where nothing in it reaches below the top of the next. Every grid there can be is tried within a band, and
        /// trying every grid among hundreds of things took seconds. It costs grids across a band's edge, in voice's
        /// tidy and in the pass after a batch alike: a busy screen's neighbourhood can pass that many.
        private static func bands(of indices: [Int], _ facts: Facts) -> [[Int]] {
            let most = StructureConventions.gridSearchedTogether
            guard indices.count > most else { return [indices] }
            let sorted = indices.sorted { a, b in
                let (x, y) = (facts[a].frame, facts[b].frame)
                return precedes(x.minY, x.minX, facts[a].place, a, y.minY, y.minX, facts[b].place, b)
            }
            var bands: [[Int]] = [], band: [Int] = [], bottom = -CGFloat.infinity
            for index in sorted {
                let frame = facts[index].frame
                if band.count == most || (band.count >= most / 2 && frame.minY >= bottom) {
                    bands.append(band)
                    (band, bottom) = ([], -.infinity)
                }
                band.append(index)
                bottom = max(bottom, frame.maxY)
            }
            return bands + [band]
        }

        /// A grid takes only leaves and cards (F5), and nothing whose subtree would pass depth 32 (F9).
        private func mayHoldInGrid(_ item: Item) -> Bool {
            item.node.kind != .group && depth + 2 + TreeEdit.levels(below: item.node) <= TreeRules.maximumDepth
        }

        /// The best grid among `available` (`ranks`), of every grid there: each run of rows (tops within 4), and in it
        /// each run of columns (leading edges within 4) of 12 at most (`StructureConventions.gridMostColumns`), with what
        /// lies in both. Only a run's last row may be short. One with fewer members than the best found so far can't be
        /// better, so it isn't looked at.
        private func bestBlock(of available: [Int], _ facts: Facts, obstacles: Obstacles) -> GridCandidate? {
            typealias C = StructureConventions
            let rows = clusters(available, facts, by: { $0.minY })
            var best: GridCandidate?
            for first in rows.indices where rows[first].count >= C.gridLeastColumns {
                for last in (first + 1)..<rows.count {
                    let inRows = rows[first...last].flatMap { $0 }
                    let columns = inRows.count < best?.items.count ?? 0 ? [] : clusters(inRows, facts, by: { $0.minX })
                    // A grid's first column holds one of each of its rows, and each column after it as many as the one
                    // before or one fewer, the last row being short. Past a column that doesn't, no wider run of
                    // columns is a grid.
                    for left in columns.indices where columns[left].count >= C.gridLeastRows {
                        var total = columns[left].count
                        for right in (left + 1)..<min(columns.count, left + C.gridMostColumns) {
                            let count = columns[right].count
                            guard count <= columns[right - 1].count, count >= columns[left].count - 1 else { break }
                            total += count
                            guard total >= best?.items.count ?? 0,
                                  let grid = grid(Array(columns[left...right].joined()), columns: Array(columns[left...right]),
                                                  facts, obstacles)
                            else { continue }
                            if best.map({ ranks(grid.items, grid.confidence, before: $0.items, $0.confidence, facts) }) ?? true {
                                best = grid
                            }
                        }
                    }
                    if rows[last].count < C.gridLeastColumns { break }
                }
            }
            return best
        }

        /// The grid `indices` make, if they make one: ≥ 2 rows and ≥ 2 columns, one member in each cell, every row full
        /// but a last one that a growing grid gains, filling its first columns; cell sizes within 20% of the median's;
        /// a new member; gaps that don't overlap; nothing else inside; and all of any container that may grow.
        /// `columns` are theirs, leading edges within 4: as `bestBlock` found them, which a run of whole columns keeps.
        private func grid(_ indices: [Int], columns: [[Int]], _ facts: Facts, _ obstacles: Obstacles) -> GridCandidate? {
            typealias C = StructureConventions
            let rows = clusters(indices, facts, by: { $0.minY })
            guard rows.count >= C.gridLeastRows, columns.count >= C.gridLeastColumns,
                  indices.contains(where: { facts[$0].isNew }) else { return nil }
            var column: [Int: Int] = [:]
            for (place, group) in columns.enumerated() { for index in group { column[index] = place } }
            let cells = rows.map { row in row.sorted { column[$0, default: 0] < column[$1, default: 0] } }
            for (place, row) in cells.enumerated() {
                // One in each cell, from the first column on; full but for the last row.
                guard row.map({ column[$0, default: -1] }) == Array(0..<row.count),
                      row.count == columns.count || place == cells.count - 1 else { return nil }
            }

            let frames = indices.map { facts[$0].frame }
            let middleWidth = median(frames.map { $0.width }), middleHeight = median(frames.map { $0.height })
            guard middleWidth > 0, middleHeight > 0 else { return nil }
            let sizeError = frames.map {
                max(abs($0.width - middleWidth) / middleWidth, abs($0.height - middleHeight) / middleHeight)
            }.max() ?? 0
            guard Double(sizeError) <= C.gridCellSizeVariation else { return nil }

            var columnGaps: [CGFloat] = [], rowGaps: [CGFloat] = []
            for row in cells {
                for (a, b) in zip(row, row.dropFirst()) { columnGaps.append(facts[b].frame.minX - facts[a].frame.maxX) }
            }
            for (upper, lower) in zip(cells, cells.dropFirst()) {
                for (a, b) in zip(upper, lower) { rowGaps.append(facts[b].frame.minY - facts[a].frame.maxY) }
            }
            guard (columnGaps + rowGaps).allSatisfy({ $0 >= 0 }) else { return nil }

            let ids = Set(indices.map { facts[$0].id })
            let box = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            guard !obstacles.meet(box, under: [box], ignoring: { ids.contains($0) }) else { return nil }

            let kind = Structure.Kind.grid(columns: columns.count)
            let members = cells.flatMap { $0 }
            guard let replaced = self.replacing(members, facts, kind: kind) else { return nil }
            // Only a grid that may grow gains a short last row.
            if cells[cells.count - 1].count < columns.count,
               !replaced.contains(where: { growing[$0]?.kind == kind }) { return nil }

            let alignment = (rows.map { $0.map { facts[$0].frame.minY } } + columns.map { $0.map { facts[$0].frame.minX } })
                .map(error).max() ?? 0
            let confidence = factor(alignment, limit: C.gridEdgeTolerance)
                * factor(max(spread(columnGaps), spread(rowGaps)), limit: gridGapLimit)
                * factor(sizeError, limit: CGFloat(C.gridCellSizeVariation))
            return GridCandidate(
                items: members, columns: columns.count,
                leading: median(columns[0].map { facts[$0].frame.minX }), top: median(rows[0].map { facts[$0].frame.minY }),
                columnGaps: columnGaps, rowGaps: rowGaps, confidence: confidence, replacing: replaced)
        }

        /// `indices` in groups along one edge: in order, a group takes each next one within 4 of its first.
        private func clusters(_ indices: [Int], _ facts: Facts, by edge: (CGRect) -> CGFloat) -> [[Int]] {
            // By (edge, place, index): the 0s stand in for a second key there isn't.
            let sorted = indices.sorted { precedes(edge(facts[$0].frame), 0, facts[$0].place, $0, edge(facts[$1].frame), 0, facts[$1].place, $1) }
            var groups: [[Int]] = []
            for index in sorted {
                if let first = groups.last?.first,
                   edge(facts[index].frame) - edge(facts[first].frame) <= StructureConventions.gridEdgeTolerance {
                    groups[groups.count - 1].append(index)
                } else {
                    groups.append([index])
                }
            }
            return groups
        }

        // MARK: Proposals

        /// The rhythm's spacing, else the exact median gap, else an offer with the rhythm's (My call 16).
        private func decision(for candidate: Candidate, among items: [Item], rule: Rule) -> Decision? {
            let gap = median(candidate.gaps)
            let rhythm = proposal(candidate, among: items, rule: rule, spacing: tokens.spacing(nearest: gap))
            let exactGap = gap.rounded()
            let exact = spacing(of: rhythm) == exactGap
                ? rhythm : proposal(candidate, among: items, rule: rule, spacing: exactGap)
            return decision(confidence: candidate.confidence, rhythm: rhythm, exact: exact)
        }

        /// A grid's column and row spacings, each through the rhythm as a row's is, then both exact.
        private func decision(for grid: GridCandidate, among items: [Item]) -> Decision? {
            let gaps = (column: median(grid.columnGaps), row: median(grid.rowGaps))
            let onRhythm = (tokens.spacing(nearest: gaps.column), tokens.spacing(nearest: gaps.row))
            let exactly = (gaps.column.rounded(), gaps.row.rounded())
            let rhythm = proposal(grid, among: items, spacing: onRhythm)
            let exact = onRhythm == exactly ? rhythm : proposal(grid, among: items, spacing: exactly)
            return decision(confidence: grid.confidence, rhythm: rhythm, exact: exact)
        }

        private func decision(confidence: Double, rhythm: Structure, exact: Structure) -> Decision? {
            switch decide(confidence: confidence, rhythmMove: rhythm.movement, medianMove: exact.movement, mode: mode) {
            case .applyRhythm?: .apply(rhythm)
            case .applyMedian?: .apply(exact)
            case .offer?: .offer(rhythm)
            case nil: nil
            }
        }

        /// A row or column as the engine lays it out: it starts at the first member, with the shared line at the
        /// members' median, in whole points.
        private func proposal(_ candidate: Candidate, among items: [Item], rule: Rule, spacing: CGFloat) -> Structure {
            let members = candidate.items.map { items[$0].node }
            var template = LayerNode(kind: .group)
            template.layout = .stack(LayerNode.Stack(axis: rule.axis, spacing: spacing, alignment: candidate.line.alignment))
            (template.width, template.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
            var container = laidOut(template, holding: members)
            let frames = members.map(\.frame)
            let along = snap(rule.start(frames[0]))
            let across = snap(median(frames.map(candidate.line.position)) - candidate.line.share * rule.across(container.frame))
            container.frame.origin = rule.axis == .horizontal ? CGPoint(x: along, y: across) : CGPoint(x: across, y: along)
            return made(rule.kind, members: members, in: container, confidence: candidate.confidence, replacing: candidate.replacing)
        }

        /// A grid as the engine lays it out, aligned (start, start): its first column's leading edge and first row's
        /// top where they were drawn, in whole points.
        private func proposal(_ grid: GridCandidate, among items: [Item], spacing: (column: CGFloat, row: CGFloat)) -> Structure {
            let members = grid.items.map { items[$0].node }
            var template = LayerNode(kind: .group)
            template.layout = .grid(LayerNode.Grid(
                columns: grid.columns, columnSpacing: spacing.column, rowSpacing: spacing.row,
                alignment: LayerNode.Alignment(horizontal: .start, vertical: .start)))
            (template.width, template.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
            var container = laidOut(template, holding: members)
            container.frame.origin = CGPoint(x: snap(grid.leading), y: snap(grid.top))
            return made(.grid(columns: grid.columns), members: members, in: container, confidence: grid.confidence,
                        replacing: grid.replacing)
        }

        /// `template` as the engine lays it out holding `members` fixed in place. A fixed member's place depends on its size alone, so the engine lays out a leaf of that size in its
        /// place, in a free parent as it will be: nothing inside a member is laid out, and no id the pass doesn't throw
        /// away is counted as laid out (F7).
        private func laidOut(_ template: LayerNode, holding members: [LayerNode]) -> LayerNode {
            var container = template
            container.children = members.map { member in
                var standIn = LayerNode(kind: .shape)
                standIn.frame = member.frame
                return standIn
            }
            var scratch = LayerNode(kind: .group)
            scratch.children = [container]
            var diagnostics: [LayoutDiagnostic] = []
            LayoutEngine.layOut(&scratch, previous: nil, measure: measure, diagnostics: &diagnostics)
            container = scratch.children[0]
            container.children = zip(members, container.children).map { member, standIn in
                var member = StructureInference.fixedInPlace(member)
                member.frame = standIn.frame
                return member
            }
            return container
        }

        /// The structure `container` makes: the id these members always make in this parent, an intent decided by
        /// `.structure`, and how far it moves what it holds.
        private func made(_ kind: Structure.Kind, members: [LayerNode], in container: LayerNode, confidence: Double,
                          replacing: [UUID]) -> Structure {
            var container = container
            container.id = containerID(kind, members: members.map(\.id))
            container.sketch = LayerNode.SketchIntent(sketched: container.frame, on: nil, margin: 0, confidence: confidence,
                                                      decidedBy: .structure)
            let origin = container.frame.origin
            let movement = container.children.map { moved($0, to: origin.offset(by: $0.frame.origin)) }.max() ?? 0
            return Structure(kind: kind, parent: parent.id, members: members.map(\.id), replacing: replacing,
                             container: container, confidence: confidence, movement: movement)
        }

        /// How far a member put at `origin` in the parent's space, or anything in it, moves. What a row proposed just
        /// before holds moves with it, from where it is now; inside a member, what a build earlier in the step moved
        /// counts from where it lay when the step began (`started`, A1).
        private func moved(_ node: LayerNode, to origin: CGPoint) -> CGFloat {
            guard let now = origins[node.id] else {
                return node.children.map { moved($0, to: origin.offset(by: $0.frame.origin)) }.max() ?? 0
            }
            var placed = node
            placed.frame.origin = now
            return furthest(placed, shiftedBy: CGVector(dx: origin.x - now.x, dy: origin.y - now.y), in: .identity)
        }

        /// The furthest `node` or anything in it ends up from where it lay when the step began, once it moves by `shift`.
        /// `toParent` takes the space it lies in to the parent's.
        private func furthest(_ node: LayerNode, shiftedBy shift: CGVector, in toParent: CGAffineTransform) -> CGFloat {
            let own = node.transformToParent.concatenating(toParent)
            let now = CGPoint.zero.applying(own)
            let start = started[node.id] ?? now
            let distance = hypot(now.x + shift.dx - start.x, now.y + shift.dy - start.y)
            // With nothing moved earlier in the step, everything in it moves as it does.
            guard !started.isEmpty else { return distance }
            return node.children.reduce(distance) { max($0, furthest($1, shiftedBy: shift, in: own)) }
        }

        private func spacing(of structure: Structure) -> CGFloat? {
            if case .stack(let stack) = structure.container.resolvedLayout { stack.spacing } else { nil }
        }

        /// The same members in the same parent always make the same id, so the pass is deterministic, and the
        /// rhythm's proposal and the exact median's share it.
        private func containerID(_ kind: Structure.Kind, members: [UUID]) -> UUID {
            var hash = SHA256()
            hash.update(data: Data(String(describing: kind).utf8))
            for id in [parent.id] + members { withUnsafeBytes(of: id.uuid) { hash.update(bufferPointer: $0) } }
            var bytes = Array(hash.finalize().prefix(16))
            bytes[6] = bytes[6] & 0x0F | 0x50
            bytes[8] = bytes[8] & 0x3F | 0x80
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
    }

    // MARK: - Rows and columns

    /// A line members share: a row's centres, tops or bottoms, or a column's leading edges, centres or trailing edges.
    private enum Line {
        case centres, tops, bottoms, leading, middles, trailing

        func position(_ frame: CGRect) -> CGFloat {
            switch self {
            case .centres: frame.midY
            case .tops: frame.minY
            case .bottoms: frame.maxY
            case .leading: frame.minX
            case .middles: frame.midX
            case .trailing: frame.maxX
            }
        }

        var tolerance: CGFloat {
            switch self {
            case .centres: StructureConventions.rowCentreTolerance
            case .tops, .bottoms: StructureConventions.rowEdgeTolerance
            case .leading, .middles, .trailing: StructureConventions.columnEdgeTolerance
            }
        }

        var alignment: LayerNode.CrossAlignment {
            switch self {
            case .centres, .middles: .center
            case .tops, .leading: .start
            case .bottoms, .trailing: .end
            }
        }

        /// How far across the container the line lies: at its start, its middle or its end.
        var share: CGFloat {
            switch self {
            case .centres, .middles: 0.5
            case .tops, .leading: 0
            case .bottoms, .trailing: 1
            }
        }
    }

    /// What makes a row or a column.
    private struct Rule {
        var kind: Structure.Kind
        var axis: LayerNode.Axis
        /// The lines its members may share, a tie going to the first.
        var lines: [Line]
        var least: Int
        /// The widest gap between neighbours (rows).
        var largestGap: CGFloat?
        /// How many times larger across the axis one member may be than another (rows).
        var sizeRatio: CGFloat?
        /// How far the gaps may vary (columns, sketching).
        var gapVariation: CGFloat?
        /// The gap factor's limit; nil leaves it out (columns, tidying).
        var gapLimit: CGFloat?

        static let row = Rule(
            kind: .row, axis: .horizontal, lines: [.centres, .tops, .bottoms], least: 2,
            largestGap: StructureConventions.rowLargestGap, sizeRatio: StructureConventions.rowHeightRatio,
            gapVariation: nil, gapLimit: StructureConventions.rowLargestGap)

        /// Tidying, a column's gaps needn't be regular, and their factor is left out (call 10).
        static func column(_ mode: Mode) -> Rule {
            let sketching = mode == .sketch
            return Rule(kind: .column, axis: .vertical, lines: [.leading, .middles, .trailing],
                        least: StructureConventions.columnLeast, largestGap: nil, sizeRatio: nil,
                        gapVariation: sketching ? StructureConventions.columnGapVariation : nil,
                        gapLimit: sketching ? StructureConventions.columnGapVariation : nil)
        }

        func start(_ frame: CGRect) -> CGFloat { axis == .horizontal ? frame.minX : frame.minY }
        func end(_ frame: CGRect) -> CGFloat { axis == .horizontal ? frame.maxX : frame.maxY }
        func startAcross(_ frame: CGRect) -> CGFloat { axis == .horizontal ? frame.minY : frame.minX }
        /// Heights in a row, widths in a column.
        func across(_ frame: CGRect) -> CGFloat { axis == .horizontal ? frame.height : frame.width }

        /// The space between two neighbours along the axis, as tall (or as wide) as the two together.
        func space(between a: CGRect, and b: CGRect) -> CGRect {
            axis == .horizontal
                ? CGRect(x: a.maxX, y: min(a.minY, b.minY), width: b.minX - a.maxX, height: max(a.maxY, b.maxY) - min(a.minY, b.minY))
                : CGRect(x: min(a.minX, b.minX), y: a.maxY, width: max(a.maxX, b.maxX) - min(a.minX, b.minX), height: b.minY - a.maxY)
        }
    }

    // MARK: - Numbers

    /// The limit of a grid's gap factor: the spec gives a grid's gaps the 4 pt a column's may vary by.
    private static let gridGapLimit = StructureConventions.columnGapVariation

    /// Among fewer things than this, a run looks at every later one rather than sorting them by their lines first.
    private static let fewestSorted = 32

    /// `(a0, a1, a2, a3) < (b0, b1, b2, b3)` written out as the tuples compare: the first that differ decide. The
    /// tuples' own comparison is generic, and unoptimised it was much of a large tidy's time.
    private static func precedes(_ a0: CGFloat, _ a1: CGFloat, _ a2: Int, _ a3: Int,
                                 _ b0: CGFloat, _ b1: CGFloat, _ b2: Int, _ b3: Int) -> Bool {
        if a0 != b0 { return a0 < b0 }
        if a1 != b1 { return a1 < b1 }
        if a2 != b2 { return a2 < b2 }
        return a3 < b3
    }

    /// The middle value, or the mean of the middle two.
    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// The largest distance of any value from the median.
    private static func error(_ values: [CGFloat]) -> CGFloat {
        let middle = median(values)
        return values.map { abs($0 - middle) }.max() ?? 0
    }

    private static func spread(_ values: [CGFloat]) -> CGFloat {
        guard let low = values.min(), let high = values.max() else { return 0 }
        return high - low
    }

    /// Whether every value from `low` to `high` is within `ratio` times every other.
    private static func isWithin(_ ratio: CGFloat, low: CGFloat, high: CGFloat) -> Bool {
        low > 0 ? high / low <= ratio : high <= 0
    }

    /// `clamp(1 − e / (2 · limit), 0.5, 1)`.
    private static func factor(_ error: CGFloat, limit: CGFloat) -> Double {
        Double(min(1, max(0.5, 1 - error / (2 * limit))))
    }

    /// Whether two boxes share some area: a box that only touches the space between two members isn't in it.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width > 0 && shared.height > 0
    }

    /// Whole points, half up, as the engine writes frames.
    private static func snap(_ value: CGFloat) -> CGFloat { (value + 0.5).rounded(.down) }

    // MARK: - What it looked at

    #if DEBUG
    /// One entry per run in that receiving container, counted under a lock (F7).
    static func neighbourhoodSizes(of parent: UUID) -> [Int] { looked.withLock { $0[parent] ?? [] } }

    private static func record(_ size: Int, for parent: UUID) {
        looked.withLock { $0[parent, default: []].append(size) }
    }

    private static let looked = OSAllocatedUnfairLock(initialState: [UUID: [Int]]())
    #endif
}

private extension StructureInference.Decision {
    var structure: StructureInference.Structure {
        switch self {
        case .apply(let structure), .offer(let structure): structure
        }
    }

    var applied: StructureInference.Structure? {
        if case .apply(let structure) = self { structure } else { nil }
    }
}

private extension StructureInference.Structure.Kind {
    var isGrid: Bool {
        if case .grid = self { true } else { false }
    }
}

private extension CGPoint {
    func offset(by other: CGPoint) -> CGPoint { CGPoint(x: x + other.x, y: y + other.y) }
}
