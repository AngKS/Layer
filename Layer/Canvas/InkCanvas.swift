import PencilKit
import SwiftUI

/// The undo manager the document's ink canvas hands to PencilKit and to the system.
///
/// Undo and redo asked of it, by the palette's buttons or the system's gestures, go to the
/// document's own history. What PencilKit registers with it for its strokes goes nowhere.
/// The design keeps ink's history itself, as changes to its drawings (see `DrawingSync`),
/// because PencilKit's own entries stop working once the canvas has been set from the
/// design, as it is whenever a drawing is moved, locked, hidden, deleted or put back.
final class InkUndoManager: UndoManager {
    /// The document's history, which undo and redo are passed on to.
    weak var document: UndoManager? {
        didSet {
            guard document !== oldValue else { return }
            let center = NotificationCenter.default
            for name in Self.changes {
                center.removeObserver(self, name: name, object: oldValue)
                if let document { center.addObserver(self, selector: #selector(documentChanged(_:)), name: name, object: document) }
            }
        }
    }

    private static let changes: [Notification.Name] = [
        .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
        DesignStore.historyDidChange,
    ]

    override init() {
        super.init()
        // What PencilKit registers here is never undone, so none of it need be kept.
        levelsOfUndo = 1
    }

    override var canUndo: Bool { document?.canUndo ?? false }
    override var canRedo: Bool { document?.canRedo ?? false }
    override func undo() { document?.undo() }
    override func redo() { document?.redo() }
    override var undoMenuItemTitle: String { document?.undoMenuItemTitle ?? super.undoMenuItemTitle }
    override var redoMenuItemTitle: String { document?.redoMenuItemTitle ?? super.redoMenuItemTitle }

    /// Says for the document's history what it says for itself, so that whatever watches
    /// this one, the palette's buttons for instance, knows when undo and redo can be done.
    @objc private func documentChanged(_ note: Notification) {
        NotificationCenter.default.post(name: note.name, object: self)
    }
}

/// Where the design's drawings are drawn on: it holds the strokes of every drawing that
/// is neither locked nor hidden. The drawings themselves are kept in the design, and
/// each change to the strokes here is a change to them there, which is what makes ink
/// undoable alongside everything else: see `DrawingSync` and `InkUndoManager`.
final class DocumentCanvasView: PKCanvasView {
    let inkUndoManager = InkUndoManager()
    var documentUndoManager: UndoManager? {
        get { inkUndoManager.document }
        set { inkUndoManager.document = newValue }
    }
    var onMoveToWindow: (() -> Void)?
    var onLayout: (() -> Void)?

    override var undoManager: UndoManager? {
        documentUndoManager == nil ? super.undoManager : inkUndoManager
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Holds Magic Pen sketches. They are not part of the document, so they have no undo history.
final class SketchCanvasView: PKCanvasView {
    override var undoManager: UndoManager? { nil }
}

/// The ink layers, the PencilKit palette, and the scrolling and zooming of the canvas.
///
/// Two PencilKit canvases fill the view. The document canvas takes the palette's pens and
/// eraser; the sketch canvas sits above it and takes the Magic Pen. The palette's lasso
/// draws on neither: its loop selects what it goes round, see `LassoGestureRecognizer`. Each is
/// a scroll view over the whole canvas, and whichever one the fingers are on leads while
/// the other follows, so the pair pan and zoom as one. Their scroll position is published
/// as the model's viewport, which everything drawn in SwiftUI follows.
struct InkCanvas: UIViewRepresentable {
    let model: AppModel
    let tool: AppModel.Tool
    let isLocked: Bool
    /// Whether the palette stays away even in draw mode, because something else is in its place.
    let hidesPalette: Bool
    /// Whether a finger draws too, with the palette up, or is left for selecting and panning.
    let fingerDraws: Bool
    /// Whether the Pencil detector has anything to do. See `AppModel.needsPencilDetector`.
    let watchesPencil: Bool
    /// How far down the view the bar across the top reaches.
    let topInset: CGFloat
    let undoManager: UndoManager?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        for canvas in context.coordinator.canvases {
            canvas.frame = container.bounds
            canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(canvas)
        }
        container.addGestureRecognizer(context.coordinator.tap)
        container.addGestureRecognizer(context.coordinator.lasso)
        container.addGestureRecognizer(context.coordinator.box)
        model.ink = context.coordinator
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.documentCanvas.documentUndoManager = undoManager
        context.coordinator.watchHistory(undoManager)
        context.coordinator.apply(tool)
        context.coordinator.setLocked(isLocked)
        context.coordinator.setHidesPalette(hidesPalette)
        context.coordinator.setFingerDraws(fingerDraws)
        // Off when it has nothing to do, so it doesn't take part in every touch in the window.
        context.coordinator.pencilDetector.isEnabled = watchesPencil
        context.coordinator.setTopInset(topInset)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.flushPendingInk()
        coordinator.stopWatchingHistory()
        coordinator.hidePalette()
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, PKToolPickerObserver, UIGestureRecognizerDelegate {
        let model: AppModel
        let documentCanvas = DocumentCanvasView()
        let sketchCanvas = SketchCanvasView()
        /// Taps on the canvas outside draw mode: selecting, deselecting, leaving comments.
        let tap = UITapGestureRecognizer()
        /// The palette's lasso: a loop drawn with it selects what it goes round, elements
        /// and screens as well as ink. PencilKit's own lasso knows only strokes, so with
        /// the lasso in hand the document canvas stops drawing and this takes the loop.
        let lasso = LassoGestureRecognizer()
        /// A finger that rests on the canvas and then drags pulls out a box, which
        /// selects what it holds, as in Freeform.
        let box = UILongPressGestureRecognizer()
        /// Where the box being dragged out began, in the container's points.
        private var boxStart: CGPoint?
        /// Notices Apple Pencil touching the canvas, without taking part in anything.
        let pencilDetector = PencilDetector()
        /// Notice the pencil bar of a narrow window being flicked away: one for each window
        /// of the scene, because iPadOS keeps that bar in a window of its own.
        private var paletteFlicks: [PaletteFlick] = []
        /// Knows where fingers are resting, for tapping things while one is held.
        let restingFingers = RestingFingerDetector()
        /// Two fingers on the selection that turn before they pinch turn it with them. The
        /// resting-finger and Pencil detectors and the flicks go along with it, as they go
        /// along with every gesture.
        let twist = TwistGestureRecognizer()
        private var fingerDraws = true
        let palette = PKToolPicker(toolItems: MagicPen.paletteItems())
        private var tool: AppModel.Tool?
        private var isFollowing = false
        /// The view size the viewport was last arranged for.
        private var arrangedViewSize = CGSize.zero
        /// Whether the canvas is still framed the way the design opened, not yet moved or used.
        private var isAtOpeningViewport = true
        /// True while the viewport is being set from here rather than moved by touch.
        private var isShowing = false
        private var topInset: CGFloat = 0
        private var hidesPalette = false
        private var zoomAnimation: ZoomAnimation?
        /// `SketchStroke`s already made for sketch strokes that haven't changed since, so
        /// that drawing one more stroke doesn't re-interpolate every stroke already on the
        /// canvas on every touch event, only the one still being drawn. Keyed by the
        /// stroke, with how many points it had when it was last turned into one of these,
        /// since `PKStroke` isn't equatable: a stroke only grows while it is being drawn,
        /// so the same point count means the same points.
        private var sketchStrokeCache: [Double: (pointCount: Int, result: SketchStroke)] = [:]
        /// Which strokes on the document canvas belong to which of the design's drawings.
        private var drawings = DrawingSync()
        /// True while the document canvas is being set from the design, which is not a
        /// change for the design to follow.
        private var isShowingDrawings = false
        /// Each stroke on the document canvas with the area it covers, for finding the ink
        /// under the Pencil as it hovers. Worked out once after the strokes change, rather
        /// than for every stroke on every hover event.
        private var inkAreas: [(stroke: PKStroke, area: CGRect)]?
        /// Whether the Magic Pen is drawing a stroke on the sketch canvas.
        private var isSketchPenDown = false

        var canvases: [PKCanvasView] { [documentCanvas, sketchCanvas] }

        init(model: AppModel) {
            self.model = model
            super.init()
            for canvas in canvases {
                canvas.backgroundColor = .clear
                canvas.isOpaque = false
                canvas.contentInsetAdjustmentBehavior = .never
                // PencilKit recolours ink in dark mode; the canvas is always paper-coloured.
                canvas.overrideUserInterfaceStyle = .light
                canvas.contentSize = Viewport.canvasSize
                canvas.minimumZoomScale = Viewport.zoomRange.lowerBound
                canvas.maximumZoomScale = Viewport.zoomRange.upperBound
                canvas.bouncesZoom = true
                canvas.showsVerticalScrollIndicator = false
                canvas.showsHorizontalScrollIndicator = false
                canvas.scrollsToTop = false
                canvas.delegate = self
            }
            showDrawings()
            documentCanvas.onMoveToWindow = { [weak self] in
                guard let self else { return }
                // On the window, to see the Pencil land on things drawn above the canvas.
                // Touches on the panels and bars are told apart in `AppModel.pencilTouched`.
                if pencilDetector.view !== documentCanvas.window {
                    pencilDetector.view?.removeGestureRecognizer(pencilDetector)
                    documentCanvas.window?.addGestureRecognizer(pencilDetector)
                }
                watchForFlicks()
                // On the window too: the finger that rests may be on an element's own
                // handle, which is drawn above the canvas.
                if restingFingers.view !== documentCanvas.window {
                    restingFingers.view?.removeGestureRecognizer(restingFingers)
                    documentCanvas.window?.addGestureRecognizer(restingFingers)
                }
                // And the twist, whose fingers land on the selection's own targets.
                if twist.view !== documentCanvas.window {
                    twist.view?.removeGestureRecognizer(twist)
                    documentCanvas.window?.addGestureRecognizer(twist)
                }
                // The smallest window the bars and controls still fit in.
                documentCanvas.window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(width: 360, height: 480)
                refresh()
                takeFirstResponder()
            }
            documentCanvas.onLayout = { [weak self] in self?.arrangeViewportIfResized() }

            sketchCanvas.tool = PKInkingTool(.monoline, color: UIColor(Theme.ink), width: 2)
            sketchCanvas.drawingGestureRecognizer.addTarget(self, action: #selector(penMoved(_:)))
            sketchCanvas.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(penMoved(_:))))

            tap.addTarget(self, action: #selector(tapped(_:)))
            lasso.addTarget(self, action: #selector(lassoed(_:)))
            lasso.delegate = self
            lasso.isEnabled = false
            box.addTarget(self, action: #selector(boxDragged(_:)))
            box.minimumPressDuration = 0.4
            box.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pencilDetector.onPencil = { [weak self] touch in
                guard let self, let container = documentCanvas.superview else { return }
                model.pencilTouched(at: touch.location(in: container), elsewhere: Self.isInAnotherPresentation(touch.view, than: container))
            }
            model.restingFingers = { [weak self] in
                guard let self, let container = documentCanvas.superview else { return [] }
                return restingFingers.fingers(in: container)
            }
            restingFingers.onAllLifted = { [weak self] in self?.model.fingersLifted() }
            twist.addTarget(self, action: #selector(twisted(_:)))
            twist.canTurn = { [weak self] in
                guard let model = self?.model else { return false }
                return model.canTurnSelection && !model.isTurning
            }
            twist.isOnSelection = { [weak self] point, touched in
                // A finger on a sheet or a popover over the selection is on that, as the
                // Pencil is: it doesn't turn what is hidden under it.
                guard let self, let container = documentCanvas.superview,
                      !Self.isInAnotherPresentation(touched, than: container) else { return false }
                return model.isOnSelection(container.convert(point, from: twist.view))
            }
            // The canvases scroll and zoom only once it is plain that two fingers on the
            // selection aren't turning it. The twist fails at once for fingers anywhere else.
            for canvas in canvases {
                canvas.panGestureRecognizer.require(toFail: twist)
                canvas.pinchGestureRecognizer?.require(toFail: twist)
            }

            // Not while unit tests run inside the app: a test that picked up the eraser or
            // the lasso changed the pen the app opened with afterwards. Left unset, the palette
            // saves under a name of PencilKit's own, so it is told to save nothing.
            palette.stateAutosaveName = ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil ? "app.layer.palette" : nil
            palette.colorUserInterfaceStyle = .light
            // Every design opens with the Magic Pen in hand, whatever was used last.
            palette.selectedToolItemIdentifier = MagicPen.identifier
            palette.addObserver(documentCanvas)
            palette.addObserver(self)
            watchTyping()
        }

        func apply(_ tool: AppModel.Tool) {
            guard self.tool != tool else { return }
            self.tool = tool
            refresh()
            takeFirstResponder()
        }

        func setFingerDraws(_ draws: Bool) {
            guard fingerDraws != draws else { return }
            fingerDraws = draws
            refresh()
        }

        func setHidesPalette(_ hides: Bool) {
            guard hidesPalette != hides else { return }
            hidesPalette = hides
            refresh()
            // A panel's sheet came or went in the palette's place: as it goes, the palette
            // comes back.
            takeFirstResponder()
        }

        /// Shows or hides the palette for the current tool, and sends touches to the canvas
        /// that the palette's selected tool draws on. Outside draw mode the document canvas
        /// stays live, without drawing, so the canvas can still be scrolled and zoomed.
        func refresh() {
            let isDrawing = tool == .draw
            let isMagicPen = palette.selectedToolItemIdentifier == MagicPen.identifier
            // With the lasso in hand a loop selects things here, rather than strokes in PencilKit.
            let isLasso = isDrawing && palette.selectedToolItem is PKToolPickerLassoItem
            sketchCanvas.isUserInteractionEnabled = isDrawing && isMagicPen
            // Put away mid-stroke, the canvas may never say the stroke ended; until it is
            // up, the pen is thought down and nothing is read.
            if !sketchCanvas.isUserInteractionEnabled, isSketchPenDown {
                isSketchPenDown = false
                model.penUp()
            }
            // The Magic Pen's canvas is put away while it isn't in use and holds nothing, so
            // PencilKit doesn't keep tiling and scrolling a second canvas the size of the board.
            let showsSketch = (isDrawing && isMagicPen) || !sketchCanvas.drawing.strokes.isEmpty
            if sketchCanvas.isHidden == showsSketch {
                if showsSketch {
                    // Catch up with where the canvas went while it was away.
                    sketchCanvas.zoomScale = documentCanvas.zoomScale
                    sketchCanvas.contentOffset = documentCanvas.contentOffset
                }
                sketchCanvas.isHidden = !showsSketch
            }
            documentCanvas.isDrawingEnabled = isDrawing && !isLasso
            // Put away mid-use, the tool's changes so far are followed now.
            if !documentCanvas.isDrawingEnabled, isUsingDocumentTool {
                isUsingDocumentTool = false
                followInkNotYetFollowed()
            }
            // With the palette up, a finger that doesn't draw taps to select. The Pencil's
            // taps are its own: dots and strokes.
            tap.isEnabled = !isDrawing || !fingerDraws
            tap.allowedTouchTypes = isDrawing
                ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [UITouch.TouchType.direct, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
            // A finger that selects can also rest and drag out a box.
            box.isEnabled = tap.isEnabled
            if !(isDrawing && isMagicPen) { model.pen.location = nil }

            let showsPalette = isDrawing && !hidesPalette
            // Drawing, a finger draws only if it is meant to; otherwise it pans the canvas.
            let policy: PKCanvasViewDrawingPolicy = !isDrawing ? .default
                : fingerDraws && !UIPencilInteraction.prefersPencilOnlyDrawing ? .anyInput : .pencilOnly
            // The lasso is drawn with whatever draws: the Pencil, and a finger when fingers draw.
            lasso.isEnabled = isLasso
            lasso.allowedTouchTypes = (policy == .anyInput ? [UITouch.TouchType.direct, .pencil] : [.pencil]).map { NSNumber(value: $0.rawValue) }
            if model.isLassoInHand != isLasso { model.isLassoInHand = isLasso }
            for canvas in canvases {
                if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
                palette.setVisible(showsPalette, forFirstResponder: canvas)
            }
            watchForFlicks()
        }

        // MARK: Typing

        /// The fields and text views in the canvas's window that began to be typed in, and may
        /// still have the keyboard.
        private var typing: [WeakResponder] = []
        private var typingObservers: [NSObjectProtocol] = []

        private struct WeakResponder {
            weak var responder: UIResponder?
        }

        /// Follows typing in the canvas's window, in a text field or a text view, from the
        /// panels, the popovers or the board's menu. While anything has the keyboard the
        /// palette is away, since it shows only for the canvas as first responder; when typing
        /// ends, it comes back (see `typingEnded`).
        private func watchTyping() {
            let began: [Notification.Name] = [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification]
            let ended: [Notification.Name] = [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification]
            typingObservers = began.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                    // Posted by UIKit on the main thread, as the field takes the keyboard.
                    let field = note.object as? UIView
                    MainActor.assumeIsolated { self?.typingBegan(in: field) }
                }
            } + ended.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.typingEnded() }
                }
            }
        }

        private func typingBegan(in field: UIView?) {
            guard let field, field.window != nil, field.window === documentCanvas.window else { return }
            typing.removeAll { $0.responder == nil || $0.responder === field }
            typing.append(WeakResponder(responder: field))
        }

        /// Typing ended in a field. Once the keyboard has settled (focus moving to another
        /// field ends typing in the first before it begins in the next), and if nothing in the
        /// window is still typed in, the canvas takes first responder back in Draw, where the
        /// palette is to show. A field still being typed in keeps the keyboard.
        private func typingEnded() {
            guard !typing.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                typing.removeAll { $0.responder?.isFirstResponder != true }
                guard typing.isEmpty, tool == .draw, !hidesPalette else { return }
                takeFirstResponder()
            }
        }

        /// Whether a field in the canvas's window has the keyboard.
        private var isTyping: Bool {
            typing.contains { $0.responder?.isFirstResponder == true }
        }

        private func stopWatchingTyping() {
            for observer in typingObservers { NotificationCenter.default.removeObserver(observer) }
            typingObservers = []
            typing = []
        }

        /// Makes the canvas first responder if neither canvas is: the palette shows only for
        /// it, and outside draw mode the system's undo and redo gestures reach the document's
        /// undo history through it. Only as the tool, the palette or the window changes, and
        /// as typing ends in Draw, and never while a field has the keyboard. A sketch
        /// converted, dissolving or cleared in the background also refreshes the canvases, and
        /// took the keyboard from a field being typed in.
        private func takeFirstResponder() {
            // Never from a field still being typed in: a tool changed by adding from the
            // library, a call starting or the window changing width took the keyboard mid-word.
            // In Draw the palette comes back as typing ends.
            guard !isTyping else { return }
            if documentCanvas.window != nil, !canvases.contains(where: \.isFirstResponder) {
                documentCanvas.becomeFirstResponder()
            }
        }

        /// Stops the canvas being panned and zoomed by touch, or lets it move again.
        func setLocked(_ isLocked: Bool) {
            for canvas in canvases where canvas.isScrollEnabled == isLocked {
                canvas.isScrollEnabled = !isLocked
                canvas.pinchGestureRecognizer?.isEnabled = !isLocked
            }
        }

        /// Whether a touch is on the pencil bar of a narrow window. iPadOS fixes that bar
        /// across the bottom of the window; a wider window's palette floats and looks
        /// after itself, so there is nothing there to flick away.
        private func isOnPencilBar(_ touch: UITouch) -> Bool {
            guard tool == .draw, !hidesPalette, model.isCompactSizeClass, palette.isVisible, let window = documentCanvas.window else { return false }
            // Only where the bar says it is. With the bar down, as it is while a name is
            // being typed, the keyboard is in the same place and is swiped on too.
            let bar = palette.frameObscured(in: window)
            return !bar.isNull && !bar.isEmpty && bar.contains(touch.location(in: window))
        }

        /// Puts a flick recogniser on each window of the scene that hasn't one. The bar is
        /// not in the app's own window, and nothing says which window it is in, so each is
        /// watched for a touch that starts where the bar is.
        private func watchForFlicks() {
            let windows = documentCanvas.window?.windowScene?.windows ?? []
            paletteFlicks.removeAll { flick in
                if let window = flick.view, windows.contains(where: { $0 === window }) { return false }
                flick.view?.removeGestureRecognizer(flick)
                return true
            }
            for window in windows where !paletteFlicks.contains(where: { $0.view === window }) {
                let flick = PaletteFlick()
                flick.isOnBar = { [weak self] in self?.isOnPencilBar($0) ?? false }
                flick.onFlick = { [weak self] in self?.model.pencilBarFlickedAway() }
                window.addGestureRecognizer(flick)
                paletteFlicks.append(flick)
            }
        }

        func hidePalette() {
            zoomAnimation?.stop()
            palette.removeObserver(self)
            palette.removeObserver(documentCanvas)
            pencilDetector.view?.removeGestureRecognizer(pencilDetector)
            for flick in paletteFlicks { flick.view?.removeGestureRecognizer(flick) }
            paletteFlicks = []
            restingFingers.view?.removeGestureRecognizer(restingFingers)
            twist.view?.removeGestureRecognizer(twist)
            stopWatchingTyping()
            for canvas in canvases {
                palette.setVisible(false, forFirstResponder: canvas)
            }
        }

        // MARK: Scrolling and zooming

        private var viewSize: CGSize { documentCanvas.bounds.size }

        /// The window this canvas is showing in, as the system knows it.
        var windowScene: UIWindowScene? { documentCanvas.window?.windowScene }

        /// Arranges the viewport for the view's size whenever that changes. A new design
        /// opens in the middle of the canvas; one with content opens showing all of it.
        /// The view passes through other sizes on its way in, so the design is framed
        /// again for each until the canvas is first used. After that, a change of size,
        /// such as turning the iPad, keeps the same spot in the middle of the view.
        private func arrangeViewportIfResized() {
            let size = viewSize
            guard size.width > 0, size.height > 0, size != arrangedViewSize else { return }
            let previous = arrangedViewSize
            arrangedViewSize = size
            // A glide under way was headed for a place worked out for the old size.
            zoomAnimation?.stop()
            zoomAnimation = nil
            if !isAtOpeningViewport {
                let middle = model.viewport.canvasPoint(for: CGPoint(x: previous.width / 2, y: previous.height / 2))
                show(.centered(on: middle, scale: model.viewport.scale, in: size))
            } else if let content = contentBounds {
                show(.fitting(content, within: clearArea))
            } else {
                let middle = CGPoint(x: Viewport.canvasSize.width / 2, y: Viewport.canvasSize.height / 2)
                show(.centered(on: middle, scale: 1, in: size))
            }
        }

        /// The bar across the top grew or shrank, as it does when the window narrows. A
        /// design still framed as it opened is framed again in the room that leaves.
        func setTopInset(_ inset: CGFloat) {
            guard inset != topInset else { return }
            topInset = inset
            guard isAtOpeningViewport, viewSize.width > 0, viewSize.height > 0, let content = contentBounds else { return }
            show(.fitting(content, within: clearArea))
        }

        /// The part of the view between the bar across the top and the controls along the bottom.
        private var clearArea: CGRect {
            let size = viewSize
            let top = min(topInset, size.height * 0.4)
            let bottom = min(92, size.height * 0.2)
            return CGRect(x: 0, y: top, width: size.width, height: size.height - top - bottom)
        }

        /// Everything on the canvas: the design and the ink.
        private var contentBounds: CGRect? {
            let ink = documentCanvas.drawing.strokes.isEmpty ? nil : documentCanvas.drawing.bounds
            guard let design = model.store.contentBounds else { return ink }
            return ink.map(design.union) ?? design
        }

        /// Jumps straight to a viewport.
        private func show(_ viewport: Viewport) {
            isShowing = true
            defer { isShowing = false }
            documentCanvas.zoomScale = viewport.scale
            documentCanvas.contentOffset = viewport.offset
            model.settledScale = documentCanvas.zoomScale
            viewportChanged(by: documentCanvas)
        }

        /// Glides to a zoom, keeping the middle of the view where it is.
        func zoom(to scale: CGFloat) {
            let center = model.viewport.canvasPoint(for: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
            let clamped = min(max(scale, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
            animate(to: .centered(on: center, scale: clamped, in: viewSize))
        }

        /// Glides to centre a canvas point in the view at a zoom.
        func glide(toCenter center: CGPoint, scale: CGFloat) {
            let clamped = min(max(scale, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
            animate(to: .centered(on: center, scale: clamped, in: viewSize))
        }

        /// Glides to show one part of the canvas whole, zoomed in no further than actual size.
        func glide(toShow area: CGRect) {
            animate(to: .fitting(area, within: clearArea))
        }

        /// Glides to show everything on the canvas, or its middle if there is nothing yet.
        func zoomToFit() {
            if let content = contentBounds {
                animate(to: .fitting(content, within: clearArea))
            } else {
                let middle = CGPoint(x: Viewport.canvasSize.width / 2, y: Viewport.canvasSize.height / 2)
                animate(to: .centered(on: middle, scale: 1, in: viewSize))
            }
        }

        private func animate(to target: Viewport, isByUser: Bool = true) {
            if isByUser { isAtOpeningViewport = false }
            zoomAnimation?.stop()
            zoomAnimation = ZoomAnimation(from: model.viewport, to: target, viewSize: viewSize) { [weak self] viewport, isDone in
                guard let self else { return }
                if isDone {
                    show(viewport)
                    zoomAnimation = nil
                } else {
                    documentCanvas.zoomScale = viewport.scale
                    documentCanvas.contentOffset = viewport.offset
                    viewportChanged(by: documentCanvas)
                }
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isAtOpeningViewport = false
            // A finger takes the canvas from a glide under way, which would otherwise end by
            // jumping to where it was going. The zoom it stopped at is settled, as the glide's
            // last frame would have: screens get their shadows back and text is drawn sharp
            // for it. A pinch settles it as the pinch ends.
            if isGliding {
                stopGliding()
                model.settledScale = documentCanvas.zoomScale
            }
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            if !isShowing { isAtOpeningViewport = false }
            if let pinch = scrollView.pinchGestureRecognizer, pinch.state == .began || pinch.state == .changed { stopGliding() }
        }

        /// Whether a glide is under way.
        var isGliding: Bool { zoomAnimation != nil }

        private func stopGliding() {
            zoomAnimation?.stop()
            zoomAnimation = nil
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            viewportChanged(by: scrollView)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            viewportChanged(by: scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            for canvas in canvases {
                canvas.minimumZoomScale = Viewport.zoomRange.lowerBound
                canvas.maximumZoomScale = Viewport.zoomRange.upperBound
            }
            model.settledScale = scale
        }

        /// One canvas moved: bring the other to the same place and publish the viewport.
        private func viewportChanged(by leader: UIScrollView) {
            guard !isFollowing else { return }
            isFollowing = true
            defer { isFollowing = false }
            // A hidden canvas doesn't follow: it catches up when it is shown.
            for follower in canvases where follower !== leader && !follower.isHidden {
                if follower.zoomScale != leader.zoomScale {
                    // The leader stretches past the limits while it rubber-bands; let the
                    // follower stretch with it. The limits are restored when zooming ends.
                    follower.minimumZoomScale = min(Viewport.zoomRange.lowerBound, leader.zoomScale)
                    follower.maximumZoomScale = max(Viewport.zoomRange.upperBound, leader.zoomScale)
                    follower.zoomScale = leader.zoomScale
                }
                if follower.contentOffset != leader.contentOffset {
                    follower.contentOffset = leader.contentOffset
                }
            }
            let viewport = Viewport(offset: leader.contentOffset, scale: leader.zoomScale)
            if model.viewport != viewport { model.viewport = viewport }
        }

        // MARK: Palette and canvas events

        /// The bar's window can be made only as the bar first comes up.
        func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
            watchForFlicks()
        }

        func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
            refresh()
            takeFirstResponder()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if canvasView === sketchCanvas {
                model.sketchChanged(sketch())
                return
            }
            inkAreas = nil
            guard !isShowingDrawings else { return }
            // While a tool is in use, its changes are followed once it is put down: the
            // eraser changes the strokes many times in one rub, and each change wrote the
            // whole drawing out again. PencilKit always says when a tool use ends.
            // The first change of a use is followed at once, which puts the use's step in
            // the history: undo pressed mid-use then takes back the use so far, as it did when
            // every change was followed, and not the step before.
            if isUsingDocumentTool, hasFollowedThisUse {
                hasInkToFollow = true
                return
            }
            if isUsingDocumentTool { hasFollowedThisUse = true }
            followInk()
        }

        /// Whether the tool in use has had a change followed yet.
        private var hasFollowedThisUse = false

        /// Whether a pen or the eraser is in use on the document canvas, and whether it has
        /// changed the strokes yet.
        private var isUsingDocumentTool = false
        private var hasInkToFollow = false

        /// Follows the ink a tool in use has changed, now rather than when it is put down.
        /// Not while the design is being put back by undo or redo, which drops it as it begins
        /// (see `watchHistory`).
        private func followInkNotYetFollowed() {
            guard hasInkToFollow else { return }
            if let history = documentCanvas.documentUndoManager, history.isUndoing || history.isRedoing { return }
            hasInkToFollow = false
            followInk()
        }

        /// Puts ink a tool in use has changed into the design now: the design is closing, or
        /// the app is leaving the screen, and may not be back to hear the tool put down.
        func flushPendingInk() {
            followInkNotYetFollowed()
        }

        /// The document's history, watched so that the ink not yet followed goes into the
        /// use's step as an undo or redo begins: undo then takes back the whole use so far,
        /// and redo puts all of it back. Dropped instead, redo lost the rubbing out.
        private var watchedHistory: UndoManager?
        /// The step of the tool's use under way: see `DesignStore.Edit`.
        private var toolEdit: DesignStore.Edit?
        private var historyObservers: [NSObjectProtocol] = []

        func watchHistory(_ history: UndoManager?) {
            guard history !== watchedHistory else { return }
            stopWatchingHistory()
            watchedHistory = history
            guard let history else { return }
            historyObservers = [Notification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange].map { name in
                NotificationCenter.default.addObserver(forName: name, object: history, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.followBeforeHistoryMoves() }
                }
            }
        }

        /// Undo or redo is about to begin. The history already says it is undoing by then, so
        /// `followInk` would skip the ink. It can still join the use's step, which is in the
        /// history since the use's first change and registers nothing more: the canvas still
        /// holds what the tool did, not yet what undo puts back. Without that step (an edit
        /// not open, or no change followed yet), registering now would be taken for undo's
        /// own, so the ink is dropped, as part of what undo takes back.
        private func followBeforeHistoryMoves() {
            guard hasInkToFollow else { return }
            hasInkToFollow = false
            guard hasFollowedThisUse, toolEdit?.isInHistory == true else { return }
            followInk(evenWhileTheHistoryMoves: true)
        }

        func stopWatchingHistory() {
            for observer in historyObservers { NotificationCenter.default.removeObserver(observer) }
            historyObservers = []
            watchedHistory = nil
        }

        // MARK: The design's drawings

        /// Makes the document canvas show the design's drawings, when it doesn't already:
        /// when a design opens, and after a drawing is moved, resized, locked, hidden or
        /// deleted, or put back by undo.
        func showDrawings() {
            // The design changed while a tool is in use (a spoken command, say): what the tool
            // has done so far is followed first, not drawn over.
            followInkNotYetFollowed()
            guard let strokes = drawings.strokes(showing: model.store.content, on: documentCanvas.drawing.strokes) else { return }
            isShowingDrawings = true
            defer { isShowingDrawings = false }
            documentCanvas.drawing = PKDrawing(strokes: strokes)
            inkAreas = nil
        }

        /// The strokes on the document canvas changed, drawn, erased or moved with
        /// PencilKit's tools or put there from here: the design's drawings change to
        /// match, which is the step that undo takes back.
        private func followInk(evenWhileTheHistoryMoves: Bool = false) {
            // While the design is being put back by undo or redo it is the one to follow.
            if !evenWhileTheHistoryMoves, let history = documentCanvas.documentUndoManager, history.isUndoing || history.isRedoing { return }
            let reach = InkGeometry.reach / max(model.viewport.scale, 0.01)
            let changes = drawings.changes(for: documentCanvas.drawing.strokes, in: model.store.content, reach: reach)
            // Part of the tool's use under way, if it is, and of nothing else under way.
            model.store.act(for: toolEdit) { model.inkChanged(changes) }
            // PencilKit's own record of the change is not the one that is kept.
            documentCanvas.inkUndoManager.removeAllActions()
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isAtOpeningViewport = false
            if canvasView === sketchCanvas {
                isSketchPenDown = true
                model.penDown()
            } else {
                // One use of a tool is one undo step, however many times it changes the
                // strokes on the way, as rubbing out does.
                isUsingDocumentTool = true
                hasFollowedThisUse = false
                if let toolEdit { model.store.endEdit(toolEdit) }
                toolEdit = model.store.beginEdit()
            }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            if canvasView === sketchCanvas {
                isSketchPenDown = false
                model.penUp()
            } else {
                isUsingDocumentTool = false
                followInkNotYetFollowed()
                if let toolEdit { model.store.endEdit(toolEdit) }
                toolEdit = nil
            }
        }

        /// Follows the Magic Pen while it draws or hovers, for the cursor.
        @objc func penMoved(_ gesture: UIGestureRecognizer) {
            let isTracking = gesture.state == .began || gesture.state == .changed
            model.pen.location = isTracking ? gesture.location(in: sketchCanvas.superview) : nil
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            isAtOpeningViewport = false
            model.canvasTapped(at: recognizer.location(in: recognizer.view))
        }

        /// Two fingers on the selection turned before they pinched: it turns with them, from
        /// the angle it had as they landed, until one lifts. With the canvas locked too, which
        /// only stops it scrolling and zooming.
        @objc func twisted(_ recognizer: TwistGestureRecognizer) {
            switch recognizer.state {
            case .began:
                model.beginTwist()
                model.twist(by: recognizer.turn)
            case .changed:
                model.twist(by: recognizer.turn)
            default:
                model.endTwist()
            }
        }

        // MARK: Drawing round things

        /// The lasso drew some more of its loop, finished it, or only tapped, which picks
        /// what is under it as a tap of PencilKit's lasso picks a stroke.
        @objc func lassoed(_ recognizer: LassoGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                isAtOpeningViewport = false
                model.lassoDrawn(recognizer.points)
            case .ended:
                if recognizer.isTap {
                    if let point = recognizer.points.first { model.canvasTapped(at: point) }
                } else {
                    model.lassoDrawn(recognizer.points)
                    model.sweepEnded()
                }
            default:
                model.sweepCancelled()
            }
        }

        /// A finger rested on the canvas, and now drags out a box. Until it has moved
        /// there is no box, and a finger that rests and lifts leaves things as they were.
        @objc func boxDragged(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                isAtOpeningViewport = false
                boxStart = point
            case .changed:
                guard let boxStart else { return }
                if model.sweep != nil || hypot(point.x - boxStart.x, point.y - boxStart.y) > 8 {
                    model.boxDragged(from: boxStart, to: point)
                }
            default:
                boxStart = nil
                model.sweepEnded()
            }
        }

        /// The canvases scroll only once it is plain that the lasso isn't being drawn: a
        /// second finger, a pinch or a two-finger scroll, makes it give way.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === lasso && canvases.contains { other === $0.panGestureRecognizer || other === $0.pinchGestureRecognizer }
        }

        /// Whether a view the Pencil touched is in a presentation of its own over the canvas,
        /// such as a panel's sheet, a popover or an alert, rather than on the canvas or the
        /// controls laid over it. The detector is on the window, which they share; what is
        /// presented sits in its own branch under the window, apart from the canvas's.
        static func isInAnotherPresentation(_ touched: UIView?, than canvas: UIView) -> Bool {
            guard let touched, let window = canvas.window, touched.window === window else { return false }
            func branch(of view: UIView) -> UIView? {
                var view = view
                while let parent = view.superview, parent !== window { view = parent }
                return view.superview === window ? view : nil
            }
            guard let canvasBranch = branch(of: canvas) else { return false }
            return branch(of: touched) !== canvasBranch
        }

        // MARK: Picking and changing ink

        /// The drawing with ink under a canvas point, among those on the document
        /// canvas. Nil if there is no ink at the point.
        func drawing(at point: CGPoint, tolerance: CGFloat) -> DesignElement.ID? {
            let areas = inkAreas ?? documentCanvas.drawing.strokes.map { ($0, $0.renderBounds) }
            inkAreas = areas
            let hit = areas.last { stroke, area in
                guard area.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
                return stroke.path.interpolatedPoints(by: .distance(4)).contains { sample in
                    let location = sample.location.applying(stroke.transform)
                    return hypot(location.x - point.x, location.y - point.y) <= tolerance + max(sample.size.width, sample.size.height) / 2
                }
            }
            return hit.flatMap { drawings.drawing(owning: $0.stroke.key) }
        }

        /// The drawing that strokes with these keys ended up in, when they share one.
        func drawing(owning keys: Set<Double>) -> DesignElement.ID? {
            let owners = Set(keys.compactMap { drawings.drawing(owning: $0) })
            return owners.count == 1 ? owners.first : nil
        }

        func deleteInk(_ keys: Set<Double>) {
            var drawing = documentCanvas.drawing
            let removed = drawing.strokes.filter { keys.contains(Self.key(for: $0)) }
            guard !removed.isEmpty else { return }
            drawing.strokes.removeAll { keys.contains(Self.key(for: $0)) }
            setDocumentDrawing(drawing)
        }

        /// Sets the strokes on the document canvas from here. The design's drawings
        /// change to match, and that change is what undo takes back.
        private func setDocumentDrawing(_ drawing: PKDrawing) {
            // PencilKit tells its delegate of a drawing set in code too, which would follow
            // the ink once there and again here.
            isShowingDrawings = true
            documentCanvas.drawing = drawing
            isShowingDrawings = false
            inkAreas = nil
            followInk()
        }

        // MARK: Magic Pen sketches

        /// Removes sketch strokes that have been converted or rejected, leaving any drawn since.
        func removeSketch(_ keys: Set<Double>) {
            sketchCanvas.drawing.strokes.removeAll { keys.contains(Self.key(for: $0)) }
            model.sketchChanged(sketch())
            refresh()
        }

        func clearSketch() {
            sketchCanvas.drawing = PKDrawing()
            sketchStrokeCache.removeAll()
            model.sketchChanged([])
            refresh()
        }

        /// Adds sketch strokes, in canvas points, as if the Magic Pen had drawn them: for
        /// the scripted demo, and for Siri, Shortcuts and models drawing with the Magic Pen.
        /// Returns the new strokes' keys.
        @discardableResult
        func appendSketch(_ strokes: [[CGPoint]]) -> Set<Double> {
            let added = makeStrokes(strokes, ink: PKInk(.monoline, color: UIColor(Theme.ink)), width: 2)
            guard !added.isEmpty else { return [] }
            sketchCanvas.drawing.strokes.append(contentsOf: added)
            refresh()
            model.sketchChanged(sketch())
            return Set(added.map(Self.key(for:)))
        }

        /// Adds ordinary ink, in canvas points, as if drawn with one of PencilKit's pens.
        /// It undoes as one step. Returns the new strokes' keys.
        @discardableResult
        func appendInk(_ strokes: [[CGPoint]], ink: PKInk, width: CGFloat) -> Set<Double> {
            let added = makeStrokes(strokes, ink: ink, width: width)
            guard !added.isEmpty else { return [] }
            var drawing = documentCanvas.drawing
            drawing.strokes.append(contentsOf: added)
            setDocumentDrawing(drawing)
            return Set(added.map(Self.key(for:)))
        }

        /// The keys of the ordinary ink strokes touching an area of the canvas, or of all of
        /// them when `area` is nil.
        func inkKeys(touching area: CGRect?) -> Set<Double> {
            let strokes = documentCanvas.drawing.strokes.filter { stroke in
                guard let area else { return true }
                return stroke.renderBounds.intersects(area)
            }
            return Set(strokes.map(Self.key(for:)))
        }

        /// How many ordinary ink strokes there are, and the area they cover.
        var inkSummary: (count: Int, bounds: CGRect?) {
            let strokes = documentCanvas.drawing.strokes
            return (strokes.count, strokes.isEmpty ? nil : documentCanvas.drawing.bounds)
        }

        /// PencilKit strokes through points in canvas points, drawn at an even pace.
        private func makeStrokes(_ strokes: [[CGPoint]], ink: PKInk, width: CGFloat) -> [PKStroke] {
            strokes.filter { !$0.isEmpty }.map { points in
                let controlPoints = points.enumerated().map { offset, point in
                    PKStrokePoint(
                        location: point, timeOffset: Double(offset) * 0.008, size: CGSize(width: width, height: width),
                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                    )
                }
                return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: InkGeometry.newStrokeDate()))
            }
        }

        /// The Magic Pen's strokes, as points for reading. While one stroke is still being
        /// drawn, this is asked for again on every touch event; the strokes already
        /// finished haven't changed, so their points come from the cache rather than being
        /// walked again.
        private func sketch() -> [SketchStroke] {
            let result = sketchCanvas.drawing.strokes.map { stroke -> SketchStroke in
                let key = Self.key(for: stroke)
                let pointCount = stroke.path.count
                if let cached = sketchStrokeCache[key], cached.pointCount == pointCount { return cached.result }
                let sketchStroke = SketchStroke(
                    key: key,
                    points: stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
                )
                sketchStrokeCache[key] = (pointCount, sketchStroke)
                return sketchStroke
            }
            // Strokes that are gone, converted or erased, don't linger in the cache.
            let keys = Set(sketchCanvas.drawing.strokes.map(Self.key(for:)))
            if sketchStrokeCache.count != keys.count { sketchStrokeCache = sketchStrokeCache.filter { keys.contains($0.key) } }
            return result
        }

        private static func key(for stroke: PKStroke) -> Double {
            stroke.key
        }
    }
}

/// Steps the viewport from one place to another on the display's own clock, so that every
/// frame of the glide is seen by everything that follows the viewport.
@MainActor
private final class ZoomAnimation: NSObject {
    private let start: Viewport
    private let end: Viewport
    private let viewSize: CGSize
    private let step: (Viewport, _ isDone: Bool) -> Void
    private let began = CACurrentMediaTime()
    private let duration = 0.3
    private var link: CADisplayLink?

