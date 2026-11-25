import CoreGraphics
import Foundation

/// Group as a Row, Column, Grid or Card (call 8), and lining things up inside a laid-out parent, on the tree. The
/// layouts' numbers are `TreeEdit.groupedLayout`'s; what can be grouped is Group's own rule (`groupable`).
extension DesignStore {
    // MARK: Group as

    /// Task 1's `groupable` (one parent, unlocked, no drawings or screens): a card may hold one thing, and all of a
    /// free group is refused only as `.group`. False when the wrap would pass depth 32 or 5,000 nodes (F15).
    func canGroup(_ selection: CanvasSelection, as shape: GroupShape) -> Bool {
        wrappable(selection, as: shape) != nil
    }

    /// One step. Wrapped in reading order (stack, grid, card), each child fixed at its size, the container fitting on
    /// both axes, placed so the first thing in reading order keeps its top-left. Selects nothing; returns the container.
    ///
    /// Nil, and nothing changes, when `canGroup(_:as:)` is false. A group is wrapped as Group wraps one, and nothing
    /// moves. In a row, column, grid or overlay the parent places the new container, so there is no top-left to keep.
    @discardableResult
    func group(_ selection: CanvasSelection, as shape: GroupShape) -> NodeRef? {
        guard let members = wrappable(selection, as: shape) else { return nil }
        // Worked out from the frames `wrap` lays out: on the canvas's top level, in the scale of the frontmost of them.
        var nodes = members.compactMap { node($0) }
        if let front = nodes.last, parent(of: front.id) == .canvas { nodes = Self.held(nodes, drawnAt: front.scale) }
        let layout = TreeEdit.groupedLayout(of: nodes, as: shape, rhythm: tree.settings.tokens.rhythm)
        // Where each one's top-left is on the canvas before it is wrapped, for a container that may move them.
        var corners: [UUID: CGPoint] = [:]
        for id in members where layout != .free {
            guard let placed = placed(id) else { continue }
            corners[id] = placed.placement.canvasRect(for: placed.frame).origin
        }
        var made: NodeRef?
        asOneStep {
            guard let id = wrap(members, in: shape.kind, layout: layout), let ref = ref(of: id) else { return }
            made = ref
            if layout != .free { keepFirstInPlace(in: id, from: corners) }
        }
        return made
    }

    /// What `group(_:as:)` wraps, back to front, or nil when it can't.
    private func wrappable(_ selection: CanvasSelection, as shape: GroupShape) -> [UUID]? {
        guard let members = groupable(selection, minimum: shape == .card ? 1 : 2, refusingAllOfAFreeGroup: shape == .group)
        else { return nil }
        // `wrap`'s own refusals: one node more, and one level more below their parent.
        let memo = index, tree = tree
        guard memo.count < TreeRules.maximumNodes else { return nil }
        for id in members {
            guard let entry = memo[id], let node = memo.node(id, in: tree),
                  entry.depth + 1 + TreeEdit.levels(below: node) <= TreeRules.maximumDepth else { return nil }
        }
        return members
    }

    /// Moves a container just made in a free parent so that the first thing it lays out, that shows, is where its
    /// top-left was on the canvas (`corners`). The container moves through its parent's inverse (`place`).
    private func keepFirstInPlace(in id: UUID, from corners: [UUID: CGPoint]) {
        guard let container = placed(id), !container.isLaidOut, container.placement.scale > 0,
              let first = container.node.children.first(where: { !$0.isHidden }), let corner = corners[first.id],
              let now = placed(first.id) else { return }
        let at = now.placement.canvasRect(for: now.frame).origin
        let scale = container.placement.scale
        place(id, at: container.frame.offsetBy(dx: (corner.x - at.x) / scale, dy: (corner.y - at.y) / scale))
    }

    // MARK: Lining up among several things

    /// Align among several things, and of one a row, column, grid or overlay places: when everything shares a laid-out
    /// parent that has the alignment, that parent takes it (`layoutAligned`), as one change; otherwise what sits in a free
    /// parent moves (`alignInFreeParents`). The popover's and the Format panel's Align (`AppModel.lineUpSelection`) and
    /// voice's (`VoiceToolbox.alignTogether`) both come this way (plan 6, Task 7 review M2).
    func lineUp(_ selection: CanvasSelection, _ alignment: ElementLayout.Alignment) {
        if let aligned = layoutAligned(selection, alignment) {
            update(aligned.parent) { $0.layout = aligned.layout }
        } else {
            alignInFreeParents(selection, alignment)
        }
    }

