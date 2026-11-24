import CoreGraphics
import Foundation
import Testing
@testable import Layer

private func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> DesignElement {
    DesignElement(kind: kind, frame: CGRect(x: x, y: y, width: width, height: height), text: kind.placeholder, tint: Theme.accent)
}

/// Two phone screens side by side, each drawn at half size: A at (100, 50) and B at
/// (400, 50), later than A and so drawn over it. A holds a button, whose middle is at
/// (180, 210) on the canvas, and a title.
@MainActor
private struct TwoScreens {
    let model: AppModel
    let undo = UndoManager()
    let a: DesignScreen.ID
    let b: DesignScreen.ID
    let button: DesignStore.ElementRef
    let title: DesignStore.ElementRef
    let drags = CanvasDrags()

    var store: DesignStore { model.store }

    init() {
        model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        a = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
        b = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 400, y: 50), scale: 0.5)).id
        let placed = model.store.setElements([
            element(.button, 100, 300, 120, 40),
            element(.title, 80, 100, 228, 40),
        ], on: a)
        (button, title) = (placed[0], placed[1])
        model.store.updateCanvas { $0.snapsToGuides = false }
        model.tool = .select
        model.drags = drags
        undo.groupsByEvent = false
        model.store.undoManager = undo
    }

    /// Where `ref`'s element is now: the same element, wherever it lives.
    func now(_ ref: DesignStore.ElementRef) -> DesignStore.ElementRef? {
        guard let element = store.element(ref.element) else { return nil }
        return DesignStore.ElementRef(host: element.parent.map { .screen($0) } ?? .canvas, element: ref.element)
    }

    /// The button as it is on B, if it is there.
    var buttonOnB: DesignStore.ElementRef { DesignStore.ElementRef(host: .screen(b), element: button.element) }

    func canvasFrame(_ ref: DesignStore.ElementRef) -> CGRect? {
        now(ref).flatMap { store.canvasFrame(of: .element($0)) }
    }
}

/// A finger's drag of one element, as `SelectionLayer`'s gesture makes it: the element's
/// frame, placement and rule are those the view had when the touch began, and SwiftUI
/// goes on calling the same closure until the view is drawn again.
@MainActor
private struct Touch {
    let ref: DesignStore.ElementRef
    let frame: CGRect
    let placement: Placement
    let start: CGPoint
    let owner: CanvasDrags.Owner
    var findsNewHome = true

    init(_ ref: DesignStore.ElementRef, on board: TwoScreens, at start: CGPoint, owner: CanvasDrags.Owner = .init(), findsNewHome: Bool = true) {
        let (element, placement) = board.store.resolve(ref)!
        self.ref = ref
        self.frame = element.frame
        self.placement = placement
        self.start = start
        self.owner = owner
        self.findsNewHome = findsNewHome
    }

    /// The finger has moved `dx` across the glass since it landed.
    func move(_ board: TwoScreens, by dx: CGFloat) {
        let element = board.store.resolve(ref)?.element ?? DesignElement(kind: .button, frame: frame, text: "", tint: Theme.accent)
        board.drags.moveElement(ref, from: frame, placement: placement, by: CGSize(width: dx, height: 0), startingAt: start, findsNewHome: findsNewHome, owner: owner, model: board.model) {
            board.drags.moveRule(for: element, placement: placement, on: nil, model: board.model)
        }
    }

    /// Its `onEnded`.
    func lift(_ board: TwoScreens) {
        board.drags.dropElement(ref, findsNewHome: findsNewHome, owner: owner, model: board.model)
    }
}

/// A drag that ends some way other than its finger lifting still lands on whatever it lies
/// over, in its own step, as a drop does. It used to end where it was without being given
/// to the screen under it: dragged from A onto B, the button stayed A's, drawn by A under B,
/// where it vanished, and was still moved with A and written into A's code (audit C4).
@MainActor
@Suite("A drag cut short lands where it lies")
struct CanvasDragLandingTests {
    /// The button dragged 300 points across the glass: from A onto B.
    private func dragOntoB(_ board: TwoScreens, owner: CanvasDrags.Owner = .init()) -> Touch {
        let touch = Touch(board.button, on: board, at: CGPoint(x: 180, y: 210), owner: owner)
        touch.move(board, by: 150)
        touch.move(board, by: 300)
        return touch
    }

