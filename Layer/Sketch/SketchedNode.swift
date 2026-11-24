import CoreGraphics
import Foundation

/// What a reading becomes on a screen (spec §5, plan 5's calls 6 to 8): a node where its sketch lands, laid out there,
/// remembering its sketch. Pure, and free of UIKit and SwiftUI, so that the store and the macOS sketch harness share it.
///
/// - In a free container it is placed as a Magic Pen sketch always was (`ElementLayout.sketched`), among that container's
///   visible children: on a screen's root by the screen's device, and in a nested container by a stand-in device of the
///   container's size, so that centring, two columns and text after a neighbour still mean something there. It is
///   `.fixed` on both axes.
/// - In a row, column or grid it takes the slot nearest its centre, sized like the nearest sibling of its kind, or as its
///   kind starts (`NaturalSize.defaultSizing`), and the engine places it.
/// - A card (call 6) is `.fixed` at the drawn box, in whole points, padded by the design's card padding. In a free
///   container it takes the arrangeable children at least 90% inside it, where they are on screen, and grows to hold
///   them. Its tint is nil and it has no words, so that it is drawn and written with the design's card fill (F2).
enum SketchedNode {
    struct Made: Equatable, Sendable {
        var node: LayerNode
        var landing: SketchLanding
        /// What a card takes: the receiving container's children it encloses, back to front. Empty for anything else.
        var takes: [UUID]
    }

    /// The node a reading of `kind` becomes where `sketch` (canvas points) lands, with its SketchIntent (call 7, call 8).
    /// Nil off every screen.
    static func make(_ kind: ElementKind, sketch: CGRect, in content: TreeContent, index: TreeIndex,
                     confidence: Double, decidedBy: LayerNode.DecidedBy) -> Made? {
        guard let landing = SketchLanding.of(sketch, in: content, index: index, forCard: kind == .card),
              let screen = content.screens.first(where: { $0.id == landing.screen }),
              let parent = landing.parent == screen.root.id ? screen.root : index.node(landing.parent, in: content)
        else { return nil }
        let device = content.device(of: screen)
        // A screen's root is laid out on the screen's device; anything inside it on a device of the container's size.
        let standIn = parent.id == screen.root.id ? device
            : DeviceFrame.custom(name: parent.kind.rawValue, size: parent.frame.size, family: device.family)

        var node: LayerNode
        var takes: [UUID] = []
        if kind == .card {
            let depth = index[parent.id]?.depth ?? 0
            (node, takes) = card(in: parent, at: depth, landing: landing, tokens: content.settings.tokens)
        } else {
            node = leaf(kind, in: parent, landing: landing, on: standIn, tokens: content.settings.tokens)
            if kind == .button, hasFilledButton(screen.root) {
                // A screen's first button is its main action; any more are outlined beside or below it.
                node.content.buttonLook = .bordered
                node.content.text = "Cancel"
            }
        }
        if landing.isLaidOut { size(&node, likeTheNearestOf: parent, to: landing.local) }
        node.sketch = LayerNode.SketchIntent(sketched: screen.placement.localRect(for: sketch), on: device.size,
                                             margin: device.margin, confidence: confidence, decidedBy: decidedBy)
        return Made(node: node, landing: landing, takes: takes)
    }

    /// The root with `made` put in: at its slot, a card holding what it takes at their places on screen.
    static func inserting(_ made: Made, into root: LayerNode) -> LayerNode {
        var root = root
        _ = put(made, in: &root)
        return root
    }

    // MARK: - How it is made

