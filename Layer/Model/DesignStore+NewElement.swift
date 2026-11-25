import CoreGraphics
import Foundation

// A new leaf: where it goes on a screen, and what it is. Siri's Add Element, voice's add and the library's drops share
// these (plan 6, F13).

extension DesignStore {
    /// Where a new leaf goes on a screen: `ElementLayout.newElementFrame` below the host shapes of the root's visible
    /// children, containers whole, so a card's padding below its last leaf isn't taken (F28). Nil for an unknown screen.
    func newElementFrame(_ kind: ElementKind, on screenID: TreeScreen.ID) -> CGRect? {
        let tree = tree, index = index
        guard let screen = tree.screens.first(where: { $0.id == screenID }) else { return nil }
        let visible = screen.root.children.filter { !$0.isHidden }.compactMap { index[$0.id]?.hostShape.rect }
        return ElementLayout.newElementFrame(for: kind, on: tree.device(of: screen), below: visible)
    }
}

extension LayerNode {
    /// A new leaf of `kind`: the kind's placeholder text, `style.tint` the kind's tint, its standard size, `.fixed` on
    /// both axes, at the origin. Siri's Add, voice's add and the library use it (F13).
    static func standard(_ kind: ElementKind, symbol: String? = nil) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = CGRect(origin: .zero, size: ElementLayout.size(for: kind, sketch: .zero))
        node.content.text = kind.placeholder
        node.content.symbol = symbol
        node.style.tint = kind.spec.tint
        return node
    }
}
