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
            if let previousID, previousID != designID { DesignIndexer.forget(design: previousID) }
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
            drags?.endAny(model: self)
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
            if selection != oldValue { isEditingText = false }
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
    var convertsAutomatically = AppModel.savedConvertsAutomatically {
        didSet {
            UserDefaults.standard.set(convertsAutomatically, forKey: AppModel.convertsAutomaticallyKey)
            scheduleConversion()
        }
    }
    /// Whether a zigzag scrubbed over an element with the Magic Pen deletes it.
    /// Remembered between launches.
    var scratchOutDeletes = UserDefaults.standard.object(forKey: "scratchOutDeletes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scratchOutDeletes, forKey: "scratchOutDeletes") }
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
        didSet { if fitsOnePanel, isLayersOpen, isInspectorOpen { isLayersOpen = false } }
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
    @ObservationIgnored private var titleSuggestion: Task<Void, Never>?
    @ObservationIgnored private var adjustmentEnd: Task<Void, Never>?

    /// Whether a finger draws while the palette is up. Once Apple Pencil has been seen,
    /// it doesn't: the Pencil draws, and a finger selects, moves, pans and taps buttons.
    /// Until then a finger draws, so that Layer works without a Pencil. Either way it can
    /// be set in the format panel, after which it is left as set. Remembered between launches.
    var fingerDraws = UserDefaults.standard.object(forKey: AppModel.fingerDrawsKey) == nil ? true : UserDefaults.standard.bool(forKey: AppModel.fingerDrawsKey) {
        didSet { UserDefaults.standard.set(fingerDraws, forKey: AppModel.fingerDrawsKey) }
    }

    /// Set by hand in the format panel.
    func setFingerDraws(_ draws: Bool) {
        fingerDraws = draws
        UserDefaults.standard.set(true, forKey: AppModel.fingerDrawsChosenKey)
    }

    /// Apple Pencil touched the canvas. The first time, a finger stops drawing, unless
    /// that has been set by hand. `elsewhere` is a touch in a presentation of its own over
    /// the canvas: a panel's sheet, a popover or an alert.
    func pencilTouched(at viewPoint: CGPoint, elsewhere: Bool = false) {
        if fingerDraws, !UserDefaults.standard.bool(forKey: AppModel.fingerDrawsChosenKey) {
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
        (fingerDraws && !UserDefaults.standard.bool(forKey: AppModel.fingerDrawsChosenKey)) || (tool == .draw && selection != nil)
    }

    private static let fingerDrawsKey = "fingerDraws"
    private static let fingerDrawsChosenKey = "fingerDrawsChosen"
    private static let convertsAutomaticallyKey = "convertsAutomatically"
    private static var savedConvertsAutomatically: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: convertsAutomaticallyKey) == nil || defaults.bool(forKey: convertsAutomaticallyKey)
    }

    init(document: LayerDocument) {
        self.document = document
        let file = document.current
        store = DesignStore(content: file.content)
        images = ImageLibrary(file.images)
        engine = SketchEngine(provider: file.content.canvas.resolvedModel.sketchProvider)
        appliedModel = .some(file.content.canvas.model)
        store.onChange = { [weak self, document] content in
            // A command or generation still unwinding after the design closed doesn't
            // write to a document the browser has already let go of.
            guard self?.isClosed != true else { return }
            document.update { $0.content = content }
            // A drawing moved, locked, hidden, deleted or put back by undo shows on the ink canvas.
            self?.ink?.showDrawings()
            // After this change is done with: ending a drag ends the edit it is part of.
            if self?.drags?.isDragging == true {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    drags?.endIfDraggedIsGone(model: self)
                }
            }
            self?.followModelChoice()
            self?.dropSelectionOfMissingThings()
            self?.matchNameAndFile()
            self?.schedulePreview()
            if let self { DesignIndexer.designChanged(self) }
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

    /// Whether the screen being generated opened an undo step of its own to close.
    @ObservationIgnored private var generationOwnsEdit = true

    /// Adds a new screen and has the design's model write it from `description`. Its
    /// elements appear as the model writes them; the whole screen is one undo step.
    ///
    /// `name` is what to call the screen; without one it is named from the description.
    ///
    /// `anchor` is a canvas point to put the screen at, where the pencil pointed for a
    /// spoken command; without one it goes where new screens always go.
    ///
    /// `partOfHeldEdit` is for a screen a spoken command asks for. The command's undo step
    /// is already being held open and the screen is part of it, so it opens none of its
    /// own. That is also how an edit by hand made in the meantime is told from it: see
    /// `DesignStore.endHeldEdit()`.
    func generateScreen(from description: String, named name: String? = nil, near anchor: CGPoint? = nil, partOfHeldEdit: Bool = false) {
        let prompt = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating, !isClosed else { return }
        generationTask?.cancel()
        generationDismissal?.cancel()

        let device = store.canvas.sketchDevice
        // What the design says already, before the new screen joins it, so the new one's
        // words match. Nothing for an empty design.
        let board = store.content.screens.isEmpty ? nil : SketchPrompt.describe(board: store.content)
        generationOwnsEdit = !partOfHeldEdit
        if generationOwnsEdit { store.beginEdit() }
        // A command the pencil pointed at empty canvas for puts the screen where it pointed.
        let screen = store.addScreen(device, at: DesignActions.placementForNewScreen(device, in: self, near: anchor))
        store.updateScreen(screen.id) { $0.name = name ?? ScreenGenerator.name(for: prompt) }
        DesignActions.reveal(.screen(screen.id), in: self)
        generation = ScreenGeneration(screenID: screen.id, description: prompt)

        let choice = modelChoice
        let stream = screenStream(prompt, board, choice)
        generationTask = Task { [weak self] in
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
                            _ = store.setElements(blueprint.layout(on: current.device), on: screen.id, replacing: true)
                        }
                        generation?.isThinking = false
                        generation?.elementCount = blueprint.itemCount
                    }
                }
                self?.finishGeneration(error: nil)
            } catch {
                self?.finishGeneration(error: error is CancellationError ? nil : error)
            }
        }
    }

    /// Stops the model; what it has written so far stays.
    func stopGenerating() {
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

    private func finishGeneration(error: (any Error)?) {
        generationTask = nil
        guard var finished = generation else { return }
        // Nothing is written to a design that has closed, and nothing is left to show.
        guard !isClosed else {
            generation = nil
            return
        }
        // A screen taken away while it was written has nothing to show either. Its edit,
        // if it opened one, is still closed.
        guard store.screen(finished.screenID) != nil else {
            if generationOwnsEdit { store.endEdit() }
            generation = nil
            return
        }
        if let error {
            finished.phase = .failed(error.localizedDescription)
        } else {
            finished.phase = finished.elementCount > 0 ? .finished : .failed(ScreenGenerator.GenerationError.nothingWritten.localizedDescription)
        }
        // A screen nothing was written on isn't left behind.
        if finished.elementCount == 0 { store.deleteScreen(finished.screenID) }
        if generationOwnsEdit { store.endEdit() }
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
        tool = .select
        // One microphone at a time, in every window: the phone call hears from now on. A
        // pencil command already sent still runs, in its turn.
        for design in OpenDesigns.shared.all where design !== self { design.stopPencilListening() }
        stopPencilListening()
        let call = VoiceCall(route: route, runner: runner, vocabulary: { [weak self] in self?.voiceVocabulary ?? [] })
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

    /// Gets a design ready to go back to the document browser: its picture as the board
    /// was left, its name decided, and its file given that name. False when the design is
    /// already on its way out, so that a second tap of the back button doesn't dismiss it
    /// again, or early, while the first still waits for the file's name.
    @discardableResult
    func prepareToClose() async -> Bool {
        guard !isClosing, !isClosed else { return false }
        isClosing = true
        refreshPreview()
        // A name still being thought up is settled now, from the design's own words.
        if titleSuggestion != nil, store.title == nil {
            store.setTitle(engine.fallbackTitle(for: store.content), undoable: false)
        }
        await settleFileName()
        close()
        return true
    }

    @ObservationIgnored private var isClosing = false

    func close() {
        // Closed by the back button, then again as the canvas goes from the screen.
        guard !isClosed else { return }
        // Ink a pen or the eraser has changed and that is waiting for the tool to be put
        // down goes into the design now, while it can still be saved.
        ink?.flushPendingInk()
        drags?.endAny(model: self)
        // A change made in the format panel moments ago is still an edit waiting for the
        // panel's pause to end it: it ends now, while the design can still be saved.
        adjustmentEnd?.cancel()
        adjustmentEnd = nil
        store.endEdit()
        // What was written without an undo step, or after the last save within an edit,
        // reaches the disk only if the system is told there is something to save.
        if document.hasChangesSinceSnapshot { store.markNeedsSaving() }
        isClosed = true
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
            if name != wanted, store.title == title { store.setTitle(name, undoable: false) }
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

    /// A tap that landed on the canvas itself rather than on an element: it picks the
    /// drawing or screen there, or clears the selection.
    func canvasTapped(at viewPoint: CGPoint) {
        let point = viewport.canvasPoint(for: viewPoint)
        // With the palette up, a finger tap reaches here for elements too: their own
        // handles stay out of the Pencil's way while it draws. A drawing has no handle
        // of its own until it is selected, so a tap on its ink always reaches here.
        if case .element(let ref)? = hoverTarget(at: viewPoint), tool == .draw || store.resolve(ref)?.element.kind == .drawing {
            pick(.element(ref))
        } else if let screen = store.screen(at: point) {
            pick(.screen(screen.id))
        } else {
            pick(nil)
        }
    }

    // MARK: Selecting several things

    /// Where fingers are resting on the canvas, in the view's points, not counting one
    /// that has just lifted. Supplied by the ink canvas, which sees every touch.
    @ObservationIgnored var restingFingers: () -> [CGPoint] = { [] }
    /// What the finger that rested during the last tap was on, so that its own lifting
    /// isn't taken for a tap; and when it lifted, once that is known.
    @ObservationIgnored private var rested: (on: CanvasSelection?, lifted: ContinuousClock.Instant?)?

    /// A tap picked something, or nothing when it landed on empty canvas. On its own it
    /// selects just that. With another finger resting on the canvas, as in Freeform, it
    /// adds the thing to what is selected, or lets go of it if it was: the thing the
    /// resting finger is on is selected with it.
    func pick(_ thing: CanvasSelection?) {
        let resting = restingFingers().filter { finger in !chromeFrames.values.contains { $0.contains(finger) } }
        guard let finger = resting.first else {
            if let rested {
                self.rested = nil
                // Lifting the finger that rested reaches whatever it was on as a tap.
                let isLifting = rested.lifted.map { ContinuousClock.now - $0 < .milliseconds(400) } ?? true
                if isLifting, rested.on == thing { return }
            }
            selection = thing
            return
        }
        var held = hoverTarget(at: finger)
        // A finger resting on a screen while its elements are tapped is only holding the
        // selection open: the screen isn't picked along with what is on it.
        if case .screen(let id) = held, case .element(let ref) = thing, ref.host == .screen(id) { held = nil }
        rested = (held, nil)
        guard let thing, thing != held else { return }
        var things = selection?.things ?? []
        // Resting on something that isn't selected starts again from it.
        if let held, !things.contains(held) { things = [held] }
        selection = CanvasSelection(things.symmetricDifference([thing]))
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

    /// Gives every element selected to whatever it now lies on, after a drag.
    func rehostSelection() {
        guard let selection else { return }
        self.selection = store.rehost(selection)
    }

    /// The drawing with ink at a canvas point.
    private func drawing(at point: CGPoint) -> DesignStore.ElementRef? {
        ink?.drawing(at: point, tolerance: 14 / viewport.scale).map { .init(host: .canvas, element: $0) }
    }

    /// What Apple Pencil is hovering over: on the canvas, or in the layers list. It is
    /// outlined softly, short of being selected.
    var hovered: CanvasSelection?
    /// True while the hover comes from the layers list rather than the canvas.
    var isHoveringList = false

    /// The topmost element or screen at a point in the view, for hover.
    ///
    /// `skippingDrawings` looks through ink to what is beneath, for voice, which can't
    /// change a drawing.
    func hoverTarget(at viewPoint: CGPoint, skippingDrawings: Bool = false) -> CanvasSelection? {
        let point = viewport.canvasPoint(for: viewPoint)
        // Ink lies over everything else, and is picked by its strokes, not the box round them.
        if !skippingDrawings, let drawing = drawing(at: point) { return .element(drawing) }
        for floating in store.floating.reversed() where floating.canvasFrame.contains(point) && floating.element.isPickedByItsFrame {
            if skippingDrawings, floating.element.kind == .drawing { continue }
            return .element(.init(host: .canvas, element: floating.id))
        }
        for screen in store.screens.reversed() {
            for element in screen.elements.reversed() where screen.placement.canvasRect(for: element.frame).contains(point) {
                return .element(.init(host: .screen(screen.id), element: element.id))
            }
            if screen.canvasFrame.contains(point) || screen.labelFrame.contains(point) {
                return .screen(screen.id)
            }
        }
        return nil
    }

    /// Where something is, in the view's own points.
    func viewRect(of target: CanvasSelection) -> CGRect? {
        switch target {
        case .element(let ref):
            guard let found = store.resolve(ref) else { return nil }
            return viewport.viewRect(for: found.placement.canvasRect(for: found.element.frame))
        case .screen(let id):
            return store.screen(id).map { viewport.viewRect(for: $0.canvasFrame) }
        case .several:
            return store.canvasFrame(of: target).map(viewport.viewRect(for:))
        }
    }

    /// Whether what is selected is locked in place: all of it, when it is several things.
    var isSelectionLocked: Bool {
        selection.map(store.isLocked) ?? false
    }

    func setSelectionLocked(_ locked: Bool) {
        guard let selection else { return }
        store.setLocked(locked, selection)
    }

    var canDuplicateSelection: Bool { selection != nil }

    /// Whatever can be selected can be locked: elements, drawings among them, and screens.
    var canLockSelection: Bool { selection != nil }

    /// Copies what is selected and selects the copy, or the copies.
    func duplicateSelection() {
        guard let selection, let copies = store.duplicate(selection) else { return }
        self.selection = copies
    }

    func arrangeSelection(_ arrangement: DesignStore.Arrangement) {
        guard case .element(let ref) = selection else { return }
        store.arrange(ref, arrangement)
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

    /// Where what is selected is, in the view's own points: for several things, the area
    /// they cover together.
    var selectionViewRect: CGRect? {
        switch selection {
        case .element:
            guard let selected = selectedElement else { return nil }
            return viewport.viewRect(for: selected.placement.canvasRect(for: selected.element.frame))
        case .screen:
            guard let screen = selectedScreen else { return nil }
            return viewport.viewRect(for: screen.canvasFrame.union(screen.labelFrame))
        case .several(let things):
            return store.canvasFrame(of: .several(things)).map(viewport.viewRect(for:))
        case nil:
            return nil
        }
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
        if let suggestion, store.resolve(suggestion.ref) == nil { dismissSuggestion() }
    }

    // MARK: Did you mean

    /// What the last close call nearly was, while that is on offer.
    private(set) var suggestion: KindSuggestion?
    @ObservationIgnored private var suggestionExpiry: Task<Void, Never>?
    /// How long a suggestion stays up when it is left alone.
    static let suggestionLifetime: Duration = .seconds(8)

    /// Offers to make what a sketch became into what it nearly was. One offer shows at a
    /// time, and goes by itself after a while.
    func offer(_ suggestion: KindSuggestion) {
        suggestionExpiry?.cancel()
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
    }

    /// True while a number field is being scrubbed.
    @ObservationIgnored private var isScrubbing = false

    /// Starts scrubbing a field. Everything until `endScrubbing()` undoes as one step.
    func beginScrubbing() {
        adjustmentEnd?.cancel()
        isScrubbing = true
        store.beginEdit()
    }

    func endScrubbing() {
        isScrubbing = false
        store.endEdit()
    }

    /// How long the format panel waits after its last change before ending its step.
    @ObservationIgnored var adjustmentPause: Duration = .milliseconds(600)

    /// While the format panel's edit is its own, how many edits the store had seen begun
    /// when the panel last joined it. Anything else beginning an edit since, a drag, a
    /// stroke or a scrub, makes the edit theirs to end: ended by the panel's pause, a drag
    /// begun just after a colour was tapped lost its step halfway, and each later move was
    /// a step of its own.
    @ObservationIgnored private var adjustmentOwnsEditAt: Int?
    /// How many edits the store had seen begun at the panel's last change: while it is the
    /// same, nothing else has begun one since.
    @ObservationIgnored private var adjustmentLastBegin: Int?
    /// Whether the panel's change was made inside a spoken command's hold. Its pause may
    /// come after the command has ended, which leaves the step open for the panel to end.
    @ObservationIgnored private var adjustmentBeganInHold = false

    /// Makes a run of quick changes, such as dragging a slider or a colour, one undo step.
    func adjusting(_ body: () -> Void) {
        // The panel's own edit if it opens one, or goes on with one it opened that nothing
        // else has joined. Inside another's edit, the change joins that one.
        let ownsEdit = !store.isEditing || adjustmentOwnsEditAt == store.editBegins
        store.beginEdit()
        adjustmentOwnsEditAt = ownsEdit ? store.editBegins : nil
        adjustmentLastBegin = store.editBegins
        if store.isHoldingEdit { adjustmentBeganInHold = true }
        body()
        // A scrub ends its own edit when it ends.
        guard !isScrubbing else { return }
        adjustmentEnd?.cancel()
        adjustmentEnd = Task { [weak self] in
            try? await Task.sleep(for: self?.adjustmentPause ?? .zero)
            guard !Task.isCancelled, let self else { return }
            // Its own edit, or, inside a spoken command's hold, its own part of it: there
            // an end only says the panel's edit by hand is over, and the command then
            // closes its step. Left, the hold would wait for an end that never comes.
            if adjustmentLastBegin == store.editBegins, adjustmentOwnsEditAt != nil || adjustmentBeganInHold || store.isHoldingEdit {
                store.endEdit()
            }
            adjustmentOwnsEditAt = nil
            adjustmentLastBegin = nil
            adjustmentBeganInHold = false
        }
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
        AssetLibrary.noteUsed(asset)
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
        store.beginEdit()
        defer { store.endEdit() }
        let screen = addFrame(device, centeredAt: point)
        store.updateScreen(screen.id) { $0.name = name }
        _ = store.setElements(blueprint.layout(on: device), on: screen.id, replacing: true)
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
        selection = .screen(screen.id)
        suggestTitleIfNeeded()
        return screen
    }

    /// Names the board once, the first time it has something on it worth naming.
    private func suggestTitleIfNeeded() {
        guard store.title == nil, titleSuggestion == nil else { return }
        titleSuggestion = Task { [weak self] in
            guard let self else { return }
            let title = await engine.suggestTitle(for: store.content)
            if store.title == nil, !isClosed { store.setTitle(title, undoable: false) }
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
            // A drawing and what it becomes change places as one undo step.
            if isDrawing { store.beginEdit() }
            defer { if isDrawing { store.endEdit() } }
            var converted = false
            var added: DesignStore.ElementRef?
            switch reading {
            case .screen:
                let screen = store.addScreen(from: bounds)
                converted = true
                if isDrawing { selection = .screen(screen.id) }
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
            case .scratchOut:
                let crossedOut = scratchOutDeletes ? store.elements(scratchedOutBy: bounds) : []
                if !crossedOut.isEmpty {
                    store.delete(crossedOut)
                    converted = true
                }
            case .unknown:
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
