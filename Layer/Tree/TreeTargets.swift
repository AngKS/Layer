import CoreGraphics
import Foundation

/// What can be touched on the canvas, host by host: each thing a tap, a drag or the pen can land on, with its turned
/// shape in canvas points. Hit-testing reads these rather than the things themselves (`AppModel.hoverTarget`), and the
/// canvas builds a target view for each (`ElementTargets`).
///
/// Any container is one target until it has been gone into (something in it is selected): a tap anywhere in its box
/// is on it, and finds the thing in it there (`leaf(at:in:content:index:)`), or the container itself in a gap. One
/// gone into gives way to what it holds, each a target of its own, and so on down. A screen's root is always gone into.
struct TreeTargets: Equatable, Sendable {
    struct Target: Equatable, Sendable {
        var id: UUID
        /// In canvas points.
        var shape: TurnedRect
        var isContainer: Bool
        /// By its own flag or a container's above it: it doesn't drag.
        var isLocked: Bool
    }

    /// Each host's targets, back to front as drawn. A container not entered is one target, picked by its box; one
    /// entered gives way to its children; a screen's root is always entered. Hidden things, unlocked drawings and
    /// containers with nothing showing have none: no visible leaf and no look of their own. A card has a look, and
    /// an empty row, column, grid or overlay is picked by its box (F14). On the canvas, locked drawings come last.
    /// A host with nothing to touch has no entry.
    private(set) var hosts: [TreeIndex.Host: [Target]] = [:]

    /// One walk over each host, in the order its things are drawn.
    init(_ content: TreeContent, index: TreeIndex, entered: Set<UUID>) {
        for screen in content.screens {
            var found: [Target] = []
            let placement = screen.placement
            let root = TreeIndex.OwnSpace.host.placing(screen.root).space
            for child in screen.root.children {
                Self.collect(child, in: root, at: placement, entered: entered, index: index, into: &found)
            }
            if !found.isEmpty { hosts[.screen(screen.id)] = found }
        }
        var floating: [Target] = []
        for node in content.canvas {
            Self.collect(node, in: .host, at: Self.placement(of: node), entered: entered, index: index, into: &floating)
        }
        // The canvas draws a drawing, which can only be touched while it is locked, above everything else there:
        // hit order is draw order.
        let drawings = Set(content.canvas.lazy.filter { $0.kind == .drawing }.map(\.id))
        if !drawings.isEmpty {
            floating = floating.filter { !drawings.contains($0.id) } + floating.filter { drawings.contains($0.id) }
        }
        if !floating.isEmpty { hosts[.canvas] = floating }
    }

    /// `node`'s targets, appended to `found`: its own, or, gone into, those of what it holds.
    private static func collect(_ node: LayerNode, in space: TreeIndex.OwnSpace, at placement: Placement,
                                entered: Set<UUID>, index: TreeIndex, into found: inout [Target]) {
        // Hidden, it is looked through, and so is everything in it.
        guard !node.isHidden else { return }
        let placed = space.placing(node)
        if node.isContainer, entered.contains(node.id) {
            for child in node.children {
                collect(child, in: placed.space, at: placement, entered: entered, index: index, into: &found)
            }
            return
        }
        // A drawing's ink is picked, not its frame, unless it is locked: then it is off the ink canvas.
        guard node.kind != .drawing || node.isLocked, !node.isContainer || isShowing(node) else { return }
        found.append(Target(
            id: node.id, shape: canvasShape(placed, at: placement), isContainer: node.isContainer,
            isLocked: index[node.id]?.isLockedWithAncestors ?? node.isLocked
        ))
    }

    /// Whether a node that isn't hidden has something showing: a leaf, a card's look, an empty row, column, grid or
    /// overlay's box (F14), or any of these inside it. A free group with nothing showing in it has nothing to touch.
    private static func isShowing(_ node: LayerNode) -> Bool {
        guard node.isContainer else {
            #if DEBUG
            GroupWork.leafLookedAt()
            #endif
            return true
        }
        if node.kind == .card || (node.resolvedLayout != .free && node.children.isEmpty) { return true }
        return node.children.contains { !$0.isHidden && isShowing($0) }
    }

    /// The topmost visible leaf inside `container` holding a canvas point, at any depth; nil in a gap.
    ///
    /// Only that container's subtree is looked at, front to back. Drawings are never inside one.
    static func leaf(at point: CGPoint, in container: UUID, content: TreeContent, index: TreeIndex) -> UUID? {
        #if DEBUG
        GroupWork.leafWalked()
        #endif
        guard let entry = index[container], !entry.isHiddenWithAncestors, let posed = index.posed(container, in: content),
              posed.node.isContainer, let placement = index.placement(of: container, in: content) else { return nil }
        func search(_ node: LayerNode, in space: TreeIndex.OwnSpace) -> UUID? {
            for child in node.children.reversed() where !child.isHidden && child.kind != .drawing {
                let placed = space.placing(child)
                if child.isContainer {
                    if let found = search(child, in: placed.space) { return found }
                } else if canvasShape(placed, at: placement).contains(point) {
                    return child.id
                }
            }
            return nil
        }
        return search(posed.node, in: posed.parentSpace.placing(posed.node).space)
    }

    /// A node placed in its host's own points, on the canvas: its upright frame turned by its summed angle, as an
    /// element on the canvas is (`PlacedNode.canvasShape`).
    private static func canvasShape(_ placed: TreeIndex.OwnSpace.Placed, at placement: Placement) -> TurnedRect {
        TurnedRect(rect: placement.canvasRect(for: placed.frame), degrees: Rotation.kept(placed.degrees) ?? 0)
    }

    /// How a top-level canvas node's own points sit on the canvas: at its scale, or 1 for one that isn't a size.
    private static func placement(of node: LayerNode) -> Placement {
        Placement(origin: .zero, scale: node.scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1)
    }
}

#if DEBUG
/// How much of the design the canvas's own questions about containers walk: for the tests that hold working out what
/// can be touched to one walk of each host, and a tap in a container to a walk of that container alone. Counted on the
/// main thread alone, where the canvas asks. The count only grows: a test measures the difference it makes.
enum GroupWork {
    nonisolated(unsafe) private(set) static var leafWalks = 0
    /// Leaves that working out what can be touched looked at to find whether a container has something showing
    /// (`TreeTargets.isShowing`): the first that shows in each, not every one it holds.
    nonisolated(unsafe) private(set) static var leavesLookedAt = 0

    static func leafWalked() {
        guard Thread.isMainThread else { return }
        leafWalks += 1
    }

    static func leafLookedAt() {
        guard Thread.isMainThread else { return }
        leavesLookedAt += 1
    }
}
#endif
