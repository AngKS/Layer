import CoreGraphics
import Foundation

/// Several things being turned together as one rigid piece.
///
/// Turned step by step from where the last step left them, rounded to whole points each
/// time, things would creep: turned there and back they wouldn't land where they started.
/// So every turn is worked out afresh from the same start: each thing as it was when the
/// session formed (its base), turned by the whole turn so far about a pivot fixed at the
/// same time. Moving the selection moves the pivot and the bases with it.
///
/// Its parts are the things selected, each where it is on the canvas: its middle in canvas
/// points and its angle summed with those of what holds it (`Pose`), so that things on
/// different screens and the open canvas turn about one pivot. A container is one rigid part:
/// it goes round, and everything in it goes with it, as it is in it. A thing a row, column,
/// grid or overlay lays out turns in place: the engine places it. Each pose is written back
/// through its parent's inverse transform (`DesignStore.setCanvasPoses`).
///
/// A session holds only while each part is as its last turn or move left it, and each thing
/// selected is locked or not as when it formed (`matches(_:)`). Anything else that changes
/// one, such as undo or the format panel, ends it, and the next turn forms a new session from
/// where things are then.
struct TurnSession: Equatable {
    /// Where a thing is on the canvas: its middle, in canvas points, and its angle summed with the angles of what
    /// holds it, clockwise.
    struct Pose: Equatable, Sendable {
        var centre: CGPoint
        var degrees: Double
    }

    /// A thing selected that turns, as it was when the session formed.
    struct Part: Equatable, Sendable {
        var id: UUID
        var base: Pose
        /// A row, column, grid or overlay lays it out: it takes the angle only, and its middle stays where the
        /// engine puts it.
        var turnsInPlace: Bool
    }

    /// A part's own frame, in its parent's space, and its own angle, as the session formed: what a turn that comes
    /// back round to where it began puts back as it was, so that the arithmetic of going round leaves no trace. Put
    /// back only while its parent's space is `parentSpace` still: a group sized to fit moves its box, and every frame
    /// in it, as what it holds turns past its edges.
    struct Start: Equatable, Sendable {
        var frame: CGRect
        var rotation: Double?
        var parentSpace: TreeIndex.OwnSpace
    }

    let selection: CanvasSelection
    /// What everything turns about, in canvas points: the middle of `outline`.
    var pivot: CGPoint
    /// The box round everything selected, in canvas points, as the session formed: turned
    /// to the angle every thing had then, or upright when their angles differed.
    var outline: TurnedRect
    /// How far everything has been turned since the session formed, clockwise.
    var turned: Double = 0
    /// The things selected that turn, as they were when the session formed.
    var parts: [Part]
    /// The things selected that stay put, being locked by themselves or by a container above them. They count
    /// towards the outline.
    private(set) var held: Set<UUID>
    /// Each part's own frame and angle as the session formed, while neither a move nor a landing has changed
    /// where it starts from.
    private(set) var starts: [UUID: Start]
    /// Each part's pose as the last turn or move left it.
    private(set) var expected: [UUID: Pose]

    /// A session for what is selected as it is now. Nil when a screen is among it, since
    /// screens never turn, or when nothing is. A thing selected counts towards the outline
    /// by its turned shape, locked or not.
    @MainActor
    static func form(for selection: CanvasSelection, in store: DesignStore) -> TurnSession? {
        #if DEBUG
        CanvasWork.turnSessionsFormed += 1
        #endif
        var parts: [Part] = []
        var held: Set<UUID> = []
        var starts: [UUID: Start] = [:]
        var shapes: [TurnedRect] = []
        for thing in store.things(in: selection) {
            guard case .element(let ref) = thing else { return nil }
            guard let placed = store.placed(ref) else { continue }
            let shape = placed.canvasShape
            shapes.append(shape)
            // Locked by itself or by a container above it, it stays where it is (F4), and so does everything in it.
            // Unlocked, a container turns all of it, whatever their own locks.
            guard !placed.isLocked else {
                held.insert(ref.node)
                continue
            }
            parts.append(Part(id: ref.node, base: Pose(centre: shape.centre, degrees: placed.degrees), turnsInPlace: placed.isLaidOut))
            if let parentSpace = store.index.posed(ref.node, in: store.tree)?.parentSpace {
                starts[ref.node] = Start(frame: placed.node.frame, rotation: placed.node.rotation, parentSpace: parentSpace)
            }
        }
        // Things all at one angle turn from that angle. One thing's outline is its own shape, so that it turns
        // about its own middle exactly.
        let angles = Set(shapes.map(\.degrees))
        let shared = angles.count == 1 ? angles.first! : 0
        let enclosing = shapes.count == 1 && shapes[0].degrees == shared ? shapes.first : TurnedRect.enclosing(shapes, at: shared)
        guard let outline = enclosing else { return nil }
        var session = TurnSession(selection: selection, pivot: outline.centre, outline: outline, parts: parts, held: held,
                                  starts: starts, expected: [:])
        session.expect(store)
        return session
    }

