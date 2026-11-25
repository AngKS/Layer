import CoreGraphics
import Foundation
import PencilKit

/// Keeps the design's drawings and the ink canvas in step.
///
/// The design is where drawings are kept: each is a node on the canvas with its own ink. The ink
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
        var drawings: [LayerNode] = []
        /// Drawings none of whose strokes are left.
        var removed: Set<LayerNode.ID> = []

        var isEmpty: Bool { drawings.isEmpty && removed.isEmpty }

        /// Writes the drawings on the canvas's top level: a new one goes on top at scale 1, one it has
        /// keeps its angle and takes only the frame and ink.
        func apply(to content: inout TreeContent) {
            let gone = removed
            if !gone.isEmpty { content.canvas.removeAll { gone.contains($0.id) } }
            for drawing in drawings {
                if let index = content.canvas.firstIndex(where: { $0.id == drawing.id }) {
                    content.canvas[index].frame = drawing.frame
                    content.canvas[index].content.ink = drawing.content.ink
                } else {
                    var added = drawing
                    added.scale = 1
                    content.canvas.append(added)
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
    private var owner: [Double: LayerNode.ID] = [:]
    /// The drawings the canvas shows, as the design had them when the two last agreed.
    private var shown: [LayerNode.ID: Shown] = [:]
    /// Each shown drawing's strokes as they were then, to tell which drawings changed.
    private var marks: [LayerNode.ID: [Mark]] = [:]

    /// The canvas's unlocked, visible drawing nodes, back to front: those that can be drawn on. Read from
    /// the open canvas's own nodes, where the design keeps every drawing, rather than from the whole
    /// design lowered to its list, which this runs on every change, each frame of a drag among them.
    /// `TreeRules` keeps every drawing there, in no container, so each one's own lock and hide are how
    /// the views show it.
    static func onCanvas(_ content: TreeContent) -> [LayerNode] {
        content.canvas.filter { $0.kind == .drawing && !$0.isLocked && !$0.isHidden }
    }

    private static func mark(_ stroke: PKStroke) -> Mark {
        Mark(key: stroke.key, transform: stroke.transform, points: stroke.path.count)
    }

    /// The drawing a stroke on the canvas belongs to.
    func drawing(owning key: Double) -> LayerNode.ID? {
        owner[key]
    }

    /// The strokes the canvas should hold to show a design, or nil when it shows it
    /// already. `current` is what the canvas holds now: strokes that stay keep their
    /// place and are handed back as they are, so that PencilKit still knows them.
    mutating func strokes(showing content: TreeContent, on current: [PKStroke]) -> [PKStroke]? {
        strokes(showing: content, reading: { current })
    }

    /// The same, reading what the canvas holds only once it is plain that the design's
    /// drawings have changed. Reading it bridges every stroke on the canvas out of PencilKit,
    /// which every change to the design did, each frame of an element's drag among them,
    /// though most changes leave every drawing as it was (audit C6).
    mutating func strokes(showing content: TreeContent, reading current: () -> [PKStroke]) -> [PKStroke]? {
        let drawings = Self.onCanvas(content)
        let wanted = Dictionary(uniqueKeysWithValues: drawings.map { ($0.id, Shown(frame: $0.frame, ink: $0.content.ink, rotation: $0.resolvedRotation)) })
        guard wanted != shown else { return nil }
        let current = current()

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
    mutating func changes(for strokes: [PKStroke], in content: TreeContent, reach: CGFloat = InkGeometry.reach) -> Changes {
        let existing = Dictionary(uniqueKeysWithValues: Self.onCanvas(content).map { ($0.id, $0) })
        var members: [LayerNode.ID: [PKStroke]] = [:]
        var order: [LayerNode.ID] = []
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
        var nowShown: [LayerNode.ID: Shown] = [:]
        var nowMarks: [LayerNode.ID: [Mark]] = [:]
        for id in order {
            guard let strokes = members[id] else { continue }
            for stroke in strokes { owner[stroke.key] = id }
            let strokeMarks = strokes.map(Self.mark)
            nowMarks[id] = strokeMarks
            // Untouched since its ink was last written out: nothing to work out again.
            if let known = existing[id], marks[id] == strokeMarks, shown[id] == Shown(frame: known.frame, ink: known.content.ink, rotation: known.resolvedRotation) {
                nowShown[id] = shown[id]
                continue
            }
            // A turned drawing's strokes lie turned on the canvas: they go back in upright,
            // and it keeps its angle. Back by the angle they were last placed at, about where
            // they were placed: a turn that has landed since, not yet shown, isn't in them, and
            // keeps its angle as only the frame and the ink are written.
            let drawn: LayerNode?
            let lies = existing[id].map { known in shown[id] ?? Shown(frame: known.frame, ink: known.content.ink, rotation: known.resolvedRotation) }
            if let lies, lies.rotation != 0 {
                drawn = LayerNode.drawing(strokes, id: id, keepingTurn: lies.rotation, about: CGPoint(x: lies.frame.midX, y: lies.frame.midY))
            } else {
                drawn = LayerNode.drawing(strokes, id: id)
            }
            guard let drawn else { continue }
            nowShown[id] = Shown(frame: drawn.frame, ink: drawn.content.ink, rotation: drawn.resolvedRotation)
            if let known = existing[id], known.frame == drawn.frame, known.content.ink == drawn.content.ink { continue }
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
