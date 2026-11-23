import CoreGraphics
import Foundation

/// What holds a node, or is to hold one: a container, a screen (its root), or the open canvas's
/// top level.
enum NodeParent: Hashable, Sendable {
    case node(UUID)
    /// That screen's root.
    case screen(TreeScreen.ID)
    case canvas
}

/// Pure edits on nodes, which the store's verbs on the tree are made of. Like the rest of the
/// tree's code it builds on macOS too: no UIKit and no SwiftUI.
enum TreeEdit {
    /// Left to right for a horizontal stack, top to bottom for a vertical one; row by row for a grid
    /// (a row starts at the topmost remaining node and takes those whose midY lies within its vertical extent).
    /// Nodes level on the stack's axis go by the other axis, then as given. A free or overlay layout
    /// keeps the order given, which is the stacking order.
    static func readingOrder(_ nodes: [LayerNode], for layout: LayerNode.Layout) -> [LayerNode] {
        switch layout {
        case .free, .overlay:
            return nodes
        case .stack(let stack):
            let horizontal = stack.axis == .horizontal
            return sorted(nodes) { horizontal ? ($0.frame.minX, $0.frame.minY) : ($0.frame.minY, $0.frame.minX) }
        case .grid:
            var remaining = Array(nodes.indices), order: [LayerNode] = []
            while let top = remaining.min(by: { (nodes[$0].frame.minY, nodes[$0].frame.minX) < (nodes[$1].frame.minY, nodes[$1].frame.minX) }) {
                let extent = nodes[top].frame
                // The topmost always starts its row, whatever its numbers, so that every pass takes one at least.
                let row = remaining.filter { $0 == top || (nodes[$0].frame.midY >= extent.minY && nodes[$0].frame.midY <= extent.maxY) }
                order += sorted(row.map { nodes[$0] }) { ($0.frame.minX, $0.frame.minY) }
                remaining.removeAll { row.contains($0) }
            }
            return order
        }
    }

    /// The node and everything in it, each with a new id. Nothing else changes.
    static func copyWithNewIDs(_ node: LayerNode) -> LayerNode {
        var copy = node
        copy.id = UUID()
        copy.children = node.children.map(copyWithNewIDs)
        return copy
    }

    /// Gives each node below `node`, in reading order, whose id `isTaken` or that a node before it has a
    /// new id. `node` keeps its own, which counts as had.
    static func renewIDs(below node: inout LayerNode, isTaken: (UUID) -> Bool) {
        var had: Set<UUID> = [node.id]
        renewIDs(below: &node, had: &had, isTaken: isTaken)
    }

    private static func renewIDs(below node: inout LayerNode, had: inout Set<UUID>, isTaken: (UUID) -> Bool) {
        for index in node.children.indices {
            if isTaken(node.children[index].id) || had.contains(node.children[index].id) { node.children[index].id = UUID() }
            had.insert(node.children[index].id)
            renewIDs(below: &node.children[index], had: &had, isTaken: isTaken)
        }
    }

    /// `nodes` sorted by `key`, those of equal keys in the order given.
    private static func sorted(_ nodes: [LayerNode], by key: (LayerNode) -> (CGFloat, CGFloat)) -> [LayerNode] {
        nodes.enumerated()
            .map { (key: key($0.element), place: $0.offset, node: $0.element) }
            .sorted { ($0.key.0, $0.key.1, $0.place) < ($1.key.0, $1.key.1, $1.place) }
            .map(\.node)
    }

    // MARK: - What a subtree holds

    /// How many levels a subtree goes below its top: 0 for a node with no children.
    static func levels(below node: LayerNode) -> Int {
        node.children.reduce(0) { max($0, 1 + levels(below: $1)) }
    }

    /// How many nodes a subtree holds, its top included.
    static func count(of node: LayerNode) -> Int {
        node.children.reduce(1) { $0 + count(of: $1) }
    }

    /// Whether the subtree holds a node `isFound` picks, its top included.
    static func holds(_ node: LayerNode, where isFound: (LayerNode) -> Bool) -> Bool {
        isFound(node) || node.children.contains { holds($0, where: isFound) }
    }

