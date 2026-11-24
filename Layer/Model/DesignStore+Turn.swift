import CoreGraphics
import Foundation

/// Turning and resizing on the tree: what the knob, the twist, the Rotation field and a handle write. Each reads the
/// store's index and a walk down one node's path, as the canvas's other writes do (`DesignStore+Canvas.swift`), and
/// none lowers the projection. Each write is one change.
extension DesignStore {
    // MARK: Turning

    /// Each node turned about its own middle to an angle on the canvas: its own angle that less its parent's summed
    /// angle, as an element keeps one. Its middle can't move, so its frame is neither worked out again nor written: only
    /// the angle is, and an angle it already has, as an element keeps one, leaves its own as it is. What a thing turned
    /// alone, the Rotation field and turning each of several things on its own pivot write. One change; ids the design
    /// doesn't have, a screen's root, and angles that aren't finite are passed over.
    func setCanvasAngles(_ angles: [UUID: Double]) {
        let memo = index, tree = tree
        var writes: [(host: TreeIndex.Host, path: [Int], rotation: Double?)] = []
        for (id, degrees) in angles where degrees.isFinite {
            guard let entry = memo[id], !entry.path.isEmpty, let posed = memo.posed(id, in: tree) else { continue }
            let angle = Rotation.kept(degrees - posed.parentSpace.degrees)
            if Rotation.kept(posed.node.rotation ?? 0) != angle { writes.append((entry.host, entry.path, angle)) }
        }
        guard !writes.isEmpty else { return }
        changeTree(writing: writes.count) { tree in
            for write in writes {
                tree.changeNode(on: write.host, at: write.path) { $0.rotation = write.rotation }
            }
        }
    }

    /// Each node to its canvas pose: its centre through its parent's inverse transform, its angle less its parent's
    /// summed angle. A laid-out child takes the angle only. One change.
    ///
    /// A centre that hasn't moved leaves the frame as it is. One that has puts the frame's corner on whole points of the
    /// parent's where that space is upright, as moving puts it, and leaves it exactly where it goes under a turned
    /// parent, whose own points are no whole points on the canvas; a drawing, whose ink lies where it was drawn, goes
    /// exactly where it is put. An angle the node already has, as an element keeps one, leaves its own as it is.
    ///
    /// Each of `starts` instead takes the own frame and angle given, as they are: a turn come back round to where it
    /// began (`TurnSession.startsPutBack(turnedBy:)`). A node and something in it aren't both given: each is put through
    /// its parent as it was. Ids the design doesn't have, a screen's root, and poses that aren't finite are passed over.
    func setCanvasPoses(_ poses: [UUID: TurnSession.Pose], puttingBack starts: [UUID: TurnSession.Start] = [:]) {
        let memo = index, tree = tree
        var writes: [(host: TreeIndex.Host, path: [Int], frame: CGRect?, rotation: Double??)] = []
        for (id, pose) in poses {
            guard let entry = memo[id], !entry.path.isEmpty, let posed = memo.posed(id, in: tree) else { continue }
            let node = posed.node
            if let start = starts[id] {
                let frame = start.frame == node.frame ? nil : start.frame
                let rotation: Double?? = start.rotation == node.rotation ? nil : .some(start.rotation)
                if frame != nil || rotation != nil { writes.append((entry.host, entry.path, frame, rotation)) }
                continue
            }
            guard pose.centre.x.isFinite, pose.centre.y.isFinite, pose.degrees.isFinite,
                  let placement = memo.placement(of: id, in: tree) else { continue }
            let angle = Rotation.kept(pose.degrees - posed.parentSpace.degrees)
            let rotation: Double?? = Rotation.kept(node.rotation ?? 0) == angle ? nil : .some(angle)
            var frame: CGRect?
            let isLaidOut = posed.parent.map { $0.resolvedLayout != .free } ?? false
            // Worked out as a pose's centre is (`PlacedNode.canvasShape`), so that a centre that hasn't moved compares equal
            // to the last bit.
            let onCanvas = placement.canvasRect(for: posed.frame)
            let current = CGPoint(x: onCanvas.midX, y: onCanvas.midY)
            if !isLaidOut, pose.centre != current {
                let centre = placement.localPoint(for: pose.centre), size = posed.frame.size
                var local = posed.parentSpace.local(of: CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                                               width: size.width, height: size.height))
                if posed.parentSpace.isUpright, node.kind != .drawing {
                    local.origin = CGPoint(x: local.minX.rounded(), y: local.minY.rounded())
                }
                if local != node.frame { frame = local }
            }
            if frame != nil || rotation != nil { writes.append((entry.host, entry.path, frame, rotation)) }
        }
        guard !writes.isEmpty else { return }
        changeTree(writing: writes.count) { tree in
            for write in writes {
                tree.changeNode(on: write.host, at: write.path) { node in
                    if let frame = write.frame { node.frame = frame }
                    if let rotation = write.rotation { node.rotation = rotation }
                }
            }
        }
    }

    // MARK: Resizing

    /// A laid-out child's handle: each axis whose size changed by more than 0.5 becomes `.fixed` at the new size.
    ///
    /// `start` is the child as the handle's drag began, and each frame is worked out from it alone. An axis within half a
    /// point of its start size is put back as it was then, its size and its sizing (fit, fill or fixed): a finger's wobble
    /// across a handle dragged along the other axis doesn't fix it, and a handle brought back to where it began, however
    /// fast, leaves the child as it was. Its origin is never written: the engine places it (plan 4, call 5). One write;
    /// none for a screen's root, an id the design doesn't have, or a size that isn't finite or is below zero.
    func resizeLaidOut(_ id: UUID, to size: CGSize, from start: LayerNode) {
        guard let entry = index[id], !entry.path.isEmpty, let node = index.node(id, in: tree),
              size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else { return }
        let begun = start.frame.size
        var resized = node
        if abs(size.width - begun.width) > 0.5 {
            resized.width.mode = .fixed
            resized.frame.size.width = size.width
        } else {
            resized.width = start.width
            resized.frame.size.width = begun.width
        }
        if abs(size.height - begun.height) > 0.5 {
            resized.height.mode = .fixed
            resized.frame.size.height = size.height
        } else {
            resized.height = start.height
            resized.frame.size.height = begun.height
        }
        guard resized != node else { return }
        let (width, height, frame) = (resized.width, resized.height, resized.frame)
        changeTree(writing: 1) { tree in
            tree.changeNode(on: entry.host, at: entry.path) { node in
                (node.width, node.height, node.frame.size) = (width, height, frame.size)
            }
        }
    }

    /// A handle on a thing placed freely, which isn't a container: its upright frame in its host's own points, as the
    /// handle's rule gives it, through its parent's inverse transform. Exactly as given: a turned thing's corner across
    /// from the handle stays where it was on the canvas, and the rule already puts an upright one on whole points. One
    /// write; none for a screen's root, an id the design doesn't have, or a frame that isn't finite.
    func resize(_ id: UUID, to ownFrame: CGRect) {
        let memo = index
        guard let entry = memo[id], !entry.path.isEmpty, let posed = memo.posed(id, in: tree),
              [ownFrame.minX, ownFrame.minY, ownFrame.width, ownFrame.height].allSatisfy(\.isFinite),
              ownFrame.width >= 0, ownFrame.height >= 0 else { return }
        let frame = posed.parentSpace.local(of: ownFrame)
        guard frame != posed.node.frame else { return }
        changeTree(writing: 1) { tree in
            tree.changeNode(on: entry.host, at: entry.path) { $0.frame = frame }
        }
    }
}
