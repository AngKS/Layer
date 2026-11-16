import SwiftUI

/// One design: an endless canvas with device screens, ink, and floating controls.
struct CanvasScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let accent = Theme.accent.color
        let isCompact = model.isCompactWidth
        let usesSheets = model.isCompactSizeClass
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Its own view, so that scrolling redraws the grid and not this whole screen.
                LiveCanvasGrid()

                OnCanvas {
                    ForEach(model.store.screens) { screen in
                        PhoneScreenView(screen: screen)
                            .offset(x: screen.origin.x, y: screen.origin.y)
                            // An element dragged off its screen stays above the others until dropped.
                            .zIndex(screen.id == screenBeingDraggedFrom ? 1 : 0)
                            .transition(.blurReplace)
                    }
                    ForEach(model.store.floating) { floating in
                        FloatingElementView(floating: floating)
                            .zIndex(2)
                            .transition(.blurReplace)
                    }
                }

                InkCanvas(
                    model: model, tool: model.tool, isLocked: model.isCanvasLocked,
                    // In a compact window the palette is a bar across the bottom, which
                    // can be tucked away, and which a panel's sheet takes the place of.
                    hidesPalette: usesSheets && (model.isPaletteCollapsed || model.isLayersOpen || model.isInspectorOpen),
                    fingerDraws: model.fingerDraws,
                    topInset: model.topBarBottom, undoManager: undoManager
                )

                OnCanvas {
                    ForEach(model.effects) { effect in
                        RetraceView(effect: effect, accent: accent)
                            .transition(.opacity)
                    }
                    ForEach(model.ghosts) { ghost in
                        GhostView(ghost: ghost)
                    }
                }
                .allowsHitTesting(false)

                SelectionLayer()
                HoverOutline()
                SelectionActions()
                PenCursor(pen: model.pen)
                EdgeGlow(accent: accent, isActive: !model.effects.isEmpty)
            }
            .onChange(of: proxy.size, initial: true) { _, size in
                model.canvasSize = size
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            VStack(spacing: 12) {
                TopBar()
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { model.topBarBottom = $0 }
                // The panels hang below the bar while the window can have them beside
                // the canvas.
                if !usesSheets {
                    HStack(alignment: .top, spacing: 12) {
                        if model.isLayersOpen {
                            LayersPanel(maxHeight: panelRoom)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        Spacer(minLength: 0)
                        if model.isInspectorOpen {
                            StylePanel(maxHeight: panelRoom)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
            // Not by `isCompact`: the bar's own fit decides that, so it mustn't change the bar's room.
            .padding(.horizontal, usesSheets ? 12 : 20)
            .padding(.top, 12)
        }
        .onChange(of: sizeClass, initial: true) { _, sizeClass in
            model.isCompactSizeClass = sizeClass == .compact
        }
        // In a compact window a panel is a sheet over the lower half, with the canvas
        // above it still live.
        .sheet(isPresented: sheet(\.isLayersOpen)) {
            PanelSheet(model: model) { LayersPanel(isSheet: true) }
        }
        .sheet(isPresented: sheet(\.isInspectorOpen)) {
            PanelSheet(model: model) { StylePanel(isSheet: true) }
        }
        .overlay {
            VStack(alignment: .leading, spacing: 12) {
                SelectionReadout()
                // Narrow, undo and redo join the zoom, which leaves the other corner free.
                if isCompact { ViewControls() } else { ZoomControl() }
            }
            .modifier(BottomCorner(edge: .leading))
        }
        .overlay {
            if !isCompact {
                UndoControl()
                    .modifier(BottomCorner(edge: .trailing))
            } else if usesSheets, model.tool == .draw, !model.isLayersOpen, !model.isInspectorOpen {
                PaletteToggle()
                    .modifier(BottomCorner(edge: .trailing))
            }
        }
        .background(Theme.canvas)
        .alert("Another Version Was Kept", isPresented: Binding(
            get: { model.keptVersionsNotice != nil },
            set: { if !$0 { model.keptVersionsNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.keptVersionsNotice ?? "")
        }
        .onChange(of: undoManager, initial: true) { _, undoManager in
            model.store.undoManager = undoManager
        }
        .task {
            model.engine.prepare()
            #if DEBUG
            await DemoScript.runIfRequested(on: model)
            #endif
        }
    }

    /// How tall a panel beside the canvas can be: from under the bar down to just short
    /// of the controls along the bottom.
    private var panelRoom: CGFloat {
        max(model.canvasSize.height - model.topBarBottom - 12 - 96, 180)
    }

    /// Whether a panel is showing as a sheet, which it only does in a compact window.
    private func sheet(_ isOpen: ReferenceWritableKeyPath<AppModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.isCompactSizeClass && model[keyPath: isOpen] },
            set: { model[keyPath: isOpen] = $0 }
        )
    }

    private var screenBeingDraggedFrom: DesignScreen.ID? {
        guard model.isAdjusting, case .element(let ref) = model.selection, case .screen(let id) = ref.host else { return nil }
        return id
    }
}

/// How a panel is presented when it can't sit beside the canvas: a sheet that opens over
/// the lower half, leaving the canvas above it live, and can be pulled up to full height.
private struct PanelSheet<Content: View>: View {
    let model: AppModel
    @ViewBuilder var content: Content
    @State private var detent = PresentationDetent.medium

    var body: some View {
        content
            .environment(model)
            .environment(model.images)
            .preferredColorScheme(.light)
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.panel)
    }
}

/// Pins a control into a bottom corner, the same distance in from the edges as the bar
/// across the top. The pencil palette may sit over it; that is the palette's to decide.
private struct BottomCorner: ViewModifier {
    let edge: HorizontalEdge

    func body(content: Content) -> some View {
        content
            .padding(edge == .leading ? .leading : .trailing, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .leading ? .bottomLeading : .bottomTrailing)
    }
}

/// A soft outline round what Apple Pencil is hovering over, on the canvas or in the
/// layers list, unless it is already selected.
private struct HoverOutline: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let target = model.hovered, target != model.selection, let rect = model.viewRect(of: target) {
            let outer = rect.insetBy(dx: -3, dy: -3)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.accent.color.opacity(0.55), lineWidth: 1.5)
                .background(Theme.accent.color.opacity(0.05), in: .rect(cornerRadius: 6, style: .continuous))
                .frame(width: outer.width, height: outer.height)
                .position(x: outer.midX, y: outer.midY)
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.12), value: target)
        }
    }
}

/// The grid, following the viewport.
private struct LiveCanvasGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        CanvasGrid(viewport: model.viewport, settings: model.store.canvas)
    }
}

/// Draws its content in canvas points, moved and scaled to where the viewport shows it.
private struct OnCanvas<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @ViewBuilder var content: Content

    var body: some View {
        let viewport = model.viewport
        // Drawn over a clear view that is the size of the window, so that what is on the
        // canvas takes no part in layout. A frame taller than the window would otherwise
        // stretch everything layered with it, the ink canvas included, past the window's edge.
        Color.clear.overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) { content }
                .fixedSize()
                // Zoomed in, text and symbols are drawn with proportionally more pixels, so
                // they stay sharp rather than being a magnified picture.
                // Capped at twice: beyond that the backing stores grow by the square of the zoom
            // and every change to the board takes longer to draw.
            .environment(\.displayScale, displayScale * min(max(model.settledScale, 1), 2))
                .scaleEffect(viewport.scale, anchor: .topLeading)
                .offset(x: -viewport.offset.x, y: -viewport.offset.y)
        }
    }
}
