import PencilKit
import SwiftUI

/// Holds the document's ink. Its strokes go on the document's undo history, which is what
/// makes them undoable alongside design changes and tells the system to save.
final class DocumentCanvasView: PKCanvasView {
    var documentUndoManager: UndoManager?
    var onMoveToWindow: (() -> Void)?
    var onLayout: (() -> Void)?

    override var undoManager: UndoManager? {
        documentUndoManager ?? super.undoManager
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
/// Two PencilKit canvases fill the view. The document canvas takes every palette tool
/// except the Magic Pen; the sketch canvas sits above it and takes the Magic Pen. Each is
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
        model.ink = context.coordinator
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.documentCanvas.documentUndoManager = undoManager
        context.coordinator.apply(tool)
        context.coordinator.setLocked(isLocked)
        context.coordinator.setHidesPalette(hidesPalette)
        context.coordinator.setFingerDraws(fingerDraws)
        // Off when it has nothing to do, so it doesn't take part in every touch in the window.
        context.coordinator.pencilDetector.isEnabled = watchesPencil
        context.coordinator.setTopInset(topInset)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.hidePalette()
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, PKToolPickerObserver {
        let model: AppModel
        let documentCanvas = DocumentCanvasView()
        let sketchCanvas = SketchCanvasView()
        /// Taps on the canvas outside draw mode: selecting, deselecting, leaving comments.
        let tap = UITapGestureRecognizer()
        /// Notices Apple Pencil touching the canvas, without taking part in anything.
        let pencilDetector = PencilDetector()
        private var fingerDraws = true
        private let palette = PKToolPicker(toolItems: MagicPen.paletteItems())
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
            documentCanvas.drawing = model.document.current.drawing
            documentCanvas.onMoveToWindow = { [weak self] in
                guard let self else { return }
                // On the window, to see the Pencil land on things drawn above the canvas.
                // Touches on the panels and bars are told apart in `AppModel.pencilTouched`.
                if pencilDetector.view !== documentCanvas.window {
                    pencilDetector.view?.removeGestureRecognizer(pencilDetector)
                    documentCanvas.window?.addGestureRecognizer(pencilDetector)
                }
                // The smallest window the bars and controls still fit in.
                documentCanvas.window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(width: 360, height: 480)
                refresh()
            }
            documentCanvas.onLayout = { [weak self] in self?.arrangeViewportIfResized() }

            sketchCanvas.tool = PKInkingTool(.monoline, color: UIColor(Theme.ink), width: 2)
            sketchCanvas.drawingGestureRecognizer.addTarget(self, action: #selector(penMoved(_:)))
            sketchCanvas.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(penMoved(_:))))

            tap.addTarget(self, action: #selector(tapped(_:)))
            pencilDetector.onPencil = { [weak self] touch in
                guard let self, let container = documentCanvas.superview else { return }
                model.pencilTouched(at: touch.location(in: container))
            }

            palette.stateAutosaveName = "app.layer.palette"
            palette.colorUserInterfaceStyle = .light
            // Every design opens with the Magic Pen in hand, whatever was used last.
            palette.selectedToolItemIdentifier = MagicPen.identifier
            palette.addObserver(documentCanvas)
            palette.addObserver(self)
        }

        func apply(_ tool: AppModel.Tool) {
            guard self.tool != tool else { return }
            self.tool = tool
            refresh()
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
        }

        /// Shows or hides the palette for the current tool, and sends touches to the canvas
        /// that the palette's selected tool draws on. Outside draw mode the document canvas
        /// stays live, without drawing, so the canvas can still be scrolled and zoomed.
        func refresh() {
            let isDrawing = tool == .draw
            let isMagicPen = palette.selectedToolItemIdentifier == MagicPen.identifier
            sketchCanvas.isUserInteractionEnabled = isDrawing && isMagicPen
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
            documentCanvas.isDrawingEnabled = isDrawing
            // With the palette up, a finger that doesn't draw taps to select. The Pencil's
            // taps are its own: dots and strokes.
            tap.isEnabled = !isDrawing || !fingerDraws
            tap.allowedTouchTypes = isDrawing
                ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [UITouch.TouchType.direct, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
            if !(isDrawing && isMagicPen) { model.pen.location = nil }

            let showsPalette = isDrawing && !hidesPalette
            // A canvas whose palette is out of sight takes only the Pencil. A palette
            // that is tucked away is still in use, so fingers go on drawing then, unless
            // the Pencil settings say that only the Pencil draws.
            // Drawing, a finger draws only if it is meant to; otherwise it pans the canvas.
            let isTuckedAway = isDrawing && hidesPalette
            let policy: PKCanvasViewDrawingPolicy = !isDrawing ? .default
                : fingerDraws && !UIPencilInteraction.prefersPencilOnlyDrawing ? .anyInput : .pencilOnly
            _ = isTuckedAway
            for canvas in canvases {
                if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
                palette.setVisible(showsPalette, forFirstResponder: canvas)
            }
            // The canvas stays first responder outside draw mode too, so the system's
            // undo and redo gestures keep reaching the document's undo history.
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

        func hidePalette() {
            zoomAnimation?.stop()
            palette.removeObserver(self)
            palette.removeObserver(documentCanvas)
            pencilDetector.view?.removeGestureRecognizer(pencilDetector)
            for canvas in canvases {
                palette.setVisible(false, forFirstResponder: canvas)
            }
        }

        // MARK: Scrolling and zooming

        private var viewSize: CGSize { documentCanvas.bounds.size }

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
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            if !isShowing { isAtOpeningViewport = false }
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

        func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
            refresh()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if canvasView === sketchCanvas {
                model.sketchChanged(sketch())
            } else {
                model.drawingChanged(canvasView.drawing)
                model.inkSelectionMayHaveMoved()
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isAtOpeningViewport = false
            if canvasView === sketchCanvas { model.penDown() }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            if canvasView === sketchCanvas { model.penUp() }
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

        // MARK: Selecting and moving document ink

        /// The drawing under a canvas point: the stroke there and every stroke touching
        /// it, directly or through others. Nil if there is no ink at the point.
        func drawing(at point: CGPoint, tolerance: CGFloat) -> Set<Double>? {
            let strokes = documentCanvas.drawing.strokes
            guard let hit = strokes.last(where: { stroke in
                guard stroke.renderBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
                return stroke.path.interpolatedPoints(by: .distance(4)).contains { sample in
                    let location = sample.location.applying(stroke.transform)
                    return hypot(location.x - point.x, location.y - point.y) <= tolerance + max(sample.size.width, sample.size.height) / 2
                }
            }) else { return nil }

            let outlines = strokes.map { stroke in
                let bounds = stroke.renderBounds
                return SketchStroke(key: Self.key(for: stroke), points: [bounds.origin, CGPoint(x: bounds.maxX, y: bounds.maxY)])
            }
            let hitKey = Self.key(for: hit)
            let group = SketchAnalyzer.cluster(outlines, reach: tolerance).first { $0.contains { $0.key == hitKey } }
            return Set(group?.map(\.key) ?? [hitKey])
        }

        /// The area the strokes with these keys cover, or nil if none of them exist.
        func bounds(of keys: Set<Double>) -> CGRect? {
            let rects = documentCanvas.drawing.strokes.filter { keys.contains(Self.key(for: $0)) }.map(\.renderBounds)
            return rects.dropFirst().reduce(rects.first) { $0?.union($1) }
        }

        func translateInk(_ keys: Set<Double>, by delta: CGSize) {
            let move = CGAffineTransform(translationX: delta.width, y: delta.height)
            var drawing = documentCanvas.drawing
            drawing.strokes = drawing.strokes.map { stroke in
                guard keys.contains(Self.key(for: stroke)) else { return stroke }
                var moved = stroke
                moved.transform = stroke.transform.concatenating(move)
                return moved
            }
            setDocumentDrawing(drawing)
        }

        /// Makes a finished move undoable. PencilKit only records what its own tools do.
        func registerUndo(ofMoving keys: Set<Double>, by delta: CGSize) {
            guard let undoManager = documentCanvas.documentUndoManager else { return }
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { coordinator in
                let back = CGSize(width: -delta.width, height: -delta.height)
                coordinator.translateInk(keys, by: back)
                coordinator.registerUndo(ofMoving: keys, by: back)
            }
            undoManager.endUndoGrouping()
        }

        /// The strokes with these keys, as points on the canvas, for reading as a sketch.
        func inkStrokes(_ keys: Set<Double>) -> [SketchStroke] {
            documentCanvas.drawing.strokes.filter { keys.contains(Self.key(for: $0)) }.map { stroke in
                SketchStroke(
                    key: Self.key(for: stroke),
                    points: stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
                )
            }
        }

        func deleteInk(_ keys: Set<Double>) {
            var drawing = documentCanvas.drawing
            let removed = drawing.strokes.filter { keys.contains(Self.key(for: $0)) }
            guard !removed.isEmpty else { return }
            drawing.strokes.removeAll { keys.contains(Self.key(for: $0)) }
            setDocumentDrawing(drawing)
            registerUndo(ofRemoving: removed)
        }

        private func registerUndo(ofRemoving strokes: [PKStroke]) {
            guard let undoManager = documentCanvas.documentUndoManager else { return }
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { coordinator in
                var drawing = coordinator.documentCanvas.drawing
                drawing.strokes.append(contentsOf: strokes)
                coordinator.setDocumentDrawing(drawing)
                coordinator.registerUndo(ofAdding: strokes)
            }
            undoManager.endUndoGrouping()
        }

        private func registerUndo(ofAdding strokes: [PKStroke]) {
            guard let undoManager = documentCanvas.documentUndoManager else { return }
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { coordinator in
                coordinator.deleteInk(Set(strokes.map(Self.key(for:))))
            }
            undoManager.endUndoGrouping()
        }

        private func setDocumentDrawing(_ drawing: PKDrawing) {
            documentCanvas.drawing = drawing
            model.drawingChanged(drawing)
            model.inkSelectionMayHaveMoved()
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
            registerUndo(ofAdding: added)
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

        /// The creation date the last stroke made here was given. Each new stroke is given a
        /// later one, since a stroke's creation date is its key.
        private var lastStrokeDate = Date.distantPast

        /// PencilKit strokes through points in canvas points, drawn at an even pace.
        private func makeStrokes(_ strokes: [[CGPoint]], ink: PKInk, width: CGFloat) -> [PKStroke] {
            strokes.filter { !$0.isEmpty }.map { points in
                let controlPoints = points.enumerated().map { offset, point in
                    PKStrokePoint(
                        location: point, timeOffset: Double(offset) * 0.008, size: CGSize(width: width, height: width),
                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                    )
                }
                let created = max(Date(), lastStrokeDate.addingTimeInterval(0.001))
                lastStrokeDate = created
                return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: created))
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
            stroke.path.creationDate.timeIntervalSinceReferenceDate
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
