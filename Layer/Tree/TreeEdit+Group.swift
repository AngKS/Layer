import CoreGraphics
import Foundation

/// What the popover's Group menu wraps things in: a free group, or a row, column, grid or card that lays them out.
enum GroupShape: String, CaseIterable, Sendable {
    case group, row, column, grid, card

    /// Its name in the menu.
    var title: String {
        switch self {
        case .group: "Group"
        case .row: "Row"
        case .column: "Column"
        case .grid: "Grid"
        case .card: "Card"
        }
    }

    /// The container it makes: a card, or a group, which its layout makes a row, column or grid.
    var kind: ElementKind { self == .card ? .card : .group }
}

extension TreeEdit {
    /// The layout `wrap` gets for siblings, framed in their parent's space, grouped as `shape` (call 8). `.free` for a group.
    ///
    /// - A row's or column's spacing is the rhythm step nearest the median gap between neighbours in reading order. Its
    ///   alignment is the edge across it that they line up on best: the smallest spread of starts, centres and ends, start
    ///   on a tie.
    /// - A grid has as many columns as there are things in its first reading row, 1 to 12. Its column spacing comes from
    ///   the gaps between neighbours in each reading row, and its row spacing from the gaps between the rows. Across, it
    ///   aligns as the things that will share each of its columns line up best; down, as those sharing each of its rows do.
    /// - A card's inside is a row when everything shares one reading row, and a column otherwise.
    ///
    /// With no gap to go by, the spacing is the rhythm's smallest step.
    static func groupedLayout(of nodes: [LayerNode], as shape: GroupShape, rhythm: [CGFloat]) -> LayerNode.Layout {
        switch shape {
        case .group: .free
        case .row: .stack(stack(of: nodes, along: .horizontal, rhythm: rhythm))
        case .column: .stack(stack(of: nodes, along: .vertical, rhythm: rhythm))
        case .grid: .grid(grid(of: nodes, rhythm: rhythm))
        case .card: .stack(stack(of: nodes, along: readingRows(nodes).count == 1 ? .horizontal : .vertical, rhythm: rhythm))
        }
    }

    /// The step of `rhythm` nearest `value`, the smaller on a tie, as the tokens carry a spacing over
    /// (`DesignTokens.step(nearest:in:)`). `value` itself when the rhythm has none.
    static func nearestStep(_ value: CGFloat, in rhythm: [CGFloat]) -> CGFloat {
        DesignTokens.step(nearest: value, in: rhythm)
    }

    // MARK: How the layouts are worked out

    private static func stack(of nodes: [LayerNode], along axis: LayerNode.Axis, rhythm: [CGFloat]) -> LayerNode.Stack {
        let isRow = axis == .horizontal
        let frames = readingOrder(nodes, for: .stack(LayerNode.Stack(axis: axis))).map(\.frame)
        let gaps = zip(frames, frames.dropFirst()).map { isRow ? $1.minX - $0.maxX : $1.minY - $0.maxY }
        let edge = linedUp([frames], horizontally: !isRow)
        return LayerNode.Stack(axis: axis, spacing: nearestStep(median(gaps), in: rhythm),
                               alignment: LayerNode.CrossAlignment(edge))
    }

    private static func grid(of nodes: [LayerNode], rhythm: [CGFloat]) -> LayerNode.Grid {
        let rows = readingRows(nodes).map { $0.map(\.frame) }
        let columns = min(12, max(1, rows.first?.count ?? 1))
        let across = rows.flatMap { row in zip(row, row.dropFirst()).map { $1.minX - $0.maxX } }
        let boxes = rows.map { $0.reduce(CGRect.null) { $0.union($1) } }
        let down = zip(boxes, boxes.dropFirst()).map { $1.minY - $0.maxY }
        // The grid flows them row by row, `columns` to a row.
        let flow = rows.flatMap { $0 }
        let cellColumns = (0..<columns).map { column in stride(from: column, to: flow.count, by: columns).map { flow[$0] } }
        let cellRows = stride(from: 0, to: flow.count, by: columns).map { Array(flow[$0..<min($0 + columns, flow.count)]) }
        return LayerNode.Grid(
            columns: columns, columnSpacing: nearestStep(median(across), in: rhythm), rowSpacing: nearestStep(median(down), in: rhythm),
            alignment: LayerNode.Alignment(horizontal: linedUp(cellColumns, horizontally: true),
                                           vertical: linedUp(cellRows, horizontally: false))
        )
    }

    /// The edge each set of frames lines up on best, across (`horizontally`) or down: the smallest spread of their
    /// starts, centres and ends, summed over the sets, start on a tie. A spread is the furthest apart two of them are.
    private static func linedUp(_ sets: [[CGRect]], horizontally: Bool) -> LayerNode.Edge3 {
        let edges: [(LayerNode.Edge3, (CGRect) -> CGFloat)] = horizontally
            ? [(.start, \.minX), (.center, \.midX), (.end, \.maxX)]
            : [(.start, \.minY), (.center, \.midY), (.end, \.maxY)]
        var best = LayerNode.Edge3.start, least = CGFloat.infinity
        for (edge, position) in edges {
            let spread = sets.reduce(CGFloat(0)) { total, frames in
                let positions = frames.map(position)
                return total + ((positions.max() ?? 0) - (positions.min() ?? 0))
            }
            // A thousandth of a point is a centre's rounding, not a better line.
            if spread < least - 0.001 { (best, least) = (edge, spread) }
        }
        return best
    }

    /// The middle value, or the mean of the middle two; 0 for none.
    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

extension LayerNode.CrossAlignment {
    /// The same edge across a row or column.
    init(_ edge: LayerNode.Edge3) {
        switch edge {
        case .start: self = .start
        case .center: self = .center
        case .end: self = .end
        }
    }
}
