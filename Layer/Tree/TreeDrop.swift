import CoreGraphics
import Foundation

/// Where one thing being dragged would go if it were let go now (spec §10, plan 4 calls 3 and 4): into the deepest
/// visible, unlocked row, column or grid under the finger, at the slot its insertion line shows, or placed freely on
/// whatever lies under its centre. Pure, like the rest of the tree's code, and built on macOS too.
enum TreeDrop {
    enum Target: Equatable, Sendable {
        /// Into `parent`, at `index` among its children once the thing has left where it was. `line` is the insertion
        /// line in canvas points, 2 pt across the gap; an empty one shows nothing (an overlay's own child over it, F23).
        case insert(into: NodeParent, at: Int, line: TurnedRect)
        /// Placed freely, as today: on that screen's top level, or the open canvas's.
        case free(on: TreeIndex.Host)
    }

    /// The line of a target that shows none.
    static let noLine = TurnedRect(rect: .zero, degrees: 0)

    /// How far across an insertion line is, in canvas points.
    static let lineWidth: CGFloat = 2

    /// Where `id`, dragged to `point` (canvas points) with its centre at `centre`, would go: the deepest visible,
    /// unlocked row, column or grid under `point` that isn't `id` or inside it, at its slot; otherwise free on the
    /// screen under `centre` (the topmost), or the canvas.
    /// - An empty row, column or grid takes it at slot 0 (F14).
    /// - A container the store would refuse the move into (past depth 32 or 5,000 nodes) is skipped for the next
    ///   candidate, or `.free` (F15).
    /// - An overlay's own child over that overlay goes back to its own index, and no line shows (F23).
    /// - A free container round a thing placed freely keeps it while the finger is in its box (`startBoxes`, as the drag
    ///   began): its member stays its member, placed freely there, and no line shows (spec §10, "Moving something in a
    ///   free container"). Only outside that box is anything further out looked at.
    /// - A thing let go off every container, with its centre over a screen whose root lays things out, takes that
    ///   root's slot at its centre, as it would at the finger.
    ///
    /// The open canvas's things lie over the screens, so its frontmost container under `point` is looked in first;
    /// then the topmost screen under `point`, its root included when that lays things out. A thing that can't go on a
    /// screen (a sticky note, or a container holding one) is placed freely on the canvas, and a drawing goes into no
    /// container, as the store keeps them. Moving changes no count of nodes, so only the depth can refuse it here.
    ///
    /// `startBoxes` are the shapes on the canvas, as the drag began, of the free containers round a thing placed freely:
    /// a free group's box grows round its member as it is dragged, so its box now always holds the finger.
    static func target(for id: UUID, at point: CGPoint, centre: CGPoint, in content: TreeContent, index: TreeIndex,
                       startBoxes: [UUID: TurnedRect] = [:]) -> Target {
        guard let entry = index[id], let node = index.node(id, in: content) else { return .free(on: .canvas) }
        let parentIsFree = entry.parent.flatMap { index.node($0, in: content) }.map { $0.resolvedLayout == .free } ?? true
        let mover = Mover(id: id, parent: entry.parent, siblingIndex: entry.siblingIndex,
                          levels: TreeEdit.levels(below: node),
                          goesOnScreens: !TreeEdit.holds(node) { !$0.kind.belongsOnScreens },
                          holdsDrawing: TreeEdit.holds(node) { $0.kind == .drawing },
                          freeHolders: parentIsFree ? Set(index.ancestors(of: id)) : [])
        let search = Search(mover: mover, point: point, content: content, index: index, startBoxes: startBoxes)

        for top in content.canvas.reversed() where top.isContainer && top.id != id && !top.isHidden {
            guard let entry = index[top.id], search.holds(top, entry: entry, placement: nil) else { continue }
            let scale = Self.drawn(top.scale)
            if let found = search.deepest(in: top, parent: .node(top.id), host: .canvas, placement: nil, scale: scale) {
                return found
            }
            if search.keeps(top) { return .free(on: .canvas) }
            break
        }
        for screen in content.screens.reversed() {
            let device = content.device(of: screen)
            guard screen.canvasFrame(on: device).contains(point) else { continue }
            if let found = search.deepest(in: screen.root, parent: .screen(screen.id), host: .screen(screen.id),
                                          placement: screen.placement, scale: Self.drawn(screen.scale)) {
                return found
            }
            break
        }
        guard mover.goesOnScreens else { return .free(on: .canvas) }
        guard let under = content.screens.last(where: { $0.canvasFrame(on: content.device(of: $0)).contains(centre) })
        else { return .free(on: .canvas) }
        let atCentre = Search(mover: mover, point: centre, content: content, index: index, startBoxes: startBoxes)
        return atCentre.taking(under.root, as: .screen(under.id), host: .screen(under.id), placement: under.placement,
                               scale: Self.drawn(under.scale)) ?? .free(on: .screen(under.id))
    }

