import SwiftUI

/// The handles on the canvas for selecting and moving things. With the palette away,
/// elements are tapped to select and dragged to move, anywhere on the canvas, and resized
/// by their corner handles. With the palette up the Pencil draws everywhere, so only
/// what a finger has selected takes touches here. A selected screen or
/// drawing is dragged by its whole area; a screen can also be dragged by its name.
/// A drawing is an element, moved and resized like the rest: its ink goes with its frame.
/// A selected element is outlined and handled on its turned box, and turned by its knob
/// (`RotateKnob`). When several things are selected, each is outlined, dragging any one
/// moves them all, and the knob turns them all as one piece.
///
/// Everything here is in the view's own points, so handles and outlines stay the same
/// size at any zoom. Screens and drawings that aren't selected have no handle of their
/// own, which leaves a drag across them free to pan the canvas.
struct SelectionLayer: View {
    /// The layer's coordinate space: the view's own points, as the viewport has them.
    static let space = "SelectionLayer"
    @Environment(AppModel.self) private var model
    /// Shared with the element targets, which draw in canvas points in a view of their own.
    @State private var drags = CanvasDrags()

    var body: some View {
        let store = model.store
        let viewport = model.viewport
        let tree = store.tree
        // Read from the tree: the canvas never lowers the design to its list (F12, F13).
        let selectedTreeScreen = model.selectedScreenID.flatMap(store.treeScreen)
        let selected = model.selectedNode
        ZStack(alignment: .topLeading) {
            SelectionSummary()
            if let screen = selectedTreeScreen {
                dragArea(viewport.viewRect(for: screen.canvasFrame(on: tree.device(of: screen))))
                    // A tap reaches what it would without the area: the screen's empty area,
                    // which lets go of it as the canvas does, or, with the palette up, an
                    // element on it.
                    .onTapGesture(coordinateSpace: .named(Self.space)) { model.selectionAreaTapped(at: $0) }
                    .canvasDrag(drags, model: model, isEnabled: screen.isLocked != true) { drags.moveScreen(screen.id, model: model, owner: $0) }
            }
            // Every element's target, laid out once in canvas points and moved as one by
            // the viewport. Panning changes a single transform rather than every target. With
            // the palette up they take no touches, and aren't built at all (audit C8).
            if model.tool == .select {
                InViewport {
                    ElementTargets(drags: drags)
                }
            }

            // With the palette up, the selected thing is moved by its own area. So is a
            // selected drawing at any time: it has no target of its own among the elements'.
            // A tap in the area reaches what lies under it, as it would without the area: a
            // drawing's box can hold other things (audit C12). A container's area moves it as
            // what is selected moves, everything in it with it.
            if let selected, model.tool == .draw || !selected.isPickedByItsFrame {
                let area = dragArea(viewport.viewRect(for: selected.placement.canvasRect(for: selected.frame)), degrees: selected.degrees)
                    .onTapGesture(coordinateSpace: .named(Self.space)) { model.selectionAreaTapped(at: $0) }
                // Locked by itself or by a container above it, it isn't moved (F4).
                if selected.node.isContainer {
                    area.canvasDrag(drags, model: model, isEnabled: !selected.isLocked) { drags.moveSelection(model: model, owner: $0) }
                } else {
                    area.canvasDrag(drags, model: model, isEnabled: !selected.isLocked) { owner in
                        drags.adjust(selected.ref, findsNewHome: true, model: model, owner: owner) { [drags] placed in
                            drags.moveRule(for: placed, model: model)
                        }
                    }
                }
            }

            // Several things at once: each is outlined on its turned shape, any of them
            // drags them all, and a tap on one takes it out. A screen's area lies over what
            // is on it, so a tap there reaches that, or the screen's empty area, instead. A
            // tap on a selected group finds what is under it, as on the group's own target:
            // ink, then the thing in it there, so a double-tap goes into it.
            // They have no handles: together they aren't resized, but they turn as one by
            // the knob.
            if case .several = model.selection {
                let things = model.selectedThings
                let isLocked = model.isSelectionLocked
                ForEach(things, id: \.self) { thing in
                    if let shape = store.canvasShape(of: thing).map(viewport.viewShape(for:)) {
                        dragArea(shape.rect, degrees: shape.degrees)
                            .onTapGesture(coordinateSpace: .named(Self.space)) { point in
                                if case .screen = thing { model.selectionAreaTapped(at: point) } else { model.targetTapped(thing, at: point) }
                            }
                            .canvasDrag(drags, model: model, isEnabled: !isLocked) { drags.moveSelection(model: model, owner: $0) }
                    }
                }
                if model.isAdjusting {
                    SnapGuidesOverlay(guides: drags.guides, placement: drags.guidePlacement, viewport: viewport)
                }
                ForEach(things, id: \.self) { thing in
                    if let shape = store.canvasShape(of: thing).map(viewport.viewShape(for:)) {
                        outline(shape.rect, degrees: shape.degrees, radius: cornerRadius(of: thing) * viewport.scale)
                    }
                }
                if let shape = model.selectionShape {
                    groupOutline(viewport.viewShape(for: shape))
                }
            }

            if let screen = selectedTreeScreen {
                let device = tree.device(of: screen)
                outline(viewport.viewRect(for: screen.canvasFrame(on: device)), radius: device.cornerRadius * screen.scale * viewport.scale)
            }
            // Below the corner handles, which win where a small element's handles and knob meet.
            RotateKnob()
            if let selected {
                // The thing's turned box: its outline, handles and badge go round with it.
                let shape = viewport.viewShape(for: selected.canvasShape)
                // Not while it turns: the gaps jitter as it goes round, and their labels would
                // cover the angle beside the knob. Nor for a container, whose box holds things the
                // gaps would be measured to, nor while it is lifted, as it stays where it is.
                if model.isAdjusting, !model.isTurning, !drags.isLifting, !selected.node.isContainer, store.canvas.showsMeasurements,
                   case .screen(let id) = selected.ref.host, let screen = store.treeScreen(id) {
                    let device = tree.device(of: screen)
                    let others = store.leafBounds(on: selected.ref.host, besides: selected.ref.element, in: selected.placement)
                    SpacingOverlay(guides: .measure(TurnedRect(rect: selected.frame, degrees: selected.degrees).bounds, among: others,
                                                    in: CGRect(origin: .zero, size: device.size)),
                                   placement: screen.placement, screenFrame: screen.canvasFrame(on: device), viewport: viewport)
                }
                if model.isAdjusting {
                    SnapGuidesOverlay(guides: drags.guides, placement: drags.guidePlacement, viewport: viewport)
                }
                outline(shape.rect, degrees: shape.degrees, radius: selected.node.resolvedCornerRadius(tokens: tree.settings.tokens) * selected.placement.scale * viewport.scale)
                // Locked by itself or by a container above it: a thing in a locked container,
                // selected by a double-tap or a Layers row, isn't resized either (F4).
                if selected.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.accent.color, in: .circle)
                        .position(TurnedRect(rect: shape.rect.insetBy(dx: -4, dy: -4), degrees: shape.degrees).corner(.topRight))
                        .accessibilityLabel("Locked")
                } else {
                    ForEach(ElementLayout.Corner.allCases, id: \.self) { corner in
                        handle(corner, on: shape, for: selected)
                    }
                }
            }
            // A thing lifted out of a row, column or grid, and the line where any one thing dragged would go.
            LayoutDrag(drags: drags)
        }
        // The view's own points, which the element targets, drawn in canvas points, are
        // touched in: what lies under a touch is found in them.
        .coordinateSpace(.named(Self.space))
        // A tick as a turn snaps to the 45s; none as it leaves.
        .sensoryFeedback(.alignment, trigger: model.snappedTurn) { _, snapped in snapped != nil }
        // A tick for each thing a tap adds to the selection or takes out of it.
        .sensoryFeedback(.selection, trigger: model.tapSelectionChanges)
        // The model ends a drag left live: see `CanvasDrags.endAny`.
        .onAppear { model.drags = drags }
    }

    /// How round a selected thing's corners are, in canvas points, read from the tree: a node's own
    /// radius, else its kind's or a card's from the design's tokens; a screen's device's.
    private func cornerRadius(of thing: CanvasSelection) -> CGFloat {
        let store = model.store
        switch thing {
        case .element(let ref):
            return store.placed(ref).map { $0.node.resolvedCornerRadius(tokens: store.tree.settings.tokens) * $0.placement.scale } ?? 0
        case .screen(let id):
            return store.treeScreen(id).map { store.tree.device(of: $0).cornerRadius * $0.scale } ?? 0
        case .several:
            return 0
        }
    }

    /// A light dashed box round everything selected, which shows several things as one
    /// selection. It is turned as their outline is, and goes round with them as they turn.
    private func groupOutline(_ shape: TurnedRect) -> some View {
        let outer = shape.rect.insetBy(dx: -9, dy: -9)
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.accent.color.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(width: outer.width, height: outer.height)
            .rotationEffect(.degrees(shape.degrees))
            .position(x: outer.midX, y: outer.midY)
            .allowsHitTesting(false)
    }

    // MARK: Pieces

    /// An invisible area that takes touches, at least big enough for a finger, turned
    /// `degrees` about its centre so that a turned element's empty corners don't take them.
    private func dragArea(_ rect: CGRect, degrees: Double = 0) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: max(rect.width, 30), height: max(rect.height, 30))
            .rotationEffect(.degrees(degrees))
            .position(x: rect.midX, y: rect.midY)
    }

    /// A corner handle just outside the thing's turned box, in the view. Dragged, the
    /// thing is resized in its own axes, and the corner across from it stays put. A container
    /// is resized in proportion, everything in it scaled alike (see `DesignStore.resizeGroup`).
    private func handle(_ corner: ElementLayout.Corner, on shape: TurnedRect, for selected: PlacedNode) -> some View {
        let point = TurnedRect(rect: shape.rect.insetBy(dx: -6, dy: -6), degrees: shape.degrees).corner(corner)
        return Circle()
            .fill(Theme.chrome)
            .overlay { Circle().strokeBorder(Theme.accent.color, lineWidth: 1.5) }
            .frame(width: 11, height: 11)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .position(point)
            .canvasDrag(drags, model: model) { owner in
                drags.adjust(selected.ref, findsNewHome: false, model: model, owner: owner) { placed in
                    CanvasDrags.resizeRule(for: placed.node.isContainer ? .group : placed.node.kind, degrees: placed.degrees, corner: corner)
                }
            }
    }

    /// The selection's outline round a box, turned `degrees` about its centre.
    private func outline(_ rect: CGRect, degrees: Double = 0, radius: CGFloat) -> some View {
        let outer = rect.insetBy(dx: -3, dy: -3)
        return RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
            .strokeBorder(Theme.accent.color, lineWidth: 1.5)
            .frame(width: outer.width, height: outer.height)
            .rotationEffect(.degrees(degrees))
            .position(x: outer.midX, y: outer.midY)
            .allowsHitTesting(false)
    }

}


