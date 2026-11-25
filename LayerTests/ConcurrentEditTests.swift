import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// Several changes under way at once: a drag, a turn, a scrub, a screen being written, a
/// template or a Siri action. Each is an undo step of its own, one ending never ends
/// another, and a gesture's frames stay one step however the others come and go. They
/// used to share one edit by hand, which the first to end closed for all: every later
/// frame of a drag, or line of a generation, was then a step of its own, and fifty of
/// them pushed the rest of the history out (C1, G4, M2, M3).
@Suite("Changes under way at once", .serialized)
@MainActor
struct ConcurrentEditTests {
    @MainActor private struct Board {
        let model: AppModel
        let undo: UndoManager
        let screen: TreeScreen.ID
        let title: NodeRef
        let button: NodeRef
        var store: DesignStore { model.store }

        func frame(of ref: NodeRef) -> CGRect? { store.placed(ref)?.frame }
        func rotation(of ref: NodeRef) -> Double? { store.placed(ref).flatMap { Rotation.kept($0.degrees) } }
    }

    /// A screen with a title and a button, and an empty history. Generations are written
    /// by the test, a line at a time.
    private func board(groupsByEvent: Bool = false) -> (Board, AsyncThrowingStream<ScreenGenerator.Update, any Error>.Continuation) {
        let undo = UndoManager()
        undo.groupsByEvent = groupsByEvent
        let model = AppModel(document: LayerDocument())
        model.store.undoManager = undo
        model.adjustmentPause = .seconds(60)
        // A name the app suggests has no step, so undo leaves it: landing at a moment of
        // its own choosing, it made "everything undone is the start" fail now and then.
        model.suggestsTitle = false
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let refs = model.store.add([
            LayerNode.leaf(.title, frame: CGRect(x: 20, y: 80, width: 353, height: 40), text: "Welcome", tint: Theme.accent),
            LayerNode.leaf(.button, frame: CGRect(x: 20, y: 700, width: 353, height: 50), text: "Go", tint: Theme.accent),
        ], onScreen: screen.id)
        undo.removeAllActions()
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        model.screenStream = { _ in stream }
        return (Board(model: model, undo: undo, screen: screen.id, title: refs[0], button: refs[1]), feed)
    }

    private static func written(_ text: String) -> ScreenGenerator.Update {
        .screen(Outline.parse(text, isComplete: true))
    }

    /// A finger drags the button while the knob turns the title. Whichever ends first, the
    /// other goes on as its own step: two steps, each taken back whole.
    @Test(arguments: [true, false])
    func aDragAndATurnAtOnceAreAStepEachEndedInEitherOrder(dragEndsFirst: Bool) throws {
        let (board, _) = board()
        let start = board.store.tree
        let buttonFrame = try #require(board.frame(of: board.button))
        board.model.selection = .element(board.title)

        board.store.beginEdit()
        board.store.update(board.button.node) { $0.frame.origin.y -= 1 }
        #expect(board.model.beginTurn())
        board.model.turnSelection(by: 10, snaps: false)
        board.store.update(board.button.node) { $0.frame.origin.y -= 1 }
        if dragEndsFirst {
            board.store.endEdit()
            for degrees in 11...70 { board.model.turnSelection(by: Double(degrees), snaps: false) }
            board.model.endTurn()
        } else {
            board.model.endTurn()
            for _ in 0..<60 { board.store.update(board.button.node) { $0.frame.origin.y -= 1 } }
            board.store.endEdit()
        }
        #expect(!board.store.isEditing)

        board.undo.undo()
        // One of them is taken back whole; the other is as it ended.
        let turned = board.rotation(of: board.title) != nil
        let moved = board.frame(of: board.button) != buttonFrame
        #expect(turned != moved)
        board.undo.undo()
        #expect(board.store.tree == start)
        #expect(!board.undo.canUndo)
    }

