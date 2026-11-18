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

    @Test func aTurnClosesOnlyTheHoldItOpened() {
        let board = TurnBoard()
        board.model.selection = .element(board.note)
        // A finger is already moving the note, so the turn holds its step open itself.
        board.store.beginEdit()
        board.model.beginTurn()
        board.store.endEdit()
        // A command closes that hold and opens one of its own, as an undo it is asked for does.
        board.store.endHeldEdit()
        board.store.beginHeldEdit()
        board.model.turnSelection(by: 20, snaps: false)
        board.model.endTurn()
        #expect(board.store.isHoldingEdit, "the command's own hold must still be open")
        board.store.update(board.title) { $0.frame.origin.x += 10 }
        board.store.endHeldEdit()
        board.undo.undo()
        #expect(board.rotation(of: board.note) == nil)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 80)
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
