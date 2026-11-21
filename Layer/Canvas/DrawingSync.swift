import CoreGraphics
import Foundation
import PencilKit

/// Keeps the design's drawings and the ink canvas in step.
///
/// The design is where drawings are kept: each is an element with its own ink. The ink
/// canvas is where they are drawn on: it shows the strokes of every drawing that is
/// neither locked nor hidden, and PencilKit's pens and eraser work on them there. (The
/// palette's lasso selects whole drawings, with everything else: see `InkCanvas`.)
/// So there are two directions. When the strokes on the canvas change, `changes` says
/// what the design's drawings become. When the design's drawings change, by being moved,
/// locked, deleted or put back by undo, `strokes(showing:on:)` says what the canvas
/// should hold.
struct DrawingSync {
    /// What the design's drawings become, to follow the canvas.
    struct Changes: Equatable {
        /// Drawings that are new, or whose ink or frame changed.
        var drawings: [DesignElement] = []
        /// Drawings none of whose strokes are left.
        var removed: Set<DesignElement.ID> = []

        var isEmpty: Bool { drawings.isEmpty && removed.isEmpty }

        func apply(to content: inout DesignContent) {
            content.remove(removed)
            for drawing in drawings {
                if content.element(drawing.id) == nil {
                    content.add(drawing, to: nil, scale: 1)
                } else {
                    content.update(drawing.id) { $0.frame = drawing.frame; $0.ink = drawing.ink }
                }
            }
        }
    }

    /// What of a drawing the canvas shows: where it is and its ink.
    private struct Shown: Equatable {
        var frame: CGRect
        var ink: Data?
        var rotation: Double
    }

    /// A stroke as it was when its drawing's ink was last written out.
    private struct Mark: Equatable {
        var key: Double
        var transform: CGAffineTransform
        var points: Int
    }

    /// Which drawing each stroke on the canvas belongs to.
    private var owner: [Double: DesignElement.ID] = [:]
    /// The drawings the canvas shows, as the design had them when the two last agreed.
    private var shown: [DesignElement.ID: Shown] = [:]
    /// Each shown drawing's strokes as they were then, to tell which drawings changed.
    private var marks: [DesignElement.ID: [Mark]] = [:]

    /// The drawings the canvas shows: those that can be drawn on.
    private static func onCanvas(_ content: DesignContent) -> [DesignElement] {
        content.elements.filter { $0.kind == .drawing && !$0.isLocked && !$0.isHidden }
    }

    private static func mark(_ stroke: PKStroke) -> Mark {
        Mark(key: stroke.key, transform: stroke.transform, points: stroke.path.count)
    }

    /// The drawing a stroke on the canvas belongs to.
    func drawing(owning key: Double) -> DesignElement.ID? {
        owner[key]
    }

    /// The strokes the canvas should hold to show a design, or nil when it shows it
    /// already. `current` is what the canvas holds now: strokes that stay keep their
    /// place and are handed back as they are, so that PencilKit still knows them.
    mutating func strokes(showing content: DesignContent, on current: [PKStroke]) -> [PKStroke]? {
        let drawings = Self.onCanvas(content)
        let wanted = Dictionary(uniqueKeysWithValues: drawings.map { ($0.id, Shown(frame: $0.frame, ink: $0.ink, rotation: $0.resolvedRotation)) })
        guard wanted != shown else { return nil }

        let held = Dictionary(current.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: [Double: PKStroke] = [:]
        var order: [Double] = []
        let wasShown = shown
        let hadMarks = marks
        owner = [:]
        marks = [:]
        for drawing in drawings {
            // A drawing shown as it is, its strokes all still on the canvas where they were
            // put: kept as they are, without working them out again. Moving one drawing
            // across a busy board used to redo every drawing's ink on every frame.
            if wasShown[drawing.id] == wanted[drawing.id], let kept = hadMarks[drawing.id],
               let strokes = Self.strokes(kept, in: held) {
                for stroke in strokes {
                    placed[stroke.key] = stroke
                    order.append(stroke.key)
                    owner[stroke.key] = drawing.id
                }
                marks[drawing.id] = kept
                continue
            }
            var drawingMarks: [Mark] = []
            for stroke in drawing.canvasStrokes {
                // A stroke already on the canvas where it should be is kept as it is. One
                // that has moved is made again: handed the stroke it knows with only a
                // new transform, PencilKit goes on drawing it where it was.
                let kept = held[stroke.key].flatMap { $0.transform.isClose(to: stroke.transform) ? $0 : nil }
                    ?? PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask)
                placed[kept.key] = kept
                order.append(kept.key)
                owner[kept.key] = drawing.id
                drawingMarks.append(Self.mark(kept))
            }
            marks[drawing.id] = drawingMarks
        }
        shown = wanted
        let staying = current.compactMap { placed[$0.key] }
        let stayingKeys = Set(staying.map(\.key))
        return staying + order.filter { !stayingKeys.contains($0) }.compactMap { placed[$0] }
    }

