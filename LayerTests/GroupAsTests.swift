import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// An app showing `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeModel(_ tree: TreeContent) -> (model: AppModel, undo: UndoManager) {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: tree)))
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    return (model, undo)
}

private func text(_ x: CGFloat, _ y: CGFloat, width: CGFloat = 60, height: CGFloat = 24) -> LayerNode {
    var node = LayerNode(kind: .text)
    node.frame = CGRect(x: x, y: y, width: width, height: height)
    node.content.text = "Text"
    return node
}

private func square(_ x: CGFloat, _ y: CGFloat) -> LayerNode {
    var node = LayerNode(kind: .shape)
    node.content.shape = .rectangle
    node.frame = CGRect(x: x, y: y, width: 50, height: 50)
    return node
}

/// A container fixed at `frame`.
private func container(_ kind: ElementKind = .group, _ layout: LayerNode.Layout? = nil, frame: CGRect,
                       _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.layout = layout
    node.frame = frame
    node.children = children
    return node
}

/// An iPhone screen with a free root at the canvas's origin, drawn at its own size, so that its points are the canvas's.
private func screen(_ children: [LayerNode]) -> TreeScreen {
    var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
    screen.root.children = children
    return screen
}

private func design(_ screens: [TreeScreen], canvas: [LayerNode] = []) -> TreeContent {
    var content = TreeContent()
    content.screens = screens
    content.canvas = canvas
    return content
}

private let rhythm = DesignTokens.standard.rhythm

// MARK: Align on every surface

/// One thing the Align parity tests line up, and what the standard says doing so leaves (`expect`): given the store
/// afterwards, the alignment, the tree before and the case's name for what is reported.
@MainActor
private struct AlignSubject {
    let name: String
    let id: UUID
    let expect: @MainActor (DesignStore, ElementLayout.Alignment, TreeContent, String) -> Void

    nonisolated private static let across: [ElementLayout.Alignment: LayerNode.Edge3] = [.left: .start, .centerX: .center, .right: .end]
    nonisolated private static let down: [ElementLayout.Alignment: LayerNode.Edge3] = [.top: .start, .centerY: .center, .bottom: .end]

    /// A child of the laid-out `parent`, which takes the layout `aligned` gives for an alignment, and with nil changes
    /// nothing: the child stays where it is in it.
    static func laidOut(_ name: String, _ id: UUID, in parent: UUID,
                        _ aligned: @escaping @MainActor (ElementLayout.Alignment) -> LayerNode.Layout?) -> AlignSubject {
        AlignSubject(name: name, id: id) { store, alignment, before, what in
            guard let layout = aligned(alignment) else {
                #expect(store.tree == before, "\(what): nothing changes")
                return
            }
            #expect(store.node(parent)?.resolvedLayout == layout, "\(what)")
            #expect(store.node(parent)?.children.contains { $0.id == id } == true, "\(what): it stays in its parent")
        }
    }

    /// A row's child: top, middle and bottom are the row's; left, centre and right are along it.
    static func inARow(_ name: String, _ id: UUID, in row: UUID, _ stack: LayerNode.Stack) -> AlignSubject {
        laidOut(name, id, in: row) { alignment in
            down[alignment].map { edge in var aligned = stack; aligned.alignment = .init(edge); return .stack(aligned) }
        }
    }

    /// A column's child: left, centre and right are the column's; top, middle and bottom are along it.
    static func inAColumn(_ name: String, _ id: UUID, in column: UUID, _ stack: LayerNode.Stack) -> AlignSubject {
        laidOut(name, id, in: column) { alignment in
            across[alignment].map { edge in var aligned = stack; aligned.alignment = .init(edge); return .stack(aligned) }
        }
    }

    /// A grid's or an overlay's alignment with the button's edge set, on its axis.
    nonisolated static func both(_ alignment: LayerNode.Alignment, _ button: ElementLayout.Alignment) -> LayerNode.Alignment {
        LayerNode.Alignment(horizontal: across[button] ?? alignment.horizontal, vertical: down[button] ?? alignment.vertical)
    }

    /// A thing in a free parent on an iPhone screen, 393 × 852: lined up with that edge or middle of the screen, by the
    /// box round its shape, its corner on a whole point.
    static func onItsScreen(_ name: String, _ id: UUID) -> AlignSubject {
        AlignSubject(name: name, id: id) { store, alignment, _, what in
            guard let seen = store.index[id]?.hostShape.bounds else {
                Issue.record("\(what): it has gone")
                return
            }
            let lined = switch alignment {
            case .left: abs(seen.minX) <= 0.5
            case .centerX: abs(seen.midX - 196.5) <= 0.5
            case .right: abs(seen.maxX - 393) <= 0.5
            case .top: abs(seen.minY) <= 0.5
            case .centerY: abs(seen.midY - 426) <= 0.5
            case .bottom: abs(seen.maxY - 852) <= 0.5
            }
            #expect(lined, "\(what): \(seen)")
        }
    }

