import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Rotation geometry")
struct RotationGeometryTests {
    private func element() -> DesignElement {
        DesignElement(kind: .button, frame: CGRect(x: 20, y: 40, width: 100, height: 30), text: "Go", tint: Theme.accent)
    }

    @Test func anglesAreKeptBetweenZeroAnd360() {
        #expect(Rotation.normalized(-90) == 270)
        #expect(Rotation.normalized(450) == 90)
        #expect(Rotation.normalized(360) == 0)
        #expect(Rotation.normalized(0) == 0)
    }

    @Test func anAngleOfZeroIsNotSaved() {
        var item = element()
        item.setRotation(360)
        #expect(item.rotation == nil)
        item.setRotation(-30)
        #expect(item.rotation == 330)
    }

    @Test func anAngleSnapsToThe45sWhenClose() {
        #expect(Rotation.snapped(43) == (45, true))
        #expect(Rotation.snapped(40) == (40, false))
        #expect(Rotation.snapped(358) == (0, true))
        #expect(Rotation.snapped(-3) == (0, true))
    }

    @Test func aTurnedBoxHoldsItsMiddleButNotItsEmptyCorners() {
        let shape = TurnedRect(rect: CGRect(x: 0, y: 0, width: 100, height: 20), degrees: 45)
        #expect(shape.contains(CGPoint(x: 50, y: 10)))
        #expect(!shape.contains(CGPoint(x: 2, y: 2)))
    }

    @Test func aQuarterTurnStandsABoxOnItsEnd() {
        let shape = TurnedRect(rect: CGRect(x: 0, y: 0, width: 100, height: 20), degrees: 90)
        let bounds = shape.bounds
        #expect(abs(bounds.minX - 40) < 0.001 && abs(bounds.minY + 40) < 0.001)
        #expect(abs(bounds.width - 20) < 0.001 && abs(bounds.height - 100) < 0.001)
        #expect(abs(shape.down.dx + 1) < 0.001 && abs(shape.down.dy) < 0.001)
    }

    @Test func theBoxRoundTurnedBoxesAtTheirAngleHoldsThemAll() throws {
        let first = TurnedRect(rect: CGRect(x: 0, y: 0, width: 80, height: 30), degrees: 30)
        let second = TurnedRect(rect: CGRect(x: 120, y: 90, width: 50, height: 60), degrees: 30)
        let box = try #require(TurnedRect.enclosing([first, second], at: 30))
        #expect(box.degrees == 30)
        for point in first.corners + second.corners {
            #expect(box.contains(point))
        }
        #expect(TurnedRect.enclosing([], at: 30) == nil)
    }

    @Test func anAngleIsSavedAndReadBackAndAnUprightOneIsNotWritten() throws {
        var turned = element()
        turned.setRotation(30)
        let back = try JSONDecoder().decode(DesignElement.self, from: JSONEncoder().encode(turned))
        #expect(back.rotation == 30)

        let upright = try JSONEncoder().encode(element())
        #expect(!String(decoding: upright, as: UTF8.self).contains("\"rotation\""))
        #expect(try JSONDecoder().decode(DesignElement.self, from: upright).rotation == nil)
    }
}

private func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> DesignElement {
    DesignElement(kind: kind, frame: CGRect(x: x, y: y, width: width, height: height), text: kind.placeholder, tint: Theme.accent)
}

/// A board with a screen at (100, 50), drawn at half size, that holds a title, some body
/// text and a button, and a sticky note on the open canvas beside it. Changes made after
/// it is set up can be undone.
@MainActor
private struct TurnBoard {
    let model: AppModel
    let screen: DesignScreen.ID
    let title: DesignStore.ElementRef
    let body: DesignStore.ElementRef
    let button: DesignStore.ElementRef
    let note: DesignStore.ElementRef
    let undo = UndoManager()

    var store: DesignStore { model.store }

    init() {
        model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
        let placed = model.store.setElements([
            element(.title, 80, 100, 228, 40),
            element(.body, 40, 200, 300, 60),
            element(.button, 28, 700, 337, 60),
        ], on: screen, replacing: true)
        (title, body, button) = (placed[0], placed[1], placed[2])
        note = model.store.addFloating(element(.stickyNote, 500, 100, 140, 130), scale: 1)
        undo.groupsByEvent = false
        model.store.undoManager = undo
    }

    func canvasFrame(_ ref: DesignStore.ElementRef) -> CGRect {
        store.canvasFrame(of: .element(ref)) ?? .null
    }

    func turn(_ ref: DesignStore.ElementRef, to degrees: Double) {
        store.update(ref) { $0.setRotation(degrees) }
    }

    func rotation(of ref: DesignStore.ElementRef) -> Double? {
        store.resolve(ref)?.element.rotation
    }
}

