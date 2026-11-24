import CoreGraphics
import CryptoKit
import Foundation
import os

/// The structure pass (spec §5): the rows and columns among what a batch drew and its neighbours, each with how sure
/// it is, the spacing it takes, and how far it moves anything. Pure and deterministic, with no UIKit and no SwiftUI,
/// so it builds on macOS and runs off the main actor. Its numbers are `StructureConventions`', and the spacing comes
/// from the design's own rhythm (§14).
///
/// Rows come first, then columns, in which a row just applied is one item: one level of nesting per pass, inner first
/// (call 3). Each proposal is laid out by the engine with its members `.fixed` at their sizes (My call 16), and its
/// movement is measured on exactly what the engine gives (call 5).
enum StructureInference {
    enum Mode: Sendable {
        /// After a batch of readings: the 0.8 bar and nothing moved more than 8 pt, or an offer.
        case sketch
        /// Voice's tidy (call 10): the 0.5 bar, no limit, and a column's gaps needn't be regular.
        case tidy
    }

    struct Structure: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case row, column, grid(columns: Int), cardColumn }
        var kind: Kind
        /// The receiving container, a screen's root included.
        var parent: UUID
        /// In reading order (My call 15). A row proposed just before, by its container's id, may be one.
        var members: [UUID]
        /// Containers the pass made that this one takes the place of (Task 6).
        var replacing: [UUID] = []
        /// What would be built: its layout and padding, its frame in the parent's space, and both sizings `.fit`,
        /// with the members inside at their laid-out frames, each `.fixed` (My call 16). It carries an intent decided
        /// by `.structure`, so that a structure proposed after it may take it (a container without one is the
        /// person's); the store writes its real one when it builds it. For `.cardColumn` it is the card itself.
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

    /// Pure and deterministic. `parent` as it is now; `new` the batch's nodes in it; `grows` the containers the pass
    /// made that may grow (Task 6); `depth` how deep `parent` sits, as `TreeIndex` counts it (a screen's root is 0),
    /// so that nothing is built past depth 32 (F9). In the order to apply: inner structures first.
    static func infer(in parent: LayerNode, new: Set<UUID>, grows: Set<UUID> = [], tokens: DesignTokens,
                      mode: Mode = .sketch, measure: TextMeasure = .shared, depth: Int = 0) -> [Decision] {
        guard parent.isContainer, parent.resolvedLayout == .free else { return [] }
        let near = neighbourhood(of: parent, new: new)
        #if DEBUG
        record(near.count, for: parent.id)
        #endif
        guard !near.isEmpty else { return [] }
        return Pass(parent: parent, new: new, tokens: tokens, mode: mode, measure: measure, depth: depth).decisions(near)
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

    /// `parent` with `structure` built in it: members as they are now, each `.fixed` at its size and at the proposed
    /// frame, inside the proposed container (its id kept) at the frontmost member's slot. Nil when a member is gone,
    /// no longer `parent`'s child, or not arrangeable, or when the container is already there.
    static func applying(_ structure: Structure, to parent: LayerNode) -> LayerNode? {
        let members = structure.members
        guard !members.isEmpty, Set(members).count == members.count,
              !parent.children.contains(where: { $0.id == structure.container.id }) else { return nil }
        var places: [Int] = []
        for id in members {
            guard let place = parent.children.firstIndex(where: { $0.id == id }), parent.children[place].isArrangeable
            else { return nil }
            places.append(place)
        }
        let proposed = Dictionary(structure.container.children.map { ($0.id, $0.frame.origin) },
                                  uniquingKeysWith: { first, _ in first })
        var container = structure.container
        container.children = zip(members, places).map { id, place in
            var member = parent.children[place]
            member.width.mode = .fixed
            member.height.mode = .fixed
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

    /// Something a structure may take: a child of the parent as it is now, or a row proposed just before, as one.
    private struct Item {
        var node: LayerNode
        /// New, or a row holding a new one.
        var isNew: Bool
        /// Its place among the parent's children; a row proposed just before takes its frontmost member's.
        var place: Int
        var frame: CGRect { node.frame }
    }

    /// Something that may lie between two members: a visible child's turned shape, or a row proposed just before.
    private struct Obstacle {
        var id: UUID
        var shape: CGRect
    }

    /// A run that qualifies: its items in reading order, the line they share, and its gaps.
    private struct Candidate {
        var items: [Int]
        var line: Line
        var gaps: [CGFloat]
        var confidence: Double
    }

    private struct Pass {
        let parent: LayerNode
        let new: Set<UUID>
        let tokens: DesignTokens
        let mode: Mode
        let measure: TextMeasure
        let depth: Int
        /// Where each of the parent's children is now.
        let origins: [UUID: CGPoint]

        init(parent: LayerNode, new: Set<UUID>, tokens: DesignTokens, mode: Mode, measure: TextMeasure, depth: Int) {
            self.parent = parent
            self.new = new
            self.tokens = tokens
            self.mode = mode
            self.measure = measure
            self.depth = depth
            origins = Dictionary(parent.children.map { ($0.id, $0.frame.origin) }, uniquingKeysWith: { first, _ in first })
        }

        /// Rows, then columns over the rows applied and the rest.
        func decisions(_ near: [Int]) -> [Decision] {
            let items = near.map { Item(node: parent.children[$0], isNew: new.contains(parent.children[$0].id), place: $0) }
            let obstacles = parent.children.filter { !$0.isHidden }.map {
                Obstacle(id: $0.id, shape: TreeEdit.shapesBox(of: [$0]) ?? $0.frame)
            }
            let rowRule = Rule.row
            let rows = candidates(among: items, rule: rowRule, obstacles: obstacles).compactMap {
                decision(for: $0, among: items, rule: rowRule)
            }

            let applied = rows.compactMap { decision -> Structure? in
                if case .apply(let row) = decision { row } else { nil }
            }
            let inRows = Set(applied.flatMap(\.members))
            let places = Dictionary(items.map { ($0.node.id, $0.place) }, uniquingKeysWith: { first, _ in first })
            let columnItems = applied.map { row in
                Item(node: row.container, isNew: row.members.contains(where: new.contains),
                     place: row.members.compactMap { places[$0] }.max() ?? 0)
            } + items.filter { !inRows.contains($0.node.id) }
            let columnObstacles = obstacles.filter { !inRows.contains($0.id) }
                + applied.map { Obstacle(id: $0.container.id, shape: $0.container.frame) }
            let columnRule = Rule.column(mode)
            let columns = candidates(among: columnItems, rule: columnRule, obstacles: columnObstacles).compactMap {
                decision(for: $0, among: columnItems, rule: columnRule)
            }

            // A row offered whose members a column now holds couldn't be built after it.
            let taken = Set(columns.flatMap { decision -> [UUID] in
                if case .apply(let column) = decision { column.members } else { [] }
            })
            let kept = rows.filter { decision in
                if case .offer(let row) = decision { taken.isDisjoint(with: row.members) } else { true }
            }
            return kept + columns
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
                    return (rule.start(x), rule.startAcross(x), items[a].place) < (rule.start(y), rule.startAcross(y), items[b].place)
                }
                let runs = order.indices.compactMap { run(from: $0, in: order, items: items, rule: rule, obstacles: obstacles) }
                guard let best = runs.min(by: { ranks($0, before: $1, items: items) }) else { break }
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
                  let line = lines.enumerated().min(by: { a, b in
                      (error(frames.map(a.element.position)) / a.element.tolerance, a.offset)
                          < (error(frames.map(b.element.position)) / b.element.tolerance, b.offset)
                  })?.element
            else { return nil }
            return Candidate(items: run, line: line, gaps: gaps, confidence: confidence(frames, line: line, gaps: gaps, rule: rule))
        }

        /// Never a row holding a row or a column holding a column (F5), nor a member's subtree past depth 32 (F9):
        /// inside the new container a member sits two below the parent.
        private func mayHold(_ item: Item, _ rule: Rule) -> Bool {
            if item.node.kind == .group, case .stack(let stack) = item.node.resolvedLayout, stack.axis == rule.axis { return false }
            return depth + 2 + TreeEdit.levels(below: item.node) <= TreeRules.maximumDepth
        }

        private func ranks(_ a: Candidate, before b: Candidate, items: [Item]) -> Bool {
            if a.items.count != b.items.count { return a.items.count > b.items.count }
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            let (x, y) = (items[a.items[0]], items[b.items[0]])
            return (x.frame.minY, x.frame.minX, x.place) < (y.frame.minY, y.frame.minX, y.place)
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

        // MARK: Proposals

        /// The rhythm's spacing, else the exact median gap, else an offer with the rhythm's (My call 16).
        private func decision(for candidate: Candidate, among items: [Item], rule: Rule) -> Decision? {
            let gap = median(candidate.gaps)
            let rhythm = proposal(candidate, among: items, rule: rule, spacing: tokens.spacing(nearest: gap))
            let exactGap = gap.rounded()
            let exact = spacing(of: rhythm) == exactGap
                ? rhythm : proposal(candidate, among: items, rule: rule, spacing: exactGap)
            switch decide(confidence: candidate.confidence, rhythmMove: rhythm.movement, medianMove: exact.movement, mode: mode) {
            case .applyRhythm?: return .apply(rhythm)
            case .applyMedian?: return .apply(exact)
            case .offer?: return .offer(rhythm)
            case nil: return nil
            }
        }

        /// The container as the engine lays it out: it starts at the first member, with the shared line at the
        /// members' median, in whole points.
        private func proposal(_ candidate: Candidate, among items: [Item], rule: Rule, spacing: CGFloat) -> Structure {
            let members = candidate.items.map { items[$0].node }
            var container = LayerNode(kind: .group)
            container.layout = .stack(LayerNode.Stack(axis: rule.axis, spacing: spacing, alignment: candidate.line.alignment))
            container.width = LayerNode.Sizing(.fit)
            container.height = LayerNode.Sizing(.fit)
            // Each member is fixed, so where the stack puts it depends on its size alone: the engine lays out a leaf
            // of that size in its place, in a free parent as it will be. So nothing inside a member is laid out, and
            // no id the pass doesn't throw away is counted as laid out (F7).
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
            container.id = containerID(rule.kind, members: members.map(\.id))
            container.children = zip(members, container.children).map { member, standIn in
                var member = member
                member.width.mode = .fixed
                member.height.mode = .fixed
                member.frame = standIn.frame
                return member
            }

            let frames = members.map(\.frame)
            let along = snap(rule.start(frames[0]))
            let across = snap(median(frames.map(candidate.line.position)) - candidate.line.share * rule.across(container.frame))
            container.frame.origin = rule.axis == .horizontal ? CGPoint(x: along, y: across) : CGPoint(x: across, y: along)
            container.sketch = LayerNode.SketchIntent(
                originalBounds: container.frame, normalizedBounds: .zero, confidence: candidate.confidence,
                decidedBy: .structure, placement: .fixed)
            let origin = container.frame.origin
            let movement = container.children.map { moved($0, to: origin.offset(by: $0.frame.origin)) }.max() ?? 0
            return Structure(kind: rule.kind, parent: parent.id, members: members.map(\.id), container: container,
                             confidence: candidate.confidence, movement: movement)
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

private extension CGPoint {
    func offset(by other: CGPoint) -> CGPoint { CGPoint(x: x + other.x, y: y + other.y) }
}