    init(from start: Viewport, to end: Viewport, viewSize: CGSize, step: @escaping (Viewport, Bool) -> Void) {
        self.start = start
        self.end = end
        self.viewSize = viewSize
        self.step = step
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let progress = min((CACurrentMediaTime() - began) / duration, 1)
        guard progress < 1 else {
            stop()
            step(end, true)
            return
        }
        // Ease in and out; zoom multiplies rather than adds, so it reads as steady.
        let eased = progress * progress * (3 - 2 * progress)
        let scale = start.scale * pow(end.scale / start.scale, eased)
        let middle = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let from = start.canvasPoint(for: middle)
        let to = end.canvasPoint(for: middle)
        let center = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
        step(.centered(on: center, scale: scale, in: viewSize), false)
    }
}

/// Notices a flick that begins on the pencil bar of a narrow window, and says so. iPadOS
/// gives that bar no flick of its own, and no word when it is touched, so one of these
/// watches from each window of the scene: the bar is in a system window, not the app's.
/// It never recognizes anything, so nothing the bar does is disturbed:
/// tapping a pen, dragging through its tools and choosing a colour all go on as they were.
final class PaletteFlick: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// Whether a touch is on the bar. Never, while the bar isn't up.
    var isOnBar: (UITouch) -> Bool = { _ in false }
    var onFlick: () -> Void = {}
    private var began: (point: CGPoint, time: TimeInterval)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    /// Whether a movement is a flick: sideways by 50 points or more and more sideways
    /// than not, or downward, off the bottom of the window, by 40 points or more.
    static func isFlick(_ translation: CGSize) -> Bool {
        let (sideways, down) = (abs(translation.width), translation.height)
        return (sideways >= 50 && sideways > abs(down)) || (down >= 40 && down > sideways)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Only a touch that starts on the bar: a stroke that wanders over it isn't one.
        guard began == nil, let touch = touches.first, let view, isOnBar(touch) else {
            if began == nil { state = .failed }
            return
        }
        began = (touch.location(in: view), touch.timestamp)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        defer {
            began = nil
            state = .failed
        }
        guard let began, let touch = touches.first, let view else { return }
        let ended = touch.location(in: view)
        // Quick, as a flick is: a slow drag along the bar is looking through its tools.
        guard touch.timestamp - began.time < 0.6 else { return }
        if Self.isFlick(CGSize(width: ended.x - began.point.x, height: ended.y - began.point.y)) { onFlick() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        began = nil
        state = .failed
    }

    override func reset() {
        began = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// The loop of the lasso: one touch, followed from where it lands to where it lifts. A
/// touch that lifts without having moved is a tap. A second finger landing before the
/// loop is under way means a pinch or a two-finger scroll, and the lasso gives way to it.
final class LassoGestureRecognizer: UIGestureRecognizer {
    /// The loop so far, in the view's points.
    private(set) var points: [CGPoint] = []
    /// Whether the touch lifted where it landed.
    private(set) var isTap = false
    private weak var touch: UITouch?
    /// How far a touch moves before it is drawing rather than tapping.
    private let slop: CGFloat = 6

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let first = touches.first else {
            // Under way, the loop carries on and the extra finger is left out of it.
            if state == .possible {
                state = .failed
            } else {
                for extra in touches where extra !== touch { ignore(extra, for: event) }
            }
            return
        }
        touch = first
        isTap = false
        points = [first.location(in: view)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch), let start = points.first else { return }
        if state == .possible {
            let now = touch.location(in: view)
            guard hypot(now.x - start.x, now.y - start.y) > slop else { return }
            points.append(now)
            state = .began
        } else {
            // Every point the touch passed through since the last event, for a smooth loop.
            let passed = event.coalescedTouches(for: touch) ?? [touch]
            points.append(contentsOf: passed.map { $0.location(in: view) })
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        if state == .possible {
            isTap = true
            state = .ended
        } else {
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        touch = nil
        points = []
    }
}

/// A gesture recognizer that never recognizes anything. It only keeps track of the
/// fingers that are down and haven't strayed from where they landed, so that a tap can
/// tell whether another finger is resting on the canvas: holding one thing and tapping
/// others selects them together.
final class RestingFingerDetector: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// Called when the last finger has lifted.
    var onAllLifted: (() -> Void)?

    private struct Finger {
        weak var touch: UITouch?
        var start: CGPoint
        var hasStrayed = false
    }

    private var down: [ObjectIdentifier: Finger] = [:]
    /// How far a finger can drift and still be resting. Further, it is dragging or scrolling.
    private let drift: CGFloat = 14

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    /// Where fingers are resting, in a view's points. A finger that has just lifted, the
    /// one whose tap is being handled for instance, isn't resting.
    func fingers(in view: UIView) -> [CGPoint] {
        down.values.compactMap { finger in
            guard !finger.hasStrayed, let touch = finger.touch else { return nil }
            switch touch.phase {
            case .began, .moved, .stationary: return touch.location(in: view)
            default: return nil
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            down[ObjectIdentifier(touch)] = Finger(touch: touch, start: touch.location(in: view))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            guard let finger = down[ObjectIdentifier(touch)], !finger.hasStrayed else { continue }
            let now = touch.location(in: view)
            if hypot(now.x - finger.start.x, now.y - finger.start.y) > drift {
                down[ObjectIdentifier(touch)]?.hasStrayed = true
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lifted(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lifted(touches)
    }

    private func lifted(_ touches: Set<UITouch>) {
        for touch in touches { down[ObjectIdentifier(touch)] = nil }
        guard down.isEmpty else { return }
        onAllLifted?()
        // Nothing was ever going to be recognized: say so, and be ready for the next touch.
        state = .failed
    }

    override func reset() {
        super.reset()
        down.removeAll()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// A gesture recognizer that never recognizes anything. It only notices that an Apple
/// Pencil touched down, and gets out of the way of every other gesture.
final class PencilDetector: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onPencil: ((UITouch) -> Void)?

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let pencil = touches.first(where: { $0.type == .pencil }) { onPencil?(pencil) }
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
