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

/// What is selected on the canvas.
enum CanvasSelection: Hashable, Sendable {
    case element(DesignStore.ElementRef)
    case screen(DesignScreen.ID)
    /// A drawing: the ink strokes with these keys.
    case ink(Set<Double>)
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

    var tool: Tool = .draw {
        didSet {
            guard tool != oldValue else { return }
            if tool == .draw {
                selection = nil
                scheduleConversion()
            } else {
                settle?.cancel()
            }
        }
    }

    var selection: CanvasSelection? {
        didSet {
            if case .ink(let keys) = selection {
                inkSelectionBounds = ink?.bounds(of: keys)
            } else {
                inkSelectionBounds = nil
            }
            if selection != oldValue { isEditingText = false }
            // The format panel is for the selection: with nothing selected it goes.
            if selection == nil, isInspectorOpen {
                withAnimation(.smooth(duration: 0.3)) { isInspectorOpen = false }
            }
        }
    }

    /// The canvas area a selected drawing covers.
    private(set) var inkSelectionBounds: CGRect?

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
    @ObservationIgnored private var isPenDown = false
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
    /// that has been set by hand.
    func pencilTouched(at viewPoint: CGPoint) {
        if fingerDraws, !UserDefaults.standard.bool(forKey: AppModel.fingerDrawsChosenKey) {
            fingerDraws = false
        }
        // On a panel, the popover or the bars, the Pencil is pressing a control, scrubbing a
        // field for instance, not landing on the canvas.
        if chromeFrames.values.contains(where: { $0.contains(viewPoint) }) { return }
        // With the palette up, the Pencil is for drawing: landing on what a finger
        // selected lets go of it, rather than dragging it about.
        if tool == .draw, let rect = selectionViewRect, rect.insetBy(dx: -8, dy: -8).contains(viewPoint) {
            selection = nil
        }
    }

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
        store.onChange = { [weak self, document] content in
            document.update { $0.content = content }
            self?.applyModelChoice()
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
        engine.use(modelChoice.sketchProvider)
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
    func generateScreen(from description: String) {
        let prompt = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else { return }
        generationTask?.cancel()
        generationDismissal?.cancel()

        let device = store.canvas.sketchDevice
        store.beginEdit()
        let screen = store.addScreen(device, at: DesignActions.placementForNewScreen(device, in: self))
        store.updateScreen(screen.id) { $0.name = ScreenGenerator.name(for: prompt) }
        DesignActions.reveal(.screen(screen.id), in: self)
        generation = ScreenGeneration(screenID: screen.id, description: prompt)

        let choice = modelChoice
        generationTask = Task { [weak self] in
            do {
                for try await update in ScreenGenerator.stream(prompt, using: choice) {
                    guard let self, let current = store.screen(screen.id) else { return }
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

    private func finishGeneration(error: (any Error)?) {
        generationTask = nil
        guard var finished = generation else { return }
        if let error {
            finished.phase = .failed(error.localizedDescription)
        } else {
            finished.phase = finished.elementCount > 0 ? .finished : .failed(ScreenGenerator.GenerationError.nothingWritten.localizedDescription)
        }
        // A screen nothing was written on isn't left behind.
        if finished.elementCount == 0 { store.deleteScreen(finished.screenID) }
        store.endEdit()
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

    // MARK: Voice mode

    /// Stands in for the voice agent until it is connected: a call can be started and
    /// spoken to, and says that nothing can be done with what it hears yet.
    private final class UnconnectedRunner: VoiceCommandRunner {
        func run(_ command: String) async -> VoiceOutcome {
            VoiceOutcome(problem: "Voice commands aren't connected yet.")
        }
    }

    /// The call that is up in this design, if one is.
    private(set) var voice: VoiceCall?
    /// Why a call couldn't start or couldn't go on, to tell the person once.
    var voiceNotice: String?

    var isInVoiceCall: Bool { voice != nil }

    /// Starts a call: the phone button's action.
    func startVoiceCall() {
        guard voice == nil else { return }
        Task { await startVoiceCall(route: DictationRoute(), runner: UnconnectedRunner()) }
    }

    /// Starts a call that hears through `route` and acts through `runner`. Returns once
    /// the call is listening, or has ended because it couldn't.
    func startVoiceCall(route: any VoiceRoute, runner: any VoiceCommandRunner) async {
        guard voice == nil else { return }
        // The pencil bar goes, and a finger pans and selects, for as long as the call is up.
        tool = .select
        let call = VoiceCall(route: route, runner: runner, vocabulary: { [weak self] in self?.voiceVocabulary ?? [] })
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
    }

    /// The words on the canvas, which are the ones most likely to be spoken and misheard:
    /// the names of the screens and what their elements say.
    private var voiceVocabulary: [String] {
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
    @ObservationIgnored private var isClosed = false

    /// Gets a design ready to go back to the document browser: its picture as the board
    /// was left, its name decided, and its file given that name.
    func prepareToClose() async {
        refreshPreview()
        // A name still being thought up is settled now, from the design's own words.
        if titleSuggestion != nil, store.title == nil {
            store.setTitle(engine.fallbackTitle(for: store.content), undoable: false)
        }
        await settleFileName()
        close()
    }

    func close() {
        isClosed = true
        voice?.end()
        OpenDesigns.shared.closed(self)
        titleSuggestion?.cancel()
        previewRefresh?.cancel()
        fileCheck?.cancel()
        generationTask?.cancel()
        generationDismissal?.cancel()
        settle?.cancel()
        adjustmentEnd?.cancel()
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
            let copies = await CloudFile.keepConflictingVersions(of: url)
            let state = await Task.detached { CloudFile.syncState(of: url) }.value
            guard let self, !Task.isCancelled, fileURL == url else { return }
            if !copies.isEmpty {
                let names = copies.map { "“\($0)”" }.formatted(.list(type: .and))
                keptVersionsNotice = copies.count == 1
                    ? "This design was changed on another device at the same time. That version is kept as \(names), beside this one."
                    : "This design was changed on other devices at the same time. Those versions are kept as \(names), beside this one."
            }
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

    /// What the board's picture shows, so that a board changed and changed back, or
    /// touched without changing, isn't drawn again.
    private struct PreviewedBoard: Equatable {
        var content: DesignContent
        var strokes: Int
        var inkBounds: CGRect
    }
    @ObservationIgnored private var previewedBoard: PreviewedBoard?

    private var board: PreviewedBoard {
        let file = document.current
        return PreviewedBoard(content: file.content, strokes: file.drawing.strokes.count, inkBounds: file.drawing.bounds)
    }

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

    var selectedElement: (ref: DesignStore.ElementRef, element: DesignElement, placement: Placement)? {
        guard case .element(let ref) = selection, let found = store.resolve(ref) else { return nil }
        return (ref, found.element, found.placement)
    }

    var selectedScreen: DesignScreen? {
        guard case .screen(let id) = selection else { return nil }
        return store.screen(id)
    }

    /// A tap that landed on the canvas itself rather than on an element: it picks the
    /// drawing or screen there, or clears the selection.
    func canvasTapped(at viewPoint: CGPoint) {
        let point = viewport.canvasPoint(for: viewPoint)
        // With the palette up, a finger tap reaches here for elements too: their own
        // handles stay out of the Pencil's way while it draws.
        if tool == .draw, case .element(let ref)? = hoverTarget(at: viewPoint) {
            selection = .element(ref)
        } else if let keys = ink?.drawing(at: point, tolerance: 14 / viewport.scale) {
            selection = .ink(keys)
        } else if let screen = store.screen(at: point) {
            selection = .screen(screen.id)
        } else {
            selection = nil
        }
    }

    /// What Apple Pencil is hovering over: on the canvas, or in the layers list. It is
    /// outlined softly, short of being selected.
    var hovered: CanvasSelection?
    /// True while the hover comes from the layers list rather than the canvas.
    var isHoveringList = false

    /// The topmost element or screen at a point in the view, for hover.
    func hoverTarget(at viewPoint: CGPoint) -> CanvasSelection? {
        let point = viewport.canvasPoint(for: viewPoint)
        for floating in store.floating.reversed() where floating.canvasFrame.contains(point) {
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
        case .ink(let keys):
            return ink?.bounds(of: keys).map { viewport.viewRect(for: $0) }
        }
    }

    /// Whether what is selected is locked in place.
    var isSelectionLocked: Bool {
        switch selection {
        case .element: selectedElement?.element.isLocked == true
        case .screen: selectedScreen?.isLocked == true
        case .ink, nil: false
        }
    }

    func setSelectionLocked(_ locked: Bool) {
        switch selection {
        case .element(let ref): store.update(ref) { $0.isLocked = locked }
        case .screen(let id): store.updateScreen(id) { $0.isLocked = locked ? true : nil }
        case .ink, nil: break
        }
    }

    var canDuplicateSelection: Bool {
        switch selection {
        case .element, .screen: true
        case .ink, nil: false
        }
    }

    /// Elements and screens can be locked; drawings can't.
    var canLockSelection: Bool { canDuplicateSelection }

    /// Copies what is selected and selects the copy.
    func duplicateSelection() {
        switch selection {
        case .element(let ref):
            if let copy = store.duplicate(ref) { selection = .element(copy) }
        case .screen(let id):
            if let copy = store.duplicateScreen(id) { selection = .screen(copy.id) }
        case .ink, nil:
            break
        }
    }

    func arrangeSelection(_ arrangement: DesignStore.Arrangement) {
        guard case .element(let ref) = selection else { return }
        store.arrange(ref, arrangement)
    }

    func alignSelection(_ alignment: ElementLayout.Alignment) {
        guard case .element(let ref) = selection, !isSelectionLocked else { return }
        store.align(ref, alignment)
    }

    func toggleLockOfSelection() {
        setSelectionLocked(!isSelectionLocked)
    }

    /// Hides or shows an element. Hiding one lets go of it, since it can't be touched.
    func toggleHidden(_ ref: DesignStore.ElementRef) {
        store.update(ref) { $0.isHidden.toggle() }
        if selection == .element(ref), store.resolve(ref)?.element.isHidden == true { selection = nil }
    }

    func toggleLock(_ ref: DesignStore.ElementRef) {
        store.update(ref) { $0.isLocked.toggle() }
    }

    /// Where what is selected is, in the view's own points.
    var selectionViewRect: CGRect? {
        switch selection {
        case .element:
            guard let selected = selectedElement else { return nil }
            return viewport.viewRect(for: selected.placement.canvasRect(for: selected.element.frame))
        case .screen:
            guard let screen = selectedScreen else { return nil }
            return viewport.viewRect(for: screen.canvasFrame.union(screen.labelFrame))
        case .ink:
            return inkSelectionBounds.map { viewport.viewRect(for: $0) }
        case nil:
            return nil
        }
    }

    func deleteSelection() {
        guard !isSelectionLocked else { return }
        switch selection {
        case .element(let ref): store.delete(ref)
        case .screen(let id): store.deleteScreen(id)
        case .ink(let keys): ink?.deleteInk(keys)
        case nil: break
        }
        selection = nil
    }

    /// Moves the selected drawing. Call `finishMovingInk` when the drag ends, so the whole
    /// move undoes as one step.
    func moveSelectedInk(by delta: CGSize) {
        guard case .ink(let keys) = selection else { return }
        ink?.translateInk(keys, by: delta)
        inkSelectionBounds = ink?.bounds(of: keys)
    }

    func finishMovingInk(movedBy total: CGSize) {
        guard case .ink(let keys) = selection, total != .zero else { return }
        ink?.registerUndo(ofMoving: keys, by: total)
    }

    /// Ink changed underneath the selection, by undo or redo: follow it, or let go of it.
    func inkSelectionMayHaveMoved() {
        guard case .ink(let keys) = selection else { return }
        inkSelectionBounds = ink?.bounds(of: keys)
        if inkSelectionBounds == nil { selection = nil }
    }

    private func dropSelectionOfMissingThings() {
        switch selection {
        case .element(let ref) where store.resolve(ref) == nil: selection = nil
        case .screen(let id) where store.screen(id) == nil: selection = nil
        default: break
        }
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

    /// Makes a run of quick changes, such as dragging a slider or a colour, one undo step.
    func adjusting(_ body: () -> Void) {
        store.beginEdit()
        body()
        // A scrub ends its own edit when it ends.
        guard !isScrubbing else { return }
        adjustmentEnd?.cancel()
        adjustmentEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.store.endEdit()
        }
    }

    // MARK: Adding things

    /// The canvas point in the middle of the view.
    private var middleOfView: CGPoint {
        viewport.canvasPoint(for: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    /// Puts a new element in the middle of the view, selected and ready to be dragged.
    @discardableResult
    private func add(_ element: DesignElement) -> DesignStore.ElementRef {
        let ref = store.place(element, centeredAt: middleOfView)
        tool = .select
        selection = .element(ref)
        return ref
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

    /// Adds a device frame in the middle of the view, sized to fit comfortably in it.
    func addFrame(_ device: DeviceFrame) {
        let room = (canvasSize.height - 220) / viewport.scale
        let scale = min(max((room / device.size.height * 100).rounded() / 100, 0.15), 1)
        let size = CGSize(width: device.size.width * scale, height: device.size.height * scale)
        let middle = middleOfView
        let origin = CGPoint(x: (middle.x - size.width / 2).rounded(), y: (middle.y - size.height / 2).rounded())
        let screen = store.addScreen(device, at: Placement(origin: origin, scale: scale))
        tool = .select
        selection = .screen(screen.id)
        suggestTitleIfNeeded()
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

    /// Ink drawn with PencilKit's own tools changed. It is part of the document.
    func drawingChanged(_ drawing: PKDrawing) {
        document.update { $0.drawing = drawing }
        schedulePreview()
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
        guard case .ink(let keys) = selection, let strokes = ink?.inkStrokes(keys), !strokes.isEmpty else { return }
        selection = nil
        let zoom = viewport.scale
        let conversion = Task { [weak self] () -> Void in
            guard let self else { return }
            await convert(onScreen(strokes, zoom: zoom), zoom: zoom, drawing: keys, prompt: prompt)
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
    /// A Magic Pen sketch is read on its own; `drawing` is set instead for ordinary ink
    /// that was selected and asked to be read, with the `prompt` typed for it.
    private func convert(_ group: [SketchStroke], zoom: CGFloat, drawing: Set<Double>? = nil, prompt: String? = nil) async {
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
        let reading = await engine.read(request)
        // Stage 0 instrumentation (reports/Fast and slow sketch recognition.md): if this
        // reading became an element below, linking it here lets a deletion soon after be
        // recognised as a likely correction of this specific reading.
        let readingLogID = engine.lastLogID
        // Stage 2: a word PencilKit's handwriting recognizer read out of these same
        // strokes, such as "Sign in" inside a box, which becomes the element's label below.
        let recognizedText = engine.lastRecognizedText
        _ = await minimum
        // Closed while the sketch was being read: nothing is put on a design that has gone.
        guard !isClosed, !Task.isCancelled else {
            effects.removeAll { $0.id == effect.id }
            return
        }

        withAnimation(.smooth(duration: 0.45)) {
            effects.removeAll { $0.id == effect.id }
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
                if let drawing { ink?.deleteInk(drawing) } else { ink?.removeSketch(keys) }
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
            // Long enough to add the strokes that would complete a half-drawn shape.
            repeat { try? await Task.sleep(for: .seconds(4)) } while self?.isPenDown == true
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