    /// The button lies over B, and belongs to it, the drag is over, and the drag is the one
    /// step it was: undone, the board is as it was before.
    private func expectLandedOnB(_ board: TwoScreens, from before: DesignContent, mark: Int, _ source: SourceLocation = #_sourceLocation) {
        let frame = board.canvasFrame(board.button) ?? .null
        #expect(board.store.screen(board.b)?.canvasFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) == true, "the button lies over B", sourceLocation: source)
        #expect(board.store.resolve(board.buttonOnB) != nil, "the button belongs to the screen it lies over", sourceLocation: source)
        #expect(!board.drags.isDragging && !board.store.isEditing && !board.model.isAdjusting, sourceLocation: source)
        #expect(board.store.historyMark == mark + 1, "the drag and its landing are one step", sourceLocation: source)
        board.undo.undo()
        #expect(board.store.content == before, "one undo puts the button back on A where it was", sourceLocation: source)
    }

    /// SwiftUI cancels the drag: its gesture state resets without `onEnded`, or its view
    /// goes. If `onEnded` comes after all, it lands nothing again.
    @Test(arguments: [false, true])
    func aDragSwiftUICancelsLandsWhereItLies(thenItsEndComesLate: Bool) {
        let board = TwoScreens()
        let before = board.store.content
        let mark = board.store.historyMark
        let touch = dragOntoB(board)

        board.drags.cancel(touch.owner, model: board.model)
        #expect(board.model.selection == .element(board.buttonOnB), "the selection names the button where it now is")
        if thenItsEndComesLate {
            touch.lift(board)
            #expect(board.model.selection == .element(board.buttonOnB))
        }
        expectLandedOnB(board, from: before, mark: mark)
    }

    @Test func aDragEndedByAToolChangeLandsWhereItLies() {
        let board = TwoScreens()
        let before = board.store.content
        let mark = board.store.historyMark
        let touch = dragOntoB(board)

        board.model.tool = .draw
        // SwiftUI goes on reporting the drag until the finger lifts: it is left alone.
        touch.move(board, by: 360)
        touch.lift(board)
        expectLandedOnB(board, from: before, mark: mark)
    }

    @Test func aDragEndedAsTheDesignClosesLandsWhereItLies() {
        let board = TwoScreens()
        _ = dragOntoB(board)

        board.model.close()
        #expect(board.store.resolve(board.buttonOnB) != nil)
        let saved = board.model.document.current.content
        #expect(saved.element(board.button.element)?.parent == board.b, "the design is saved with the button on B")
    }

    /// Draw on: the Pencil lands on what a finger is dragging, which lets go of it, and the
    /// drag's area goes from under the finger. The selection stays let go of.
    @Test func thePencilLandingOnADraggedElementLandsItWhereItLies() throws {
        let board = TwoScreens()
        board.model.tool = .draw
        let before = board.store.content
        let mark = board.store.historyMark
        let touch = dragOntoB(board)
        let selected = try #require(board.model.selectionViewRect)

        board.model.pencilTouched(at: CGPoint(x: selected.midX, y: selected.midY))
        #expect(board.model.selection == nil)
        board.drags.cancel(touch.owner, model: board.model)
        #expect(board.model.selection == nil, "let go of, the button isn't selected again")
        expectLandedOnB(board, from: before, mark: mark)
    }

    /// A spoken command locks what a finger is dragging: the drag ends there.
    @Test func aDragEndedByALockLandsWhereItLies() async {
        let board = TwoScreens()
        let mark = board.store.historyMark
        let touch = dragOntoB(board)

        board.store.asOwnStep { board.store.update(board.button) { $0.isLocked = true } }
        for _ in 0..<5 { await Task.yield() }
        #expect(!board.drags.isDragging)
        #expect(board.store.resolve(board.buttonOnB)?.element.isLocked == true)
        #expect(board.store.historyMark == mark + 2, "the drag and the lock are a step each")
        touch.lift(board)
        #expect(board.store.historyMark == mark + 2)
    }

