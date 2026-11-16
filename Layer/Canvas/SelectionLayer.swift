import SwiftUI

/// The handles on the canvas for selecting and moving things. With the palette away,
/// elements are tapped to select and dragged to move, anywhere on the canvas, and resized
/// by their corner handles. With the palette up the Pencil draws everywhere, so only
/// what a finger has selected takes touches here. A selected screen or
/// drawing is dragged by its whole area; a screen can also be dragged by its name.
///
/// Everything here is in the view's own points, so handles and outlines stay the same
/// size at any zoom. Screens and drawings that aren't selected have no handle of their
/// own, which leaves a drag across them free to pan the canvas.
struct SelectionLayer: View {
    @Environment(AppModel.self) private var model
    /// The frame an element had when the current drag began.
    @State private var elementDragOrigin: CGRect?
    @State private var screenDragOrigin: CGPoint?
    /// How far, in canvas points, the selected drawing has been dragged so far.
    @State private var inkDragged = CGSize.zero
    /// The lines the dragged element has snapped to, and the placement of their points.
    @State private var guides: [SnapGuide] = []
    @State private var guidePlacement = Placement(origin: .zero, scale: 1)

    var body: some View {
        let store = model.store
        let viewport = model.viewport
        ZStack(alignment: .topLeading) {
            // What is selected and its size, for VoiceOver and automation rather than the eye.
            if let summary = selectionSummary {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Selection")
                    .accessibilityValue(summary)
                    .accessibilityIdentifier("Selection")
            }
            if let screen = model.selectedScreen {
                dragArea(viewport.viewRect(for: screen.canvasFrame))
                    .gesture(moveScreen(screen), including: screen.isLocked == true ? .subviews : .all)
            }
            if let bounds = model.inkSelectionBounds {
                dragArea(viewport.viewRect(for: bounds).insetBy(dx: -8, dy: -8))
                    .gesture(moveInk)
            }

            Group {
                ForEach(store.screens) { screen in
                    if store.canvas.showsFrameNames {
                        dragArea(viewport.viewRect(for: screen.labelFrame))
                            .onTapGesture { model.selection = .screen(screen.id) }
                            .gesture(moveScreen(screen), including: screen.isLocked == true ? .subviews : .all)
                    }
                    ForEach(screen.elements.filter { !$0.isHidden }) { element in
                        target(for: element, ref: .init(host: .screen(screen.id), element: element.id), placement: screen.placement, on: screen)
                    }
                }
                ForEach(store.floating.filter { !$0.element.isHidden }) { floating in
                    target(for: floating.element, ref: .init(host: .canvas, element: floating.id), placement: floating.placement, on: nil)
                }
            }
            .allowsHitTesting(model.tool == .select)

            // With the palette up, the selected element is moved by its own area.
            if model.tool == .draw, let selected = model.selectedElement {
                let screen: DesignScreen? = if case .screen(let id) = selected.ref.host { store.screen(id) } else { nil }
                dragArea(viewport.viewRect(for: selected.placement.canvasRect(for: selected.element.frame)))
                    .gesture(
                        adjust(selected.ref, from: selected.element.frame, placement: selected.placement, findsNewHome: true,
                               apply: moveRule(for: selected.element, placement: selected.placement, on: screen)),
                        isEnabled: !selected.element.isLocked
                    )
            }

            if let screen = model.selectedScreen {
                outline(viewport.viewRect(for: screen.canvasFrame), radius: screen.device.cornerRadius * screen.scale * viewport.scale)
            }
            if let bounds = model.inkSelectionBounds {
                outline(viewport.viewRect(for: bounds).insetBy(dx: -5, dy: -5), radius: 4)
            }
            if let selected = model.selectedElement {
                let rect = viewport.viewRect(for: selected.placement.canvasRect(for: selected.element.frame))
                if model.isAdjusting, store.canvas.showsMeasurements, case .screen(let id) = selected.ref.host, let screen = store.screen(id) {
                    SpacingOverlay(guides: .measure(selected.element, in: screen), screen: screen, viewport: viewport)
                }
                if model.isAdjusting {
                    SnapGuidesOverlay(guides: guides, placement: guidePlacement, viewport: viewport)
                }
                outline(rect, radius: selected.element.resolvedCornerRadius * selected.placement.scale * viewport.scale)
                if selected.element.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.accent.color, in: .circle)
                        .position(x: rect.maxX + 4, y: rect.minY - 4)
                        .accessibilityLabel("Locked")
                } else {
                    ForEach(ElementLayout.Corner.allCases, id: \.self) { corner in
                        handle(corner, at: rect, for: selected.element, ref: selected.ref, placement: selected.placement)
                    }
                }
            }

        }
    }

    private var selectionSummary: String? {
        if let selected = model.selectedElement {
            return "\(Int(selected.element.frame.width)) × \(Int(selected.element.frame.height))"
        }
        if let screen = model.selectedScreen {
            return "\(screen.name) · \(Int(screen.size.width)) × \(Int(screen.size.height))"
        }
        if case .ink(let strokes) = model.selection {
            return strokes.count == 1 ? "Drawing · 1 stroke" : "Drawing · \(strokes.count) strokes"
        }
        return nil
    }

    // MARK: Pieces

    /// An invisible area that takes touches, at least big enough for a finger.
    private func dragArea(_ rect: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: max(rect.width, 30), height: max(rect.height, 30))
            .position(x: rect.midX, y: rect.midY)
    }

    /// `screen` is the screen the element is on, or nil on the open canvas.
    private func target(for element: DesignElement, ref: DesignStore.ElementRef, placement: Placement, on screen: DesignScreen?) -> some View {
        dragArea(model.viewport.viewRect(for: placement.canvasRect(for: element.frame)))
            .onTapGesture { model.selection = .element(ref) }
            .gesture(
                adjust(ref, from: element.frame, placement: placement, findsNewHome: true, apply: moveRule(for: element, placement: placement, on: screen)),
                isEnabled: !element.isLocked
            )
    }

    /// Where a dragged element goes: onto the grid's marks, or lined up with its screen and
    /// its neighbours, as the canvas is set up to do.
    private func moveRule(for element: DesignElement, placement: Placement, on screen: DesignScreen?) -> (CGRect, CGSize) -> (CGRect, [SnapGuide]) {
        let canvas = model.store.canvas
        let zoom = model.viewport.scale
        // What the element can line up with, in its own host's points.
        let others: [CGRect] = if let screen {
            screen.elements.filter { $0.id != element.id && !$0.isHidden }.map(\.frame)
        } else {
            model.store.floating.filter { $0.id != element.id && !$0.element.isHidden }.map { placement.localRect(for: $0.canvasFrame) }
        }
        let container = screen.map { CGRect(origin: .zero, size: $0.size) }
        return { origin, translation in
            let moved = ElementLayout.moved(origin, by: translation, snapsToCenter: false)
            if canvas.snapsToGrid {
                return (ElementLayout.snappedToGrid(moved, spacing: canvas.gridSpacing, placement: placement), [])
            }
            guard canvas.snapsToGuides else { return (moved, []) }
            // Close enough is the same few points on the glass at any zoom.
            let threshold = 6 / max(placement.scale * zoom, 0.01)
            return ElementLayout.snapped(moved, to: others, in: container, threshold: threshold)
        }
    }

    private func handle(
        _ corner: ElementLayout.Corner,
        at rect: CGRect,
        for element: DesignElement,
        ref: DesignStore.ElementRef,
        placement: Placement
    ) -> some View {
        let outer = rect.insetBy(dx: -6, dy: -6)
        let point = switch corner {
        case .topLeft: CGPoint(x: outer.minX, y: outer.minY)
        case .topRight: CGPoint(x: outer.maxX, y: outer.minY)
        case .bottomLeft: CGPoint(x: outer.minX, y: outer.maxY)
        case .bottomRight: CGPoint(x: outer.maxX, y: outer.maxY)
        }
        return Circle()
            .fill(Theme.chrome)
            .overlay { Circle().strokeBorder(Theme.accent.color, lineWidth: 1.5) }
            .frame(width: 11, height: 11)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .position(point)
            .gesture(adjust(ref, from: element.frame, placement: placement, findsNewHome: false) { origin, translation in
                (ElementLayout.resizedKeepingShape(origin, from: corner, by: translation, kind: element.kind), [])
            })
    }

    private func outline(_ rect: CGRect, radius: CGFloat) -> some View {
        let outer = rect.insetBy(dx: -3, dy: -3)
        return RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
            .strokeBorder(Theme.accent.color, lineWidth: 1.5)
            .frame(width: outer.width, height: outer.height)
            .position(x: outer.midX, y: outer.midY)
            .allowsHitTesting(false)
    }

    // MARK: Drags

    /// A drag that moves or resizes an element. The translation is measured against the
    /// window, which stays put while the element moves, and converted to the element's
    /// own points.
    private func adjust(
        _ ref: DesignStore.ElementRef,
        from frame: CGRect,
        placement: Placement,
        findsNewHome: Bool,
        apply: @escaping (_ origin: CGRect, _ translation: CGSize) -> (CGRect, [SnapGuide])
    ) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if elementDragOrigin == nil {
                    model.store.beginEdit()
                    model.selection = .element(ref)
                    elementDragOrigin = frame
                    model.isAdjusting = true
                }
                guard let elementDragOrigin else { return }
                let scale = placement.scale * model.viewport.scale
                let translation = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                let (frame, snappedTo) = apply(elementDragOrigin, translation)
                guides = snappedTo
                guidePlacement = placement
                model.store.update(ref) { $0.frame = frame }
            }
            .onEnded { _ in
                elementDragOrigin = nil
                guides = []
                model.isAdjusting = false
                if findsNewHome {
                    // Dropped somewhere new, the element belongs to whatever it now lies on.
                    model.selection = .element(model.store.rehost(ref))
                }
                model.store.endEdit()
            }
    }

    private func moveScreen(_ screen: DesignScreen) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if screenDragOrigin == nil {
                    model.store.beginEdit()
                    model.selection = .screen(screen.id)
                    screenDragOrigin = screen.origin
                    model.isAdjusting = true
                }
                guard let screenDragOrigin else { return }
                let scale = model.viewport.scale
                let canvas = model.store.canvas
                var origin = CGPoint(
                    x: (screenDragOrigin.x + value.translation.width / scale).rounded(),
                    y: (screenDragOrigin.y + value.translation.height / scale).rounded()
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
            .onEnded { _ in
                screenDragOrigin = nil
                model.isAdjusting = false
                model.store.endEdit()
            }
    }

    private var moveInk: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                let scale = model.viewport.scale
                let total = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                model.moveSelectedInk(by: CGSize(width: total.width - inkDragged.width, height: total.height - inkDragged.height))
                inkDragged = total
                model.isAdjusting = true
            }
            .onEnded { _ in
                model.isAdjusting = false
                model.finishMovingInk(movedBy: inkDragged)
                inkDragged = .zero
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
