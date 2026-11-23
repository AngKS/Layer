import CoreGraphics
import Foundation

// PROJECTION: deleted in plan 6
/// The tree read as today's flat list, for the code that hasn't moved onto the tree yet.
///
/// Each host is lowered in block order: a container's children first, back to front, then the
/// container itself as a `.group` item just in front of them, which its children point at with
/// `group`. A screen's root isn't lowered, so its children point at nothing. Screens come first, in
/// order, then the canvas. Children this build couldn't read aren't lowered.
///
/// Each element is where its node is in its host's points (on the canvas, its top-level node's own
/// points): its centre carried through its ancestors' moves and turns, its own size, and its angle
/// summed with theirs. Under upright ancestors the origins are added, so whole numbers stay exact.
/// Containers never scale what they hold; on the canvas every node carries its top-level node's scale.
enum TreeProjection {
    // PROJECTION: deleted in plan 6
    struct Pose: Equatable, Sendable {
        var frame: CGRect
        var rotation: Double?
        var scale: CGFloat?
    }

    // PROJECTION: deleted in plan 6
    struct Lowered: Sendable {
        /// The list as it is kept: each element with its own flags, containers as `.group` items, block order.
        var elements: [DesignElement]
        /// Each screen with its leaves, each locked or hidden as it is with its containers. `resolvedDevice`
        /// is left nil here.
        var screens: [DesignScreen]
        /// The canvas's leaves, shown as the screens' are.
        var floating: [FloatingElement]
        /// Each element's index in `elements`; the first, for an identifier held twice.
        var position: [UUID: Int]

        /// What is on a screen, or on the open canvas when `host` is nil, as it is kept, back to front.
        func children(of host: DesignScreen.ID?) -> [DesignElement] {
            elements.filter { $0.parent == host }
        }
    }

    #if DEBUG
    /// Whole designs lowered: counted on the main thread alone, as `ListWork` is, so that a design
    /// lowered elsewhere meanwhile doesn't add to a test's count. It only grows.
    nonisolated(unsafe) private(set) static var lowerings = 0
    #endif

    static func lower(_ content: TreeContent, pending: [UUID: UUID] = [:]) -> Lowered {
        #if DEBUG
        if Thread.isMainThread { lowerings += 1 }
        #endif
        var elements: [DesignElement] = []
        var screens: [DesignScreen] = []
        screens.reserveCapacity(content.screens.count)
        for screen in content.screens {
            var lowering = Lowering(host: screen.id, pending: pending)
            lowering.lowerRoot(screen.root)
            elements += lowering.raw
            var view = Self.view(of: screen)
            view.elements = lowering.shown
            screens.append(view)
        }
        var canvas = Lowering(host: nil, pending: pending)
        canvas.lowerCanvas(content.canvas)
        elements += canvas.raw
        let floating = canvas.shown.map { FloatingElement(element: $0, scale: $0.scale ?? 1) }

        var position: [UUID: Int] = [:]
        position.reserveCapacity(elements.count)
        for (index, element) in elements.enumerated() where position[element.id] == nil {
            position[element.id] = index
        }
        return Lowered(elements: elements, screens: screens, floating: floating, position: position)
    }

    /// A screen as `lower(_:pending:)` shows it, without what is on it.
    static func view(of screen: TreeScreen) -> DesignScreen {
        var view = DesignScreen(id: screen.id, name: screen.name, origin: screen.origin, scale: screen.scale,
                                deviceID: screen.deviceID)
        view.isLocked = screen.isLocked
        view.unknownKeys = screen.unknownKeys
        return view
    }

    /// One host's part of `lower(_:pending:)`'s `elements`: nothing for a screen the design doesn't have.
    static func lowerHost(_ host: TreeIndex.Host, in content: TreeContent, pending: [UUID: UUID] = [:]) -> [DesignElement] {
        lowering(host, in: content, pending: pending, keepsNodes: false)?.raw ?? []
    }

    // PROJECTION: deleted in plan 6
    /// One element of a host's lowering, with the node it was lowered from: what the writes read to write
    /// over each node only what differs, without walking the tree again.
    struct LoweredNode: Sendable {
        /// As it is in the design, with its children.
        var node: LayerNode
        /// As `lowerHost` lowers it: its own flags, its pointer a pending one where there is one.
        var element: DesignElement
        /// The container that holds it in the tree: nil under a screen's root and on the canvas's top level.
        var holder: UUID?
        /// As the views show it: a leaf locked or hidden with its containers, a container as it is lowered.
        var shown: DesignElement
    }

    /// `lowerHost(_:in:pending:)`, each element with the node it came from, in the same order.
    static func lowerHostNodes(_ host: TreeIndex.Host, in content: TreeContent, pending: [UUID: UUID] = [:]) -> [LoweredNode] {
        lowering(host, in: content, pending: pending, keepsNodes: true)?.nodes ?? []
    }

    /// One host lowered, or nil for a screen the design doesn't have.
    private static func lowering(_ host: TreeIndex.Host, in content: TreeContent, pending: [UUID: UUID],
                                 keepsNodes: Bool) -> Lowering? {
        switch host {
        case .screen(let id):
            guard let screen = content.screens.first(where: { $0.id == id }) else { return nil }
            var lowering = Lowering(host: id, pending: pending, keepsNodes: keepsNodes)
            lowering.lowerRoot(screen.root)
            return lowering
        case .canvas:
            var lowering = Lowering(host: nil, pending: pending, keepsNodes: keepsNodes)
            lowering.lowerCanvas(content.canvas)
            return lowering
        }
    }

