import CoreGraphics
import Foundation

// PROJECTION: deleted in plan 6
extension Look {
    /// What `ScreenBlueprint.Item.applyLook(to:)` wrote, field for field: border width 1 when only a colour is
    /// given, opacity of 99.5% or more read as none, value clamped to 0...1. It goes through `apply(to: inout LayerNode)`
    /// on a scratch node holding the element's style and content fields, which are then written back, so the rule
    /// lives once. A width is a node's, so an element ignores it.
    func apply(to element: inout DesignElement) {
        var scratch = LayerNode(kind: element.kind)
        scratch.style.tint = element.tint
        scratch.style.textColor = element.textColor
        scratch.style.fontSize = element.fontSize
        scratch.style.fontWeight = element.fontWeight
        scratch.style.textAlignment = element.textAlignment
        scratch.style.cornerRadius = element.cornerRadius
        scratch.style.opacity = element.opacity
        scratch.style.borderColor = element.borderColor
        scratch.style.borderWidth = element.borderWidth
        scratch.style.hasShadow = element.hasShadow
        scratch.content.isOn = element.isOn
        scratch.content.value = element.value
        scratch.content.buttonLook = element.buttonLook
        apply(to: &scratch)
        if let tint = scratch.style.tint { element.tint = tint }
        element.textColor = scratch.style.textColor
        element.fontSize = scratch.style.fontSize
        element.fontWeight = scratch.style.fontWeight
        element.textAlignment = scratch.style.textAlignment
        element.cornerRadius = scratch.style.cornerRadius
        element.opacity = scratch.style.opacity
        element.borderColor = scratch.style.borderColor
        element.borderWidth = scratch.style.borderWidth
        element.hasShadow = scratch.style.hasShadow
        element.isOn = scratch.content.isOn
        element.value = scratch.content.value
        element.buttonLook = scratch.content.buttonLook
    }
}
