#if DEBUG
import CoreGraphics
import Foundation

/// Synthetic hand-drawn strokes: slightly wobbly versions of the shapes people sketch.
/// Used by the tests and by the scripted demo, where nobody is holding a pencil.
enum SketchSamples {
    /// A box drawn in one stroke, clockwise from its top-left. A radius of half the
    /// height gives a pill.
    static func box(_ rect: CGRect, radius: CGFloat, wobble: CGFloat = 1.2) -> [CGPoint] {
        let r = min(radius, min(rect.width, rect.height) / 2)
        var points: [CGPoint] = []

        func line(_ a: CGPoint, _ b: CGPoint) {
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        func arc(_ center: CGPoint, from: CGFloat, to: CGFloat) {
            let steps = max(2, Int(abs(to - from) * r / 3))
            for step in 0..<steps {
                let angle = from + (to - from) * CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r))
            }
        }

        line(CGPoint(x: rect.minX + r, y: rect.minY), CGPoint(x: rect.maxX - r, y: rect.minY))
        arc(CGPoint(x: rect.maxX - r, y: rect.minY + r), from: -.pi / 2, to: 0)
        line(CGPoint(x: rect.maxX, y: rect.minY + r), CGPoint(x: rect.maxX, y: rect.maxY - r))
        arc(CGPoint(x: rect.maxX - r, y: rect.maxY - r), from: 0, to: .pi / 2)
        line(CGPoint(x: rect.maxX - r, y: rect.maxY), CGPoint(x: rect.minX + r, y: rect.maxY))
        arc(CGPoint(x: rect.minX + r, y: rect.maxY - r), from: .pi / 2, to: .pi)
        line(CGPoint(x: rect.minX, y: rect.maxY - r), CGPoint(x: rect.minX, y: rect.minY + r))
        arc(CGPoint(x: rect.minX + r, y: rect.minY + r), from: .pi, to: .pi * 1.5)
        points.append(points[0])
        return wobbled(points, by: wobble)
    }

    /// Two diagonal strokes across a box, as drawn to mark an image.
    static func cross(_ rect: CGRect) -> [[CGPoint]] {
        let inner = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.14)
        return [
            straight(from: CGPoint(x: inner.minX, y: inner.minY), to: CGPoint(x: inner.maxX, y: inner.maxY)),
            straight(from: CGPoint(x: inner.maxX, y: inner.minY), to: CGPoint(x: inner.minX, y: inner.maxY)),
        ]
    }

    /// A squiggle running left to right with the given number of humps.
    static func wave(_ rect: CGRect, humps: Int) -> [CGPoint] {
        let steps = max(16, Int(rect.width / 1.5))
        return (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(
                x: rect.minX + rect.width * t,
                y: rect.midY - sin(t * CGFloat(humps) * 2 * .pi) * rect.height / 2
            )
        }
    }

    static func straight(from start: CGPoint, to end: CGPoint, wobble: CGFloat = 0.8) -> [CGPoint] {
        let steps = max(2, Int(hypot(end.x - start.x, end.y - start.y) / 3))
        let points = (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
        return wobbled(points, by: wobble)
    }

    static func strokes(_ paths: [[CGPoint]], firstKey: Double = 0) -> [SketchStroke] {
        paths.enumerated().map { SketchStroke(key: firstKey + Double($0.offset), points: $0.element) }
    }

    private static func wobbled(_ points: [CGPoint], by amount: CGFloat) -> [CGPoint] {
        points.enumerated().map { index, point in
            CGPoint(
                x: point.x + sin(CGFloat(index) * 0.21) * amount,
                y: point.y + cos(CGFloat(index) * 0.17) * amount
            )
        }
    }
}
#endif
