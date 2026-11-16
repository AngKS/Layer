import CoreGraphics
import Foundation

/// One pen stroke, reduced to evenly spaced points on the canvas.
struct SketchStroke: Sendable, Equatable {
    /// Identifies the stroke in the ink canvas so it can be removed once converted.
    var key: Double
    var points: [CGPoint]

    var bounds: CGRect { points.boundingBox }
}

/// What a group of strokes looks like, in purely geometric terms. Deciding what the shape
/// *means* is left to a `SketchInterpreter`.
struct SketchObservation: Sendable, Equatable {
    enum InnerMark: Sendable, Equatable {
        case none
        /// Strokes running corner to corner across the middle, as drawn to mark an image.
        case cross
        /// One bent stroke across the middle, as drawn to check a box.
        case tick
        /// A small mark in the middle, as drawn to select a radio button.
        case dot
        case other
    }

    enum Form: Sendable, Equatable {
        /// A closed outline. `roundness` runs from 0 (sharp corners) to 1 (an oval or pill).
        case enclosure(roundness: Double, inner: InnerMark)
        /// An open squiggle running sideways, with this many humps.
        case wave(humps: Int)
        /// Several roughly horizontal strokes, one above another.
        case stackedLines(count: Int)
        /// A single straight horizontal stroke.
        case line
        case scribble
        /// A zigzag scrubbed back and forth over something, as drawn to cross it out.
        case scratch(passes: Int)

        var isEnclosure: Bool {
            if case .enclosure = self { true } else { false }
        }
    }

    var bounds: CGRect
    var form: Form
    var strokeCount: Int
    /// For an enclosure with marks inside: where those marks sit, as fractions of the
    /// enclosure's bounds, so (0, 0, 1, 1) covers all of it. A toggle's knob on the
    /// right ends past 0.5; a progress bar's hatching ends where the bar is filled to.
    var innerBounds: CGRect? = nil
}

enum SketchAnalyzer {
    /// Groups strokes that belong to the same sketch: strokes whose bounds touch or nearly
    /// touch end up together, so an X drawn inside a box joins the box.
    static func cluster(_ strokes: [SketchStroke], reach: CGFloat = 14) -> [[SketchStroke]] {
        var groups: [(bounds: CGRect, strokes: [SketchStroke])] = []
        for stroke in strokes where !stroke.points.isEmpty {
            var merged = (bounds: stroke.bounds, strokes: [stroke])
            var remaining: [(bounds: CGRect, strokes: [SketchStroke])] = []
            for group in groups {
                if group.bounds.insetBy(dx: -reach, dy: -reach).intersects(merged.bounds) {
                    merged = (group.bounds.union(merged.bounds), group.strokes + merged.strokes)
                } else {
                    remaining.append(group)
                }
            }
            // Growing the merged bounds may now reach groups that were skipped earlier.
            var changed = true
            while changed {
                changed = false
                for (index, group) in remaining.enumerated()
                where group.bounds.insetBy(dx: -reach, dy: -reach).intersects(merged.bounds) {
                    merged = (group.bounds.union(merged.bounds), group.strokes + merged.strokes)
                    remaining.remove(at: index)
                    changed = true
                    break
                }
            }
            groups = remaining + [merged]
        }
        return groups.map { $0.strokes.sorted { $0.key < $1.key } }
    }

    /// Describes a group of strokes, or returns nil when it is too small to be a sketch.
    static func observe(_ strokes: [SketchStroke]) -> SketchObservation? {
        let strokes = strokes.filter { $0.points.count >= 2 }
        let bounds = strokes.flatMap(\.points).boundingBox
        guard !strokes.isEmpty, max(bounds.width, bounds.height) >= 16 else { return nil }
        if let closed = enclosure(strokes, in: bounds) {
            return SketchObservation(bounds: bounds, form: closed.form, strokeCount: strokes.count, innerBounds: closed.inner)
        }
        return SketchObservation(bounds: bounds, form: openForm(strokes, in: bounds), strokeCount: strokes.count)
    }

    // MARK: Closed outlines

