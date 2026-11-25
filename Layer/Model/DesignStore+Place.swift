import CoreGraphics
import Foundation

// The library's drop on the tree (plan 6, F2): where a new node goes when it is dropped or added by hand, with the
// app's `add(_:at:)`.

extension DesignStore {
    /// A new node centred on `point` (canvas points), as the library drops it. For a kind that belongs on screens, the
    /// topmost screen holding the point takes it: a free root centred and clamped inside as today, a laid-out root
    /// appended (as Siri's Add Element, call 5). Otherwise the canvas, at `looseScale`. One step. Nil if refused.
    ///
    /// Only the size of `node.frame` is read. On a free root its corner goes on whole points of the screen's, kept
    /// inside the screen's edges on each axis it fits across; on the canvas, on whole points of its own.
    @discardableResult
    func place(_ node: LayerNode, centredAt point: CGPoint) -> NodeRef? {
        var placed = node
        let size = node.frame.size
        func cornered(on centre: CGPoint) -> CGPoint {
            CGPoint(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded())
        }

        if node.kind.belongsOnScreens, let screen = treeScreen(at: point) {
            if screen.root.resolvedLayout == .free {
                let bounds = tree.device(of: screen).size
                var centre = screen.placement.localPoint(for: point)
                let half = CGSize(width: size.width / 2, height: size.height / 2)
                if size.width <= bounds.width { centre.x = min(max(centre.x, half.width), bounds.width - half.width) }
                if size.height <= bounds.height { centre.y = min(max(centre.y, half.height), bounds.height - half.height) }
                placed.frame.origin = cornered(on: centre)
            }
            placed.scale = nil
            guard add(placed, to: .screen(screen.id)) else { return nil }
            return NodeRef(host: .screen(screen.id), node: placed.id)
        }

        let scale = looseScale
        placed.frame.origin = cornered(on: Placement(origin: .zero, scale: scale).localPoint(for: point))
        placed.scale = scale
        guard add(placed, to: .canvas) else { return nil }
        return NodeRef(host: .canvas, node: placed.id)
    }

    /// A new leaf of `kind` for a sketch read off every screen (canvas points): about as large as it was drawn, at the
    /// scale loose things are drawn at (`looseScale`), as its kind's loose size allows, put where the sketch's middle is
    /// (`place(_:centredAt:)`). One step. Nil if refused.
    @discardableResult
    func placeLoose(_ kind: ElementKind, sketchedAs sketch: CGRect) -> NodeRef? {
        var node = LayerNode.standard(kind)
        let scale = looseScale
        let drawn = CGSize(width: sketch.width / scale, height: sketch.height / scale)
        node.frame.size = kind.spec.looseSize.size(from: node.frame.size, drawn: drawn)
        return place(node, centredAt: CGPoint(x: sketch.midX, y: sketch.midY))
    }
}
