import CoreGraphics
import Foundation

/// Shapes sorted into square buckets by where they lie, so that asking whether one of them meets a box looks only at
/// those near it. The structure pass asks whether anything lies between two things for every pair it tries, and over a
/// container of hundreds of things looking at every shape each time was most of its cost (plan 5, Task 10). The caller
/// decides with its own test: every shape that shares some area with the box is among those looked at, so the answer
/// is the one looking at every shape gives.
struct ShapeBuckets {
    /// A bucket's side, in points: about a small control.
    private static let side: CGFloat = 64
    /// A shape over more buckets than this is looked at every time instead.
    private static let widest = 64

    private let count: Int
    /// By bucket: its column in the high half of the key, its row in the low.
    private var buckets: [Int: [Int]] = [:]
    /// Shapes too big, or too far out, for the buckets.
    private var everywhere: [Int] = []

    init(_ shapes: [CGRect]) {
        count = shapes.count
        for (index, shape) in shapes.enumerated() {
            guard let span = Self.span(of: shape), span.x.count * span.y.count <= Self.widest else {
                everywhere.append(index)
                continue
            }
            for x in span.x {
                for y in span.y { buckets[Self.key(x, y), default: []].append(index) }
            }
        }
    }

    /// Whether `test` holds for a shape that may share some area with `box`, by its place in the list given. Looks at
    /// every shape when `box` covers more buckets than there are shapes.
    func contains(near box: CGRect, where test: (Int) -> Bool) -> Bool {
        guard let span = Self.span(of: box), span.x.count * span.y.count <= count else {
            return (0..<count).contains(where: test)
        }
        if everywhere.contains(where: test) { return true }
        for x in span.x {
            for y in span.y {
                if let near = buckets[Self.key(x, y)], near.contains(where: test) { return true }
            }
        }
        return false
    }

    /// The buckets a box lies across, from the one holding its least corner to the one holding its greatest; nil for a
    /// box that is null or not finite, or too far out to count in buckets.
    private static func span(of rect: CGRect) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        guard !rect.isNull, let minX = bucket(rect.minX), let maxX = bucket(rect.maxX), let minY = bucket(rect.minY),
              let maxY = bucket(rect.maxY) else { return nil }
        return (minX...maxX, minY...maxY)
    }

    /// The bucket a coordinate falls in; nil when it isn't finite or is too far out to count.
    private static func bucket(_ value: CGFloat) -> Int? {
        let bucket = (value / side).rounded(.down)
        return bucket.isFinite && abs(bucket) < 1_000_000 ? Int(bucket) : nil
    }

    private static func key(_ x: Int, _ y: Int) -> Int { x << 32 | (y & 0xFFFF_FFFF) }
}
