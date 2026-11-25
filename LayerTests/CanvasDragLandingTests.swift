import CoreGraphics
import Foundation
import Testing
@testable import Layer

private func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> LayerNode {
    .leaf(kind, frame: CGRect(x: x, y: y, width: width, height: height), text: kind.placeholder, tint: Theme.accent)
}

/// Two phone screens side by side, each drawn at half size: A at (100, 50) and B at
/// (400, 50), later than A and so drawn over it. A holds a button, whose middle is at
/// (180, 210) on the canvas, and a title.
@MainActor
private struct TwoScreens {
    let model: AppModel
    let undo = UndoManager()
    let a: TreeScreen.ID
    let b: TreeScreen.ID
    let button: DesignStore.ElementRef
    let title: DesignStore.ElementRef
    let drags = CanvasDrags()

    var store: DesignStore { model.store }

    init() {
        model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        a = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
        b = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 400, y: 50), scale: 0.5)).id
        let placed = model.store.add([
            element(.button, 100, 300, 120, 40),
            element(.title, 80, 100, 228, 40),
        ], onScreen: a)
        (button, title) = (placed[0], placed[1])
        model.store.updateCanvas { $0.snapsToGuides = false }
        model.tool = .select
        model.drags = drags
        undo.groupsByEvent = false
        model.store.undoManager = undo
    }

    /// Where `ref`'s element is now: the same element, wherever it lives.
    func now(_ ref: DesignStore.ElementRef) -> DesignStore.ElementRef? {
        store.ref(of: ref.element)
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
        let placed = board.store.placed(ref)!
        self.ref = ref
        self.frame = placed.frame
        self.placement = placed.placement
        self.start = start
        self.owner = owner
        self.findsNewHome = findsNewHome
    }

    /// The finger has moved `dx` across the glass since it landed.
    func move(_ board: TwoScreens, by dx: CGFloat) {
        board.drags.moveNode(ref, by: CGSize(width: dx, height: 0), startingAt: start, findsNewHome: findsNewHome, owner: owner, model: board.model) { placed in
            board.drags.moveRule(for: placed, model: board.model)
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
    private func expectLandedOnB(_ board: TwoScreens, from before: TreeContent, mark: Int, _ source: SourceLocation = #_sourceLocation) {
        let frame = board.canvasFrame(board.button) ?? .null
        #expect(board.store.canvasFrame(ofScreen: board.b)?.contains(CGPoint(x: frame.midX, y: frame.midY)) == true, "the button lies over B", sourceLocation: source)
        #expect(board.store.placed(board.buttonOnB) != nil, "the button belongs to the screen it lies over", sourceLocation: source)
        #expect(!board.drags.isDragging && !board.store.isEditing && !board.model.isAdjusting, sourceLocation: source)
        #expect(board.store.historyMark == mark + 1, "the drag and its landing are one step", sourceLocation: source)
        board.undo.undo()
        #expect(board.store.tree == before, "one undo puts the button back on A where it was", sourceLocation: source)
    }

    /// SwiftUI cancels the drag: its gesture state resets without `onEnded`, or its view
    /// goes. If `onEnded` comes after all, it lands nothing again.
    @Test(arguments: [false, true])
    func aDragSwiftUICancelsLandsWhereItLies(thenItsEndComesLate: Bool) {
        let board = TwoScreens()
        let before = board.store.tree
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
        let before = board.store.tree
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
        #expect(board.store.placed(board.buttonOnB) != nil)
        let saved = board.model.document.current.content
        #expect(saved.element(board.button.element)?.parent == board.b, "the design is saved with the button on B")
    }

    /// Draw on: the Pencil lands on what a finger is dragging, which lets go of it, and the
    /// drag's area goes from under the finger. The selection stays let go of.
    @Test func thePencilLandingOnADraggedElementLandsItWhereItLies() throws {
        let board = TwoScreens()
        board.model.tool = .draw
        let before = board.store.tree
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

        board.store.asOwnStep { board.store.update(board.button.element) { $0.isLocked = true } }
        for _ in 0..<5 { await Task.yield() }
        #expect(!board.drags.isDragging)
        #expect(board.store.node(board.buttonOnB.element)?.isLocked == true)
        #expect(board.store.historyMark == mark + 2, "the drag and the lock are a step each")
        touch.lift(board)
        #expect(board.store.historyMark == mark + 2)
    }

    /// Two fingers twist the button the first was dragging. The twist cuts the drag short:
    /// the button lands on B as it does, in the turn's step, and goes on turning there.
    /// What SwiftUI still reports of the drag lands nothing.
    @Test func aDragCutShortByATwistLandsWhereItLiesAndTheTurnGoesOn() throws {
        let board = TwoScreens()
        let before = board.store.tree
        let mark = board.store.historyMark
        let touch = dragOntoB(board)

        #expect(board.model.beginTwist())
        #expect(board.store.placed(board.buttonOnB) != nil, "the button lands on B as the twist begins")
        #expect(board.model.selection == .element(board.buttonOnB))
        board.model.twist(by: 30)
        #expect(board.store.placed(board.buttonOnB).flatMap { Rotation.kept($0.degrees) } == 30, "the turn goes on with the button on B")
        board.model.endTwist()
        touch.move(board, by: 360)
        touch.lift(board)
        #expect(board.store.placed(board.buttonOnB).flatMap { Rotation.kept($0.degrees) } == 30)
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
        #expect(board.store.placed(board.buttonOnB).flatMap { Rotation.kept($0.degrees) } == 40, "the turn goes on with the button on B")
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
        #expect(board.store.placed(board.buttonOnB) != nil, "the button lands on B")
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
        #expect(board.store.placed(board.buttonOnB) != nil, "the button lands on B as the second touch ends")
        #expect(board.model.selection == .element(board.buttonOnB))
    }

    /// Several things dragged together, cut short: each lands on what it lies over, and the
    /// selection goes on naming them.
    @Test func severalThingsWhoseDragIsCutShortLandWhereTheyLie() throws {
        let board = TwoScreens()
        let note = board.store.addOnCanvas(element(.stickyNote, 600, 600, 100, 100), scale: 1)
        board.undo.removeAllActions()
        let afterNote = board.store.tree
        let mark = board.store.historyMark
        board.model.selection = CanvasSelection([.element(board.button), .element(board.title), .element(note)])
        let owner = CanvasDrags.Owner()
        board.drags.moveGroup(by: CGSize(width: 150, height: 0), startingAt: CGPoint(x: 180, y: 210), owner: owner, model: board.model)
        board.drags.moveGroup(by: CGSize(width: 300, height: 0), startingAt: CGPoint(x: 180, y: 210), owner: owner, model: board.model)

        board.drags.cancel(owner, model: board.model)
        let titleOnB = DesignStore.ElementRef(host: .screen(board.b), element: board.title.element)
        #expect(board.store.placed(board.buttonOnB) != nil && board.store.placed(titleOnB) != nil)
        #expect(board.model.selection == CanvasSelection([.element(board.buttonOnB), .element(titleOnB), .element(note)]))
        #expect(board.store.historyMark == mark + 1)
        board.drags.dropGroup(owner: owner, model: board.model)
        #expect(board.store.historyMark == mark + 1)
        board.undo.undo()
        #expect(board.store.tree == afterNote)
    }

    /// A handle's drag resizes: cut short, it lands nothing, as its drop doesn't.
    @Test func aResizeCutShortStaysWithItsScreen() {
        let board = TwoScreens()
        let touch = Touch(board.button, on: board, at: CGPoint(x: 210, y: 220), findsNewHome: false)
        touch.move(board, by: 300)
        board.drags.cancel(touch.owner, model: board.model)
        #expect(board.store.placed(board.button) != nil, "still A's")
        #expect(!board.store.isEditing)
    }

    /// Several things landed by a drag cut short keep their stacking: they used to land in
    /// the order a dictionary gave them, and each landed on top of the one before (review I1).
    @Test func severalThingsLandedByADragCutShortKeepTheirStacking() throws {
        let board = TwoScreens()
        // Six labels overlapping on A, each over the one before it.
        let labels = board.store.add((0..<6).map { index in
            element(.body, 60 + CGFloat(index) * 4, 500 + CGFloat(index) * 4, 120, 40)
        }, onScreen: board.a)
        let ids = labels.map(\.element)
        let order = { (screen: TreeScreen.ID) in board.store.listed(on: .screen(screen)).filter { ids.contains($0.id) }.map(\.id) }
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
        let landed = board.store.placed(board.buttonOnB)?.frame
        touch.move(board, by: 360)
        #expect(!board.drags.isDragging)
        #expect(board.store.placed(board.buttonOnB)?.frame == landed)
    }

    /// The same for a drag ended because what it moves was locked meanwhile: a later frame
    /// used to start a drag of the locked element and move it.
    @Test func aDragEndedByALockIsntStartedAgainByItsLaterFrames() async {
        let board = TwoScreens()
        let touch = dragOntoB(board)
        board.store.asOwnStep { board.store.update(board.button.element) { $0.isLocked = true } }
        for _ in 0..<5 { await Task.yield() }
        let landed = board.store.placed(board.buttonOnB)?.frame
        touch.move(board, by: 360)
        #expect(!board.drags.isDragging)
        #expect(board.store.placed(board.buttonOnB)?.frame == landed, "the locked button stays where it landed")
    }
}

// MARK: - Drags in rows, columns and grids

/// A thing fixed at `width` × `height`, as a row's children are.
private func fixed(_ kind: ElementKind = .text, _ text: String, _ frame: CGRect) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.content.text = text
    node.frame = frame
    return node
}