    /// Every id in the subtree, its top's included, in reading order: one appears twice only in a damaged design.
    static func ids(in node: LayerNode) -> [UUID] {
        var ids: [UUID] = []
        func visit(_ node: LayerNode) {
            ids.append(node.id)
            node.children.forEach(visit)
        }
        visit(node)
        return ids
    }

    // MARK: - Moving between spaces

    /// The box round nodes' turned shapes in their parent's space, or nil when there are none.
    static func shapesBox(of nodes: [LayerNode]) -> CGRect? {
        nodes.map { node -> CGRect in
            let degrees = node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
            return Rotation.normalized(degrees) == 0 ? node.frame : TurnedRect(rect: node.frame, degrees: degrees).bounds
        }.reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// `children` given to `node` in place of those it has. Each child this build couldn't read keeps its
    /// place among those of the others that stay, so that it is written back where it was.
    static func give(_ children: [LayerNode], to node: inout LayerNode) {
        if !node.unreadChildren.isEmpty {
            let staying = Set(children.map(\.id))
            TreeRules.keepUnreadPlaces(in: &node, removing: node.children.indices.filter { !staying.contains(node.children[$0].id) })
        }
        node.children = children
    }

    /// A path on a host once the node at `removed` on the same host has been taken out: the siblings
    /// after it, and everything in them, are one place earlier.
    static func path(_ path: [Int], afterRemoving removed: [Int]) -> [Int] {
        let level = removed.count - 1
        guard level >= 0, path.count > level, path[..<level].elementsEqual(removed[..<level]),
              path[level] > removed[level] else { return path }
        var moved = path
        moved[level] -= 1
        return moved
    }
}

// MARK: - Changing the tree in place

extension TreeContent {
    /// The children of the node at `path` on `host` (a screen's root at []), or, on the canvas at [],
    /// the canvas's top level. Nil when there is nothing there.
    func children(on host: TreeIndex.Host, at path: [Int]) -> [LayerNode]? {
        if host == .canvas, path.isEmpty { return canvas }
        return node(on: host, at: path)?.children
    }

    /// The node at `path` on `host`: a screen's root at [], a canvas node at [its index, …].
    func node(on host: TreeIndex.Host, at path: [Int]) -> LayerNode? {
        var current: LayerNode
        var rest = path[...]
        switch host {
        case .screen(let id):
            guard let screen = screens.first(where: { $0.id == id }) else { return nil }
            current = screen.root
        case .canvas:
            guard let first = rest.popFirst(), canvas.indices.contains(first) else { return nil }
            current = canvas[first]
        }
        for index in rest {
            guard current.children.indices.contains(index) else { return nil }
            current = current.children[index]
        }
        return current
    }

    /// Changes the node at `path` on `host` in place: only the nodes on its path are copied.
    mutating func changeNode(on host: TreeIndex.Host, at path: [Int], _ body: (inout LayerNode) -> Void) {
        switch host {
        case .screen(let id):
            guard let screen = screens.firstIndex(where: { $0.id == id }) else { return }
            screens[screen].root.changeNode(at: path[...], body)
        case .canvas:
            guard let first = path.first, canvas.indices.contains(first) else { return }
            canvas[first].changeNode(at: path.dropFirst(), body)
        }
    }

    /// Changes the children of the node at `path` on `host`, or, on the canvas at [], the canvas's top
    /// level, in place. A child this build couldn't read keeps its place among the others that stay.
    mutating func changeChildren(on host: TreeIndex.Host, at path: [Int], _ body: (inout [LayerNode]) -> Void) {
        if host == .canvas, path.isEmpty { return body(&canvas) }
        changeNode(on: host, at: path) { node in
            var children = node.children
            body(&children)
            TreeEdit.give(children, to: &node)
        }
    }
}

private extension LayerNode {
    mutating func changeNode(at path: ArraySlice<Int>, _ body: (inout LayerNode) -> Void) {
        guard let first = path.first else { return body(&self) }
        guard children.indices.contains(first) else { return }
        children[first].changeNode(at: path.dropFirst(), body)
    }
}
