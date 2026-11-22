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
        ZStack(alignment: .topLeading) {
            SelectionSummary()
            if let screen = model.selectedScreen {
                dragArea(viewport.viewRect(for: screen.canvasFrame))
                    // A tap reaches what it would without the area: the screen's empty area,
                    // which lets go of it as the canvas does, or, with the palette up, an
                    // element on it.
                    .onTapGesture(coordinateSpace: .named(Self.space)) { model.selectionAreaTapped(at: $0) }
                    .canvasDrag(drags, model: model, isEnabled: screen.isLocked != true) { drags.moveScreen(screen, model: model, owner: $0) }
            }
            // Every element's target, laid out once in canvas points and moved as one by
            // the viewport. Panning changes a single transform rather than every target. With
            // the palette up they take no touches, and aren't built at all (audit C8).
            if model.tool == .select {
                InViewport {
                    ElementTargets(drags: drags)
                }
            }

            // With the palette up, the selected element is moved by its own area. So is a
            // selected drawing at any time: it has no target of its own among the elements'.
            // A tap in the area reaches what lies under it, as it would without the area: a
            // drawing's box can hold other things (audit C12).
            if let selected = model.selectedElement, model.tool == .draw || !selected.element.isPickedByItsFrame {
                let screen: DesignScreen? = if case .screen(let id) = selected.ref.host { store.screen(id) } else { nil }
                dragArea(viewport.viewRect(for: selected.placement.canvasRect(for: selected.element.frame)), degrees: selected.element.resolvedRotation)
                    .onTapGesture(coordinateSpace: .named(Self.space)) { model.selectionAreaTapped(at: $0) }
                    // Locked by itself or by a group above it, it isn't moved (F4).
                    .canvasDrag(drags, model: model, isEnabled: !store.isLocked(.element(selected.ref))) { owner in
                        drags.adjust(selected.ref, from: selected.element.frame, placement: selected.placement, findsNewHome: true, model: model, owner: owner) {
                            drags.moveRule(for: selected.element, placement: selected.placement, on: screen, model: model)
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

            if let screen = model.selectedScreen {
                outline(viewport.viewRect(for: screen.canvasFrame), radius: screen.device.cornerRadius * screen.scale * viewport.scale)
            }
            // Below the corner handles, which win where a small element's handles and knob meet.
            RotateKnob()
            if let selected = model.selectedElement {
                // The element's turned box: its outline, handles and badge go round with it.
                let shape = viewport.viewShape(for: TurnedRect(rect: selected.placement.canvasRect(for: selected.element.frame), degrees: selected.element.resolvedRotation))
                // Not while it turns: the gaps jitter as it goes round, and their labels would
                // cover the angle beside the knob.
                if model.isAdjusting, !model.isTurning, store.canvas.showsMeasurements, case .screen(let id) = selected.ref.host, let screen = store.screen(id) {
                    SpacingOverlay(guides: .measure(selected.element, in: screen), screen: screen, viewport: viewport)
                }
                if model.isAdjusting {
                    SnapGuidesOverlay(guides: drags.guides, placement: drags.guidePlacement, viewport: viewport)
                }
                outline(shape.rect, degrees: shape.degrees, radius: selected.element.resolvedCornerRadius * selected.placement.scale * viewport.scale)
                // Locked by itself or by a group above it: a member of a locked group, selected
                // by a double-tap or a Layers row, isn't resized either (F4).
                if store.isLocked(.element(selected.ref)) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.accent.color, in: .circle)
                        .position(TurnedRect(rect: shape.rect.insetBy(dx: -4, dy: -4), degrees: shape.degrees).corner(.topRight))
                        .accessibilityLabel("Locked")
                } else {
                    ForEach(ElementLayout.Corner.allCases, id: \.self) { corner in
                        handle(corner, on: shape, for: selected.element, ref: selected.ref, placement: selected.placement)
                    }
                }
            }

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

    /// How round a selected thing's corners are, in canvas points.
    private func cornerRadius(of thing: CanvasSelection) -> CGFloat {
        switch thing {
        case .element(let ref):
            model.store.resolve(ref).map { $0.element.resolvedCornerRadius * $0.placement.scale } ?? 0
        case .screen(let id):
            model.store.screen(id).map { $0.device.cornerRadius * $0.scale } ?? 0
        case .several:
            0
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

    /// A corner handle just outside the element's turned box, in the view. Dragged, the
    /// element is resized in its own axes, and the corner across from it stays put.
    private func handle(
        _ corner: ElementLayout.Corner,
        on shape: TurnedRect,
        for element: DesignElement,
        ref: DesignStore.ElementRef,
        placement: Placement
    ) -> some View {
        let point = TurnedRect(rect: shape.rect.insetBy(dx: -6, dy: -6), degrees: shape.degrees).corner(corner)
        return Circle()
            .fill(Theme.chrome)
            .overlay { Circle().strokeBorder(Theme.accent.color, lineWidth: 1.5) }
            .frame(width: 11, height: 11)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .position(point)
            .canvasDrag(drags, model: model) { owner in
                drags.adjust(ref, from: element.frame, placement: placement, findsNewHome: false, model: model, owner: owner) {
                    { origin, translation in
                        (ElementLayout.resizedTurned(origin, degrees: element.resolvedRotation, from: corner, by: translation, kind: element.kind), [])
                    }
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
private struct SelectionSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let summary {
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

    private var summary: String? {
        if case .several(let things) = model.selection, let area = model.store.canvasFrame(of: .several(things)) {
            return "\(things.count) items · \(Int(area.width.rounded())) × \(Int(area.height.rounded()))"
        }
        if let selected = model.selectedElement {
            let size = "\(Int(selected.element.frame.width)) × \(Int(selected.element.frame.height))"
            switch selected.element.kind {
            case .drawing:
                let strokes = selected.element.strokeCount
                return strokes == 1 ? "Drawing · 1 stroke" : "Drawing · \(strokes) strokes"
            case .group:
                // Told apart from an element, by VoiceOver and the UI tests.
                return "Group · \(size)"
            default:
                return size
            }
        }
        if let screen = model.selectedScreen {
            return "\(screen.name) · \(Int(screen.size.width)) × \(Int(screen.size.height))"
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

    /// The lines the dragged element has snapped to, and the placement of their points.
    var guides: [SnapGuide] = []
    var guidePlacement = Placement(origin: .zero, scale: 1)
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
    /// drop would land it: on whatever it now lies over, in the drag's step, or the turn's
    /// that cut it short. Left where it was, an element dragged from one screen onto another
    /// stayed the first one's, and was drawn under the second (audit C4). `keeping` is what
    /// a new touch on the same view goes on to move.
    private func endAbandoned(model: AppModel, keeping: Set<CanvasSelection> = []) {
        let landing = findsNewHome ? dragged.filter { !keeping.contains($0) } : []
        let step = edit ?? handedOver
        finish(model: model)
        if !landing.isEmpty { model.store.act(for: step) { model.rehost(landing) } }
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
        rule = nil
        if !guides.isEmpty { guides = [] }
        // A turn still under way is still adjusting the selection: the twist that ended
        // this drag, or the knob held while another finger let go.
        if !model.isTurning { model.isAdjusting = false }
    }

    /// Where a dragged element goes: onto the grid's marks, or lined up with its screen and
    /// its neighbours, as the canvas is set up to do. Worked out once, as the drag begins.
    func moveRule(for element: DesignElement, placement: Placement, on screen: DesignScreen?, model: AppModel) -> Rule {
        let canvas = model.store.canvas
        // Only the zoom: the viewport would make whatever builds this depend on panning too.
        let zoom = model.zoomScale
        // What the element can line up with, in its own host's points.
        let others: [CGRect] = if let screen {
            screen.elements.filter { $0.id != element.id && !$0.isHidden }.map(\.shapeBounds)
        } else {
            model.store.floating.filter { $0.id != element.id && !$0.element.isHidden }.map { placement.localRect(for: $0.placement.canvasRect(for: $0.element.shapeBounds)) }
        }
        let container = screen.map { CGRect(origin: .zero, size: $0.size) }
        // A turned element snaps by the box round its shape; its frame moves with the box.
        let box = element.shapeBounds
        let shift = CGSize(width: box.minX - element.frame.minX, height: box.minY - element.frame.minY)
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

    /// A drag that moves or resizes an element. The translation is measured against the
    /// window, which stays put while the element moves, and converted to the element's
    /// own points. `rule` is asked for once, when the drag begins.
    func adjust(
        _ ref: DesignStore.ElementRef,
        from frame: CGRect,
        placement: Placement,
        findsNewHome: Bool,
        model: AppModel,
        owner: Owner,
        rule: @escaping () -> Rule
    ) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { [self] value in
                moveElement(ref, from: frame, placement: placement, by: value.translation, startingAt: value.startLocation, findsNewHome: findsNewHome, owner: owner, model: model, rule: rule)
            }
            .onEnded { [self] _ in
                dropElement(ref, findsNewHome: findsNewHome, owner: owner, model: model)
            }
    }

    /// `findsNewHome`: whether the element belongs to whatever it lies on as the drag ends,
    /// as it does when it is moved, though not when a handle resizes it.
    func moveElement(
        _ ref: DesignStore.ElementRef, from frame: CGRect, placement: Placement, by glassTranslation: CGSize,
        startingAt start: CGPoint, findsNewHome: Bool = true, owner: Owner, model: AppModel, rule makeRule: () -> Rule
    ) {
        let turn = begins(owner, at: start, moving: [.element(ref)], model: model)
        guard turn != .ignored else { return }
        if turn == .new {
            // Locked, by itself or by a group above it, it is neither moved nor resized (F4):
            // the drag is left alone until its finger lifts. The handles and targets of a
            // locked thing are hidden or off, but a member's lock can come from its group.
            guard !model.store.isLocked(.element(ref)) else {
                session = nil
                leaveAlone(owner, startingAt: start)
                return
            }
            beginEdit(model: model, named: findsNewHome ? String(localized: "Move") : String(localized: "Resize"))
            dragged = [.element(ref)]
            self.findsNewHome = findsNewHome
            model.selection = .element(ref)
            elementOrigin = frame
            rule = makeRule()
            model.isAdjusting = true
        }
        guard let elementOrigin, let rule else { return }
        let scale = placement.scale * model.zoomScale
        let translation = CGSize(width: glassTranslation.width / scale, height: glassTranslation.height / scale)
        let (frame, snappedTo) = rule(elementOrigin, translation)
        if guides != snappedTo { guides = snappedTo }
        // Set only when it differs: each setting tells whatever draws the guides to draw again.
        if guidePlacement != placement { guidePlacement = placement }
        model.store.act(for: edit) { model.store.update(ref) { $0.frame = frame } }
    }

    func dropElement(_ ref: DesignStore.ElementRef, findsNewHome: Bool, owner: Owner, model: AppModel) {
        guard ends(owner) else { return }
        finish(model: model)
        if findsNewHome {
            // Dropped somewhere new, the element belongs to whatever it now lies on.
            model.selection = .element(model.store.act(for: edit) { model.store.rehost(ref) })
        }
        endEdit(model: model)
    }

    /// The drag on an element's own target, in the selection layer's points. Ink is drawn
    /// over every element, so a drag that starts on a drawing's ink moves the drawing, as a
    /// tap there picks it. The element, and the screen it is on, are looked up as the drag
    /// goes, so that its target is built again only when where it lies changes, not with
    /// every change to it or to its screen (audit C6).
    func adjustOnTarget(_ ref: DesignStore.ElementRef, model: AppModel, owner: Owner) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(SelectionLayer.space))
            .onChanged { [self] value in
                guard let (element, placement) = model.store.resolve(ref) else { return }
                let screen: DesignScreen? = if case .screen(let id) = ref.host { model.store.screen(id) } else { nil }
                moveOnTarget(ref, element: element, placement: placement, on: screen, by: value.translation, startingAt: value.startLocation, owner: owner, model: model)
            }
            .onEnded { [self] value in
                dropOnTarget(ref, startingAt: value.startLocation, owner: owner, model: model)
            }
    }

    /// Moves what a drag on an element's target moves: the element, or the drawing whose ink
    /// lay over it where the drag began. A group's target moves the group, as a tap there
    /// picks it, with whatever else is selected along with it. `start` is in the view's points.
    func moveOnTarget(
        _ ref: DesignStore.ElementRef, element: DesignElement, placement: Placement, on screen: DesignScreen?,
        by translation: CGSize, startingAt start: CGPoint, owner: Owner, model: AppModel
    ) {
        guard let drawing = ink(under: start, for: owner, model: model) else {
            if element.kind == .group {
                moveGroup(by: translation, startingAt: start, owner: owner, model: model, selecting: .element(ref))
                return
            }
            moveElement(ref, from: element.frame, placement: placement, by: translation, startingAt: start, owner: owner, model: model) {
                self.moveRule(for: element, placement: placement, on: screen, model: model)
            }
            return
        }
        guard let found = model.store.resolve(drawing) else { return }
        moveElement(drawing, from: found.element.frame, placement: found.placement, by: translation, startingAt: start, owner: owner, model: model) {
            self.moveRule(for: found.element, placement: found.placement, on: nil, model: model)
        }
    }

    func dropOnTarget(_ ref: DesignStore.ElementRef, startingAt start: CGPoint, owner: Owner, model: AppModel) {
        let drawing = owner.ink.flatMap { $0.start == start ? $0.drawing : nil }
        owner.ink = nil
        if drawing == nil, model.store.groupItem(ref.element) != nil {
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

    /// A drag that moves everything selected, each thing by the same distance across the
    /// canvas. Together they go to the grid's marks, or line up with what is around them,
    /// as one element does; and dropped, each element belongs to whatever it then lies on.
    /// What they have been turned about goes with them.
    func moveSelection(model: AppModel, owner: Owner) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
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
            model.isAdjusting = true
        }
        guard let origins = groupOrigins,
              let area = origins.values.dropFirst().reduce(origins.values.first, { $0?.union($1) })
        else { return }
        let zoom = max(model.zoomScale, 0.01)
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
        if guides != snappedTo { guides = snappedTo }
        // The lines are in canvas points, as the things lined up are.
        let onCanvas = Placement(origin: .zero, scale: 1)
        if guidePlacement != onCanvas { guidePlacement = onCanvas }
        model.store.act(for: edit) {
            model.store.position(origins.mapValues { CGPoint(x: $0.minX + delta.width, y: $0.minY + delta.height) })
            model.selectionMoved(by: delta)
        }
    }

    func dropGroup(owner: Owner, model: AppModel) {
        guard ends(owner) else { return }
        finish(model: model)
        model.store.act(for: edit) { model.rehostSelection() }
        endEdit(model: model)
    }

    /// A drag that moves a screen by its name, which looks the screen up as the drag goes:
    /// the name's target isn't built again with every change to what is on the screen.
    func moveScreen(_ id: DesignScreen.ID, model: AppModel, owner: Owner) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { [self] value in
                guard let screen = model.store.screen(id) else { return }
                moveScreen(screen, by: value.translation, startingAt: value.startLocation, owner: owner, model: model)
            }
            .onEnded { [self] _ in
                dropScreen(owner: owner, model: model)
            }
    }

    func moveScreen(_ screen: DesignScreen, model: AppModel, owner: Owner) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { [self] value in
                moveScreen(screen, by: value.translation, startingAt: value.startLocation, owner: owner, model: model)
            }
            .onEnded { [self] _ in
                dropScreen(owner: owner, model: model)
            }
    }

    func moveScreen(_ screen: DesignScreen, by translation: CGSize, startingAt start: CGPoint, owner: Owner, model: AppModel) {
        let turn = begins(owner, at: start, moving: [.screen(screen.id)], model: model)
        guard turn != .ignored else { return }
        if turn == .new {
            beginEdit(model: model)
            dragged = [.screen(screen.id)]
            model.selection = .screen(screen.id)
            screenOrigin = screen.origin
            model.isAdjusting = true
        }
        guard let screenOrigin else { return }
        let scale = model.zoomScale
        let canvas = model.store.canvas
        var origin = CGPoint(
            x: (screenOrigin.x + translation.width / scale).rounded(),
            y: (screenOrigin.y + translation.height / scale).rounded()
        )
        if canvas.snapsToGrid, canvas.gridSpacing > 0 {
            origin.x = (origin.x / canvas.gridSpacing).rounded() * canvas.gridSpacing
            origin.y = (origin.y / canvas.gridSpacing).rounded() * canvas.gridSpacing
        } else if canvas.snapsToGuides {
            // Screens line up with each other's edges, as frames do in Freeform.
            let others = model.store.screens.filter { $0.id != screen.id }.map(\.canvasFrame)
            let frame = CGRect(origin: origin, size: screen.canvasFrame.size)
            origin = ElementLayout.snapped(frame, to: others, in: nil, threshold: 8 / scale).frame.origin
        }
        model.store.act(for: edit) { model.store.updateScreen(screen.id) { $0.origin = origin } }
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
/// A group that hasn't been gone into (`AppModel.enteredGroups`) is one target, its box,
/// and what is in it has none; selecting something in it swaps its target for theirs.
private struct ElementTargets: View {
    @Environment(AppModel.self) private var model
    let drags: CanvasDrags

    var body: some View {
        let store = model.store
        let targets = store.targetElements(entered: model.enteredGroups)
        // A finger's worth of target at the zoom the canvas comes to rest at: following the
        // zoom itself, every target was built again on every frame of a pinch (audit C8).
        let minimum = 30 / max(model.settledScale, 0.01)
        ZStack(alignment: .topLeading) {
            ForEach(store.screens) { screen in
                if store.canvas.showsFrameNames {
                    ScreenNameTarget(id: screen.id, frame: screen.labelFrame, isLocked: screen.isLocked == true, minimum: minimum, model: model, drags: drags)
                        .equatable()
                }
                ForEach(targets[.screen(screen.id)] ?? []) { element in
                    target(for: element, on: .screen(screen.id), placement: screen.placement, minimum: minimum)
                }
            }
            // A drawing on the ink canvas has no target here: a tap on its ink picks it, and
            // a drag across it is free to pan the canvas.
            ForEach(targets[.canvas] ?? []) { element in
                target(for: element, on: .canvas, placement: Placement(origin: .zero, scale: element.scale ?? 1), minimum: minimum)
            }
        }
        .frame(width: Viewport.canvasSize.width, height: Viewport.canvasSize.height, alignment: .topLeading)
    }

    /// A thing's target, or a group's: its box. Locked by itself or by a group above it, it
    /// doesn't drag; a group's members' own locks don't stop the group.
    private func target(for element: DesignElement, on host: DesignStore.ElementRef.Host, placement: Placement, minimum: CGFloat) -> some View {
        ElementTarget(
            ref: .init(host: host, element: element.id), frame: placement.canvasRect(for: element.frame),
            degrees: element.resolvedRotation, isLocked: model.store.isLockedWithItsGroups(element), minimum: minimum, model: model, drags: drags
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
    let frame: CGRect
    let degrees: Double
    let isLocked: Bool
    let minimum: CGFloat
    /// For what a tap and a drag do; not part of where the target lies.
    let model: AppModel
    let drags: CanvasDrags

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.ref == b.ref && a.frame == b.frame && a.degrees == b.degrees && a.isLocked == b.isLocked && a.minimum == b.minimum
    }

    var body: some View {
        #if DEBUG
        let _ = CanvasWork.targetsBuilt += 1
        #endif
        targetArea(frame, degrees: degrees, minimum: minimum)
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

/// The distances from the selected element to its neighbours, shown while it is adjusted.
private struct SpacingOverlay: View {
    let guides: SpacingGuides
    let screen: DesignScreen
    let viewport: Viewport

    var body: some View {
        ZStack(alignment: .topLeading) {
            if guides.isCentered {
                let frame = viewport.viewRect(for: screen.canvasFrame)
                Path { path in
                    path.move(to: CGPoint(x: frame.midX, y: frame.minY))
                    path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
                }
                .stroke(Theme.guide, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            ForEach(Array(guides.gaps.enumerated()), id: \.offset) { _, gap in
                if gap.distance >= 1 {
                    let start = viewport.viewPoint(for: screen.canvasPoint(for: gap.start))
                    let end = viewport.viewPoint(for: screen.canvasPoint(for: gap.end))
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
    /// Element targets built, each with its tap and drag.
    static var targetsBuilt = 0
    /// Drag owners made: one each time a view carrying a drag is made.
    static var ownersMade = 0
}
#endif