    /// A node's pose in its host's points (canvas: its top-level node's own points) and that node's scale.
    /// It is found first by its path, then posed along that path alone.
    static func pose(of id: UUID, in content: TreeContent) -> Pose? {
        for screen in content.screens {
            if let path = path(to: id, in: screen.root) {
                return pose(along: path, from: screen.root, scale: nil)
            }
        }
        for node in content.canvas {
            if let path = path(to: id, in: node) {
                return pose(along: path, from: node, scale: node.scale)
            }
        }
        return nil
    }

    /// The child indices from `node` down to the node with `id`, `node` itself first in reading order.
    static func path(to id: UUID, in node: LayerNode) -> [Int]? {
        if node.id == id { return [] }
        for (index, child) in node.children.enumerated() {
            if let rest = path(to: id, in: child) { return [index] + rest }
        }
        return nil
    }

    private static func pose(along path: [Int], from top: LayerNode, scale: CGFloat?) -> Pose {
        var node = top
        var placed = Place.host.placing(node)
        for index in path {
            node = node.children[index]
            placed = placed.place.placing(node)
        }
        return Pose(frame: placed.frame, rotation: placed.rotation, scale: scale)
    }

    // PROJECTION: deleted in plan 6
    /// Where a node's own space sits in its host's: what its children are placed by. The writes
    /// (`TreeProjection+Writes.swift`, `TreeLift`) place through it too, so that what they write
    /// lowers back to exactly what was written.
    struct Place {
        /// The node's own space to the host's.
        var toHost: CGAffineTransform
        /// Its frame's origin in the host's space, which its children's origins are added to while
        /// every node down to it is upright.
        var origin: CGPoint
        /// The angles of the nodes down to it, summed.
        var degrees: Double
        var isUpright: Bool

        /// The host itself: a screen's space, or on the canvas a top-level node's own points.
        static let host = Place(toHost: .identity, origin: .zero, degrees: 0, isUpright: true)

        /// A child of the node this is the place of: its frame and angle in the host's space, and its own place.
        func placing(_ node: LayerNode) -> (frame: CGRect, rotation: Double?, place: Place) {
            let own = node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let size = node.frame.size
            let frame: CGRect
            if isUpright {
                frame = CGRect(origin: CGPoint(x: origin.x + node.frame.origin.x, y: origin.y + node.frame.origin.y),
                               size: size)
            } else {
                let centre = CGPoint(x: node.frame.origin.x + size.width / 2, y: node.frame.origin.y + size.height / 2)
                    .applying(toHost)
                frame = CGRect(origin: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2), size: size)
            }
            let degrees = self.degrees + own
            let place = Place(toHost: node.transformToParent.concatenating(toHost), origin: frame.origin,
                              degrees: degrees, isUpright: isUpright && Rotation.normalized(own) == 0)
            return (frame, Rotation.kept(degrees), place)
        }
    }

    // PROJECTION: deleted in plan 6
    /// One host lowered: its list as kept, and its leaves as the views show them.
    private struct Lowering {
        /// The screen the elements are on, or nil on the canvas.
        let host: DesignScreen.ID?
        let pending: [UUID: UUID]
        /// Whether each element is kept with its node in `nodes` too.
        let keepsNodes: Bool
        var raw: [DesignElement] = []
        var shown: [DesignElement] = []
        var nodes: [LoweredNode] = []

        init(host: DesignScreen.ID?, pending: [UUID: UUID], keepsNodes: Bool = false) {
            self.host = host
            self.pending = pending
            self.keepsNodes = keepsNodes
        }

        /// A screen's root's children, pointing at nothing. The screen's own lock isn't shown on them.
        mutating func lowerRoot(_ root: LayerNode) {
            let place = Place.host.placing(root).place
            for child in root.children {
                emit(child, at: place, scale: nil, group: nil, locked: false, hidden: false)
            }
        }

        /// The canvas's nodes, each in its own points, at its own scale with everything in it.
        mutating func lowerCanvas(_ nodes: [LayerNode]) {
            for node in nodes {
                emit(node, at: .host, scale: node.scale, group: nil, locked: false, hidden: false)
            }
        }

        /// `node`'s block: its children's blocks, back to front, then the node. `place` is its parent's,
        /// and `locked` and `hidden` say whether a container above it is.
        private mutating func emit(_ node: LayerNode, at place: Place, scale: CGFloat?, group: UUID?,
                                   locked: Bool, hidden: Bool) {
            let placed = place.placing(node)
            let lockedInside = locked || (node.isContainer && node.isLocked)
            let hiddenInside = hidden || (node.isContainer && node.isHidden)
            for child in node.children {
                emit(child, at: placed.place, scale: scale, group: node.id, locked: lockedInside, hidden: hiddenInside)
            }
            let element = DesignElement(node: node, frame: placed.frame, rotation: placed.rotation, parent: host,
                                        scale: scale, group: pending[node.id] ?? group)
            raw.append(element)
            var view = element
            if !node.isContainer {
                view.isLocked = view.isLocked || locked
                view.isHidden = view.isHidden || hidden
                shown.append(view)
            }
            if keepsNodes { nodes.append(LoweredNode(node: node, element: element, holder: group, shown: view)) }
        }
    }
}
