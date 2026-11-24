@_weakLinked import AppIntents
import SwiftUI

/// One design: an endless canvas with device screens, ink, and floating controls.
struct CanvasScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// What the last A2UI dropped or pasted here made, and left out, until its sheet is put away (F19).
    @State private var importReport: A2UIImportReport?

    var body: some View {
        let accent = Theme.accent.color
        let isCompact = model.isCompactWidth
        let usesSheets = model.isCompactSizeClass
        let isInCall = model.isInVoiceCall
        ZStack(alignment: .topLeading) {
                // Its own view, so that scrolling redraws the grid and not this whole screen.
                LiveCanvasGrid()

                OnCanvas {
                    // Drawn from the tree, each screen and canvas node compared by value: an edit draws
                    // again only the views on its path.
                    let tree = model.store.tree
                    let tokens = tree.settings.tokens
                    let showsNames = tree.settings.showsFrameNames
                    let raised = model.screensBeingDraggedFrom
                    ForEach(tree.screens) { screen in
                        ScreenView(screen: screen, device: tree.device(of: screen), tokens: tokens, showsName: showsNames)
                            .equatable()
                            .offset(x: screen.origin.x, y: screen.origin.y)
                            // An element dragged off its screen stays above the others until dropped.
                            .zIndex(raised.contains(screen.id) ? 1 : 0)
                            .transition(.blurReplace)
                    }
                    ForEach(tree.canvas) { node in
                        CanvasNodeView(node: node, tokens: tokens)
                            .equatable()
                            // A locked drawing is above the other things, as it is touched. An unlocked one
                            // draws nothing here: PencilKit draws it.
                            .zIndex(node.kind == .drawing ? 3 : 2)
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
                // What a tap there would pick: a grouped thing's outermost group, say.
                target = model.hoverTarget(at: point).map { model.pickTarget($0) }
            }
            if model.hovered != target { model.hovered = target }
        }
        // Apple Pencil Pro's squeeze: the window's one handler, and the pencil's roll and
        // ticks for a ruler. On a layer of their own behind the canvas, so that the handler
        // can be left out without the canvas itself being made anew each time.
        .background { WindowSqueeze() }
        // Things dragged out of the library, and A2UI dropped or pasted.
        .modifier(CanvasDrops(model: model, report: $importReport))
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
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("Format panel")
                                .reportsChromeFrame(AppModel.formatChrome, to: model)
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
            get: { model.panelIsASheet && model[keyPath: isOpen] },
            set: { model[keyPath: isOpen] = $0 }
        )
    }
}

/// What the canvas takes. Things dragged out of the library land where they are dropped: on a screen when dropped over
/// one, on the open canvas otherwise. A2UI dropped as text or a `.json` file becomes new screens from where it was
/// dropped, and A2UI pasted with ⌘V becomes new screens where new screens go (call 17). What an import couldn't bring
/// in as it was written is shown afterwards.
///
/// On iPadOS 27.2 a hardware keyboard's ⌘V doesn't reach `pasteDestination` here, with the pencil palette up or not,
/// though ⌘Z does reach the app: plan 4, which rebuilds the canvas, takes that up. The add menu's Paste works.
private struct CanvasDrops: ViewModifier {
    let model: AppModel
    @Binding var report: A2UIImportReport?