/// A container sized to fit on both axes.
private func holding(_ layout: LayerNode.Layout?, at origin: CGPoint, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: .group)
    node.layout = layout
    node.frame = CGRect(origin: origin, size: .zero)
    node.width = LayerNode.Sizing(.fit)
    node.height = LayerNode.Sizing(.fit)
    node.children = children
    return node
}

private func rowLayout(spacing: CGFloat = 20) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .horizontal, spacing: spacing))
}

/// Plan 4 Task 4's row: at (20, 100) on a free iPhone root at the canvas's origin, drawn at its own size so that its
/// points are the canvas's, and the view showing the canvas unscrolled and unzoomed. It holds a, b and c, each 80 × 40
/// and fixed, at x 0, 100 and 200. `more` goes on the root after it, and `canvas` on the open canvas. With a `root`
/// layout, the root lays them out instead.
@MainActor
private struct RowBoard {
    let model: AppModel
    let undo = UndoManager()
    let drags = CanvasDrags()
    let screen: TreeScreen.ID
    let row: UUID
    let a: UUID
    let b: UUID
    let c: UUID

    var store: DesignStore { model.store }

    init(_ more: [LayerNode] = [], canvas: [LayerNode] = [], root layout: LayerNode.Layout? = nil) {
        let cells = ["A", "B", "C"].map { fixed(.text, $0, CGRect(x: 0, y: 0, width: 80, height: 40)) }
        let line = holding(rowLayout(), at: CGPoint(x: 20, y: 100), cells)
        var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
        screen.root.layout = layout
        screen.root.children = [line] + more
        var tree = TreeContent()
        tree.screens = [screen]
        tree.canvas = canvas
        TreeRules.apply(to: &tree, after: nil)
        model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        model.tool = .select
        model.drags = drags
        undo.groupsByEvent = false
        model.store.undoManager = undo
        self.screen = screen.id
        row = line.id
        (a, b, c) = (cells[0].id, cells[1].id, cells[2].id)
    }

