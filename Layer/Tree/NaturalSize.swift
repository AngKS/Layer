import CoreGraphics
import Foundation

/// How big each kind of leaf is when nothing else decides, and what sizing a new node of a
/// kind starts with. The layout engine asks here for every `.fit` leaf.
enum NaturalSize {
    /// `fontSize(of:tokens:)` with Layer's own tokens.
    static func fontSize(of node: LayerNode) -> CGFloat {
        fontSize(of: node, tokens: .standard)
    }

    /// The node's own font size, else the design's title, body or text size, else its kind's: the one rule text is
    /// measured and drawn by (F5).
    static func fontSize(of node: LayerNode, tokens: DesignTokens) -> CGFloat {
        if let size = node.style.fontSize { return size }
        let spec = node.kind.spec
        let sizes = tokens.textSizes
        switch node.kind {
        case .title: return sizes.title
        case .body: return sizes.body
        case .text: return sizes.text
        default: break
        }
        switch spec.fontSize {
        case .points(let points): return points
        case .ofHeight(let fraction):
            // The kind's standard height, not the node's: a title is 0.7 x 40 = 28 wherever it sits.
            if case .fixed(let size) = spec.size { return fraction * size.height }
            return fraction * node.frame.height
        }
    }

    static func fontWeight(of node: LayerNode) -> FontWeightChoice {
        node.style.fontWeight ?? node.kind.spec.fontWeight
    }

    /// A leaf's natural size for an offered width (nil = ideal). Not for containers.
    static func of(_ node: LayerNode, width: CGFloat?, measure: TextMeasure) -> CGSize {
        switch node.kind {
        case .title, .body, .text:
            return measure.size(
                of: node.content.text, fontSize: fontSize(of: node), weight: fontWeight(of: node), width: width)
        case .stickyNote:
            return CGSize(width: 150, height: 150)
        case .button:
            let label = measure.size(of: node.content.text, fontSize: 17, weight: .semibold, width: nil)
            return CGSize(width: max(label.width + 40, 44), height: 50)
        case .textField: return CGSize(width: width ?? 280, height: 48)
        case .divider: return CGSize(width: width ?? 1, height: 1)
        case .progress: return CGSize(width: width ?? 333, height: 6)
        case .image: return CGSize(width: width ?? 333, height: 200)
        case .symbol: return CGSize(width: 44, height: 44)
        case .toggle: return CGSize(width: 51, height: 31)
        case .checkbox, .radio: return CGSize(width: 24, height: 24)
        case .avatar: return CGSize(width: 48, height: 48)
        case .shape: return CGSize(width: 100, height: 100)
        case .drawing: return node.frame.size
        case .group, .card: return .zero
        }
    }

    /// Whether a leaf's natural width is (up to) the width offered it: text wraps to it, and a
    /// text field, divider, progress bar or image spans it. Every other leaf is one width whatever
    /// it is offered.
    static func takesTheWidthOffered(_ kind: ElementKind) -> Bool {
        switch kind {
        case .title, .body, .text, .textField, .divider, .progress, .image: true
        default: false
        }
    }

    /// Whether a kind keeps its natural size when a row or column stretches its children across
    /// (Ruling M3): a toggle, checkbox, radio button, avatar or symbol drawn any other size is
    /// drawn wrong, so it stays at its size, at the stack's start edge.
    static func keepsItsShape(_ kind: ElementKind) -> Bool {
        switch kind {
        case .toggle, .checkbox, .radio, .avatar, .symbol: true
        default: false
        }
    }

    /// The sizing a generated or imported node of this kind starts with.
    static func defaultSizing(for kind: ElementKind) -> (width: LayerNode.Sizing, height: LayerNode.Sizing) {
        let fills = kind == .card || kind.spec.fillsWrittenWidth
        return (LayerNode.Sizing(fills ? .fill(weight: 1) : .fit), LayerNode.Sizing(.fit))
    }
}
