import CoreGraphics
import Foundation
import os
import PencilKit

extension PKStroke {
    /// Identifies a stroke for as long as it lasts: when it was made. Moving a stroke
    /// keeps its key; a stroke the eraser splits becomes new strokes with keys of their own.
    var key: Double {
        path.creationDate.timeIntervalSinceReferenceDate
    }
}

extension DesignElement {
    /// A drawing made of these strokes, given where they lie on the canvas. Its frame is
    /// the area they cover. Nil when there are no strokes.
    static func drawing(_ strokes: [PKStroke], id: UUID = UUID()) -> DesignElement? {
        guard let area = InkGeometry.bounds(of: strokes) else { return nil }
        var element = DesignStore.newElement(.drawing)
        element.id = id
        element.frame = area
        element.ink = InkGeometry.data(for: strokes, measuredFrom: area.origin)
        return element
    }

    /// A drawing's strokes where they now lie on the canvas: at its frame, stretched
    /// to it if the frame has been resized since they were drawn, and then turned about
    /// the frame's middle by the drawing's angle.
    var canvasStrokes: [PKStroke] {
        guard kind == .drawing, let ink, let drawing = DecodedInk.drawing(id, ink: ink), !drawing.strokes.isEmpty else { return [] }
        let natural = drawing.bounds
        func stretch(_ now: CGFloat, _ then: CGFloat) -> CGFloat {
            // Ink that covers no width or height, a straight line for instance, has nothing to stretch.
            then > 0.5 && abs(now - then) > 0.01 ? now / then : 1
        }
        let place = CGAffineTransform(translationX: -natural.minX, y: -natural.minY)
            .concatenating(CGAffineTransform(scaleX: stretch(frame.width, natural.width), y: stretch(frame.height, natural.height)))
            .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
            .concatenating(turn(resolvedRotation, about: CGPoint(x: frame.midX, y: frame.midY)))
        return drawing.strokes.map { stroke in
            var placed = stroke
            placed.transform = stroke.transform.concatenating(place)
            return placed
        }
    }

    /// Strokes as they lie on the canvas, already turned by `degrees` about `centre`, made
    /// into a drawing that keeps that angle and looks exactly the same. The ink is
    /// kept upright, and the frame is moved so that turning about its own middle puts
    /// the strokes where they are. Nil when there are no strokes.
    static func drawing(_ strokes: [PKStroke], id: UUID, keepingTurn degrees: Double, about centre: CGPoint) -> DesignElement? {
        let back = turn(-degrees, about: centre)
        let unturned = strokes.map { stroke -> PKStroke in
            var upright = stroke
            upright.transform = stroke.transform.concatenating(back)
            return upright
        }
        guard let area = InkGeometry.bounds(of: unturned) else { return nil }
        let middle = CGPoint(x: area.midX, y: area.midY)
        let turned = Rotation.rotate(middle, about: centre, by: degrees)
        // Turning about the new frame's middle must equal turning about the old one.
        let shift = CGPoint(x: turned.x - middle.x, y: turned.y - middle.y)
        var element = DesignStore.newElement(.drawing)
        element.id = id
        element.frame = area.offsetBy(dx: shift.x, dy: shift.y)
        element.ink = InkGeometry.data(for: unturned, measuredFrom: area.origin)
        element.setRotation(degrees)
        return element
    }

    /// How many strokes a drawing is made of.
    var strokeCount: Int {
        guard kind == .drawing, let ink, let drawing = DecodedInk.drawing(id, ink: ink) else { return 0 }
        return drawing.strokes.count
    }

    /// A drawing's strokes as points on the canvas, for reading it as a sketch.
    var sketchStrokes: [SketchStroke] {
        canvasStrokes.map { stroke in
            SketchStroke(
                key: stroke.key,
                points: stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
            )
        }
    }

    /// The same drawing with strokes of its own: each stroke is made again with a new
    /// key. A copy needs this, or its strokes would be taken for the original's once
    /// both are on the ink canvas.
    func withStrokesOfItsOwn() -> DesignElement {
        guard kind == .drawing, let ink, let own = InkGeometry.strokesOfTheirOwn(ink) else { return self }
        var copy = self
        copy.ink = own
        return copy
    }

    /// Whether a touch anywhere in the element's frame picks it. A drawing on the ink
    /// canvas is picked by its strokes instead, which leaves the space round and inside
    /// them free. Locked, it is off that canvas, and its frame is all there is to touch.
    var isPickedByItsFrame: Bool {
        kind != .drawing || isLocked
    }
}

extension LayerNode {
    /// The same drawing with strokes of its own, as `DesignElement.withStrokesOfItsOwn()` makes
    /// one: what a copied drawing's ink needs. Anything else is returned as it is.
    func withStrokesOfItsOwn() -> LayerNode {
        guard kind == .drawing, let ink = content.ink, let own = InkGeometry.strokesOfTheirOwn(ink) else { return self }
        var copy = self
        copy.content.ink = own
        return copy
    }
}