    /// The index among `children` without `skipping` that `point` (the container's own space) falls before:
    /// by mid-x in a row, mid-y in a column, and in a grid by row (the point's row band) then mid-x.
    ///
    /// A hidden child, which the engine doesn't lay out, is counted where it is but never decides the slot. A free or
    /// overlay layout, which has no order to fall in, gives the end.
    static func slot(for point: CGPoint, among children: [LayerNode], skipping: UUID, layout: LayerNode.Layout) -> Int {
        let staying = children.filter { $0.id != skipping }
        let isAfter = order(of: staying.filter { !$0.isHidden }, layout: layout, point: point)
        return staying.firstIndex { !$0.isHidden && isAfter($0) } ?? staying.count
    }

    // MARK: - How it is worked out

    /// What is being dragged, as the drop rule needs it.
    private struct Mover {
        var id: UUID
        var parent: UUID?
        var siblingIndex: Int
        /// How many levels it goes below its top.
        var levels: Int
        /// No sticky note, nor anything else that stays on the canvas, in it.
        var goesOnScreens: Bool
        var holdsDrawing: Bool
        /// What holds it, when it is placed freely in its parent: any free container among these keeps it.
        var freeHolders: Set<UUID>
    }

    /// One look for the deepest container under the finger.
    private struct Search {
        let mover: Mover
        /// In canvas points.
        let point: CGPoint
        let content: TreeContent
        let index: TreeIndex
        let startBoxes: [UUID: TurnedRect]

        /// The target in `container` or the deepest container in it under the point: the frontmost child container under
        /// it first, then `container` itself. Nil when neither takes the thing. `placement` is the screen's, nil on the
        /// canvas, where the index's shapes are in canvas points already; `scale` is what the host is drawn at. A free
        /// container round the thing, under the point, keeps it there.
        func deepest(in container: LayerNode, parent: NodeParent, host: TreeIndex.Host, placement: Placement?,
                     scale: CGFloat) -> Target? {
            for child in container.children.reversed() where child.isContainer && !child.isHidden && child.id != mover.id {
                guard let entry = index[child.id], holds(child, entry: entry, placement: placement) else { continue }
                if let found = deepest(in: child, parent: .node(child.id), host: host, placement: placement, scale: scale) {
                    return found
                }
                if keeps(child) { return .free(on: host) }
                break
            }
            return taking(container, as: parent, host: host, placement: placement, scale: scale)
        }

        /// Whether a free container keeps the thing in it, placed freely, while the point is in its box.
        func keeps(_ container: LayerNode) -> Bool {
            container.resolvedLayout == .free && mover.freeHolders.contains(container.id)
        }

        /// Whether the point is in a container's box on the canvas: for one that keeps the thing, its box as the drag
        /// began, which hasn't grown round it.
        func holds(_ container: LayerNode, entry: TreeIndex.Entry, placement: Placement?) -> Bool {
            let shape = keeps(container) ? startBoxes[container.id] ?? canvasShape(of: entry, placement: placement)
                : canvasShape(of: entry, placement: placement)
            return shape.contains(point)
        }

        /// The target `container` gives, if it takes the thing: it lays things out (or is the overlay the thing is in),
        /// isn't locked, and the store would move the thing into it.
        func taking(_ container: LayerNode, as parent: NodeParent, host: TreeIndex.Host, placement: Placement?,
                            scale: CGFloat) -> Target? {
            guard let entry = index[container.id], !entry.isLockedWithAncestors, !entry.isHiddenWithAncestors,
                  entry.depth + 1 + mover.levels <= TreeRules.maximumDepth, !mover.holdsDrawing else { return nil }
            if case .screen = host, !mover.goesOnScreens { return nil }
            let layout = container.resolvedLayout
            switch layout {
            case .free:
                return nil
            case .overlay:
                guard container.id == mover.parent else { return nil }
                return .insert(into: parent, at: mover.siblingIndex, line: TreeDrop.noLine)
            case .stack, .grid:
                var own = placement.map { $0.localPoint(for: point) } ?? point
                own = own.applying(entry.toHost.inverted())
                let at = TreeDrop.slot(for: own, among: container.children, skipping: mover.id, layout: layout)
                let line = TreeDrop.line(at: own, in: container, skipping: mover.id)
                return .insert(into: parent, at: at, line: turned(line, entry: entry, placement: placement, scale: scale))
            }
        }

