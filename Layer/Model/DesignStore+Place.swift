import CoreGraphics
import Foundation

// The library's drop on the tree (plan 6, F2): what the flat store's placing of an element and the app's `add(_:at:)`
// did together, for a node.

extension DesignStore {
    /// A new node centred on `point` (canvas points), as the library drops it. For a kind that belongs on screens, the
    /// topmost screen holding the point takes it: a free root centred and clamped inside as today, a laid-out root
    /// appended (as Siri's Add Element, call 5). Otherwise the canvas, at `looseScale`. One step. Nil if refused.
    ///
    /// Only the size of `node.frame` is read. On a free root its corner goes on whole points of the screen's, kept
    /// inside the screen's edges on each axis it fits across; on the canvas, on whole points of its own.
    @discardableResult
    func place(_ node: LayerNode, centredAt point: CGPoint) -> ElementRef? {
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
            return ElementRef(host: .screen(screen.id), element: placed.id)
        }

        let scale = looseScale
        placed.frame.origin = cornered(on: Placement(origin: .zero, scale: scale).localPoint(for: point))
        placed.scale = scale
        guard add(placed, to: .canvas) else { return nil }
        return ElementRef(host: .canvas, element: placed.id)
    }
}
