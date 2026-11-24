import CoreGraphics
import Foundation

/// The structure pass's numbers, in one place. They are the spec's (§5 and My call 6), not
/// settings, and not tuned. Only the builder's own (`reach`, and the card reading's scores in
/// `SketchConventions`) may change, against the structure fixtures, each change recorded.
enum StructureConventions {
    // Rows: things on one line.
    static let rowCentreTolerance: CGFloat = 6
    static let rowEdgeTolerance: CGFloat = 4
    static let rowHeightRatio: CGFloat = 2
    static let rowLargestGap: CGFloat = 32
    // Columns: things in one stack.
    static let columnLeast = 3
    static let columnEdgeTolerance: CGFloat = 4
    static let columnGapVariation: CGFloat = 4
    // Grids.
    static let gridLeastRows = 2
    static let gridLeastColumns = 2
    static let gridEdgeTolerance: CGFloat = 4
    static let gridCellSizeVariation = 0.2
    // Enclosure: the share of a thing that must lie inside a card's rectangle.
    static let enclosedShare = 0.9
    // Confidence bars.
    static let automatic = 0.8
    static let offered = 0.5
    /// Call 10: voice's tidy takes a structure this sure.
    static let tidyAutomatic = 0.5
    /// Nothing moves unasked by more than this.
    static let furthestAutomaticMove: CGFloat = 8
    static let offerLifetime: Duration = .seconds(8)
    /// The builder's: a sibling this close to the neighbourhood joins it.
    static let reach: CGFloat = 48
    // Placement zones.
    /// Of the screen's width: how far from the middle still reads as centred.
    static let centredShare = 0.06
    /// Of the content width (call 8): as wide as this reads as proportional.
    static let proportionalShare = 0.9
    /// Of the content width, past the margin: starting or ending this near an edge reads as leading or trailing.
    static let marginZoneShare = 0.15
}

extension LayerNode.PlacementIntent {
    /// §5's rules, first match: proportional, centred, leading, trailing, fixed.
    /// `rect` is in screen points (call 8).
    static func of(_ rect: CGRect, screenWidth: CGFloat, margin: CGFloat) -> Self {
        let content = max(screenWidth - 2 * margin, 0)
        let zone = content * StructureConventions.marginZoneShare
        if rect.width >= StructureConventions.proportionalShare * content, content > 0 { return .proportional }
        if abs(rect.midX - screenWidth / 2) <= StructureConventions.centredShare * screenWidth { return .centered }
        if rect.minX < margin + zone { return .leading }
        if rect.maxX > screenWidth - margin - zone { return .trailing }
        return .fixed
    }
}
