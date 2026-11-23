import CoreGraphics
import Foundation

/// A lookup over a `TreeContent`, built in one walk over every node (O(N)): where each
/// node sits, its place in the tree, how it maps to its host, and whether it is locked or
/// hidden through an ancestor. It holds no nodes: `node(_:in:)` finds one by its path.
struct TreeIndex: Sendable {
    enum Host: Hashable, Sendable { case screen(TreeScreen.ID), canvas }

    struct Entry: Sendable {
        var host: Host
        var parent: UUID?
        var siblingIndex: Int
        var depth: Int
        /// Child indices from the host's top: a screen's root is `[]`, a canvas node starts
        /// with its index among the canvas nodes.
        var path: [Int]
        /// This node's space to its host's (screen points, or canvas points).
        var toHost: CGAffineTransform
        /// Its frame in the host's space, with its summed angle.
        var hostShape: TurnedRect
        var isLockedWithAncestors: Bool
        var isHiddenWithAncestors: Bool
    }

    private var entries: [UUID: Entry] = [:]

    init(_ content: TreeContent) {
        var count = content.canvas.count + content.screens.count
        for screen in content.screens { count += screen.root.children.count }
        entries.reserveCapacity(count)
        for screen in content.screens {
            walk(screen.root, host: .screen(screen.id), parent: nil, siblingIndex: 0, path: [],
                 parentToHost: nil, parentScale: 1, parentDegrees: 0,
                 locked: screen.isLocked ?? false, hidden: false)
        }
        for (index, node) in content.canvas.enumerated() {
            walk(node, host: .canvas, parent: nil, siblingIndex: index, path: [index],
                 parentToHost: nil, parentScale: 1, parentDegrees: 0, locked: false, hidden: false)
        }
    }

    private mutating func walk(_ node: LayerNode, host: Host, parent: UUID?, siblingIndex: Int, path: [Int],
                               parentToHost: CGAffineTransform?, parentScale: CGFloat, parentDegrees: Double,
                               locked: Bool, hidden: Bool) {
        var toHost = node.transformToParent
        var scale = parentScale
        if let parentToHost {
            toHost = toHost.concatenating(parentToHost)
        } else if host == .canvas {
            let s = node.scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            toHost = toHost.concatenating(CGAffineTransform(scaleX: s, y: s))
            scale = s
        }
        let degrees = parentDegrees + (node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        let centre = CGPoint(x: node.frame.width / 2, y: node.frame.height / 2).applying(toHost)
        let size = CGSize(width: node.frame.width * scale, height: node.frame.height * scale)
        let rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                          width: size.width, height: size.height)
        let isLocked = locked || node.isLocked, isHidden = hidden || node.isHidden
        // A second node of one id, which only a damaged design has, leaves the first its entry;
        // what it holds is still indexed, where it is.
        if entries[node.id] == nil {
            entries[node.id] = Entry(host: host, parent: parent, siblingIndex: siblingIndex, depth: path.count - (host == .canvas ? 1 : 0),
                                     path: path, toHost: toHost, hostShape: TurnedRect(rect: rect, degrees: degrees),
                                     isLockedWithAncestors: isLocked, isHiddenWithAncestors: isHidden)
        }
        for (index, child) in node.children.enumerated() {
            walk(child, host: host, parent: node.id, siblingIndex: index, path: path + [index],
                 parentToHost: toHost, parentScale: scale, parentDegrees: degrees, locked: isLocked, hidden: isHidden)
        }
    }

    subscript(_ id: UUID) -> Entry? { entries[id] }

    var count: Int { entries.count }

    /// Its parent, then that one's parent, up to the top.
    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var next = entries[id]?.parent
        while let current = next {
            result.append(current)
            next = entries[current]?.parent
        }
        return result
    }

    /// The node itself, found by walking its path through `content`.
    func node(_ id: UUID, in content: TreeContent) -> LayerNode? {
        guard let entry = entries[id] else { return nil }
        var path = entry.path[...]
        var current: LayerNode
        switch entry.host {
        case .screen(let screenID):
            guard let screen = content.screens.first(where: { $0.id == screenID }) else { return nil }
            current = screen.root
        case .canvas:
            guard let first = path.popFirst(), content.canvas.indices.contains(first) else { return nil }
            current = content.canvas[first]
        }
        for index in path {
            guard current.children.indices.contains(index) else { return nil }
            current = current.children[index]
        }
        return current.id == id ? current : nil
    }

    /// Its shape on the canvas: a screen's nodes go through the screen's placement.
    func canvasShape(of id: UUID, in content: TreeContent) -> TurnedRect? {
        guard let entry = entries[id] else { return nil }
        switch entry.host {
        case .canvas:
            return entry.hostShape
        case .screen(let screenID):
            guard let screen = content.screens.first(where: { $0.id == screenID }) else { return nil }
            let placement = Placement(origin: screen.origin, scale: screen.scale)
            return TurnedRect(rect: placement.canvasRect(for: entry.hostShape.rect), degrees: entry.hostShape.degrees)
        }
    }
}
