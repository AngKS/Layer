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
                    .canvasDrag(drags, model: model, isEnabled: screen.isLocked != true) { drags.moveScreen(screen, model: model, owner: $0) }
            }
            // Every element's target, laid out once in canvas points and moved as one by
            // the viewport. Panning changes a single transform rather than every target.
            InViewport {
                ElementTargets(drags: drags)
            }
            .allowsHitTesting(model.tool == .select)

            // With the palette up, the selected element is moved by its own area. So is a
            // selected drawing at any time: it has no target of its own among the elements'.
            if let selected = model.selectedElement, model.tool == .draw || !selected.element.isPickedByItsFrame {
                let screen: DesignScreen? = if case .screen(let id) = selected.ref.host { store.screen(id) } else { nil }
                dragArea(viewport.viewRect(for: selected.placement.canvasRect(for: selected.element.frame)), degrees: selected.element.resolvedRotation)
                    .canvasDrag(drags, model: model, isEnabled: !selected.element.isLocked) { owner in
                        drags.adjust(selected.ref, from: selected.element.frame, placement: selected.placement, findsNewHome: true, model: model, owner: owner) {
                            drags.moveRule(for: selected.element, placement: selected.placement, on: screen, model: model)
                        }
                    }
            }

            // Several things at once: each is outlined on its turned shape, any of them
            // drags them all, and a tap on one picks it out. They have no handles: together
            // they aren't resized, but they turn as one by the knob.
            if case .several = model.selection {
                let things = model.selectedThings
                let isLocked = model.isSelectionLocked
                ForEach(things, id: \.self) { thing in
                    if let shape = store.canvasShape(of: thing).map(viewport.viewShape(for:)) {
                        dragArea(shape.rect, degrees: shape.degrees)
                            .onTapGesture { model.pick(thing) }
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
                if selected.element.isLocked {
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
        // A tick as a turn snaps to the 45s; none as it leaves.
        .sensoryFeedback(.alignment, trigger: model.snappedTurn) { _, snapped in snapped != nil }
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
                        Button("Reset rotation") { model.resetSelectionTurn() }
                    }
                }
        }
    }

    private var summary: String? {
        if case .several(let things) = model.selection, let area = model.store.canvasFrame(of: .several(things)) {
            return "\(things.count) items · \(Int(area.width.rounded())) × \(Int(area.height.rounded()))"
        }
        if let selected = model.selectedElement {
            if selected.element.kind == .drawing {
                let strokes = selected.element.strokeCount
                return strokes == 1 ? "Drawing · 1 stroke" : "Drawing · \(strokes) strokes"
            }
            return "\(Int(selected.element.frame.width)) × \(Int(selected.element.frame.height))"
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
@MainActor @Observable
final class CanvasDrags {
    /// Moves a dragged element: from its frame as the drag began, by the translation in its
    /// own points, to its new frame and the lines it snapped to.
    typealias Rule = (_ origin: CGRect, _ translation: CGSize) -> (CGRect, [SnapGuide])

    /// Stands for one view that carries a drag.
    final class Owner {}

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

    /// What the drag under way moves.
    @ObservationIgnored private var dragged: [CanvasSelection] = []

    /// Ends the drag under way, whoever's it is. A backstop for a cancel SwiftUI didn't
    /// report: while a drag is live every other is ignored, so one left live would stop all
    /// dragging. Called as the design closes and when the tool changes.
    func endAny(model: AppModel) {
        guard session != nil else { return }
        endAbandoned(model: model)
    }

    /// Ends the drag under way if what it moves has been locked or taken away, by a spoken
    /// command for instance: its gesture is disabled or its view gone, which may not be heard.
    func endIfDraggedIsGone(model: AppModel) {
        guard session != nil else { return }
        let store = model.store
        if dragged.contains(where: { store.canvasFrame(of: $0) == nil || store.isLocked($0) }) {
            endAbandoned(model: model)
        }
    }

    private enum Turn { case new, continuing, ignored }

    /// Whether a drag is new, goes on, or is to be left alone. Another view's drag under way
    /// is a second finger, and the new one is left alone: taking over, the two made every
    /// frame a step. A drag SwiftUI cancelled has already been ended by its owner's gesture
    /// state resetting, or its view going (see `canvasDrag`). A new touch on the same view
    /// means the one before was cancelled: it is ended first, leaving nothing behind.
    private func begins(_ owner: Owner, at start: CGPoint, model: AppModel) -> Turn {
        if let session {
            guard session.owner === owner else { return .ignored }
            if session.start == start { return .continuing }
            endAbandoned(model: model)
        }
        session = (owner, start)
        return .new
    }

    /// Ends the drag under way where it is, if it is this owner's: SwiftUI cancelled it.
    func cancel(_ owner: Owner, model: AppModel) {
        guard session?.owner === owner else { return }
        endAbandoned(model: model)
    }

    private func endAbandoned(model: AppModel) {
        finish(model: model)
        model.store.endEdit()
    }

    /// Whether `onEnded` belongs to the drag under way, or to the one just ended.
    private func ends(_ owner: Owner) -> Bool {
        session?.owner === owner || (session == nil && lastOwner === owner)
    }

    /// Whose the last drag was, after it ended: its `onEnded` may come after it was already
    /// ended as cancelled. A second finger's drag, left alone, never was a drag here.
    @ObservationIgnored private weak var lastOwner: Owner?

    private func finish(model: AppModel) {
        if let session { lastOwner = session.owner }
        session = nil
        dragged = []
        elementOrigin = nil
        screenOrigin = nil
        groupOrigins = nil
        rule = nil
        if !guides.isEmpty { guides = [] }
        model.isAdjusting = false
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
                moveElement(ref, from: frame, placement: placement, by: value.translation, startingAt: value.startLocation, owner: owner, model: model, rule: rule)
            }
            .onEnded { [self] _ in
                dropElement(ref, findsNewHome: findsNewHome, owner: owner, model: model)
            }
    }

    func moveElement(
        _ ref: DesignStore.ElementRef, from frame: CGRect, placement: Placement, by glassTranslation: CGSize,
        startingAt start: CGPoint, owner: Owner, model: AppModel, rule makeRule: () -> Rule
    ) {
        let turn = begins(owner, at: start, model: model)
        guard turn != .ignored else { return }
        if turn == .new {
            model.store.beginEdit()
            dragged = [.element(ref)]
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
        guidePlacement = placement
        model.store.update(ref) { $0.frame = frame }
    }

    func dropElement(_ ref: DesignStore.ElementRef, findsNewHome: Bool, owner: Owner, model: AppModel) {
        guard ends(owner) else { return }
        finish(model: model)
        if findsNewHome {
            // Dropped somewhere new, the element belongs to whatever it now lies on.
            model.selection = .element(model.store.rehost(ref))
        }
        model.store.endEdit()
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

    func moveGroup(by translation: CGSize, startingAt start: CGPoint, owner: Owner, model: AppModel) {
        let turn = begins(owner, at: start, model: model)
        guard turn != .ignored else { return }
        if turn == .new {
            model.store.beginEdit()
            model.selectionWillMove()
            var origins: [CanvasSelection: CGRect] = [:]
            for thing in model.selectedThings where !model.store.isLocked(thing) {
                origins[thing] = model.store.canvasFrame(of: thing)
            }
            groupOrigins = origins
            dragged = Array(origins.keys)
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
        guidePlacement = Placement(origin: .zero, scale: 1)
        model.store.position(origins.mapValues { CGPoint(x: $0.minX + delta.width, y: $0.minY + delta.height) })
        model.selectionMoved(by: delta)
    }

    func dropGroup(owner: Owner, model: AppModel) {
        guard ends(owner) else { return }
        finish(model: model)
        model.rehostSelection()
        model.store.endEdit()
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
        let turn = begins(owner, at: start, model: model)
        guard turn != .ignored else { return }
        if turn == .new {
            model.store.beginEdit()
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
        model.store.updateScreen(screen.id) { $0.origin = origin }
    }

    func dropScreen(owner: Owner, model: AppModel) {
        guard ends(owner) else { return }
        finish(model: model)
        model.store.endEdit()
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
/// out in canvas points. Its body depends on the design and the zoom, not on where the
/// canvas has scrolled to, so panning doesn't rebuild it.
private struct ElementTargets: View {
    @Environment(AppModel.self) private var model
    let drags: CanvasDrags

    var body: some View {
        let store = model.store
        // A finger's worth of target at any zoom.
        let minimum = 30 / max(model.zoomScale, 0.01)
        ZStack(alignment: .topLeading) {
            ForEach(store.screens) { screen in
                if store.canvas.showsFrameNames {
                    area(screen.labelFrame, minimum: minimum)
                        .onTapGesture { model.pick(.screen(screen.id)) }
                        .canvasDrag(drags, model: model, isEnabled: screen.isLocked != true) { drags.moveScreen(screen, model: model, owner: $0) }
                }
                ForEach(screen.elements.filter { !$0.isHidden }) { element in
                    target(for: element, ref: .init(host: .screen(screen.id), element: element.id), placement: screen.placement, on: screen, minimum: minimum)
                }
            }
            // A drawing on the ink canvas has no target here: a tap on its ink picks it, and
            // a drag across it is free to pan the canvas.
            ForEach(store.floating.filter { !$0.element.isHidden && $0.element.isPickedByItsFrame }) { floating in
                target(for: floating.element, ref: .init(host: .canvas, element: floating.id), placement: floating.placement, on: nil, minimum: minimum)
            }
        }
        .frame(width: Viewport.canvasSize.width, height: Viewport.canvasSize.height, alignment: .topLeading)
    }

    /// An invisible area in canvas points that takes touches.
    private func area(_ rect: CGRect, degrees: Double = 0, minimum: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: max(rect.width, minimum), height: max(rect.height, minimum))
            .rotationEffect(.degrees(degrees))
            .position(x: rect.midX, y: rect.midY)
    }

    /// `screen` is the screen the element is on, or nil on the open canvas.
    private func target(for element: DesignElement, ref: DesignStore.ElementRef, placement: Placement, on screen: DesignScreen?, minimum: CGFloat) -> some View {
        area(placement.canvasRect(for: element.frame), degrees: element.resolvedRotation, minimum: minimum)
            .onTapGesture { model.pick(.element(ref)) }
            .canvasDrag(drags, model: model, isEnabled: !element.isLocked) { owner in
                drags.adjust(ref, from: element.frame, placement: placement, findsNewHome: true, model: model, owner: owner) {
                    drags.moveRule(for: element, placement: placement, on: screen, model: model)
                }
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