    /// A knob turn ends when the selection changes (the knob goes with it). Ending, it ends
    /// its own step and nothing else: a drag still under way goes on as one step.
    @Test func aTurnEndedByASelectionChangeEndsOnlyItsOwnStep() throws {
        let (board, _) = board()
        let start = board.store.tree
        let drag = board.store.beginEdit()
        board.store.act(for: drag) { board.store.update(board.button.node) { $0.frame.origin.x = 30 } }
        board.model.selection = .element(board.title)
        #expect(board.model.beginTurn())
        board.model.turnSelection(by: 10, snaps: false)
        board.model.selection = .element(board.button)
        #expect(!board.model.isTurning)
        #expect(board.store.isEditing(by: .hand))
        let mark = board.store.historyMark
        for x in 31...60 { board.store.act(for: drag) { board.store.update(board.button.node) { $0.frame.origin.x = CGFloat(x) } } }
        #expect(board.store.historyMark == mark, "the drag's frames are still the drag's one step")
        board.store.endEdit(drag)
        board.undo.undo()
        #expect(board.rotation(of: board.title) == nil)
        #expect(board.frame(of: board.button)?.minX == 60)
        board.undo.undo()
        #expect(board.store.tree == start)
        #expect(!board.undo.canUndo)
    }

    /// A template added, or a Siri action, in the middle of a drag: its begin and end used
    /// to close the drag's step, and the drag's remaining frames were each a step (M3).
    @Test(arguments: ["template", "Siri"])
    func aOneShotEditDuringADragLeavesTheDragOneStep(oneShot: String) throws {
        let (board, _) = board()
        let start = board.store.tree
        board.store.beginEdit()
        board.store.update(board.button.node) { $0.frame.origin.y -= 1 }
        if oneShot == "template" {
            board.model.addTemplate("Sign In")
            #expect(board.store.tree.screens.count == 2)
        } else {
            DesignActions.edit(board.model, undoManager: nil, actionName: "Rename") {
                board.store.updateTreeScreen(board.screen) { $0.name = "Renamed" }
            }
        }
        for _ in 0..<60 { board.store.update(board.button.node) { $0.frame.origin.y -= 1 } }
        #expect(board.store.isEditing, "the drag's step is still open")
        board.store.endEdit()

        board.undo.undo()
        // The one-shot is taken back; the drag stays where it ended.
        #expect(board.store.tree.screens.count == 1)
        #expect(board.store.treeScreen(board.screen)?.name == start.screens.first?.name)
        let draggedTo: CGFloat = 700 - 61
        #expect(board.frame(of: board.button)?.minY == draggedTo)
        board.undo.undo()
        #expect(board.store.tree == start)
        #expect(!board.undo.canUndo)
    }

    /// A 200-frame drag made while a screen is written, begun after its first line and
    /// still going when it finishes, is one step, and the screen another. The screen's,
    /// finished last, is taken back first, and the drag's frames after it are still the
    /// drag's (C1, G4, M2).
    @Test func aLongDragDuringAGenerationIsOneDragStepAndOneGenerationStep() async throws {
        let (board, feed) = board()
        let start = board.store.tree
        board.model.generateScreen(from: "a settings screen")
        let generated = try #require(board.model.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { board.store.screenLeaves(generated).count == 1 })

        board.store.beginEdit()
        for frame in 0..<100 { board.store.update(board.button.node) { $0.frame.origin.x = 20 + CGFloat(frame) } }
        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        #expect(await eventually { board.store.screenLeaves(generated).count == 2 })
        for frame in 100..<150 { board.store.update(board.button.node) { $0.frame.origin.x = 20 + CGFloat(frame) } }
        feed.yield(Self.written("title: Settings\nbutton: Save\ntext: Notifications\n"))
        feed.finish()
        await board.model.waitForGeneration()
        #expect(board.store.screenLeaves(generated).count == 3)
        // The generation's end leaves the drag going (G4, M2).
        #expect(board.store.isEditing(by: .hand))
        for frame in 150..<200 { board.store.update(board.button.node) { $0.frame.origin.x = 20 + CGFloat(frame) } }
        board.store.endEdit()

        board.undo.undo()
        #expect(board.store.treeScreen(generated) == nil)
        #expect(board.frame(of: board.button)?.minX == 219)
        board.undo.undo()
        #expect(board.store.tree == start)
        #expect(!board.undo.canUndo)
    }

