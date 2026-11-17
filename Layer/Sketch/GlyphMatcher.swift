import CoreGraphics
import Foundation

/// A $P point-cloud glyph: a few labelled examples of one small mark, stored as plain
/// points so adding a new glyph is a JSON edit, not a code change. `magic-pen-expansion.md`
/// §3B: "about 200 lines, runs on the device, needs no training, and doesn't care about
/// stroke order or direction."
struct GlyphExample: Codable, Sendable {
    var glyph: String
    /// One array of `[x, y]` points per stroke, in drawing order; `GlyphMatcher` doesn't
    /// care about that order once it's normalised, only about the shape it traces.
    var strokes: [[[Double]]]
}

/// The $P recognizer (Vatavu, Anthony & Wobbrock, "Gestures as Point Clouds", ICMI 2012):
/// a template matcher for small marks that needs only a handful of examples per glyph, no
/// training phase, and is invariant to stroke count, order and direction, which matters
/// here since nobody draws a tick or a chevron the same way twice.
enum GlyphMatcher {
    /// How many points every cloud is resampled to before comparing. $P's own experiments
    /// found accuracy roughly flat from 32 points up; 32 keeps the greedy match cheap.
    static let resamplePoints = 32

    // MARK: Loading templates

    /// Set before the first `match(_:)` call to load `GlyphTemplates.json` from somewhere
    /// other than the app bundle — the macOS benchmark harness, which has no bundle at all,
    /// points this at the file directly. `nonisolated(unsafe)` because it's written once,
    /// at process start, strictly before the concurrent reads `normalizedTemplates`' lazy
    /// initialisation might do; the app itself never writes it at all.
    nonisolated(unsafe) static var templatesFileOverride: URL?

    private static func loadTemplates() -> [GlyphExample] {
        let url = templatesFileOverride ?? Bundle.main.url(forResource: "GlyphTemplates", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let examples = try? JSONDecoder().decode([GlyphExample].self, from: data)
        else { return [] }
        return examples
    }

    /// Every bundled example, as normalised point clouds. Computed lazily, once, the first
    /// time a match is asked for — by then `templatesFileOverride` has had its chance to
    /// be set.
    private static let normalizedTemplates: [(glyph: String, cloud: [CGPoint])] = loadTemplates().map {
        (glyph: $0.glyph, cloud: normalize($0.strokes.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }))
    }

    // MARK: Matching

    /// The best-matching glyph for this group of strokes, and a confidence from 0 (no
    /// resemblance) to 1 (an exact match), against every bundled template. `nil` when
    /// there are no templates at all, not when the match is merely weak — a weak match
    /// still returns its best (low-confidence) guess, since the caller decides what counts
    /// as confident enough.
    static func match(_ strokes: [[CGPoint]]) -> (glyph: String, confidence: Double)? {
        match(strokes, against: normalizedTemplates)
    }

    static func match(_ strokes: [[CGPoint]], against templates: [(glyph: String, cloud: [CGPoint])]) -> (glyph: String, confidence: Double)? {
        guard !templates.isEmpty else { return nil }
        let cloud = normalize(strokes)
        guard !cloud.isEmpty else { return nil }
        var best: (glyph: String, distance: Double)?
        for template in templates {
            let distance = cloudDistance(cloud, template.cloud)
            if best == nil || distance < best!.distance {
                best = (template.glyph, distance)
            }
        }
        guard let best else { return nil }
        // Distances from normalised (unit-diagonal) clouds are bounded in practice around
        // 0...0.6 for anything resembling the template; squash to a 0...1 confidence.
        let confidence = max(0, 1 - best.distance / 0.6)
        return (best.glyph, confidence)
    }

    // MARK: Normalising

    /// Every stroke's points, concatenated in order and resampled by arc length to
    /// `resamplePoints` total, then moved to the centroid and scaled to a unit bounding
    /// box. $P treats the result as an unordered cloud from here on: concatenation order
    /// only seeds the resampling, it doesn't constrain the match.
    static func normalize(_ strokes: [[CGPoint]]) -> [CGPoint] {
        let points = strokes.flatMap { $0 }
        guard points.count >= 2 else { return points }
        let resampled = resample(points, to: resamplePoints)
        guard !resampled.isEmpty else { return [] }
        let centroid = resampled.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            .applying(CGAffineTransform(scaleX: 1 / CGFloat(resampled.count), y: 1 / CGFloat(resampled.count)))
        let centered = resampled.map { CGPoint(x: $0.x - centroid.x, y: $0.y - centroid.y) }
        let bounds = centered.boundingBox
        let scale = max(bounds.width, bounds.height, 1e-6)
        return centered.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
    }

    /// `count` points evenly spaced by arc length along the path through `points`.
    private static func resample(_ points: [CGPoint], to count: Int) -> [CGPoint] {
        guard points.count >= 2, count >= 2 else { return points }
        let total = zip(points, points.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard total > 0 else { return Array(repeating: points[0], count: count) }
        let step = total / CGFloat(count - 1)

        var result: [CGPoint] = [points[0]]
        // The walking point along the path, which may sit partway along a segment once a
        // resampled point has been emitted there; `index` is the segment it's currently on.
        var current = points[0]
        var index = 0
        var distanceToNext = step

        while result.count < count, index < points.count - 1 {
            let next = points[index + 1]
            let segment = hypot(next.x - current.x, next.y - current.y)
            if segment < distanceToNext {
                distanceToNext -= segment
                current = next
                index += 1
            } else {
                let t = segment > 0 ? distanceToNext / segment : 0
                current = CGPoint(x: current.x + (next.x - current.x) * t, y: current.y + (next.y - current.y) * t)
                result.append(current)
                distanceToNext = step
            }
        }
        while result.count < count { result.append(points.last!) }
        return result
    }

    // MARK: $P's greedy cloud matching

    /// The $P distance between two equal-length, already-normalised point clouds: the
    /// minimum-cost pairing found by greedy nearest-neighbour matching, tried from several
    /// starting points (since greedy matching is itself order-sensitive) and in both
    /// directions, cheapened by only checking every few points as $P's own paper does.
    static func cloudDistance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        let n = a.count
        let step = max(1, Int(pow(Double(n), 0.5)))
        var best = Double.infinity
        var start = 0
        while start < n {
            best = min(best, greedyMatch(a, b, startingAt: start))
            best = min(best, greedyMatch(b, a, startingAt: start))
            start += step
        }
        return best / Double(n)
    }

    private static func greedyMatch(_ from: [CGPoint], _ to: [CGPoint], startingAt start: Int) -> Double {
        let n = from.count
        var matched = [Bool](repeating: false, count: n)
        var sum = 0.0
        var i = start
        var step = 0
        repeat {
            var minDistance = Double.infinity
            var bestIndex = -1
            for j in 0..<n where !matched[j] {
                let d = Double(hypot(from[i].x - to[j].x, from[i].y - to[j].y))
                if d < minDistance { minDistance = d; bestIndex = j }
            }
            guard bestIndex >= 0 else { break }
            matched[bestIndex] = true
            let weight = 1 - Double((i - start + n) % n) / Double(n)
            sum += weight * minDistance
            i = (i + 1) % n
            step += 1
        } while i != start && step < n
        return sum
    }
}
