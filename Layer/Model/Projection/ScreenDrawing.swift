import CoreGraphics
import Foundation

// PROJECTION: deleted in plan 6 (plan 4's renderer draws nodes)
/// What the canvas draws of a screen that the flat list leaves out: the cards, and which leaves the
/// layout engine placed.
struct ScreenDrawing: Equatable, Sendable {
    /// The screen's visible cards at their absolute poses, outermost first, as kind `.card`. A card with no fill or
    /// radius of its own takes the design's card tokens.
    var cards: [DesignElement] = []
    /// Leaves whose parent is a row, column, grid or overlay: drawn in their engine frame (My call 18).
    var laidOut: Set<DesignElement.ID> = []
}