    /// Two edits whose changes interleave, on the same element among others: undoing one
    /// takes back its own changes, what it took away comes back where it was, and the
    /// other's changes, made between its own, stay. Redo puts them back.
    @Test func undoingOneEditLeavesWhatAnotherDidMeanwhile() throws {
        let (board, _) = board()
        let store = board.store
        let start = store.tree
        let extra = { (text: String) in LayerNode.leaf(.body, frame: CGRect(x: 20, y: 300, width: 200, height: 40), text: text, tint: Theme.accent) }
        let a = store.beginEdit(by: .app)
        let b = store.beginEdit(by: .app)
        store.act(for: a) { store.update(board.title.node) { $0.content.text = "A" } }
        store.act(for: b) {
            store.update(board.title.node) { $0.frame.origin.x += 5 }
            store.delete(board.button)
            _ = store.add([extra("From B")], onScreen: board.screen)
        }
        store.act(for: a) {
            store.update(board.title.node) { $0.content.text = "AA" }
            _ = store.add([extra("From A")], onScreen: board.screen)
        }
        store.endEdit(b)
        store.endEdit(a)
        let end = store.tree

        // A's step went in first, so B's is on top: its move, delete and add are taken back,
        // and A's words and element stay.
        board.undo.undo()
        _ = try #require(store.treeScreen(board.screen))
        #expect(store.screenLeaves(board.screen).map(\.content.text) == ["AA", "Go", "From A"])
        #expect(board.frame(of: board.title)?.minX == 20)
        board.undo.undo()
        #expect(store.tree == start)
        board.undo.redo()
        board.undo.redo()
        #expect(store.tree == end)
    }

