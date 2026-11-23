import Foundation

extension LayerNode {
    /// Nodes below this one that aren't containers, hidden or not.
    var leafCount: Int {
        children.reduce(0) { count, child in count + (child.isContainer ? 0 : 1) + child.leafCount }
    }
}