/// What is selected and its size, for VoiceOver and automation rather than the eye. A view
/// of its own, so that it isn't worked out again on every frame of a pan, as the outlines are.
struct SelectionSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let summary = Self.value(for: model) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Selection")
                .accessibilityValue(summary)
                .accessibilityIdentifier("Selection")
                .accessibilityActions {
                    if model.canTurnSelection {
                        Button("Rotate 15° clockwise") { model.rotateSelection(by: 15) }
                        Button("Rotate 15° counterclockwise") { model.rotateSelection(by: -15) }
                        Button("Reset rotation") { model.resetSelectionRotation() }
                    }
                }
        }
    }
}

extension SelectionSummary {
    /// "W × H"; "Row · W × H", "Column", "Grid", "Overlay", "Card" or "Group · W × H" (F7's words); "Drawing · N
    /// strokes"; "N items · W × H"; "<screen> · W × H". Read from the tree.
    @MainActor static func value(for model: AppModel) -> String? {
        if case .several(let things) = model.selection, let area = model.store.canvasFrame(of: .several(things)) {
            return "\(things.count) items · \(area.width.rounded().wholePoints) × \(area.height.rounded().wholePoints)"
        }
        if let selected = model.selectedNode {
            let node = selected.node
            let size = "\(selected.frame.width.wholePoints) × \(selected.frame.height.wholePoints)"
            if node.kind == .drawing {
                let strokes = node.content.ink.flatMap { DecodedInk.drawing(node.id, ink: $0) }?.strokes.count ?? 0
                return strokes == 1 ? "Drawing · 1 stroke" : "Drawing · \(strokes) strokes"
            }
            // A container is told apart from a thing, by VoiceOver and the UI tests, by what it is.
            return node.isContainer ? "\(node.kindName) · \(size)" : size
        }
        if let id = model.selectedScreenID, let screen = model.store.treeScreen(id) {
            // A device's size is as a file held it, which may be too large for a whole number (`wholePoints`).
            let size = model.store.tree.device(of: screen).size
            return "\(screen.name) · \(size.width.wholePoints) × \(size.height.wholePoints)"
        }
        return nil
    }
}

/// Where a drag on the canvas started, and what a dragged element has snapped to. Kept in
/// an object of its own so that the element targets, which draw in a separate view, and the
/// handles share one drag at a time.
///
/// SwiftUI doesn't call `onEnded` for a drag it cancels: when the view carrying it leaves
/// mid-drag (the Pencil lands on what a finger is dragging, or a command changes the
/// selection or the tool), or a system gesture takes the touch. Each view with a drag
/// therefore has an `Owner`, and the drag under way is ended when its owner's gesture
/// state resets or the view goes (see `canvasDrag`), or when a drag starts that isn't it.
/// However a drag ends, what it moved lands as a drop would land it: on whatever it lies
/// over, in the drag's own step (audit C4).
///
/// Two fingers that twist the selection end the drag the first of them had begun, and
/// SwiftUI may go on reporting it, or a drag either of them begins meanwhile, until they
/// lift. Those are left alone: they neither move anything nor drop it.
@MainActor @Observable
final class CanvasDrags {
    /// Moves a dragged element: from its frame as the drag began, by the translation in its
    /// own points, to its new frame and the lines it snapped to.
    typealias Rule = (_ origin: CGRect, _ translation: CGSize) -> (CGRect, [SnapGuide])

    /// Stands for one view that carries a drag.
    @MainActor final class Owner {
        init() {
            #if DEBUG
            CanvasWork.ownersMade += 1
            #endif
        }

        /// For an element's target: where its drag began, and the drawing whose ink was
        /// there, which the drag moves instead (see `moveOnTarget`). Kept for the whole drag,
        /// since the ink moves away from where the drag began.
        fileprivate var ink: (start: CGPoint, drawing: DesignStore.ElementRef?)?
    }