    /// A finger picks something up while a screen is written and drops it on that screen
    /// once it is finished. Undoing the screen, on top as the last thing finished, took the
    /// screen away and left what was dropped on it on no screen: invisible, and saved so
    /// (review C-1). It goes onto the open canvas where it was, and the drag's own undo
    /// then puts it back where it came from.
    @Test func undoingAGenerationLeavesNothingOnNoScreen() async throws {
        let (board, feed) = board()
        let start = board.store.tree
        board.model.generateScreen(from: "a settings screen")
        let generated = try #require(board.model.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { board.store.screenLeaves(generated).count == 1 })
        let drag = board.store.beginEdit()
        board.store.act(for: drag) { board.store.update(board.button.node) { $0.frame.origin.x += 5 } }
        feed.finish()
        await board.model.waitForGeneration()
        let dropped = try #require(board.store.act(for: drag) {
            board.store.move(board.button, toScreen: generated, origin: CGPoint(x: 20, y: 400))
        })
        board.store.endEdit(drag)
        let onScreen = try #require(board.store.placed(dropped))

        board.undo.undo()
        #expect(board.store.treeScreen(generated) == nil)
        let floating = try #require(board.store.placed(NodeRef(host: .canvas, node: dropped.node)))
        // Where it was on the canvas, at the screen's scale.
        #expect(floating.placement.canvasRect(for: floating.frame) == onScreen.placement.canvasRect(for: onScreen.frame))
        board.undo.redo()
        #expect(board.store.placed(dropped) != nil)
        board.undo.undo()
        board.undo.undo()
        #expect(board.store.tree == start)
    }

    /// Something else changes the design while a change is being made, as the ink canvas
    /// follows an eraser inside the store's own notice of a change. That change was put in
    /// both steps, so undoing a generation's line took back part of an erasure (review I-1).
    @Test func aChangeMadeWhileAnotherIsReportedIsInItsOwnStepOnly() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = DesignStore()
        store.undoManager = undo
        let screen = store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let refs = store.add([
            LayerNode.leaf(.title, frame: CGRect(x: 20, y: 80, width: 353, height: 40), text: "Welcome", tint: Theme.accent),
            LayerNode.leaf(.button, frame: CGRect(x: 20, y: 700, width: 353, height: 50), text: "Go", tint: Theme.accent),
        ], onScreen: screen.id)
        undo.removeAllActions()
        let start = store.tree
        let erasing = store.beginEdit()
        let writing = store.beginEdit(by: .app)
        store.act(for: erasing) { store.update(refs[0].node) { $0.content.text = "1" } }
        var follows = true
        store.onChange = { _ in
            guard follows else { return }
            follows = false
            store.act(for: erasing) { store.update(refs[0].node) { $0.content.text = "2" } }
        }
        store.act(for: writing) { store.update(refs[1].node) { $0.frame.origin.y = 600 } }
        store.onChange = nil
        store.endEdit(writing)
        store.endEdit(erasing)

        // The line's step takes back the line, and leaves the erasure whole.
        undo.undo()
        #expect(store.node(refs[0].node)?.content.text == "2")
        #expect(store.placed(refs[1])?.frame.minY == 700)
        undo.undo()
        #expect(store.tree == start)
    }

    /// A screen finishing used to move its step to the top of the history, and registering
    /// a step clears Redo: what the person had just undone could no longer be redone
    /// (review I-3).
    @Test func aGenerationFinishingKeepsRedo() async throws {
        let (board, feed) = board()
        board.model.generateScreen(from: "a settings screen")
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { board.model.generation?.elementCount == 1 })
        board.store.update(board.title.node) { $0.content.text = "Hello" }
        board.store.update(board.button.node) { $0.content.text = "Next" }
        board.undo.undo()
        #expect(board.undo.canRedo)
        feed.finish()
        await board.model.waitForGeneration()
        #expect(board.undo.canRedo)
        board.undo.redo()
        #expect(board.store.node(board.button.node)?.content.text == "Next")
    }

    /// A drag and a turn whose frames take turns: each step used to start a new run, two
    /// whole designs kept, at every frame of the other (review M-1). A run goes on over
    /// what the other changed meanwhile when that touched nothing of the run's.
    @Test func editsTakingTurnsFrameByFrameKeepFewRuns() throws {
        let (board, _) = board()
        let start = board.store.tree
        board.model.selection = .element(board.title)
        let drag = board.store.beginEdit()
        #expect(board.model.beginTurn())
        for frame in 1...200 {
            board.store.act(for: drag) { board.store.update(board.button.node) { $0.frame.origin.x = 20 + CGFloat(frame) } }
            board.model.turnSelection(by: Double(frame) / 10, snaps: false)
        }
        #expect(board.store.recordedRuns(of: drag) <= 2)
        board.store.endEdit(drag)
        board.model.endTurn()
        board.undo.undo()
        board.undo.undo()
        #expect(board.store.tree == start)
    }

    /// A generation started as part of a one-off step, which ends at once, took that step
    /// for its own: every line after it was then a step of its own (review M-5). Only a
    /// spoken command's step, which waits for the screen, is joined.
    @Test func aGenerationStartedInsideAOneOffStepIsAStepOfItsOwn() async throws {
        let (board, feed) = board()
        board.store.asOwnStep { board.model.generateScreen(from: "a settings screen") }
        let generated = try #require(board.model.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        feed.finish()
        await board.model.waitForGeneration()
        #expect(board.store.screenLeaves(generated).count == 2)
        board.undo.undo()
        #expect(board.store.treeScreen(generated) == nil)
        #expect(!board.undo.canUndo)
    }

    /// A turn that would take over a drag but begins inside another edit's work ended
    /// nothing: the drag's edit, already given up, was left open for good (review M-10).
    @Test func aTurnThatCannotTakeOverADragEndsIt() {
        let (board, _) = board()
        let drag = board.store.beginEdit()
        let other = board.store.beginEdit(by: .app)
        let turn = board.store.act(for: other) { board.store.beginEdit(by: .turn, takingOver: drag) }
        board.store.endEdit(turn)
        board.store.endEdit(other)
        #expect(!board.store.isEditing)
    }

    /// A change by hand ended between two lines of a generation used to close the screen's
    /// step: every later line was then a step of its own, and one undo took back only the
    /// last (G4). The screen is one step, taken back by one undo, and the hand's change,
    /// a step of its own, isn't taken with it.
    @Test func aChangeByHandBetweenLinesLeavesTheScreenOneStep() async throws {
        let (board, feed) = board()
        board.model.generateScreen(from: "a settings screen")
        let generated = try #require(board.model.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { board.store.screenLeaves(generated).count == 1 })
        board.store.beginEdit()
        board.store.setTitle("Mine")
        board.store.endEdit()
        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        feed.yield(Self.written("title: Settings\nbutton: Save\ntext: Notifications\n"))
        feed.finish()
        await board.model.waitForGeneration()
        #expect(board.store.screenLeaves(generated).count == 3)

        board.undo.undo()
        #expect(board.store.treeScreen(generated) == nil)
        #expect(board.store.title == "Mine")
        board.undo.undo()
        #expect(board.store.title == nil)
        #expect(!board.undo.canUndo)
    }
}


