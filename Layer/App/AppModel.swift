import CoreGraphics
import Observation
import os
import PencilKit
import SwiftUI

/// Where the pen is, kept apart from `AppModel` so that tracking it redraws only the cursor.
@MainActor @Observable
final class PenTracker {
    /// In the view's own points, not the canvas's.
    var location: CGPoint?
}

/// A sketch that is being read: its strokes are re-traced in the accent colour meanwhile.
struct RetraceEffect: Identifiable, Equatable {
    let id = UUID()
    var strokes: [[CGPoint]]
    /// For sketches of text: a line across the screen at the sketch's height.
    var band: CGRect?
}

/// A sketch that meant nothing, fading away.
struct InkGhost: Identifiable, Equatable {
    let id = UUID()
    var strokes: [[CGPoint]]
}

/// A close call the Magic Pen settled, offered again as what it nearly was: "Did you mean
/// Text Field?"
struct KindSuggestion: Identifiable, Equatable {
    let id = UUID()
    /// The element the sketch became.
    var ref: DesignStore.ElementRef
    /// What it nearly was instead.
    var kind: ElementKind
    /// Where it was sketched, in canvas points, so that the other kind is laid out from
    /// the same drawing.
    var sketch: CGRect
    /// What the sketch looked like, for what the marks inside it say.
    var observation: SketchObservation
}

/// A line being drawn round things to select them, in the view's points: the loop of the
/// palette's lasso, or the box a finger drags out after resting on the canvas.
enum Sweep: Equatable, Sendable {
    case lasso([CGPoint])
    case box(from: CGPoint, to: CGPoint)

    /// The line as a loop, corner by corner for a box.
    var loop: [CGPoint] {
        switch self {
        case .lasso(let points):
            points
        case .box(let start, let end):
            [start, CGPoint(x: end.x, y: start.y), end, CGPoint(x: start.x, y: end.y)]
        }
    }
}

/// One open design's working state, and the path from Magic Pen sketches to elements.
@MainActor @Observable
final class AppModel {
    enum Tool: Sendable {
        /// The PencilKit palette is up; its selected tool decides what a stroke does.
        case draw
        /// The palette is away; touches select and move things, and pan the canvas.
        case select
    }

    enum PanelTab: Sendable {
        case layers, code
    }

