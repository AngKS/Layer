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