    /// A thing in a row, column, grid or overlay as a drag of it goes (plan 4, call 3): it stays where it is, and
    /// nothing is written until it is let go, while a copy follows the finger (`LayoutDrag`).
    struct Lift: Equatable {
        var ref: DesignStore.ElementRef
        /// Its own frame as the drag began, in its host's own points.
        var start: CGRect
        /// How far the finger has taken it, in its host's own points.
        var translation: CGSize
        /// Where it goes if it is let go now.
        var target: TreeDrop.Target
    }

    /// The lines the dragged element has snapped to, and the placement of their points.
    var guides: [SnapGuide] = []
    var guidePlacement = Placement(origin: .zero, scale: 1)
    /// A laid-out child's drag; nil otherwise.
    private(set) var lift: Lift?
    /// The line any single drag shows, free drags included: where the one thing dragged would go if it were let go
    /// now. Nil for several things dragged together, for a resize, and between drags.
    private(set) var dropTarget: TreeDrop.Target?
    /// Whether a lift is under way: set as it begins and ends, so that what reads it isn't drawn again on its every
    /// frame, as what reads `lift` is.
    private(set) var isLifting = false
    /// What a lift under way lifts, unobserved: the canvas keeps its screen on top (`AppModel.screensBeingDraggedFrom`).
    @ObservationIgnored private(set) var lifted: DesignStore.ElementRef?
    /// The drag under way: whose it is, and where on the glass it began.
    @ObservationIgnored private var session: (owner: Owner, start: CGPoint)?
    /// The frame an element had when the current drag began.
    @ObservationIgnored private(set) var elementOrigin: CGRect?
    @ObservationIgnored private(set) var screenOrigin: CGPoint?
    /// Where each of several selected things was on the canvas when the drag that moves
    /// them all began.
    @ObservationIgnored private(set) var groupOrigins: [CanvasSelection: CGRect]?
    /// How the dragged element moves, worked out as its drag begins rather than whenever
    /// the targets are drawn.
    @ObservationIgnored private var rule: Rule?
    /// A container a handle resizes, as the drag began: every frame resizes it from there.
    @ObservationIgnored private var groupPose: DesignStore.GroupPose?
    /// A thing a row, column, grid or overlay lays out, as a handle resizing it began: each frame writes only the axes it
    /// changes from there, fixed at their new sizes, puts the others back as they were, and the engine places it
    /// (`resizeLaidOut`).
    @ObservationIgnored private var laidOutStart: LayerNode?
    /// The one thing a drag moves on its own, and how its host's points sit on the canvas, read from the tree as the
    /// drag began. Nil while several things are dragged together, and for a screen.
    @ObservationIgnored private var oneThing: (ref: DesignStore.ElementRef, placement: Placement)?
    /// The boxes on the canvas, as the drag began, of the free containers round the one thing placed freely: while
    /// the finger is in one, it keeps the thing (`TreeDrop`). Its box grows round the thing as it is dragged.
    @ObservationIgnored private var startBoxes: [UUID: TurnedRect] = [:]
    /// Whether the finger, as last seen, is in one of those boxes: the thing stays in its free group when let go there,
    /// even over a screen it would otherwise go to (fix round 2, N2).
    @ObservationIgnored private var isInItsGroupsBox = false

    var isDragging: Bool { session != nil }

    /// Whether the change being made now is the drag's own: a frame of it, or its landing.
    /// That neither locks nor takes away what it moves.
    func isMakingChange(in store: DesignStore) -> Bool {
        guard let acting = store.actingEdit else { return false }
        return acting === edit || acting === handedOver
    }

    /// The drag under way's own step: see `DesignStore.Edit`.
    @ObservationIgnored private var edit: DesignStore.Edit?

    /// Gives the drag under way's step to a turn that cuts it short, so that the move so far
    /// and the turn are one step. The drag then ends without ending it, and what it moved
    /// lands in that step.
    func handOverEdit() -> DesignStore.Edit? {
        defer { edit = nil }
        handedOver = edit
        return edit
    }

    /// The drag's step, given to the turn that cut it short, until the drag has ended.
    @ObservationIgnored private var handedOver: DesignStore.Edit?

    /// Opens the drag's step as it begins, named for what it does.
    private func beginEdit(model: AppModel, named name: String = String(localized: "Move")) {
        if let edit { model.store.endEdit(edit) }
        edit = model.store.beginEdit()
        model.store.name(edit, name)
    }

    /// Closes the drag's step, and nothing else under way.
    private func endEdit(model: AppModel) {
        guard let edit else { return }
        self.edit = nil
        model.store.endEdit(edit)
    }

    /// What the drag under way moves.
    @ObservationIgnored private var dragged: [CanvasSelection] = []
    /// Whether what the drag under way moves belongs to whatever it lies on as it ends: an
    /// element moved, or several things. Not an element resized by a handle, nor a screen.
    @ObservationIgnored private var findsNewHome = false

    /// Ends the drag under way, whoever's it is. A backstop for a cancel SwiftUI didn't
    /// report: while a drag is live every other is ignored, so one left live would stop all
    /// dragging. Called as the design closes, when the tool changes, and as two fingers
    /// begin to twist the selection. Whatever SwiftUI still reports of it is left alone.
    func endAny(model: AppModel) {
        guard let session else { return }
        leaveAlone(session.owner, startingAt: session.start)
        endAbandoned(model: model)
    }

    /// A drag that is left alone until its finger lifts: whose it is, and where it began.
    private struct LeftAlone {
        weak var owner: Owner?
        var start: CGPoint
    }

    @ObservationIgnored private var leftAlone: [LeftAlone] = []

    private func leaveAlone(_ owner: Owner, startingAt start: CGPoint) {
        leftAlone.removeAll { $0.owner == nil || $0.owner === owner }
        leftAlone.append(LeftAlone(owner: owner, start: start))
    }

    /// Ends the drag under way if what it moves has been locked or taken away, by a spoken
    /// command for instance: its gesture is disabled or its view gone, which may not be heard.
    /// Whatever SwiftUI still reports of it is left alone.
    func endIfDraggedIsGone(model: AppModel) {
        guard let session else { return }
        let store = model.store
        if dragged.contains(where: { store.canvasFrame(of: $0) == nil || store.isLocked($0) }) {
            leaveAlone(session.owner, startingAt: session.start)
            endAbandoned(model: model)
        }
    }

    private enum Turn { case new, continuing, ignored }

    /// Whether a drag is new, goes on, or is to be left alone. Another view's drag under way
    /// is a second finger, and the new one is left alone: taking over, the two made every
    /// frame a step. A drag SwiftUI cancelled has already been ended by its owner's gesture
    /// state resetting, or its view going (see `canvasDrag`). A new touch on the same view
    /// means the one before was cancelled: it is ended first, leaving nothing behind. What
    /// it moved lands then, apart from what the new touch moves (`moving`), which the view
    /// has as it lay, on its old host: that lands as the new touch ends.
    /// While two fingers twist the selection, a drag that begins is one of theirs.
    private func begins(_ owner: Owner, at start: CGPoint, moving: @autoclosure () -> Set<CanvasSelection>, model: AppModel) -> Turn {
        if let index = leftAlone.firstIndex(where: { $0.owner === owner }) {
            if leftAlone[index].start == start { return .ignored }
            // That touch ended without a word: this is a new one.
            leftAlone.remove(at: index)
        }
        if model.isTwisting {
            leaveAlone(owner, startingAt: start)
            return .ignored
        }
        if let session {
            guard session.owner === owner else { return .ignored }
            if session.start == start { return .continuing }
            endAbandoned(model: model, keeping: moving())
        }
        session = (owner, start)
        return .new
    }