/// The same changes with the history the document really has, which groups what is
/// registered in one turn of the run loop, and the run loop turning between one touch and
/// the next. Each step is still a group of its own (`DesignStore.register`): two begun in
/// one turn used to share the event's group, and one undo took back both.
@Suite("Changes under way at once, grouped by event", .serialized)
@MainActor
struct ConcurrentEditsGroupedByEventTests {
    private func board() -> (model: AppModel, undo: UndoManager, screen: TreeScreen.ID, title: NodeRef, button: NodeRef, feed: AsyncThrowingStream<ScreenGenerator.Update, any Error>.Continuation) {
        let undo = UndoManager()
        undo.groupsByEvent = true
        let model = AppModel(document: LayerDocument())
        model.store.undoManager = undo
        model.adjustmentPause = .seconds(60)
        // A name the app suggests has no step, so undo leaves it: landing at a moment of
        // its own choosing, it made "everything undone is the start" fail now and then.
        model.suggestsTitle = false
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let refs = model.store.add([
            LayerNode.leaf(.title, frame: CGRect(x: 20, y: 80, width: 353, height: 40), text: "Welcome", tint: Theme.accent),
            LayerNode.leaf(.button, frame: CGRect(x: 20, y: 700, width: 353, height: 50), text: "Go", tint: Theme.accent),
        ], onScreen: screen.id)
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        model.screenStream = { _ in stream }
        return (model, undo, screen.id, refs[0], refs[1], feed)
    }

    /// The run loop turns, as between two touches, and the event's group closes.
    private func nextEvent() async {
        try? await Task.sleep(for: .milliseconds(5))
    }

    /// Starts from an empty history, once the setting up's group has closed.
    private func clearHistory(_ undo: UndoManager) async {
        await nextEvent()
        undo.removeAllActions()
    }

    private static func written(_ text: String) -> ScreenGenerator.Update {
        .screen(Outline.parse(text, isComplete: true))
    }

    @Test func aDragIsOneStep() async throws {
        let b = board()
        await clearHistory(b.undo)
        let start = b.model.store.tree
        let drag = b.model.store.beginEdit()
        for frame in 1...20 {
            b.model.store.act(for: drag) { b.model.store.update(b.button.node) { $0.frame.origin.x = 20 + CGFloat(frame) } }
            await nextEvent()
        }
        b.model.store.endEdit(drag)
        let end = b.model.store.tree
        await nextEvent()
        b.undo.undo()
        #expect(b.model.store.tree == start)
        #expect(!b.undo.canUndo)
        b.undo.redo()
        #expect(b.model.store.tree == end)
    }

    @Test(arguments: [true, false])
    func aDragAndATurnAtOnceAreAStepEach(dragEndsFirst: Bool) async throws {
        let b = board()
        await clearHistory(b.undo)
        let start = b.model.store.tree
        b.model.selection = .element(b.title)
        let drag = b.model.store.beginEdit()
        #expect(b.model.beginTurn())
        for frame in 1...20 {
            b.model.store.act(for: drag) { b.model.store.update(b.button.node) { $0.frame.origin.y = 700 - CGFloat(frame) } }
            b.model.turnSelection(by: Double(frame), snaps: false)
            await nextEvent()
        }
        if dragEndsFirst { b.model.store.endEdit(drag) } else { b.model.endTurn() }
        await nextEvent()
        for frame in 21...40 {
            if dragEndsFirst {
                b.model.turnSelection(by: Double(frame), snaps: false)
            } else {
                b.model.store.act(for: drag) { b.model.store.update(b.button.node) { $0.frame.origin.y = 700 - CGFloat(frame) } }
            }
            await nextEvent()
        }
        if dragEndsFirst { b.model.endTurn() } else { b.model.store.endEdit(drag) }
        await nextEvent()
        b.undo.undo()
        let turned = b.model.store.placed(b.title).flatMap { Rotation.kept($0.degrees) } != nil
        let moved = b.model.store.placed(b.button)?.frame.minY != 700
        #expect(turned != moved)
        b.undo.undo()
        #expect(b.model.store.tree == start)
        #expect(!b.undo.canUndo)
    }

