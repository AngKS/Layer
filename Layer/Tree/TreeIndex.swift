import CoreGraphics
import Foundation

/// A lookup over a `TreeContent`, built in one walk over every node (O(N)): where each
/// node sits, its place in the tree, how it maps to its host, and whether it is locked or
/// hidden through an ancestor (a screen's own lock isn't one). It holds no nodes: `node(_:in:)`
/// finds one by its path.
///
/// The store keeps one across changes and brings it up to date only where the design changed
/// (`refresh(from:to:)`), so that a change moves no node pays for its own nodes, not the whole design's.
struct TreeIndex: Equatable, Sendable {
    enum Host: Hashable, Sendable { case screen(TreeScreen.ID), canvas }

    struct Entry: Equatable, Sendable {
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
    /// False when the design holds an id twice, which only a damaged design does: the first node of the id has the
    /// entry (see `walk`). Such an index is built again for every version, never brought up to date.
    private(set) var isClean = true

    init(_ content: TreeContent) {
        var count = content.canvas.count + content.screens.count
        for screen in content.screens { count += screen.root.children.count }
        entries.reserveCapacity(count)
        for screen in content.screens {
            // A screen's own lock keeps the screen where it is; what is on it stays editable.
            walk(screen.root, host: .screen(screen.id), parent: nil, siblingIndex: 0, path: [], in: .top)
        }
        for (index, node) in content.canvas.enumerated() {
            walk(node, host: .canvas, parent: nil, siblingIndex: index, path: [index], in: .top)
        }
    }

    /// What a node's children are placed in: its own space to its host's (nil above a host's top), the scale its host
    /// draws it at, its angle summed with its ancestors', and whether it or one of them is locked or hidden.
    private struct Space {
        var toHost: CGAffineTransform?
        var scale: CGFloat
        var degrees: Double
        var isLocked: Bool
        var isHidden: Bool

        /// Above a host's top: a screen's root, or a node on the canvas's top level, which has a scale of its own.
        static let top = Space(toHost: nil, scale: 1, degrees: 0, isLocked: false, isHidden: false)
    }

    /// Where `node` is, placed in `space` on `host`: its space to its host's, its shape there, and the space its own
    /// children are placed in. The one rule for a build and for bringing an index up to date, so both have the same numbers.
    private static func pose(of node: LayerNode, in space: Space, host: Host) -> (toHost: CGAffineTransform, shape: TurnedRect, own: Space) {
        var toHost = node.transformToParent
        var scale = space.scale
        if let parentToHost = space.toHost {
            toHost = toHost.concatenating(parentToHost)
        } else if host == .canvas {
            let s = node.scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            toHost = toHost.concatenating(CGAffineTransform(scaleX: s, y: s))
            scale = s
        }
        let degrees = space.degrees + (node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        let centre = CGPoint(x: node.frame.width / 2, y: node.frame.height / 2).applying(toHost)
        let size = CGSize(width: node.frame.width * scale, height: node.frame.height * scale)
        let rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                          width: size.width, height: size.height)
        let own = Space(toHost: toHost, scale: scale, degrees: degrees, isLocked: space.isLocked || node.isLocked,
                        isHidden: space.isHidden || node.isHidden)
        return (toHost, TurnedRect(rect: rect, degrees: degrees), own)
    }

