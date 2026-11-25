import CoreGraphics
import Foundation

/// Angles for turning things on the board. Degrees, clockwise on screen (the y axis points
/// down), shown to the user as 0 to 359.
enum Rotation {
    /// The same angle, kept from 0 up to but not including 360. An angle that isn't a
    /// number (or is infinite) is upright, so that it can't be saved and break the file.
    static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let kept = wrapped < 0 ? wrapped + 360 : wrapped
        return kept >= 360 ? 0 : kept
    }

    /// The angle as the Rotation field shows it: to the whole degree, from 0 to 359.
    static func shown(_ degrees: Double) -> Double {
        normalized(degrees.rounded())
    }

    /// The angle as an element keeps it: from 0 up to 360, and nothing when upright.
    static func kept(_ degrees: Double) -> Double? {
        let kept = normalized(degrees)
        return kept < 0.0001 || kept > 360 - 0.0001 ? nil : kept
    }

    /// The angle pulled to the nearest multiple of `step` when it is within `tolerance` of
    /// one, and left alone otherwise. Always returns the normalised angle.
    static func snapped(_ degrees: Double, every step: Double = 45, within tolerance: Double = 4) -> (degrees: Double, isSnapped: Bool) {
        let angle = normalized(degrees)
        let nearest = (angle / step).rounded() * step
        if abs(angle - nearest) <= tolerance {
            return (normalized(nearest), true)
        }
        return (angle, false)
    }

    /// The way round from one angle to another that turns the least, from -180 to 180.
    static func shortestTurn(from: Double, to: Double) -> Double {
        let turn = normalized(to - from)
        return turn > 180 ? turn - 360 : turn
    }
}

extension Viewport {
    /// The turned box as it appears in the view: the same angle, the rect moved and scaled.
    func viewShape(for canvas: TurnedRect) -> TurnedRect {
        TurnedRect(rect: viewRect(for: canvas.rect), degrees: canvas.degrees)
    }
}