    /// Ends the drag under way where it is, if it is this owner's: SwiftUI cancelled it. Its
    /// `onEnded`, if it comes after all, is left alone: it has landed already.
    func cancel(_ owner: Owner, model: AppModel) {
        guard let session, session.owner === owner else { return }
        leaveAlone(owner, startingAt: session.start)
        endAbandoned(model: model)
    }

    /// Ends the drag under way without its drop. What it moved lands all the same, as the
    /// drop would land it: on whatever it now lies over, or into the row whose line shows, in
    /// the drag's step, or the turn's that cut it short. Left where it was, an element dragged
    /// from one screen onto another stayed the first one's, and was drawn under the second
    /// (audit C4). `keeping` is what a new touch on the same view goes on to move.
    private func endAbandoned(model: AppModel, keeping: Set<CanvasSelection> = []) {
        let landing = findsNewHome ? dragged.filter { !keeping.contains($0) } : []
        let drop = oneThing.map { _ in (lift: lift, target: dropTarget, staying: isInItsGroupsBox) }
        let step = edit ?? handedOver
        finish(model: model)
        if !landing.isEmpty {
            model.store.act(for: step) {
                if let drop {
                    model.rehost(landing) {
                        Self.land($0, lift: drop.lift, at: drop.target, stayingInItsGroup: drop.staying, in: model.store)
                    }
                } else {
                    model.rehost(landing)
                }
            }
        }
        endEdit(model: model)
    }

    /// Whether `onEnded` belongs to the drag under way. That of a drag left alone doesn't:
    /// its finger has lifted, and that is all. Nor does one that comes after its drag was
    /// ended some other way, which left it alone, having landed what it moved.
    private func ends(_ owner: Owner) -> Bool {
        if let index = leftAlone.firstIndex(where: { $0.owner === owner }) {
            leftAlone.remove(at: index)
            return false
        }
        return session?.owner === owner
    }

    private func finish(model: AppModel) {
        session = nil
        handedOver = nil
        findsNewHome = false
        dragged = []
        elementOrigin = nil
        screenOrigin = nil
        groupOrigins = nil
        groupPose = nil
        laidOutStart = nil
        rule = nil
        oneThing = nil
        startBoxes = [:]
        isInItsGroupsBox = false
        lifted = nil
        if lift != nil { lift = nil }
        if dropTarget != nil { dropTarget = nil }
        if isLifting { isLifting = false }
        if !guides.isEmpty { guides = [] }
        // A turn still under way is still adjusting the selection: the twist that ended
        // this drag, or the knob held while another finger let go.
        if !model.isTurning { model.isAdjusting = false }
    }

    // MARK: One thing lifted, or placed freely

    /// Lifts one thing a drag begins on, out of the row, column, grid or overlay that lays it out: nothing is
    /// written until it is let go (plan 4, call 3).
    private func beginLift(of placed: PlacedNode) {
        lift = Lift(ref: placed.ref, start: placed.frame, translation: .zero, target: .free(on: TreeIndex.Host(placed.ref.host)))
        lifted = placed.ref
        isLifting = true
    }

    /// A lift taken `translation` (its host's own points) with the finger at `finger` on the canvas: where it would
    /// go is worked out afresh, and nothing is written.
    private func follow(by translation: CGSize, finger: CGPoint, model: AppModel) {
        guard var moved = lift, let placement = oneThing?.placement else { return }
        moved.translation = translation
        let centre = placement.canvasPoint(for: CGPoint(x: moved.start.midX + translation.width, y: moved.start.midY + translation.height))
        moved.target = TreeDrop.target(for: moved.ref.element, at: finger, centre: centre, in: model.store.tree, index: model.store.index)
        if lift != moved { lift = moved }
        if dropTarget != moved.target { dropTarget = moved.target }
    }

    /// Where one thing placed freely, its middle now at `centre` on the canvas, would go if it were let go with the
    /// finger at `finger`: the line shows. True when it shows a line, which no snapping guide shows beside.
    private func aim(_ ref: DesignStore.ElementRef, centre: CGPoint, finger: CGPoint, model: AppModel) -> Bool {
        let target = TreeDrop.target(for: ref.element, at: finger, centre: centre, in: model.store.tree, index: model.store.index,
                                     startBoxes: startBoxes)
        if dropTarget != target { dropTarget = target }
        isInItsGroupsBox = startBoxes.values.contains { $0.contains(finger) }
        if case .insert = target { return true }
        return false
    }

    /// Lands one thing a drag moved, as it is let go: a lift into the slot its line shows, or out where it was let go,
    /// at the top of the host under it (`takeOut`); a thing placed freely into the row, column or grid whose line
    /// shows, or onto whatever it lies on (`rehost`), unless it is `stayingInItsGroup`, let go in its free group's box
    /// as the drag began, which keeps it as a free move. Back in the slot it was in, it stays as it is. A move the
    /// store refuses changes nothing (F15).
    private static func land(_ ref: DesignStore.ElementRef, lift: Lift?, at target: TreeDrop.Target?,
                             stayingInItsGroup: Bool = false, in store: DesignStore) {
        switch target {
        case .insert(let parent, let index, _)?:
            let isWhereItIs = store.parent(of: ref.element) == parent && store.index[ref.element]?.siblingIndex == index
            if !isWhereItIs { store.move(ref.element, to: parent, at: index) }
        case .free(let host)? where lift != nil:
            guard let lift, let placement = store.placed(ref.element)?.placement else { return }
            let letGo = CGPoint(x: lift.start.midX + lift.translation.width, y: lift.start.midY + lift.translation.height)
            store.takeOut(ref.element, to: host, centredAt: placement.canvasPoint(for: letGo))
        case .free?, nil:
            if !stayingInItsGroup { store.rehost(ref) }
        }
    }

    /// The boxes on the canvas of the free containers round a thing, as a drag of it begins: see `startBoxes`. A
    /// screen's root isn't one: it is the screen.
    private static func freeBoxes(round id: UUID, in store: DesignStore) -> [UUID: TurnedRect] {
        let index = store.index, tree = store.tree
        var boxes: [UUID: TurnedRect] = [:]
        for holder in index.ancestors(of: id) {
            guard index[holder]?.path.isEmpty == false, let node = index.node(holder, in: tree), node.resolvedLayout == .free,
                  let shape = index.canvasShape(of: holder, in: tree) else { continue }
            boxes[holder] = shape
        }
        return boxes
    }

    /// Where the finger is on the canvas: it landed at `start` in the view's points, and has gone `translation` across
    /// the glass since.
    private func fingerOnCanvas(from start: CGPoint, by translation: CGSize, model: AppModel) -> CGPoint {
        model.viewport.canvasPoint(for: CGPoint(x: start.x + translation.width, y: start.y + translation.height))
    }

    // MARK: Rules

    /// How a corner handle resizes something of a kind, turned `degrees`: an element in its own
    /// axes, keeping its shape where its kind has one; a group in proportion, so that what is in
    /// it scales alike (see `DesignStore.resizeGroup`). The corner across stays put.
    static func resizeRule(for kind: ElementKind, degrees: Double, corner: ElementLayout.Corner) -> Rule {
        { origin, translation in
            let frame = kind == .group
                ? ElementLayout.resizedProportionally(origin, degrees: degrees, from: corner, by: translation)
                : ElementLayout.resizedTurned(origin, degrees: degrees, from: corner, by: translation, kind: kind)
            return (frame, [])
        }
    }

