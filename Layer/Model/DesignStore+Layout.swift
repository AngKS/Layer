import CoreGraphics
import Foundation

/// What the Format panel's layout picker offers: how a container places what it holds.
enum LayoutChoice: String, CaseIterable, Sendable {
    case free, row, column, grid, overlay

    init(_ layout: LayerNode.Layout) {
        switch layout {
        case .free: self = .free
        case .stack(let stack): self = stack.axis == .horizontal ? .row : .column
        case .grid: self = .grid
        case .overlay: self = .overlay
        }
    }

    var title: String {
        switch self {
        case .free: "Free"
        case .row: "Row"
        case .column: "Column"
        case .grid: "Grid"
        case .overlay: "Overlay"
        }
    }

    /// What a container can be: a screen's root is free or a column, and nothing else.
    static func choices(forScreenRoot: Bool) -> [LayoutChoice] {
        forScreenRoot ? [.free, .column] : allCases
    }

    /// The layout this choice makes of a container now laid out as `current`, holding `children`.
    /// - Row and column keep a stack's spacing, alignment and justify, and turn its axis.
    /// - From anything else, a row, column or grid takes the layout Group as would give `children`: a grid already a
    ///   grid keeps its columns and spacing.
    /// - An overlay is centred; one already an overlay keeps its alignment.
    func layout(from current: LayerNode.Layout, children: [LayerNode], rhythm: [CGFloat]) -> LayerNode.Layout {
        switch self {
        case .free:
            return .free
        case .overlay:
            if case .overlay = current { return current }
            return .overlay(LayerNode.Alignment())
        case .row, .column:
            let axis: LayerNode.Axis = self == .row ? .horizontal : .vertical
            if case .stack(var stack) = current {
                stack.axis = axis
                return .stack(stack)
            }
            return TreeEdit.groupedLayout(of: children, as: self == .row ? .row : .column, rhythm: rhythm)
        case .grid:
            if case .grid = current { return current }
            return TreeEdit.groupedLayout(of: children, as: .grid, rhythm: rhythm)
        }
    }
}

/// How a laid-out child takes its size along one axis.
enum SizingChoice: String, CaseIterable, Sendable {
    case fit, fill, fixed

    init(_ sizing: LayerNode.Sizing) {
        switch sizing.mode {
        case .fit: self = .fit
        case .fill: self = .fill
        case .fixed: self = .fixed
        }
    }

    var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .fixed: "Fixed"
        }
    }
}

extension DesignStore {
    /// Spacing, alignment, justify, columns and axis of a laid-out container or a screen's root, as `body` changes them,
    /// in one change. Spacing that isn't a number or is below 0 reads as 0, and columns are kept to 1–12. A free layout
    /// stays free: the choice of layout is `setLayout`'s.
    func updateLayout(_ id: UUID, _ body: (inout LayerNode.Layout) -> Void) {
        guard let current = node(id), current.isContainer, current.resolvedLayout != .free else { return }
        var layout = current.resolvedLayout
        body(&layout)
        layout = Self.clamped(layout)
        guard layout != current.resolvedLayout else { return }
        update(id) { $0.layout = layout }
    }

    /// A container's padding; a side that isn't a number or is below 0 reads as 0.
    func setPadding(_ id: UUID, _ padding: LayerNode.Padding) {
        func side(_ value: CGFloat) -> CGFloat { value.isFinite && value > 0 ? value : 0 }
        guard let current = node(id), current.isContainer else { return }
        let clean = LayerNode.Padding(top: side(padding.top), leading: side(padding.leading),
                                      bottom: side(padding.bottom), trailing: side(padding.trailing))
        guard clean != current.padding else { return }
        update(id) { $0.padding = clean }
    }

    /// One axis of a thing a row, column, grid or overlay lays out: fit to what it holds, fill the room (weight 1), or
    /// fixed at `points`, at its size now when nil. Points that aren't a number, or are below 1, leave its size as it is.
    func setSizing(_ id: UUID, axis: LayerNode.Axis, _ choice: SizingChoice, points: CGFloat? = nil) {
        guard ref(of: id) != nil else { return }
        update(id) { node in
            var sizing = axis == .horizontal ? node.width : node.height
            switch choice {
            case .fit:
                sizing.mode = .fit
            case .fill:
                if case .fill = sizing.mode {} else { sizing.mode = .fill(weight: 1) }
            case .fixed:
                sizing.mode = .fixed
                if let points, points.isFinite, points >= 1 {
                    if axis == .horizontal { node.frame.size.width = points } else { node.frame.size.height = points }
                }
            }
            if axis == .horizontal { node.width = sizing } else { node.height = sizing }
        }
    }

    private static func clamped(_ layout: LayerNode.Layout) -> LayerNode.Layout {
        func spacing(_ value: CGFloat) -> CGFloat { value.isFinite && value > 0 ? value : 0 }
        switch layout {
        case .free, .overlay:
            return layout
        case .stack(var stack):
            stack.spacing = spacing(stack.spacing)
            return .stack(stack)
        case .grid(var grid):
            grid.columns = min(max(grid.columns, 1), 12)
            grid.columnSpacing = spacing(grid.columnSpacing)
            grid.rowSpacing = spacing(grid.rowSpacing)
            return .grid(grid)
        }
    }
}

extension AppModel {
    /// Changes those of `ids` that `applies` to, in the Format panel's own edit (see `adjusting`): the nodes a field was
    /// showing, even if it is set once the selection has moved on. With `unlockedOnly`, only those that aren't locked,
    /// by themselves or by a container above them.
    func changeNodes(_ ids: [UUID], unlockedOnly: Bool = false, where applies: (LayerNode) -> Bool, _ body: (inout LayerNode) -> Void) {
        adjusting {
            for id in ids {
                guard let found = store.placed(id), !unlockedOnly || !found.isLocked, applies(found.node) else { continue }
                store.update(id, body)
            }
        }
    }
}

extension LayerNode {
    /// The fill a card shows: its own, or the design's card fill until it is reset (the tokens' look).
    func shownFill(tokens: DesignTokens) -> RGBColor {
        style.tint ?? (kind == .card ? tokens.card.fill : kind.spec.tint)
    }
}
