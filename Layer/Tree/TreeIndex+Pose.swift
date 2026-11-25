import CoreGraphics
import Foundation

// Where a node is in its host's own points: what the canvas draws, selects, moves and shows in the
// Format panel. A screen's own points are its device's; on the open canvas they are the top-level
// node's own, which its scale draws on the canvas (`placement(of:in:)`).
//
// A pose is worked out along the node's path: under upright containers their origins are added, so
// whole numbers stay exactly whole whatever the canvas's scale; once one is turned, the node's
// centre is carried through their transforms.

extension TreeIndex {
    /// Where a node's own space sits in its host's own points: what its children are placed by, and
    /// what an own frame is put back into their parent's space through. Two are equal when the node sits exactly
    /// where it did, as a turn or a resize that comes back to where it began asks before putting an own frame back.
    struct OwnSpace: Equatable, Sendable {
        /// The node's own space to its host's own points.
        var toHost: CGAffineTransform
        /// Its frame's origin in its host's own points, which its children's origins are added to
        /// while every node down to it is upright.
        var origin: CGPoint
        /// The angles of the nodes down to it, summed.
        var degrees: Double
        var isUpright: Bool

        /// A child placed in this space: see `placing(_:)`.
        struct Placed: Sendable {
            /// Its upright frame in the host's own points, centred on its turned shape's centre.
            var frame: CGRect
            /// Its angle summed with its ancestors', as it was added up.
            var degrees: Double
            /// Its own space, which its children are placed in.
            var space: OwnSpace
        }

        /// A host's top: a screen's space, or on the canvas a top-level node's own points.
        static let host = OwnSpace(toHost: .identity, origin: .zero, degrees: 0, isUpright: true)

        /// A child of the node this is the space of: its upright frame in the host's own points, centred
        /// on its turned shape's centre, its summed angle, and its own space.
        func placing(_ node: LayerNode) -> Placed {
            let own = node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let size = node.frame.size
            let frame: CGRect
            if isUpright {
                frame = CGRect(origin: CGPoint(x: origin.x + node.frame.origin.x, y: origin.y + node.frame.origin.y), size: size)
            } else {
                let centre = CGPoint(x: node.frame.origin.x + size.width / 2, y: node.frame.origin.y + size.height / 2)
                    .applying(toHost)
                frame = CGRect(origin: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2), size: size)
            }
            let degrees = self.degrees + own
            let space = OwnSpace(toHost: node.transformToParent.concatenating(toHost), origin: frame.origin,
                                 degrees: degrees, isUpright: isUpright && Rotation.normalized(own) == 0)
            return Placed(frame: frame, degrees: degrees, space: space)
        }

        /// An upright frame in the host's own points, centred where its turned shape's centre is to be, as
        /// a child's frame in this space: the same size, its centre through the inverse of `toHost`.
        func local(of frame: CGRect) -> CGRect {
            guard !isUpright else {
                return CGRect(origin: CGPoint(x: frame.origin.x - origin.x, y: frame.origin.y - origin.y), size: frame.size)
            }
            let size = frame.size
            let centre = CGPoint(x: frame.origin.x + size.width / 2, y: frame.origin.y + size.height / 2)
                .applying(toHost.inverted())
            return CGRect(origin: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2), size: size)
        }
    }

    /// A node found along its path, posed on the way down.
    struct Posed: Sendable {
        var node: LayerNode
        /// Its upright frame in its host's own points, centred on its turned shape's centre.
        var frame: CGRect
        /// Its angle summed with its ancestors', as it was added up: see `ownPose(of:in:)` for it kept.
        var degrees: Double
        /// What holds it: a container or a screen's root. Nil for a screen's root and on the canvas's top level.
        var parent: LayerNode?
        /// Where its parent's own space sits: `.host` on the canvas's top level.
        var parentSpace: OwnSpace
    }

    /// The node and its pose, found by walking its path from its host's top: O(depth). Nil for an id the
    /// index doesn't have, or a path that no longer leads to it in `content`.
    func posed(_ id: UUID, in content: TreeContent) -> Posed? {
        guard let entry = self[id] else { return nil }
        var path = entry.path[...]
        var node: LayerNode
        switch entry.host {
        case .screen(let screenID):
            guard let screen = content.screens.first(where: { $0.id == screenID }) else { return nil }
            node = screen.root
        case .canvas:
            guard let first = path.popFirst(), content.canvas.indices.contains(first) else { return nil }
            node = content.canvas[first]
        }
        var placed = OwnSpace.host.placing(node)
        var parent: LayerNode?
        var parentSpace = OwnSpace.host
        for index in path {
            guard node.children.indices.contains(index) else { return nil }
            parent = node
            parentSpace = placed.space
            node = node.children[index]
            placed = parentSpace.placing(node)
        }
        guard node.id == id else { return nil }
        return Posed(node: node, frame: placed.frame, degrees: placed.degrees, parent: parent, parentSpace: parentSpace)
    }

    /// Its upright frame in its host's own points (screen points; on the canvas, its top-level node's own points),
    /// centred on its turned shape's centre, with its summed angle: what the Format panel and the summary show.
    ///
    /// The angle is kept as an element keeps one (`Rotation.kept`), from 0 up to 360, and 0 when upright.
    func ownPose(of id: UUID, in content: TreeContent) -> (frame: CGRect, degrees: Double)? {
        posed(id, in: content).map { ($0.frame, Rotation.kept($0.degrees) ?? 0) }
    }

    /// How those own points sit on the canvas: the screen's origin and scale, or (0, 0) and the top-level node's scale.
    ///
    /// A scale that isn't a size is drawn as 1, as the index draws it.
    func placement(of id: UUID, in content: TreeContent) -> Placement? {
        guard let entry = self[id] else { return nil }
        switch entry.host {
        case .screen(let screenID):
            return content.screens.first { $0.id == screenID }?.placement
        case .canvas:
            guard let top = entry.path.first, content.canvas.indices.contains(top) else { return nil }
            let scale = content.canvas[top].scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            return Placement(origin: .zero, scale: scale)
        }
    }
}

extension TreeScreen {
    /// Where its points are drawn on the canvas, and how large.
    var placement: Placement { Placement(origin: origin, scale: scale) }

    /// Its frame on the canvas, drawn as `device`: the design's own frame for a custom device, which the
    /// screen alone can't name (`TreeContent.device(of:)`).
    func canvasFrame(on device: DeviceFrame) -> CGRect {
        placement.canvasRect(for: CGRect(origin: .zero, size: device.size))
    }

    /// Where its name is drawn on the canvas, just above its top-left corner, whatever the device.
    func labelFrame(on device: DeviceFrame) -> CGRect {
        placement.canvasRect(for: CGRect(x: 0, y: -34, width: 150, height: 30))
    }
}