    /// Two fingers twist the button the first was dragging. The twist cuts the drag short:
    /// the button lands on B as it does, in the turn's step, and goes on turning there.
    /// What SwiftUI still reports of the drag lands nothing.
    @Test func aDragCutShortByATwistLandsWhereItLiesAndTheTurnGoesOn() throws {
        let board = TwoScreens()
        let before = board.store.content
        let mark = board.store.historyMark
        let touch = dragOntoB(board)

        #expect(board.model.beginTwist())
        #expect(board.store.resolve(board.buttonOnB) != nil, "the button lands on B as the twist begins")
        #expect(board.model.selection == .element(board.buttonOnB))
        board.model.twist(by: 30)
        #expect(board.store.resolve(board.buttonOnB)?.element.rotation == 30, "the turn goes on with the button on B")
        board.model.endTwist()
        touch.move(board, by: 360)
        touch.lift(board)
        #expect(board.store.resolve(board.buttonOnB)?.element.rotation == 30)
        expectLandedOnB(board, from: before, mark: mark)
    }

    /// The knob is held while a finger drags: the drag is cut short, and the turn goes on
    /// with the button where it landed.
    @Test func aDragCutShortWhileTheKnobTurnsLeavesTheTurnGoingOn() throws {
        let board = TwoScreens()
        let touch = dragOntoB(board)
        #expect(board.model.beginTurn())
        board.model.turnSelection(by: 20, snaps: false)

        board.drags.cancel(touch.owner, model: board.model)
        #expect(board.model.isTurning && board.model.isAdjusting)
        board.model.turnSelection(by: 40, snaps: false)
        #expect(board.store.resolve(board.buttonOnB)?.element.rotation == 40, "the turn goes on with the button on B")
        board.model.endTurn()
    }

    /// A new touch on the same view means the drag before it ended without a word. What it
    /// moved lands then, unless the new touch goes on moving it: that lands when it ends.
    @Test func aNewTouchOnTheSameViewLandsTheDragBefore() {
        let board = TwoScreens()
        let owner = CanvasDrags.Owner()
        _ = dragOntoB(board, owner: owner)

        // The selected element's drag area, now carrying the title.
        let next = Touch(board.title, on: board, at: CGPoint(x: 150, y: 80), owner: owner)
        next.move(board, by: 10)
        #expect(board.store.resolve(board.buttonOnB) != nil, "the button lands on B")
        #expect(board.drags.isDragging)
        next.lift(board)
        #expect(!board.store.isEditing)
    }

    @Test func aNewTouchOnTheSameElementGoesOnMovingItAndLandsItAsItEnds() {
        let board = TwoScreens()
        let owner = CanvasDrags.Owner()
        let first = Touch(board.button, on: board, at: CGPoint(x: 180, y: 210), owner: owner)
        first.move(board, by: 150)

        // The view drawn again since, as the button lay then: still on A.
        let next = Touch(board.button, on: board, at: CGPoint(x: 260, y: 210), owner: owner)
        next.move(board, by: 10)
        next.move(board, by: 150)
        #expect(board.drags.isDragging)
        next.lift(board)
        #expect(board.store.resolve(board.buttonOnB) != nil, "the button lands on B as the second touch ends")
        #expect(board.model.selection == .element(board.buttonOnB))
    }

