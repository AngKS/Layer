import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// An app showing `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeModel(_ tree: TreeContent) -> (model: AppModel, undo: UndoManager) {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
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

        let row = try #require(store.node(made.element))
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

        let column = try #require(store.node(made.element))
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

        let grid = try #require(store.node(made.element))
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

        let card = try #require(store.node(made.element))
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

    // MARK: What can be grouped

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

    /// The popover asks after every change whether each shape can group, and whether each alignment applies: neither
    /// that nor grouping and lining up lowers the design.
    @Test func groupingAndLiningUpLowerNothing() throws {
        let narrow = text(0, 0, width: 60), wide = text(0, 0, width: 100)
        let column = container(.group, .stack(LayerNode.Stack(axis: .vertical, spacing: 8)),
                               frame: CGRect(x: 20, y: 100, width: 100, height: 56), [narrow, wide])
        let a = text(20, 300), b = text(120, 300)
        let (model, _) = makeModel(design([screen([column, a, b])]))
        let store = model.store
        let inColumn = try store.selection(of: [narrow.id]), loose = try store.selection(of: [a.id, b.id])

        // The per-version memo is stale after a change, so a read of the projection lowers: the counter is live.
        store.update(a.id) { $0.content.text = "One" }
        let live = TreeProjection.lowerings
        _ = store.screens
        #expect(TreeProjection.lowerings - live == 1)

        store.update(a.id) { $0.content.text = "Two" }
        let before = TreeProjection.lowerings
        model.selection = inColumn
        #expect(model.isSelectionLaidOut)
        #expect(ElementLayout.Alignment.allCases.filter(model.canLineUpSelection) == [.left, .centerX, .right])
        model.lineUpSelection(.centerX)
        model.selection = loose
        #expect(!model.isSelectionLaidOut)
        #expect(GroupShape.allCases.allSatisfy(model.canGroupSelection(as:)))
        model.groupSelection(as: .row)
        #expect(model.selectedNode?.node.children.map(\.id) == [a.id, b.id])

        #expect(TreeProjection.lowerings - before == 0)
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
