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
/// text and a button, and a sticky note on the open canvas beside it.
@MainActor
private struct TurnBoard {
    let model: AppModel
    let screen: DesignScreen.ID
    let title: DesignStore.ElementRef
    let body: DesignStore.ElementRef
    let button: DesignStore.ElementRef
    let note: DesignStore.ElementRef

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
    }

    func canvasFrame(_ ref: DesignStore.ElementRef) -> CGRect {
        store.canvasFrame(of: .element(ref)) ?? .null
    }

    func turn(_ ref: DesignStore.ElementRef, to degrees: Double) {
        store.update(ref) { $0.setRotation(degrees) }
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
        board.turn(board.note, to: 45)
        let shape = try #require(board.store.canvasShape(of: .element(board.note)))
        #expect(board.store.things(enclosedBy: shape.corners) == [.element(board.note)])
    }

    @Test func aLassoRoundOnlyTheEmptyCornersDoesNot() throws {
        let board = TurnBoard()
        board.turn(board.note, to: 45)
        let box = board.canvasFrame(board.note)
        let quarter = CGRect(x: box.minX - 5, y: box.minY - 5, width: box.width / 4 + 5, height: box.height / 4 + 5)
        let corners = [CGPoint(x: quarter.minX, y: quarter.minY), CGPoint(x: quarter.maxX, y: quarter.minY),
                       CGPoint(x: quarter.maxX, y: quarter.maxY), CGPoint(x: quarter.minX, y: quarter.maxY)]
        #expect(board.store.things(enclosedBy: corners).isEmpty)
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
        board.turn(board.note, to: 90)
        let second = board.store.addFloating(element(.stickyNote, 900, 300, 140, 130), scale: 1)
        board.store.align(.several([.element(board.note), .element(second)]), .left)
        #expect(abs(board.canvasFrame(board.note).minX - board.canvasFrame(second).minX) <= 1)
    }
}