    let document: LayerDocument
    let store: DesignStore
    let engine: SketchEngine
    let pen = PenTracker()
    let images: ImageLibrary
    /// Where the design is saved, when the system has said.
    var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            let previousID = designID
            designID = fileURL.map(DesignLibrary.id(for:))
            if let previousID, previousID != designID {
                DesignIndexer.forget(design: previousID)
                // What Siri and Shortcuts hold from before the move still finds the design.
                if let designID { OpenDesigns.shared.designMoved(from: previousID, to: designID) }
            }
            // A rename that finishes after the design closed doesn't list it again, but the
            // design is indexed under its new identifier now: nothing here will change it again.
            guard !isClosed else {
                if previousID != designID, let snapshot = DesignActions.snapshot(of: self) {
                    Task { await DesignIndexer.index(snapshot) }
                }
                return
            }
            OpenDesigns.shared.opened(self)
            DesignIndexer.designChanged(self)
            matchNameAndFile()
            checkFile()
        }
    }
    /// How Siri, Shortcuts and Spotlight know this design: see `DesignLibrary`. Nil until
    /// the system has said where the design is saved.
    private(set) var designID: String?
    /// Where the design's file stands with iCloud.
    private(set) var syncState = SyncState.local(canUseICloud: false)
    /// Set when versions of the design from other devices were kept aside as copies, to
    /// tell the person once.
    var keptVersionsNotice: String?

    /// The canvas's drags, so that one left live by a cancel nobody heard can be ended.
    @ObservationIgnored weak var drags: CanvasDrags?

    var tool: Tool = .draw {
        didSet {
            guard tool != oldValue else { return }
            // Drawing chosen in a narrow window is kept, whatever the width does next.
            if tool == .draw { drawingWaitsForAWiderWindow = false }
            // A drag or a turn whose end was never heard ends here: left live, a drag stops
            // every other, and a turn keeps its part of the step open.
            drags?.endAny(model: self)
            endTurn()
            if tool == .draw {
                selection = nil
                scheduleConversion()
                pencilVoiceIfMade?.drawTurnedOn()
            } else {
                settle?.cancel()
            }
        }
    }

    var selection: CanvasSelection? {
        didSet {
            if selection != oldValue {
                isEditingText = false
                // The format panel's changes so far are a step, apart from the next selection's.
                endAdjustmentNow()
                // Several things turn about a pivot fixed as they are selected, and forgotten
                // when the selection changes: selected again, they form a new one.
                turnSession = nil
                // A turn of what was selected ends with it: the knob that was turning it goes,
                // and may never hear its drag end. Not two fingers' twist, which ends as they
                // lift, nor a turn of what a drag has given to other hosts, still the same things.
                if !isRehosting, !isTwisting { endTurn() }
            }
            // The format panel is for the selection: with nothing selected it goes.
            if selection == nil, isInspectorOpen {
                withAnimation(.smooth(duration: 0.3)) { isInspectorOpen = false }
            }
        }
    }

    /// Where the canvas has scrolled to and how far it is zoomed, tracked apart: panning
    /// changes only the offset, so what depends on the zoom alone isn't redrawn by a pan.
    /// Kept current by the ink canvases, which own the scrolling and zooming.
    var scrollOffset = CGPoint.zero
    var zoomScale: CGFloat = 1
    /// Which part of the canvas is showing. Reading it depends on both the offset and the
    /// zoom; read `zoomScale` alone where only the zoom matters.
    var viewport: Viewport {
        get { Viewport(offset: scrollOffset, scale: zoomScale) }
        set {
            if scrollOffset != newValue.offset { scrollOffset = newValue.offset }
            if zoomScale != newValue.scale { zoomScale = newValue.scale }
        }
    }
    /// The zoom the canvas last came to rest at. Text is redrawn sharp for this zoom,
    /// rather than on every frame of a pinch.
    var settledScale: CGFloat = 1
    /// While locked, the canvas can't be panned or zoomed by touch.
    var isCanvasLocked = false

    var isLayersOpen = false {
        didSet { if isLayersOpen, fitsOnePanel { isInspectorOpen = false } }
    }
    var panelTab: PanelTab = .layers
    /// Whether the paintbrush's panel of settings for the selection or the canvas is open.
    var isInspectorOpen = false {
        didSet { if isInspectorOpen, fitsOnePanel { isLayersOpen = false } }
    }
    /// Whether the menu under the board's name is open: its name, and the canvas's settings.
    var isBoardMenuOpen = false

    /// Opens the board's menu. In a compact window a panel's sheet makes way for it first,
    /// since only one sheet can show at a time.
    func openBoardMenu() {
        guard isCompactSizeClass, isInspectorOpen || isLayersOpen else {
            isBoardMenuOpen = true
            return
        }
        isInspectorOpen = false
        isLayersOpen = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.isBoardMenuOpen = true
        }
    }

    /// Whether the selected element's text is being typed into.
    var isEditingText = false
    /// An image being made in Image Playground, while its sheet is up. See `ImagePlaygroundSupport`.
    var imagePlaygroundRequest: ImagePlaygroundRequest?
    /// Whether sketches convert on their own once the pen has rested for a moment.
    /// Remembered between launches.
    var convertsAutomatically: Bool {
        didSet {
            settings.set(convertsAutomatically, forKey: AppModel.convertsAutomaticallyKey)
            scheduleConversion()
        }
    }
    /// The size of the view the canvas is shown in, which is the size of the window.
    var canvasSize: CGSize = .zero {
        didSet { if fitsOnePanel, isLayersOpen, isInspectorOpen { isLayersOpen = false } }
    }
    /// How far down the view the bar across the top reaches.
    var topBarBottom: CGFloat = 0
    /// Whether the window is too narrow for the controls to be spread along its edges.
    /// The top bar decides, from whether its tools fit beside the board's name: when they
    /// don't they fold into a menu, and undo, redo and zoom share one control.
    var isCompactWidth = false
    /// Whether the window is narrow enough that iPadOS lays it out like an iPhone. Sheets
    /// then rise from the bottom edge, which is how the panels open, and the pencil
    /// palette is a bar fixed across the bottom rather than one that floats.
    var isCompactSizeClass = false {
        didSet {
            if fitsOnePanel, isLayersOpen, isInspectorOpen { isLayersOpen = false }
            windowWidthChanged()
        }
    }
    /// Whether the window has said how wide it is yet: the first time is the design opening.
    private var hasSeenWindowWidth = false
    /// Drawing was left off because the design opened in a narrow window. It comes on when
    /// the window widens, unless something else was chosen meanwhile.
    private var drawingWaitsForAWiderWindow = false

    /// A design opened in a narrow window, or on a phone, starts with Draw off: the pencil
    /// bar would take the bottom of a small screen before anything was drawn. The palette
    /// comes when the window widens, or when Draw is turned on.
    private func windowWidthChanged() {
        if !hasSeenWindowWidth {
            hasSeenWindowWidth = true
            guard isCompactSizeClass, tool == .draw else { return }
            tool = .select
            drawingWaitsForAWiderWindow = true
        } else if !isCompactSizeClass, drawingWaitsForAWiderWindow {
            drawingWaitsForAWiderWindow = false
            if tool == .select { tool = .draw }
        }
    }
    /// Whether there is only room for one panel at a time.
    private var fitsOnePanel: Bool { isCompactSizeClass || (canvasSize.width > 0 && canvasSize.width < 680) }
    /// True while an element is being dragged or resized, which shows the spacing guides.
    var isAdjusting = false

    private(set) var effects: [RetraceEffect] = []
    private(set) var ghosts: [InkGhost] = []
    /// True while there is Magic Pen ink on the canvas that hasn't become anything.
    private(set) var hasSketch = false

    @ObservationIgnored weak var ink: InkCanvas.Coordinator?
    /// Magic Pen strokes, in canvas points.
    @ObservationIgnored private var strokes: [SketchStroke] = []
    @ObservationIgnored private var inFlight: Set<Double> = []
    /// Stroke groups that were read and meant nothing. They linger briefly, in case more
    /// strokes are coming to complete them, and are not re-read as they are.
    @ObservationIgnored private var rejected: Set<Set<Double>> = []
    @ObservationIgnored private var settle: Task<Void, Never>?
    /// Sketches being read, so that a design that closes can stop them.
    @ObservationIgnored private var conversions: [Task<Void, Never>] = []
    @ObservationIgnored private(set) var isPenDown = false
    /// The name being thought up for the board, while it is: a test can wait for it.
    @ObservationIgnored private(set) var titleSuggestion: Task<Void, Never>?
    /// The board's name as it is shown: its own, or else its file's, unless the file still
    /// has the name new designs get. A name undone or cleared showed "Untitled" in the top
    /// bar, while the file, Files and Siri kept the name (review m2).
    var boardName: String { chosenName ?? String(localized: "Untitled") }

    /// The board's own name, or else its file's, if somebody chose that.
    var chosenName: String? {
        if let title = store.title { return title }
        guard let file = fileURL?.deletingPathExtension().lastPathComponent, !DesignFileName.isUntitled(file) else { return nil }
        return file
    }

    /// Whether the board is given a name of the app's once it has something on it. A test
    /// about something else turns it off, so that no name lands in the middle of it.
    @ObservationIgnored var suggestsTitle = true
    /// Whether the board has had a name here, given by hand or by the app.
    @ObservationIgnored private var hasHadName = false
    /// Whether the board has been named: it has had a name here, or its file has one
    /// somebody chose. A name is suggested only for a board that hasn't, so one cleared or
    /// undone stays so, rather than a suggestion renaming the file again (M4).
    private var hasBeenNamed: Bool {
        hasHadName || store.title != nil || document.current.fileName.map { !DesignFileName.isUntitled($0) } == true
    }
    @ObservationIgnored private var adjustmentEnd: Task<Void, Never>?

    /// Whether a finger draws while the palette is up. Once Apple Pencil has been seen,
    /// it doesn't: the Pencil draws, and a finger selects, moves, pans and taps buttons.
    /// Until then a finger draws, so that Layer works without a Pencil. Either way it can
    /// be set in the format panel, after which it is left as set. Remembered between launches.
    var fingerDraws: Bool {
        didSet { settings.set(fingerDraws, forKey: AppModel.fingerDrawsKey) }
    }

    /// Where the app's own settings are kept: see `AppSettings`. A test can give a design
    /// settings of its own.
    @ObservationIgnored let settings: UserDefaults

    /// Set by hand in the format panel.
    func setFingerDraws(_ draws: Bool) {
        fingerDraws = draws
        settings.set(true, forKey: AppModel.fingerDrawsChosenKey)
    }

    /// Apple Pencil touched the canvas. The first time, a finger stops drawing, unless
    /// that has been set by hand. `elsewhere` is a touch in a presentation of its own over
    /// the canvas: a panel's sheet, a popover or an alert.
    func pencilTouched(at viewPoint: CGPoint, elsewhere: Bool = false) {
        if fingerDraws, !settings.bool(forKey: AppModel.fingerDrawsChosenKey) {
            fingerDraws = false
        }
        // On a panel, a popover or the bars, the Pencil is pressing a control, scrubbing a
        // field for instance, not landing on the canvas.
        if elsewhere || chromeFrames.values.contains(where: { $0.contains(viewPoint) }) { return }
        // With the palette up, the Pencil is for drawing: landing on what a finger
        // selected lets go of it, rather than dragging it about. Not with the lasso in
        // hand, though: what the lasso has picked, the Pencil can drag.
        if tool == .draw, !isLassoInHand, let rect = selectionViewRect, rect.insetBy(dx: -8, dy: -8).contains(viewPoint) {
            selection = nil
        }
    }

    /// Whether the palette's lasso is the tool in hand. Then a loop drawn on the canvas
    /// selects what it goes round, rather than leaving ink. Kept current by the ink canvas.
    @ObservationIgnored var isLassoInHand = false

    /// Where the controls that float over the canvas are, in the view's points, by name.
    /// Read when the Pencil touches down, not drawn from, so not observed.
    @ObservationIgnored var chromeFrames: [String: CGRect] = [:]

    /// Whether the Pencil detector has anything to do: notice a first Pencil, or let go of
    /// what a finger selected when the Pencil lands on it.
    var needsPencilDetector: Bool {
        (fingerDraws && !settings.bool(forKey: AppModel.fingerDrawsChosenKey)) || (tool == .draw && selection != nil)
    }

    private static let fingerDrawsKey = "fingerDraws"
    private static let fingerDrawsChosenKey = "fingerDrawsChosen"
    private static let convertsAutomaticallyKey = "convertsAutomatically"

    init(document: LayerDocument, settings: UserDefaults = AppSettings.defaults) {
        self.document = document
        self.settings = settings
        // All on until set otherwise.
        fingerDraws = settings.object(forKey: AppModel.fingerDrawsKey) == nil || settings.bool(forKey: AppModel.fingerDrawsKey)
        convertsAutomatically = settings.object(forKey: AppModel.convertsAutomaticallyKey) == nil || settings.bool(forKey: AppModel.convertsAutomaticallyKey)
        squeezesToTalk = settings.object(forKey: AppModel.squeezesToTalkKey) == nil || settings.bool(forKey: AppModel.squeezesToTalkKey)
        let file = document.current
        store = DesignStore(content: file.content)
        images = ImageLibrary(file.images)
        engine = SketchEngine(provider: file.content.canvas.resolvedModel.sketchProvider)
        appliedModel = .some(file.content.canvas.model)
        hasHadName = file.content.title != nil
        store.onChange = { [weak self, document] content in
            // A command or generation still unwinding after the design closed doesn't
            // write to a document the browser has already let go of.
            guard self?.isClosed != true else { return }
            document.update { $0.content = content }
            if content.title != nil { self?.hasHadName = true }
            // A drawing moved, locked, hidden, deleted or put back by undo shows on the ink canvas.
            self?.ink?.showDrawings()
            // Something else may have locked or taken away what a finger is dragging.
            self?.checkDragAfterChange()
            self?.followModelChoice()
            self?.dropSelectionOfMissingThings()
            self?.stopGeneratingForAScreenThatIsGone()
            self?.matchNameAndFile()
            self?.schedulePreview()
            if let self { DesignIndexer.designChanged(self) }
        }
    }

    /// The check put off until after a change, of whether what a drag moves is still there.
    @ObservationIgnored private var dragCheck: Task<Void, Never>?

    /// Sees, once the change being told of is done with, whether a drag under way still has
    /// what it moves: ending the drag ends the edit the change may be part of. Not for the
    /// drag's own frames, which neither lock nor take away what it moves, and once for all
    /// the changes made before it runs. A task was made for every change, each frame of a
    /// drag among them (audit C6).
    private func checkDragAfterChange() {
        guard dragCheck == nil, let drags, drags.isDragging, !drags.isMakingChange(in: store) else { return }
        #if DEBUG
        CanvasWork.dragChecks += 1
        #endif
        dragCheck = Task { @MainActor [weak self] in
            guard let self else { return }
            dragCheck = nil
            drags.endIfDraggedIsGone(model: self)
        }
    }

    // MARK: The model

    /// The model this design uses, as saved in its file or the app's default.
    var modelChoice: ModelChoice { store.content.canvas.resolvedModel }

    /// Changes the model this design uses, saved in its file. Undoable like any setting.
    func setModelChoice(_ choice: ModelChoice) {
        guard store.canvas.model != choice else { return }
        store.updateCanvas { $0.model = choice }
    }

    /// Points the sketch engine at this design's model. Cheap when nothing changed, so it
    /// runs on every change to the design and whenever the app's model settings change.
    func applyModelChoice() {
        appliedModel = .some(store.canvas.model)
        engine.use(modelChoice.sketchProvider)
    }

    /// The design's own choice of model as it was last applied. Every change to the design,
    /// each frame of a drag among them, used to apply the choice again, which reads the
    /// app's default and its lists of models from the user's defaults and decodes them.
    @ObservationIgnored private var appliedModel: ModelChoice??

    /// Applies the model choice if the design's own has changed. A change to the app's
    /// default applies it through `applyModelChoice()`, on `ModelPreferences.changed`.
    private func followModelChoice() {
        if appliedModel != .some(store.canvas.model) { applyModelChoice() }
    }

    // MARK: Generating screens

    /// A screen being written by the design's model, element by element.
    struct ScreenGeneration: Equatable {
        enum Phase: Equatable {
            case writing
            case finished
            case failed(String)
        }

        var screenID: DesignScreen.ID
        var description: String
        var elementCount = 0
        var phase = Phase.writing
        /// True until the model starts writing its answer.
        var isThinking = true
    }

    /// The screen being generated, or the last one while its outcome is shown.
    private(set) var generation: ScreenGeneration?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationDismissal: Task<Void, Never>?

    var isGenerating: Bool { generation?.phase == .writing }

    /// Adds a new screen and has the design's model write it from `description`. Its
    /// elements appear as the model writes them; the whole screen is one undo step.
    ///
    /// `name` is what to call the screen; without one it is named from the description.
    /// `device` is what it is a screen of; without one, the canvas's own device.
    ///
    /// `anchor` is a canvas point to put the screen at, where the pencil pointed for a
    /// spoken command; without one it goes where new screens always go.
    ///
    /// The screen is an undo step of its own (`DesignStore.Edit`), or, asked for by a spoken
    /// command, part of the command's: either way, what the person does while it is
    /// written is a step of its own, which the screen's never takes in or closes (G4).
    func generateScreen(from description: String, named name: String? = nil, near anchor: CGPoint? = nil, device: DeviceFrame? = nil) {
        let prompt = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating, !isClosed else { return }
        generationTask?.cancel()
        generationDismissal?.cancel()

        let device = device ?? store.canvas.sketchDevice
        // What the design says already, before the new screen joins it, so the new one's
        // words match. Nothing for an empty design.
        let board = store.content.screens.isEmpty ? nil : SketchPrompt.describe(board: store.content)
        // Part of a spoken command's step, which waits for the screen; otherwise a step of its
        // own, even when asked for inside a one-off step that ends at once (review M-5).
        let joined = store.actingEdit.flatMap { $0 === store.heldEdit ? $0 : nil }
        let ownsEdit = joined == nil
        let edit = joined ?? store.beginEditOfItsOwn(by: .app)
        store.name(edit, String(localized: "Generate Screen"))
        // A command the pencil pointed at empty canvas for puts the screen where it pointed.
        let screen = store.act(for: edit) { () -> DesignScreen in
            let screen = store.addScreen(device, at: DesignActions.placementForNewScreen(device, in: self, near: anchor))
            store.updateScreen(screen.id) { $0.name = name ?? ScreenGenerator.name(for: prompt) }
            return screen
        }
        // Shown, not selected: a new screen comes in without selection handles round it.
        DesignActions.reveal(.screen(screen.id), in: self, selecting: false)
        generation = ScreenGeneration(screenID: screen.id, description: prompt)

        let choice = modelChoice
        let stream = screenStream(prompt, board, choice)
        generationWasStopped = false
        generationTask = Task { [weak self] in
            // What the generation has written, by place in its latest version.
            var written: [DesignElement?] = []
            do {
                for try await update in stream {
                    guard let self else { return }
                    // The screen was taken away, by undo or by hand: there is nothing left to
                    // write on, but the generation still finishes, or it is stuck writing.
                    guard let current = store.screen(screen.id) else { break }
                    switch update {
                    case .startedWriting:
                        generation?.isThinking = false
                    case .screen(let blueprint):
                        withAnimation(.snappy(duration: 0.25)) {
                            written = store.act(for: edit) {
                                store.writeGenerated(blueprint.layout(on: current.device), on: screen.id, over: written)
                            }
                        }
                        generation?.isThinking = false
                        generation?.elementCount = blueprint.itemCount
                    }
                }
                self?.finishGeneration(error: nil, edit: edit, ownsEdit: ownsEdit)
            } catch {
                self?.finishGeneration(error: error is CancellationError ? nil : error, edit: edit, ownsEdit: ownsEdit)
            }
        }
    }

    /// Stops the model; what it has written so far stays.
    func stopGenerating() {
        generationWasStopped = isGenerating
        generationTask?.cancel()
    }

    /// Whether the generation under way was stopped, rather than finished or failed.
    @ObservationIgnored private var generationWasStopped = false

    /// A screen taken away while it is being written, by undo or by hand, stops the model:
    /// a reasoning model can think for tens of seconds, a paid request, before it writes
    /// the line that would find the screen gone (G11).
    private func stopGeneratingForAScreenThatIsGone() {
        guard isGenerating, let generation, store.screen(generation.screenID) == nil else { return }
        generationTask?.cancel()
    }

    /// Returns once the screen being generated has finished, failed or been stopped.
    func waitForGeneration() async {
        await generationTask?.value
    }

    /// Where a generated screen's updates come from. A test puts its own in.
    @ObservationIgnored var screenStream: (String, String?, ModelChoice) -> AsyncThrowingStream<ScreenGenerator.Update, any Error> = {
        ScreenGenerator.stream($0, board: $1, using: $2)
    }

    /// Ends a generation, and the screen's undo step if it has one of its own (`ownsEdit`):
    /// that and nothing else, so a drag still under way goes on as its own step (G4).
    private func finishGeneration(error: (any Error)?, edit: DesignStore.Edit, ownsEdit: Bool) {
        generationTask = nil
        let wasStopped = generationWasStopped
        generationWasStopped = false
        defer { if ownsEdit { store.endEdit(edit) } }
        guard var finished = generation else { return }
        // Nothing is written to a design that has closed, and nothing is left to show.
        guard !isClosed else {
            generation = nil
            return
        }
        // A screen taken away while it was written has nothing to show either.
        guard let screen = store.screen(finished.screenID) else {
            generation = nil
            return
        }
        // A screen nothing was written on isn't left behind, unless something was put on it
        // by hand meanwhile: it stays, with that on it (M1).
        if finished.elementCount == 0, screen.elements.isEmpty {
            store.act(for: edit) { store.deleteScreen(finished.screenID) }
        }
        // Stopped before it wrote anything: there is nothing to say (G10).
        if wasStopped, finished.elementCount == 0 {
            generation = nil
            return
        }
        if let error {
            finished.phase = .failed(error.localizedDescription)
        } else {
            finished.phase = finished.elementCount > 0 ? .finished : .failed(ScreenGenerator.GenerationError.nothingWritten.localizedDescription)
        }
        finished.isThinking = false
        generation = finished
        // Success says so briefly; a failure stays until it is dismissed.
        if finished.phase == .finished {
            generationDismissal = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.3)) { self?.dismissGeneration() }
            }
        }
    }

    /// Clears a finished generation's outcome.
    func dismissGeneration() {
        guard !isGenerating else { return }
        generationDismissal?.cancel()
        generation = nil
    }

    /// The pencil bar of a narrow window was flicked aside or down. That puts it away and
    /// ends drawing, so nothing is left in the corner but what belongs there, and a
    /// finger goes back to selecting and panning. Draw in the tools menu brings it back.
    func pencilBarFlickedAway() {
        guard isCompactSizeClass, tool == .draw else { return }
        withAnimation(.smooth(duration: 0.3)) { tool = .select }
    }

    // MARK: Voice mode

    /// The call that is up in this design, if one is.
    private(set) var voice: VoiceCall?
    /// Why a call couldn't start or couldn't go on, to tell the person once.
    var voiceNotice: String?

    var isInVoiceCall: Bool { voice != nil }

    /// Whether the phone button is there to start a call with: in the free corner of a
    /// narrow window, with no call up already and no panel over that corner. Drawing and
    /// voice mode are one or the other: while Draw is on the pencil bar has the bottom of
    /// the window and the button is gone, as Draw is unavailable while a call is up.
    var offersVoiceMode: Bool {
        isCompactSizeClass && tool != .draw && !isInVoiceCall && !isLayersOpen && !isInspectorOpen
    }

    /// Starts a call: the phone button's action. A call with no model to act on what it
    /// hears would be no use, so one that can't be used is said so instead.
    func startVoiceCall() {
        guard voice == nil else { return }
        if case .unavailable(let reason) = modelChoice.sketchProvider.readiness() {
            voiceNotice = reason
            return
        }
        Task { await startVoiceCall(route: DictationRoute(), runner: VoiceAgent(model: self)) }
    }

    /// Lets one spoken command at a time act on the design, whichever call it came from.
    let voiceCommands = VoiceCommandGate()

    /// The line the design's phone calls are made on: the app's, so that one started in
    /// any window ends one up in another. A test gives its design a line of its own.
    @ObservationIgnored var phoneLine = PhoneLine.shared

    /// Said when a command reaches a design that has closed.
    static let closedProblem = "The design has closed."

    /// Stops the pencil listening, if it is: another call is taking the microphone.
    func stopPencilListening() {
        pencilVoiceIfMade?.stopListening()
    }

    /// Starts a call that hears through `route` and acts through `runner`. Returns once
    /// the call is listening, or has ended because it couldn't.
    func startVoiceCall(route: any VoiceRoute, runner: any VoiceCommandRunner) async {
        guard voice == nil else { return }
        // The pencil bar goes, and a finger pans and selects, for as long as the call is up.
        // That is a choice made: drawing put off by a narrow window no longer waits for a
        // wider one, or widening the window mid-call would bring the bar over the pill.
        tool = .select
        drawingWaitsForAWiderWindow = false
        // One microphone at a time, in every window: the phone call hears from now on. A
        // pencil command already sent still runs, in its turn.
        for design in OpenDesigns.shared.all where design !== self { design.stopPencilListening() }
        stopPencilListening()
        let call = VoiceCall(route: route, runner: runner, vocabulary: { [weak self] in self?.voiceVocabulary ?? [] }, line: phoneLine)
        call.gate = voiceCommands
        // What the agent is doing, tool by tool, is what the pill says while it works.
        (runner as? VoiceAgent)?.onStep = { [weak call] step in call?.showStep(step) }
        call.onEnd = { [weak self, weak call] in
            guard let self, let call, self.voice === call else { return }
            self.voiceNotice = call.endReason
            withAnimation(.smooth(duration: 0.3)) { self.voice = nil }
        }
        withAnimation(.smooth(duration: 0.3)) { voice = call }
        await call.start()
    }

    func endVoiceCall() {
        voice?.end()
    }

    /// Layer only listens while it is in front: a call ends when its window leaves the
    /// screen. The window's own scene says when that is. SwiftUI's scene phase can't be
    /// used for it: it reads as in the background while a window is being resized, and
    /// stays that way, though the window never left.
    func windowLeftTheScreen() {
        endVoiceCall()
        pencilVoiceIfMade?.stopListening()
    }

    /// Apple Pencil Pro's push-to-talk, made when first asked for. A test puts its own in.
    var pencilVoice: PencilVoice {
        get {
            if let pencilVoiceIfMade { return pencilVoiceIfMade }
            let made = PencilVoice(model: self)
            pencilVoiceIfMade = made
            return made
        }
        set { pencilVoiceIfMade = newValue }
    }

    @ObservationIgnored private var pencilVoiceIfMade: PencilVoice?

    /// Whether squeezing Apple Pencil Pro talks to the design: Squeeze to Talk, in
    /// Settings and the board's Magic Pen tab, on until turned off there. Off, the squeeze
    /// is the system's, as in any other app, and whatever the pencil is listening to is let
    /// go of, unsent. Either place sets it for every open design at once.
    var squeezesToTalk: Bool {
        didSet {
            guard squeezesToTalk != oldValue else { return }
            if !squeezesToTalk { pencilVoiceIfMade?.squeezeToTalkTurnedOff() }
        }
    }

    /// Where the app keeps Squeeze to Talk. Without dots: it is watched by key, and a dot
    /// would make the key a path.
    static let squeezesToTalkKey = "squeezesToTalk"

    /// Reads Squeeze to Talk again, once it has been changed.
    func readSqueezesToTalk() {
        squeezesToTalk = settings.object(forKey: AppModel.squeezesToTalkKey) == nil || settings.bool(forKey: AppModel.squeezesToTalkKey)
    }

    /// Turns Squeeze to Talk on or off from the board's Magic Pen tab. It is the app's
    /// setting, the one in Settings too, so every open design follows it.
    func setSqueezesToTalk(_ on: Bool) {
        AppModel.setSqueezesToTalk(on, in: settings, designs: [self] + openDesigns().filter { $0 !== self })
    }

    /// Turns Squeeze to Talk on or off, in Settings or a board's Magic Pen tab, and has
    /// each of `designs` that keeps its settings in `settings` follow it at once. In the
    /// app that is every open design.
    static func setSqueezesToTalk(_ on: Bool, in settings: UserDefaults = AppSettings.defaults, designs: [AppModel] = OpenDesigns.shared.all) {
        settings.set(on, forKey: squeezesToTalkKey)
        for design in designs where design.settings === settings { design.readSqueezesToTalk() }
    }

    /// The designs open in the app's windows, which a setting of the app's reaches. A test says.
    @ObservationIgnored var openDesigns: @MainActor () -> [AppModel] = { OpenDesigns.shared.all }

    /// Whether the canvas has a squeeze action, for the pencil to talk with. Not with
    /// Squeeze to Talk off, nor in Draw, where the squeeze is PencilKit's.
    var canvasHearsSqueezes: Bool { squeezesToTalk && tool != .draw }

    /// The words on the canvas, which are the ones most likely to be spoken and misheard:
    /// the names of the screens and what their elements say.
    var voiceVocabulary: [String] {
        var seen: Set<String> = []
        let words = store.screens.flatMap { [$0.name] + $0.elements.map(\.text) } + store.floating.map(\.element.text)
        return words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 60 && seen.insert($0).inserted }
            .prefix(100)
            .map { $0 }
    }

    // MARK: The file

    @ObservationIgnored private var renaming: Task<Void, Never>?
    /// A name the file couldn't be given, so that it isn't tried again and again.
    @ObservationIgnored private var refusedName: String?
    @ObservationIgnored private var previewRefresh: Task<Void, Never>?
    @ObservationIgnored private let fileLog = Logger(subsystem: "kahshin.Layer", category: "file")

    /// Set once the design has closed. Whatever was still under way then, a name being
    /// thought up or a picture due, is dropped rather than done to a file the document
    /// browser has already listed.
    @ObservationIgnored private(set) var isClosed = false

    /// Whether the design's canvas is inside `view`: the view of the controller that shows it.
    func isShown(in view: UIView) -> Bool {
        ink?.canvases.contains { $0.isDescendant(of: view) } == true
    }

    /// Gets a design ready to go back to the document browser: its picture as the board
    /// was left, its name decided, and its file given that name. Asked again while it is
    /// getting ready, by a second tap of the back button or by an action opening another
    /// design, it waits for that to finish rather than going on early, and says false, so
    /// that only the first asker dismisses the design.
    @discardableResult
    func prepareToClose() async -> Bool {
        if let closing {
            await closing.value
            return false
        }
        guard !isClosed else { return false }
        let getting = Task {
            refreshPreview()
            // A name still being thought up is settled now, from the design's own words.
            if titleSuggestion != nil, store.title == nil, !hasBeenNamed {
                store.setTitle(engine.fallbackTitle(for: store.content), undoable: false)
            }
            await settleFileName()
            close()
        }
        closing = getting
        await getting.value
        return true
    }

    /// The design getting ready to close, once something has asked it to.
    @ObservationIgnored private var closing: Task<Void, Never>?

    /// Actions Siri and Shortcuts took on this design that their own undo can still take
    /// back. Each is taken out of their history once it can't be: see `TakenAction`.
    @ObservationIgnored var takenActions: [TakenAction] = []
    /// Said when Siri's undo of an action found nothing left to take back.
    var undoNotice: String?

    /// Takes out of Siri's history the actions everything of which has been changed since,
    /// so that Siri isn't left to undo one, do nothing, and say it did. Done as the app
    /// stops being active, which is when Siri can next be asked.
    func withdrawTakenActionsWithNothingLeft() {
        let content = store.content
        takenActions.removeAll { action in
            guard !action.canTakeBack(from: content) else { return false }
            action.withdraw()
            return true
        }
    }

    func close() {
        // Closed by the back button, then again as the canvas goes from the screen.
        guard !isClosed else { return }
        // Ink a pen or the eraser has changed and that is waiting for the tool to be put
        // down goes into the design now, while it can still be saved.
        ink?.flushPendingInk()
        drags?.endAny(model: self)
        // So is a turn the knob left live: its part of the step is its own, which the end
        // by hand below leaves open.
        endTurn()
        // A change made in the format panel moments ago is still an edit waiting for the
        // panel's pause to end it: it ends now, while the design can still be saved, with
        // whatever else is still under way.
        adjustmentEnd?.cancel()
        adjustmentEnd = nil
        adjustment = nil
        store.endAllEdits()
        // What was written without an undo step, or after the last save within an edit,
        // reaches the disk only if the system is told there is something to save.
        if document.hasChangesSinceSnapshot { store.markNeedsSaving() }
        isClosed = true
        // Siri's undo can't reach a closed design: it is given nothing to undo.
        for action in takenActions { action.withdraw() }
        takenActions.removeAll()
        voice?.end()
        // Listening stops. A pencil command already running isn't cancelled, but it ends at
        // its next tool call, since nothing more is done to a closed design.
        pencilVoiceIfMade?.designClosed()
        OpenDesigns.shared.closed(self)
        titleSuggestion?.cancel()
        previewRefresh?.cancel()
        fileCheck?.cancel()
        generationTask?.cancel()
        generationDismissal?.cancel()
        settle?.cancel()
        suggestionExpiry?.cancel()
        for conversion in conversions { conversion.cancel() }
        conversions.removeAll()
        // A rename under way finishes: stopping it halfway would leave the file misnamed.
    }

    /// Keeps the board's name and its file's name the same, so that the document browser
    /// shows designs by name. A file renamed elsewhere, in Files for instance, names the
    /// board. A board that is named, by hand or by suggestion, names its file.
    @ObservationIgnored private var matched: (url: URL, title: String?)?

    private func matchNameAndFile() {
        guard let url = fileURL, renaming == nil, !isClosed else { return }
        // Most changes, a drag for instance, touch neither the name nor the file.
        if let matched, matched.url == url, matched.title == store.title { return }
        matched = (url, store.title)
        let onDisk = url.deletingPathExtension().lastPathComponent
        let known = document.current.fileName
        if known != onDisk {
            document.update { $0.fileName = onDisk }
            if known == nil, document.isNew {
                // A design made just now has the name the system gives new ones.
                DesignFileName.untitled = DesignFileName.withoutNumber(onDisk)
            } else if known != nil || (store.title == nil && !DesignFileName.isUntitled(onDisk)) {
                // Not the name it had when the app last looked, or a name somebody gave
                // the file before its board had one: it was renamed elsewhere, and the
                // board takes the name.
                if store.title != onDisk { store.setTitle(onDisk, undoable: false) }
            }
        }

        guard let title = store.title else { return }
        let wanted = DesignFileName.fileName(for: title)
        guard !wanted.isEmpty, wanted != onDisk, wanted != refusedName else { return }
        renaming = Task { [weak self] in
            let moved = try? await DesignFileName.rename(url, to: wanted)
            guard let self else { return }
            renaming = nil
            guard let moved else {
                // A folder that can't be written to, or a file some other service holds.
                // The board keeps its name; the file keeps its own.
                fileLog.error("Couldn't rename the design's file to match its board")
                refusedName = wanted
                return
            }
            let name = moved.deletingPathExtension().lastPathComponent
            document.update { $0.fileName = name }
            // The name was taken, so the file has a number on the end: the board takes it too.
            if name != wanted { store.numberTitle(name, for: title) }
            fileURL = moved
            matchNameAndFile()
        }
    }

    @ObservationIgnored private var fileCheck: Task<Void, Never>?
    /// Keeps aside the versions of the file other devices saved at the same time.
    @ObservationIgnored var keepConflictingVersions: @Sendable (URL) async -> [String] = { await CloudFile.keepConflictingVersions(of: $0) }

    /// Looks at where the design's file stands with iCloud, and settles any versions of
    /// it that other devices saved at the same time. Done when the design opens, when
    /// the app comes back to the screen, and whenever the system says the file changed.
    /// Whether the app is on the screen. Nothing is checked on a schedule while it isn't.
    @ObservationIgnored var isActive = true {
        didSet { if isActive, !oldValue { OpenDesigns.shared.activated(self) } }
    }
    /// How long to wait before looking again at a file that is still uploading. It doubles
    /// each time, up to a minute, and starts again from three seconds on any other check.
    @ObservationIgnored private var fileCheckDelay: Duration = .seconds(3)

    func checkFile() {
        fileCheckDelay = .seconds(3)
        scheduleFileCheck()
    }

    private func scheduleFileCheck() {
        guard let url = fileURL, !isClosed else { return }
        fileCheck?.cancel()
        fileCheck = Task { [weak self] in
            guard let keep = self?.keepConflictingVersions else { return }
            let copies = await keep(url)
            // Said even by a check the next one cut short: settling can't be stopped part
            // way, and the next check finds the versions settled and has nothing to say.
            if !copies.isEmpty, let self, !isClosed, fileURL == url {
                let names = copies.map { "“\($0)”" }.formatted(.list(type: .and))
                keptVersionsNotice = copies.count == 1
                    ? "This design was changed on another device at the same time. That version is kept as \(names), beside this one."
                    : "This design was changed on other devices at the same time. Those versions are kept as \(names), beside this one."
            }
            guard !Task.isCancelled else { return }
            let state = await Task.detached { CloudFile.syncState(of: url) }.value
            guard let self, !Task.isCancelled, fileURL == url else { return }
            if syncState != state { syncState = state }
            // While something has still to go up, keep looking, less often each time, and
            // not at all while the app is away: coming back checks again.
            guard state.isInFlux, isActive else { return }
            try? await Task.sleep(for: fileCheckDelay)
            guard !Task.isCancelled, isActive else { return }
            fileCheckDelay = min(fileCheckDelay * 2, .seconds(60))
            fileCheck = nil
            scheduleFileCheck()
        }
    }

    /// Waits, briefly, for the file to have been given the board's name. Done before a
    /// design closes: a file renamed after the document browser has listed it stays
    /// listed under its old name for a while.
    func settleFileName() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while renaming != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    @ObservationIgnored private var lastBoardChange = ContinuousClock.now
    @ObservationIgnored private var isPreviewStale = false

    /// The board changed: its picture for the document browser is redrawn once the board
    /// has been left alone for a while. Drawing it takes the main thread for a moment,
    /// which is not to happen while someone is drawing or dragging.
    private func schedulePreview() {
        isPreviewStale = true
        lastBoardChange = .now
        guard previewRefresh == nil, !isClosed else { return }
        previewRefresh = Task { [weak self] in
            while true {
                guard let due = self.map({ $0.lastBoardChange + .seconds(5) }) else { return }
                if ContinuousClock.now >= due { break }
                try? await Task.sleep(until: due)
                if Task.isCancelled { return }
            }
            await self?.refreshPreviewInBackground()
            guard let self, !Task.isCancelled else { return }
            previewRefresh = nil
            images.keepDecoded(store.content.imageIDs)
            // Changed while it was being drawn: wait for the next pause.
            if needsPreview { schedulePreview() }
        }
    }

    /// What the board's picture shows, its ink included, so that a board changed and
    /// changed back, or touched without changing, isn't drawn again.
    @ObservationIgnored private var previewedBoard: DesignContent?

    private var board: DesignContent { document.current.content }

    private var needsPreview: Bool {
        guard document.current.preview != nil else { return true }
        // Until a picture has been drawn here, the one the file came with stands until a change.
        guard let previewedBoard else { return isPreviewStale }
        return previewedBoard != board
    }

    /// A copy of the design as it is now, to share. The file on disk can be some seconds
    /// behind, since the system saves a while after each change. The ink still waiting
    /// for the pen to be put down is taken in and the board's picture drawn first; the
    /// copy is written on another thread, under the file's name, in a folder of its own in
    /// `temporary`, which the share menu takes away when its sheet closes (see `ShareItem`).
    /// Old copies whose sheet closed unheard are cleared first, and a copy that can't be
    /// written leaves nothing behind.
    func fileToShare(in temporary: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        ink?.flushPendingInk()
        refreshPreview()
        let file = document.current
        let name = [fileURL?.deletingPathExtension().lastPathComponent, store.title.map(DesignFileName.fileName(for:))]
            .compactMap(\.self).first { !$0.isEmpty } ?? DesignFileName.untitled
        return try await Task.detached(priority: .userInitiated) {
            ShareItem.clearOldCopies(in: temporary)
            let folder = temporary.appendingPathComponent(ShareItem.copyPrefix + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(name).appendingPathExtension("layer")
                try file.wrapper().write(to: url, options: .atomic, originalContentsURL: nil)
                return url
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }.value
    }

    /// Redraws the board's picture now. Done before a design closes or the app leaves the
    /// screen, so that the picture saved is of the board as it was left.
    func refreshPreview() {
        previewRefresh?.cancel()
        previewRefresh = nil
        guard needsPreview else { return }
        isPreviewStale = false
        previewedBoard = board
        let picture = BoardSnapshot.thumbnail(of: self)
        document.update { $0.preview = picture }
    }

    /// The app has gone to the background, and the system saves the design as it goes.
    /// The board's picture is drawn for it, and, written without an undo step, has to be
    /// announced to be saved. (Only drawn, not announced, when the app is merely inactive:
    /// Control Center or an alert over it.)
    func leavingTheScreen() {
        ink?.flushPendingInk()
        refreshPreview()
        withdrawTakenActionsWithNothingLeft()
        if document.hasChangesSinceSnapshot { store.markNeedsSaving() }
    }

    /// Redraws the board's picture while the board is left alone. Only its views are drawn
    /// on the main thread; the ink and the JPEG are done on another.
    private func refreshPreviewInBackground() async {
        guard needsPreview, !isClosed else { return }
        let shown = board
        isPreviewStale = false
        guard let parts = BoardSnapshot.thumbnailParts(of: self) else {
            previewedBoard = shown
            document.update { $0.preview = nil }
            return
        }
        let picture = await Task.detached(priority: .utility) { parts.thumbnail() }.value
        // Changed meanwhile: the next pause draws it again.
        guard !isClosed, !Task.isCancelled, board == shown else { return }
        previewedBoard = shown
        document.update { $0.preview = picture }
    }

    /// True while any sketch is waiting to be read or being read.
    var isBusy: Bool {
        !effects.isEmpty || !inFlight.isEmpty || !unreadGroups(zoom: viewport.scale).isEmpty
    }

    // MARK: Selection

    /// The one element that is selected. Nil when several things are: see `selectedElements`.
    var selectedElement: (ref: DesignStore.ElementRef, element: DesignElement, placement: Placement)? {
        guard case .element(let ref) = selection, let found = store.resolve(ref) else { return nil }
        return (ref, found.element, found.placement)
    }

    /// The one screen that is selected. Nil when several things are.
    var selectedScreen: DesignScreen? {
        guard case .screen(let id) = selection else { return nil }
        return store.screen(id)
    }

    /// Everything selected, one thing at a time, in the design's own order.
    var selectedThings: [CanvasSelection] { store.things(in: selection) }

    /// Every element selected, alone or among other things, from the back to the front.
    var selectedElements: [(ref: DesignStore.ElementRef, element: DesignElement, placement: Placement)] {
        selectedThings.compactMap { thing in
            guard case .element(let ref) = thing, let found = store.resolve(ref) else { return nil }
            return (ref, found.element, found.placement)
        }
    }

    /// A tap that landed on the canvas itself rather than on an element's target: it picks
    /// the drawing, element or screen's name there, or, on a screen's empty area or empty
    /// canvas, clears the selection; see `pointTapped(at:picksAnyElement:)`.
    func canvasTapped(at viewPoint: CGPoint) {
        pointTapped(at: viewPoint, picksAnyElement: false)
    }

    /// A tap in the area that drags the selected element, at a point in the view: a selected
    /// drawing's box, or the selected element's with the palette up. It reaches what it would
    /// have reached with no area there: in Draw the canvas, as a finger's tap does when a
    /// finger doesn't draw; in Select whatever is drawn on top there, as the targets under
    /// the area would pick it. The area used to take the tap and do nothing (audit C12).
    func selectionAreaTapped(at viewPoint: CGPoint) {
        if tool == .draw {
            guard !fingerDraws else { return }
            canvasTapped(at: viewPoint)
        } else {
            pointTapped(at: viewPoint, picksAnyElement: true)
        }
    }

    /// The one rule for a tap at a point in the view that no element's target took.
    /// - Ink, or an element there, is picked: any element when `picksAnyElement`, and
    ///   otherwise a drawing, or any element with the palette up.
    /// - A screen's name strip, while names are shown, picks the screen, which adds it.
    /// - A screen's empty area clears the selection, or selects the screen when nothing is.
    ///   Tapped again quickly, after a tap selected the screen, it keeps the screen: that is
    ///   a double-tap, which never takes a thing out.
    /// - Empty canvas clears the selection.
    ///
    /// A tap that would clear but only just missed something selected does nothing.
    private func pointTapped(at viewPoint: CGPoint, picksAnyElement: Bool) {
        let point = viewport.canvasPoint(for: viewPoint)
        let target = hoverTarget(at: viewPoint)
        // With the palette up, a finger tap reaches the canvas for elements too: their own
        // handles stay out of the Pencil's way while it draws. A drawing has no handle
        // of its own until it is selected, so a tap on its ink always reaches here.
        if case .element(let ref)? = target, picksAnyElement || tool == .draw || store.resolve(ref)?.element.kind == .drawing {
            pick(target)
        } else if case .screen(let id)? = target, let screen = store.screen(id), !screen.canvasFrame.contains(point) {
            // `hoverTarget` gives the screen for its name strip as well as for itself.
            pick(.screen(id))
        } else if selection == nil, let screen = store.screen(at: point) {
            pick(.screen(screen.id))
        } else if let screen = store.screen(at: point), restingOnCanvas.isEmpty, isLiftOfRestedFinger(on: .screen(screen.id)) {
            // The finger that rested on the screen's empty area, lifting. What it rested
            // on was the screen, but the tap would reach `pick` as a clearing, which its
            // guard wouldn't know for the lift.
            rested = nil
        } else if let screen = store.screen(at: point), isSecondTap(on: .screen(screen.id)) {
            // A double-tap on the screen's empty area, whose first tap selected the screen:
            // a double-tap never takes a thing out.
            pick(.screen(screen.id))
        } else if !isNearMiss(viewPoint) {
            pick(nil)
        }
    }

    /// How far from a selected thing's outline, on either side, a tap that hits nothing
    /// only just missed it, in the view's points: on the glass, whatever the zoom.
    private static let nearMiss: CGFloat = 8

    /// Whether a point in the view is within `nearMiss` of the outline of something
    /// selected: a band along the edge, not the shape grown, so a tap well inside a selected
    /// screen's empty area isn't one. Selected drawings don't count: a tap inside a drawing's
    /// box reaches what lies under it (audit C12), and its ink is already picked with room
    /// to spare.
    private func isNearMiss(_ viewPoint: CGPoint) -> Bool {
        selectedThings.contains { thing in
            if case .element(let ref) = thing, store.resolve(ref)?.element.kind == .drawing { return false }
            guard let shape = store.canvasShape(of: thing).map(viewport.viewShape(for:)) else { return false }
            return Self.distance(from: viewPoint, toEdgeOf: shape) <= Self.nearMiss
        }
    }

    /// How far a point is from the edge of a turned box, from inside or out.
    private static func distance(from point: CGPoint, toEdgeOf shape: TurnedRect) -> CGFloat {
        // In the box's own unturned axes.
        let back = Rotation.rotate(point, about: shape.centre, by: -shape.degrees)
        let rect = shape.rect
        let outsideX = max(rect.minX - back.x, 0, back.x - rect.maxX)
        let outsideY = max(rect.minY - back.y, 0, back.y - rect.maxY)
        if outsideX > 0 || outsideY > 0 { return hypot(outsideX, outsideY) }
        return min(back.x - rect.minX, rect.maxX - back.x, back.y - rect.minY, rect.maxY - back.y)
    }

    /// A tap on the target of an element, a group or a screen's name, or on something among
    /// several selected, at a point in the view. Ink is drawn over every element and screen,
    /// so where a drawing's ink lies over the target the tap picks the drawing, as hover and
    /// a tap with the palette up do. On a group's target it is on the thing in the group
    /// under it, or on the group itself in a gap between them: both taps of a double-tap find
    /// the same one, and `pick` works out what it picks.
    func targetTapped(_ thing: CanvasSelection, at viewPoint: CGPoint) {
        if let drawing = inkTarget(at: viewPoint) {
            pick(.element(drawing))
        } else if case .element(let ref) = thing, store.groupItem(ref.element) != nil {
            pick(.element(store.leaf(at: viewport.canvasPoint(for: viewPoint), in: ref.element) ?? ref))
        } else {
            pick(thing)
        }
    }

    /// The drawing whose ink is at a point in the view. It lies over everything else and
    /// takes a touch there, even where an element's target is under it.
    func inkTarget(at viewPoint: CGPoint) -> DesignStore.ElementRef? {
        drawing(at: viewport.canvasPoint(for: viewPoint))
    }

    // MARK: Selecting several things

    /// Where fingers are resting on the canvas, in the view's points, not counting one
    /// that has just lifted. Supplied by the ink canvas, which sees every touch.
    @ObservationIgnored var restingFingers: () -> [CGPoint] = { [] }
    /// What the finger that rested during the last tap was on, so that its own lifting
    /// isn't taken for a tap; and when it lifted, once that is known.
    @ObservationIgnored private var rested: (on: CanvasSelection?, lifted: ContinuousClock.Instant?)?

    /// The time now, which tells a double-tap's second tap from a tap of its own. A test
    /// sets a clock of its own.
    @ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }
    /// How soon a second tap on the same thing makes a double-tap. It stands in for the
    /// system double-tap interval the spec names: iPadOS gives no public value for it to
    /// read (L4).
    static let doubleTapInterval: Duration = .milliseconds(350)
    /// The last tap that picked a thing: what it was on (a thing in a group, or a group's
    /// gap, before `pickTarget`), when, and the selection before and after it. A second tap
    /// on the same thing soon after, with nothing else changed meanwhile, is a double-tap.
    @ObservationIgnored private var lastTap: (thing: CanvasSelection, at: ContinuousClock.Instant, before: CanvasSelection?, after: CanvasSelection?)?

    /// Every group that holds something selected, at any depth: those that have been gone
    /// into. A tap picks what is inside them, one level at a time, and their members have
    /// targets of their own in place of theirs.
    var enteredGroups: Set<DesignElement.ID> {
        enteredGroups(in: selection)
    }

    private func enteredGroups(in selection: CanvasSelection?) -> Set<DesignElement.ID> {
        var entered: Set<DesignElement.ID> = []
        for case .element(let ref) in selection?.things ?? [] {
            entered.formUnion(store.groups(holding: ref).map(\.element))
        }
        return entered
    }

    /// What a tap on a thing picks as things are selected now: for something in a group,
    /// its outermost group that hasn't been gone into, or itself once all of them have; for
    /// anything else, itself. A tap, a drag and hover all go by it.
    func pickTarget(_ thing: CanvasSelection) -> CanvasSelection {
        guard case .element(let ref) = thing else { return thing }
        return .element(store.pickTarget(for: ref, entered: enteredGroups))
    }

    /// A tap picked something, or nothing when it landed on empty space, which clears the
    /// selection. What it picks is worked out by `pickTarget(_:)`: a thing in a group picks
    /// its outermost group first. That is added to what is selected, or taken out if it was:
    /// see `selection(afterTapOn:from:)`. With another finger resting on the canvas, as in
    /// Freeform, what a tap where the resting finger is would pick is selected with it.
    ///
    /// The first tap acts at once. A second on the same thing, soon after, is a double-tap,
    /// which goes one level in: see `selection(afterDoubleTapOn:from:)`. Each quick tap after
    /// that goes one level further in again.
    func pick(_ thing: CanvasSelection?) {
        let finger = restingOnCanvas.first
        var held: CanvasSelection?
        if let finger {
            held = hoverTarget(at: finger).map(pickTarget(_:))
            // A finger resting on a screen while its elements are tapped is only holding the
            // selection open: the screen isn't picked along with what is on it.
            if case .screen(let id) = held, case .element(let ref) = thing, ref.host == .screen(id) { held = nil }
            rested = (held, nil)
        } else {
            // Told by what a tap there picks, as what the finger held was.
            let isLift = isLiftOfRestedFinger(on: thing.map(pickTarget(_:)))
            rested = nil
            if isLift { return }
        }
        guard let thing else {
            lastTap = nil
            selectByTap(nil)
            return
        }
        let time = now()
        if isSecondTap(on: thing), let last = lastTap {
            let made = selection(afterDoubleTapOn: thing, from: last.before)
            // Read against what it made, a quick tap after it goes one level further in.
            lastTap = (thing, time, made, made)
            selectByTap(made)
            return
        }
        let target = pickTarget(thing)
        var seeded = selection
        if finger != nil {
            guard target != held else { return }
            // Resting on something that isn't selected starts again from it.
            if let held, seeded?.things.contains(held) != true { seeded = held }
        }
        let made = selection(afterTapOn: target, from: seeded)
        // What the tap started from, the thing a resting finger holds included.
        lastTap = (thing, time, seeded, made)
        selectByTap(made)
    }

    /// Whether a tap on a thing is the second of a double-tap: the last tap was on the same
    /// thing, not long before, and the selection is as it left it.
    private func isSecondTap(on thing: CanvasSelection) -> Bool {
        guard let lastTap, lastTap.thing == thing, lastTap.after == selection else { return false }
        return now() - lastTap.at < Self.doubleTapInterval
    }

    /// What a tap on one thing makes of a selection: the one rule for a tap, wherever it
    /// lands.
    /// - With nothing selected, the thing is selected.
    /// - A selected thing is taken out.
    /// - A thing on a selected screen, or in a selected group, takes the screen's or the
    ///   group's place: the same as going one level in.
    /// - Anything else is added. A screen added folds in its elements that were selected.
    private func selection(afterTapOn thing: CanvasSelection, from current: CanvasSelection?) -> CanvasSelection? {
        guard let current else { return thing }
        if current.contains(thing) { return current.removing(thing) }
        if case .element(let ref) = thing {
            var holders: [CanvasSelection] = store.groups(holding: ref).map { .element($0) }
            if case .screen(let id) = ref.host { holders.append(.screen(id)) }
            let selected = holders.filter(current.contains)
            if !selected.isEmpty {
                return CanvasSelection(current.things.subtracting(selected).union([thing]))
            }
        }
        return CanvasSelection(current.things.union([thing]))
    }

    /// What a double-tap on a thing makes of the selection as it was before its first tap:
    /// one level in from what that first tap picked from there, and never less than that
    /// selection.
    /// - A thing on a selected screen takes the screen's place with what a tap picks on it:
    ///   its outermost group, or itself.
    /// - Otherwise the double-tap picks one level in from what a tap would have: the group
    ///   just inside it on the way to the thing, or the thing itself. A selected group
    ///   holding that takes its place; otherwise it is added.
    /// - What is selected already stays selected: a double-tap never takes a thing out.
    private func selection(afterDoubleTapOn thing: CanvasSelection, from before: CanvasSelection?) -> CanvasSelection? {
        var target = thing
        if case .element(let leaf) = thing {
            let first = store.pickTarget(for: leaf, entered: enteredGroups(in: before))
            let isOnSelectedScreen = if case .screen(let id) = leaf.host { before?.contains(.screen(id)) == true } else { false }
            target = .element(isOnSelectedScreen ? first : store.nextLevel(in: first, towards: leaf))
        }
        if before?.contains(target) == true { return before }
        return selection(afterTapOn: target, from: before)
    }

    /// A tap changed the selection this many times: each change plays a selection tick.
    private(set) var tapSelectionChanges = 0

    /// Selects what a tap made of the selection, with a tick if it changed.
    private func selectByTap(_ new: CanvasSelection?) {
        guard new != selection else { return }
        selection = new
        tapSelectionChanges += 1
    }

    /// Where fingers are resting on the canvas itself, in the view's points: not on a panel
    /// or popover over it.
    private var restingOnCanvas: [CGPoint] {
        restingFingers().filter { finger in !chromeFrames.values.contains { $0.contains(finger) } }
    }

    /// Whether a tap on a thing, or on nothing, made with no finger resting, is only the
    /// finger that rested lifting: lifting, it reaches whatever it was on as a tap.
    private func isLiftOfRestedFinger(on thing: CanvasSelection?) -> Bool {
        guard let rested, rested.on == thing else { return false }
        return rested.lifted.map { ContinuousClock.now - $0 < .milliseconds(400) } ?? true
    }

    /// The last finger resting on the canvas has lifted.
    func fingersLifted() {
        rested?.lifted = .now
    }

    /// Selects what a loop drawn on the canvas goes round, in canvas points, and lets go
    /// of everything else.
    func select(enclosedBy loop: [CGPoint]) {
        selection = CanvasSelection(store.things(enclosedBy: loop))
    }

    /// The loop or box being drawn round things, while it is being drawn.
    private(set) var sweep: Sweep?

    /// The lasso has drawn this much of its loop, in the view's points. Nothing is
    /// picked until it is finished.
    func lassoDrawn(_ points: [CGPoint]) {
        sweep = .lasso(points)
    }

    /// A box is being dragged out between two corners, in the view's points. What it
    /// holds is selected as it grows.
    func boxDragged(from start: CGPoint, to end: CGPoint) {
        let box = Sweep.box(from: start, to: end)
        sweep = box
        let picked = CanvasSelection(store.things(enclosedBy: box.loop.map(viewport.canvasPoint(for:))))
        if selection != picked { selection = picked }
    }

    /// The loop or box is finished. A lasso's loop selects what it went round.
    func sweepEnded() {
        if case .lasso(let points) = sweep {
            select(enclosedBy: points.map(viewport.canvasPoint(for:)))
        }
        sweep = nil
    }

    /// The loop or box was given up, as when a second finger turns it into a pinch.
    func sweepCancelled() {
        sweep = nil
    }

    /// Lets go of one thing, leaving the rest of what is selected.
    func deselect(_ thing: CanvasSelection) {
        guard let selection, selection.contains(thing) else { return }
        self.selection = selection.removing(thing)
    }

    /// Makes one change to every selected element that `applies` to, as one step: a
    /// colour, for instance, to each that has a fill.
    func changeSelectedElements(where applies: (DesignElement) -> Bool = { _ in true }, _ body: (inout DesignElement) -> Void) {
        store.update(selectedElements.filter { applies($0.element) }.map(\.ref), body)
    }

    /// The elements selected that aren't locked, by themselves or by a group above them:
    /// what corners, opacity and angle change for several things (F4).
    var unlockedSelectedElements: [(ref: DesignStore.ElementRef, element: DesignElement, placement: Placement)] {
        selectedElements.filter { !store.isLocked(.element($0.ref)) }
    }

    /// Changes those of `refs` that `applies` to, in the Format panel's own edit (see
    /// `adjusting`): the elements a field was showing, even if it is set once the selection
    /// has moved on. With `unlockedOnly`, only those that aren't locked, by themselves or by
    /// a group above them (F4).
    func changeElements(_ refs: [DesignStore.ElementRef], unlockedOnly: Bool = false, where applies: (DesignElement) -> Bool, _ body: (inout DesignElement) -> Void) {
        adjusting {
            store.update(refs.filter { ref in
                guard let found = store.resolve(ref) else { return false }
                return (!unlockedOnly || !store.isLocked(.element(ref))) && applies(found.element)
            }, body)
        }
    }

    /// Gives every element selected to whatever it now lies on, after a drag. Several
    /// things being turned go on turning about the same pivot: an element given to another
    /// host is still the same thing, though the selection now names it differently.
    func rehostSelection() {
        guard let selection else { return }
        let session = turnSession.flatMap { $0.selection == selection && $0.matches(store) ? $0 : nil }
        // Moved to its new host, an element drops out of the selection until it is named again.
        isRehosting = true
        defer { isRehosting = false }
        let rehosted = store.rehost(selection)
        self.selection = rehosted
        // The new selection let go of the session as it was set; it is the same one.
        if let session, let rehosted { turnSession = session.rehosted(as: rehosted, in: store) }
    }

    /// Gives things a drag moved to whatever they now lie on, as the drag ends some way other
    /// than its finger lifting: SwiftUI cancelled it, the tool changed, a twist cut it short
    /// (see `CanvasDrags`). The selection goes on naming those of them it named, wherever they
    /// now are, and a turn of them under way goes on: they are still the same things.
    func rehost(_ things: [CanvasSelection]) {
        let selected = selection
        let session = turnSession.flatMap { $0.selection == selected && $0.matches(store) ? $0 : nil }
        // Moved to its new host, an element drops out of the selection until it is named again.
        isRehosting = true
        defer { isRehosting = false }
        var renamed: [CanvasSelection: CanvasSelection] = [:]
        // In the design's order, back to front: each lands on top of its new host's things, so
        // landed in any other order they would be stacked differently there (review I1).
        let inOrder = CanvasSelection(things).map { store.things(in: $0) } ?? []
        store.asOneStep {
            for case .element(let ref) in inOrder {
                let now = store.rehost(ref)
                if now != ref { renamed[.element(ref)] = .element(now) }
            }
        }
        guard let selected, selected.things.contains(where: { renamed[$0] != nil }) else { return }
        let rehosted = CanvasSelection(selected.things.map { renamed[$0] ?? $0 })
        selection = rehosted
        // The new selection let go of the session as it was set; it is the same one.
        if let session, let rehosted { turnSession = session.rehosted(as: rehosted, in: store) }
        if case .element(let ref, let degrees)? = turnStart, case .element(let now)? = renamed[.element(ref)] {
            turnStart = .element(now, degrees: degrees)
        }
    }

    /// True while `rehostSelection()` or `rehost(_:)` names what is selected afresh.
    @ObservationIgnored private var isRehosting = false

    /// The drawing with ink at a canvas point.
    private func drawing(at point: CGPoint) -> DesignStore.ElementRef? {
        ink?.drawing(at: point, tolerance: 14 / viewport.scale).map { .init(host: .canvas, element: $0) }
    }

    /// What Apple Pencil is hovering over: on the canvas, or in the layers list. It is
    /// outlined softly, short of being selected.
    var hovered: CanvasSelection?
    /// True while the hover comes from the layers list rather than the canvas.
    var isHoveringList = false

    /// The topmost element or screen at a point in the view, for hover, and for a tap or a
    /// resting finger that reaches the model. Only what is drawn there: a hidden element is
    /// looked through, as is a screen's name strip while names aren't shown. Each screen's
    /// things, and the open canvas's, are looked at as their targets lie
    /// (`DesignStore.targets(on:entered:)`): a group that hasn't been gone into is hit
    /// anywhere in its box, giving the thing in it there, or the group itself in a gap
    /// between them; `pickTarget(_:)` makes either what a tap picks.
    ///
    /// `skippingDrawings` looks through ink to what is beneath, for voice, which can't
    /// change a drawing; and through a group's gaps, so that voice sees elements, not groups.
    func hoverTarget(at viewPoint: CGPoint, skippingDrawings: Bool = false) -> CanvasSelection? {
        let point = viewport.canvasPoint(for: viewPoint)
        // Ink lies over everything else, and is picked by its strokes, not the box round them.
        // A hidden drawing's ink isn't on the canvas.
        if !skippingDrawings, let drawing = drawing(at: point) { return .element(drawing) }
        let targets = store.targetElements(entered: enteredGroups)
        if let hit = topmost(at: point, among: targets[.canvas] ?? [], on: .canvas, placement: nil, skippingDrawings: skippingDrawings) {
            return .element(hit)
        }
        let showsNames = store.canvas.showsFrameNames
        for screen in store.screens.reversed() {
            if let hit = topmost(at: point, among: targets[.screen(screen.id)] ?? [], on: .screen(screen.id), placement: screen.placement, skippingDrawings: skippingDrawings) {
                return .element(hit)
            }
            if screen.canvasFrame.contains(point) || (showsNames && screen.labelFrame.contains(point)) {
                return .screen(screen.id)
            }
        }
        return nil
    }

    /// The topmost of one host's targets, given back to front, that holds a canvas point: see
    /// `hoverTarget(at:skippingDrawings:)`. `placement` is the screen's; on the open canvas,
    /// where each thing has its own, it is nil.
    private func topmost(
        at point: CGPoint, among targets: [DesignElement], on host: DesignStore.ElementRef.Host,
        placement: Placement?, skippingDrawings: Bool
    ) -> DesignStore.ElementRef? {
        for element in targets.reversed() {
            let placement = placement ?? Placement(origin: .zero, scale: element.scale ?? 1)
            guard TurnedRect(rect: placement.canvasRect(for: element.frame), degrees: element.resolvedRotation).contains(point) else { continue }
            if element.kind == .group {
                if let leaf = store.leaf(at: point, in: element.id) { return leaf }
                if skippingDrawings { continue }
            } else if skippingDrawings, element.kind == .drawing {
                continue
            }
            return .init(host: host, element: element.id)
        }
        return nil
    }

    /// Where something is, in the view's own points: for a turned element, the box round
    /// its turned shape.
    func viewRect(of target: CanvasSelection) -> CGRect? {
        store.canvasFrame(of: target).map(viewport.viewRect(for:))
    }

    /// Whether what is selected is locked in place: all of it, when it is several things.
    var isSelectionLocked: Bool {
        selection.map(store.isLocked) ?? false
    }

    /// Locks or unlocks what is selected. Unlocking unlocks the locked groups above it too, in
    /// the same step: a thing locked only by its group would otherwise stay locked, and the
    /// button would do nothing (conflict D). A Layers row's toggle changes only its own flag.
    func setSelectionLocked(_ locked: Bool) {
        guard let selection else { return }
        if locked {
            store.setLocked(true, selection)
        } else {
            store.unlock(selection)
        }
    }

    var canDuplicateSelection: Bool { selection != nil }

    /// Whatever can be selected can be locked: elements, drawings among them, and screens.
    var canLockSelection: Bool { selection != nil }

    /// Copies what is selected and selects the copy, or the copies.
    func duplicateSelection() {
        guard let selection, let copies = store.duplicate(selection) else { return }
        self.selection = copies
    }

    /// Brings what is selected to the front or forward, or sends it backward or to the
    /// back: one thing, or several as one block among their siblings. See
    /// `DesignStore.arrange(_ selection:_:)`.
    func arrangeSelection(_ arrangement: DesignStore.Arrangement) {
        guard let selection else { return }
        store.arrange(selection, arrangement)
    }

    /// Whether arranging what is selected would change the order of anything.
    func canArrangeSelection(_ arrangement: DesignStore.Arrangement) -> Bool {
        selection.map { store.canArrange($0, arrangement) } ?? false
    }

    /// Puts what is selected in a new group and selects the group: see `DesignStore.group(_:)`.
    func groupSelection() {
        guard let selection, let group = store.group(selection) else { return }
        self.selection = .element(group)
    }

    /// Whether Group would make a group of what is selected (L7).
    var canGroupSelection: Bool {
        selection.map(store.canGroup) ?? false
    }

    /// Whether the elements selected are on more than one screen, or on a screen and the open
    /// canvas: why Group is off, when it is.
    var groupSelectionSpansHosts: Bool {
        Set(selectedElements.map(\.ref.host)).count > 1
    }

    /// Takes the selected group apart and selects its members: see `DesignStore.ungroup(_:)`.
    func ungroupSelection() {
        guard canUngroupSelection, case .element(let ref) = selection, let members = store.ungroup(ref) else { return }
        selection = members
    }

    /// Whether one group is selected, and it isn't locked.
    var canUngroupSelection: Bool {
        guard let selected = selectedElement else { return false }
        return selected.element.kind == .group && !store.isLocked(.element(selected.ref))
    }

    /// Lines up what is selected: one element with its screen, several things with each other.
    func alignSelection(_ alignment: ElementLayout.Alignment) {
        guard let selection, !isSelectionLocked else { return }
        switch selection {
        case .element(let ref): store.align(ref, alignment)
        case .several: store.align(selection, alignment)
        case .screen: break
        }
    }

    /// Spaces the selected things evenly, across or down. It takes three to have a gap to even out.
    func distributeSelection(_ distribution: ElementLayout.Distribution) {
        guard let selection, canDistributeSelection else { return }
        store.distribute(selection, distribution)
    }

    var canDistributeSelection: Bool {
        (selection?.things.count ?? 0) >= 3 && !isSelectionLocked
    }

    func toggleLockOfSelection() {
        setSelectionLocked(!isSelectionLocked)
    }

    /// Hides or shows an element. Hiding one lets go of it, since it can't be touched.
    func toggleHidden(_ ref: DesignStore.ElementRef) {
        store.update(ref) { $0.isHidden.toggle() }
        if store.resolve(ref)?.element.isHidden == true { deselect(.element(ref)) }
    }

    func toggleLock(_ ref: DesignStore.ElementRef) {
        store.update(ref) { $0.isLocked.toggle() }
    }

    /// Where what is selected is, in the view's own points: for a turned element, the box
    /// round its turned shape; for several things, the box round the outline they turn
    /// within, which covers them all. When it can turn, the knob's touch target is
    /// included, so that the popover, which places itself against this, never covers the knob.
    var selectionViewRect: CGRect? {
        let area: CGRect?
        switch selection {
        case .element, .several:
            area = selectionShape.map { viewport.viewShape(for: $0).bounds }
        case .screen:
            area = selectedScreen.map { viewport.viewRect(for: $0.canvasFrame.union($0.labelFrame)) }
        case nil:
            return nil
        }
        guard let area, let knob = knobViewPoint else { return area }
        let reach = Self.knobTarget / 2
        return area.union(CGRect(x: knob.x - reach, y: knob.y - reach, width: Self.knobTarget, height: Self.knobTarget))
    }

    // MARK: Turning

    /// Whether what is selected can be turned: something is, no screen is among it, and
    /// at least one element of it isn't locked, by itself or by a group above it (F4).
    var canTurnSelection: Bool {
        var hasUnlocked = false
        for thing in selectedThings {
            // Screens never turn.
            guard case .element(let ref) = thing else { return false }
            if store.resolve(ref) != nil, !store.isLocked(thing) { hasUnlocked = true }
        }
        return hasUnlocked
    }

    /// True from `beginTurn()` to `endTurn()`, while the knob or two fingers turn the selection.
    private(set) var isTurning = false
    /// The angle a turn has snapped to, while it is held there; nil between the 45s. A
    /// tick plays as it snaps. Nil, too, while it is held at the mark it started on, until
    /// it has left it: taking hold of an upright element is no snap.
    private(set) var snappedTurn: Double?
    /// The mark the turn under way started on, until it leaves it.
    @ObservationIgnored private var startMark: Double?

    /// What the turn under way turns, and how far it was turned when the turn began.
    private enum TurnStart {
        /// One element, and its angle.
        case element(DesignStore.ElementRef, degrees: Double)
        /// Several things, and how far their session had turned them.
        case several(turned: Double)
    }
    @ObservationIgnored private var turnStart: TurnStart?
    /// Several things selected, as their last turn or move left them: see `severalTurn`.
    @ObservationIgnored private var turnSession: TurnSession?
    /// That session as it was when the drag moving them began, if it held then.
    @ObservationIgnored private var moveStart: TurnSession?

    /// The one element selected, unless it is locked, by itself or by a group above it, or is
    /// a group, which turns as several things do: what a turn turns.
    private var turnableElement: (ref: DesignStore.ElementRef, element: DesignElement)? {
        guard let selected = selectedElement, selected.element.kind != .group, !store.isLocked(.element(selected.ref)) else { return nil }
        return (selected.ref, selected.element)
    }

    /// Whether what is selected is one group, which turns as one rigid piece of several
    /// things: its members, and the groups in it, go round its middle with it.
    private var selectsOneGroup: Bool {
        selectedElement?.element.kind == .group
    }

    /// What turns several things selected, or one group: the session kept from their last
    /// turn or move, while it is for what is selected and each of them is as it left them;
    /// otherwise one formed from where they are now. Reading it keeps nothing. Nil unless
    /// several things or a group are selected, or when a screen is among them.
    private var severalTurn: TurnSession? {
        guard let selection, selection.isSeveral || selectsOneGroup else { return nil }
        if let turnSession, turnSession.selection == selection, turnSession.matches(store) { return turnSession }
        return TurnSession.form(for: selection, in: store)
    }

    /// Starts turning what is selected. Everything until `endTurn()` undoes as one step.
    /// Returns whether a turn began: none does while another is under way, or when what
    /// is selected can't turn.
    @discardableResult
    func beginTurn(cuttingDragShort: Bool = false) -> Bool {
        guard !isTurning, canTurnSelection else { return false }
        let start: Double
        if let turnable = turnableElement {
            turnStart = .element(turnable.ref, degrees: turnable.element.resolvedRotation)
            start = turnable.element.resolvedRotation
        } else if let session = severalTurn {
            turnSession = session
            turnStart = .several(turned: session.turned)
            start = session.outline.degrees + session.turned
        } else {
            return false
        }
        let (mark, isOnMark) = Rotation.snapped(start)
        startMark = isOnMark ? mark : nil
        // The turn's own step: a drag, a command or a screen being generated that is under
        // way, or that begins or ends meanwhile, has its own, and neither ends the other.
        // A drag the turn cuts short goes on as the turn, one step with it.
        let drag = cuttingDragShort ? drags?.handOverEdit() : nil
        turnEdit = store.beginEdit(by: .turn, takingOver: drag)
        if let drag, drag === turnEdit {
            store.rename(turnEdit, String(localized: "Move and Rotate"))
        } else {
            store.name(turnEdit, String(localized: "Rotate"))
        }
        isAdjusting = true
        isTurning = true
        return true
    }

    /// Turns what is selected `degrees` clockwise from the angle it had when the turn
    /// began: the whole turn so far, not the latest step of it. With `snaps`, an angle
    /// close to a multiple of 45° goes to it. Returns whether it did. Several things turn
    /// as one about their pivot, and it is their outline's angle that snaps.
    @discardableResult
    func turnSelection(by degrees: Double, snaps: Bool) -> Bool {
        let snapped: Double?
        switch turnStart {
        case .element(let ref, let start)?:
            guard selection == .element(ref) else { return false }
            let (angle, isSnapped) = snaps ? Rotation.snapped(start + degrees) : (Rotation.normalized(start + degrees), false)
            store.act(for: turnEdit) { store.update(ref) { $0.setRotation(angle) } }
            snapped = isSnapped ? angle : nil
        case .several(let start)?:
            // Changed by something else meanwhile, they are left as that left them.
            guard var session = turnSession, session.selection == selection, session.matches(store) else { return false }
            var turned = Rotation.normalized(start + degrees)
            let (angle, isSnapped) = snaps ? Rotation.snapped(session.outline.degrees + turned) : (0, false)
            if isSnapped { turned = Rotation.normalized(angle - session.outline.degrees) }
            store.act(for: turnEdit) { turn(&session, to: turned) }
            snapped = isSnapped ? angle : nil
        case nil:
            return false
        }
        // Held at the mark it started on, it hasn't snapped to it: no tick until it has left.
        var shown = snapped
        if let mark = startMark {
            if snapped == mark { shown = nil } else { startMark = nil }
        }
        if snappedTurn != shown { snappedTurn = shown }
        return snapped != nil
    }

    /// Ends the turn and its own step, and nothing else under way. Does nothing when no
    /// turn began.
    func endTurn() {
        guard isTurning else { return }
        turnStart = nil
        isTurning = false
        isTwisting = false
        // A drag still under way, another finger's, is still adjusting the selection (C9).
        isAdjusting = drags?.isDragging ?? false
        snappedTurn = nil
        startMark = nil
        if let turnEdit { store.endEdit(turnEdit) }
        turnEdit = nil
    }

    /// The turn under way's own step.
    @ObservationIgnored private var turnEdit: DesignStore.Edit?

    // MARK: Twisting with two fingers

    /// True from `beginTwist()` until its turn ends: two fingers are turning what is
    /// selected. A drag either of them makes meanwhile is left alone (see `CanvasDrags`).
    @ObservationIgnored private(set) var isTwisting = false

    /// Two fingers on the selection have turned before they pinched: their turn begins. A
    /// drag the first finger was already making is ended after the turn has begun, so that
    /// its move so far is part of the turn's step, and the rest of it is left alone.
    /// Returns whether the turn began: not while another, the knob's, is under way, nor
    /// when what is selected can't turn.
    @discardableResult
    func beginTwist() -> Bool {
        guard beginTurn(cuttingDragShort: true) else { return false }
        isTwisting = true
        drags?.endAny(model: self)
        return true
    }

    /// Turns what is selected as far as the two fingers have turned since they landed,
    /// snapping to the 45s. Only a turn the twist began.
    func twist(by degrees: Double) {
        guard isTwisting else { return }
        turnSelection(by: degrees, snaps: true)
    }

    /// A finger lifted, or the twist was cancelled: its turn ends. A turn the twist didn't
    /// begin is left alone.
    func endTwist() {
        guard isTwisting else { return }
        endTurn()
    }

    /// Whether a point in the view is on what is selected, for a finger that would twist
    /// it: within 8 points of its turned shape, so that a finger landing just off its edge
    /// counts, and not on a control floating over it.
    func isOnSelection(_ viewPoint: CGPoint) -> Bool {
        guard let canvas = selectionShape, !chromeFrames.values.contains(where: { $0.contains(viewPoint) }) else { return false }
        let shape = viewport.viewShape(for: canvas)
        return TurnedRect(rect: shape.rect.insetBy(dx: -8, dy: -8), degrees: shape.degrees).contains(viewPoint)
    }

    /// Turns what is selected `degrees` clockwise in one step, without snapping.
    func rotateSelection(by degrees: Double) {
        if let turnable = turnableElement {
            store.update(turnable.ref) { $0.setRotation($0.resolvedRotation + degrees) }
        } else if canTurnSelection, var session = severalTurn {
            turn(&session, to: Rotation.normalized(session.turned + degrees))
        }
    }

    /// Stands what is selected upright again, in one step. Several things go back exactly
    /// to where they were, and to the angles they had, when they were selected. A group is
    /// turned about its middle until it is upright, everything in it going round with it.
    func resetSelectionTurn() {
        if let turnable = turnableElement {
            store.update(turnable.ref) { $0.setRotation(0) }
        } else if canTurnSelection, var session = severalTurn {
            turn(&session, to: selectsOneGroup ? Rotation.normalized(-session.outline.degrees) : 0)
        }
    }

    /// VoiceOver's "Reset rotation": the knob's double tap, except for several things not
    /// turned together since they were selected, where that has nothing to put back. Each of
    /// them is then stood upright about its own centre, in one step, as the Rotation field
    /// set to 0 does: an action that did nothing would read as broken.
    func resetSelectionRotation() {
        if case .several = selection, canTurnSelection, let session = severalTurn, Rotation.kept(session.turned) == nil {
            store.update(unlockedSelectedElements.map(\.ref)) { $0.setRotation(0) }
        } else {
            resetSelectionTurn()
        }
    }

    /// Puts several things where their session turned `degrees` places them, as one change,
    /// and keeps the session. A group's angle is written in the same change as its members'
    /// places, so that its box, fitted round them at the end of it, goes round as one with
    /// them: a group selected alone has the outline's angle.
    private func turn(_ session: inout TurnSession, to degrees: Double) {
        session.turned = degrees
        let placed = session.placed(turnedBy: degrees)
        store.apply { content in
            for (ref, place) in placed {
                content.update(ref.element) {
                    if $0.kind != .group { $0.frame = place.frame }
                    $0.rotation = place.rotation
                }
            }
        }
        session.expect(store)
        turnSession = session
    }

    /// How far what is selected is turned, for the readout beside the knob: one element's
    /// angle, a group's among them, or how far several things have turned since they were
    /// selected.
    var selectionTurn: Double? {
        if case .several = selection { return severalTurn.map { Rotation.normalized($0.turned) } }
        return selectedElement?.element.resolvedRotation
    }

    /// The shape of what is selected, in canvas points, turned as it is. For several
    /// things, or a group, the outline they turn within (`TurnSession.shape`), which goes
    /// round rigidly with them; with a screen among several, the upright box round them all.
    var selectionShape: TurnedRect? {
        guard let selection else { return nil }
        guard selection.isSeveral || selectsOneGroup else { return store.canvasShape(of: selection) }
        if let session = severalTurn { return session.shape }
        guard selection.isSeveral else { return store.canvasShape(of: selection) }
        return store.canvasFrame(of: selection).map { TurnedRect(rect: $0, degrees: 0) }
    }

    /// How far the knob hangs below the selection's bottom edge, to its centre, in the
    /// view's points: the same reach at any zoom.
    static let knobStem: CGFloat = 28
    /// The size of the knob's touch target, in the view's points.
    static let knobTarget: CGFloat = 44

    /// Where the knob is in the view: below the middle of the selection's bottom edge, in
    /// its own axes, so that it goes round as the selection turns. Nil when what is
    /// selected can't turn.
    var knobViewPoint: CGPoint? {
        guard canTurnSelection, let canvas = selectionShape else { return nil }
        let shape = viewport.viewShape(for: canvas)
        let reach = shape.rect.height / 2 + Self.knobStem
        return CGPoint(x: shape.centre.x + shape.down.dx * reach, y: shape.centre.y + shape.down.dy * reach)
    }

    /// Several things selected are about to be dragged. If they are as their last turn
    /// left them, their pivot goes with them: see `selectionMoved(by:)`.
    func selectionWillMove() {
        moveStart = nil
        guard let turnSession, turnSession.selection == selection, turnSession.matches(store) else { return }
        moveStart = turnSession
    }

    /// Several things selected have been dragged `canvasDelta` across the canvas in all
    /// since `selectionWillMove()`. Their pivot, their outline and where each started go
    /// with them, so that turned back they land where they were dragged to. Called as the
    /// drag goes, so that their outline goes rigidly with them.
    func selectionMoved(by canvasDelta: CGSize) {
        guard var session = moveStart, session.selection == selection else { return }
        session.translate(by: canvasDelta)
        session.expect(store)
        turnSession = session
    }

    /// Deletes what is selected. Of several things, those that are locked are left.
    func deleteSelection() {
        guard let selection, !isSelectionLocked else { return }
        store.delete(selection)
        self.selection = nil
    }

    private func dropSelectionOfMissingThings() {
        if let selection {
            let present = selection.things.filter { thing in
                switch thing {
                case .element(let ref): store.resolve(ref) != nil
                case .screen(let id): store.screen(id) != nil
                case .several: false
                }
            }
            if present.count != selection.things.count { self.selection = CanvasSelection(present) }
        }
        // Taking an offer lays the element out again from its sketch: once it, or its
        // screen, has been moved, resized or turned, that would undo the move.
        if suggestion != nil, suggestedPlace != suggestion.flatMap(place(of:)) { dismissSuggestion() }
    }

    /// Where a suggestion's element is: its frame and turn, and where its screen is.
    private struct SuggestedPlace: Equatable {
        var frame: CGRect
        var rotation: Double
        var placement: Placement
    }

    private func place(of suggestion: KindSuggestion) -> SuggestedPlace? {
        store.resolve(suggestion.ref).map { SuggestedPlace(frame: $0.element.frame, rotation: $0.element.resolvedRotation, placement: $0.placement) }
    }

    // MARK: Did you mean

    /// What the last close call nearly was, while that is on offer.
    private(set) var suggestion: KindSuggestion?
    @ObservationIgnored private var suggestionExpiry: Task<Void, Never>?
    /// Where the suggestion's element was when it was offered.
    @ObservationIgnored private var suggestedPlace: SuggestedPlace?
    /// How long a suggestion stays up when it is left alone.
    static let suggestionLifetime: Duration = .seconds(8)

    /// Offers to make what a sketch became into what it nearly was. One offer shows at a
    /// time, and goes by itself after a while.
    func offer(_ suggestion: KindSuggestion) {
        suggestionExpiry?.cancel()
        suggestedPlace = place(of: suggestion)
        self.suggestion = suggestion
        suggestionExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.suggestionLifetime)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) { self?.dismissSuggestion() }
        }
    }

    /// Makes the element what was suggested, as one undo step, and notes the correction
    /// against the reading it corrects.
    func acceptSuggestion() {
        guard let suggestion else { return }
        dismissSuggestion()
        let changed = store.changeKind(of: suggestion.ref, to: suggestion.kind, sketchedAt: suggestion.sketch) {
            $0.adoptMarks(of: suggestion.observation)
        }
        guard changed != nil else { return }
        Task { await SketchReadingLog.shared.noteCorrected(suggestion.ref.element, to: suggestion.kind.rawValue) }
    }

    func dismissSuggestion() {
        suggestionExpiry?.cancel()
        suggestionExpiry = nil
        suggestion = nil
        suggestedPlace = nil
    }

    /// True while a number field is being scrubbed.
    @ObservationIgnored private var isScrubbing = false

    /// Starts scrubbing a field. Everything until `endScrubbing()` undoes as one step,
    /// together with a run of changes in the format panel just before it.
    func beginScrubbing() {
        adjustmentEnd?.cancel()
        isScrubbing = true
        beginAdjustment()
    }

    func endScrubbing() {
        isScrubbing = false
        if let adjustment { store.endEdit(adjustment) }
        adjustment = nil
    }

    /// How long the format panel waits after its last change before ending its step.
    @ObservationIgnored var adjustmentPause: Duration = .milliseconds(600)

    /// The format panel's own edit: its run of quick changes, or a scrub. Its pause, or the
    /// scrub's end, ends it and nothing else: a drag, a stroke, a turn or a spoken command
    /// under way meanwhile has its own, which the panel's end leaves open, and theirs leave
    /// the panel's open.
    @ObservationIgnored private var adjustment: DesignStore.Edit?

    /// Makes a run of quick changes, such as dragging a slider or a colour, one undo step.
    /// Only the panel's own: what else is done meanwhile, a delete or a lock, is a step of its
    /// own, and so is a change made once the selection has changed (M14).
    func adjusting(_ body: () -> Void) {
        beginAdjustment()
        store.act(for: adjustment, body)
        // A scrub ends its own edit when it ends.
        guard !isScrubbing else { return }
        adjustmentEnd?.cancel()
        adjustmentEnd = Task { [weak self] in
            try? await Task.sleep(for: self?.adjustmentPause ?? .zero)
            guard !Task.isCancelled, let self else { return }
            if let adjustment { store.endEdit(adjustment) }
            adjustment = nil
        }
    }

    /// Opens the panel's own edit, unless it is open already.
    private func beginAdjustment() {
        guard adjustment?.isOpen != true else { return }
        adjustment = store.beginEdit(takingOnlyItsOwn: true)
        store.name(adjustment, String(localized: "Format"))
    }

    /// Ends the panel's run of changes now rather than at its pause: the panel is for another
    /// selection. A scrub under way ends its own as it ends.
    private func endAdjustmentNow() {
        guard !isScrubbing, let adjustment else { return }
        adjustmentEnd?.cancel()
        adjustmentEnd = nil
        store.endEdit(adjustment)
        self.adjustment = nil
    }

    // MARK: Adding things

    /// The canvas point in the middle of the view.
    private var middleOfView: CGPoint {
        viewport.canvasPoint(for: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    /// Puts a new element in the middle of the view, or centred on `point` in canvas
    /// points, selected and ready to be dragged. Over a screen it joins the screen, kept
    /// inside its edges.
    @discardableResult
    private func add(_ element: DesignElement, at point: CGPoint? = nil) -> DesignStore.ElementRef {
        var center = point ?? middleOfView
        if element.kind.belongsOnScreens, let screen = store.screens.last(where: { $0.canvasFrame.contains(center) }) {
            var local = screen.placement.localPoint(for: center)
            let half = CGSize(width: element.frame.width / 2, height: element.frame.height / 2)
            if half.width * 2 <= screen.size.width { local.x = min(max(local.x, half.width), screen.size.width - half.width) }
            if half.height * 2 <= screen.size.height { local.y = min(max(local.y, half.height), screen.size.height - half.height) }
            center = screen.placement.canvasPoint(for: local)
        }
        let ref = store.place(element, centeredAt: center)
        tool = .select
        selection = .element(ref)
        return ref
    }

    /// Puts something from the library on the canvas: in the middle of the view, or where
    /// it was dropped, `viewPoint` being in the canvas view's own points.
    func addAsset(_ asset: Asset, at viewPoint: CGPoint? = nil) {
        let point = viewPoint.map { viewport.canvasPoint(for: $0) }
        AssetLibrary.noteUsed(asset, in: settings)
        switch asset.content {
        case .symbol(let name):
            add(DesignStore.newElement(.symbol, symbol: name), at: point)
        case .shape(let kind, let filled):
            var element = DesignStore.newElement(.shape)
            element.shape = kind
            element.frame.size = kind.size
            element.isOn = filled
            add(element, at: point)
        case .component(let id):
            guard let element = AssetLibrary.element(forComponent: id) else { return }
            add(element, at: point)
            if element.kind == .stickyNote { isEditingText = true }
        case .frame(let id):
            guard let device = DeviceFrame.all.first(where: { $0.id == id }) else { return }
            addFrame(device, centeredAt: point)
        case .template(let name):
            addTemplate(name, centeredAt: point)
        }
    }

    /// Adds a ready-made screen from the library, laid out on the design's usual device,
    /// as one undo step.
    func addTemplate(_ name: String, centeredAt point: CGPoint? = nil) {
        guard let blueprint = AssetLibrary.template(named: name) else { return }
        let device = store.canvas.sketchDevice
        // Its own step even in the middle of a drag, which it leaves open (M3).
        store.asOwnStep {
            let screen = addFrame(device, centeredAt: point)
            store.updateScreen(screen.id) { $0.name = name }
            _ = store.setElements(blueprint.layout(on: device), on: screen.id, replacing: true)
        }
    }

    func addSymbol(_ name: String) {
        add(DesignStore.newElement(.symbol, symbol: name))
    }

    /// Adds a piece of text and opens it for typing.
    func addText() {
        add(DesignStore.newElement(.text))
        isEditingText = true
        suggestTitleIfNeeded()
    }

    func addStickyNote() {
        add(DesignStore.newElement(.stickyNote))
        isEditingText = true
    }

    /// Adds a picture, drawn no wider than most of a phone screen.
    func addImage(_ prepared: ImageImport.Prepared) {
        let id = images.add(prepared)
        document.update { $0.images[id.uuidString] = prepared.data }
        var element = DesignStore.newElement(.image)
        let width = min(prepared.image.size.width, 280)
        element.frame.size = CGSize(width: width.rounded(), height: (width * prepared.image.size.height / max(prepared.image.size.width, 1)).rounded())
        element.imageID = id
        add(element)
    }

    /// Adds a device frame in the middle of the view, or centred on `point` in canvas
    /// points, sized to fit comfortably in the view.
    @discardableResult
    func addFrame(_ device: DeviceFrame, centeredAt point: CGPoint? = nil) -> DesignScreen {
        let room = (canvasSize.height - 220) / viewport.scale
        let scale = min(max((room / device.size.height * 100).rounded() / 100, 0.15), 1)
        let size = CGSize(width: device.size.width * scale, height: device.size.height * scale)
        let middle = point ?? middleOfView
        let origin = CGPoint(x: (middle.x - size.width / 2).rounded(), y: (middle.y - size.height / 2).rounded())
        let screen = store.addScreen(device, at: Placement(origin: origin, scale: scale))
        tool = .select
        // A new frame comes in unselected.
        selection = nil
        suggestTitleIfNeeded()
        return screen
    }

    /// Names the board once, the first time it has something on it worth naming.
    private func suggestTitleIfNeeded() {
        guard suggestsTitle, store.title == nil, !hasBeenNamed, titleSuggestion == nil else { return }
        titleSuggestion = Task { [weak self] in
            guard let self else { return }
            let title = await engine.suggestTitle(for: store.content)
            if store.title == nil, !hasBeenNamed, !isClosed { store.setTitle(title, undoable: false) }
            titleSuggestion = nil
        }
    }

    // MARK: Ink events

    /// The ink drawn with PencilKit's own tools changed: the design's drawings change to
    /// match. This is the step undo takes back, for ink as for anything else.
    func inkChanged(_ changes: DrawingSync.Changes) {
        guard !changes.isEmpty else { return }
        store.apply { changes.apply(to: &$0) }
    }

    /// The Magic Pen's ink changed.
    func sketchChanged(_ strokes: [SketchStroke]) {
        self.strokes = strokes
        hasSketch = !strokes.isEmpty
        let present = Set(strokes.map(\.key))
        rejected = rejected.filter { $0.isSubset(of: present) }
        scheduleConversion()
    }

    func penDown() {
        isPenDown = true
        settle?.cancel()
    }

    func penUp() {
        isPenDown = false
        scheduleConversion()
    }

    // MARK: Conversion

    /// Reads every sketch on the canvas that hasn't been read yet, without waiting for a pause.
    func convertNow() {
        settle?.cancel()
        let zoom = viewport.scale
        for group in unreadGroups(zoom: zoom) {
            inFlight.formUnion(group.map(\.key))
            let conversion = Task { [weak self] () -> Void in await self?.convert(group, zoom: zoom) }
            conversions.append(conversion)
            Task { [weak self] in
                await conversion.value
                self?.conversions.removeAll { $0 == conversion }
            }
        }
    }

    /// Reads the selected drawing as a sketch, told what `prompt` says of it, and puts what
    /// it means in its place. The drawing stays if it can't be read as anything.
    func convertSelection(prompt: String) {
        guard let selected = selectedElement, selected.element.kind == .drawing else { return }
        let strokes = selected.element.sketchStrokes
        guard !strokes.isEmpty else { return }
        selection = nil
        let zoom = viewport.scale
        let conversion = Task { [weak self] () -> Void in
            guard let self else { return }
            await convert(onScreen(strokes, zoom: zoom), zoom: zoom, drawing: selected.ref, prompt: prompt)
        }
        conversions.append(conversion)
        Task { [weak self] in
            await conversion.value
            self?.conversions.removeAll { $0 == conversion }
        }
    }

    /// Waits until every sketch that is being read has been placed, or `limit` passes. For
    /// actions that draw and then report what the drawing became.
    func waitForConversions(limit: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now + limit
        // Give a conversion just started time to register before checking it has settled.
        try? await Task.sleep(for: .milliseconds(300))
        while isBusy || !conversions.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Throws away all Magic Pen ink that hasn't become anything.
    func discardSketch() {
        settle?.cancel()
        ink?.clearSketch()
    }

    private func scheduleConversion() {
        settle?.cancel()
        guard convertsAutomatically, tool == .draw, !isPenDown, !unreadGroups(zoom: viewport.scale).isEmpty else { return }
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.convertNow()
        }
    }

    /// The sketch strokes as they appear on screen at a zoom. Sketches are read at this
    /// size, so what a shape means doesn't depend on how far the canvas was zoomed when
    /// it was drawn.
    private func onScreen(_ strokes: [SketchStroke], zoom: CGFloat) -> [SketchStroke] {
        strokes.map { stroke in
            SketchStroke(key: stroke.key, points: stroke.points.map { CGPoint(x: $0.x * zoom, y: $0.y * zoom) })
        }
    }

    private func unreadGroups(zoom: CGFloat) -> [[SketchStroke]] {
        SketchAnalyzer.cluster(onScreen(strokes.filter { !inFlight.contains($0.key) }, zoom: zoom))
            .filter { !rejected.contains(Set($0.map(\.key))) }
    }

    /// Reads one sketch, given at its on-screen size, and puts what it means on the canvas.
    /// A Magic Pen sketch is read on its own; `drawing` is set instead for a drawing
    /// that was selected and asked to be read, with the `prompt` typed for it.
    private func convert(_ group: [SketchStroke], zoom: CGFloat, drawing: DesignStore.ElementRef? = nil, prompt: String? = nil) async {
        let keys = Set(group.map(\.key))
        let isDrawing = drawing != nil
        defer { if !isDrawing { inFlight.subtract(keys) } }
        guard let observation = SketchAnalyzer.observe(group) else {
            if !isDrawing { reject(keys) }
            return
        }

        // Back to canvas points for everything that is placed or drawn.
        let bounds = observation.bounds.applying(CGAffineTransform(scaleX: 1 / zoom, y: 1 / zoom))
        let canvasStrokes = group.map { $0.points.map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) } }

        let host = store.screen(under: bounds)
        let placement: SketchPlacement = if let host {
            .onScreen(
                local: host.localRect(for: bounds),
                existing: host.elements.map { ExistingElement(kind: $0.kind, frame: $0.frame) },
                size: host.size
            )
        } else {
            .openCanvas
        }
        let request = SketchRequest(observation: observation, placement: placement, strokes: group.map(\.points), prompt: prompt)

        var band: CGRect?
        if let host, !observation.form.isEnclosure, request.candidates != [.scratchOut] {
            band = CGRect(x: host.canvasFrame.minX, y: bounds.midY, width: host.canvasFrame.width, height: 0)
        }
        let effect = RetraceEffect(strokes: canvasStrokes, band: band)
        withAnimation(.easeOut(duration: 0.2)) { effects.append(effect) }

        // Let the re-trace play out even when the reading comes back at once.
        async let minimum: Void? = try? Task.sleep(for: .milliseconds(750))
        let outcome = await engine.outcome(for: request)
        let reading = outcome.reading
        // Stage 0 instrumentation (reports/Fast and slow sketch recognition.md): if this
        // reading became an element below, linking it here lets a deletion or a change of
        // kind soon after be recognised as a correction of this specific reading.
        let readingLogID = outcome.logID
        // Stage 2: a word PencilKit's handwriting recognizer read out of these same
        // strokes, such as "Sign in" inside a box, which becomes the element's label below.
        let recognizedText = outcome.recognizedText
        _ = await minimum
        // Closed while the sketch was being read: nothing is put on a design that has gone.
        guard !isClosed, !Task.isCancelled else {
            effects.removeAll { $0.id == effect.id }
            return
        }

        withAnimation(.smooth(duration: 0.45)) {
            effects.removeAll { $0.id == effect.id }
            // What a sketch becomes, with the words written in it, is one undo step of its own,
            // and a drawing changes places with it in that step: made in one turn of the run
            // loop but not for an edit, they were two steps, and the first undo only put the
            // placeholder back (review N-1). A drag under way meanwhile keeps its own (M3).
            let conversion = store.beginEdit(by: .app)
            defer { store.endEdit(conversion) }
            store.act(for: conversion) {
                var converted = false
                var added: DesignStore.ElementRef?
                switch reading {
                case .screen:
                    _ = store.addScreen(from: bounds)
                    converted = true
                case .element(let kind):
                    if let host {
                        if let element = store.addElement(kind, from: bounds, to: host.id, adjust: { $0.adoptMarks(of: observation) }) {
                            converted = true
                            added = .init(host: .screen(host.id), element: element.id)
                        }
                    } else if !kind.belongsOnScreens || kind == .text {
                        added = store.addFloating(kind, from: bounds)
                        converted = true
                    }
                    if let added, let readingLogID {
                        Task { await SketchReadingLog.shared.link(element: added.element, toEntry: readingLogID) }
                    }
                    if let added, let recognizedText, store.resolve(added)?.element.kind.hasText == true {
                        store.update(added) { $0.text = recognizedText }
                    }
                    // A close call says what else it nearly was, in case that is what was meant.
                    if let added, host != nil, case .element(let other)? = outcome.alternative, other != kind {
                        offer(KindSuggestion(ref: added, kind: other, sketch: bounds, observation: observation))
                    }
                case .scratchOut, .unknown:
                    // A scribble deletes nothing: scratching out is no longer a way to delete.
                    break
                }
                // Words the prompt gave for the element go on it, and a drawing read on request
                // ends with what it became selected.
                if let added, isDrawing {
                    if let label = prompt.flatMap(SketchPrompt.label(in:)), store.resolve(added)?.element.kind.hasText == true {
                        store.update(added) { $0.text = label }
                    }
                    selection = .element(added)
                }
                if converted {
                    if let drawing { store.delete(drawing) } else { ink?.removeSketch(keys) }
                    if reading != .scratchOut { suggestTitleIfNeeded() }
                } else if !isDrawing {
                    reject(keys)
                }
            }
        }
    }

    // MARK: Sketches that meant nothing

    private func reject(_ keys: Set<Double>) {
        rejected.insert(keys)
        Task { [weak self] in
            // Long enough to add the strokes that would complete a half-drawn shape. Not for
            // ever, though, should the pen's end never be heard.
            var waited = 0
            repeat {
                try? await Task.sleep(for: .seconds(4))
                waited += 4
            } while self?.isPenDown == true && waited < 30
            self?.dissolve(keys)
        }
    }

    /// Fades a rejected sketch away, unless it has changed since it was rejected.
    private func dissolve(_ keys: Set<Double>) {
        let groups = SketchAnalyzer.cluster(onScreen(strokes, zoom: viewport.scale))
        guard rejected.contains(keys), groups.contains(where: { Set($0.map(\.key)) == keys }) else { return }
        let ghost = InkGhost(strokes: strokes.filter { keys.contains($0.key) }.map(\.points))
        ghosts.append(ghost)
        ink?.removeSketch(keys)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.ghosts.removeAll { $0.id == ghost.id }
        }
    }
}