    /// The strokes on the canvas that a drawing's marks name, if they are all there as
    /// marked.
    private static func strokes(_ marks: [Mark], in held: [Double: PKStroke]) -> [PKStroke]? {
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(marks.count)
        for mark in marks {
            guard let stroke = held[mark.key], Self.mark(stroke) == mark else { return nil }
            strokes.append(stroke)
        }
        return strokes
    }

    /// What the design's drawings become now that the canvas holds `strokes`. A new
    /// stroke joins the drawing it touches, within `reach` canvas points, or starts one.
    mutating func changes(for strokes: [PKStroke], in content: DesignContent, reach: CGFloat = InkGeometry.reach) -> Changes {
        let existing = Dictionary(uniqueKeysWithValues: Self.onCanvas(content).map { ($0.id, $0) })
        var members: [DesignElement.ID: [PKStroke]] = [:]
        var order: [DesignElement.ID] = []
        var strays: [PKStroke] = []

        for stroke in strokes {
            if let id = owner[stroke.key], existing[id] != nil {
                if members[id] == nil { order.append(id) }
                members[id, default: []].append(stroke)
            } else {
                strays.append(stroke)
            }
        }
        // New strokes, in the order they were made.
        for stroke in strays {
            let near = stroke.renderBounds.insetBy(dx: -reach, dy: -reach)
            let touched = order.last { id in members[id]?.contains { $0.renderBounds.intersects(near) } == true }
            let id = touched ?? UUID()
            if members[id] == nil { order.append(id) }
            members[id, default: []].append(stroke)
        }

        var changes = Changes()
        owner = [:]
        var nowShown: [DesignElement.ID: Shown] = [:]
        var nowMarks: [DesignElement.ID: [Mark]] = [:]
        for id in order {
            guard let strokes = members[id] else { continue }
            for stroke in strokes { owner[stroke.key] = id }
            let strokeMarks = strokes.map(Self.mark)
            nowMarks[id] = strokeMarks
            // Untouched since its ink was last written out: nothing to work out again.
            if let known = existing[id], marks[id] == strokeMarks, shown[id] == Shown(frame: known.frame, ink: known.ink, rotation: known.resolvedRotation) {
                nowShown[id] = shown[id]
                continue
            }
            // A turned drawing's strokes lie turned on the canvas: they go back in upright,
            // and it keeps its angle. Back by the angle they were last placed at, about where
            // they were placed: a turn that has landed since, not yet shown, isn't in them, and
            // keeps its angle as only the frame and the ink are written.
            let drawn: DesignElement?
            let lies = existing[id].map { known in shown[id] ?? Shown(frame: known.frame, ink: known.ink, rotation: known.resolvedRotation) }
            if let lies, lies.rotation != 0 {
                drawn = DesignElement.drawing(strokes, id: id, keepingTurn: lies.rotation, about: CGPoint(x: lies.frame.midX, y: lies.frame.midY))
            } else {
                drawn = DesignElement.drawing(strokes, id: id)
            }
            guard let drawn else { continue }
            nowShown[id] = Shown(frame: drawn.frame, ink: drawn.ink, rotation: drawn.resolvedRotation)
            if let known = existing[id], known.frame == drawn.frame, known.ink == drawn.ink { continue }
            changes.drawings.append(drawn)
        }
        changes.removed = Set(existing.keys).subtracting(order)
        shown = nowShown
        marks = nowMarks
        return changes
    }
}

private extension CGAffineTransform {
    /// Whether two transforms put a stroke in the same place, to within what can be seen.
    func isClose(to other: CGAffineTransform) -> Bool {
        abs(a - other.a) < 1e-6 && abs(b - other.b) < 1e-6 && abs(c - other.c) < 1e-6 && abs(d - other.d) < 1e-6
            && abs(tx - other.tx) < 1e-3 && abs(ty - other.ty) < 1e-3
    }
}