@MainActor
@Suite("Turned things on the board")
struct TurnedThingsOnTheBoardTests {
    @Test func aTapInTheEmptyCornerOfATurnedElementMissesIt() throws {
        let board = TurnBoard()
        board.turn(board.button, to: 45)
        let found = try #require(board.store.resolve(board.button))
        let upright = found.placement.canvasRect(for: found.element.frame)
        let corner = board.model.viewport.viewPoint(for: CGPoint(x: upright.minX + 4, y: upright.minY + 4))
        #expect(board.model.hoverTarget(at: corner) == .screen(board.screen))
        let middle = board.model.viewport.viewPoint(for: CGPoint(x: upright.midX, y: upright.midY))
        #expect(board.model.hoverTarget(at: middle) == .element(board.button))
    }

    @Test func aLassoRoundATurnedShapePicksIt() throws {
        let board = TurnBoard()
        board.turn(board.button, to: 45)
        let shape = try #require(board.store.canvasShape(of: .element(board.button)))
        // The turned corners go round all of it, though only a quarter of its upright frame.
        #expect(board.store.things(enclosedBy: shape.corners) == [.element(board.button)])
    }

    @Test func aLassoRoundOnlyTheEmptyCornersDoesNot() throws {
        let board = TurnBoard()
        board.turn(board.button, to: 45)
        // The upright frame's corners go round the button's empty corners and a quarter of it.
        let frame = TurnedRect(rect: try #require(board.store.canvasShape(of: .element(board.button))).rect, degrees: 0)
        #expect(board.store.things(enclosedBy: frame.corners).isEmpty)
    }

    @Test func aTurnedElementTakesUpTheBoxRoundItsShape() throws {
        let board = TurnBoard()
        let rect = board.canvasFrame(board.note)
        board.turn(board.note, to: 30)
        #expect(board.canvasFrame(board.note) == TurnedRect(rect: rect, degrees: 30).bounds)
    }

    @Test func movingSeveralThingsMovesATurnedOneByItsBox() throws {
        let board = TurnBoard()
        board.turn(board.note, to: 30)
        let noteBox = board.canvasFrame(board.note)
        let titleBox = board.canvasFrame(board.title)
        board.store.position([
            .element(board.note): CGPoint(x: noteBox.minX + 10, y: noteBox.minY + 10),
            .element(board.title): CGPoint(x: titleBox.minX + 10, y: titleBox.minY + 10),
        ])
        let moved = board.canvasFrame(board.note)
        #expect(abs(moved.minX - noteBox.minX - 10) <= 1 && abs(moved.minY - noteBox.minY - 10) <= 1)
        #expect(board.store.resolve(board.note)?.element.resolvedRotation == 30)
    }

    @Test func aligningLinesUpTheTurnedShapesBoxes() throws {
        let board = TurnBoard()
        // A long thing stood on end: its box is far narrower than its frame, and it is
        // not the leftmost, so it has to move.
        let long = board.store.addFloating(element(.button, 500, 300, 200, 40), scale: 1)
        board.turn(long, to: 90)
        let second = board.store.addFloating(element(.stickyNote, 300, 100, 140, 130), scale: 1)
        board.store.align(.several([.element(long), .element(second)]), .left)
        #expect(abs(board.canvasFrame(long).minX - 300) <= 1)
        #expect(abs(board.canvasFrame(second).minX - 300) <= 1)
    }
}

@MainActor
@Suite("Turning one element")
struct TurningOneElementTests {
    @Test func resizingATurnedBoxKeepsTheOppositeCornerInPlace() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 50)
        let resized = ElementLayout.resizedTurned(frame, degrees: 30, from: .bottomRight, by: CGSize(width: 40, height: 30), kind: .stickyNote)
        let before = TurnedRect(rect: frame, degrees: 30).corner(.topLeft)
        let after = TurnedRect(rect: resized, degrees: 30).corner(.topLeft)
        #expect(abs(after.x - before.x) <= 0.01 && abs(after.y - before.y) <= 0.01)
        // The drag goes along the box's own axes: (40, 30) turned back by 30° is about
        // (49.6, 6.0), where taken as it was on the glass it would be 40 and 30.
        #expect(resized.size == CGSize(width: 250, height: 56))
    }

    @Test func resizingAnUprightBoxIsAsBefore() {
        // Off whole points, which resizing an upright box rounds and keeping a corner exactly wouldn't.
        let frame = CGRect(x: 100.4, y: 80.3, width: 200, height: 50)
        let drag = CGSize(width: 13.6, height: -7.2)
        for corner in ElementLayout.Corner.allCases {
            #expect(ElementLayout.resizedTurned(frame, degrees: 0, from: corner, by: drag, kind: .stickyNote)
                == ElementLayout.resizedKeepingShape(frame, from: corner, by: drag, kind: .stickyNote))
        }
    }

    @Test func aTurnIsOneUndoStep() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        #expect(board.model.beginTurn())
        #expect(board.model.isTurning && board.model.isAdjusting)
        // A second turn doesn't begin while one is under way.
        #expect(!board.model.beginTurn())
        board.model.turnSelection(by: 10, snaps: false)
        board.model.turnSelection(by: 20, snaps: false)
        board.model.turnSelection(by: 35, snaps: false)
        board.model.endTurn()
        #expect(!board.model.isTurning && !board.model.isAdjusting)
        #expect(board.rotation(of: board.note) == 35)
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
    }

    @Test func aTurnSnapsToThe45sWhenClose() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        board.model.beginTurn()
        #expect(board.model.turnSelection(by: 43, snaps: true))
        #expect(board.rotation(of: board.note) == 45)
        #expect(board.model.snappedTurn == 45)
        #expect(!board.model.turnSelection(by: 30, snaps: true))
        #expect(board.rotation(of: board.note) == 30)
        #expect(board.model.snappedTurn == nil)
        board.model.endTurn()
    }

    @Test func aTurnCarriesOnFromTheAngleItHad() {
        let board = TurnBoard()
        board.turn(board.note, to: 100)
        board.model.selection = .element(board.note)
        board.model.beginTurn()
        board.model.turnSelection(by: 25, snaps: false)
        #expect(board.rotation(of: board.note) == 125)
        board.model.turnSelection(by: 300, snaps: false)
        #expect(board.rotation(of: board.note) == 40)
        board.model.endTurn()
        #expect(board.model.selectionTurn == 40)
    }

    @Test func aLockedElementOrAScreenCannotBeTurned() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        #expect(board.model.canTurnSelection)
        board.store.update(board.note) { $0.isLocked = true }
        #expect(!board.model.canTurnSelection)
        board.model.beginTurn()
        board.model.turnSelection(by: 30, snaps: false)
        #expect(!board.model.isTurning && !board.model.isAdjusting && !board.store.isHoldingEdit)
        board.model.endTurn()
        board.model.rotateSelection(by: 15)
        #expect(board.rotation(of: board.note) == nil)

        // With an element that could turn on its own, the screen alone is what stops it.
        board.store.update(board.note) { $0.isLocked = false }
        let before = board.store.content
        board.model.selection = .screen(board.screen)
        #expect(!board.model.canTurnSelection)
        board.model.selection = .several([.screen(board.screen), .element(board.note)])
        #expect(!board.model.canTurnSelection)
        board.model.beginTurn()
        board.model.turnSelection(by: 30, snaps: false)
        #expect(!board.model.isTurning && !board.store.isHoldingEdit)
        board.model.endTurn()
        #expect(!board.store.isHoldingEdit)
        #expect(board.store.content == before)
    }

    @Test func aTurnDuringASpokenCommandJoinsItsStep() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        // A spoken command holds its step open while it works.
        board.store.beginHeldEdit()
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        // Ending a turn that never began leaves the command's step alone.
        board.model.endTurn()
        #expect(board.store.isHoldingEdit)
        board.model.beginTurn()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        #expect(board.store.isHoldingEdit, "the turn must leave the command's step open")
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.endHeldEdit()
        #expect(board.rotation(of: board.note) == 20)
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 80)
    }

    @Test func aSpokenCommandEndingMidTurnLeavesTheTurnOneStep() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        board.model.beginTurn()
        // A command starts and finishes while the knob is still being turned.
        board.store.beginHeldEdit()
        board.model.turnSelection(by: 10, snaps: false)
        board.store.endHeldEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.turnSelection(by: 30, snaps: false)
        board.model.endTurn()
        #expect(!board.store.isHoldingEdit)
        #expect(board.rotation(of: board.note) == 30)
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
    }

    @Test func aSpokenCommandStartedMidTurnKeepsItsStepAfterTheTurn() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        board.model.beginTurn()
        // A command starts while the knob is being turned, and is still working when it is let go.
        board.store.beginHeldEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        #expect(board.store.isHoldingEdit, "the command's step must still be open")
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.endHeldEdit()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 80)
    }

    @Test func aTurnThatCutsADragShortIsOneStepWithIt() throws {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        let frame = try #require(board.store.resolve(board.note)).element.frame
        // A finger has begun moving the note when the turn begins, and the drag is then ended.
        board.store.beginEdit()
        board.store.update(board.note) { $0.frame.origin.x += 3 }
        board.model.beginTurn()
        board.store.endEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        #expect(!board.store.isHoldingEdit)
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.note)?.element.frame == frame)
    }

    @Test func aTurnNeverClosesAHoldItDidNotOpen() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        board.model.beginTurn()
        // One command comes and goes mid-turn, and another starts before the turn ends.
        board.store.beginHeldEdit()
        board.store.endHeldEdit()
        board.store.beginHeldEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        #expect(board.store.isHoldingEdit, "the second command's step must still be open")
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.endHeldEdit()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 80)
    }

    @Test func aTurnStaysOneStepWhenAnotherEditEndsInsideIt() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        // A command is working; the turn joins its step.
        board.store.beginHeldEdit()
        board.model.beginTurn()
        // Another finger moves the title and lets go while the knob is still held.
        board.store.beginEdit()
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.endEdit()
        board.model.turnSelection(by: 10, snaps: false)
        // The command finishes before the knob is let go.
        board.store.endHeldEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.turnSelection(by: 30, snaps: false)
        board.model.endTurn()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 80)
    }

    @Test func endingAHoldNoCommandOpenedLeavesTheTurnsStepOpen() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        // A finger was already moving the note when the turn began, and has let go.
        board.store.beginEdit()
        board.model.beginTurn()
        board.store.endEdit()
        // A hold is ended though no command has one open; then a command does start.
        board.store.endHeldEdit()
        board.store.beginHeldEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        #expect(board.store.isHoldingEdit, "the command's hold must still be open")
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.endHeldEdit()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 80)
    }

    @Test func aHandleDraggedAndLetGoDuringATurnIsOneStepWithIt() throws {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        let frame = try #require(board.store.resolve(board.note)).element.frame
        board.model.beginTurn()
        board.model.turnSelection(by: 10, snaps: false)
        // A second finger drags a corner handle and lets go while the knob is still held.
        board.store.beginEdit()
        board.store.update(board.note) { $0.frame.size.width += 20 }
        board.store.endEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.note)?.element.frame == frame)
    }

    @Test func aDragGoingOnAfterTheKnobIsLetGoIsOneStepWithTheTurn() throws {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        let frame = try #require(board.store.resolve(board.note)).element.frame
        board.model.beginTurn()
        board.model.turnSelection(by: 10, snaps: false)
        // The one step, in the history from the turn's first change.
        let mark = board.store.historyMark
        // A second finger starts dragging a handle, and is still dragging when the knob is let go.
        board.store.beginEdit()
        board.store.update(board.note) { $0.frame.size.width += 20 }
        board.model.endTurn()
        board.store.update(board.note) { $0.frame.size.width += 20 }
        board.store.update(board.note) { $0.frame.size.width += 20 }
        #expect(board.store.historyMark == mark, "nothing is a step of its own while the finger is still down")
        board.store.endEdit()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.note)?.element.frame == frame)
    }

    @Test func aTurnWhileAScreenIsGeneratedIsOneStepWithIt() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        // A screen being generated opens a step as it starts and closes it when it finishes
        // (`AppModel.generateScreen`), with each streamed update made in between.
        board.store.beginEdit()
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        // The one step, in the history from the edit's first change.
        let mark = board.store.historyMark
        board.model.beginTurn()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        #expect(board.store.historyMark == mark, "nothing is a step of its own while the screen is still being written")
        board.store.endEdit()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 80)
    }

    @Test func aCommandStartedDuringATurnThatCutADragShortKeepsItsStep() throws {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        let frame = try #require(board.store.resolve(board.note)).element.frame
        // As two fingers twisting begin: one finger was already moving the note, and that
        // drag ends as the turn begins.
        board.store.beginEdit()
        board.store.update(board.note) { $0.frame.origin.x += 3 }
        // The one step, in the history from the drag's first change.
        let mark = board.store.historyMark
        board.model.beginTurn()
        board.store.endEdit()
        // A command starts during the turn, and is still working when the turn ends.
        board.store.beginHeldEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        #expect(board.store.isHoldingEdit, "the command's step must still be open")
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        #expect(board.store.historyMark == mark)
        board.store.endHeldEdit()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.note)?.element.frame == frame)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 80)
    }

    /// The format panel's pause ends its own part of the step, made just before a turn or
    /// during it: the turn's end leaves a part by hand open, so a panel that took the turn
    /// for another's edit by hand left the step open for good once the turn ended.
    @Test(arguments: [true, false])
    func aPanelChangeAroundATurnLeavesNoEditOpen(panelFirst: Bool) async throws {
        let board = TurnBoard()
        board.model.adjustmentPause = .milliseconds(20)
        board.model.selection = .element(board.note)
        let before = board.store.content
        let panel = { board.model.adjusting { board.store.update(board.title) { $0.frame.origin.x += 10 } } }
        if panelFirst {
            panel()
            board.model.beginTurn()
        } else {
            board.model.beginTurn()
            panel()
        }
        board.model.turnSelection(by: 20, snaps: false)
        try await Task.sleep(for: .milliseconds(150))
        board.model.endTurn()
        for _ in 0..<100 where board.store.isEditing {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!board.store.isEditing)
        board.undo.undo()
        #expect(board.store.content == before, "the panel's change and the turn are one step")
    }

    /// A turn the knob left live as the design closes is ended with it, as a drag is.
    @Test func closingMidTurnEndsTheTurn() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        board.model.beginTurn()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.close()
        #expect(!board.model.isTurning)
        #expect(!board.store.isEditing)
        #expect(board.model.document.current.content.element(board.note.element)?.rotation == 20)
    }

    @Test func resettingTheTurnStandsItUpright() {
        let board = TurnBoard()
        board.turn(board.note, to: 70)
        board.model.selection = .element(board.note)
        board.model.resetSelectionTurn()
        #expect(board.rotation(of: board.note) == nil)
        board.undo.undo()
        #expect(board.rotation(of: board.note) == 70)
    }

    @Test func rotatingBySteps() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        board.model.rotateSelection(by: -15)
        #expect(board.rotation(of: board.note) == 345)
        board.model.rotateSelection(by: 30)
        #expect(board.rotation(of: board.note) == 15)
        board.undo.undo()
        #expect(board.rotation(of: board.note) == 345)
    }

    @Test func theKnobHangsBelowTheElementInItsOwnAxes() throws {
        let board = TurnBoard()
        board.model.viewport = Viewport(offset: CGPoint(x: 40, y: 20), scale: 2)
        // The button is 168.5 by 30 on the canvas: stood on end, its own bottom faces left.
        board.turn(board.button, to: 90)
        board.model.selection = .element(board.button)
        let shape = board.model.viewport.viewShape(for: try #require(board.model.selectionShape))
        let knob = try #require(board.model.knobViewPoint)
        #expect(abs(knob.x - (shape.centre.x - 30 - AppModel.knobStem)) < 0.01)
        #expect(abs(knob.y - shape.centre.y) < 0.01)
    }

    @Test func thePopoverKeepsClearOfTheKnob() throws {
        let board = TurnBoard()
        // Turned a little, the note's knob hangs below the box round its shape.
        board.turn(board.note, to: 10)
        board.model.selection = .element(board.note)
        let knob = try #require(board.model.knobViewPoint)
        let area = try #require(board.model.selectionViewRect)
        #expect(area.contains(knob))
        let shape = board.model.viewport.viewShape(for: try #require(board.model.selectionShape))
        #expect(area.contains(shape.bounds))
    }

    @Test func aTurnedElementIsWhereItsShapeIs() throws {
        let board = TurnBoard()
        board.turn(board.button, to: 90)
        let rect = try #require(board.model.viewRect(of: .element(board.button)))
        // Stood on end, the 168.5 by 30 button takes up a box 30 wide and 168.5 tall.
        #expect(abs(rect.width - 30) < 0.01 && abs(rect.height - 168.5) < 0.01)
    }
}

/// An element's frame, in its host's points, and its angle, as the design keeps them.
private struct Placed: Equatable {
    var frame: CGRect
    var rotation: Double?
}

private extension TurnBoard {
    func placed(_ refs: [DesignStore.ElementRef]) -> [Placed?] {
        refs.map { ref in store.resolve(ref).map { Placed(frame: $0.element.frame, rotation: $0.element.rotation) } }
    }

    /// The middle of an element on the canvas, which it turns about on its own.
    func centre(of ref: DesignStore.ElementRef) -> CGPoint {
        store.canvasShape(of: .element(ref))?.centre ?? CGPoint(x: CGFloat.nan, y: .nan)
    }

    /// An element's own frame on the canvas, before it is turned.
    func canvasRect(_ ref: DesignStore.ElementRef) -> CGRect {
        store.canvasShape(of: .element(ref))?.rect ?? .null
    }

    /// Selects several elements together, as a lasso round them would.
    func select(_ refs: [DesignStore.ElementRef]) {
        model.selection = CanvasSelection(refs.map { .element($0) })
    }

    /// One turn of the knob: taken hold of, turned through each angle in turn (each the
    /// whole turn since it was taken hold of), and let go.
    func knobTurn(_ angles: Double...) {
        model.beginTurn()
        for angle in angles { model.turnSelection(by: angle, snaps: true) }
        model.endTurn()
    }

    /// A drawing on the open canvas off whole points: where it is doesn't survive the
    /// arithmetic of being turned there and back unless it is put back exactly.
    func addDrawing() -> DesignStore.ElementRef {
        store.addFloating(element(.drawing, 612.37, 288.91, 87.13, 41.77), scale: 1)
    }
}

private func isClose(_ a: CGPoint, _ b: CGPoint, within slack: CGFloat = 1) -> Bool {
    abs(a.x - b.x) <= slack && abs(a.y - b.y) <= slack
}

@MainActor
@Suite("Turning several things")
struct TurningSeveralThingsTests {
    @Test func turningSeveralThingsAndBackPutsEverythingExactlyWhereItWas() throws {
        let board = TurnBoard()
        // Two on the half-size screen, a note and a drawing on the open canvas.
        let things = [board.title, board.button, board.note, board.addDrawing()]
        board.select(things)
        let before = board.placed(things)
        #expect(board.model.beginTurn())
        board.model.turnSelection(by: 37, snaps: true)
        for (ref, was) in zip(things, before) {
            #expect(board.rotation(of: ref) == 37)
            // Each has gone round the middle of them all, not stayed about its own.
            #expect(board.placed([ref])[0]?.frame != was?.frame)
        }
        board.model.turnSelection(by: 0, snaps: true)
        board.model.endTurn()
        #expect(board.placed(things) == before)
    }

    @Test func manySmallTurnsDoNotDrift() {
        let board = TurnBoard()
        let things = [board.title, board.button, board.note, board.addDrawing()]
        board.select(things)
        let before = board.placed(things)
        board.model.beginTurn()
        for step in 1...90 { board.model.turnSelection(by: Double(step), snaps: true) }
        board.model.endTurn()
        #expect(things.allSatisfy { board.rotation(of: $0) == 90 })
        for _ in 0..<3 { board.knobTurn(30) }
        #expect(things.allSatisfy { board.rotation(of: $0) == 180 })
        board.knobTurn(-180)
        board.model.resetSelectionTurn()
        #expect(board.placed(things) == before)
    }

    @Test func severalThingsTurnAboutTheMiddleOfTheirOutline() throws {
        let board = TurnBoard()
        // Two notes of different sizes, neither in the middle of the pair.
        let other = board.store.addFloating(element(.stickyNote, 720, 330, 100, 60), scale: 1)
        let things = [board.note, other]
        board.select(things)
        let outline = board.canvasFrame(board.note).union(board.canvasFrame(other))
        let middle = CGPoint(x: outline.midX, y: outline.midY)
        #expect(isClose(try #require(board.model.selectionShape).centre, middle, within: 0.001))
        let centres = things.map(board.centre(of:))
        board.knobTurn(180)
        for (ref, centre) in zip(things, centres) {
            #expect(board.rotation(of: ref) == 180)
            #expect(isClose(board.centre(of: ref), CGPoint(x: 2 * middle.x - centre.x, y: 2 * middle.y - centre.y)))
        }
    }

    @Test func aLockedMemberStaysWhileTheRestTurn() {
        let board = TurnBoard()
        board.store.update(board.note) { $0.isLocked = true }
        board.select([board.title, board.button, board.note])
        let note = board.placed([board.note])
        // The note is far to the right: the middle the others turn about is pulled towards it.
        let outline = board.canvasFrame(board.title).union(board.canvasFrame(board.button)).union(board.canvasFrame(board.note))
        let pivot = CGPoint(x: outline.midX, y: outline.midY)
        let turning = [board.title, board.button]
        let centres = turning.map(board.centre(of:))
        #expect(board.model.canTurnSelection)
        board.knobTurn(50)
        #expect(board.placed([board.note]) == note)
        for (ref, centre) in zip(turning, centres) {
            #expect(board.rotation(of: ref) == 50)
            #expect(isClose(board.centre(of: ref), Rotation.rotate(centre, about: pivot, by: 50)))
        }
    }

    @Test func turningNeverMovesAnElementOffItsScreen() throws {
        let board = TurnBoard()
        let far = board.store.addFloating(element(.stickyNote, 1200, 600, 140, 130), scale: 1)
        board.select([board.button, far])
        let outline = board.canvasFrame(board.button).union(board.canvasFrame(far))
        let wanted = Rotation.rotate(board.centre(of: board.button), about: CGPoint(x: outline.midX, y: outline.midY), by: 90)
        // A quarter turn swings the button's middle well off its screen.
        let screen = try #require(board.store.screen(board.screen))
        #expect(!screen.canvasFrame.contains(wanted))
        board.knobTurn(90)
        #expect(board.rotation(of: board.button) == 90)
        #expect(isClose(board.centre(of: board.button), wanted))
        // It still belongs to the screen, overhanging it.
        #expect(board.store.element(board.button.element)?.parent == board.screen)
        #expect(board.model.selection == CanvasSelection([.element(board.button), .element(far)]))
    }

    @Test func afterAMoveTheyTurnAboutTheirNewMiddle() throws {
        let board = TurnBoard()
        // Angles that differ, so that after the turn their outline, formed afresh, would be
        // upright with another middle: only the pivot moved with them turns them back.
        board.turn(board.note, to: 20)
        let things = [board.title, board.button, board.note]
        board.select(things)
        let before = things.map(board.canvasRect)
        board.knobTurn(30)
        #expect(board.rotation(of: board.title) == 30 && board.rotation(of: board.note) == 50)

        board.model.selectionWillMove()
        var origins: [CanvasSelection: CGPoint] = [:]
        for ref in things {
            let box = board.canvasFrame(ref)
            origins[.element(ref)] = CGPoint(x: box.minX + 100, y: box.minY)
        }
        board.store.position(origins)
        board.model.selectionMoved(by: CGSize(width: 100, height: 0))
        #expect(board.model.selectionTurn == 30)

        board.knobTurn(-30)
        for (ref, was) in zip(things, before) {
            let now = board.canvasRect(ref)
            #expect(isClose(now.origin, CGPoint(x: was.minX + 100, y: was.minY)) && now.size == was.size)
        }
        #expect(board.rotation(of: board.title) == nil && board.rotation(of: board.button) == nil && board.rotation(of: board.note) == 20)
    }

    @Test func afterAMoveOffWholePointsTheyTurnBackOntoWholePoints() {
        let board = TurnBoard()
        let things = [board.title, board.button, board.note]
        board.select(things)
        let before = things.map(board.canvasRect)
        board.knobTurn(30)
        // A finger's drag is seldom a whole number of points.
        let delta = CGSize(width: 33.3, height: 12.7)
        board.model.selectionWillMove()
        var origins: [CanvasSelection: CGPoint] = [:]
        for ref in things {
            let box = board.canvasFrame(ref)
            origins[.element(ref)] = CGPoint(x: box.minX + delta.width, y: box.minY + delta.height)
        }
        board.store.position(origins)
        board.model.selectionMoved(by: delta)
        board.knobTurn(-30)
        for (ref, was) in zip(things, before) {
            let frame = board.placed([ref])[0]?.frame ?? .null
            // Back upright, each is on whole points of its own, as if it had been moved upright.
            #expect(frame.minX == frame.minX.rounded() && frame.minY == frame.minY.rounded())
            #expect(isClose(board.canvasRect(ref).origin, CGPoint(x: was.minX + delta.width, y: was.minY + delta.height)))
        }
    }

    @Test func undoAfterATurnFormsTheNextTurnFromWhereThingsAre() {
        let board = TurnBoard()
        let things = [board.title, board.button, board.note]
        board.select(things)
        let before = board.placed(things)
        board.knobTurn(40)
        #expect(things.allSatisfy { board.rotation(of: $0) == 40 })
        board.undo.undo()
        #expect(board.placed(things) == before)
        #expect(board.model.beginTurn())
        board.model.turnSelection(by: 0, snaps: true)
        board.model.endTurn()
        #expect(board.placed(things) == before)
        #expect(board.model.selectionTurn == 0)
    }

    @Test func theKnobsDoubleTapReturnsEverythingToWhereTheSelectionFormed() {
        let board = TurnBoard()
        // One of them is turned already: it goes back to its own angle, not upright.
        board.turn(board.note, to: 15)
        let things = [board.title, board.button, board.note]
        board.select(things)
        let before = board.placed(things)
        board.knobTurn(30)
        board.knobTurn(20)
        #expect(board.model.selectionTurn == 50)
        #expect(things.map(board.rotation(of:)) == [50, 50, 65])
        let turned = board.placed(things)
        board.model.resetSelectionTurn()
        #expect(board.placed(things) == before)
        #expect(board.model.selectionTurn == 0)
        board.undo.undo()
        #expect(board.placed(things) == turned)
    }

    @Test func aSelectionWithAScreenCannotTurn() throws {
        let board = TurnBoard()
        let selection = CanvasSelection.several([.screen(board.screen), .element(board.note)])
        #expect(TurnSession.form(for: selection, in: board.store) == nil)
        board.model.selection = selection
        let before = board.store.content
        #expect(!board.model.canTurnSelection)
        #expect(board.model.knobViewPoint == nil)
        #expect(!board.model.beginTurn())
        #expect(!board.model.turnSelection(by: 30, snaps: false))
        board.model.endTurn()
        board.model.rotateSelection(by: 15)
        board.model.resetSelectionTurn()
        #expect(board.store.content == before)
        #expect(!board.store.isHoldingEdit)
        // It is still outlined, upright, round everything in it.
        let area = try #require(board.store.canvasFrame(of: selection))
        #expect(board.model.selectionShape == TurnedRect(rect: area, degrees: 0))

        // Without the screen, the same sort of selection turns.
        board.select([board.title, board.note])
        #expect(board.model.canTurnSelection)
        #expect(board.model.knobViewPoint != nil)
        #expect(board.model.beginTurn())
        board.model.endTurn()
    }

    @Test func theOutlineTurnsWhenEveryMemberSharesAnAngle() throws {
        let board = TurnBoard()
        let other = board.store.addFloating(element(.stickyNote, 720, 330, 100, 60), scale: 1)
        board.select([board.note, other])
        let pivot = try #require(board.model.selectionShape).centre
        board.knobTurn(30)
        board.model.selection = nil
        board.select([board.note, other])
        let shape = try #require(board.model.selectionShape)
        #expect(shape.degrees == 30)
        #expect(isClose(shape.centre, pivot))
        // Selected again, the selection has formed anew: its knob starts from 0.
        #expect(board.model.selectionTurn == 0)
        // Once their angles differ, the outline stands upright round them.
        board.store.update(other) { $0.setRotation(45) }
        #expect(try #require(board.model.selectionShape).degrees == 0)
    }

    @Test func aMemberLockedAfterATurnStaysWhereItIs() {
        let board = TurnBoard()
        let things = [board.title, board.button, board.note]
        board.select(things)
        board.knobTurn(30)
        // Locked from its row in the layers list, which leaves the selection as it is.
        board.model.toggleLock(board.button)
        let button = board.placed([board.button])
        board.knobTurn(20)
        #expect(board.placed([board.button]) == button)
        #expect(board.rotation(of: board.title) == 50 && board.rotation(of: board.note) == 50)
        board.model.resetSelectionTurn()
        #expect(board.placed([board.button]) == button)
        #expect(board.rotation(of: board.title) == 30 && board.rotation(of: board.note) == 30)
    }

    @Test func aMemberUnlockedAfterATurnTurnsWithTheRest() {
        let board = TurnBoard()
        board.store.update(board.button) { $0.isLocked = true }
        let things = [board.title, board.button, board.note]
        board.select(things)
        board.knobTurn(30)
        #expect(things.map(board.rotation(of:)) == [30, nil, 30])
        board.model.toggleLock(board.button)
        board.knobTurn(20)
        #expect(things.map(board.rotation(of:)) == [50, 20, 50])
    }

    @Test func aMemberDroppedOffItsScreenKeepsTurningWithTheRest() {
        let board = TurnBoard()
        let far = board.store.addFloating(element(.stickyNote, 1200, 600, 140, 130), scale: 1)
        let things = [board.button, far]
        board.select(things)
        let before = things.map(board.canvasRect)
        // The quarter turn swings the button's middle off its screen (see
        // `turningNeverMovesAnElementOffItsScreen`); dragged a little and dropped there, it
        // belongs to the open canvas.
        board.knobTurn(90)
        let delta = CGSize(width: 10, height: 6)
        board.model.selectionWillMove()
        var origins: [CanvasSelection: CGPoint] = [:]
        for ref in things {
            let box = board.canvasFrame(ref)
            origins[.element(ref)] = CGPoint(x: box.minX + delta.width, y: box.minY + delta.height)
        }
        board.store.position(origins)
        board.model.selectionMoved(by: delta)
        board.model.rehostSelection()
        let button = DesignStore.ElementRef(host: .canvas, element: board.button.element)
        #expect(board.model.selection == CanvasSelection([.element(button), .element(far)]))
        // Still the same turn: the knob reads it, and a double tap undoes it.
        #expect(board.model.selectionTurn == 90)
        board.model.resetSelectionTurn()
        for (ref, was) in zip([button, far], before) {
            let now = board.canvasRect(ref)
            #expect(isClose(now.origin, CGPoint(x: was.minX + delta.width, y: was.minY + delta.height)) && now.size == was.size)
            #expect(board.rotation(of: ref) == nil)
        }
    }
}

@MainActor
@Suite("The Rotation field")
struct RotationFieldTests {
    @Test func aWrappingValuePassesRoundThe360() {
        #expect(Scrubber.value(from: 350, steps: 15, in: 0...360, wraps: true) == 5)
        #expect(Scrubber.value(from: 5, steps: -10, in: 0...360, wraps: true) == 355)
        #expect(Scrubber.value(from: 350, steps: 15, in: 0...360) == 360)
    }

    @Test func theRotationRulerTakesTwoPointsADegree() {
        #expect(Scrubber.steps(forDrag: 90, pointsPerStep: 2) == 45)
        #expect(Scrubber.steps(forDrag: 90) == 11)
    }

    @Test func theBarrelTurnsItOneToOne() {
        #expect(Scrubber.steps(forRoll: .degrees(30), degreesPerStep: 1) == 30)
        #expect(Scrubber.steps(forRoll: .degrees(30)) == 3)
    }

    @Test func aTypedAngleWrapsRatherThanStops() {
        #expect(Scrubber.typed(-90, in: 0...360, wraps: true) == 270)
        #expect(Scrubber.typed(450, in: 0...360, wraps: true) == 90)
        #expect(Scrubber.typed(5000, in: 1...4000, wraps: false) == 4000)
    }

    @Test func aScrubStepOnlyTicksOnTheMarks() {
        let scrubber = Scrubber()
        var value: CGFloat = 0
        var ticks: [CGFloat] = []
        scrubber.onStep = { _ in ticks.append(value) }
        scrubber.begin(Scrubber.Target(
            label: "Rotation", unit: "°", frame: .zero, range: 0...360,
            get: { value }, set: { value = $0 },
            pointsPerStep: 2, degreesPerStep: 1, wraps: true, ticksEvery: 15
        ))
        for steps in 1...31 { scrubber.scrub(to: steps) }
        #expect(ticks == [15, 30])
        scrubber.end()
        // Wrapping back past zero.
        scrubber.begin(Scrubber.Target(
            label: "Rotation", unit: "°", frame: .zero, range: 0...360,
            get: { 3 }, set: { value = $0 },
            wraps: true
        ))
        scrubber.scrub(to: -5)
        #expect(value == 358)
    }

    @Test func settingTheAngleOfSeveralSetsEachOnItsOwn() {
        let board = TurnBoard()
        board.store.update(board.note) { $0.setRotation(10) }
        board.select([board.title, board.note])
        let before = [board.title, board.note].map(board.canvasRect)
        board.model.changeSelectedElements(where: { !$0.isLocked }) { $0.setRotation(30) }
        #expect(board.rotation(of: board.title) == 30 && board.rotation(of: board.note) == 30)
        #expect([board.title, board.note].map(board.canvasRect) == before)
    }

    @Test func anAngleThatIsNotANumberIsUpright() {
        #expect(Rotation.normalized(.nan) == 0)
        #expect(Rotation.normalized(.infinity) == 0)
        #expect(Rotation.normalized(-.infinity) == 0)
        #expect(Rotation.kept(.nan) == nil)
        #expect(Rotation.normalized(-90) == 270)
    }
}
