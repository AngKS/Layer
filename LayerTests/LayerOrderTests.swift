import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

/// The one board the layer-order and group tests build on (D4): a screen at (100, 50), drawn
/// at half size, holding five elements named "A" to "E", back to front, that don't overlap;
/// and on the open canvas two sticky notes, "note 1" then "note 2", and then a drawing, so
/// that the drawing is frontmost in the canvas's own list. The view shows the canvas
/// unscrolled and unzoomed, so a point in the view is the same point on the canvas. A test
/// adds what else it needs, such as a second screen.
@MainActor
struct OrderBoard {
    let model: AppModel
    let undo = UndoManager()
    let screen: TreeScreen.ID
    let a: DesignStore.ElementRef
    let b: DesignStore.ElementRef
    let c: DesignStore.ElementRef
    let d: DesignStore.ElementRef
    let e: DesignStore.ElementRef
    let note1: DesignStore.ElementRef
    let note2: DesignStore.ElementRef
    let drawing: DesignStore.ElementRef

    var store: DesignStore { model.store }

    init() {
        model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        let buttons = ["A", "B", "C", "D", "E"].enumerated().map { index, name in
            Self.element(.button, named: name, CGRect(x: 40, y: 40 + CGFloat(index) * 150, width: 300, height: 100))
        }
        let store = model.store
        let screenID = store.addFreeScreen(buttons, origin: CGPoint(x: 100, y: 50), scale: 0.5)
        screen = screenID
        let placed = buttons.map { DesignStore.ElementRef(host: .screen(screenID), element: $0.id) }
        (a, b, c, d, e) = (placed[0], placed[1], placed[2], placed[3], placed[4])
        func onCanvas(_ node: LayerNode) -> DesignStore.ElementRef {
            DesignStore.ElementRef(host: .canvas, element: store.addCanvasNode(node, scale: 1))
        }
        note1 = onCanvas(Self.element(.stickyNote, named: "note 1", CGRect(x: 500, y: 100, width: 140, height: 130)))
        note2 = onCanvas(Self.element(.stickyNote, named: "note 2", CGRect(x: 700, y: 100, width: 140, height: 130)))
        var ink = LayerNode.drawing([
            Self.stroke(from: CGPoint(x: 520, y: 400), to: CGPoint(x: 640, y: 460)),
            Self.stroke(from: CGPoint(x: 640, y: 400), to: CGPoint(x: 520, y: 460)),
        ])!
        ink.name = "drawing"
        drawing = onCanvas(ink)
        // Building the board is not something these tests undo.
        undo.groupsByEvent = false
        model.store.undoManager = undo
    }

    /// Adds a sticky note to the open canvas, in front of everything there, so that a
    /// test can have a drawing between notes. One step to undo, as a note added by hand is.
    @discardableResult
    func addNote(named name: String, at origin: CGPoint) -> DesignStore.ElementRef {
        let note = Self.element(.stickyNote, named: name, CGRect(origin: origin, size: CGSize(width: 140, height: 130)))
        return DesignStore.ElementRef(host: .canvas, element: store.addCanvasNode(note, scale: 1))
    }

    /// One element, or several, as a selection.
    func selection(_ refs: DesignStore.ElementRef...) -> CanvasSelection {
        CanvasSelection(refs.map(CanvasSelection.element))!
    }

    /// The names of what is on a screen, or on the open canvas, back to front, as the
    /// design's own list held them (`listed(on:)`).
    func order(on host: DesignStore.ElementRef.Host) -> [String] {
        store.listed(on: host).map { $0.name ?? "" }
    }

    /// The names of what is on the board's screen, back to front.
    var screenOrder: [String] { order(on: .screen(screen)) }

    /// The names of what is on the open canvas, back to front.
    var canvasOrder: [String] { order(on: .canvas) }

    static func element(_ kind: ElementKind, named name: String, _ frame: CGRect) -> LayerNode {
        .leaf(kind, frame: frame, text: kind.placeholder, tint: Theme.accent, name: name)
    }

    static func stroke(from start: CGPoint, to end: CGPoint) -> PKStroke {
        let points = (0..<12).map { index in
            let t = CGFloat(index) / 11
            return PKStrokePoint(
                location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                timeOffset: Double(index) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: InkGeometry.newStrokeDate()))
    }
}

