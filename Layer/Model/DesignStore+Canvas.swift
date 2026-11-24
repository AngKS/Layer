import CoreGraphics
import Foundation

/// A node where the canvas finds it: what it is, where it is in its host's own points, how those
/// points sit on the canvas, and what holds it. Built from the store's index and one walk down the
/// node's path, never from the projection.
struct PlacedNode: Equatable {
    var ref: DesignStore.ElementRef
    var node: LayerNode
    /// Its own pose: its upright frame in its host's own points, centred on its turned shape's centre.
    var frame: CGRect
    /// Summed with its ancestors', kept from 0 up to 360.
    var degrees: Double
    var placement: Placement
    /// `.free` under a free container, a free root, or at the canvas's top.
    var parentLayout: LayerNode.Layout
    /// With its ancestors.
    var isLocked: Bool
    /// With its ancestors.
    var isHidden: Bool

    /// Whether what holds it lays it out: a row, column, grid or overlay, which places it.
    var isLaidOut: Bool { parentLayout != .free }

    /// Its turned shape on the canvas.
    var canvasShape: TurnedRect {
        TurnedRect(rect: placement.canvasRect(for: frame), degrees: degrees)
    }
}

extension DesignStore.ElementRef.Host {
    /// Where the index has a node.
    init(_ host: TreeIndex.Host) {
        switch host {
        case .screen(let id): self = .screen(id)
        case .canvas: self = .canvas
        }
    }
}

/// The canvas's reads and writes on the tree, beside plan 2's verbs (`DesignStore+Tree.swift`). Each read
/// comes from the store's index, worked out once per version, and a walk down one node's path; none lowers
/// the projection. Each write is one change, made as the store's verbs make theirs.
extension DesignStore {
    // MARK: Reading

    /// A screen as the tree holds it, its root with everything on it.
    func treeScreen(_ id: TreeScreen.ID) -> TreeScreen? {
        tree.screens.first { $0.id == id }
    }

    /// Where a node is, as the selection points at it: its host as the index has it. Nil for a screen's root,
    /// which is the screen rather than a thing on it, and for an id the design doesn't have.
    func ref(of id: UUID) -> ElementRef? {
        guard let entry = index[id], !entry.path.isEmpty else { return nil }
        return ElementRef(host: ElementRef.Host(entry.host), element: id)
    }

    /// A node with where it is: see `PlacedNode`. Nil for a screen's root and an id the design doesn't have.
    func placed(_ id: UUID) -> PlacedNode? {
        let memo = index, tree = tree
        guard let ref = ref(of: id), let entry = memo[id], let posed = memo.posed(id, in: tree),
              let placement = memo.placement(of: id, in: tree) else { return nil }
        return PlacedNode(ref: ref, node: posed.node, frame: posed.frame, degrees: Rotation.kept(posed.degrees) ?? 0,
                          placement: placement, parentLayout: posed.parent?.resolvedLayout ?? .free,
                          isLocked: entry.isLockedWithAncestors, isHidden: entry.isHiddenWithAncestors)
    }

    /// `placed(_:)` for what a ref points at, when it is still where the ref says: nil when it is gone, or
    /// has gone to another host since.
    func placed(_ ref: ElementRef) -> PlacedNode? {
        placed(ref.element).flatMap { $0.ref == ref ? $0 : nil }
    }

    // MARK: Writing

    /// A node's upright frame, given in its host's own points. Under a free parent: through the parent's inverse
    /// transform, its subtree riding along; whole points, drawings exact. Under a laid-out parent: plan 2's call 6
    /// exactly (F20). A size change fixes that axis. An origin change takes it out to its host's root when that root
    /// is free, and is dropped when it isn't (plan 2's F11). One write (`ListWork`).
    ///
    /// A new origin is put on whole points, but for a drawing, whose ink lies where it was drawn; an origin given as
    /// it is stays exactly where it is. A row, column, grid or overlay given a new size under a free parent is fixed
    /// on the axis that changed, so that it keeps it. Taken out, it goes on top of what is on its host's top level
    /// at its angle there, fixed both ways, and on the canvas at its top-level node's scale. Nothing is written for a
    /// screen's root, an id the design doesn't have, or a frame that isn't finite.
    func place(_ id: UUID, at ownFrame: CGRect) {
        let memo = index, tree = tree
        guard let entry = memo[id], let slot = entry.path.last, let posed = memo.posed(id, in: tree),
              [ownFrame.minX, ownFrame.minY, ownFrame.width, ownFrame.height].allSatisfy(\.isFinite),
              ownFrame.width >= 0, ownFrame.height >= 0 else { return }
        let node = posed.node
        var frame = ownFrame
        let isMoved = frame.origin != posed.frame.origin
        if isMoved, node.kind != .drawing { frame.origin = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()) }
        var placed = node

        guard let parent = posed.parent, parent.resolvedLayout != .free else {
            // Under a free container, a free root, or at the canvas's top level.
            placed.frame = posed.parentSpace.local(of: frame)
            if node.isContainer, node.resolvedLayout != .free { Self.fix(&placed, from: node.frame.size, to: frame.size) }
            guard placed != node else { return }
            changeTree(writing: 1) { $0.changeNode(on: entry.host, at: entry.path) { $0 = placed } }
            return
        }

        let hostRootIsFree: Bool = switch entry.host {
        case .screen(let screenID): tree.screens.first { $0.id == screenID }?.root.resolvedLayout ?? .free == .free
        case .canvas: true
        }
        guard isMoved, hostRootIsFree else {
            // Nowhere to take it out to: the origin is dropped, and the engine lays it back.
            Self.fix(&placed, from: node.frame.size, to: frame.size)
            placed.frame.size = frame.size
            guard placed != node else { return }
            changeTree(writing: 1) { $0.changeNode(on: entry.host, at: entry.path) { $0 = placed } }
            return
        }

        // Out to the top of its host, where it was put, at its angle there, fixed both ways.
        placed.frame = frame
        placed.rotation = Rotation.kept(posed.degrees)
        placed.width.mode = .fixed
        placed.height.mode = .fixed
        if entry.host == .canvas, let top = entry.path.first, tree.canvas.indices.contains(top) { placed.scale = tree.canvas[top].scale }
        let taken = placed, from = Array(entry.path.dropLast())
        changeTree(writing: 1) { tree in
            tree.changeChildren(on: entry.host, at: from) { $0.remove(at: slot) }
            tree.changeChildren(on: entry.host, at: []) { $0.append(taken) }
        }
    }

    /// A screen's own fields and its root's layout, in one change; the root's children stay as they are.
    ///
    /// So do the screen's id and its root's, and anything the root holds that this build couldn't read. The tree's
    /// rules then keep the root to the screen's device, and lay it out again if its layout or device changed.
    func updateTreeScreen(_ id: TreeScreen.ID, _ body: (inout TreeScreen) -> Void) {
        guard var screen = treeScreen(id) else { return }
        let before = screen
        body(&screen)
        screen.id = before.id
        screen.root.id = before.root.id
        screen.root.children = before.root.children
        screen.root.unreadChildren = before.root.unreadChildren
        guard screen != before else { return }
        let changed = screen
        apply { content in
            guard let index = content.tree.screens.firstIndex(where: { $0.id == id }) else { return }
            content.tree.screens[index] = changed
        }
    }

    // MARK: How the writes work

    /// `.fixed` on each axis whose size changed.
    private static func fix(_ node: inout LayerNode, from old: CGSize, to new: CGSize) {
        if new.width != old.width { node.width.mode = .fixed }
        if new.height != old.height { node.height.mode = .fixed }
    }
}
