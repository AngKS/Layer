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
        let screen: DesignScreen.ID
        let title: DesignStore.ElementRef
        let button: DesignStore.ElementRef
        var store: DesignStore { model.store }

        func frame(of ref: DesignStore.ElementRef) -> CGRect? { store.resolve(ref)?.element.frame }
        func rotation(of ref: DesignStore.ElementRef) -> Double? { store.resolve(ref)?.element.rotation }
    }

    /// A screen with a title and a button, and an empty history. Generations are written
    /// by the test, a line at a time.
    private func board() -> (Board, AsyncThrowingStream<ScreenGenerator.Update, any Error>.Continuation) {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = AppModel(document: LayerDocument())
        model.store.undoManager = undo
        model.adjustmentPause = .seconds(60)
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let refs = model.store.setElements([
            DesignElement(kind: .title, frame: CGRect(x: 20, y: 80, width: 353, height: 40), text: "Welcome", tint: Theme.accent),
            DesignElement(kind: .button, frame: CGRect(x: 20, y: 700, width: 353, height: 50), text: "Go", tint: Theme.accent),
        ], on: screen.id, replacing: false)
        undo.removeAllActions()
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        model.screenStream = { _, _, _ in stream }
        return (Board(model: model, undo: undo, screen: screen.id, title: refs[0], button: refs[1]), feed)
    }

    private static func written(_ text: String) -> ScreenGenerator.Update {
        .screen(ScreenGenerator.blueprint(ofFinishedLinesIn: text, isComplete: true)!)
    }

    /// A finger drags the button while the knob turns the title. Whichever ends first, the
    /// other goes on as its own step: two steps, each taken back whole.
    @Test(arguments: [true, false])
    func aDragAndATurnAtOnceAreAStepEachEndedInEitherOrder(dragEndsFirst: Bool) throws {
        let (board, _) = board()
        let start = board.store.content
        let buttonFrame = try #require(board.frame(of: board.button))
        board.model.selection = .element(board.title)

        board.store.beginEdit()
        board.store.update(board.button) { $0.frame.origin.y -= 1 }
        #expect(board.model.beginTurn())
        board.model.turnSelection(by: 10, snaps: false)
        board.store.update(board.button) { $0.frame.origin.y -= 1 }
        if dragEndsFirst {
            board.store.endEdit()
            for degrees in 11...70 { board.model.turnSelection(by: Double(degrees), snaps: false) }
            board.model.endTurn()
        } else {
            board.model.endTurn()
            for _ in 0..<60 { board.store.update(board.button) { $0.frame.origin.y -= 1 } }
            board.store.endEdit()
        }
        #expect(!board.store.isEditing)

        board.undo.undo()
        // One of them is taken back whole; the other is as it ended.
        let turned = board.rotation(of: board.title) != nil
        let moved = board.frame(of: board.button) != buttonFrame
        #expect(turned != moved)
        board.undo.undo()
        #expect(board.store.content == start)
        #expect(!board.undo.canUndo)
    }

    /// A template added, or a Siri action, in the middle of a drag: its begin and end used
    /// to close the drag's step, and the drag's remaining frames were each a step (M3).
    @Test(arguments: ["template", "Siri"])
    func aOneShotEditDuringADragLeavesTheDragOneStep(oneShot: String) throws {
        let (board, _) = board()
        let start = board.store.content
        board.store.beginEdit()
        board.store.update(board.button) { $0.frame.origin.y -= 1 }
        if oneShot == "template" {
            board.model.addTemplate("Sign In")
            #expect(board.store.screens.count == 2)
        } else {
            DesignActions.edit(board.model, undoManager: nil, actionName: "Rename") {
                board.store.updateScreen(board.screen) { $0.name = "Renamed" }
            }
        }
        for _ in 0..<60 { board.store.update(board.button) { $0.frame.origin.y -= 1 } }
        #expect(board.store.isEditing, "the drag's step is still open")
        board.store.endEdit()

        board.undo.undo()
        // The one-shot is taken back; the drag stays where it ended.
        #expect(board.store.screens.count == 1)
        #expect(board.store.screen(board.screen)?.name == start.screens.first?.name)
        let draggedTo: CGFloat = 700 - 61
        #expect(board.frame(of: board.button)?.minY == draggedTo)
        board.undo.undo()
        #expect(board.store.content == start)
        #expect(!board.undo.canUndo)
    }

    /// A 200-frame drag made while a screen is written, begun after its first line and
    /// still going when it finishes, is one step, and the screen another. The screen's,
    /// finished last, is taken back first, and the drag's frames after it are still the
    /// drag's (C1, G4, M2).
    @Test func aLongDragDuringAGenerationIsOneDragStepAndOneGenerationStep() async throws {
        let (board, feed) = board()
        let start = board.store.content
        board.model.generateScreen(from: "a settings screen")
        let generated = try #require(board.model.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { board.store.screen(generated)?.elements.count == 1 })

        board.store.beginEdit()
        for frame in 0..<100 { board.store.update(board.button) { $0.frame.origin.x = 20 + CGFloat(frame) } }
        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        #expect(await eventually { board.store.screen(generated)?.elements.count == 2 })
        for frame in 100..<150 { board.store.update(board.button) { $0.frame.origin.x = 20 + CGFloat(frame) } }
        feed.yield(Self.written("title: Settings\nbutton: Save\ntext: Notifications\n"))
        feed.finish()
        await board.model.waitForGeneration()
        #expect(board.store.screen(generated)?.elements.count == 3)
        // The generation's end leaves the drag going (G4, M2).
        #expect(board.store.isEditing(by: .hand))
        for frame in 150..<200 { board.store.update(board.button) { $0.frame.origin.x = 20 + CGFloat(frame) } }
        board.store.endEdit()

        board.undo.undo()
        #expect(board.store.screen(generated) == nil)
        #expect(board.frame(of: board.button)?.minX == 219)
        board.undo.undo()
        #expect(board.store.content == start)
        #expect(!board.undo.canUndo)
    }

    /// Two edits whose changes interleave, on the same element among others: undoing one
    /// takes back its own changes, what it took away comes back where it was, and the
    /// other's changes, made between its own, stay. Redo puts them back.
    @Test func undoingOneEditLeavesWhatAnotherDidMeanwhile() throws {
        let (board, _) = board()
        let store = board.store
        let start = store.content
        let extra = { (text: String) in DesignElement(kind: .body, frame: CGRect(x: 20, y: 300, width: 200, height: 40), text: text, tint: Theme.accent) }
        let a = store.beginEdit(by: .app)
        let b = store.beginEdit(by: .app)
        store.act(for: a) { store.update(board.title) { $0.text = "A" } }
        store.act(for: b) {
            store.update(board.title) { $0.frame.origin.x += 5 }
            store.delete(board.button)
            _ = store.setElements([extra("From B")], on: board.screen, replacing: false)
        }
        store.act(for: a) {
            store.update(board.title) { $0.text = "AA" }
            _ = store.setElements([extra("From A")], on: board.screen, replacing: false)
        }
        store.endEdit(b)
        store.endEdit(a)
        let end = store.content

        // A's step went in first, so B's is on top: its move, delete and add are taken back,
        // and A's words and element stay.
        board.undo.undo()
        let screen = try #require(store.screen(board.screen))
        #expect(screen.elements.map(\.text) == ["AA", "Go", "From A"])
        #expect(board.frame(of: board.title)?.minX == 20)
        board.undo.undo()
        #expect(store.content == start)
        board.undo.redo()
        board.undo.redo()
        #expect(store.content == end)
    }

    /// A finger picks something up while a screen is written and drops it on that screen
    /// once it is finished. Undoing the screen, on top as the last thing finished, took the
    /// screen away and left what was dropped on it on no screen: invisible, and saved so
    /// (review C-1). It goes onto the open canvas where it was, and the drag's own undo
    /// then puts it back where it came from.
    @Test func undoingAGenerationLeavesNothingOnNoScreen() async throws {
        let (board, feed) = board()
        let start = board.store.content
        board.model.generateScreen(from: "a settings screen")
        let generated = try #require(board.model.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { board.store.screen(generated)?.elements.count == 1 })
        let drag = board.store.beginEdit()
        board.store.act(for: drag) { board.store.update(board.button) { $0.frame.origin.x += 5 } }
        feed.finish()
        await board.model.waitForGeneration()
        let dropped = try #require(board.store.act(for: drag) {
            board.store.move(board.button, toScreen: generated, origin: CGPoint(x: 20, y: 400))
        })
        board.store.endEdit(drag)
        let onScreen = try #require(board.store.resolve(dropped))

        board.undo.undo()
        #expect(board.store.screen(generated) == nil)
        #expect(board.store.content.elementsOnMissingScreens.isEmpty)
        let floating = try #require(board.store.floating.first { $0.id == dropped.element })
        // Where it was on the canvas, at the screen's scale.
        #expect(floating.canvasFrame == onScreen.placement.canvasRect(for: onScreen.element.frame))
        board.undo.redo()
        #expect(board.store.resolve(dropped) != nil)
        board.undo.undo()
        board.undo.undo()
        #expect(board.store.content == start)
        #expect(board.store.content.elementsOnMissingScreens.isEmpty)
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
        let refs = store.setElements([
            DesignElement(kind: .title, frame: CGRect(x: 20, y: 80, width: 353, height: 40), text: "Welcome", tint: Theme.accent),
            DesignElement(kind: .button, frame: CGRect(x: 20, y: 700, width: 353, height: 50), text: "Go", tint: Theme.accent),
        ], on: screen.id, replacing: false)
        undo.removeAllActions()
        let start = store.content
        let erasing = store.beginEdit()
        let writing = store.beginEdit(by: .app)
        store.act(for: erasing) { store.update(refs[0]) { $0.text = "1" } }
        var follows = true
        store.onChange = { _ in
            guard follows else { return }
            follows = false
            store.act(for: erasing) { store.update(refs[0]) { $0.text = "2" } }
        }
        store.act(for: writing) { store.update(refs[1]) { $0.frame.origin.y = 600 } }
        store.onChange = nil
        store.endEdit(writing)
        store.endEdit(erasing)

        // The line's step takes back the line, and leaves the erasure whole.
        undo.undo()
        #expect(store.resolve(refs[0])?.element.text == "2")
        #expect(store.resolve(refs[1])?.element.frame.minY == 700)
        undo.undo()
        #expect(store.content == start)
    }

    /// A screen finishing used to move its step to the top of the history, and registering
    /// a step clears Redo: what the person had just undone could no longer be redone
    /// (review I-3).
    @Test func aGenerationFinishingKeepsRedo() async throws {
        let (board, feed) = board()
        board.model.generateScreen(from: "a settings screen")
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { board.model.generation?.elementCount == 1 })
        board.store.update(board.title) { $0.text = "Hello" }
        board.store.update(board.button) { $0.text = "Next" }
        board.undo.undo()
        #expect(board.undo.canRedo)
        feed.finish()
        await board.model.waitForGeneration()
        #expect(board.undo.canRedo)
        board.undo.redo()
        #expect(board.store.resolve(board.button)?.element.text == "Next")
    }

    /// A drag and a turn whose frames take turns: each step used to start a new run, two
    /// whole designs kept, at every frame of the other (review M-1). A run goes on over
    /// what the other changed meanwhile when that touched nothing of the run's.
    @Test func editsTakingTurnsFrameByFrameKeepFewRuns() throws {
        let (board, _) = board()
        let start = board.store.content
        board.model.selection = .element(board.title)
        let drag = board.store.beginEdit()
        #expect(board.model.beginTurn())
        for frame in 1...200 {
            board.store.act(for: drag) { board.store.update(board.button) { $0.frame.origin.x = 20 + CGFloat(frame) } }
            board.model.turnSelection(by: Double(frame) / 10, snaps: false)
        }
        #expect(board.store.recordedRuns(of: drag) <= 2)
        board.store.endEdit(drag)
        board.model.endTurn()
        board.undo.undo()
        board.undo.undo()
        #expect(board.store.content == start)
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
        #expect(board.store.screen(generated)?.elements.count == 2)
        board.undo.undo()
        #expect(board.store.screen(generated) == nil)
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
        #expect(await eventually { board.store.screen(generated)?.elements.count == 1 })
        board.store.beginEdit()
        board.store.setTitle("Mine")
        board.store.endEdit()
        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        feed.yield(Self.written("title: Settings\nbutton: Save\ntext: Notifications\n"))
        feed.finish()
        await board.model.waitForGeneration()
        #expect(board.store.screen(generated)?.elements.count == 3)

        board.undo.undo()
        #expect(board.store.screen(generated) == nil)
        #expect(board.store.title == "Mine")
        board.undo.undo()
        #expect(board.store.title == nil)
        #expect(!board.undo.canUndo)
    }
}