/// Bring to Front, Bring Forward, Send Backward and Send to Back, for one thing or several:
/// several move as one block keeping their own order, each among the things that share its
/// screen or the open canvas, and drawings keep their places.
@MainActor
@Suite("Layer order")
struct LayerOrderTests {
    @Test func frontAndBackMoveOneThingToTheEnds() {
        let board = OrderBoard()

        board.store.arrange(board.selection(board.b), .front)
        #expect(board.screenOrder == ["A", "C", "D", "E", "B"])

        board.store.arrange(board.selection(board.d), .back)
        #expect(board.screenOrder == ["D", "A", "C", "E", "B"])
    }

    @Test func scatteredThingsMoveAsOneBlockKeepingTheirOrder() {
        let board = OrderBoard()

        board.store.arrange(board.selection(board.b, board.d), .back)
        #expect(board.screenOrder == ["B", "D", "A", "C", "E"])

        let fresh = OrderBoard()
        fresh.store.arrange(fresh.selection(fresh.a, fresh.c), .front)
        #expect(fresh.screenOrder == ["B", "D", "E", "A", "C"])
    }

    @Test func forwardStepsPastTheNextSiblingInFront() {
        let board = OrderBoard()

        board.store.arrange(board.selection(board.b, board.c), .forward)
        #expect(board.screenOrder == ["A", "D", "B", "C", "E"])

        // And backward past the next one behind, the block keeping its order.
        board.store.arrange(board.selection(board.b, board.c), .backward)
        #expect(board.screenOrder == ["A", "B", "C", "D", "E"])

        // Scattered, they move as one block: just in front of what was in front of the
        // frontmost, or just behind what was behind the backmost. Stepped one at a time,
        // they would give A, C, B, E, D and B, A, D, C, E.
        let scattered = OrderBoard()
        scattered.store.arrange(scattered.selection(scattered.b, scattered.d), .forward)
        #expect(scattered.screenOrder == ["A", "C", "E", "B", "D"])
        let back = OrderBoard()
        back.store.arrange(back.selection(back.b, back.d), .backward)
        #expect(back.screenOrder == ["B", "D", "A", "C", "E"])
    }

    @Test func thingsOnTwoHostsEachMoveAmongTheirOwn() {
        let board = OrderBoard()

        board.store.arrange(board.selection(board.note1, board.a), .front)

        #expect(board.screenOrder == ["B", "C", "D", "E", "A"])
        // Note 1 is frontmost among the notes, and the drawing keeps its slot: among the
        // notes' siblings, note 1 would have gone in front of it (note 2, drawing, note 1).
        #expect(board.canvasOrder == ["note 2", "note 1", "drawing"])
    }

    @Test func arrangingIsOneUndoStep() {
        let board = OrderBoard()
        #expect(!board.undo.canUndo)

        board.store.arrange(board.selection(board.note1, board.a, board.c), .front)
        #expect(board.screenOrder == ["B", "D", "E", "A", "C"])
        #expect(board.canvasOrder == ["note 2", "note 1", "drawing"])

        board.undo.undo()
        #expect(board.screenOrder == ["A", "B", "C", "D", "E"])
        #expect(board.canvasOrder == ["note 1", "note 2", "drawing"])
        #expect(!board.undo.canUndo)
    }

    @Test func severalSelectedThingsAreArrangedFromTheirCommands() {
        let board = OrderBoard()
        board.model.selection = board.selection(board.b, board.d, board.note1)
        #expect(board.model.canArrangeSelection(.back))
        #expect(board.model.canArrangeSelection(.front))

        board.model.arrangeSelection(.back)
        #expect(board.screenOrder == ["B", "D", "A", "C", "E"])
        #expect(board.canvasOrder == ["note 1", "note 2", "drawing"])
        // Already at the back, there is nothing more to do.
        #expect(!board.model.canArrangeSelection(.back))
        #expect(!board.model.canArrangeSelection(.backward))

        board.model.selection = nil
        #expect(!board.model.canArrangeSelection(.front))
    }

    @Test func nothingToDoMeansTheCommandIsOff() {
        let board = OrderBoard()

        #expect(!board.store.canArrange(board.selection(board.e), .front))
        #expect(!board.store.canArrange(board.selection(board.e), .forward))
        #expect(board.store.canArrange(board.selection(board.e), .back))
        // Note 2 is the frontmost note, though the drawing is in front of it in the list.
        #expect(!board.store.canArrange(board.selection(board.note2), .front))
        #expect(board.store.canArrange(board.selection(board.note2), .backward))
        // A drawing keeps its place whatever is asked.
        for arrangement in DesignStore.Arrangement.allCases {
            #expect(!board.store.canArrange(board.selection(board.drawing), arrangement))
        }
        board.store.arrange(board.selection(board.drawing), .back)
        #expect(board.canvasOrder == ["note 1", "note 2", "drawing"])
        // A screen in the selection is left as it is, and only what is on it moves.
        let withScreen = CanvasSelection([.screen(board.screen), .element(board.note2)])!
        #expect(!board.store.canArrange(withScreen, .front))
    }