    /// A thing on the open canvas in no laid-out parent: there is no screen to line it up with, and nothing changes.
    static func offScreen(_ name: String, _ id: UUID) -> AlignSubject {
        AlignSubject(name: name, id: id) { store, _, before, what in
            #expect(store.tree == before, "\(what): nothing changes")
        }
    }
}

/// The design the Align parity tests share (2026-11-26), its ids fixed so that every app made from it holds the same
/// tree. An iPhone screen with a free root holds:
/// - a row at (20, 100), 8 apart, lined up at the top, of a short text and a tall one;
/// - a column at (20, 200), 8 apart, lined up on the left, of a narrow text and a wide one;
/// - a grid of two at (20, 320), 8 apart, centred, of three texts of two sizes;
/// - an overlay at (20, 440), centred, of a wide text behind a narrow one;
/// - a free card at (20, 540) holding a text at (16, 16);
/// - a text at (20, 700) on the root.
///
/// A second screen, at (453, 0), lays its root out in a column 24 apart, lined up on the left, of a narrow and a wide
/// text. The open canvas holds a row at (1000, 100) like the screen's, and a sticky note at (1000, 300).
@MainActor
private struct AlignFixture {
    let tree: TreeContent
    let subjects: [AlignSubject]
    /// Two things together: in each laid-out parent; one in a free parent and one in a row; one in a row and one in a
    /// column.
    let pairs: [(name: String, ids: [UUID])]
    let rowChild, card, inCard, loose: UUID

    init() {
        let row = LayerNode.Stack(axis: .horizontal, spacing: 8), column = LayerNode.Stack(axis: .vertical, spacing: 8)
        let grid = LayerNode.Grid(columns: 2, columnSpacing: 8, rowSpacing: 8), overlay = LayerNode.Alignment()
        let root = LayerNode.Stack(axis: .vertical, spacing: 24)

        let rowA = text(0, 0), rowB = text(0, 0, height: 40)
        let rowNode = container(.group, .stack(row), frame: CGRect(x: 20, y: 100, width: 128, height: 40), [rowA, rowB])
        let columnA = text(0, 0), columnB = text(0, 0, width: 100)
        let columnNode = container(.group, .stack(column), frame: CGRect(x: 20, y: 200, width: 100, height: 56),
                                   [columnA, columnB])
        let gridA = text(0, 0), gridB = text(0, 0, width: 100, height: 40), gridC = text(0, 0)
        let gridNode = container(.group, .grid(grid), frame: CGRect(x: 20, y: 320, width: 208, height: 72), [gridA, gridB, gridC])
        let back = text(0, 0, width: 120, height: 60), front = text(0, 0)
        let overlayNode = container(.group, .overlay(overlay), frame: CGRect(x: 20, y: 440, width: 120, height: 60), [back, front])
        let inCard = text(16, 16)
        let card = container(.card, frame: CGRect(x: 20, y: 540, width: 200, height: 100), [inCard])
        let loose = text(20, 700)
        var free = screen([rowNode, columnNode, gridNode, overlayNode, card, loose])
        free.name = "Free"

        let rootA = text(0, 0), rootB = text(0, 0, width: 200)
        var laidOut = TreeScreen(name: "Column", origin: CGPoint(x: 453, y: 0), scale: 1, deviceID: nil)
        laidOut.root.layout = .stack(root)
        laidOut.root.children = [rootA, rootB]

        let canvasA = text(0, 0), canvasB = text(0, 0, height: 40)
        let canvasRow = container(.group, .stack(row), frame: CGRect(x: 1000, y: 100, width: 128, height: 40), [canvasA, canvasB])
        var note = LayerNode(kind: .stickyNote)
        note.frame = CGRect(x: 1000, y: 300, width: 150, height: 150)
        note.content.text = "Idea"

        tree = design([free, laidOut], canvas: [canvasRow, note])
        subjects = [
            .inARow("a row's child", rowA.id, in: rowNode.id, row),
            .inAColumn("a column's child", columnA.id, in: columnNode.id, column),
            .laidOut("a grid's child", gridB.id, in: gridNode.id) { button in
                var aligned = grid
                aligned.alignment = AlignSubject.both(grid.alignment, button)
                return .grid(aligned)
            },
            .laidOut("an overlay's child", front.id, in: overlayNode.id) { .overlay(AlignSubject.both(overlay, $0)) },
            .inAColumn("a laid-out screen root's child", rootA.id, in: laidOut.root.id, root),
            .inARow("a row's child on the open canvas", canvasA.id, in: canvasRow.id, row),
            .onItsScreen("a free card's child", inCard.id),
            .onItsScreen("a thing on a free root", loose.id),
            .offScreen("a sticky note on the open canvas", note.id),
        ]
        pairs = [
            ("a row's children", [rowA.id, rowB.id]),
            ("a column's children", [columnA.id, columnB.id]),
            ("a grid's children", [gridA.id, gridC.id]),
            ("an overlay's children", [back.id, front.id]),
            ("a laid-out screen root's children", [rootA.id, rootB.id]),
            ("a canvas row's children", [canvasA.id, canvasB.id]),
            ("a free thing and a row's child", [loose.id, rowB.id]),
            ("a row's child and a column's", [rowA.id, columnA.id]),
        ]
        rowChild = rowA.id
        self.card = card.id
        self.inCard = inCard.id
        self.loose = loose.id
    }
}

