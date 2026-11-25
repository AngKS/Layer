import CoreGraphics
import Foundation

/// Where a reading lands (spec §5, plan 5's call 7): the container its node goes in, where the sketch is in that
/// container's own space, and, when the container lays things out, the slot it takes. Pure, like the rest of the tree's
/// code, and built on macOS too.
struct SketchLanding: Equatable, Sendable {
    var screen: TreeScreen.ID
    /// The receiving container; a screen root's id included.
    var parent: UUID
    /// Whether the parent lays its children out: a row, column, grid or overlay.
    var isLaidOut: Bool
    /// The sketch in the parent's space; through a turned container, the same size with its centre mapped.
    var local: CGRect
    /// Laid out: the slot nearest its centre (`TreeDrop.slot`, F25). Free: nil, in front.
    var index: Int?

    /// The topmost screen under the sketch's centre (canvas points), then the deepest visible, unlocked container there;
    /// a locked or hidden one hands it to its nearest unlocked, visible ancestor. `forCard` skips containers the sketch
    /// encloses (call 7), and a row, column, grid or overlay round some of whose members it is drawn but can't take them
    /// there in place (`takenInPlace(by:in:)`, call 6), so that it lands round that container. Nil off every screen.
    ///
    /// A container is under the centre when its turned shape holds it; the frontmost is looked in first, and a hidden one
    /// isn't there to be seen, so what is behind it is looked at instead. A container whose child would sit deeper than
    /// `TreeRules.maximumDepth` hands it to its parent too (F9). A screen's root, when nothing else will do, always takes it.
    static func of(_ sketch: CGRect, in content: TreeContent, index: TreeIndex, forCard: Bool = false) -> SketchLanding? {
        let canvasCentre = CGPoint(x: sketch.midX, y: sketch.midY)
        guard let screen = content.screens.last(where: { $0.canvasFrame(on: content.device(of: $0)).contains(canvasCentre) })
        else { return nil }
        let drawn = screen.placement.localRect(for: sketch)
        let centre = CGPoint(x: drawn.midX, y: drawn.midY)

        // Down through the containers under the centre, frontmost first.
        var chain = [screen.root]
        while let next = chain[chain.count - 1].children.last(where: { child in
            guard child.isContainer, !child.isHidden, let shape = index[child.id]?.hostShape, shape.contains(centre)
            else { return false }
            guard forCard else { return true }
            // A card takes a container it encloses from where that lies, and lands round one that lays its children out
            // when it can't take what it encloses there in place.
            if share(of: shape.bounds, inside: drawn) >= StructureConventions.enclosedShare { return false }
            guard child.resolvedLayout != .free else { return true }
            guard let space = ownSpace(of: child, on: screen, in: content, index: index) else { return false }
            return takenInPlace(by: space.local(of: drawn), in: child) != nil
        }) {
            chain.append(next)
        }
        // Up to the deepest that takes it.
        let parent = chain.last { node in
            guard node.id != screen.root.id else { return true }
            guard let entry = index[node.id] else { return false }
            return !entry.isLockedWithAncestors && !entry.isHiddenWithAncestors && entry.depth + 1 <= TreeRules.maximumDepth
        } ?? screen.root
        guard let space = ownSpace(of: parent, on: screen, in: content, index: index) else { return nil }

        let local = space.local(of: drawn)
        let layout = parent.resolvedLayout
        let isLaidOut = layout != .free
        let slot = isLaidOut
            ? TreeDrop.slot(for: CGPoint(x: local.midX, y: local.midY), among: parent.children, skipping: UUID(), layout: layout)
            : nil
        return SketchLanding(screen: screen.id, parent: parent.id, isLaidOut: isLaidOut, local: local, index: slot)
    }