    @Test func aDrawingBetweenNotesKeepsItsSlot() {
        let board = OrderBoard()
        let note3 = board.addNote(named: "note 3", at: CGPoint(x: 900, y: 100))
        #expect(board.canvasOrder == ["note 1", "note 2", "drawing", "note 3"])

        // Note 1 goes in front of the other notes; the drawing stays third in the list.
        // Arranged with the drawing among them, or written back with the drawings after
        // the rest, it would end up elsewhere.
        board.store.arrange(board.selection(board.note1), .front)
        #expect(board.canvasOrder == ["note 2", "note 3", "drawing", "note 1"])

        // A drawing selected with a note is left where it is, and the note moves.
        let mixed = board.selection(board.drawing, note3)
        #expect(board.store.canArrange(mixed, .back))
        board.store.arrange(mixed, .back)
        #expect(board.canvasOrder == ["note 3", "note 2", "drawing", "note 1"])
        #expect(!board.store.canArrange(mixed, .back))
    }

    @Test func lockedThingsStayWhereTheyAre() {
        let board = OrderBoard()
        board.store.setLocked(true, .element(board.b))

        for arrangement in DesignStore.Arrangement.allCases {
            #expect(!board.store.canArrange(board.selection(board.b), arrangement))
            #expect(!board.store.canArrange(board.b, arrangement))
            #expect(!board.store.canArrange(board.selection(board.b, board.drawing), arrangement))
        }
        // Selected with something that isn't locked, it stays and the other moves.
        board.store.arrange(board.selection(board.b, board.d), .back)
        #expect(board.screenOrder == ["D", "A", "B", "C", "E"])

        // The commands for the selection agree.
        board.model.selection = board.selection(board.b)
        #expect(!board.model.canArrangeSelection(.front))
        board.model.arrangeSelection(.front)
        #expect(board.screenOrder == ["D", "A", "B", "C", "E"])

        // A member of a locked group is locked by it, though its own flag isn't set.
        let grouped = OrderBoard()
        grouped.group(grouped.b, grouped.d) { $0.isLocked = true }
        #expect(grouped.store.node(grouped.b.element)?.isLocked == false)
        for arrangement in DesignStore.Arrangement.allCases {
            #expect(!grouped.store.canArrange(grouped.selection(grouped.b), arrangement))
            #expect(!grouped.store.canArrange(grouped.b, arrangement))
        }
        grouped.model.selection = grouped.selection(grouped.b)
        #expect(!grouped.model.canArrangeSelection(.front))
        grouped.model.arrangeSelection(.front)
        #expect(grouped.screenOrder == ["A", "C", "B", "D", "G", "E"])
    }

    @Test func siriSaysWhyADrawingOrALockedThingKeepsItsPlace() throws {
        let board = OrderBoard()

        let drawing = #expect(throws: LayerIntentError.self) {
            try ArrangeElementIntent.arrange(board.drawing, in: board.model, .back, undoManager: nil)
        }
        #expect(drawing.map { if case .drawingsStayOnTop = $0 { true } else { false } } == true)
        #expect(board.canvasOrder == ["note 1", "note 2", "drawing"])

        board.store.setLocked(true, .element(board.c))
        let locked = #expect(throws: LayerIntentError.self) {
            try ArrangeElementIntent.arrange(board.c, in: board.model, .front, undoManager: nil)
        }
        #expect(locked.map { if case .locked = $0 { true } else { false } } == true)

        // Anything else is arranged, as one step of the design's own.
        try ArrangeElementIntent.arrange(board.a, in: board.model, .front, undoManager: nil)
        #expect(board.screenOrder == ["B", "C", "D", "E", "A"])
        board.undo.undo()
        #expect(board.screenOrder == ["A", "B", "C", "D", "E"])
    }
}