    /// Several things dragged together, cut short: each lands on what it lies over, and the
    /// selection goes on naming them.
    @Test func severalThingsWhoseDragIsCutShortLandWhereTheyLie() throws {
        let board = TwoScreens()
        let note = board.store.addFloating(element(.stickyNote, 600, 600, 100, 100), scale: 1)
        board.undo.removeAllActions()
        let afterNote = board.store.content
        let mark = board.store.historyMark
        board.model.selection = CanvasSelection([.element(board.button), .element(board.title), .element(note)])
        let owner = CanvasDrags.Owner()
        board.drags.moveGroup(by: CGSize(width: 150, height: 0), startingAt: CGPoint(x: 180, y: 210), owner: owner, model: board.model)
        board.drags.moveGroup(by: CGSize(width: 300, height: 0), startingAt: CGPoint(x: 180, y: 210), owner: owner, model: board.model)

        board.drags.cancel(owner, model: board.model)
        let titleOnB = DesignStore.ElementRef(host: .screen(board.b), element: board.title.element)
        #expect(board.store.resolve(board.buttonOnB) != nil && board.store.resolve(titleOnB) != nil)
        #expect(board.model.selection == CanvasSelection([.element(board.buttonOnB), .element(titleOnB), .element(note)]))
        #expect(board.store.historyMark == mark + 1)
        board.drags.dropGroup(owner: owner, model: board.model)
        #expect(board.store.historyMark == mark + 1)
        board.undo.undo()
        #expect(board.store.content == afterNote)
    }

    /// A handle's drag resizes: cut short, it lands nothing, as its drop doesn't.
    @Test func aResizeCutShortStaysWithItsScreen() {
        let board = TwoScreens()
        let touch = Touch(board.button, on: board, at: CGPoint(x: 210, y: 220), findsNewHome: false)
        touch.move(board, by: 300)
        board.drags.cancel(touch.owner, model: board.model)
        #expect(board.store.resolve(board.button) != nil, "still A's")
        #expect(!board.store.isEditing)
    }

    /// Several things landed by a drag cut short keep their stacking: they used to land in
    /// the order a dictionary gave them, and each landed on top of the one before (review I1).
    @Test func severalThingsLandedByADragCutShortKeepTheirStacking() throws {
        let board = TwoScreens()
        // Six labels overlapping on A, each over the one before it.
        let labels = board.store.setElements((0..<6).map { index in
            element(.body, 60 + CGFloat(index) * 4, 500 + CGFloat(index) * 4, 120, 40)
        }, on: board.a)
        let ids = labels.map(\.element)
        let order = { (screen: DesignScreen.ID) in board.store.content.elements.filter { $0.parent == screen && ids.contains($0.id) }.map(\.id) }
        #expect(order(board.a) == ids)
        board.model.selection = CanvasSelection(labels.map { .element($0) })
        let owner = CanvasDrags.Owner()
        for dx in [CGFloat(150), 300] {
            board.drags.moveGroup(by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 100, y: 300), owner: owner, model: board.model)
        }

        board.drags.cancel(owner, model: board.model)
        #expect(order(board.b) == ids, "on B as they were stacked on A")
    }

    /// A drag ended by its view's gesture being cancelled is over: what SwiftUI still reports
    /// of that touch neither starts it again nor moves anything.
    @Test func aCancelledDragIsntStartedAgainByWhatSwiftUIStillReports() {
        let board = TwoScreens()
        let touch = dragOntoB(board)
        board.drags.cancel(touch.owner, model: board.model)
        let landed = board.store.resolve(board.buttonOnB)?.element.frame
        touch.move(board, by: 360)
        #expect(!board.drags.isDragging)
        #expect(board.store.resolve(board.buttonOnB)?.element.frame == landed)
    }

    /// The same for a drag ended because what it moves was locked meanwhile: a later frame
    /// used to start a drag of the locked element and move it.
    @Test func aDragEndedByALockIsntStartedAgainByItsLaterFrames() async {
        let board = TwoScreens()
        let touch = dragOntoB(board)
        board.store.asOwnStep { board.store.update(board.button) { $0.isLocked = true } }
        for _ in 0..<5 { await Task.yield() }
        let landed = board.store.resolve(board.buttonOnB)?.element.frame
        touch.move(board, by: 360)
        #expect(!board.drags.isDragging)
        #expect(board.store.resolve(board.buttonOnB)?.element.frame == landed, "the locked button stays where it landed")
    }
}
