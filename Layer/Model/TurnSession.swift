import CoreGraphics
import Foundation

/// Several things being turned together as one rigid piece.
///
/// Turned step by step from where the last step left them, rounded to whole points each
/// time, things would creep: turned there and back they wouldn't land where they started.
/// So every turn is worked out afresh from the same start: each element as it was when
/// the session formed (the baseline), turned by the whole turn so far about a pivot fixed
/// at the same time. Moving the selection moves the pivot and the baseline with it.
///
/// A session holds only while each of its elements is as its last turn or move left it
/// (`matches(_:)`). Anything else that changes one, such as undo or the format panel, ends
/// it, and the next turn forms a new session from where things are then.
///
/// A group selected turns as one rigid piece: everything in it, at any depth, goes round with
/// it, and it and each group inside it turn by as much, so that their boxes go round too. One
/// group alone turns about the middle of its own box, from its own angle.
struct TurnSession: Equatable {
    /// An element's frame, in its host's points, and its angle as it keeps it.
    struct Pose: Equatable {
        var frame: CGRect
        var rotation: Double?
    }

    /// An element of the selection, or in a group selected, as it was when the session formed.
    struct Member: Equatable {
        var pose: Pose
        /// What turns its frame into canvas points.
        let placement: Placement
        /// Whether it stays put, though it counts towards the outline: when the thing selected
        /// that it is, or is in, is locked, by itself or by a group above it. A member of a
        /// group selected goes with the group whatever its own lock (spec, Lock and hide).
        let isLocked: Bool
        /// The thing selected that it is, or is in: whose lock `isLocked` is.
        let owner: DesignElement.ID
        /// A drawing goes exactly where it is put; anything else lands on whole points.
        let isDrawing: Bool
        /// A group item: only its angle is its own, its box being fitted round its members.
        let isGroup: Bool
    }

    let selection: CanvasSelection
    /// What everything turns about, in canvas points: the middle of `outline`.
    var pivot: CGPoint
    /// The box round everything selected, in canvas points, as the session formed: turned
    /// to the angle every element had then, or upright when their angles differed.
    var outline: TurnedRect
    /// How far everything has been turned since the session formed, clockwise.
    var turned: Double = 0
    /// Each element as it was when the session formed.
    private(set) var baseline: [DesignStore.ElementRef: Member]
    /// Each element's frame and angle as the last turn or move left it.
    private(set) var expected: [DesignStore.ElementRef: Pose]

    /// A session for what is selected as it is now. Nil when a screen is among it, since
    /// screens never turn, or when no element is. A group selected counts towards the outline
    /// by its box, and its members, and the groups inside it, turn with it.
    @MainActor
    static func form(for selection: CanvasSelection, in store: DesignStore) -> TurnSession? {
        #if DEBUG
        CanvasWork.turnSessionsFormed += 1
        #endif
        var baseline: [DesignStore.ElementRef: Member] = [:]
        var shapes: [TurnedRect] = []
        for thing in store.things(in: selection) {
            guard case .element(let ref) = thing else { return nil }
            guard let (element, placement) = store.resolve(ref) else { continue }
            shapes.append(TurnedRect(rect: placement.canvasRect(for: element.frame), degrees: element.resolvedRotation))
            // Locked by itself or by a group above it, it stays where it is (F4), and so does
            // everything in it. Unlocked, a group turns all of it, whatever their own locks.
            let isLocked = store.isLocked(thing)
            let turning = element.kind == .group ? [element] + store.contents(of: element.id) : [element]
            for part in turning {
                let partRef = DesignStore.ElementRef(host: ref.host, element: part.id)
                guard let partPlacement = part.id == element.id ? placement : store.resolve(partRef)?.placement else { continue }
                baseline[partRef] = Member(
                    pose: Pose(frame: part.frame, rotation: part.rotation), placement: partPlacement,
                    isLocked: isLocked, owner: element.id, isDrawing: part.kind == .drawing, isGroup: part.kind == .group
                )
            }
        }
        // One group alone, or things all at one angle, turn from that angle.
        let angles = Set(shapes.map(\.degrees))
        let shared = angles.count == 1 ? angles.first! : 0
        guard let outline = TurnedRect.enclosing(shapes, at: shared) else { return nil }
        return TurnSession(selection: selection, pivot: outline.centre, outline: outline, baseline: baseline, expected: baseline.mapValues(\.pose))
    }