    // PROJECTION: deleted in plan 6
    /// `moveRule(for:model:)` for an element as the projection had it: only its id is read, and the rest from the
    /// tree. One that is gone moves without lining up with anything.
    func moveRule(for element: DesignElement, placement: Placement, on screen: DesignScreen?, model: AppModel) -> Rule {
        guard let placed = model.store.placed(element.id) else {
            return { origin, translation in (ElementLayout.moved(origin, by: translation, snapsToCenter: false), []) }
        }
        return moveRule(for: placed, model: model)
    }

    /// Where a dragged thing goes: onto the grid's marks, or lined up with its screen and the
    /// visible leaves on its host besides itself and what it holds, from the index
    /// (`leafBounds`), as the canvas is set up to do. In its host's own points. Worked out once,
    /// as the drag begins.
    func moveRule(for placed: PlacedNode, model: AppModel) -> Rule {
        let store = model.store
        let canvas = store.canvas
        // Only the zoom: the viewport would make whatever builds this depend on panning too.
        let zoom = model.zoomScale
        let placement = placed.placement
        // What the thing can line up with, in its own host's points.
        let others = store.leafBounds(on: placed.ref.host, besides: placed.ref.element, in: placement)
        let container: CGRect? = if case .screen(let id) = placed.ref.host, let screen = store.treeScreen(id) {
            CGRect(origin: .zero, size: store.tree.device(of: screen).size)
        } else {
            nil
        }
        // A turned thing snaps by the box round its shape; its frame moves with the box.
        let box = TurnedRect(rect: placed.frame, degrees: placed.degrees).bounds
        let shift = CGSize(width: box.minX - placed.frame.minX, height: box.minY - placed.frame.minY)
        return { origin, translation in
            let start = CGRect(x: origin.minX + shift.width, y: origin.minY + shift.height, width: box.width, height: box.height)
            func framed(_ box: CGRect) -> CGRect {
                CGRect(x: box.minX - shift.width, y: box.minY - shift.height, width: origin.width, height: origin.height)
            }
            let moved = ElementLayout.moved(start, by: translation, snapsToCenter: false)
            if canvas.snapsToGrid {
                return (framed(ElementLayout.snappedToGrid(moved, spacing: canvas.gridSpacing, placement: placement)), [])
            }
            guard canvas.snapsToGuides else { return (framed(moved), []) }
            // Close enough is the same few points on the glass at any zoom.
            let threshold = 6 / max(placement.scale * zoom, 0.01)
            let (snapped, lines) = ElementLayout.snapped(moved, to: others, in: container, threshold: threshold)
            return (framed(snapped), lines)
        }
    }

    // MARK: One thing