    /// Today's Align among several things (`align(_:_:)`), moving only what sits in a free parent (spec §10): what a row,
    /// column, grid or overlay places stays where it is, and the others line up with it all the same, as they do with a
    /// locked thing.
    func alignInFreeParents(_ selection: CanvasSelection, _ alignment: ElementLayout.Alignment) {
        lineUp(selection, moving: isInAFreeParent) { ElementLayout.aligned($0, alignment) }
    }

    /// Today's Distribute among several things (`distribute(_:_:)`), moving only what sits in a free parent (spec §10).
    func distributeInFreeParents(_ selection: CanvasSelection, _ distribution: ElementLayout.Distribution) {
        lineUp(selection, moving: isInAFreeParent) { ElementLayout.distributed($0, distribution) }
    }

    /// Whether something selected sits in a free parent, a screen's or the open canvas's top level among them, or is a
    /// screen: something `alignInFreeParents` and `distributeInFreeParents` can move.
    func holdsSomethingInAFreeParent(_ selection: CanvasSelection) -> Bool {
        things(in: selection).contains(where: isInAFreeParent)
    }

    /// Whether a thing goes where it is put: a screen, or a thing in a free container, a free root or the open canvas.
    private func isInAFreeParent(_ thing: CanvasSelection) -> Bool {
        guard case .element(let ref) = thing else { return true }
        return placed(ref).map { !$0.isLaidOut } ?? false
    }

    // MARK: Lining up in a laid-out parent

    /// When everything selected shares one laid-out parent: the layout that parent takes from an align button
    /// (a column: left, centres, right → start, centre, end; a row: top, middles, bottom; a grid or overlay: both).
    /// Nil when it doesn't apply, or the parent is free.
    func layoutAligned(_ selection: CanvasSelection, _ alignment: ElementLayout.Alignment) -> (parent: UUID, layout: LayerNode.Layout)? {
        guard let parent = laidOutParent(of: selection), let layout = node(parent)?.resolvedLayout,
              let aligned = Self.layout(layout, aligned: alignment) else { return nil }
        return (parent, aligned)
    }

    /// The row, column, grid or overlay that holds everything selected, a screen's laid-out root included: what places
    /// it, so that Align edits its alignment and Distribute has nothing to space. Nil when what is selected doesn't
    /// share one parent, a screen is among it, or the parent is free.
    func laidOutParent(of selection: CanvasSelection) -> UUID? {
        var shared: NodeParent?
        for thing in things(in: selection) {
            guard case .element(let ref) = thing, let parent = parent(of: ref.node), shared == nil || shared == parent
            else { return nil }
            shared = parent
        }
        let id: UUID? = switch shared {
        case .node(let id): id
        case .screen(let screenID): treeScreen(screenID)?.root.id
        case .canvas, nil: nil
        }
        guard let id, let holder = node(id), holder.isContainer, holder.resolvedLayout != .free else { return nil }
        return id
    }

    /// `layout` with the alignment an align button gives it, or nil when the button lines things up along a row or
    /// column rather than across it, or the layout is free.
    private static func layout(_ layout: LayerNode.Layout, aligned alignment: ElementLayout.Alignment) -> LayerNode.Layout? {
        let (across, down): (LayerNode.Edge3?, LayerNode.Edge3?) = switch alignment {
        case .left: (.start, nil)
        case .centerX: (.center, nil)
        case .right: (.end, nil)
        case .top: (nil, .start)
        case .centerY: (nil, .center)
        case .bottom: (nil, .end)
        }
        func aligned(_ alignment: LayerNode.Alignment) -> LayerNode.Alignment {
            LayerNode.Alignment(horizontal: across ?? alignment.horizontal, vertical: down ?? alignment.vertical)
        }
        switch layout {
        case .free:
            return nil
        case .stack(var stack):
            guard let edge = stack.axis == .vertical ? across : down else { return nil }
            stack.alignment = LayerNode.CrossAlignment(edge)
            return .stack(stack)
        case .grid(var grid):
            grid.alignment = aligned(grid.alignment)
            return .grid(grid)
        case .overlay(let alignment):
            return .overlay(aligned(alignment))
        }
    }
}
