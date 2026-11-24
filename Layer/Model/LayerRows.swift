import Foundation

/// One row of the Layers panel: a node, how far in it is, and what holds it. Given to a row as it is, so a
/// row is built again only when what it shows has changed: never a frame, which changes on every frame of a
/// drag.
struct LayerLine: Equatable, Identifiable, Sendable {
    var id: UUID
    var ref: DesignStore.ElementRef
    var name: String
    var symbol: String
    var depth: Int
    var isContainer: Bool
    var isOpen: Bool
    /// Its own lock and hide.
    var isLocked: Bool
    var isHidden: Bool
    /// Locked, though not by itself: by a container above it.
    var isLockedByAncestor: Bool
    /// Hidden, by itself or by a container above it.
    var isDimmed: Bool
    /// The list the row is in.
    var list: NodeParent
    /// Its list is a row's, column's or grid's: first at the top, as the layout has it.
    var isLayoutOrder: Bool
}

/// What the Layers panel lists, read from the tree and the store's index: no projection is made for it.
enum LayerRows {
    /// A host's rows: its top-level things (a screen's root's children), each open container's children under
    /// it. Free and overlay lists topmost first; rows, columns and grids in layout order. Drawings are left out.
    static func lines(on host: TreeIndex.Host, in content: TreeContent, index: TreeIndex, open: Set<UUID>) -> [LayerLine] {
        var lines: [LayerLine] = []
        var seen: Set<UUID> = []
        func add(_ list: NodeParent, _ children: [LayerNode], layout: LayerNode.Layout, depth: Int) {
            for line in Self.lines(of: children, in: list, layout: layout, depth: depth, index: index, open: open)
            where seen.insert(line.id).inserted {
                lines.append(line)
                guard line.isOpen, let node = index.node(line.id, in: content) else { continue }
                add(.node(line.id), node.children, layout: node.resolvedLayout, depth: depth + 1)
            }
        }
        switch host {
        case .screen(let id):
            guard let root = content.screens.first(where: { $0.id == id })?.root else { return [] }
            add(.screen(id), root.children, layout: root.resolvedLayout, depth: 0)
        case .canvas:
            add(.canvas, content.canvas, layout: .free, depth: 0)
        }
        return lines
    }

    /// The rows of one list alone, none of what is in its containers.
    static func lines(in list: NodeParent, content: TreeContent, index: TreeIndex) -> [LayerLine] {
        let held: (children: [LayerNode], layout: LayerNode.Layout)? = switch list {
        case .screen(let id): content.screens.first { $0.id == id }.map { ($0.root.children, $0.root.resolvedLayout) }
        case .canvas: (content.canvas, .free)
        case .node(let id): index.node(id, in: content).map { ($0.children, $0.resolvedLayout) }
        }
        guard let held else { return [] }
        return lines(of: held.children, in: list, layout: held.layout, depth: 0, index: index, open: [])
    }

    private static func lines(
        of children: [LayerNode], in list: NodeParent, layout: LayerNode.Layout, depth: Int, index: TreeIndex, open: Set<UUID>
    ) -> [LayerLine] {
        let isLayoutOrder = Self.isLayoutOrder(layout)
        let shown = children.filter { $0.kind != .drawing }
        return (isLayoutOrder ? shown : shown.reversed()).compactMap { node in
            line(for: node, in: list, isLayoutOrder: isLayoutOrder, depth: depth, index: index, open: open)
        }
    }

    /// A node's row, or nil when the index doesn't have it.
    static func line(
        for node: LayerNode, in list: NodeParent, isLayoutOrder: Bool = false, depth: Int = 0, index: TreeIndex, open: Set<UUID> = []
    ) -> LayerLine? {
        guard let entry = index[node.id] else { return nil }
        return LayerLine(
            id: node.id, ref: DesignStore.ElementRef(host: DesignStore.ElementRef.Host(entry.host), element: node.id),
            name: node.displayName, symbol: symbol(for: node), depth: depth,
            isContainer: node.isContainer, isOpen: node.isContainer && open.contains(node.id),
            isLocked: node.isLocked, isHidden: node.isHidden,
            isLockedByAncestor: entry.isLockedWithAncestors && !node.isLocked, isDimmed: entry.isHiddenWithAncestors,
            list: list, isLayoutOrder: isLayoutOrder
        )
    }

    /// Whether a layout lists its children first at the top: a row, column or grid. A free container or an
    /// overlay lists them topmost first.
    static func isLayoutOrder(_ layout: LayerNode.Layout) -> Bool {
        switch layout {
        case .stack, .grid: true
        case .free, .overlay: false
        }
    }

    /// A row's "rectangle.split.3x1", a column's "rectangle.split.1x2", a grid's "square.grid.2x2", an overlay's
    /// "square.stack", a card's `ElementKind.card.symbol`, a free group's "rectangle.3.group"; a leaf's own
    /// symbol or its kind's.
    static func symbol(for node: LayerNode) -> String {
        switch node.kind {
        case .card:
            return ElementKind.card.symbol
        case .group:
            switch node.resolvedLayout {
            case .free: return "rectangle.3.group"
            case .stack(let stack): return stack.axis == .horizontal ? "rectangle.split.3x1" : "rectangle.split.1x2"
            case .grid: return "square.grid.2x2"
            case .overlay: return "square.stack"
            }
        default:
            return node.content.symbol.map(SystemSymbol.resolve) ?? node.kind.symbol
        }
    }

    /// The canvas's drawings, topmost first.
    static func drawings(in content: TreeContent) -> [UUID] {
        content.canvas.filter { $0.kind == .drawing }.reversed().map(\.id)
    }

    /// The `before` a drop above `row` means in `list`, for `moveLayer` (which lands it just in front of `before`;
    /// nil is the back). In a topmost-first list, the row itself. In a layout-order list, the row above `row`, or
    /// nil when `row` is first; a drop below the last row (`row` nil) uses `moveLayerToTop` (F22).
    static func before(_ row: UUID?, in list: [LayerLine], layoutOrder: Bool) -> UUID? {
        guard layoutOrder else { return row }
        guard let row, let place = list.firstIndex(where: { $0.id == row }), place > 0 else { return nil }
        return list[place - 1].id
    }

    /// Lands layers in a list just above `row`, keeping their order as given (top to bottom as the panel shows
    /// them) at every drop position; nil is below the last row, which is the back of a topmost-first list and the
    /// front of one in layout order (F22). One step. A `row` that is itself dragged is taken as the next row
    /// that isn't, and the `before` is worked out among the rows that stay, so no dragged layer is refused for
    /// where another was. Refusals are `moveLayer`'s. True when any moved.
    @MainActor @discardableResult
    static func drop(_ ids: [UUID], in list: NodeParent, above row: UUID?, layoutOrder: Bool, store: DesignStore) -> Bool {
        let all = lines(in: list, content: store.tree, index: store.index)
        let moving = Set(ids)
        var row = row
        if let dragged = row, moving.contains(dragged) {
            row = all.drop { $0.id != dragged }.dropFirst().first { !moving.contains($0.id) }?.id
        }
        var moved = false
        store.asOneStep {
            if layoutOrder, row == nil {
                for id in ids { moved = store.moveLayerToTop(id, of: list) || moved }
                return
            }
            let before = before(row, in: all.filter { !moving.contains($0.id) }, layoutOrder: layoutOrder)
            // Each lands just after `before` in a layout-order list, so the last goes first; in a topmost-first
            // list each lands just in front of it, which is above it, so the first does.
            for id in layoutOrder ? ids.reversed() : ids { moved = store.moveLayer(id, to: list, before: before) || moved }
        }
        return moved
    }
}