/// A turn clockwise on screen by `degrees` about a point, as a transform.
private func turn(_ degrees: Double, about centre: CGPoint) -> CGAffineTransform {
    let radians = degrees * .pi / 180
    return CGAffineTransform(translationX: -centre.x, y: -centre.y)
        .concatenating(CGAffineTransform(rotationAngle: radians))
        .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
}

/// Drawings' ink as PencilKit strokes, kept from one decoding to the next. A drawing's ink
/// is decoded whenever it is shown on the ink canvas, counted for the selection's summary,
/// or drawn in a picture, and that happened on every frame of a drag or a pan: for every
/// drawing on the board, while one was moved. Kept by drawing, and good while its ink is
/// the same bytes. Locked, since pictures of the board are drawn off the main thread.
enum DecodedInk {
    struct Drawing {
        var strokes: [PKStroke]
        /// The area the strokes cover, as PencilKit measures a drawing.
        var bounds: CGRect
    }

    private struct Entry {
        var ink: Data
        var drawing: Drawing
    }

    /// Enough for every drawing on a busy board. Past it, the cache starts again.
    private static let capacity = 256
    private static let cache = OSAllocatedUnfairLock<[UUID: Entry]>(uncheckedState: [:])

    static func drawing(_ id: UUID, ink: Data) -> Drawing? {
        if let kept = cache.withLockUnchecked({ $0[id] }), kept.ink == ink { return kept.drawing }
        guard let decoded = try? PKDrawing(data: ink) else { return nil }
        let drawing = Drawing(strokes: decoded.strokes, bounds: decoded.bounds)
        cache.withLockUnchecked { cache in
            if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
            cache[id] = Entry(ink: ink, drawing: drawing)
        }
        return drawing
    }
}

enum InkGeometry {
    /// How near two strokes come, in canvas points, to count as parts of one drawing.
    static let reach: CGFloat = 14

    private static let lastStrokeDate = OSAllocatedUnfairLock(initialState: Date.distantPast)

    /// A creation date for a stroke made in code, later than any given out before. A
    /// stroke's creation date is its key, so no two may share one.
    static func newStrokeDate() -> Date {
        lastStrokeDate.withLock { last in
            let date = max(Date(), last.addingTimeInterval(0.001))
            last = date
            return date
        }
    }

    /// Ink with each stroke made again with a new key, or nil when it isn't a drawing's ink.
    static func strokesOfTheirOwn(_ ink: Data) -> Data? {
        guard let drawing = try? PKDrawing(data: ink) else { return nil }
        let strokes = drawing.strokes.map { stroke in
            PKStroke(
                ink: stroke.ink,
                path: PKStrokePath(controlPoints: Array(stroke.path), creationDate: newStrokeDate()),
                transform: stroke.transform, mask: stroke.mask
            )
        }
        return PKDrawing(strokes: strokes).dataRepresentation()
    }

    /// The area strokes cover, their thickness included. Nil for no strokes.
    static func bounds(of strokes: [PKStroke]) -> CGRect? {
        let rects = strokes.map(\.renderBounds)
        return rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }

    /// Strokes written out as PencilKit writes a drawing, measured from `origin`.
    static func data(for strokes: [PKStroke], measuredFrom origin: CGPoint) -> Data {
        let move = CGAffineTransform(translationX: -origin.x, y: -origin.y)
        let local = strokes.map { stroke in
            var moved = stroke
            moved.transform = stroke.transform.concatenating(move)
            return moved
        }
        return PKDrawing(strokes: local).dataRepresentation()
    }

    /// Sorts strokes into drawings: strokes that touch or nearly touch, directly or
    /// through others, are one drawing. Each drawing keeps its strokes in the order given.
    static func groups(_ strokes: [PKStroke], reach: CGFloat = InkGeometry.reach) -> [[PKStroke]] {
        let outlines = strokes.enumerated().map { index, stroke in
            let bounds = stroke.renderBounds
            return SketchStroke(key: Double(index), points: [bounds.origin, CGPoint(x: bounds.maxX, y: bounds.maxY)])
        }
        return SketchAnalyzer.cluster(outlines, reach: reach).map { group in
            group.map { Int($0.key) }.sorted().map { strokes[$0] }
        }
    }
}

extension DesignContent {
    /// The ink of the design's drawings where it lies on the canvas, as one PencilKit
    /// drawing: for pictures of the board. Hidden drawings are left out.
    var visibleInk: PKDrawing {
        PKDrawing(strokes: elements.filter { $0.kind == .drawing && !$0.isHidden }.flatMap(\.canvasStrokes))
    }

    /// Takes in ink for the whole board as one drawing: strokes that touch become one
    /// drawing each, on the open canvas.
    mutating func adopt(_ ink: PKDrawing) {
        for strokes in InkGeometry.groups(ink.strokes) {
            if let drawing = DesignElement.drawing(strokes) { add(drawing, to: nil, scale: 1) }
        }
    }
}
