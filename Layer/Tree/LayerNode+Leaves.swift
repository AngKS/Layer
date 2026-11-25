import Foundation

// The leaves of a tree in the order a screen listed what it held: depth first, back to front, each container's leaves
// where the container is. Siri shows leaves only, and tests read a screen's contents this way.

extension LayerNode {
    /// Every leaf under it (itself when it is one), depth first, back to front: the order a screen's elements had.
    var leaves: [LayerNode] {
        guard isContainer else { return [self] }
        var found: [LayerNode] = []
        Self.collectLeaves(of: self, into: &found)
        return found
    }

    private static func collectLeaves(of node: LayerNode, into found: inout [LayerNode]) {
        for child in node.children {
            if child.isContainer {
                collectLeaves(of: child, into: &found)
            } else {
                found.append(child)
            }
        }
    }
}

extension TreeContent {
    /// The leaves of a screen's root, in order. None for a screen the design doesn't have.
    func leaves(on screenID: TreeScreen.ID) -> [LayerNode] {
        screens.first { $0.id == screenID }?.root.leaves ?? []
    }

    /// The canvas's nodes' leaves in order, drawings included.
    var canvasLeaves: [LayerNode] { canvas.flatMap(\.leaves) }
}