    private static func enclosure(_ strokes: [SketchStroke], in bounds: CGRect) -> (form: SketchObservation.Form, inner: CGRect?)? {
        let short = min(bounds.width, bounds.height)
        // Long, thin outlines are allowed: a progress bar can be ten or more times wider than tall.
        guard short >= 14, short >= max(bounds.width, bounds.height) * 0.07 else { return nil }

        // Positions are measured from the centre, in units where the bounds' edges sit at 1.
        func reach(_ point: CGPoint) -> CGFloat {
            max(abs(point.x - bounds.midX) / (bounds.width / 2), abs(point.y - bounds.midY) / (bounds.height / 2))
        }

        // An outline stroke stays near the edge of the bounds and never visits the middle.
        // Squiggles and crosses do visit the middle, which is what tells them apart.
        var outline: [CGPoint] = []
        var inner: [CGPoint] = []
        var innerStrokes: [SketchStroke] = []
        for stroke in strokes {
            let reaches = stroke.points.map(reach)
            let nearEdge = reaches.count { $0 >= 0.6 }
            let inMiddle = reaches.count { $0 < 0.4 }
            let count = Double(reaches.count)
            if Double(nearEdge) >= count * 0.8, Double(inMiddle) <= count * 0.03 {
                outline += stroke.points
            } else {
                inner += stroke.points
                innerStrokes.append(stroke)
            }
        }
        guard !outline.isEmpty else { return nil }

        // The outline must go all the way round: look for ink in every direction from the centre.
        let sectors = 24
        var seen = [Bool](repeating: false, count: sectors)
        for point in outline {
            let angle = atan2((point.y - bounds.midY) / bounds.height, (point.x - bounds.midX) / bounds.width)
            let index = Int((angle + .pi) / (2 * .pi) * Double(sectors))
            seen[min(max(index, 0), sectors - 1)] = true
        }
        guard Double(seen.count { $0 }) >= Double(sectors) * 0.85 else { return nil }

        // Sharp corners reach into the corners of the bounds; ovals and pills cut them off.
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        let cutoff = corners
            .map { corner in outline.map { hypot($0.x - corner.x, $0.y - corner.y) }.min() ?? 0 }
            .reduce(0, +) / 4
        let roundness = min(1, Double(cutoff / (short * 0.2)))

        guard !inner.isEmpty else { return (.enclosure(roundness: roundness, inner: .none), nil) }
        let innerBounds = inner.boundingBox
        let relative = CGRect(
            x: (innerBounds.minX - bounds.minX) / bounds.width,
            y: (innerBounds.minY - bounds.minY) / bounds.height,
            width: innerBounds.width / bounds.width,
            height: innerBounds.height / bounds.height
        )
        let crossesMiddle = inner.contains { reach($0) < 0.3 }
        let spans = relative.width >= 0.45 && relative.height >= 0.45
        let mark: SketchObservation.InnerMark
        if crossesMiddle, spans {
            // A tick is one stroke that changes direction; an X is two, or one that doubles back.
            if innerStrokes.count == 1, let tick = innerStrokes.first, isTick(tick.points) {
                mark = .tick
            } else {
                mark = .cross
            }
        } else if relative.width <= 0.6, relative.height <= 0.6, (0.3...0.7).contains(relative.midX), (0.3...0.7).contains(relative.midY) {
            mark = .dot
        } else {
            mark = .other
        }
        return (.enclosure(roundness: roundness, inner: mark), relative)
    }

    /// Whether a stroke is a tick: it bends once, sharply, and its two arms both run
    /// sideways rather than doubling back over each other.
    private static func isTick(_ points: [CGPoint]) -> Bool {
        guard let first = points.first, let last = points.last, points.count >= 3 else { return false }
        // The bend is where the stroke is lowest on the canvas (the largest y).
        guard let bend = points.max(by: { $0.y < $1.y }) else { return false }
        let total = pathLength(points)
        let chord = hypot(last.x - first.x, last.y - first.y)
        let rises = bend.y - first.y > 2 && bend.y - last.y > 2
        let forward = first.x < bend.x && bend.x < last.x
        return total > 0 && chord < total * 0.9 && rises && forward
    }

    // MARK: Open strokes

    private static func openForm(_ strokes: [SketchStroke], in bounds: CGRect) -> SketchObservation.Form {
        // Squiggles and lines run one way; a scratch-out doubles back on itself, again and again.
        let doubleBack = max(6, bounds.width * 0.3)
        let reversals = strokes.reduce(0) { $0 + Self.turns($1.points.map(\.x), threshold: doubleBack) }
        if reversals >= 3, bounds.width >= 16 {
            return .scratch(passes: reversals + 1)
        }

        if strokes.count >= 2 {
            let sideways = strokes.allSatisfy { $0.bounds.width >= max(24, $0.bounds.height * 2.5) }
            let rows = distinctRows(strokes.map(\.bounds))
            if sideways, rows >= 2 { return .stackedLines(count: rows) }
        }

        if strokes.count == 1, let stroke = strokes.first, let first = stroke.points.first, let last = stroke.points.last {
            let chord = hypot(last.x - first.x, last.y - first.y)
            if bounds.width >= bounds.height * 4, chord >= pathLength(stroke.points) * 0.92 {
                return .line
            }
        }

        let threshold = max(3, bounds.height * 0.3)
        let ups = strokes.reduce(0) { $0 + verticalTurns($1.points, threshold: threshold) }
        if bounds.width >= bounds.height * 1.5, bounds.height >= 8, ups >= 3 {
            return .wave(humps: (ups + 1) / 2)
        }
        return .scribble
    }

    /// Counts how often a stroke reverses between heading up and heading down, ignoring
    /// reversals smaller than `threshold`.
    private static func verticalTurns(_ points: [CGPoint], threshold: CGFloat) -> Int {
        turns(points.map(\.y), threshold: threshold)
    }

    /// Counts how often a run of values reverses direction, ignoring reversals smaller
    /// than `threshold`.
    private static func turns(_ values: [CGFloat], threshold: CGFloat) -> Int {
        guard var extreme = values.first else { return 0 }
        var direction = 0
        var turns = 0
        for y in values.dropFirst() {
            switch direction {
            case 1:
                if y > extreme { extreme = y } else if extreme - y >= threshold { turns += 1; direction = -1; extreme = y }
            case -1:
                if y < extreme { extreme = y } else if y - extreme >= threshold { turns += 1; direction = 1; extreme = y }
            default:
                if y - extreme >= threshold { direction = 1; extreme = y } else if extreme - y >= threshold { direction = -1; extreme = y }
            }
        }
        return turns
    }

    private static func distinctRows(_ bounds: [CGRect]) -> Int {
        var rows: [CGFloat] = []
        for rect in bounds.sorted(by: { $0.midY < $1.midY }) {
            if let last = rows.last, rect.midY - last < max(6, rect.height) { continue }
            rows.append(rect.midY)
        }
        return rows.count
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
}

extension Collection where Element == CGPoint {
    /// The smallest rectangle containing every point; `.zero` for an empty collection.
    var boundingBox: CGRect {
        guard let first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in dropFirst() {
            minX = Swift.min(minX, point.x)
            maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y)
            maxY = Swift.max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