/// Three apps made from one tree, each with an undo history of its own: one for the Format panel's Align, one for
/// voice's (a toolbox on the handles of one capture, as a call has) and one for Siri's. `prepare` runs on each, as no
/// step.
@MainActor
private struct AlignSurfaces {
    @MainActor
    struct App {
        let model: AppModel
        let undo: UndoManager
        var store: DesignStore { model.store }
    }

    let panel: App
    let voice: App
    let siri: App
    let handles: VoiceHandles
    let box: VoiceToolbox

    var apps: [App] { [panel, voice, siri] }

    init(_ tree: TreeContent, prepare: (DesignStore) -> Void = { _ in }) {
        func app() -> App {
            let (model, undo) = makeModel(tree)
            prepare(model.store)
            undo.removeAllActions()
            return App(model: model, undo: undo)
        }
        panel = app()
        voice = app()
        siri = app()
        handles = VoiceHandles()
        _ = CanvasPicture.capture(from: voice.model, handles: handles)
        box = VoiceToolbox(model: voice.model, handles: handles)
    }

    /// The words voice's model says for each alignment.
    static func spoken(_ alignment: ElementLayout.Alignment) -> String {
        switch alignment {
        case .left: "left"
        case .centerX: "centre"
        case .right: "right"
        case .top: "top"
        case .centerY: "vertical centre"
        case .bottom: "bottom"
        }
    }

    /// Selects the thing on the panel's app and taps its Align button: whether the button was on.
    func alignOnThePanel(_ id: UUID, _ alignment: ElementLayout.Alignment) -> Bool {
        panel.model.selection = panel.store.ref(of: id).map(CanvasSelection.element)
        let isOn = panel.model.canLineUpSelection(alignment)
        panel.model.lineUpSelection(alignment)
        return isOn
    }

    /// Asks voice's `alignElement` to align the thing: what it said.
    func alignByVoice(_ id: UUID, _ alignment: ElementLayout.Alignment) -> String {
        box.alignElement(element: handles.handle(forNode: id), alignment: Self.spoken(alignment))
    }

    /// Runs Siri's Align Element on the thing: the error it threw, or nil.
    func alignBySiri(_ id: UUID, _ alignment: ElementLayout.Alignment) -> LayerIntentError? {
        guard let ref = siri.store.ref(of: id) else { return .elementNotFound }
        do {
            try AlignElementIntent.align(ref, in: siri.model, alignment, undoManager: nil)
            return nil
        } catch let error as LayerIntentError {
            return error
        } catch {
            Issue.record("Siri's Align threw \(error)")
            return nil
        }
    }

    /// What Siri says for an error.
    func said(_ error: LayerIntentError?) -> String? {
        error.map { String(localized: $0.localizedStringResource) }
    }

    /// On each app that changed: one undo puts `before` back, and there is nothing more to undo.
    func expectOneStepEach(back before: TreeContent, _ what: String) {
        for (name, app) in [("panel", panel), ("voice", voice), ("Siri", siri)] where app.store.tree != before {
            app.undo.undo()
            #expect(app.store.tree == before, "\(what): \(name)'s undo")
            #expect(!app.undo.canUndo, "\(what): \(name)'s one step")
        }
    }
}

private extension DesignStore {
    /// The things with these ids, wherever they are.
    func selection(of ids: [UUID]) throws -> CanvasSelection {
        try #require(CanvasSelection(ids.compactMap(ref(of:)).map(CanvasSelection.element)))
    }

    /// Its turned shape's centre on the canvas.
    func canvasCentre(of id: UUID) throws -> CGPoint {
        try #require(placed(id)).canvasShape.centre
    }
}

/// Group as Row, Column, Grid or Card from the popover's Group menu (plan 4, Task 6; call 8): things wrapped in reading
/// order at their sizes, spaced and aligned as they were, the first keeping its place; and Align in a laid-out parent
/// setting that parent's alignment.
@Suite("Group as")
@MainActor
struct GroupAsTests {
    // MARK: The layouts

    @Test func groupAsRowSortsByXFixesSizesAndKeepsTheFirstInPlace() throws {
        let right = text(200, 100), left = text(20, 100), middle = text(110, 100)
        let (model, _) = makeModel(design([screen([right, left, middle])]))
        let store = model.store

        let made = try #require(store.group(store.selection(of: [right.id, left.id, middle.id]), as: .row))

        let row = try #require(store.node(made.node))
        #expect(row.kind == .group)
        #expect(row.width.mode == .fit && row.height.mode == .fit)
        #expect(row.children.map(\.id) == [left.id, middle.id, right.id])
        for child in row.children {
            #expect(child.width.mode == .fixed && child.height.mode == .fixed)
            #expect(child.frame.size == CGSize(width: 60, height: 24))
        }
        // The gaps are 30, and the nearest step is 32.
        #expect(TreeEdit.nearestStep(30, in: rhythm) == 32)
        #expect(row.resolvedLayout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 32, alignment: .start)))
        #expect(store.placed(left.id)?.frame == CGRect(x: 20, y: 100, width: 60, height: 24))
    }

