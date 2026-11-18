import CoreGraphics
import Foundation

/// Angles for turning things on the board. Degrees, clockwise on screen (the y axis points
/// down), shown to the user as 0 to 359.
enum Rotation {
    /// The same angle, kept from 0 up to but not including 360.
    static func normalized(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let kept = wrapped < 0 ? wrapped + 360 : wrapped
        return kept >= 360 ? 0 : kept
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

    /// The point turned clockwise on screen about `centre`.
    static func rotate(_ point: CGPoint, about centre: CGPoint, by degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        let dx = point.x - centre.x, dy = point.y - centre.y
        return CGPoint(x: centre.x + dx * cosine - dy * sine, y: centre.y + dx * sine + dy * cosine)
    }

    /// The way round from one angle to another that turns the least, from -180 to 180.
    static func shortestTurn(from: Double, to: Double) -> Double {
        let turn = normalized(to - from)
        return turn > 180 ? turn - 360 : turn
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

    func corner(_ corner: ElementLayout.Corner) -> CGPoint {
        switch corner {
        case .topLeft: corners[0]
        case .topRight: corners[1]
        case .bottomRight: corners[2]
        case .bottomLeft: corners[3]
        }
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

extension Viewport {
    /// The turned box as it appears in the view: the same angle, the rect moved and scaled.
    func viewShape(for canvas: TurnedRect) -> TurnedRect {
        TurnedRect(rect: viewRect(for: canvas.rect), degrees: canvas.degrees)
    }
}

extension DesignElement {
    /// How far it is turned, 0 when upright.
    var resolvedRotation: Double { rotation ?? 0 }

    /// Turns it to `degrees`, kept from 0 up to 360. An upright element stores nothing.
    mutating func setRotation(_ degrees: Double) {
        let kept = Rotation.normalized(degrees)
        rotation = kept < 0.0001 || kept > 360 - 0.0001 ? nil : kept
    }

    /// The upright box round the turned frame, in its host's points. The frame itself when upright.
    var shapeBounds: CGRect { TurnedRect(rect: frame, degrees: resolvedRotation).bounds }
}