    /// Where each part goes, turned `degrees` from where the session formed: its middle goes round the pivot, unless
    /// it turns in place, and it turns as much on its own. Turned by nothing, or by whole turns, each goes back to
    /// its base exactly.
    func placed(turnedBy degrees: Double) -> [UUID: Pose] {
        let isBack = Rotation.normalized(degrees) == 0
        var placed: [UUID: Pose] = [:]
        for part in parts {
            if isBack {
                placed[part.id] = part.base
                continue
            }
            let centre = part.turnsInPlace ? part.base.centre : Rotation.rotate(part.base.centre, about: pivot, by: degrees)
            placed[part.id] = Pose(centre: centre, degrees: part.base.degrees + degrees)
        }
        return placed
    }

    /// The own frames and angles to put back as they were, for a turn of `degrees` that comes back round to where the
    /// session formed: each part's start, while it has one. Empty for any other turn.
    func startsPutBack(turnedBy degrees: Double) -> [UUID: Start] {
        Rotation.normalized(degrees) == 0 ? starts : [:]
    }

    /// Whether every part is still as the last turn or move left it, and each thing selected
    /// stays put or not as when the session formed: locking or unlocking one changes what
    /// turns, so the next turn forms a new session from where things are.
    @MainActor
    func matches(_ store: DesignStore) -> Bool {
        for part in parts {
            guard let placed = store.placed(part.id), !placed.isLocked, Self.pose(of: placed) == expected[part.id] else { return false }
        }
        return held.allSatisfy { store.placed($0)?.isLocked == true }
    }

    /// From now on, expects each part to stay as the design has it now: called once the
    /// session's own turn or move has been made. A part a move has taken out of what laid it
    /// out turns round the pivot from then on, and one put into a layout turns in place.
    @MainActor
    mutating func expect(_ store: DesignStore) {
        expected = [:]
        for index in parts.indices {
            guard let placed = store.placed(parts[index].id) else { continue }
            expected[parts[index].id] = Self.pose(of: placed)
            parts[index].turnsInPlace = placed.isLaidOut
        }
    }

    /// Moves the pivot, the outline and every part's base by a distance on the canvas, as
    /// when the selection is dragged. Where each part starts from is then its base, landed on
    /// whole points as a turn lands it (`DesignStore.setCanvasPoses`).
    mutating func translate(by canvasDelta: CGSize) {
        pivot = CGPoint(x: pivot.x + canvasDelta.width, y: pivot.y + canvasDelta.height)
        outline.rect = outline.rect.offsetBy(dx: canvasDelta.width, dy: canvasDelta.height)
        for index in parts.indices {
            let centre = parts[index].base.centre
            parts[index].base.centre = CGPoint(x: centre.x + canvasDelta.width, y: centre.y + canvasDelta.height)
        }
        starts = [:]
    }

    /// The same session for the same things after a drop gave some of them to another host
    /// (see `DesignStore.rehost(_:)`), as `selection` now has them. A part that isn't where the
    /// session last left it starts from where it landed, taken back through the turn so far, so
    /// that turned by as much it is where it landed, and the turn goes on about the same pivot
    /// without a jump. Nil when `selection` isn't the same things.
    @MainActor
    func rehosted(as selection: CanvasSelection, in store: DesignStore) -> TurnSession? {
        var ids: Set<UUID> = []
        for thing in selection.things {
            guard case .element(let ref) = thing else { return nil }
            ids.insert(ref.node)
        }
        guard ids == Set(parts.map(\.id)).union(held) else { return nil }
        var session = TurnSession(selection: selection, pivot: pivot, outline: outline, turned: turned, parts: parts, held: held,
                                  starts: starts, expected: expected)
        let isTurned = Rotation.normalized(turned) != 0
        for index in session.parts.indices {
            let id = session.parts[index].id
            guard let placed = store.placed(id) else { return nil }
            let now = Self.pose(of: placed)
            guard now != expected[id] else { continue }
            var base = now
            if isTurned {
                if !placed.isLaidOut { base.centre = Rotation.rotate(now.centre, about: pivot, by: -turned) }
                base.degrees = now.degrees - turned
            }
            session.parts[index].base = base
            session.starts[id] = nil
        }
        session.expect(store)
        return session
    }

    /// The outline as it stands now: the box it formed as, turned as far as everything has
    /// been. It goes round rigidly with them, so it, and the knob that hangs off it, never jump.
    var shape: TurnedRect {
        TurnedRect(rect: outline.rect, degrees: Rotation.normalized(outline.degrees + turned))
    }

    /// A thing's pose where the tree has it.
    private static func pose(of placed: PlacedNode) -> Pose {
        Pose(centre: placed.canvasShape.centre, degrees: placed.degrees)
    }
}