    func body(content: Content) -> some View {
        content
            .dropDestination(for: CanvasDrop.DroppedText.self) { items, location in
                switch CanvasDrop.payload(ofDropped: items) {
                case .assets(let ids):
                    withAnimation(.smooth(duration: 0.3)) {
                        for (index, asset) in ids.compactMap(AssetLibrary.asset(id:)).enumerated() {
                            // Several at once fan out a little, rather than piling up.
                            let offset = CGFloat(index) * 24
                            model.addAsset(asset, at: CGPoint(x: location.x + offset, y: location.y + offset))
                        }
                    }
                    return true
                case .a2ui(let data):
                    let point = model.viewport.canvasPoint(for: location)
                    Task { report = await model.importA2UI(data, near: point) }
                    return true
                case .tooLarge:
                    report = A2UIImportReport(screens: [], diagnostics: [A2UIImporter.tooLarge])
                    return true
                case nil:
                    return false
                }
            }
            .pasteDestination(for: String.self) { strings in
                guard case .a2ui(let data)? = CanvasDrop.payload(of: strings) else { return }
                Task { report = await model.importA2UI(data) }
            } validator: { strings in
                strings.filter(A2UIImporter.looksLikeA2UI)
            }
            .a2uiImportSheet($report)
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
        .alert("Couldn't Undo", isPresented: Binding(
            get: { model.undoNotice != nil },
            set: { if !$0 { model.undoNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.undoNotice ?? "")
        }
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
            .background {
                // The sheet is chrome too: a pencil over it isn't over the canvas beneath. In
                // window points, which a sheet's own global space may not be.
                WindowFrameReporter(name: AppModel.panelSheetChrome, model: model)
                // The squeeze, on the very view the frame is of: its points start where that
                // frame does.
                SheetSqueeze(model: model)
            }
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
struct WindowFrameReporter: UIViewRepresentable {
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

/// The window's one Apple Pencil Pro squeeze handler: the router says who each squeeze is
/// for, a Format field's or the zoom's ruler, or push-to-talk. Every visible view's squeeze
/// action is called, in no fixed order, so there is only this one. Behind it, the bridge
/// that follows the pencil's roll anywhere in the window and plays a ruler's ticks.
private struct WindowSqueeze: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let router = model.squeezeRouter
        // Draw, Squeeze to Talk, whether a ruler would take a squeeze, a squeeze under way
        // and a panel's sheet, all observed.
        let isOn = router.windowHandlerIsOn
        ZStack {
            PencilBridge(scrubber: model.scrubber)
            // Not `Color.clear`, which gets no squeezes on the iPad.
            Color.black.opacity(0.001)
                .modifier(Squeezable(router: router, isOn: isOn))
        }
        .onChange(of: isOn, initial: true) { _, isOn in
            VoiceLog.log.info("pencil: the window's squeeze handler is \(isOn ? "on" : "off", privacy: .public)")
            // Draw on, Squeeze to Talk off with nothing to scrub, or a panel's sheet up: the
            // squeeze under way, if any, won't be heard to end here.
            if !isOn { router.failed() }
        }
        // Nor once the canvas has gone.
        .onDisappear { router.failed() }
    }
}

/// A panel's sheet's squeeze handler. While a panel is a sheet, it has the squeezes rather
/// than the window's under it: the system doesn't promise squeezes to a view under a sheet,
/// and only one handler is there at a time. Its points are the sheet's, put in the window's.
private struct SheetSqueeze: View {
    let model: AppModel

    var body: some View {
        let router = model.squeezeRouter
        let isOn = router.sheetHandlerIsOn
        // Not `Color.clear`, which gets no squeezes on the iPad.
        Color.black.opacity(0.001)
            .modifier(Squeezable(router: router, isOn: isOn, offset: { router.sheetOrigin }))
            .onChange(of: isOn) { _, isOn in
                VoiceLog.log.info("pencil: the panel sheet's squeeze handler is \(isOn ? "on" : "off", privacy: .public)")
                if !isOn { router.failed() }
            }
            .onDisappear { if isOn { router.failed() } }
    }
}

/// Gives `router` Apple Pencil Pro's squeezes while `isOn`: the only place a squeeze action
/// is set. While off, the action is not there at all: an action that is there, even one that
/// ignores the squeeze, stops PencilKit's palette coming up at the tip in Draw (seen on the
/// iPad), and the system's own squeeze action elsewhere.
struct Squeezable: ViewModifier {
    let router: SqueezeRouter
    let isOn: Bool
    /// Where the view is in the window, which its points are counted from.
    var offset: () -> CGPoint = { .zero }

    func body(content: Content) -> some View {
        if isOn {
            content.onPencilSqueeze { phase in
                switch phase {
                case .active(let value):
                    // It comes every 10–20 ms while the squeeze lasts: the router acts on the first.
                    let pose = value.hoverPose
                    router.began(at: SqueezeRouter.windowPoint(pose?.location, offsetBy: offset()), azimuth: pose?.azimuth, roll: pose?.roll)
                case .ended:
                    router.ended()
                case .failed:
                    // Nobody said the squeeze was over, so a held one sends nothing.
                    router.failed()
                }
            }
        } else {
            content
        }
    }
}

/// A soft outline round what Apple Pencil is hovering over, on the canvas or in the
/// layers list, unless it is already selected.
private struct HoverOutline: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let target = model.hovered, model.selection?.contains(target) != true,
           let canvasShape = model.store.canvasShape(of: target) {
            // Drawn on the turned shape, so a turned element's outline turns with it.
            let shape = model.viewport.viewShape(for: canvasShape)
            let outer = shape.rect.insetBy(dx: -3, dy: -3)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.accent.color.opacity(0.55), lineWidth: 1.5)
                .background(Theme.accent.color.opacity(0.05), in: .rect(cornerRadius: 6, style: .continuous))
                .frame(width: outer.width, height: outer.height)
                .rotationEffect(.degrees(shape.degrees))
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