    private mutating func walk(_ node: LayerNode, host: Host, parent: UUID?, siblingIndex: Int, path: [Int], in space: Space) {
        let pose = Self.pose(of: node, in: space, host: host)
        // A second node of one id, which only a damaged design has, leaves the first its entry;
        // what it holds is still indexed, where it is.
        if entries[node.id] == nil {
            entries[node.id] = Entry(host: host, parent: parent, siblingIndex: siblingIndex, depth: path.count - (host == .canvas ? 1 : 0),
                                     path: path, toHost: pose.toHost, hostShape: pose.shape,
                                     isLockedWithAncestors: pose.own.isLocked, isHiddenWithAncestors: pose.own.isHidden)
        } else {
            isClean = false
        }
        for (index, child) in node.children.enumerated() {
            walk(child, host: host, parent: node.id, siblingIndex: index, path: path + [index], in: pose.own)
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

    /// The node itself, found by walking its path through `content` (`TreeContent.node(on:at:)`).
    func node(_ id: UUID, in content: TreeContent) -> LayerNode? {
        guard let entry = entries[id] else { return nil }
        return content.node(on: entry.host, at: entry.path).flatMap { $0.id == id ? $0 : nil }
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

    // MARK: - Brought up to date

    /// Brings this index, worked out for `old`, up to `new`, as `TreeIndex(new)` would have it, looking only where the
    /// two differ. A list of children, or of the canvas's nodes, shared by both is passed over whole. In one that isn't,
    /// a node at the same place with the same id is followed: its entry is worked out again, with everything inside it,
    /// when its frame, angle, scale, lock or hide changed, or what holds it moved; what is inside it is looked at the
    /// same way. A node at a new place, and one gone from its place, are put in and taken out with everything in them;
    /// so are a screen added and one taken away. Everything else is left as it is. False, and the index is left part
    /// done, for an index of a damaged design, a screen id held twice, or a change that gives a node's id to another:
    /// build it again then.
    mutating func refresh(from old: TreeContent, to new: TreeContent) -> Bool {
        guard isClean else { return false }
        var changes = Changes()
        if !old.screens.isShared(with: new.screens) {
            let roots = Dictionary(old.screens.map { ($0.id, $0.root) }, uniquingKeysWith: { first, _ in first })
            let now = Set(new.screens.map(\.id))
            guard roots.count == old.screens.count, now.count == new.screens.count else { return false }
            for screen in old.screens where !now.contains(screen.id) { changes.taken.append((screen.root, .screen(screen.id))) }
            for screen in new.screens {
                let host = Host.screen(screen.id)
                if let root = roots[screen.id], root.id == screen.root.id {
                    follow(root, to: screen.root, host: host, path: [], in: .top, moved: false, changes: &changes)
                } else {
                    if let root = roots[screen.id] { changes.taken.append((root, host)) }
                    changes.put.append(Put(node: screen.root, host: host, parent: nil, siblingIndex: 0, path: [], space: .top))
                }
            }
        }
        follow(old.canvas, to: new.canvas, of: nil, host: .canvas, path: [], in: .top, moved: false, changes: &changes)
        // Everything taken out first, so that a node moved from one place to another is put in where it is now.
        for (node, host) in changes.taken { forget(node, on: host) }
        for put in changes.put {
            walk(put.node, host: put.host, parent: put.parent, siblingIndex: put.siblingIndex, path: put.path, in: put.space)
        }
        // A node put in where the index already had its id: the design now holds that id twice.
        return isClean
    }

    /// Nodes taken out, with the host each was on, and nodes put in, found while bringing an index up to date.
    private struct Changes {
        var taken: [(node: LayerNode, host: Host)] = []
        var put: [Put] = []
    }

    /// A node put in, with everything in it, where it is now.
    private struct Put {
        var node: LayerNode
        var host: Host
        var parent: UUID?
        var siblingIndex: Int
        var path: [Int]
        var space: Space
    }

    /// Whether what a node's own entry is worked out from is the same in `a` and `b`: its frame, angle, lock and hide,
    /// and its scale on the canvas's top level.
    private static func isPosedAlike(_ a: LayerNode, _ b: LayerNode, onCanvasTop: Bool) -> Bool {
        a.frame == b.frame && a.rotation == b.rotation && a.isLocked == b.isLocked && a.isHidden == b.isHidden
            && (!onCanvasTop || a.scale == b.scale)
    }

    /// Brings the entries of `now` and everything in it up to date from `was`, the node of the same id at the same
    /// place. `space` is what its parent places it in now; `moved`, whether that differs from what it was placed in.
    private mutating func follow(_ was: LayerNode, to now: LayerNode, host: Host, path: [Int], in space: Space, moved: Bool,
                                 changes: inout Changes) {
        let isPosedAlike = Self.isPosedAlike(was, now, onCanvasTop: host == .canvas && path.count == 1)
        if !moved, isPosedAlike, was.children.isShared(with: now.children) { return }
        let posed = moved || !isPosedAlike
        let pose = Self.pose(of: now, in: space, host: host)
        if posed {
            entries[now.id]?.toHost = pose.toHost
            entries[now.id]?.hostShape = pose.shape
            entries[now.id]?.isLockedWithAncestors = pose.own.isLocked
            entries[now.id]?.isHiddenWithAncestors = pose.own.isHidden
        }
        follow(was.children, to: now.children, of: now.id, host: host, path: path, in: pose.own, moved: posed, changes: &changes)
    }

    /// The same for a list of children of the node `parent` at `path`, or of the canvas's top level (`parent` nil, `path`
    /// []), each placed in `space`: one at the same place with the same id is followed, and the rest taken out and put in.
    private mutating func follow(_ before: [LayerNode], to after: [LayerNode], of parent: UUID?, host: Host, path: [Int],
                                 in space: Space, moved: Bool, changes: inout Changes) {
        if !moved, before.isShared(with: after) { return }
        let onCanvasTop = host == .canvas && path.isEmpty
        for index in before.indices where !(after.indices.contains(index) && after[index].id == before[index].id) {
            changes.taken.append((before[index], host))
        }
        for index in after.indices {
            guard before.indices.contains(index), before[index].id == after[index].id else {
                changes.put.append(Put(node: after[index], host: host, parent: parent, siblingIndex: index, path: path + [index],
                                       space: space))
                continue
            }
            if !moved, Self.isPosedAlike(before[index], after[index], onCanvasTop: onCanvasTop),
               before[index].children.isShared(with: after[index].children) { continue }
            follow(before[index], to: after[index], host: host, path: path + [index], in: space, moved: moved, changes: &changes)
        }
    }

    /// Takes `node`'s entry, and those of everything in it, out of the index.
    private mutating func forget(_ node: LayerNode, on host: Host) {
        entries[node.id] = nil
        for child in node.children { forget(child, on: host) }
    }
}

extension LayerNode {
    /// Whether this is `other` as it was, everything in it unchanged: equal, with the very list of children `other`
    /// has, as a version of a design that changed elsewhere holds it. Quick where `==` would compare all it holds. A node
    /// equal to `other` but whose children were written again isn't, and is looked at as one that changed.
    func isUnchanged(from other: LayerNode) -> Bool {
        children.isShared(with: other.children) && self == other
    }
}

extension Array {
    /// Whether this and `other` are one list: shared between two versions of a design, as a list nothing was written
    /// to is, so that nothing in it changed either.
    func isShared(with other: [Element]) -> Bool {
        count == other.count
            && withUnsafeBufferPointer { mine in other.withUnsafeBufferPointer { theirs in mine.baseAddress == theirs.baseAddress } }
    }
}
