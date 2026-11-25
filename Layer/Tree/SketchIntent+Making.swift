import CoreGraphics
import Foundation

extension LayerNode.SketchIntent {
    /// What a reading remembers. `screen` nil means the open canvas: normalised bounds zero, placement `.fixed`.
    init(sketched bounds: CGRect, on screen: CGSize?, margin: CGFloat, confidence: Double, decidedBy: LayerNode.DecidedBy) {
        if let screen, screen.width > 0, screen.height > 0 {
            self.init(
                originalBounds: bounds,
                normalizedBounds: CGRect(
                    x: bounds.minX / screen.width, y: bounds.minY / screen.height,
                    width: bounds.width / screen.width, height: bounds.height / screen.height),
                confidence: confidence, decidedBy: decidedBy,
                placement: .of(bounds, screenWidth: screen.width, margin: margin))
        } else {
            self.init(
                originalBounds: bounds, normalizedBounds: .zero,
                confidence: confidence, decidedBy: decidedBy, placement: .fixed)
        }
    }
}

extension LayerNode {
    /// Whether the structure pass may take it: upright, not hidden, not locked, not a drawing, not declined,
    /// and, for a container, one with a `sketch` (a sketched card, or one the pass made), never the person's.
    /// It reads the node's own flags; callers check ancestors through the index.
    var isArrangeable: Bool {
        if isLocked || isHidden || kind == .drawing { return false }
        if let rotation, rotation.isFinite, rotation != 0 { return false }
        if sketch?.structureDeclined == true { return false }
        if isContainer, sketch == nil { return false }
        return true
    }
}

extension TreeContent {
    /// The person's own placing is the newest instruction (plan 5's final review, A4): each sketched node that `self`
    /// has somewhere new since `before`, in a free container on a screen, has its placement intent read again from its
    /// upright frame on the screen, by Task 1's zones (`PlacementIntent.of`), so that a device change keeps it where the
    /// person last put it. Somewhere new is on another screen, or more than half a point off where it was there: a node
    /// carried by what holds it, or taken into a card or out of a group where it lay, isn't. A node whose kind or intent
    /// the change also set (a "Did you mean", a reading) keeps the intent it was given. Only the placement is read again.
    mutating func followPlacements(since before: TreeContent) {
        let earlier = Dictionary(before.screens.map { ($0.id, $0.root) }, uniquingKeysWith: { first, _ in first })
        var follower = PlacementFollower(before: before)
        for index in screens.indices {
            let screen = screens[index]
            guard earlier[screen.id] != screen.root else { continue }
            follower.device = device(of: screen)
            follower.host = .screen(screen.id)
            if let root = follower.followed(screen.root, was: earlier[screen.id], toHost: .identity, wasToHost: .identity) {
                screens[index].root = root
            }
        }
    }
}

/// `TreeContent.followPlacements(since:)`'s walk: down the tree as it is now beside the tree as it was, pairing each node
/// with the one of its id that its parent held before, or, for one moved from elsewhere, the one the design held.
private struct PlacementFollower {
    /// Where a node was, and what it was, before the change.
    private struct Was {
        var host: TreeIndex.Host
        var frame: CGRect
        var kind: ElementKind
        var sketch: LayerNode.SketchIntent?
    }

    let before: TreeContent
    /// The screen being followed, and its device.
    var host = TreeIndex.Host.canvas
    var device = DeviceFrame.iPhone
    /// Every node the design held, by id, made the first time a node isn't where its parent held it.
    private var everywhere: [UUID: Was]?

    init(before: TreeContent) {
        self.before = before
    }

    /// `node` with its children, and theirs, followed; nil when none changes. `was` is `node` as it was, when its parent
    /// held it then. `toHost` takes the space `node` lies in to the screen's now, and `wasToHost` as it was. Only what
    /// changes is copied, so that what doesn't stays shared with the tree as it was.
    mutating func followed(_ node: LayerNode, was: LayerNode?, toHost: CGAffineTransform,
                           wasToHost: CGAffineTransform) -> LayerNode? {
        let own = node.transformToParent.concatenating(toHost)
        let wasOwn = was.map { $0.transformToParent.concatenating(wasToHost) } ?? .identity
        let isFree = node.resolvedLayout == .free
        var held: [UUID: Int]?
        var rewritten: LayerNode?
        for index in node.children.indices {
            var child = node.children[index]
            var then: LayerNode?
            if let was {
                if was.children.indices.contains(index), was.children[index].id == child.id {
                    then = was.children[index]
                } else {
                    if held == nil {
                        held = Dictionary(was.children.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
                    }
                    then = held?[child.id].map { was.children[$0] }
                }
            }
            if let then, then == child { continue }
            var changed = false
            if isFree, let sketch = child.sketch {
                let placed = Self.upright(child, in: own)
                let prior = then.map { Was(host: host, frame: Self.upright($0, in: wasOwn), kind: $0.kind, sketch: $0.sketch) }
                    ?? elsewhere(child.id)
                let placement = LayerNode.PlacementIntent.of(placed, screenWidth: device.size.width, margin: device.margin)
                if let prior, prior.kind == child.kind, prior.sketch == sketch, placement != sketch.placement,
                   prior.host != host || !Self.isClose(prior.frame, placed) {
                    child.sketch?.placement = placement
                    changed = true
                }
            }
            if let deeper = followed(child, was: then, toHost: own, wasToHost: wasOwn) {
                child = deeper
                changed = true
            }
            if changed {
                if rewritten == nil { rewritten = node }
                rewritten?.children[index] = child
            }
        }
        return rewritten
    }

    /// Where the node with `id` was before the change, wherever that was; nil for a new one.
    private mutating func elsewhere(_ id: UUID) -> Was? {
        if everywhere == nil {
            var found: [UUID: Was] = [:]
            func visit(_ node: LayerNode, on host: TreeIndex.Host, in toHost: CGAffineTransform) {
                let own = node.transformToParent.concatenating(toHost)
                for child in node.children where found[child.id] == nil {
                    found[child.id] = Was(host: host, frame: Self.upright(child, in: own), kind: child.kind, sketch: child.sketch)
                    visit(child, on: host, in: own)
                }
            }
            for screen in before.screens { visit(screen.root, on: .screen(screen.id), in: .identity) }
            for node in before.canvas {
                found[node.id] = found[node.id] ?? Was(host: .canvas, frame: node.frame, kind: node.kind, sketch: node.sketch)
                visit(node, on: .canvas, in: .identity)
            }
            everywhere = found
        }
        return everywhere?[id]
    }

    /// `node`'s upright frame in the host's points, centred on its turned shape's centre, as `TreeIndex` has it.
    private static func upright(_ node: LayerNode, in parentToHost: CGAffineTransform) -> CGRect {
        let centre = CGPoint(x: node.frame.width / 2, y: node.frame.height / 2)
            .applying(node.transformToParent.concatenating(parentToHost))
        return CGRect(x: centre.x - node.frame.width / 2, y: centre.y - node.frame.height / 2,
                      width: node.frame.width, height: node.frame.height)
    }

    /// Within half a point on every edge: the same place, however the transforms round.
    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.maxX - b.maxX) <= 0.5 && abs(a.maxY - b.maxY) <= 0.5
    }
}