    /// A leaf with today's fields (placeholder text and the accent tint), placed in a free container as a Magic Pen sketch
    /// always was. In a row, column or grid, which places it, it starts at the size it would have on a phone. A title
    /// drawn small or large carries its size as its own font size (`sketchedTitleSize`), wherever it lands.
    private static func leaf(_ kind: ElementKind, in parent: LayerNode, landing: SketchLanding, on device: DeviceFrame,
                             tokens: DesignTokens) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.content.text = kind.placeholder
        node.style.tint = Theme.accent
        let laid = landing.isLaidOut
            ? ElementLayout.sketched(kind, sketch: landing.local)
            : ElementLayout.sketched(kind, sketch: landing.local, on: device,
                                     among: parent.children.filter { !$0.isHidden }.map(\.frame))
        node.frame = laid.frame
        if !landing.isLaidOut { node.style.textAlignment = laid.alignment }
        if node.frame.size.width < 1 {
            // A container narrower than the margins a kind that runs across keeps: the least it can be, on the sketch.
            let width = kind.spec.minimumSize.width
            node.frame = CGRect(x: (landing.local.midX - width / 2).rounded(), y: node.frame.minY, width: width,
                                height: node.frame.height)
        }
        if kind == .title { node.style.fontSize = ElementLayout.sketchedTitleSize(height: laid.frame.height, tokens: tokens) }
        return node
    }

    /// A card at the drawn box in whole points, and what it takes: in a free container, the arrangeable children at least
    /// 90% inside it whose subtrees stay within depth 32 once inside it (F9), the box grown to hold them. `depth` is the
    /// receiving container's.
    private static func card(in parent: LayerNode, at depth: Int, landing: SketchLanding,
                             tokens: DesignTokens) -> (LayerNode, [UUID]) {
        var node = LayerNode(kind: .card)
        node.padding = LayerNode.Padding(all: tokens.card.padding)
        let drawn = landing.local
        let minX = drawn.minX.rounded(), minY = drawn.minY.rounded()
        node.frame = CGRect(x: minX, y: minY, width: drawn.maxX.rounded() - minX, height: drawn.maxY.rounded() - minY)
        guard !landing.isLaidOut else { return (node, []) }
        let enclosed = Set(SketchLanding.enclosed(by: drawn, in: parent))
        // A child of the card sits two levels below the receiving container.
        let taken = parent.children.filter {
            enclosed.contains($0.id) && depth + 2 + TreeEdit.levels(below: $0) <= TreeRules.maximumDepth
        }
        if let box = TreeEdit.shapesBox(of: taken) { node.frame = node.frame.union(box).integral }
        return (node, taken.map(\.id))
    }

    /// Sized for a row, column or grid (call 7): like the visible sibling of its kind whose middle is nearest the sketch's,
    /// its size included when it is fixed; else as its kind starts.
    private static func size(_ node: inout LayerNode, likeTheNearestOf parent: LayerNode, to sketch: CGRect) {
        let centre = CGPoint(x: sketch.midX, y: sketch.midY)
        func distance(_ sibling: LayerNode) -> CGFloat {
            hypot(sibling.frame.midX - centre.x, sibling.frame.midY - centre.y)
        }
        let alike = parent.children.filter { $0.kind == node.kind && !$0.isHidden }
        if let nearest = alike.min(by: { distance($0) < distance($1) }) {
            node.width = nearest.width
            node.height = nearest.height
            node.frame.size = nearest.frame.size
        } else {
            (node.width, node.height) = NaturalSize.defaultSizing(for: node.kind)
        }
    }

    /// Whether a screen shows a filled button: one not hidden, nor inside anything hidden.
    private static func hasFilledButton(_ node: LayerNode) -> Bool {
        guard !node.isHidden else { return false }
        if node.kind == .button, (node.content.buttonLook ?? .filled) == .filled { return true }
        return node.children.contains(where: hasFilledButton)
    }

    /// `made` put in `node`, or in what `node` holds, wherever its landing's parent is. False when it isn't there.
    private static func put(_ made: Made, in node: inout LayerNode) -> Bool {
        guard node.id == made.landing.parent else {
            for index in node.children.indices {
                if put(made, in: &node.children[index]) { return true }
            }
            return false
        }
        var added = made.node
        var children = node.children
        if !made.takes.isEmpty {
            let taking = Set(made.takes)
            // Back to front as they were, each where it is on screen: moved into the card's space.
            added.children = children.filter { taking.contains($0.id) }.map { child in
                var held = child
                held.frame.origin = CGPoint(x: child.frame.minX - added.frame.minX, y: child.frame.minY - added.frame.minY)
                return held
            }
            children.removeAll { taking.contains($0.id) }
        }
        children.insert(added, at: made.landing.index.map { min(max($0, 0), children.count) } ?? children.count)
        TreeEdit.give(children, to: &node)
        return true
    }
}
