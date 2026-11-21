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