    /// A drag during a generation, still going when it finishes, and a template dropped in
    /// the middle of it: a step each, nothing more.
    @Test func aDragDuringAGenerationAndATemplateAreAStepEach() async throws {
        let b = board()
        await clearHistory(b.undo)
        let start = b.model.store.tree
        b.model.generateScreen(from: "a settings screen")
        let generated = try #require(b.model.generation?.screenID)
        await nextEvent()
        b.feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { b.model.store.screenLeaves(generated).count == 1 })
        let drag = b.model.store.beginEdit()
        for frame in 0..<200 {
            b.model.store.act(for: drag) { b.model.store.update(b.button.node) { $0.frame.origin.x = 20 + CGFloat(frame) } }
            if frame == 50 { b.feed.yield(Self.written("title: Settings\nbutton: Save\n")) }
            if frame == 100 { b.model.addTemplate("Sign In") }
            if frame == 150 { b.feed.finish() }
            await nextEvent()
        }
        await b.model.waitForGeneration()
        b.model.store.endEdit(drag)
        await nextEvent()
        #expect(b.model.store.tree.screens.count == 3)
        // The generation finished last and touched nothing else: it goes first.
        b.undo.undo()
        #expect(b.model.store.treeScreen(generated) == nil)
        b.undo.undo()
        b.undo.undo()
        #expect(b.model.store.tree == start)
        #expect(!b.undo.canUndo)
    }

    /// A sketch the Magic Pen reads becomes an element and takes the words written in it in
    /// the same turn of the run loop. Not made for an edit, the two changes were two steps,
    /// and the first undo only put the placeholder back (review N-1).
    @Test func aMagicPenConversionIsOneStep() async throws {
        let b = board()
        await clearHistory(b.undo)
        let start = b.model.store.tree
        b.model.engine.readHandwriting = { _ in "Sign in" }
        let wave = StrokeScript.wave(CGRect(x: 150, y: 300, width: 96, height: 40), humps: 3)
        b.model.sketchChanged([SketchStroke(key: 1, points: wave)])
        b.model.convertNow()
        #expect(await eventually(within: .seconds(10)) { b.model.store.screenLeaves(b.screen).count == 3 })
        // With no ink canvas here, the sketch is taken away by hand.
        b.model.sketchChanged([])
        let added = try #require(b.model.store.screenLeaves(b.screen).last)
        #expect(b.model.store.screenLeaves(b.screen).count == 3)
        #expect(added.content.text == "Sign in")
        await nextEvent()
        b.undo.undo()
        #expect(b.model.store.tree == start)
        #expect(!b.undo.canUndo)
    }

    /// A generation that writes nothing leaves no step, though its step is taken out in
    /// the group it went into, and a step by hand made meanwhile stays the only one.
    @Test func aGenerationThatWritesNothingLeavesOnlyTheHandsStep() async throws {
        let b = board()
        await clearHistory(b.undo)
        b.model.generateScreen(from: "a settings screen")
        await nextEvent()
        b.model.store.update(b.title.node) { $0.content.text = "Mine" }
        await nextEvent()
        b.feed.finish(throwing: URLError(.notConnectedToInternet))
        await b.model.waitForGeneration()
        await nextEvent()
        #expect(b.model.store.tree.screens.count == 1)
        b.undo.undo()
        #expect(b.model.store.node(b.title.node)?.content.text == "Welcome")
        #expect(!b.undo.canUndo)
    }

    /// Undo of a finished screen leaves nothing on no screen (review C-1), and the redo of
    /// a step undone while it was written survives its end (review I-3).
    @Test func undoAndRedoAroundAGenerationKeepTheDesignWhole() async throws {
        let b = board()
        await clearHistory(b.undo)
        b.model.generateScreen(from: "a settings screen")
        let generated = try #require(b.model.generation?.screenID)
        b.feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { b.model.store.screenLeaves(generated).count == 1 })
        let drag = b.model.store.beginEdit()
        b.model.store.act(for: drag) { b.model.store.update(b.button.node) { $0.frame.origin.x += 5 } }
        await nextEvent()
        b.model.store.update(b.title.node) { $0.content.text = "Mine" }
        await nextEvent()
        b.undo.undo()
        #expect(b.undo.canRedo)
        b.feed.finish()
        await b.model.waitForGeneration()
        #expect(b.undo.canRedo)
        b.undo.redo()
        #expect(b.model.store.node(b.title.node)?.content.text == "Mine")
        let dropped = try #require(b.model.store.act(for: drag) {
            b.model.store.move(b.button, toScreen: generated, origin: CGPoint(x: 20, y: 400))
        })
        b.model.store.endEdit(drag)
        await nextEvent()
        while b.undo.canUndo {
            b.undo.undo()
            await nextEvent()
        }
        #expect(b.model.store.placed(b.button)?.frame.minX == 20)
        while b.undo.canRedo {
            b.undo.redo()
            await nextEvent()
        }
        #expect(b.model.store.placed(dropped) != nil)
    }
}
