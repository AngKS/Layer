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

    var body: some View {
        let store = model.store
        let viewport = model.viewport
        ZStack(alignment: .topLeading) {
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
                    dragArea(viewport.viewRect(for: screen.labelFrame))
                        .onTapGesture { model.selection = .screen(screen.id) }
                        .gesture(moveScreen(screen), including: screen.isLocked == true ? .subviews : .all)
                    ForEach(screen.elements) { element in
                        target(for: element, ref: .init(host: .screen(screen.id), element: element.id), placement: screen.placement, on: screen.size)
                    }
                }
                ForEach(store.floating) { floating in
                    target(for: floating.element, ref: .init(host: .canvas, element: floating.id), placement: floating.placement, on: nil)
                }
            }
            .allowsHitTesting(model.tool == .select)

            // With the palette up, the selected element is moved by its own area.
            if model.tool == .draw, let selected = model.selectedElement {
                let snaps = model.store.canvas.snapsToGuides
                let screen: CGSize? = if case .screen(let id) = selected.ref.host { store.screen(id)?.size } else { nil }
                dragArea(viewport.viewRect(for: selected.placement.canvasRect(for: selected.element.frame)))
                    .gesture(adjust(selected.ref, from: selected.element.frame, placement: selected.placement, findsNewHome: true) { origin, translation in
                        ElementLayout.moved(origin, by: translation, snapsToCenter: snaps && screen != nil, in: screen ?? DeviceFrame.iPhone.size)
                    }, including: selected.element.isLocked == true ? .subviews : .all)
            }

            if let screen = model.selectedScreen {
                outline(viewport.viewRect(for: screen.canvasFrame), radius: screen.device.cornerRadius * screen.scale * viewport.scale)
            }
            if let bounds = model.inkSelectionBounds {
                outline(viewport.viewRect(for: bounds).insetBy(dx: -5, dy: -5), radius: 4)
            }
            if let selected = model.selectedElement {
                let rect = viewport.viewRect(for: selected.placement.canvasRect(for: selected.element.frame))
                if model.isAdjusting, case .screen(let id) = selected.ref.host, let screen = store.screen(id) {
                    SpacingOverlay(guides: .measure(selected.element, in: screen), screen: screen, viewport: viewport)
                }
                outline(rect, radius: selected.element.resolvedCornerRadius * selected.placement.scale * viewport.scale)
                if selected.element.isLocked != true {
                    ForEach(ElementLayout.Corner.allCases, id: \.self) { corner in
                        handle(corner, at: rect, for: selected.element, ref: selected.ref, placement: selected.placement)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    /// An invisible area that takes touches, at least big enough for a finger.
    private func dragArea(_ rect: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: max(rect.width, 30), height: max(rect.height, 30))
            .position(x: rect.midX, y: rect.midY)
    }

    /// `screen` is the size of the screen the element is on, or nil on the open canvas.
    private func target(for element: DesignElement, ref: DesignStore.ElementRef, placement: Placement, on screen: CGSize?) -> some View {
        let snaps = screen != nil && model.store.canvas.snapsToGuides
        return dragArea(model.viewport.viewRect(for: placement.canvasRect(for: element.frame)))
            .onTapGesture { model.selection = .element(ref) }
            .gesture(adjust(ref, from: element.frame, placement: placement, findsNewHome: true) { origin, translation in
                ElementLayout.moved(origin, by: translation, snapsToCenter: snaps, in: screen ?? DeviceFrame.iPhone.size)
            }, including: element.isLocked == true ? .subviews : .all)
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
                ElementLayout.resized(origin, from: corner, by: translation, kind: element.kind)
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
        apply: @escaping (_ origin: CGRect, _ translation: CGSize) -> CGRect
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
                model.store.update(ref) { $0.frame = apply(elementDragOrigin, translation) }
            }
            .onEnded { _ in
                elementDragOrigin = nil
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
                model.store.updateScreen(screen.id) {
                    $0.origin = CGPoint(
                        x: (screenDragOrigin.x + value.translation.width / scale).rounded(),
                        y: (screenDragOrigin.y + value.translation.height / scale).rounded()
                    )
                }
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
