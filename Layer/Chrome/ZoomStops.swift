import SwiftUI

/// The zoom levels the zoom control's ruler steps through, and the ruler's target for them.
/// A stop's scale is its percent over 100 (33 is 0.33).
enum ZoomStops {
    nonisolated static let percents = [10, 15, 20, 25, 33, 50, 67, 75, 100, 125, 150, 200, 250, 300, 400]
    /// The levels the zoom menu offers, which get the ruler's longer marks.
    nonisolated static let menuLevels = [25, 50, 100, 200, 400]
    /// How far a finger slides for each stop.
    nonisolated static let pointsPerStop: CGFloat = 16
    /// How far the pencil's barrel turns for each stop.
    nonisolated static let degreesPerStop = 10.0

    /// How close to a stop, by ratio, a zoom still counts as on it.
    private nonisolated static let onStopTolerance = log(1.02)

    nonisolated static func scale(at index: Int) -> CGFloat {
        CGFloat(percents[min(max(index, 0), percents.count - 1)]) / 100
    }

    /// The stop nearest `scale` by ratio, a tie going to the lower one.
    nonisolated static func nearestIndex(to scale: CGFloat) -> Int {
        guard scale > 0 else { return 0 }
        var best = 0
        var bestDistance = Double.infinity
        for index in percents.indices {
            let distance = abs(log(Double(scale / self.scale(at: index))))
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// The zoom `stops` stops from `scale`, for VoiceOver. On a stop (within 2%) it moves from
    /// that stop; between stops the first step lands on the next stop in that direction.
    nonisolated static func step(from scale: CGFloat, by stops: Int) -> CGFloat {
        guard stops != 0, scale > 0 else { return self.scale(at: nearestIndex(to: scale)) }
        let nearest = nearestIndex(to: scale)
        let ratio = abs(log(Double(scale / self.scale(at: nearest))))
        if ratio <= onStopTolerance { return self.scale(at: nearest + stops) }
        let target: Int
        if stops > 0 {
            let above = percents.indices.first { self.scale(at: $0) > scale } ?? percents.count
            target = above + stops - 1
        } else {
            let below = percents.indices.last { self.scale(at: $0) < scale } ?? -1
            target = below + stops + 1
        }
        return self.scale(at: target)
    }

    /// As `step(from:by:)`, for VoiceOver's adjust: while a glide is under way the zoom hasn't
    /// reached the stop last asked for, so a second adjustment steps from that stop, not from
    /// where the glide has got to.
    nonisolated static func step(from scale: CGFloat, requested: CGFloat?, isGliding: Bool, by stops: Int) -> CGFloat {
        step(from: isGliding ? (requested ?? scale) : scale, by: stops)
    }

    /// The zoom's ruler: indices into the stops, shown as percents, with the menu's levels
    /// as the longer marks.
    @MainActor
    static func target(
        frame: CGRect,
        current: @escaping @MainActor () -> CGFloat,
        zoom: @escaping @MainActor (CGFloat) -> Void
    ) -> Scrubber.Target {
        let majors = Set(menuLevels.compactMap { percents.firstIndex(of: $0) })
        return Scrubber.Target(
            label: "Zoom",
            unit: "%",
            frame: frame,
            range: 0...CGFloat(percents.count - 1),
            get: { MainActor.assumeIsolated { CGFloat(nearestIndex(to: current())) } },
            set: { index in MainActor.assumeIsolated { zoom(scale(at: Int(index))) } },
            pointsPerStep: pointsPerStop,
            degreesPerStep: degreesPerStop,
            ticksEvery: 1,
            owner: .zoom,
            text: { percents[min(max(Int($0), 0), percents.count - 1)].description + "%" },
            majorMarks: majors
        )
    }
}
