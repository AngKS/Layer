import CoreGraphics
import Foundation
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

    /// A drawing's strokes where they now lie on the canvas: at its frame, and stretched
    /// to it if the frame has been resized since they were drawn.
    var canvasStrokes: [PKStroke] {
        guard kind == .drawing, let ink, let drawing = try? PKDrawing(data: ink), !drawing.strokes.isEmpty else { return [] }
        let natural = drawing.bounds
        func stretch(_ now: CGFloat, _ then: CGFloat) -> CGFloat {
            // Ink that covers no width or height, a straight line for instance, has nothing to stretch.
            then > 0.5 && abs(now - then) > 0.01 ? now / then : 1
        }
        let place = CGAffineTransform(translationX: -natural.minX, y: -natural.minY)
            .concatenating(CGAffineTransform(scaleX: stretch(frame.width, natural.width), y: stretch(frame.height, natural.height)))
            .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
        return drawing.strokes.map { stroke in
            var placed = stroke
            placed.transform = stroke.transform.concatenating(place)
            return placed
        }
    }

    /// How many strokes a drawing is made of.
    var strokeCount: Int {
        guard kind == .drawing, let ink, let drawing = try? PKDrawing(data: ink) else { return 0 }
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

    /// Whether a touch anywhere in the element's frame picks it. A drawing on the ink
    /// canvas is picked by its strokes instead, which leaves the space round and inside
    /// them free. Locked, it is off that canvas, and its frame is all there is to touch.
    var isPickedByItsFrame: Bool {
        kind != .drawing || isLocked
    }
}

enum InkGeometry {
    /// How near two strokes come, in canvas points, to count as parts of one drawing.
    static let reach: CGFloat = 14

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

    /// Takes in ink that was kept as one drawing for the whole board, as it was until
    /// file version 3: strokes that touch become one drawing each, on the open canvas.
    mutating func adopt(_ ink: PKDrawing) {
        for strokes in InkGeometry.groups(ink.strokes) {
            if let drawing = DesignElement.drawing(strokes) { add(drawing, to: nil, scale: 1) }
        }
    }
}
