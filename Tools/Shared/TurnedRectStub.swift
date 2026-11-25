import CoreGraphics
import Foundation

// A stand-in for `TurnedRect` (Layer/Model/Rotation.swift), which the tree's records, index,
// edits and layout use, and for the `Rotation.rotate` it turns its corners with. The real file
// also turns rects for the canvas (`Viewport`), which needs much of the app's model. What is
// here is copied from it unchanged, less `corner(_:)` and the `Viewport` extension; keep it in
// step with Rotation.swift. `corner(_:)` takes an `ElementLayout.Corner`, so it is in
// Tools/SketchBenchmarkHarness/TurnedRectCorner.swift, beside the one harness that compiles
// ElementLayout.swift: every file here is copied into the screen harness, which doesn't.
extension Rotation {
    /// The point turned clockwise on screen about `centre`.
    static func rotate(_ point: CGPoint, about centre: CGPoint, by degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        let dx = point.x - centre.x, dy = point.y - centre.y
        return CGPoint(x: centre.x + dx * cosine - dy * sine, y: centre.y + dx * sine + dy * cosine)
    }
}

/// A rectangle turned about its own centre: the shape a rotated element really takes up.
struct TurnedRect: Equatable, Sendable {
    /// The box before it is turned.
    var rect: CGRect
    var degrees: Double

    var centre: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// Top-left, top-right, bottom-right and bottom-left, each turned.
    var corners: [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .map { Rotation.rotate($0, about: centre, by: degrees) }
    }

    /// The upright box round the turned one.
    var bounds: CGRect {
        let points = corners
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Whether the point is inside the turned box: turned back about the centre, then
    /// tested against the unturned one, with a hair of slack at the edges.
    func contains(_ point: CGPoint) -> Bool {
        let back = Rotation.rotate(point, about: centre, by: -degrees)
        return rect.insetBy(dx: -0.001, dy: -0.001).contains(back)
    }

    /// The direction the box's own downward axis points once turned, as a unit vector.
    var down: CGVector {
        let radians = degrees * .pi / 180
        return CGVector(dx: -sin(radians), dy: cos(radians))
    }

    /// The smallest box turned to `degrees` that holds every corner of every shape, or nil
    /// when there are none.
    static func enclosing(_ shapes: [TurnedRect], at degrees: Double) -> TurnedRect? {
        let points = shapes.flatMap(\.corners)
        guard !points.isEmpty else { return nil }
        let radians = degrees * .pi / 180
        let across = CGVector(dx: cos(radians), dy: sin(radians))
        let downward = CGVector(dx: -sin(radians), dy: cos(radians))
        let acrossValues = points.map { $0.x * across.dx + $0.y * across.dy }
        let downValues = points.map { $0.x * downward.dx + $0.y * downward.dy }
        let minAcross = acrossValues.min()!, maxAcross = acrossValues.max()!
        let minDown = downValues.min()!, maxDown = downValues.max()!
        let midAcross = (minAcross + maxAcross) / 2, midDown = (minDown + maxDown) / 2
        let centre = CGPoint(x: across.dx * midAcross + downward.dx * midDown,
                             y: across.dy * midAcross + downward.dy * midDown)
        let size = CGSize(width: maxAcross - minAcross, height: maxDown - minDown)
        let rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        return TurnedRect(rect: rect, degrees: degrees)
    }
}