        /// A rect in a container's own space as a turned rect on the canvas, `lineWidth` across.
        private func turned(_ line: CGRect, entry: TreeIndex.Entry, placement: Placement?, scale: CGFloat) -> TurnedRect {
            var centre = CGPoint(x: line.midX, y: line.midY).applying(entry.toHost)
            if let placement { centre = placement.canvasPoint(for: centre) }
            let isAcross = line.width <= line.height
            let size = isAcross ? CGSize(width: TreeDrop.lineWidth, height: line.height * scale)
                : CGSize(width: line.width * scale, height: TreeDrop.lineWidth)
            return TurnedRect(rect: CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                           width: size.width, height: size.height),
                              degrees: entry.hostShape.degrees)
        }

        private func canvasShape(of entry: TreeIndex.Entry, placement: Placement?) -> TurnedRect {
            guard let placement else { return entry.hostShape }
            return TurnedRect(rect: placement.canvasRect(for: entry.hostShape.rect), degrees: entry.hostShape.degrees)
        }
    }

    /// Whether a child comes after `point`, by the rule of `layout`, given the children that stay and show.
    private static func order(of shown: [LayerNode], layout: LayerNode.Layout, point: CGPoint) -> (LayerNode) -> Bool {
        switch layout {
        case .free, .overlay:
            return { _ in false }
        case .stack(let stack):
            return stack.axis == .horizontal ? { point.x < $0.frame.midX } : { point.y < $0.frame.midY }
        case .grid:
            let rows = TreeEdit.readingRows(shown)
            var rowOf: [UUID: Int] = [:]
            for (number, row) in rows.enumerated() { for node in row { rowOf[node.id] = number } }
            let band = band(of: point, in: rows)
            return { node in
                let row = rowOf[node.id] ?? 0
                return row > band || (row == band && point.x < node.frame.midX)
            }
        }
    }

    /// The row a point is in: the last whose top is at or above it, or the first.
    private static func band(of point: CGPoint, in rows: [[LayerNode]]) -> Int {
        rows.lastIndex { row in (row.map(\.frame.minY).min() ?? 0) <= point.y } ?? 0
    }

    /// The insertion line in a row, column or grid's own space, at the slot `point` gives: across the gap between the
    /// two children it falls between, or half a gap outside the first or last, and as long as the children beside it
    /// reach (the point's row of a grid), or the container's inside when it holds nothing that shows.
    private static func line(at point: CGPoint, in container: LayerNode, skipping: UUID) -> CGRect {
        let shown = container.children.filter { $0.id != skipping && !$0.isHidden }
        let padding = container.padding
        let inside = CGRect(x: padding.leading, y: padding.top,
                            width: max(container.frame.width - padding.leading - padding.trailing, 0),
                            height: max(container.frame.height - padding.top - padding.bottom, 0))
        switch container.resolvedLayout {
        case .stack(let stack) where stack.axis == .horizontal:
            let isAfter = order(of: shown, layout: container.resolvedLayout, point: point)
            return across(shown, splitBy: isAfter, spacing: stack.spacing, inside: inside, isRow: true)
        case .stack(let stack):
            let isAfter = order(of: shown, layout: container.resolvedLayout, point: point)
            return across(shown, splitBy: isAfter, spacing: stack.spacing, inside: inside, isRow: false)
        case .grid(let grid):
            let rows = TreeEdit.readingRows(shown)
            guard !rows.isEmpty else { return across([], splitBy: { _ in false }, spacing: 0, inside: inside, isRow: true) }
            let row = rows[band(of: point, in: rows)]
            return across(row, splitBy: { point.x < $0.frame.midX }, spacing: grid.columnSpacing, inside: inside, isRow: true)
        case .free, .overlay:
            return .zero
        }
    }

    /// The line between the last of `nodes` before the split and the first after it, in a row (`isRow`) or a column.
    private static func across(_ nodes: [LayerNode], splitBy isAfter: (LayerNode) -> Bool, spacing: CGFloat,
                               inside: CGRect, isRow: Bool) -> CGRect {
        let split = nodes.firstIndex(where: isAfter) ?? nodes.count
        let before = split > 0 ? nodes[split - 1].frame : nil
        let after = split < nodes.count ? nodes[split].frame : nil
        let along: CGFloat = switch (before, after) {
        case let (before?, after?): isRow ? (before.maxX + after.minX) / 2 : (before.maxY + after.minY) / 2
        case let (before?, nil): isRow ? before.maxX + spacing / 2 : before.maxY + spacing / 2
        case let (nil, after?): isRow ? after.minX - spacing / 2 : after.minY - spacing / 2
        case (nil, nil): isRow ? inside.minX : inside.minY
        }
        let reach = nodes.map(\.frame).reduce(nil as CGRect?) { $0?.union($1) ?? $1 } ?? inside
        return isRow ? CGRect(x: along, y: reach.minY, width: 0, height: reach.height)
            : CGRect(x: reach.minX, y: along, width: reach.width, height: 0)
    }

    /// A scale as it is drawn: 1 for none, or one that isn't a size.
    private static func drawn(_ scale: CGFloat?) -> CGFloat {
        scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
    }
}
