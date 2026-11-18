@_weakLinked import AppIntents
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
        let isInCall = model.isInVoiceCall
        ZStack(alignment: .topLeading) {
                // Its own view, so that scrolling redraws the grid and not this whole screen.
                LiveCanvasGrid()

                OnCanvas {
                    ForEach(model.store.screens) { screen in
                        PhoneScreenView(screen: screen, showsName: model.store.canvas.showsFrameNames)
                            .offset(x: screen.origin.x, y: screen.origin.y)
                            // An element dragged off its screen stays above the others until dropped.
                            .zIndex(screensBeingDraggedFrom.contains(screen.id) ? 1 : 0)
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
                    // In a compact window the palette is a bar across the bottom, which a
                    // panel's sheet takes the place of. The bar is up for as long as Draw is on.
                    hidesPalette: usesSheets && (model.isLayersOpen || model.isInspectorOpen),
                    fingerDraws: model.fingerDraws,
                    watchesPencil: model.needsPencilDetector,
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
                SweepOutline()
                SelectionActions()
                SuggestionPill()
                PenCursor(pen: model.pen)
                EdgeGlow(accent: accent, isActive: !model.effects.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The view's size, read without a GeometryReader wrapped round the whole canvas.
        .onGeometryChange(for: CGSize.self, of: \.size) { model.canvasSize = $0 }
        // Apple Pencil, or a pointer, hovering over the canvas outlines what it is over. Only
        // with the palette away: while drawing, the pen's own cursor shows where it is.
        .onContinuousHover(coordinateSpace: .local) { phase in
            // The pen coming near gets the pencil's model ready, so the first squeeze
            // doesn't wait for it. Nothing listens yet.
            if case .active = phase { model.pencilVoice.hovered() }
            guard !model.isHoveringList else { return }
            var target: CanvasSelection?
            if case .active(let point) = phase, model.tool == .select, point.y > model.topBarBottom,
               !model.chromeFrames.values.contains(where: { $0.contains(point) }) {
                target = model.hoverTarget(at: point)
            }
            if model.hovered != target { model.hovered = target }
        }
        // Apple Pencil Pro's squeeze listens for a command about what the pen is over. Every
        // visible view's squeeze action is called, so this one goes on a layer of its own
        // behind the canvas: that way it can be left out in Draw, where the squeeze must stay
        // PencilKit's, without the canvas itself being made anew each time Draw turns on.
        .background {
            Color.clear.modifier(SqueezeToSpeak(pencil: model.pencilVoice, isOn: model.tool != .draw))
        }
        // Things dragged out of the library land where they are dropped: on a screen when
        // dropped over one, on the open canvas otherwise.
        .dropDestination(for: String.self) { ids, location in
            let assets = ids.compactMap(AssetLibrary.asset(id:))
            guard !assets.isEmpty else { return false }
            withAnimation(.smooth(duration: 0.3)) {
                for (index, asset) in assets.enumerated() {
                    // Several at once fan out a little, rather than piling up.
                    let offset = CGFloat(index) * 24
                    model.addAsset(asset, at: CGPoint(x: location.x + offset, y: location.y + offset))
                }
            }
            return true
        }
        .ignoresSafeArea()
        // A screen being generated says how it is getting on, clear of the screen itself.
        // During a call the pill says it instead.
        .overlay(alignment: .bottom) {
            if !isInCall {
                GenerationStatus()
                    .reportsChromeFrame("generation", to: model)
                    .padding(.bottom, 20)
                    .animation(.smooth(duration: 0.3), value: model.generation == nil)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 12) {
                TopBar()
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { model.topBarBottom = $0 }
                    .reportsChromeFrame("top bar", to: model)
                // The panels hang below the bar while the window can have them beside
                // the canvas.
                if !usesSheets {
                    HStack(alignment: .top, spacing: 12) {
                        if model.isLayersOpen {
                            LayersPanel(maxHeight: panelRoom)
                                .reportsChromeFrame("layers", to: model)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        Spacer(minLength: 0)
                        if model.isInspectorOpen {
                            StylePanel(maxHeight: panelRoom)
                                .reportsChromeFrame("format", to: model)
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
            // Undo and redo join the zoom at any width, which leaves the other corner free.
            // A call's pill takes their place along the bottom while it is up.
            if !isInCall {
                ViewControls()
                    // A Pencil on the zoom or undo isn't on the element under them.
                    .reportsChromeFrame("view controls", to: model)
                    .modifier(BottomCorner(edge: .leading))
                    .transition(.opacity)
            }
        }
        .overlay {
            // The free corner of a narrow window is where voice mode starts.
            if isCompact, model.offersVoiceMode {
                PhoneButton()
                    .reportsChromeFrame("phone button", to: model)
                    .modifier(BottomCorner(edge: .trailing))
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            CallPill()
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        // The pencil's bubble, at the tip where a squeeze opened it, over the canvas and
        // its controls, laid out in the canvas's own points as the squeeze was.
        .overlay {
            PencilVoiceLayer()
                .ignoresSafeArea()
        }
        // In a modifier of its own: one chain this long is more than a Release build can
        // type-check in reasonable time.
        .modifier(CanvasEvents(model: model, undoManager: undoManager))
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

    /// The screens that hold elements being dragged, one or several of them.
    private var screensBeingDraggedFrom: Set<DesignScreen.ID> {
        guard model.isAdjusting, let selection = model.selection else { return [] }
        return Set(selection.things.compactMap { thing in
            if case .element(let ref) = thing, case .screen(let id) = ref.host { id } else { nil }
        })
    }
}

/// What the canvas listens for and tells the system: leaving the screen, its notices,
/// the undo manager, and what Siri can see.
private struct CanvasEvents: ViewModifier {
    let model: AppModel
    let undoManager: UndoManager?

    func body(content: Content) -> some View {
        content
        // Layer only listens while it is in front.
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { note in
            if let scene = note.object as? UIScene, scene === model.ink?.windowScene { model.windowLeftTheScreen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            model.windowLeftTheScreen()
        }
        .alert("Voice Mode", isPresented: Binding(
            get: { model.voiceNotice != nil },
            set: { if !$0 { model.voiceNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.voiceNotice ?? "")
        }
        .background(model.store.canvas.resolvedBackground.color)
        // What is on the canvas, for Siri and Apple Intelligence: see `OnscreenContext`.
        .appEntityUIElements { [model] context in model.onscreenEntities(context) }
        .appEntityIdentifier(model.designEntityIdentifier)
        .background { Color.clear.modifier(ImagePlaygroundPresenter()) }
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
            await VoiceDemo.runIfRequested(on: model)
            #endif
        }
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
            // The sheet is chrome too: a pencil over it isn't over the canvas beneath. In
            // window points, which a sheet's own global space may not be.
            .background { WindowFrameReporter(name: "panel sheet", model: model) }
            .environment(model)
            .environment(model.images)
            .preferredColorScheme(.light)
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
    }
}

/// Tells the model where a view is in its window's points, for a view that may sit in a
/// presentation of its own, such as a sheet, where SwiftUI's global space is the sheet's.
private struct WindowFrameReporter: UIViewRepresentable {
    let name: String
    let model: AppModel

    func makeUIView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.isUserInteractionEnabled = false
        view.report = { [weak model] frame in model?.chromeFrames[name] = frame }
        return view
    }

    func updateUIView(_ view: ReportingView, context: Context) {
        view.reportFrame()
    }

    static func dismantleUIView(_ view: ReportingView, coordinator: ()) {
        view.report(nil)
    }

    final class ReportingView: UIView {
        var report: (CGRect?) -> Void = { _ in }
        private var reported: CGRect?

        override func layoutSubviews() {
            super.layoutSubviews()
            reportFrame()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportFrame()
        }

        func reportFrame() {
            // The canvas fills its window, so the window's points are the canvas's.
            let frame = window.map { convert(bounds, to: $0) }
            guard frame != reported else { return }
            reported = frame
            report(frame)
        }
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

/// Feeds Apple Pencil Pro's squeezes to the pencil's push-to-talk while `isOn`. While off
/// the action is not there at all: an action that is there, even one that ignores the
/// squeeze, stops PencilKit's palette coming up at the tip in Draw (seen on the iPad).
private struct SqueezeToSpeak: ViewModifier {
    let pencil: PencilVoice
    let isOn: Bool
    /// Whether a squeeze is under way. Its `.active` comes every 10–20 ms while it lasts,
    /// and only the first one starts anything, as with the scrubber.
    @State private var isSqueezing = false

    func body(content: Content) -> some View {
        Group {
            if isOn {
                squeezable(content)
            } else {
                content
            }
        }
        // Draw coming on mid-squeeze means its end never arrives here.
        .onChange(of: isOn) { isSqueezing = false }
        // Nor does it once the canvas has gone.
        .onDisappear {
            if isSqueezing { pencil.squeezeFailed() }
            isSqueezing = false
        }
    }

    private func squeezable(_ content: Content) -> some View {
        content.onPencilSqueeze { phase in
            switch phase {
            case .active(let value):
                guard !isSqueezing else { return }
                isSqueezing = true
                pencil.squeezeBegan(at: value.hoverPose?.location, azimuth: value.hoverPose?.azimuth)
            case .ended:
                isSqueezing = false
                pencil.squeezeEnded()
            case .failed:
                // Nobody said the squeeze was over, so a held one sends nothing.
                isSqueezing = false
                pencil.squeezeFailed()
            }
        }
    }
}

/// A soft outline round what Apple Pencil is hovering over, on the canvas or in the
/// layers list, unless it is already selected.
private struct HoverOutline: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let target = model.hovered, model.selection?.contains(target) != true, let rect = model.viewRect(of: target) {
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

/// The line being drawn round things to select them: the lasso's loop, dashed and closed
/// back to where it began, as PencilKit's own lasso is drawn; or the box a finger drags out.
private struct SweepOutline: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.sweep {
        case .lasso(let points):
            if let first = points.first {
                Path { path in
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                }
                .fill(Theme.accent.color.opacity(0.06))
                .allowsHitTesting(false)
                Path { path in
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(Theme.accent.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [6, 5]))
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Lasso")
            }
        case .box(let start, let end):
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.accent.color.opacity(0.08))
                .strokeBorder(Theme.accent.color.opacity(0.8), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Selection box")
        case nil:
            EmptyView()
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
extension View {
    /// Tells the model where this floating control is, so that a Pencil touch or hover
    /// on it isn't taken for one on the canvas. `shapeOnly` is for controls laid out across
    /// the whole view that only take touches where they draw: none is reported for them.
    func reportsChromeFrame(_ name: String, to model: AppModel, shapeOnly: Bool = false) -> some View {
        self
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if !shapeOnly { model.chromeFrames[name] = frame }
            }
            .onDisappear { model.chromeFrames[name] = nil }
    }
}

extension EnvironmentValues {
    /// True while the canvas is part way through a zoom, when costly effects such as large
    /// shadows are left out and come back once it settles.
    @Entry var isCanvasZooming = false
}

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
            .environment(\.isCanvasZooming, abs(model.zoomScale - model.settledScale) > 0.001)
                .scaleEffect(viewport.scale, anchor: .topLeading)
                .offset(x: -viewport.offset.x, y: -viewport.offset.y)
        }
    }
}