/// Dragging a row in the Layers panel moves a thing within its list, into a group or out of one
/// (`moveLayer`), by the same rules as the arrange commands.
@MainActor
@Suite("Moving layers")
struct MovingLayersTests {
    @Test func aLayerMovesWithinItsList() {
        let board = OrderBoard()
        // Above D's row in the panel: just in front of D in the list.
        #expect(board.store.moveLayer(board.a.element, to: .host(.screen(board.screen)), before: board.d.element))
        #expect(board.screenOrder == ["B", "C", "D", "A", "E"])
        // The bottom of the panel's list: the back.
        #expect(board.store.moveLayer(board.e.element, to: .host(.screen(board.screen)), before: nil))
        #expect(board.screenOrder == ["E", "B", "C", "D", "A"])
    }

    @Test func aLayerMovesIntoAGroupAndOut() {
        let board = OrderBoard()
        let group = board.group(board.b, board.d)
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])

        #expect(board.store.moveLayer(board.a.element, to: .group(group.element), before: board.b.element))
        #expect(board.store.node(group.element)?.children.map { $0.name ?? "" } == ["B", "A", "D"])
        #expect(board.store.container(of: board.a.element) == group.element)

        #expect(board.store.moveLayer(board.a.element, to: .host(.screen(board.screen)), before: nil))
        #expect(board.store.container(of: board.a.element) == nil)
        #expect(board.store.node(group.element)?.children.map { $0.name ?? "" } == ["B", "D"])
    }

    @Test func aGroupLeftWithOneMemberByAMoveDissolves() {
        let board = OrderBoard()
        let group = board.group(board.b, board.d)
        board.undo.removeAllActions()

        #expect(board.store.moveLayer(board.b.element, to: .host(.screen(board.screen)), before: nil))
        #expect(board.store.node(group.element) == nil)
        #expect(board.store.container(of: board.d.element) == nil)
        #expect(board.screenOrder == ["B", "A", "C", "D", "E"])

        board.undo.undo()
        #expect(board.store.node(group.element) != nil)
        #expect(board.store.container(of: board.b.element) == group.element)
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])
    }

    @Test func aLayerCannotBeMovedToAnotherHostsList() {
        let board = OrderBoard()
        let other = board.store.addFreeScreen([], name: "Screen 2", origin: CGPoint(x: 900, y: 50), scale: 0.5)
        let otherGroup = board.group(board.note1, board.note2)
        let before = board.store.tree

        #expect(!board.store.moveLayer(board.a.element, to: .host(.screen(other)), before: nil))
        #expect(!board.store.moveLayer(board.a.element, to: .host(.canvas), before: nil))
        #expect(!board.store.moveLayer(board.a.element, to: .group(otherGroup.element), before: nil))
        #expect(board.store.tree == before)
    }

    @Test func aGroupCannotBeMovedIntoItself() {
        let board = OrderBoard()
        let inner = board.group(board.b, board.c, named: "inner")
        let outer = board.group(inner, board.d, named: "outer")
        let before = board.store.tree

        #expect(!board.store.moveLayer(outer.element, to: .group(outer.element), before: nil))
        #expect(!board.store.moveLayer(outer.element, to: .group(inner.element), before: nil))
        #expect(board.store.tree == before)
    }

    @Test func aDrawingDoesntMove() {
        let board = OrderBoard()
        let before = board.store.tree
        #expect(!board.store.moveLayer(board.drawing.element, to: .host(.canvas), before: board.note1.element))
        #expect(board.store.tree == before)
    }

    @Test func drawingsKeepTheirSlotsWhenThingsMove() {
        let board = OrderBoard()
        #expect(board.store.moveLayer(board.note2.element, to: .host(.canvas), before: nil))
        #expect(board.canvasOrder == ["note 2", "note 1", "drawing"])
    }

    @Test func aLockedLayerDoesntMove() {
        let board = OrderBoard()
        board.store.update(board.a.element) { $0.isLocked = true }
        #expect(!board.store.moveLayer(board.a.element, to: .host(.screen(board.screen)), before: nil))
        #expect(board.screenOrder == ["A", "B", "C", "D", "E"])
    }

    @Test func eachMoveIsOneUndoStep() {
        let board = OrderBoard()
        let group = board.group(board.b, board.d)
        board.undo.removeAllActions()

        board.store.moveLayer(board.a.element, to: .group(group.element), before: board.b.element)
        board.undo.undo()
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])
        #expect(board.store.container(of: board.a.element) == nil)
        #expect(!board.undo.canUndo)
    }
}
