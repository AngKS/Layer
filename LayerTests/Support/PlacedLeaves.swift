import CoreGraphics
@testable import Layer

/// The leaves under a screen's root, each frame in the screen's points: its origin carried through its containers',
/// none of which is turned.
func placedLeaves(of node: LayerNode, in origin: CGPoint = .zero) -> [(node: LayerNode, frame: CGRect)] {
    let frame = node.frame.offsetBy(dx: origin.x, dy: origin.y)
    return node.isContainer ? node.children.flatMap { placedLeaves(of: $0, in: frame.origin) } : [(node, frame)]
}