    /// A drag that moves or resizes one thing. The translation is measured in the view's
    /// points, where the finger landed too. `rule` is asked for once, when the drag begins.
    func adjust(_ ref: DesignStore.ElementRef, findsNewHome: Bool, model: AppModel, owner: Owner,
                rule: @escaping (PlacedNode) -> Rule) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(SelectionLayer.space))
            .onChanged { [self] value in
                moveNode(ref, by: value.translation, startingAt: value.startLocation, findsNewHome: findsNewHome, owner: owner, model: model, rule: rule)
            }
            .onEnded { [self] _ in
                dropElement(ref, findsNewHome: findsNewHome, owner: owner, model: model)
            }
    }

    // PROJECTION: deleted in plan 6
    /// `moveNode` for an element as the projection had it: its frame and placement are read from the tree as the
    /// drag begins, not taken from what is given.
    func moveElement(
        _ ref: DesignStore.ElementRef, from frame: CGRect, placement: Placement, by glassTranslation: CGSize,
        startingAt start: CGPoint, findsNewHome: Bool = true, owner: Owner, model: AppModel, rule makeRule: () -> Rule
    ) {
        moveNode(ref, by: glassTranslation, startingAt: start, findsNewHome: findsNewHome, owner: owner, model: model) { _ in makeRule() }
    }

    /// One frame of a drag that moves or resizes one thing, read from the tree as the drag begins (`placed(_:)`): its
    /// frame, how its host's points sit on the canvas, and what holds it. `start` is where the finger landed, in the
    /// view's points, and `glassTranslation` how far it has gone since.
    ///
    /// Moved (`findsNewHome`), a thing in a row, column, grid or overlay is lifted (`lift`): nothing is written on any
    /// frame, and the line shows where it would go. A thing placed freely goes where `rule` puts it, written through its
    /// parent (`place`), and the line shows when a row, column or grid would take it, with no guides beside it.
    /// Resized, it takes `rule`'s frame: a thing laid out only the size of each axis it changed (`resizeLaidOut`), a
    /// container from its pose as the drag began (`resizeGroup`), and anything else through its parent (`resize`).
    func moveNode(
        _ ref: DesignStore.ElementRef, by glassTranslation: CGSize, startingAt start: CGPoint, findsNewHome: Bool = true,
        owner: Owner, model: AppModel, rule makeRule: (PlacedNode) -> Rule
    ) {
        let turn = begins(owner, at: start, moving: [.element(ref)], model: model)
        guard turn != .ignored else { return }
        if turn == .new {
            // Locked, by itself or by a container above it, it is neither moved nor resized (F4):
            // the drag is left alone until its finger lifts. The handles and targets of a
            // locked thing are hidden or off, but a lock can come from a container above it.
            guard let placed = model.store.placed(ref), !placed.isLocked else {
                session = nil
                leaveAlone(owner, startingAt: start)
                return
            }
            beginEdit(model: model, named: findsNewHome ? String(localized: "Move") : String(localized: "Resize"))
            dragged = [.element(ref)]
            self.findsNewHome = findsNewHome
            model.selection = .element(ref)
            oneThing = (ref, placed.placement)
            elementOrigin = placed.frame
            if findsNewHome, placed.isLaidOut {
                beginLift(of: placed)
            } else {
                if findsNewHome { startBoxes = Self.freeBoxes(round: ref.element, in: model.store) }
                // Laid out, only its size is written, and the engine places it. A container's frame is the box round what
                // is in it: they are resized, from where they were as the drag began, and the box is fitted round them.
                laidOutStart = !findsNewHome && placed.isLaidOut ? placed.node : nil
                groupPose = !findsNewHome && laidOutStart == nil && placed.node.isContainer ? model.store.groupPose(of: ref) : nil
                elementOrigin = groupPose?.box ?? placed.frame
                rule = makeRule(placed)
            }
            model.isAdjusting = true
        }
        guard let elementOrigin, let placement = oneThing?.placement else { return }
        let scale = placement.scale * model.zoomScale
        let translation = CGSize(width: glassTranslation.width / scale, height: glassTranslation.height / scale)
        let finger = fingerOnCanvas(from: start, by: glassTranslation, model: model)
        if lift != nil {
            follow(by: translation, finger: finger, model: model)
            return
        }
        guard let rule else { return }
        let (frame, snappedTo) = rule(elementOrigin, translation)
        // Set only when it differs: each setting tells whatever draws the guides to draw again.
        if guidePlacement != placement { guidePlacement = placement }
        model.store.act(for: edit) {
            if let laidOutStart = self.laidOutStart {
                model.store.resizeLaidOut(ref.element, to: frame.size, from: laidOutStart)
            } else if let groupPose {
                model.store.resizeGroup(ref, to: frame, from: groupPose)
            } else if self.findsNewHome {
                model.store.place(ref.element, at: frame)
            } else {
                model.store.resize(ref.element, to: frame)
            }
        }
        let showsLine = self.findsNewHome
            && aim(ref, centre: placement.canvasPoint(for: CGPoint(x: frame.midX, y: frame.midY)), finger: finger, model: model)
        let shown = showsLine ? [] : snappedTo
        if guides != shown { guides = shown }
    }

    /// The end of a drag of one thing. `findsNewHome`: whether it belongs to whatever it lies on as the drag ends, as
    /// it does when it is moved, though not when a handle resizes it. A lift lands in the slot its line shows, or out
    /// where it was let go; a thing placed freely joins the row, column or grid whose line shows, or whatever it lies
    /// on. Selected where it lands.
    func dropElement(_ ref: DesignStore.ElementRef, findsNewHome: Bool, owner: Owner, model: AppModel) {
        guard ends(owner) else { return }
        let (lift, target, staying) = (lift, dropTarget, isInItsGroupsBox)
        finish(model: model)
        if findsNewHome {
            let store = model.store
            store.act(for: edit) { Self.land(ref, lift: lift, at: target, stayingInItsGroup: staying, in: store) }
            model.selection = .element(store.ref(of: ref.element) ?? ref)
        }
        endEdit(model: model)
    }

    /// The drag on an element's own target, in the selection layer's points. Ink is drawn
    /// over every element, so a drag that starts on a drawing's ink moves the drawing, as a
    /// tap there picks it. What it moves is read from the tree as the drag begins, so that
    /// its target is built again only when where it lies changes, not with every change to
    /// it or to its screen (audit C6).
    func adjustOnTarget(_ ref: DesignStore.ElementRef, model: AppModel, owner: Owner) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(SelectionLayer.space))
            .onChanged { [self] value in
                moveOnTarget(ref, by: value.translation, startingAt: value.startLocation, owner: owner, model: model)
            }
            .onEnded { [self] value in
                dropOnTarget(ref, startingAt: value.startLocation, owner: owner, model: model)
            }
    }

    // PROJECTION: deleted in plan 6
    /// `moveOnTarget(_:by:startingAt:owner:model:)` as the projection's callers make it: what is given besides the
    /// ref isn't read.
    func moveOnTarget(
        _ ref: DesignStore.ElementRef, element: DesignElement, placement: Placement, on screen: DesignScreen?,
        by translation: CGSize, startingAt start: CGPoint, owner: Owner, model: AppModel
    ) {
        moveOnTarget(ref, by: translation, startingAt: start, owner: owner, model: model)
    }

    /// Moves what a drag on a thing's target moves: the thing, or the drawing whose ink lay
    /// over it where the drag began. A container's target moves the container, as a tap there
    /// picks it, with whatever else is selected along with it. `start` is in the view's points.
    func moveOnTarget(_ ref: DesignStore.ElementRef, by translation: CGSize, startingAt start: CGPoint, owner: Owner, model: AppModel) {
        let moving = ink(under: start, for: owner, model: model) ?? ref
        if moving == ref, model.store.node(ref.element)?.isContainer == true {
            moveGroup(by: translation, startingAt: start, owner: owner, model: model, selecting: .element(ref))
            return
        }
        moveNode(moving, by: translation, startingAt: start, owner: owner, model: model) { [self] placed in
            moveRule(for: placed, model: model)
        }
    }

    func dropOnTarget(_ ref: DesignStore.ElementRef, startingAt start: CGPoint, owner: Owner, model: AppModel) {
        let drawing = owner.ink.flatMap { $0.start == start ? $0.drawing : nil }
        owner.ink = nil
        if drawing == nil, groupOrigins != nil {
            dropGroup(owner: owner, model: model)
        } else {
            dropElement(drawing ?? ref, findsNewHome: true, owner: owner, model: model)
        }
    }

    /// The drawing with ink where a drag on a target began, looked up once for each drag: as
    /// it begins, and kept while it is this owner's drag under way. A drag ended any other
    /// way, and then begun again from the same point, looks again.
    private func ink(under start: CGPoint, for owner: Owner, model: AppModel) -> DesignStore.ElementRef? {
        if let ink = owner.ink, ink.start == start, session?.owner === owner { return ink.drawing }
        let drawing = model.inkTarget(at: start)
        owner.ink = (start, drawing)
        return drawing
    }

    // MARK: What is selected

    /// A drag that moves everything selected, each thing by the same distance across the
    /// canvas. Together they go to the grid's marks, or line up with what is around them,
    /// as one element does; and dropped, each element belongs to whatever it then lies on.
    /// What they have been turned about goes with them.
    func moveSelection(model: AppModel, owner: Owner) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(SelectionLayer.space))
            .onChanged { [self] value in
                moveGroup(by: value.translation, startingAt: value.startLocation, owner: owner, model: model)
            }
            .onEnded { [self] _ in
                dropGroup(owner: owner, model: model)
            }
    }

    /// `selecting`: what the drag is on, when it isn't on what is selected, such as a group's
    /// target. Unless it is among what is selected, it is selected alone as the drag begins,
    /// as an element is by a drag on it.
    ///
    /// One thing dragged on its own, a container say, is moved as one thing is (`moveNode`):
    /// lifted out of a row, column, grid or overlay that lays it out, or, placed freely, showing
    /// the line of a row, column or grid that would take it. Several keep their moves on every
    /// frame (plan 4, call 4).
    func moveGroup(by translation: CGSize, startingAt start: CGPoint, owner: Owner, model: AppModel, selecting thing: CanvasSelection? = nil) {
        let selects = thing.flatMap { model.selection?.contains($0) == true ? nil : $0 }
        let turn = begins(owner, at: start, moving: selects?.things ?? model.selection?.things ?? [], model: model)
        guard turn != .ignored else { return }
        if turn == .new {
            if let selects {
                // Locked, by itself or by a group above it, it isn't moved (F4).
                guard !model.store.isLocked(selects) else {
                    session = nil
                    leaveAlone(owner, startingAt: start)
                    return
                }
            }
            beginEdit(model: model)
            if let selects { model.selection = selects }
            model.selectionWillMove()
            var origins: [CanvasSelection: CGRect] = [:]
            for thing in model.selectedThings where !model.store.isLocked(thing) {
                origins[thing] = model.store.canvasFrame(of: thing)
            }
            groupOrigins = origins
            dragged = Array(origins.keys)
            findsNewHome = true
            if case .element(let ref)? = model.selection, origins.count == 1, origins[.element(ref)] != nil,
               let placed = model.store.placed(ref) {
                oneThing = (ref, placed.placement)
                if placed.isLaidOut {
                    beginLift(of: placed)
                } else {
                    startBoxes = Self.freeBoxes(round: ref.element, in: model.store)
                }
            }
            model.isAdjusting = true
        }
        guard let origins = groupOrigins,
              let area = origins.values.dropFirst().reduce(origins.values.first, { $0?.union($1) })
        else { return }
        let zoom = max(model.zoomScale, 0.01)
        let finger = fingerOnCanvas(from: start, by: translation, model: model)
        if lift != nil, let placement = oneThing?.placement {
            let scale = max(placement.scale * zoom, 0.01)
            follow(by: CGSize(width: translation.width / scale, height: translation.height / scale), finger: finger, model: model)
            return
        }
        var delta = CGSize(width: translation.width / zoom, height: translation.height / zoom)
        let moved = area.offsetBy(dx: delta.width, dy: delta.height)
        let canvas = model.store.canvas
        var snappedTo: [SnapGuide] = []
        if canvas.snapsToGrid, canvas.gridSpacing > 0 {
            delta.width += (moved.minX / canvas.gridSpacing).rounded() * canvas.gridSpacing - moved.minX
            delta.height += (moved.minY / canvas.gridSpacing).rounded() * canvas.gridSpacing - moved.minY
        } else if canvas.snapsToGuides {
            let others = model.store.canvasFrames(besides: Set(origins.keys))
            let (snapped, lines) = ElementLayout.snapped(moved, to: others, in: nil, threshold: 6 / zoom)
            delta.width += snapped.minX - moved.minX
            delta.height += snapped.minY - moved.minY
            snappedTo = lines
        }
        // The lines are in canvas points, as the things lined up are.
        let onCanvas = Placement(origin: .zero, scale: 1)
        if guidePlacement != onCanvas { guidePlacement = onCanvas }
        model.store.act(for: edit) {
            model.store.position(origins.mapValues { CGPoint(x: $0.minX + delta.width, y: $0.minY + delta.height) })
            model.selectionMoved(by: delta)
        }
        if let one = oneThing, let centre = model.store.placed(one.ref)?.canvasShape.centre,
           aim(one.ref, centre: centre, finger: finger, model: model) {
            snappedTo = []
        }
        if guides != snappedTo { guides = snappedTo }
    }

    func dropGroup(owner: Owner, model: AppModel) {
        guard ends(owner) else { return }
        let drop = oneThing.map { _ in (things: dragged, lift: lift, target: dropTarget, staying: isInItsGroupsBox) }
        finish(model: model)
        model.store.act(for: edit) {
            if let drop {
                model.rehost(drop.things) {
                    Self.land($0, lift: drop.lift, at: drop.target, stayingInItsGroup: drop.staying, in: model.store)
                }
            } else {
                model.rehostSelection()
            }
        }
        endEdit(model: model)
    }

    // MARK: Screens

    /// A drag that moves a screen by its name, or its area once selected, which reads the
    /// screen from the tree as the drag goes: the name's target isn't built again with every
    /// change to what is on the screen.
    func moveScreen(_ id: TreeScreen.ID, model: AppModel, owner: Owner) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { [self] value in
                moveScreen(id, by: value.translation, startingAt: value.startLocation, owner: owner, model: model)
            }
            .onEnded { [self] _ in
                dropScreen(owner: owner, model: model)
            }
    }

    /// One frame of a screen's drag: from where it was as the drag began, onto the grid's marks or lined up with the
    /// edges of the design's other screens, read from the tree and written to it (`updateTreeScreen`) (F13).
    func moveScreen(_ id: TreeScreen.ID, by translation: CGSize, startingAt start: CGPoint, owner: Owner, model: AppModel) {
        let turn = begins(owner, at: start, moving: [.screen(id)], model: model)
        guard turn != .ignored else { return }
        let store = model.store
        if turn == .new {
            guard let screen = store.treeScreen(id) else {
                session = nil
                leaveAlone(owner, startingAt: start)
                return
            }
            beginEdit(model: model)
            dragged = [.screen(id)]
            model.selection = .screen(id)
            screenOrigin = screen.origin
            model.isAdjusting = true
        }
        guard let screenOrigin else { return }
        let scale = model.zoomScale
        let canvas = store.canvas
        var origin = CGPoint(
            x: (screenOrigin.x + translation.width / scale).rounded(),
            y: (screenOrigin.y + translation.height / scale).rounded()
        )
        if canvas.snapsToGrid, canvas.gridSpacing > 0 {
            origin.x = (origin.x / canvas.gridSpacing).rounded() * canvas.gridSpacing
            origin.y = (origin.y / canvas.gridSpacing).rounded() * canvas.gridSpacing
        } else if canvas.snapsToGuides {
            // Screens line up with each other's edges, as frames do in Freeform.
            let tree = store.tree
            guard let screen = tree.screens.first(where: { $0.id == id }) else { return }
            let others = tree.screens.filter { $0.id != id }.map { $0.canvasFrame(on: tree.device(of: $0)) }
            let frame = CGRect(origin: origin, size: screen.canvasFrame(on: tree.device(of: screen)).size)
            origin = ElementLayout.snapped(frame, to: others, in: nil, threshold: 8 / scale).frame.origin
        }
        store.act(for: edit) { store.updateTreeScreen(id) { $0.origin = origin } }
    }

    func dropScreen(owner: Owner, model: AppModel) {
        guard ends(owner) else { return }
        finish(model: model)
        endEdit(model: model)
    }
}