    /// Where each element that doesn't stay put goes, turned `degrees` from where the session
    /// formed: its middle goes round the pivot and it turns as much on its own. A group item
    /// turns as much, and its box goes where its members do. Turned by nothing, or by whole
    /// turns, each goes back exactly to where it was.
    func placed(turnedBy degrees: Double) -> [DesignStore.ElementRef: (frame: CGRect, rotation: Double?)] {
        var placed: [DesignStore.ElementRef: (frame: CGRect, rotation: Double?)] = [:]
        for (ref, member) in baseline where !member.isLocked {
            if Rotation.normalized(degrees) == 0 {
                placed[ref] = (member.pose.frame, member.pose.rotation)
                continue
            }
            let frame = member.pose.frame
            let middle = member.placement.canvasPoint(for: CGPoint(x: frame.midX, y: frame.midY))
            let centre = member.placement.localPoint(for: Rotation.rotate(middle, about: pivot, by: degrees))
            var origin = CGPoint(x: centre.x - frame.width / 2, y: centre.y - frame.height / 2)
            if !member.isDrawing, !member.isGroup { origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded()) }
            placed[ref] = (CGRect(origin: origin, size: frame.size), Rotation.kept((member.pose.rotation ?? 0) + degrees))
        }
        return placed
    }

    /// Whether every element is still as the last turn or move left it, on the same host,
    /// and stays put or not as when the session formed: by the lock of the thing selected
    /// that it is, or is in. Locking or unlocking that changes what turns, so the next turn
    /// forms a new session from where things are.
    @MainActor
    func matches(_ store: DesignStore) -> Bool {
        var locks: [DesignElement.ID: Bool] = [:]
        return baseline.allSatisfy { ref, member in
            guard let found = store.resolve(ref), found.placement == member.placement, let pose = expected[ref] else { return false }
            guard found.element.frame == pose.frame, found.element.rotation == pose.rotation else { return false }
            let isLocked = locks[member.owner] ?? store.element(member.owner).map(store.isLockedWithItsGroups) ?? false
            locks[member.owner] = isLocked
            return isLocked == member.isLocked
        }
    }

    /// From now on, expects each element to stay as the design has it now: called once the
    /// session's own turn or move has been made.
    @MainActor
    mutating func expect(_ store: DesignStore) {
        expected = [:]
        for ref in baseline.keys {
            guard let element = store.resolve(ref)?.element else { continue }
            expected[ref] = Pose(frame: element.frame, rotation: element.rotation)
        }
    }

    /// Moves the pivot, the outline and every element's start by a distance on the canvas,
    /// as when the selection is dragged. Elements' starts land on whole points of their
    /// own, as moving puts them; a drawing's goes exactly.
    mutating func translate(by canvasDelta: CGSize) {
        pivot = CGPoint(x: pivot.x + canvasDelta.width, y: pivot.y + canvasDelta.height)
        outline.rect = outline.rect.offsetBy(dx: canvasDelta.width, dy: canvasDelta.height)
        for (ref, member) in baseline {
            var moved = member
            let scale = member.placement.scale
            var origin = CGPoint(x: member.pose.frame.minX + canvasDelta.width / scale, y: member.pose.frame.minY + canvasDelta.height / scale)
            if !member.isDrawing, !member.isGroup { origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded()) }
            moved.pose.frame.origin = origin
            baseline[ref] = moved
        }
    }

    /// The same session for the same elements after a drop gave some of them to another
    /// host (see `DesignStore.rehost(_:)`), as `selection` now has them: a group there, with
    /// everything in it, where it landed. Each one's start keeps its middle where it was on
    /// the canvas, in its new host's points, so that the turn goes on about the same pivot.
    /// What is in a group lands as the group does, scaled about the middle of its box to the
    /// new host's scale (`DesignStore.rehostGroup(_:)`): its start is scaled likewise about
    /// where that middle was before the turn so far, so that turned by as much it is where it
    /// landed, and a twist that cut the drag short goes on without a jump. Nil when
    /// `selection` isn't the same elements.
    @MainActor
    func rehosted(as selection: CanvasSelection, in store: DesignStore) -> TurnSession? {
        var refs: [DesignElement.ID: DesignStore.ElementRef] = [:]
        for thing in selection.things {
            guard case .element(let ref) = thing else { return nil }
            refs[ref.element] = ref
            guard store.groupItem(ref.element) != nil else { continue }
            for part in store.contents(of: ref.element) {
                refs[part.id] = DesignStore.ElementRef(host: ref.host, element: part.id)
            }
        }
        guard Set(refs.keys) == Set(baseline.keys.map(\.element)) else { return nil }
        // The middle of each group selected as it was before it landed, as the session last
        // left it, taken back through the turn so far: what its start is scaled about.
        var middles: [DesignElement.ID: CGPoint] = [:]
        for (old, member) in baseline where member.isGroup && member.owner == old.element {
            guard let box = expected[old]?.frame else { continue }
            let middle = member.placement.canvasPoint(for: CGPoint(x: box.midX, y: box.midY))
            middles[old.element] = Rotation.normalized(turned) == 0 ? middle : Rotation.rotate(middle, about: pivot, by: -turned)
        }
        var moved: [DesignStore.ElementRef: Member] = [:]
        for (old, member) in baseline {
            guard let ref = refs[old.element], let placement = store.resolve(ref)?.placement else { return nil }
            guard placement != member.placement else {
                moved[ref] = member
                continue
            }
            let frame = member.pose.frame
            var onCanvas = member.placement.canvasPoint(for: CGPoint(x: frame.midX, y: frame.midY))
            if let groupMiddle = middles[member.owner] {
                onCanvas = DesignStore.landedMiddle(of: onCanvas, about: groupMiddle, from: member.placement, to: placement)
            }
            let middle = placement.localPoint(for: onCanvas)
            var origin = CGPoint(x: middle.x - frame.width / 2, y: middle.y - frame.height / 2)
            if !member.isDrawing, !member.isGroup { origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded()) }
            moved[ref] = Member(
                pose: Pose(frame: CGRect(origin: origin, size: frame.size), rotation: member.pose.rotation),
                placement: placement, isLocked: member.isLocked, owner: member.owner, isDrawing: member.isDrawing, isGroup: member.isGroup
            )
        }
        var session = TurnSession(selection: selection, pivot: pivot, outline: outline, turned: turned, baseline: moved, expected: [:])
        session.expect(store)
        return session
    }

    /// The outline as it stands now: the box it formed as, turned as far as everything has
    /// been. It goes round rigidly with them, so it, and the knob that hangs off it, never jump.
    var shape: TurnedRect {
        TurnedRect(rect: outline.rect, degrees: Rotation.normalized(outline.degrees + turned))
    }
}