    /// Where a reading drawn at `drawn` (screen points) lands in `parent`, a container already on `screen`, whatever else is
    /// under its centre: the same landing as `of(_:in:index:forCard:)` with the receiving container chosen. `slot` is the
    /// slot to give a laid-out container. Nil when the container isn't posed in `content`.
    static func within(_ parent: LayerNode, on screen: TreeScreen, drawn: CGRect, slot: Int?, in content: TreeContent,
                       index: TreeIndex) -> SketchLanding? {
        guard let space = ownSpace(of: parent, on: screen, in: content, index: index) else { return nil }
        return SketchLanding(screen: screen.id, parent: parent.id, isLaidOut: parent.resolvedLayout != .free,
                             local: space.local(of: drawn), index: slot)
    }

    /// What a card drawn round `rect` (the parent's space) takes: the children at least 90% inside it that aren't locked,
    /// hidden or turned, back to front. The person's own containers are among them, and become the card's (call 7).
    static func enclosed(by rect: CGRect, in parent: LayerNode) -> [UUID] {
        parent.children.filter { canBeTaken($0) && isMostlyInside($0, rect) }.map(\.id)
    }

    /// What a card drawn round `rect` (the container's space) takes from a row, column, grid or overlay (call 6): what it
    /// encloses (`enclosed(by:in:)`), in order, when that can become one thing in its place, so that only the card's
    /// padding moves what else is there. That is an unbroken run of a row, column or overlay, which hidden things, taking
    /// no room, don't break; or one cell of a grid, since the cells after two taken would each move back a cell. Empty
    /// when it encloses nothing there; nil when what it encloses can't be one thing in place.
    static func takenInPlace(by rect: CGRect, in container: LayerNode) -> [UUID]? {
        let taken = Set(enclosed(by: rect, in: container))
        guard !taken.isEmpty else { return [] }
        if case .grid = container.resolvedLayout { return taken.count == 1 ? Array(taken) : nil }
        let shown = container.children.filter { !$0.isHidden }
        guard let first = shown.firstIndex(where: { taken.contains($0.id) }),
              let last = shown.lastIndex(where: { taken.contains($0.id) }),
              shown[first...last].allSatisfy({ taken.contains($0.id) }) else { return nil }
        return shown[first...last].map(\.id)
    }

    // MARK: - How it is worked out

    /// Whether a card may take a thing: not locked, hidden or turned, which stay where they are. A drawing never sits where
    /// a card is drawn.
    private static func canBeTaken(_ node: LayerNode) -> Bool {
        if node.isLocked || node.isHidden || node.kind == .drawing { return false }
        if let rotation = node.rotation, rotation.isFinite, rotation != 0 { return false }
        return true
    }

    /// Whether at least 90% of the box round a thing's turned shape is inside `rect`.
    private static func isMostlyInside(_ node: LayerNode, _ rect: CGRect) -> Bool {
        share(of: TreeEdit.shapesBox(of: [node]) ?? node.frame, inside: rect) >= StructureConventions.enclosedShare
    }

    /// How much of `box` lies inside `rect`, by area: 0 to 1. A box with no area is inside when its middle is.
    private static func share(of box: CGRect, inside rect: CGRect) -> Double {
        let area = box.width * box.height
        guard area > 0 else { return rect.contains(CGPoint(x: box.midX, y: box.midY)) ? 1 : 0 }
        let inside = box.intersection(rect)
        guard !inside.isNull else { return 0 }
        return Double(inside.width * inside.height / area)
    }

    /// Where a container's own space sits in its screen's points: its children's space, as the canvas poses them
    /// (`TreeIndex.OwnSpace`), so that under upright containers a sketch's origin only has their origins taken away.
    private static func ownSpace(of node: LayerNode, on screen: TreeScreen, in content: TreeContent,
                                 index: TreeIndex) -> TreeIndex.OwnSpace? {
        guard node.id != screen.root.id else { return TreeIndex.OwnSpace.host.placing(screen.root).space }
        guard let posed = index.posed(node.id, in: content) else { return nil }
        return posed.parentSpace.placing(posed.node).space
    }
}