    @Test func groupAsColumnReadsTopToBottom() throws {
        // Leading edges that agree, where the centres and trailing edges don't.
        let low = text(20, 300, width: 60), high = text(20, 100, width: 80), middle = text(20, 200, width: 100)
        let (model, _) = makeModel(design([screen([low, high, middle])]))
        let store = model.store

        let made = try #require(store.group(store.selection(of: [low.id, high.id, middle.id]), as: .column))

        let column = try #require(store.node(made.node))
        #expect(column.children.map(\.id) == [high.id, middle.id, low.id])
        #expect(column.resolvedLayout == .stack(LayerNode.Stack(axis: .vertical, spacing: 32, alignment: .start)))
        #expect(store.placed(high.id)?.frame == CGRect(x: 20, y: 100, width: 80, height: 24))

        // Centres that agree give centre, and trailing edges that agree give end. A gap of 26 is nearest 24.
        let centred = [text(40, 0, width: 60), text(20, 50, width: 100)]
        #expect(TreeEdit.groupedLayout(of: centred, as: .column, rhythm: rhythm)
            == .stack(LayerNode.Stack(axis: .vertical, spacing: 24, alignment: .center)))
        let ending = [text(40, 0, width: 60), text(0, 50, width: 100)]
        #expect(TreeEdit.groupedLayout(of: ending, as: .column, rhythm: rhythm)
            == .stack(LayerNode.Stack(axis: .vertical, spacing: 24, alignment: .end)))
    }

    @Test func groupAsGridTakesItsColumnsFromTheFirstRow() throws {
        let a = square(100, 0), b = square(0, 0), c = square(100, 60), d = square(0, 60)
        let (model, _) = makeModel(design([screen([a, b, c, d])]))
        let store = model.store

        let made = try #require(store.group(store.selection(of: [a.id, b.id, c.id, d.id]), as: .grid))

        let grid = try #require(store.node(made.node))
        #expect(grid.children.map(\.id) == [b.id, a.id, d.id, c.id])
        guard case .grid(let layout) = grid.resolvedLayout else {
            Issue.record("Grouped as a grid, it is \(grid.resolvedLayout)")
            return
        }
        #expect(layout.columns == 2)
        #expect(layout.columnSpacing == 32)
        // A 10 gap ties between 8 and 12, so it takes the smaller.
        #expect(layout.rowSpacing == 8)
        #expect(store.placed(b.id)?.frame == CGRect(x: 0, y: 0, width: 50, height: 50))

        let threeAndOne = [square(100, 0), square(0, 0), square(200, 0), square(0, 60)]
        guard case .grid(let wider) = TreeEdit.groupedLayout(of: threeAndOne, as: .grid, rhythm: rhythm) else {
            Issue.record("Not a grid")
            return
        }
        #expect(wider.columns == 3)
    }

    @Test func groupAsCardIsAColumnUnlessTheyShareARow() throws {
        let top = text(20, 100), bottom = text(20, 200)
        let (model, _) = makeModel(design([screen([top, bottom])]))
        let store = model.store

        let made = try #require(store.group(store.selection(of: [top.id, bottom.id]), as: .card))

        let card = try #require(store.node(made.node))
        #expect(card.kind == .card)
        guard case .stack(let stack) = card.resolvedLayout else {
            Issue.record("A card of two holds a \(card.resolvedLayout)")
            return
        }
        #expect(stack.axis == .vertical)
        #expect(card.padding == LayerNode.Padding(all: 16))
        #expect(card.width.mode == .fit && card.height.mode == .fit)
        #expect(store.placed(top.id)?.frame == CGRect(x: 20, y: 100, width: 60, height: 24))

        let beside = [text(20, 100), text(120, 100)]
        guard case .stack(let across) = TreeEdit.groupedLayout(of: beside, as: .card, rhythm: rhythm) else {
            Issue.record("Not a stack")
            return
        }
        #expect(across.axis == .horizontal)
    }

    /// The column is as wide as its widest, so the first, to the right of the second, would move left: the column
    /// moves instead, on a screen and on the open canvas, where things are drawn at a scale of their own.
    @Test func theFirstInReadingOrderKeepsItsPlaceWhereTheOthersMove() throws {
        let first = text(120, 100), second = text(20, 200)
        let (model, _) = makeModel(design([screen([second, first])]))
        let store = model.store

        _ = try #require(store.group(store.selection(of: [first.id, second.id]), as: .column))

        #expect(store.placed(first.id)?.frame == CGRect(x: 120, y: 100, width: 60, height: 24))
        #expect(store.placed(second.id)?.frame == CGRect(x: 120, y: 156, width: 60, height: 24))

        var high = text(60, 50), low = text(10, 100)
        high.scale = 2
        low.scale = 2
        let (canvas, _) = makeModel(design([], canvas: [low, high]))
        let corner = try #require(canvas.store.placed(high.id)).canvasShape.rect.origin

        _ = try #require(canvas.store.group(canvas.store.selection(of: [high.id, low.id]), as: .column))

        #expect(try #require(canvas.store.placed(high.id)).canvasShape.rect.origin == corner)
    }

    /// On the open canvas `wrap` frames things drawn at other scales in the frontmost one's, and the numbers are worked
    /// out there too (I1). In the front one's points the gap is 50, so the spacing is 32, and the centres agree. Read
    /// from the raw frames, the gap would be 0 and the tops would count as lined up: spacing 8, start.
    @Test func onTheOpenCanvasTheNumbersAreWorkedOutAtTheFrontOnesScale() throws {
        var back = text(0, 0, width: 100, height: 100), front = text(100, 12, width: 26, height: 26)
        back.scale = 1
        front.scale = 2
        let (model, _) = makeModel(design([], canvas: [back, front]))
        let store = model.store
        let line = try store.canvasCentre(of: back.id).y
        #expect(try store.canvasCentre(of: front.id).y == line)

        let made = try #require(store.group(store.selection(of: [back.id, front.id]), as: .row))

        let row = try #require(store.node(made.node))
        #expect(row.resolvedLayout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 32, alignment: .center)))
        // The first keeps its place, and the other stays on the line through their centres.
        #expect(try #require(store.placed(back.id)).canvasShape.rect.origin == .zero)
        #expect(try store.canvasCentre(of: front.id).y == line)
    }

    // MARK: What can be grouped

    /// The Group button offers the shapes what is selected can be grouped as (I2, call 8): a tap groups only when Group
    /// is among them, and opens the menu otherwise. One thing is offered a card.
    @Test func theGroupButtonOffersWhatCanBeGrouped() throws {
        let a = text(0, 0), b = text(100, 0)
        let g = container(frame: CGRect(x: 20, y: 100, width: 160, height: 24), [a, b])
        var locked = text(120, 300)
        locked.isLocked = true
        let loose = text(20, 300), other = text(20, 400)
        var ink = LayerNode(kind: .drawing)
        ink.frame = CGRect(x: 600, y: 0, width: 40, height: 40)
        let note = text(700, 0)
        let (model, _) = makeModel(design([screen([g, loose, locked, other])], canvas: [ink, note]))
        let store = model.store
        func offered(_ ids: [UUID]) throws -> [GroupShape] {
            model.selection = try store.selection(of: ids)
            return model.groupShapesOffered
        }

        #expect(try offered([loose.id, other.id]) == GroupShape.allCases)
        // All of a free group: everything but Group, which would make that group again.
        #expect(try offered([a.id, b.id]) == [.row, .column, .grid, .card])
        // A locked thing, or a drawing, is left out, leaving one thing: a card.
        #expect(try offered([locked.id, loose.id]) == [.card])
        #expect(try offered([ink.id, note.id]) == [.card])
        #expect(try offered([loose.id]) == [.card])
        model.selection = nil
        #expect(model.groupShapesOffered.isEmpty)

        model.selection = try store.selection(of: [loose.id])
        model.groupSelection(as: .card)
        #expect(model.selectedNode?.node.kind == .card)
        #expect(model.selectedNode?.node.children.map(\.id) == [loose.id])
    }

    @Test func aCardCanHoldOneThingAndTheOthersNeedTwo() throws {
        let one = text(20, 100)
        let (model, _) = makeModel(design([screen([one])]))
        let store = model.store
        let selection = try store.selection(of: [one.id])
        model.selection = selection

        #expect(store.canGroup(selection, as: .card))
        #expect(model.canGroupSelection(as: .card))
        for shape in [GroupShape.group, .row, .column, .grid] {
            #expect(!store.canGroup(selection, as: shape))
            #expect(!model.canGroupSelection(as: shape))
        }

        model.groupSelection(as: .card)

        let card = try #require(model.selectedNode)
        #expect(card.node.kind == .card)
        #expect(card.node.children.map(\.id) == [one.id])
    }

    @Test func thingsInDifferentContainersCantBeGrouped() throws {
        let loose = text(20, 100), held = text(16, 16)
        let card = container(.card, frame: CGRect(x: 20, y: 300, width: 92, height: 56), [held])
        let (model, _) = makeModel(design([screen([loose, card])]))
        let store = model.store
        let selection = try store.selection(of: [loose.id, held.id])

        for shape in GroupShape.allCases {
            #expect(!store.canGroup(selection, as: shape))
        }
    }

    @Test func allOfAFreeGroupIsRefusedOnlyAsAGroup() throws {
        let a = text(0, 0), b = text(100, 0)
        let g = container(frame: CGRect(x: 20, y: 100, width: 160, height: 24), [a, b])
        let (model, _) = makeModel(design([screen([g])]))
        let store = model.store
        let both = try store.selection(of: [a.id, b.id])

        #expect(!store.canGroup(both, as: .group))
        #expect(store.canGroup(both, as: .row))
        for shape in [GroupShape.column, .grid, .card] {
            #expect(store.canGroup(both, as: shape))
        }
    }

    /// Wrapped, then moved so that the first keeps its place: two changes, one step.
    @Test func groupingIsOneUndoStep() throws {
        let first = text(120, 100), second = text(20, 200)
        let (model, undo) = makeModel(design([screen([first, second])]))
        let store = model.store
        let before = store.tree

        _ = try #require(store.group(store.selection(of: [first.id, second.id]), as: .column))
        #expect(store.tree != before)
        undo.undo()

        #expect(store.tree == before)
        #expect(!undo.canUndo)
    }

    /// With the things at depth 32, a container round them would be 33 deep (F15); one level up it would fit. A design
    /// of 5,000 nodes has no room for the container either.
    @Test func groupingPastTheStoresLimitsIsOff() throws {
        let a = text(0, 0), b = text(100, 0)
        var nested = container(.card, frame: CGRect(x: 0, y: 0, width: 300, height: 300), [a, b])
        for _ in 1..<30 { nested = container(.card, frame: CGRect(x: 0, y: 0, width: 300, height: 300), [nested]) }
        let roomy = makeModel(design([screen([nested])])).model.store
        #expect(roomy.index[a.id]?.depth == 31)
        #expect(roomy.canGroup(try roomy.selection(of: [a.id, b.id]), as: .row))

        nested = container(.card, frame: CGRect(x: 0, y: 0, width: 300, height: 300), [nested])
        let (model, _) = makeModel(design([screen([nested])]))
        let store = model.store
        #expect(store.index[a.id]?.depth == 32)
        let selection = try store.selection(of: [a.id, b.id])
        let before = store.tree

        for shape in GroupShape.allCases {
            #expect(!store.canGroup(selection, as: shape))
            #expect(store.group(selection, as: shape) == nil)
        }
        #expect(store.tree == before)

        // A screen's root and 4,999 things on it are 5,000 nodes.
        let many = (0..<4_999).map { text(CGFloat($0 % 50) * 8, CGFloat($0 / 50) * 8, width: 4, height: 4) }
        let full = makeModel(design([screen(many)])).model.store
        #expect(full.index.count == TreeRules.maximumNodes)
        let two = try full.selection(of: [many[0].id, many[1].id])
        for shape in GroupShape.allCases {
            #expect(!full.canGroup(two, as: shape))
        }
    }

    // MARK: Lining up in a laid-out parent

    @Test func lineUpInAColumnEditsItsAlignment() throws {
        let narrow = text(0, 0, width: 60), wide = text(0, 0, width: 100)
        let column = container(.group, .stack(LayerNode.Stack(axis: .vertical, spacing: 8)),
                               frame: CGRect(x: 20, y: 100, width: 100, height: 56), [narrow, wide])
        let (model, undo) = makeModel(design([screen([column])]))
        let store = model.store
        model.selection = try store.selection(of: [narrow.id])
        #expect(model.isSelectionLaidOut)

        #expect(model.canLineUpSelection(.centerX))
        model.lineUpSelection(.centerX)

        #expect(store.node(column.id)?.resolvedLayout == .stack(LayerNode.Stack(axis: .vertical, spacing: 8, alignment: .center)))
        undo.undo()
        #expect(store.node(column.id)?.resolvedLayout == .stack(LayerNode.Stack(axis: .vertical, spacing: 8, alignment: .start)))
        #expect(!undo.canUndo)

        // Top is along a column, not across it: nothing to line up.
        let before = store.tree
        #expect(!model.canLineUpSelection(.top))
        model.lineUpSelection(.top)
        #expect(store.tree == before)
    }

    @Test func lineUpInAFreeParentIsTodaysAlign() throws {
        let a = text(20, 100), b = text(60, 200, width: 100)
        let tree = design([screen([a, b])])
        let (aligned, _) = makeModel(tree), (linedUp, _) = makeModel(tree)
        let selection = try aligned.store.selection(of: [a.id, b.id])
        aligned.selection = selection
        linedUp.selection = selection
        #expect(!linedUp.isSelectionLaidOut)
        #expect(linedUp.canLineUpSelection(.left))

        aligned.alignSelection(.left)
        linedUp.lineUpSelection(.left)

        #expect(linedUp.store.node(b.id)?.frame.minX == 20)
        #expect(linedUp.store.tree == aligned.store.tree)
    }

    /// Spec §10: Align and Distribute apply in free parents. Across parents, what a row places stays where it is, and the
    /// rest line up with it all the same, as with a locked thing; today's align took it out of its row.
    @Test func lineUpAcrossParentsMovesOnlyWhatIsInAFreeParent() throws {
        let held = text(0, 0), beside = text(0, 0)
        let row = container(.group, .stack(LayerNode.Stack(axis: .horizontal, spacing: 8)),
                            frame: CGRect(x: 20, y: 100, width: 128, height: 24), [held, beside])
        let wide = text(60, 300, width: 100)
        let (model, _) = makeModel(design([screen([row, wide])]))
        let store = model.store
        let place = try #require(store.placed(held.id)).frame
        model.selection = try store.selection(of: [held.id, wide.id])
        #expect(!model.isSelectionLaidOut)
        #expect(model.canLineUpSelection(.centerX))

        model.lineUpSelection(.centerX)

        // Centred in the area both cover, 20 to 160: the free one moves, and the row's stays in its row.
        #expect(store.parent(of: held.id) == .node(row.id))
        #expect(store.placed(held.id)?.frame == place)
        #expect(store.placed(wide.id)?.frame.minX == 40)

        // Distributed across: the ends stay, the row's child stays, and the other free one takes its even place.
        let first = text(20, 200), middle = text(0, 0), third = text(220, 300), last = text(400, 400), alone = text(0, 0)
        let holding = container(.group, .stack(LayerNode.Stack(axis: .horizontal, spacing: 8)),
                                frame: CGRect(x: 150, y: 100, width: 60, height: 24), [middle])
        let another = container(.group, .stack(LayerNode.Stack(axis: .horizontal, spacing: 8)),
                                frame: CGRect(x: 20, y: 500, width: 60, height: 24), [alone])
        let (spread, _) = makeModel(design([screen([first, holding, third, last, another])]))
        let spreadStore = spread.store
        let middlePlace = try #require(spreadStore.placed(middle.id)).frame
        spread.selection = try spreadStore.selection(of: [first.id, middle.id, third.id, last.id])
        #expect(spread.canLineUpSelection(.horizontal))

        spread.lineUpSelection(.horizontal)

        #expect(spreadStore.parent(of: middle.id) == .node(holding.id))
        #expect(spreadStore.placed(middle.id)?.frame == middlePlace)
        // 20 to 460 holds 240 of things and three gaps of 66.67: the third starts at 273.33, on a whole point.
        #expect(spreadStore.placed(third.id)?.frame.minX == 273)
        #expect(spreadStore.placed(first.id)?.frame.minX == 20)
        #expect(spreadStore.placed(last.id)?.frame.minX == 400)

        // Things in two rows, and nothing in a free parent: nothing to line up.
        spread.selection = try spreadStore.selection(of: [middle.id, alone.id])
        #expect(!spread.canLineUpSelection(.left))
        let before = spreadStore.tree
        spread.lineUpSelection(.left)
        #expect(spreadStore.tree == before)
    }

    /// The popover asks after every change whether each shape can group, and whether each alignment applies, and then
    /// groups and lines up, all on the tree. The check that none of it lowered the design went with the flat list (plan
    /// 6, Task 11, clause (s)).
    @Test func groupingAndLiningUpWorkOnTheTree() throws {
        let narrow = text(0, 0, width: 60), wide = text(0, 0, width: 100)
        let column = container(.group, .stack(LayerNode.Stack(axis: .vertical, spacing: 8)),
                               frame: CGRect(x: 20, y: 100, width: 100, height: 56), [narrow, wide])
        let a = text(20, 300), b = text(120, 300)
        let (model, _) = makeModel(design([screen([column, a, b])]))
        let store = model.store
        let inColumn = try store.selection(of: [narrow.id]), loose = try store.selection(of: [a.id, b.id])

        model.selection = inColumn
        #expect(model.isSelectionLaidOut)
        #expect(ElementLayout.Alignment.allCases.filter(model.canLineUpSelection) == [.left, .centerX, .right])
        model.lineUpSelection(.centerX)
        model.selection = loose
        #expect(!model.isSelectionLaidOut)
        #expect(GroupShape.allCases.allSatisfy(model.canGroupSelection(as:)))
        model.groupSelection(as: .row)
        #expect(model.selectedNode?.node.children.map(\.id) == [a.id, b.id])
    }

    /// My call 15: a row's children have the one order its layout gives them; an overlay stacks what it holds.
    @Test func arrangeIsOffForARowsChildAndOnInAnOverlay() throws {
        let first = text(0, 0), middle = text(0, 0), last = text(0, 0)
        let row = container(.group, .stack(LayerNode.Stack(axis: .horizontal, spacing: 8)),
                            frame: CGRect(x: 20, y: 100, width: 200, height: 24), [first, middle, last])
        let back = text(0, 0), front = text(0, 0)
        let overlay = container(.group, .overlay(LayerNode.Alignment()), frame: CGRect(x: 20, y: 300, width: 60, height: 24),
                                [back, front])
        let (model, _) = makeModel(design([screen([row, overlay])]))

        model.selection = try model.store.selection(of: [middle.id])
        #expect(!model.canArrangeSelection(.forward))

        model.selection = try model.store.selection(of: [back.id])
        #expect(model.canArrangeSelection(.forward))
    }

    // MARK: One rule for Align on every surface (2026-11-26)

    /// The user asked for one standard for aligning things in a row, and it is the Format panel's (spec §10): one thing
    /// a row, column, grid or overlay places, a screen's laid-out root among them, is lined up by that parent's
    /// alignment when the parent has a use for it; when it has none, nothing changes; and one thing in a free parent
    /// lines up with its screen. The panel, voice's `alignElement` and Siri's Align Element each act on an app of their
    /// own holding the same tree and leave the same tree, which one undo takes back, and each does something exactly
    /// when the panel's button is on.
    @Test(arguments: ElementLayout.Alignment.allCases)
    func oneThingIsAlignedAlikeOnEverySurface(_ alignment: ElementLayout.Alignment) throws {
        let fixture = AlignFixture()
        for subject in fixture.subjects {
            let surfaces = AlignSurfaces(fixture.tree)
            let before = surfaces.panel.store.tree
            #expect(surfaces.voice.store.tree == before && surfaces.siri.store.tree == before)
            let what = "\(subject.name), \(alignment)"

            let isOn = surfaces.alignOnThePanel(subject.id, alignment)
            let line = surfaces.alignByVoice(subject.id, alignment)
            let error = surfaces.alignBySiri(subject.id, alignment)

            let after = surfaces.panel.store.tree
            #expect(surfaces.voice.store.tree == after, "\(what): voice said “\(line)”")
            #expect(surfaces.siri.store.tree == after, "\(what): Siri said \(surfaces.said(error) ?? "nothing")")
            #expect(surfaces.box.lastFailed == !isOn, "\(what): voice said “\(line)”")
            #expect((error == nil) == isOn, "\(what): Siri said \(surfaces.said(error) ?? "nothing")")
            subject.expect(surfaces.panel.store, alignment, before, what)
            surfaces.expectOneStepEach(back: before, what)
        }
    }

    /// Several things: the popover's Align and voice's leave the same tree, in one laid-out parent (its alignment, or
    /// nothing), across a free and a laid-out parent (the free one moves), and across two laid-out parents (nothing).
    @Test(arguments: ElementLayout.Alignment.allCases)
    func severalThingsAreAlignedAlikeByThePopoverAndVoice(_ alignment: ElementLayout.Alignment) throws {
        let fixture = AlignFixture()
        for pair in fixture.pairs {
            let surfaces = AlignSurfaces(fixture.tree)
            let before = surfaces.panel.store.tree
            let what = "\(pair.name), \(alignment)"

            surfaces.panel.model.selection = try surfaces.panel.store.selection(of: pair.ids)
            let isOn = surfaces.panel.model.canLineUpSelection(alignment)
            surfaces.panel.model.lineUpSelection(alignment)
            let named = pair.ids.map { surfaces.handles.handle(forNode: $0) }.joined(separator: ", ")
            let line = surfaces.box.alignElement(element: named, alignment: AlignSurfaces.spoken(alignment))

            #expect(surfaces.voice.store.tree == surfaces.panel.store.tree, "\(what): voice said “\(line)”")
            #expect(surfaces.box.lastFailed == !isOn, "\(what): voice said “\(line)”")
            surfaces.expectOneStepEach(back: before, what)
        }
    }

    /// Locked things are refused as before, on every surface: by their own lock, and by their container's.
    @Test(arguments: ElementLayout.Alignment.allCases)
    func aLockedThingIsRefusedOnEverySurface(_ alignment: ElementLayout.Alignment) throws {
        let fixture = AlignFixture()
        for (name, id, locking) in [("a row's child", fixture.rowChild, fixture.rowChild),
                                    ("a thing in a locked card", fixture.inCard, fixture.card),
                                    ("a thing on a free root", fixture.loose, fixture.loose)] {
            let surfaces = AlignSurfaces(fixture.tree) { store in store.update(locking) { $0.isLocked = true } }
            let before = surfaces.panel.store.tree
            let what = "\(name), \(alignment)"

            #expect(!surfaces.alignOnThePanel(id, alignment), "\(what)")
            #expect(surfaces.alignByVoice(id, alignment) == "\(surfaces.handles.handle(forNode: id)) is locked.", "\(what)")
            #expect(surfaces.said(surfaces.alignBySiri(id, alignment)) == "That's locked. Unlock it in Layer first.", "\(what)")
            for app in surfaces.apps {
                #expect(app.store.tree == before, "\(what)")
                #expect(!app.undo.canUndo, "\(what)")
            }
        }
    }

    // MARK: Ungroup

    @Test func ungroupingATurnedCardFromThePopoverKeepsPlaces() throws {
        let a = text(0, 0), b = text(0, 0)
        var card = container(.card, .stack(LayerNode.Stack(axis: .vertical, spacing: 16)),
                             frame: CGRect(x: 100, y: 200, width: 92, height: 96), [a, b])
        card.padding = LayerNode.Padding(all: 16)
        card.rotation = 90
        let (model, _) = makeModel(design([screen([card])]))
        let store = model.store
        let centres = try [a.id, b.id].map { try store.canvasCentre(of: $0) }
        model.selection = try store.selection(of: [card.id])
        #expect(model.canUngroupSelection)

        model.ungroupSelection()

        #expect(store.node(card.id) == nil)
        for (id, centre) in zip([a.id, b.id], centres) {
            let now = try store.canvasCentre(of: id)
            #expect(abs(now.x - centre.x) < 0.001 && abs(now.y - centre.y) < 0.001)
        }
        let members = try store.selection(of: [a.id, b.id])
        #expect(model.selection == members)
    }
}