    func children(of parent: UUID) -> [UUID] { store.node(parent)?.children.map(\.id) ?? [] }

    var rootChildren: [UUID] { store.treeScreen(screen)?.root.children.map(\.id) ?? [] }

    /// Where a thing's middle is on the canvas, and in the view.
    func centre(_ id: UUID) -> CGPoint { store.placed(id)?.canvasShape.centre ?? .zero }

    /// One frame of a finger on `id`'s target, `translation` across the glass since it landed at `start`, as the
    /// canvas drives it: with node values.
    func drag(_ id: UUID, by translation: CGSize, from start: CGPoint, owner: CanvasDrags.Owner) {
        guard let ref = store.ref(of: id) else { return }
        drags.moveOnTarget(ref, by: translation, startingAt: start, owner: owner, model: model)
    }

    /// The finger on `id`'s target lifts.
    func drop(_ id: UUID, from start: CGPoint, owner: CanvasDrags.Owner) {
        guard let ref = store.ref(of: id) else { return }
        drags.dropOnTarget(ref, startingAt: start, owner: owner, model: model)
    }

    /// A drag of `id` from its middle straight to `point` on the canvas, in a few frames, then its drop.
    func drag(_ id: UUID, to point: CGPoint) {
        let start = centre(id), owner = CanvasDrags.Owner()
        for step in 1...4 {
            let part = CGFloat(step) / 4
            drag(id, by: CGSize(width: (point.x - start.x) * part, height: (point.y - start.y) * part), from: start, owner: owner)
        }
        drop(id, from: start, owner: owner)
    }
}

