import CoreGraphics
import Foundation

// How one node and one flat element say the same thing, for the projection that keeps old
// code reading and writing `DesignElement`s while the design is kept as a tree.
//
// | `DesignElement`                                        | `LayerNode`                                  |
// |--------------------------------------------------------|----------------------------------------------|
// | id, kind, name, isLocked, isHidden, unknownKeys        | the same; a container lowers as `.group`     |
// | text, symbol, shape, imageID, isOn, value, buttonLook, ink | `content`                                |
// | tint                                                   | `style.tint ?? kind.spec.tint`               |
// | fontSize … hasShadow                                   | `style`                                      |
// | parent, scale, frame, rotation, group                  | where the node is: see `TreeProjection`      |

// PROJECTION: deleted in plan 6
extension LayerNode {
    /// What an element says, as a node. A `.group` element becomes a free container sized to fit (both axes);
    /// a leaf is `.fixed` on both axes. The frame is the element's, as given.
    init(element: DesignElement) {
        self.init(kind: element.kind)
        id = element.id
        frame = element.frame
        rotation = element.rotation
        if element.kind == .group {
            width = Sizing(.fit)
            height = Sizing(.fit)
        }
        take(element, shown: nil)
    }

    /// `element`'s mapped fields written over this node; tree-only fields kept (F9). Every mapped field is written
    /// only where `element` differs from `shown`, this node's own lowering; for lock and hide that is today's
    /// `DesignContent.written(_:over:groups:)` rule. With `shown` nil (a new node) every field is written. A
    /// container's kind is never taken from a `.group` element: a card stays a card. A tint equal to the
    /// lowered one leaves `style.tint` as it is, nil included.
    ///
    /// The id is never taken: ids are stable. Where the node is (its frame, angle, parent and scale) is the
    /// projection's to write, not this.
    mutating func take(_ element: DesignElement, shown: DesignElement?) {
        func differs<Value: Equatable>(_ field: KeyPath<DesignElement, Value>) -> Bool {
            guard let shown else { return true }
            return element[keyPath: field] != shown[keyPath: field]
        }
        if differs(\.kind), !(isContainer && element.kind == .group) { kind = element.kind }
        if differs(\.name) { name = element.name }
        if differs(\.isLocked) { isLocked = element.isLocked }
        if differs(\.isHidden) { isHidden = element.isHidden }
        if differs(\.unknownKeys) { unknownKeys = element.unknownKeys }

        if differs(\.text) { content.text = element.text }
        if differs(\.symbol) { content.symbol = element.symbol }
        if differs(\.shape) { content.shape = element.shape }
        if differs(\.imageID) { content.imageID = element.imageID }
        if differs(\.isOn) { content.isOn = element.isOn }
        if differs(\.value) { content.value = element.value }
        if differs(\.buttonLook) { content.buttonLook = element.buttonLook }
        if differs(\.ink) { content.ink = element.ink }

        // After the kind, so that the tint it lowers to is the new kind's.
        if differs(\.tint), element.tint != (style.tint ?? kind.spec.tint) { style.tint = element.tint }
        if differs(\.fontSize) { style.fontSize = element.fontSize }
        if differs(\.fontWeight) { style.fontWeight = element.fontWeight }
        if differs(\.textColor) { style.textColor = element.textColor }
        if differs(\.textAlignment) { style.textAlignment = element.textAlignment }
        if differs(\.cornerRadius) { style.cornerRadius = element.cornerRadius }
        if differs(\.opacity) { style.opacity = element.opacity }
        if differs(\.borderColor) { style.borderColor = element.borderColor }
        if differs(\.borderWidth) { style.borderWidth = element.borderWidth }
        if differs(\.hasShadow) { style.hasShadow = element.hasShadow }
    }
}

// PROJECTION: deleted in plan 6
extension DesignElement {
    /// A node as an element, at the place the projection worked out for it. A container, a card included,
    /// is a `.group` item; its tint, when it has none of its own, is its kind's.
    init(node: LayerNode, frame: CGRect, rotation: Double?, parent: DesignScreen.ID?, scale: CGFloat?, group: UUID?) {
        self.init(kind: node.isContainer ? .group : node.kind, frame: frame, text: node.content.text,
                  tint: node.style.tint ?? node.kind.spec.tint)
        id = node.id
        self.parent = parent
        self.scale = scale
        self.rotation = rotation
        self.group = group
        name = node.name
        isLocked = node.isLocked
        isHidden = node.isHidden
        unknownKeys = node.unknownKeys

        symbol = node.content.symbol
        shape = node.content.shape
        imageID = node.content.imageID
        isOn = node.content.isOn
        value = node.content.value
        buttonLook = node.content.buttonLook
        ink = node.content.ink

        fontSize = node.style.fontSize
        fontWeight = node.style.fontWeight
        textColor = node.style.textColor
        textAlignment = node.style.textAlignment
        cornerRadius = node.style.cornerRadius
        opacity = node.style.opacity
        borderColor = node.style.borderColor
        borderWidth = node.style.borderWidth
        hasShadow = node.style.hasShadow
    }
}
