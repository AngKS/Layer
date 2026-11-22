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
    let screen: DesignScreen.ID
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
        screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
        let placed = model.store.setElements(["A", "B", "C", "D", "E"].enumerated().map { index, name in
            Self.element(.button, named: name, CGRect(x: 40, y: 40 + CGFloat(index) * 150, width: 300, height: 100))
        }, on: screen, replacing: true)
        (a, b, c, d, e) = (placed[0], placed[1], placed[2], placed[3], placed[4])
        note1 = model.store.addFloating(Self.element(.stickyNote, named: "note 1", CGRect(x: 500, y: 100, width: 140, height: 130)), scale: 1)
        note2 = model.store.addFloating(Self.element(.stickyNote, named: "note 2", CGRect(x: 700, y: 100, width: 140, height: 130)), scale: 1)
        var ink = DesignElement.drawing([
            Self.stroke(from: CGPoint(x: 520, y: 400), to: CGPoint(x: 640, y: 460)),
            Self.stroke(from: CGPoint(x: 640, y: 400), to: CGPoint(x: 520, y: 460)),
        ])!
        ink.name = "drawing"
        drawing = model.store.addFloating(ink, scale: 1)
        // Building the board is not something these tests undo.
        undo.groupsByEvent = false
        model.store.undoManager = undo
    }

    /// One element, or several, as a selection.
    func selection(_ refs: DesignStore.ElementRef...) -> CanvasSelection {
        CanvasSelection(refs.map(CanvasSelection.element))!
    }

    /// The names of what is on a screen, or on the open canvas, back to front, as the
    /// design's own list holds them.
    func order(on host: DesignStore.ElementRef.Host) -> [String] {
        let parent: DesignScreen.ID? = if case .screen(let id) = host { id } else { nil }
        return store.content.children(of: parent).map { $0.name ?? "" }
    }

    /// The names of what is on the board's screen, back to front.
    var screenOrder: [String] { order(on: .screen(screen)) }

    /// The names of what is on the open canvas, back to front.
    var canvasOrder: [String] { order(on: .canvas) }

    static func element(_ kind: ElementKind, named name: String, _ frame: CGRect) -> DesignElement {
        var element = DesignElement(kind: kind, frame: frame, text: kind.placeholder, tint: Theme.accent)
        element.name = name
        return element
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
}