/// A drag in a row, column or grid (plan 4, call 3): the thing is lifted, an insertion line shows where it would go, and
/// nothing is written until the drop, which reorders it, takes it out where it was let go, or moves it into the row
/// under the finger. A free thing is placed as today, and joins a row, column or grid whose line shows as it is let go.
@MainActor
@Suite("Drags in rows, columns and grids")
struct LayoutDragTests {
    /// F11: a lift writes nothing, so its frames change no version. Its check that they lowered nothing went with the
    /// flat list (plan 6, Task 11, clause (s)).
    @Test func draggingARowChildWritesNothingUntilTheDrop() throws {
        let board = RowBoard()
        let (written, version) = (ListWork.elementsWritten, board.store.contentVersion)
        let start = board.centre(board.b), owner = CanvasDrags.Owner()
        var targets: [TreeDrop.Target?] = []
        // Right along the row past c, then down out of it: 60 frames.
        for k in 1...30 {
            board.drag(board.b, by: CGSize(width: CGFloat(k) * 4, height: 0), from: start, owner: owner)
            if k == 30 { targets.append(board.drags.lift?.target) }
        }
        for k in 1...30 {
            board.drag(board.b, by: CGSize(width: 120, height: CGFloat(k) * 4), from: start, owner: owner)
        }
        targets.append(board.drags.lift?.target)

        print("BENCH drag row child frames=60 writes=\(ListWork.elementsWritten - written) versions=\(board.store.contentVersion - version)")
        #expect(ListWork.elementsWritten == written, "nodes written during a 60-frame lift")
        #expect(board.store.contentVersion == version, "versions made during a 60-frame lift")
        #expect(board.drags.lift?.ref.element == board.b)
        #expect(board.drags.lift?.start == CGRect(x: 120, y: 100, width: 80, height: 40))
        #expect(board.drags.lift?.translation == CGSize(width: 120, height: 120))
        #expect(board.drags.dropTarget == board.drags.lift?.target)
        // Past c: the end of the row, the line half a gap beyond c. Then below the row: placed freely on the screen.
        #expect(targets == [.insert(into: .node(board.row), at: 2, line: TurnedRect(rect: CGRect(x: 309, y: 100, width: 2, height: 40), degrees: 0)),
                            .free(on: .screen(board.screen))])
        board.drop(board.b, from: start, owner: owner)
        #expect(board.store.contentVersion > version)
        #expect(board.drags.lift == nil && board.drags.dropTarget == nil)
    }

    @Test func droppingInTheSameRowReorders() {
        let board = RowBoard()
        let mark = board.store.historyMark
        let start = board.centre(board.a)

        board.drag(board.a, to: CGPoint(x: start.x + 150, y: start.y))

        #expect(board.children(of: board.row) == [board.b, board.a, board.c])
        #expect(board.store.historyMark == mark + 1)
        #expect(board.undo.undoActionName == "Move")
        board.undo.undo()
        #expect(board.children(of: board.row) == [board.a, board.b, board.c])
    }

    @Test func droppingOutsideTakesItOutWhereItWasLetGo() throws {
        let board = RowBoard()
        let start = board.centre(board.b)

        board.drag(board.b, to: CGPoint(x: start.x, y: start.y + 200))

        #expect(board.rootChildren.last == board.b)
        let node = try #require(board.store.node(board.b))
        #expect(node.frame == CGRect(x: 120, y: 300, width: 80, height: 40))
        #expect(node.width.mode == .fixed && node.height.mode == .fixed)
        #expect(board.children(of: board.row) == [board.a, board.c])
        #expect(board.model.selection == .element(DesignStore.ElementRef(host: .screen(board.screen), element: board.b)))
    }

    @Test func droppingIntoAnotherRowJoinsItAtTheLine() throws {
        let other = holding(rowLayout(), at: CGPoint(x: 20, y: 300), ["D", "E"].map { fixed(.text, $0, CGRect(x: 0, y: 0, width: 80, height: 40)) })
        let board = RowBoard([other])
        let (d, e) = (other.children[0].id, other.children[1].id)
        // The gap between d (0 to 80) and e (100 to 180) in the other row, which is at (20, 300).
        board.drag(board.b, to: CGPoint(x: 20 + 90, y: 320))

        #expect(board.children(of: other.id) == [d, board.b, e])
        #expect(board.children(of: board.row) == [board.a, board.c])
        #expect(board.store.parent(of: board.b) == .node(other.id))
    }

    /// A text on screen A, whose root is free, dropped over screen B, a column, between B's second and third things:
    /// it joins B's column there.
    @Test func aFreeThingDroppedOnAColumnScreenJoinsItAtTheLine() throws {
        let board = TwoScreens()
        let rootB = try #require(board.store.treeScreen(board.b)?.root.id)
        let lines = ["One", "Two", "Three"].map { fixed(.text, $0, CGRect(x: 20, y: 100, width: 200, height: 40)) }
        for line in lines { try #require(board.store.add(line, to: .screen(board.b))) }
        board.store.setLayout(rootB, .stack(LayerNode.Stack(axis: .vertical, spacing: 12)))
        let (second, third) = try (#require(board.store.placed(lines[1].id)), #require(board.store.placed(lines[2].id)))
        let gap = CGPoint(x: second.canvasShape.rect.midX, y: (second.canvasShape.rect.maxY + third.canvasShape.rect.minY) / 2)
        let title = board.title.element
        let start = try #require(board.store.placed(title)).canvasShape.centre
        let owner = CanvasDrags.Owner()

        for part in [0.25, 0.5, 1.0] {
            board.drags.moveOnTarget(board.title, by: CGSize(width: (gap.x - start.x) * part, height: (gap.y - start.y) * part),
                                     startingAt: start, owner: owner, model: board.model)
        }
        if case .insert(let parent, let slot, _)? = board.drags.dropTarget {
            #expect(parent == .screen(board.b) && slot == 2, "the line shows between Two and Three")
        } else {
            Issue.record("a line should show on B: \(String(describing: board.drags.dropTarget))")
        }
        #expect(board.drags.guides.isEmpty, "no guides while a line shows")
        board.drags.dropOnTarget(board.title, startingAt: start, owner: owner, model: board.model)

        #expect(board.store.parent(of: title) == .screen(board.b))
        #expect(board.store.treeScreen(board.b)?.root.children.map(\.id) == [lines[0].id, lines[1].id, title, lines[2].id])
        #expect(board.model.selection == .element(DesignStore.ElementRef(host: .screen(board.b), element: title)))
    }

    /// A free thing dropped on a free screen lands on top there, as it always has: where it was let go on the canvas,
    /// at its own size.
    @Test func aFreeThingDroppedOnAFreeScreenIsRehostedAsToday() throws {
        let board = TwoScreens()
        let button = board.button.element
        let before = try #require(board.store.placed(button))
        let start = before.canvasShape.centre
        let owner = CanvasDrags.Owner()

        for dx in [150.0, 300.0] {
            board.drags.moveOnTarget(board.button, by: CGSize(width: dx, height: 0), startingAt: start, owner: owner, model: board.model)
        }
        #expect(board.drags.dropTarget == .free(on: .screen(board.b)))
        board.drags.dropOnTarget(board.button, startingAt: start, owner: owner, model: board.model)

        let after = try #require(board.store.placed(button))
        #expect(after.ref == board.buttonOnB)
        #expect(board.store.treeScreen(board.b)?.root.children.last?.id == button)
        #expect(after.node.frame.size == before.node.frame.size)
        #expect(after.canvasShape.centre == CGPoint(x: start.x + 300, y: start.y))
    }

    /// A member of a free group dragged out of the group's box stays in the group, whose box grows round it.
    @Test func aMemberDraggedOutOfItsFreeGroupsBoxStaysInIt() throws {
        let p = fixed(.text, "P", CGRect(x: 0, y: 0, width: 80, height: 40))
        let q = fixed(.text, "Q", CGRect(x: 100, y: 0, width: 80, height: 40))
        let group = holding(nil, at: CGPoint(x: 20, y: 400), [p, q])
        let board = RowBoard([group])
        let start = board.centre(q.id)

        board.drag(q.id, to: CGPoint(x: start.x, y: start.y + 200))

        #expect(board.store.parent(of: q.id) == .node(group.id))
        let box = try #require(board.store.placed(group.id)).canvasShape.rect
        let moved = try #require(board.store.placed(q.id)).canvasShape.rect
        #expect(box.contains(moved), "the box \(box) grows round \(moved)")
        #expect(moved.midY == start.y + 200)
    }

    @Test func snappingIsOnlyForFreePlacement() throws {
        let board = RowBoard()
        try #require(board.store.canvas.snapsToGuides)
        let start = board.centre(board.b), owner = CanvasDrags.Owner()

        for dx in stride(from: 2.0, through: 40, by: 2) {
            board.drag(board.b, by: CGSize(width: dx, height: 1), from: start, owner: owner)
            #expect(board.drags.lift != nil)
            #expect(board.drags.guides.isEmpty, "no guides while lifted over the row (\(dx))")
        }
        board.drop(board.b, from: start, owner: owner)
    }

    @Test func aLockedRowChildIsNotDragged() {
        let board = RowBoard()
        board.store.setOwnLocks(true, nodes: [board.b], screens: [])
        let before = board.store.tree
        let start = board.centre(board.b), owner = CanvasDrags.Owner()

        board.drag(board.b, by: CGSize(width: 150, height: 0), from: start, owner: owner)
        #expect(!board.drags.isDragging)
        #expect(board.drags.lift == nil)
        board.drop(board.b, from: start, owner: owner)

        #expect(board.store.tree == before)
        #expect(board.children(of: board.row) == [board.a, board.b, board.c])
    }

    /// F12: a lift SwiftUI cancels lands as its drop would, in the slot its line showed.
    @Test func aLiftCutShortLandsAsADropWould() {
        let board = RowBoard()
        let mark = board.store.historyMark
        let start = board.centre(board.a), owner = CanvasDrags.Owner()
        board.drag(board.a, by: CGSize(width: 100, height: 0), from: start, owner: owner)
        board.drag(board.a, by: CGSize(width: 220, height: 0), from: start, owner: owner)
        if case .insert(_, let slot, _)? = board.drags.lift?.target { #expect(slot == 2) }

        board.drags.cancel(owner, model: board.model)

        #expect(board.children(of: board.row) == [board.b, board.c, board.a])
        #expect(!board.drags.isDragging && !board.store.isEditing && !board.model.isAdjusting)
        #expect(board.drags.lift == nil)
        #expect(board.store.historyMark == mark + 1)
        board.drop(board.a, from: start, owner: owner)
        #expect(board.store.historyMark == mark + 1, "its late end lands nothing again")
    }

    /// F23: a thing in an overlay nudged and let go over the overlay stays where it was in it. Dragged outside, it is
    /// taken out.
    @Test func aNudgeInsideAnOverlayChangesNothing() throws {
        let back = fixed(.text, "Back", CGRect(x: 0, y: 0, width: 200, height: 100))
        let front = fixed(.text, "Front", CGRect(x: 50, y: 30, width: 100, height: 40))
        let overlay = holding(.overlay(LayerNode.Alignment()), at: CGPoint(x: 20, y: 400), [back, front])
        let board = RowBoard([overlay])
        let before = board.store.tree
        let mark = board.store.historyMark
        let start = board.centre(front.id)

        board.drag(front.id, to: CGPoint(x: start.x + 10, y: start.y))

        #expect(board.store.tree == before)
        #expect(board.store.historyMark == mark)
        #expect(board.children(of: overlay.id) == [back.id, front.id])

        board.drag(front.id, to: CGPoint(x: start.x, y: start.y + 300))
        #expect(board.store.parent(of: front.id) == .screen(board.screen))
        #expect(board.children(of: overlay.id) == [back.id])
    }

    /// F15: a drop the store refuses, here into a row taken away while the finger was down, leaves the thing where
    /// it was, and the drag is a step that changes nothing.
    @Test func aDropTheStoreRefusesLeavesItWhereItWas() throws {
        let other = holding(rowLayout(), at: CGPoint(x: 20, y: 300), ["D", "E"].map { fixed(.text, $0, CGRect(x: 0, y: 0, width: 80, height: 40)) })
        let board = RowBoard([other])
        let start = board.centre(board.b), owner = CanvasDrags.Owner()
        board.drag(board.b, by: CGSize(width: -50, height: 200), from: start, owner: owner)
        let target = try #require(board.drags.lift?.target)
        #expect(target != .free(on: .screen(board.screen)))
        if case .insert(let parent, _, _) = target { #expect(parent == .node(other.id)) }

        board.store.asOwnStep { board.store.delete(nodes: [other.id]) }
        let before = board.store.tree
        let mark = board.store.historyMark
        board.drop(board.b, from: start, owner: owner)

        #expect(board.store.tree == before)
        #expect(board.store.historyMark == mark)
        #expect(board.children(of: board.row) == [board.a, board.b, board.c])
        #expect(!board.store.isEditing)
    }

    /// A container in a row, dragged with other things, is taken out of the row where it is let go, as a thing that
    /// isn't a container is (My call 20; plan 4 Task 4's carry). It goes whole, what it holds riding in it.
    @Test func aContainerInARowDraggedWithOtherThingsIsTakenOut() throws {
        var card = LayerNode(kind: .card)
        card.frame = CGRect(x: 0, y: 0, width: 100, height: 60)
        card.children = [fixed(.text, "In", CGRect(x: 16, y: 16, width: 60, height: 20))]
        let e = fixed(.text, "E", CGRect(x: 0, y: 0, width: 80, height: 40))
        let other = holding(rowLayout(), at: CGPoint(x: 20, y: 300), [card, e])
        let d = fixed(.text, "D", CGRect(x: 20, y: 500, width: 80, height: 40))
        let board = RowBoard([other, d])
        board.store.updateCanvas { $0.snapsToGuides = false }
        let cardRef = try #require(board.store.ref(of: card.id)), dRef = try #require(board.store.ref(of: d.id))
        let (cardWas, dWas) = (board.centre(card.id), board.centre(d.id))
        board.model.selection = CanvasSelection([.element(cardRef), .element(dRef)])
        let mark = board.store.historyMark
        let owner = CanvasDrags.Owner()

        for dy in [20.0, 60.0, 100.0] {
            board.drags.moveGroup(by: CGSize(width: 0, height: dy), startingAt: dWas, owner: owner, model: board.model)
        }
        board.drags.dropGroup(owner: owner, model: board.model)

        #expect(board.store.parent(of: card.id) == .screen(board.screen), "the card is taken out of its row")
        #expect(board.children(of: other.id) == [e.id])
        #expect(board.children(of: card.id) == card.children.map(\.id), "what it holds rides in it")
        #expect(board.centre(card.id) == CGPoint(x: cardWas.x, y: cardWas.y + 100), "it lands where it was let go")
        #expect(board.centre(d.id) == CGPoint(x: dWas.x, y: dWas.y + 100))
        #expect(board.store.historyMark == mark + 1, "the drag is one step")
    }

    /// F13: a screen dragged snaps among the tree's screens and writes the tree. Its check that its frames lowered
    /// nothing went with the flat list (plan 6, Task 11, clause (s)).
    @Test func aScreenDragReadsTheTree() throws {
        let board = RowBoard()
        let owner = CanvasDrags.Owner()
        for frame in 1...60 {
            board.drags.moveScreen(board.screen, by: CGSize(width: CGFloat(frame) * 3, height: 0), startingAt: CGPoint(x: 100, y: 10),
                                   owner: owner, model: board.model)
        }
        let moved = board.store.treeScreen(board.screen)?.origin
        board.drags.dropScreen(owner: owner, model: board.model)

        #expect(moved == CGPoint(x: 180, y: 0))
        #expect(!board.store.isEditing)
    }

    /// A member of a free group in a column, nudged or moved within the group's box, stays in the group, placed freely
    /// there, and no line shows; let go outside the box as it was when the drag began, it joins the column at the
    /// line (spec §10, "Moving something in a free container"; fix round 1, I3).
    @Test func aFreeGroupInAColumnKeepsItsMemberUntilItIsLetGoOutsideItsBox() throws {
        let p = fixed(.text, "P", CGRect(x: 0, y: 0, width: 80, height: 40))
        let q = fixed(.text, "Q", CGRect(x: 100, y: 0, width: 80, height: 40))
        let group = holding(nil, at: .zero, [p, q])
        let board = RowBoard([group], root: .stack(LayerNode.Stack(axis: .vertical, spacing: 12)))
        try #require(board.store.parent(of: group.id) == .screen(board.screen))
        // Q's edges line up with b's in the row above: a nudge this small would snap back.
        board.store.updateCanvas { $0.snapsToGuides = false }

        for (dx, what) in [(3.0, "a 3 pt nudge"), (-40.0, "a move within the box")] {
            let start = board.centre(q.id), owner = CanvasDrags.Owner()
            board.drag(q.id, by: CGSize(width: dx / 2, height: 0), from: start, owner: owner)
            board.drag(q.id, by: CGSize(width: dx, height: 0), from: start, owner: owner)
            #expect(board.drags.dropTarget == .free(on: .screen(board.screen)), "no line shows for \(what)")
            board.drop(q.id, from: start, owner: owner)
            #expect(board.store.parent(of: q.id) == .node(group.id), "\(what) leaves it in its group")
            #expect(board.centre(q.id) == CGPoint(x: start.x + dx, y: start.y), "\(what) places it where it was let go")
        }

        // Below the group's box: the column under the finger takes it.
        let start = board.centre(q.id)
        board.drag(q.id, to: CGPoint(x: start.x, y: start.y + 150))
        #expect(board.store.parent(of: q.id) == .screen(board.screen))
    }

    /// A member of a free group on the open canvas, lying over a column screen, nudged within the group's box, stays
    /// in the group on the canvas: it isn't given to the screen under it. Let go outside the box, the column under the
    /// finger takes it (fix round 2, N2).
    @Test func aFreeCanvasGroupOverAScreenKeepsItsMemberInItsBox() throws {
        let p = fixed(.text, "P", CGRect(x: 0, y: 0, width: 80, height: 40))
        let q = fixed(.text, "Q", CGRect(x: 100, y: 0, width: 80, height: 40))
        let group = holding(nil, at: CGPoint(x: 30, y: 400), [p, q])
        let board = RowBoard(canvas: [group], root: .stack(LayerNode.Stack(axis: .vertical, spacing: 12)))
        board.store.updateCanvas { $0.snapsToGuides = false }
        try #require(board.store.parent(of: group.id) == .canvas)
        try #require(board.store.treeScreen(at: board.centre(q.id))?.id == board.screen, "the group lies over the screen")

        let start = board.centre(q.id), owner = CanvasDrags.Owner()
        board.drag(q.id, by: CGSize(width: 1.5, height: 0), from: start, owner: owner)
        board.drag(q.id, by: CGSize(width: 3, height: 0), from: start, owner: owner)
        #expect(board.drags.dropTarget == .free(on: .canvas))
        board.drop(q.id, from: start, owner: owner)

        #expect(board.store.parent(of: q.id) == .node(group.id))
        #expect(board.store.parent(of: group.id) == .canvas)
        #expect(board.centre(q.id) == CGPoint(x: start.x + 3, y: start.y))

        board.drag(q.id, to: CGPoint(x: start.x, y: start.y + 150))
        #expect(board.store.parent(of: q.id) == .screen(board.screen))
    }

    /// Carried from plan 2: a container is taken out of a row as a leaf is. Its target's drag moves it as what is
    /// selected moves, and on its own it is lifted, then let go where it lands; dropped freely on a row, it joins it.
    @Test func aContainerIsLiftedTakenOutAndMovedInAsAThingIs() throws {
        let inner = holding(rowLayout(spacing: 0), at: .zero, ["P", "Q"].map { fixed(.text, $0, CGRect(x: 0, y: 0, width: 40, height: 40)) })
        let other = holding(rowLayout(), at: CGPoint(x: 20, y: 300), [inner, fixed(.text, "D", CGRect(x: 0, y: 0, width: 80, height: 40))])
        let board = RowBoard([other])
        let start = board.centre(inner.id), owner = CanvasDrags.Owner()

        board.drag(inner.id, by: CGSize(width: 0, height: 100), from: start, owner: owner)
        board.drag(inner.id, by: CGSize(width: 0, height: 200), from: start, owner: owner)
        let ref = try #require(board.store.ref(of: inner.id))
        #expect(board.drags.groupOrigins.map { Set($0.keys) } == [.element(ref)])
        #expect(board.drags.lift?.ref == ref)
        #expect(board.children(of: other.id) == [inner.id, other.children[1].id], "nothing is written until the drop")
        board.drop(inner.id, from: start, owner: owner)

        #expect(board.rootChildren.last == inner.id)
        let out = try #require(board.store.node(inner.id))
        #expect(out.frame == CGRect(x: 20, y: 500, width: 80, height: 40))
        #expect(out.width.mode == .fixed && out.height.mode == .fixed)

        // Placed freely now, it joins the row whose line shows as it is let go: between a and b.
        board.drag(inner.id, to: CGPoint(x: 20 + 90, y: 120))
        #expect(board.children(of: board.row) == [board.a, inner.id, board.b, board.c])
    }

    /// Carried from plan 2, with the controller's ruling (fix round 1, I4): a thing moved into a group drawn at another
    /// scale keeps its own size, as every move between scales does. Dropped into a row on the open canvas drawn at half
    /// size, it joins it where the line showed; moved into a free group drawn at half size, its middle stays where it
    /// was let go.
    @Test func aCanvasThingMovedIntoAGroupDrawnAtAnotherScaleKeepsItsOwnSize() throws {
        var line = holding(rowLayout(), at: CGPoint(x: 1200, y: 200), ["P", "Q"].map { fixed(.text, $0, CGRect(x: 0, y: 0, width: 80, height: 40)) })
        line.scale = 0.5
        var loose = holding(nil, at: CGPoint(x: 1200, y: 800), ["R", "S"].map { fixed(.text, $0, CGRect(x: 0, y: 0, width: 80, height: 40)) })
        loose.children[1].frame.origin.x = 100
        loose.scale = 0.5
        let t = fixed(.text, "T", CGRect(x: 800, y: 400, width: 100, height: 20))
        let u = fixed(.text, "U", CGRect(x: 800, y: 600, width: 100, height: 20))
        let board = RowBoard(canvas: [line, loose, t, u])
        let (p, q) = (line.children[0].id, line.children[1].id)

        // The gap between P (0 to 80) and Q (100 to 180), in the row's own points at (1200, 200), drawn at half size.
        board.drag(t.id, to: CGPoint(x: (1200 + 90) * 0.5, y: (200 + 20) * 0.5))

        #expect(board.children(of: line.id) == [p, t.id, q])
        let joined = try #require(board.store.node(t.id))
        #expect(joined.scale == nil)
        #expect(joined.frame.size == CGSize(width: 100, height: 20), "its own size")

        // Into the free group: where it was let go, at its own size.
        let middle = board.centre(u.id)
        #expect(board.store.move(u.id, to: .node(loose.id)))
        #expect(board.store.node(u.id)?.frame.size == CGSize(width: 100, height: 20), "its own size")
        let landed = board.centre(u.id)
        #expect(abs(landed.x - middle.x) < 0.5 && abs(landed.y - middle.y) < 0.5, "its middle where it was")
    }
}
