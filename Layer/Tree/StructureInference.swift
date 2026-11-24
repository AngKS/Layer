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
        /// The furthest any member moves, as proposed. Members are upright and keep their sizes, so every corner
        /// moves as the origin does; what a row proposed just before holds counts from where it is now.
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
    /// counts it (a screen's root is 0), so that nothing is built past depth 32 (F9). Tidying, every arrangeable child
    /// counts as new, whatever `new` says. In the order to apply: inner structures first.
    static func infer(in parent: LayerNode, new: Set<UUID>, grows: Set<UUID> = [], tokens: DesignTokens,
                      mode: Mode = .sketch, measure: TextMeasure = .shared, depth: Int = 0) -> [Decision] {
        guard parent.isContainer, parent.resolvedLayout == .free else { return [] }
        let new = mode == .tidy ? Set(parent.children.filter(\.isArrangeable).map(\.id)) : new
        let near = neighbourhood(of: parent, new: new)
        #if DEBUG
        record(near.count, for: parent.id)
        #endif
        guard !near.isEmpty else { return [] }
        return Pass(parent: parent, new: new, grows: grows, tokens: tokens, mode: mode, measure: measure, depth: depth)
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
    /// inside the proposed container (its id kept) at the frontmost member's slot. For `.cardColumn`, `parent` is the
    /// card, which takes the proposed layout and padding and holds its children in the proposed order and frames.
    /// Nil when a member is gone, no longer `parent`'s child, or not arrangeable, when a container it replaces isn't
    /// there, or when the container is already there.
    static func applying(_ structure: Structure, to parent: LayerNode) -> LayerNode? {
        if structure.kind == .cardColumn { return applyingInside(structure, card: parent) }
        var parent = parent
        for id in structure.replacing {
            guard let place = parent.children.firstIndex(where: { $0.id == id }), open(place, in: &parent) else { return nil }
        }
        let members = structure.members
        guard !members.isEmpty, Set(members).count == members.count,
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
        // The container takes the frontmost member's place, and the others go: a child this build couldn't read
        // keeps its place among those that stay.
        let front = places.max() ?? 0
        let others = places.filter { $0 != front }
        var result = parent
        TreeRules.keepUnreadPlaces(in: &result, removing: others)
        var children = parent.children
        children[front] = container
        for place in others.sorted(by: >) { children.remove(at: place) }
        result.children = children
        return result
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

    /// Opens the container the pass made at `place`: its members take its slot where they are on screen, and a child
    /// this build couldn't read keeps its place among the rest. False when it isn't one the pass made, or holds
    /// something this build couldn't read.
    private static func open(_ place: Int, in parent: inout LayerNode) -> Bool {
        let container = parent.children[place]
        guard container.kind == .group, container.sketch?.decidedBy == .structure, container.unreadChildren.isEmpty
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
    /// in it, until nothing joins: in the parent's order, as places among its children.
    private static func neighbourhood(of parent: LayerNode, new: Set<UUID>) -> [Int] {
        let reach = StructureConventions.reach
        let arrangeable = parent.children.indices.filter { parent.children[$0].isArrangeable }
        var inside = arrangeable.filter { new.contains(parent.children[$0].id) }
        var outside = arrangeable.filter { !new.contains(parent.children[$0].id) }
        var next = 0
        while next < inside.count, !outside.isEmpty {
            let frame = parent.children[inside[next]].frame
            let joining = outside.filter { meets(parent.children[$0].frame.insetBy(dx: -reach, dy: -reach), frame) }
            inside += joining
            outside.removeAll { joining.contains($0) }
            next += 1
        }
        return inside.sorted()
    }

    /// Whether two boxes touch or overlap.
    private static func meets(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
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

    /// Something that may lie between members: a visible child's turned shape, or a structure proposed just before.
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

    /// A run that qualifies: its items in reading order, the line they share, and its gaps.
    private struct Candidate {
        var items: [Int]
        var line: Line
        var gaps: [CGFloat]
        var confidence: Double
        var replacing: [UUID]
    }

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
        /// The children in `grows` that are still a row, column or grid the pass made, holding only what it may take.
        let growing: [UUID: Growing]
        /// Where each of the parent's children, and each member of a container that may grow, is now on screen.
        let origins: [UUID: CGPoint]
        /// Their places among the parent's children: a member's is its container's.
        let places: [UUID: Int]

        init(parent: LayerNode, new: Set<UUID>, grows: Set<UUID>, tokens: DesignTokens, mode: Mode,
             measure: TextMeasure, depth: Int) {
            self.parent = parent
            self.new = new
            self.tokens = tokens
            self.mode = mode
            self.measure = measure
            self.depth = depth
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
            let grids = gridCandidates(among: gridItems, obstacles: obstacles(gridItems)).compactMap {
                decision(for: $0, among: gridItems)
            }
            let inGrids = Set(grids.flatMap { $0.structure.members + $0.structure.replacing })
            let rest = base.filter { !inGrids.contains($0.node.id) }

            // Rows, with the rows that may grow read as their members.
            let rowItems = expanding(rest) { $0 == .row }
            let rows = candidates(among: rowItems, rule: .row, obstacles: obstacles(rowItems)).compactMap {
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
            let columnObstacles = obstacles(columnItems, leaving: inApplied)
                + applied.map { Obstacle(id: $0.container.id, shape: $0.container.frame) }
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
        private func replacing(_ members: [Item], kind: Structure.Kind) -> [UUID]? {
            let ids = Set(members.map(\.node.id))
            var replaced: [UUID] = []
            for case let container? in members.map(\.grower) where !replaced.contains(container) {
                guard let growing = growing[container] else { return nil }
                let held = Set(growing.members)
                guard held.isSubset(of: ids), members.contains(where: { $0.isNew && !held.contains($0.node.id) }),
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
                  let column = candidates(among: items, rule: rule, obstacles: []).first, column.items.count == items.count
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
        /// Each item is in one at most.
        private func candidates(among items: [Item], rule: Rule, obstacles: [Obstacle]) -> [Candidate] {
            var available = items.indices.filter { mayHold(items[$0], rule) }
            var chosen: [Candidate] = []
            while true {
                let order = available.sorted { a, b in
                    let (x, y) = (items[a].frame, items[b].frame)
                    return (rule.start(x), rule.startAcross(x), items[a].place, a) < (rule.start(y), rule.startAcross(y), items[b].place, b)
                }
                let runs = order.indices.compactMap { run(from: $0, in: order, items: items, rule: rule, obstacles: obstacles) }
                guard let best = runs.min(by: { ranks($0.items, $0.confidence, before: $1.items, $1.confidence, items: items) })
                else { break }
                chosen.append(best)
                available.removeAll { best.items.contains($0) }
            }
            return chosen
        }

        /// The run that starts at `order[start]`: each next one along the axis joins while it is past the last, shares
        /// a line with the whole run, keeps the run's sizes and gaps, and nothing else lies between them.
        private func run(from start: Int, in order: [Int], items: [Item], rule: Rule, obstacles: [Obstacle]) -> Candidate? {
            var run = [order[start]], gaps: [CGFloat] = [], lines = rule.lines
            for next in order[(start + 1)...] {
                let last = items[run[run.count - 1]].frame, frame = items[next].frame
                let gap = rule.start(frame) - rule.end(last)
                if gap < 0 { continue }
                // Sorted along the axis, what comes after is further still.
                if let largest = rule.largestGap, gap > largest { break }
                let frames = (run + [next]).map { items[$0].frame }
                if let ratio = rule.sizeRatio, !isWithin(ratio, frames.map(rule.across)) { continue }
                let fitting = lines.filter { spread(frames.map($0.position)) <= $0.tolerance }
                if fitting.isEmpty { continue }
                if let variation = rule.gapVariation, spread(gaps + [gap]) > variation { continue }
                let members = Set((run + [next]).map { items[$0].node.id })
                let between = rule.space(between: last, and: frame)
                if obstacles.contains(where: { !members.contains($0.id) && overlaps($0.shape, between) }) { continue }
                run.append(next)
                gaps.append(gap)
                lines = fitting
            }
            let frames = run.map { items[$0].frame }
            // The line that fits best against its tolerance; ties go to the first (a row's centres, a column's leading).
            guard run.count >= rule.least, run.contains(where: { items[$0].isNew }),
                  let replaced = self.replacing(run.map { items[$0] }, kind: rule.kind),
                  let line = lines.enumerated().min(by: { a, b in
                      (error(frames.map(a.element.position)) / a.element.tolerance, a.offset)
                          < (error(frames.map(b.element.position)) / b.element.tolerance, b.offset)
                  })?.element
            else { return nil }
            return Candidate(items: run, line: line, gaps: gaps, confidence: confidence(frames, line: line, gaps: gaps, rule: rule),
                             replacing: replaced)
        }

        /// Never a row holding a row or a column holding a column (F5), nor a member's subtree past depth 32 (F9):
        /// inside the new container a member sits two below the parent.
        private func mayHold(_ item: Item, _ rule: Rule) -> Bool {
            if item.node.kind == .group, case .stack(let stack) = item.node.resolvedLayout, stack.axis == rule.axis { return false }
            return depth + 2 + TreeEdit.levels(below: item.node) <= TreeRules.maximumDepth
        }

        /// Most members first, then most sure, then first in reading order.
        private func ranks(_ a: [Int], _ aSure: Double, before b: [Int], _ bSure: Double, items: [Item]) -> Bool {
            if a.count != b.count { return a.count > b.count }
            if aSure != bSure { return aSure > bSure }
            let (x, y) = (items[a[0]], items[b[0]])
            return (x.frame.minY, x.frame.minX, x.place, a[0]) < (y.frame.minY, y.frame.minX, y.place, b[0])
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

        /// The grids that qualify, taken greedily as runs are. Each item is in one at most.
        private func gridCandidates(among items: [Item], obstacles: [Obstacle]) -> [GridCandidate] {
            var available = items.indices.filter { mayHoldInGrid(items[$0]) }
            var chosen: [GridCandidate] = []
            while true {
                let found = blocks(of: available, in: items, obstacles: obstacles)
                guard let best = found.min(by: { ranks($0.items, $0.confidence, before: $1.items, $1.confidence, items: items) })
                else { break }
                chosen.append(best)
                available.removeAll { best.items.contains($0) }
            }
            return chosen
        }

        /// A grid takes only leaves and cards (F5), and nothing whose subtree would pass depth 32 (F9).
        private func mayHoldInGrid(_ item: Item) -> Bool {
            item.node.kind != .group && depth + 2 + TreeEdit.levels(below: item.node) <= TreeRules.maximumDepth
        }

        /// Every grid among `available`: each run of rows (tops within 4), and in it each run of columns (leading edges
        /// within 4), with what lies in both. Only a run's last row may be short.
        private func blocks(of available: [Int], in items: [Item], obstacles: [Obstacle]) -> [GridCandidate] {
            let least = StructureConventions.gridLeastColumns
            let rows = clusters(available, items, by: \.minY)
            var found: [GridCandidate] = []
            for first in rows.indices where rows[first].count >= least {
                for last in (first + 1)..<rows.count {
                    let inRows = rows[first...last].flatMap { $0 }
                    let columns = clusters(inRows, items, by: \.minX)
                    for left in columns.indices {
                        for right in (left + 1)..<columns.count {
                            let taken = Set(columns[left...right].joined())
                            if let grid = grid(inRows.filter(taken.contains), items, obstacles) { found.append(grid) }
                        }
                    }
                    if rows[last].count < least { break }
                }
            }
            return found
        }

        /// The grid `indices` make, if they make one: ≥ 2 rows and ≥ 2 columns, one member in each cell, every row full
        /// but a last one that a growing grid gains, filling its first columns; cell sizes within 20% of the median's;
        /// a new member; gaps that don't overlap; nothing else inside; and all of any container that may grow.
        private func grid(_ indices: [Int], _ items: [Item], _ obstacles: [Obstacle]) -> GridCandidate? {
            typealias C = StructureConventions
            let rows = clusters(indices, items, by: \.minY), columns = clusters(indices, items, by: \.minX)
            guard rows.count >= C.gridLeastRows, columns.count >= C.gridLeastColumns,
                  indices.contains(where: { items[$0].isNew }) else { return nil }
            var column: [Int: Int] = [:]
            for (place, group) in columns.enumerated() { for index in group { column[index] = place } }
            let cells = rows.map { row in row.sorted { column[$0, default: 0] < column[$1, default: 0] } }
            for (place, row) in cells.enumerated() {
                // One in each cell, from the first column on; full but for the last row.
                guard row.map({ column[$0, default: -1] }) == Array(0..<row.count),
                      row.count == columns.count || place == cells.count - 1 else { return nil }
            }

            let frames = indices.map { items[$0].frame }
            let middleWidth = median(frames.map(\.width)), middleHeight = median(frames.map(\.height))
            guard middleWidth > 0, middleHeight > 0 else { return nil }
            let sizeError = frames.map {
                max(abs($0.width - middleWidth) / middleWidth, abs($0.height - middleHeight) / middleHeight)
            }.max() ?? 0
            guard Double(sizeError) <= C.gridCellSizeVariation else { return nil }

            var columnGaps: [CGFloat] = [], rowGaps: [CGFloat] = []
            for row in cells {
                for (a, b) in zip(row, row.dropFirst()) { columnGaps.append(items[b].frame.minX - items[a].frame.maxX) }
            }
            for (upper, lower) in zip(cells, cells.dropFirst()) {
                for (a, b) in zip(upper, lower) { rowGaps.append(items[b].frame.minY - items[a].frame.maxY) }
            }
            guard (columnGaps + rowGaps).allSatisfy({ $0 >= 0 }) else { return nil }

            let ids = Set(indices.map { items[$0].node.id })
            let box = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            guard !obstacles.contains(where: { !ids.contains($0.id) && overlaps($0.shape, box) }) else { return nil }

            let kind = Structure.Kind.grid(columns: columns.count)
            let members = cells.flatMap { $0 }
            guard let replaced = self.replacing(members.map { items[$0] }, kind: kind) else { return nil }
            // Only a grid that may grow gains a short last row.
            if cells[cells.count - 1].count < columns.count,
               !replaced.contains(where: { growing[$0]?.kind == kind }) { return nil }

            let alignment = (rows.map { $0.map { items[$0].frame.minY } } + columns.map { $0.map { items[$0].frame.minX } })
                .map(error).max() ?? 0
            let confidence = factor(alignment, limit: C.gridEdgeTolerance)
                * factor(max(spread(columnGaps), spread(rowGaps)), limit: gridGapLimit)
                * factor(sizeError, limit: CGFloat(C.gridCellSizeVariation))
            return GridCandidate(
                items: members, columns: columns.count,
                leading: median(columns[0].map { items[$0].frame.minX }), top: median(rows[0].map { items[$0].frame.minY }),
                columnGaps: columnGaps, rowGaps: rowGaps, confidence: confidence, replacing: replaced)
        }

        /// `indices` in groups along one edge: in order, a group takes each next one within 4 of its first.
        private func clusters(_ indices: [Int], _ items: [Item], by edge: (CGRect) -> CGFloat) -> [[Int]] {
            let sorted = indices.sorted { (edge(items[$0].frame), items[$0].place, $0) < (edge(items[$1].frame), items[$1].place, $1) }
            var groups: [[Int]] = []
            for index in sorted {
                if let first = groups.last?.first,
                   edge(items[index].frame) - edge(items[first].frame) <= StructureConventions.gridEdgeTolerance {
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

        /// How far a member moves to `origin` in the parent's space. What a row proposed just before holds moves with it,
        /// from where it is now.
        private func moved(_ node: LayerNode, to origin: CGPoint) -> CGFloat {
            if let before = origins[node.id] { return hypot(origin.x - before.x, origin.y - before.y) }
            return node.children.map { moved($0, to: origin.offset(by: $0.frame.origin)) }.max() ?? 0
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

    /// Whether every value is within `ratio` times every other.
    private static func isWithin(_ ratio: CGFloat, _ values: [CGFloat]) -> Bool {
        guard let low = values.min(), let high = values.max() else { return true }
        return low > 0 ? high / low <= ratio : high <= 0
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