extension View {
    /// Attaches one of the canvas's drags, made for this view's owner, and ends the drag
    /// if SwiftUI cancels it: its gesture state resets without `onEnded`, or the view goes.
    func canvasDrag<G: Gesture>(_ drags: CanvasDrags, model: AppModel, isEnabled: Bool = true, _ make: @escaping (CanvasDrags.Owner) -> G) -> some View {
        modifier(CanvasDragModifier(drags: drags, model: model, isEnabled: isEnabled, make: make))
    }
}

private struct CanvasDragModifier<G: Gesture>: ViewModifier {
    let drags: CanvasDrags
    let model: AppModel
    let isEnabled: Bool
    let make: (CanvasDrags.Owner) -> G
    @State private var owner = CanvasDrags.Owner()
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        content
            // Disabled, the drag gives way to the gestures inside, a tap to select for one.
            .gesture(make(owner).updating($isDragging) { _, dragging, _ in dragging = true }, including: isEnabled ? .all : .subviews)
            .onChange(of: isDragging) { _, dragging in
                if !dragging { drags.cancel(owner, model: model) }
            }
            .onDisappear { drags.cancel(owner, model: model) }
    }
}

/// The tap and drag target of every visible element, and of every screen's name, laid
/// out in canvas points. Its body depends on the design and the zoom the canvas has come to
/// rest at, not on where the canvas has scrolled to, so panning and pinching don't rebuild it. Each target is a view of its own,
/// given where it lies and compared by that alone: a change to the design builds only the
/// targets of what it moved, where every target, with its tap and its drag, was built again
/// for every change, each frame of a drag among them (audit C6).
///
/// A container that hasn't been gone into (`AppModel.enteredGroups`) is one target, its box,
/// and what is in it has none; selecting something in it swaps its target for theirs. Built
/// from the tree's targets (`TreeTargets`).
private struct ElementTargets: View {
    @Environment(AppModel.self) private var model
    let drags: CanvasDrags

    var body: some View {
        let store = model.store
        let targets = store.treeTargets(entered: model.enteredGroups)
        let tree = store.tree
        // A finger's worth of target at the zoom the canvas comes to rest at: following the
        // zoom itself, every target was built again on every frame of a pinch (audit C8).
        let minimum = 30 / max(model.settledScale, 0.01)
        ZStack(alignment: .topLeading) {
            ForEach(tree.screens) { screen in
                if store.canvas.showsFrameNames {
                    ScreenNameTarget(id: screen.id, frame: screen.labelFrame(on: tree.device(of: screen)), isLocked: screen.isLocked == true,
                                     minimum: minimum, model: model, drags: drags)
                        .equatable()
                }
                ForEach(targets.hosts[.screen(screen.id)] ?? [], id: \.id) { target in
                    self.target(target, on: .screen(screen.id), minimum: minimum)
                }
            }
            // A drawing on the ink canvas has no target here: a tap on its ink picks it, and
            // a drag across it is free to pan the canvas.
            ForEach(targets.hosts[.canvas] ?? [], id: \.id) { target in
                self.target(target, on: .canvas, minimum: minimum)
            }
        }
        .frame(width: Viewport.canvasSize.width, height: Viewport.canvasSize.height, alignment: .topLeading)
    }

    /// A thing's target, or a container's: its box. Locked by itself or by a container above it,
    /// it doesn't drag; what is in a container, locked on its own, doesn't stop the container.
    private func target(_ target: TreeTargets.Target, on host: DesignStore.ElementRef.Host, minimum: CGFloat) -> some View {
        ElementTarget(
            ref: .init(host: host, element: target.id), shape: target.shape, isLocked: target.isLocked,
            minimum: minimum, model: model, drags: drags
        )
        .equatable()
    }
}

/// An invisible area in canvas points that takes touches.
private func targetArea(_ rect: CGRect, degrees: Double = 0, minimum: CGFloat) -> some View {
    Color.clear
        .contentShape(Rectangle())
        .frame(width: max(rect.width, minimum), height: max(rect.height, minimum))
        .rotationEffect(.degrees(degrees))
        .position(x: rect.midX, y: rect.midY)
}

/// One element's target: where it lies on the canvas, in canvas points, and whether it can
/// be dragged. It reads nothing from the model that would build it again otherwise: what
/// a tap or a drag acts on is looked up as it happens.
private struct ElementTarget: View, Equatable {
    let ref: DesignStore.ElementRef
    /// Its turned shape, in canvas points.
    let shape: TurnedRect
    let isLocked: Bool
    let minimum: CGFloat
    /// For what a tap and a drag do; not part of where the target lies.
    let model: AppModel
    let drags: CanvasDrags

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.ref == b.ref && a.shape == b.shape && a.isLocked == b.isLocked && a.minimum == b.minimum
    }

    var body: some View {
        #if DEBUG
        let _ = CanvasWork.builtTarget(ref.element)
        #endif
        targetArea(shape.rect, degrees: shape.degrees, minimum: minimum)
            // Ink lies over the element: where it does, a tap or a drag is the drawing's.
            .onTapGesture(coordinateSpace: .named(SelectionLayer.space)) { [model, ref] in model.targetTapped(.element(ref), at: $0) }
            .canvasDrag(drags, model: model, isEnabled: !isLocked) { [drags, model, ref] owner in
                drags.adjustOnTarget(ref, model: model, owner: owner)
            }
    }
}

/// A screen's name, which picks the screen and drags it.
private struct ScreenNameTarget: View, Equatable {
    let id: DesignScreen.ID
    let frame: CGRect
    let isLocked: Bool
    let minimum: CGFloat
    let model: AppModel
    let drags: CanvasDrags

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.frame == b.frame && a.isLocked == b.isLocked && a.minimum == b.minimum
    }

    var body: some View {
        targetArea(frame, minimum: minimum)
            .onTapGesture(coordinateSpace: .named(SelectionLayer.space)) { [model, id] in model.targetTapped(.screen(id), at: $0) }
            .canvasDrag(drags, model: model, isEnabled: !isLocked) { [drags, model, id] owner in
                drags.moveScreen(id, model: model, owner: owner)
            }
    }
}

/// Shows content drawn in canvas points where the viewport has the canvas, without the
/// content taking part in layout. Only this reads where the canvas has scrolled to.
private struct InViewport<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        Color.clear.overlay(alignment: .topLeading) {
            content
                .scaleEffect(model.zoomScale, anchor: .topLeading)
                .offset(x: -model.scrollOffset.x, y: -model.scrollOffset.y)
        }
    }
}

/// The lines a dragged element has snapped to.
private struct SnapGuidesOverlay: View {
    let guides: [SnapGuide]
    let placement: Placement
    let viewport: Viewport

    var body: some View {
        Path { path in
            for guide in guides {
                let (start, end) = guide.axis == .vertical
                    ? (CGPoint(x: guide.position, y: guide.start), CGPoint(x: guide.position, y: guide.end))
                    : (CGPoint(x: guide.start, y: guide.position), CGPoint(x: guide.end, y: guide.position))
                path.move(to: viewport.viewPoint(for: placement.canvasPoint(for: start)))
                path.addLine(to: viewport.viewPoint(for: placement.canvasPoint(for: end)))
            }
        }
        .stroke(Theme.guide, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .allowsHitTesting(false)
    }
}

/// The distances from the selected element to its neighbours, shown while it is adjusted: measured in its screen's own
/// points (`placement`), and drawn in the view's.
private struct SpacingOverlay: View {
    let guides: SpacingGuides
    let placement: Placement
    /// The screen's frame on the canvas.
    let screenFrame: CGRect
    let viewport: Viewport

    var body: some View {
        ZStack(alignment: .topLeading) {
            if guides.isCentered {
                let frame = viewport.viewRect(for: screenFrame)
                Path { path in
                    path.move(to: CGPoint(x: frame.midX, y: frame.minY))
                    path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
                }
                .stroke(Theme.guide, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            ForEach(Array(guides.gaps.enumerated()), id: \.offset) { _, gap in
                if gap.distance >= 1 {
                    let start = viewport.viewPoint(for: placement.canvasPoint(for: gap.start))
                    let end = viewport.viewPoint(for: placement.canvasPoint(for: gap.end))
                    Path { path in
                        path.move(to: start)
                        path.addLine(to: end)
                    }
                    .stroke(Theme.guide, lineWidth: 1)

                    Text("\(Int(gap.distance))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.white, in: .rect(cornerRadius: 4))
                        .fixedSize()
                        .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#if DEBUG
/// How much of the board a change to the design during a drag works through: for the tests
/// that hold a drag to doing only what its own frames need (audit C6). The counts only grow:
/// the suites that read them run side by side, so each measures the difference it makes.
@MainActor
enum CanvasWork {
    /// Strokes read out of PencilKit to show the design's drawings.
    static var strokesRead = 0
    /// Checks put off until after a change, of whether what a drag moves is still there.
    static var dragChecks = 0
    /// Element targets built, each with its tap and drag, by the id of what each is the target of: what a test
    /// reads for its own board's things, so that other suites' canvases drawn meanwhile don't add to it (F9).
    private static var targets: [UUID: Int] = [:]
    /// Drag owners made: one each time a view carrying a drag is made.
    static var ownersMade = 0
    /// Passes over the design's list to work out what can be touched on the canvas.
    static var targetPasses = 0
    /// Turn sessions formed from the design: one for each read of a selection's shape that
    /// had none held.
    static var turnSessionsFormed = 0
    /// Walks over the design's list to find the single things a selection is.
    static var thingsListed = 0
    /// Tasks started to tell the sketch reading log of elements deleted.
    static var readingLogTasks = 0

    /// How many times the target of the thing with `id` has been built, with its tap and drag. It only grows.
    static func targetsBuilt(of id: UUID) -> Int { targets[id] ?? 0 }

    /// Counts one build of the target of the thing with `id`.
    static func builtTarget(_ id: UUID) {
        targets[id, default: 0] += 1
    }
}
#endif
