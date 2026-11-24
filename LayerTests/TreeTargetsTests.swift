import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

private func leaf(_ kind: ElementKind = .text, _ frame: CGRect, text: String = "Text") -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    node.content.text = text
    return node
}

/// A text sized to fit its words on both axes, as one in a row usually is.
private func fittingText(_ text: String) -> LayerNode {
    var node = leaf(.text, .zero, text: text)
    node.width = LayerNode.Sizing(.fit)
    node.height = LayerNode.Sizing(.fit)
    return node
}

/// A container, fixed at `frame` unless it `fits` what it holds.
private func container(_ kind: ElementKind = .group, _ layout: LayerNode.Layout? = nil, frame: CGRect = .zero,
                       fits: Bool = false, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.layout = layout
    node.frame = frame
    if fits {
        node.width = LayerNode.Sizing(.fit)
        node.height = LayerNode.Sizing(.fit)
    }
    node.children = children
    return node
}

private func columnLayout(spacing: CGFloat = 12) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .vertical, spacing: spacing))
}

private func rowLayout(spacing: CGFloat = 8) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .horizontal, spacing: spacing))
}

/// An app showing one iPhone screen at the canvas's origin, drawn at its own size so that its points are the
/// canvas's, holding `children` on a free root, and `canvas` on the open canvas: laid out as a file read lays it out,
/// with an undo history of its own, and the view showing the canvas unscrolled and unzoomed.
@MainActor
private struct TreeBoard {
    let model: AppModel
    let undo = UndoManager()
    let screenID: TreeScreen.ID

    var store: DesignStore { model.store }

    init(_ children: [LayerNode], canvas: [LayerNode] = []) {
        var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
        screen.root.children = children
        var tree = TreeContent()
        tree.screens = [screen]
        tree.canvas = canvas
        TreeRules.apply(to: &tree, after: nil)
        model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        undo.groupsByEvent = false
        model.store.undoManager = undo
        screenID = screen.id
    }

    func ref(_ id: UUID) -> DesignStore.ElementRef {
        store.ref(of: id) ?? DesignStore.ElementRef(host: .canvas, element: id)
    }

    func thing(_ id: UUID) -> CanvasSelection { .element(ref(id)) }

    /// Its turned shape on the canvas.
    func shape(_ id: UUID) -> TurnedRect {
        store.placed(id)?.canvasShape ?? TurnedRect(rect: .null, degrees: 0)
    }

    func middle(_ id: UUID) -> CGPoint { shape(id).centre }

    /// What can be touched on the screen, back to front, while `entered` have been gone into.
    func targets(_ entered: Set<UUID> = []) -> [UUID] {
        store.treeTargets(entered: entered).hosts[.screen(screenID)]?.map(\.id) ?? []
    }

    /// A finger's tap at a point: what is there, picked as the canvas picks it.
    func tap(at point: CGPoint) {
        model.pick(model.hoverTarget(at: point))
    }

    /// A loop round an area of the canvas, its corners in turn.
    func loop(round rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
}

/// The board most of these tests use: a free root holding A, then a card holding t1 above a row of t2 and t3.
@MainActor
private struct CardBoard {
    let a: LayerNode
    let t1 = fittingText("One"), t2 = fittingText("Two"), t3 = fittingText("Three")
    let row: LayerNode
    let card: LayerNode
    let board: TreeBoard

    /// A at `frame`: by default above the card, apart from it.
    init(a frame: CGRect = CGRect(x: 20, y: 40, width: 200, height: 24)) {
        a = leaf(.text, frame, text: "A")
        row = container(.group, rowLayout(), fits: true, [t2, t3])
        card = container(.card, columnLayout(), frame: CGRect(x: 20, y: 200, width: 0, height: 0), fits: true, [t1, row])
        board = TreeBoard([a, card])
    }

    var model: AppModel { board.model }
    var store: DesignStore { board.store }
}

/// Hit-testing and selection on the tree (plan 4, Task 3): any container is one target until it is gone into, picked by
/// its box; gaps pick it, turned shapes are hit as turned, and the lasso and the box pick each host's top level whole.
@Suite("Targets on the tree")
@MainActor
struct TreeTargetsTests {
    // MARK: One target until gone into

    @Test func aContainerIsOneTargetUntilGoneInto() {
        let b = CardBoard()
        #expect(b.board.targets() == [b.a.id, b.card.id])
        #expect(b.board.targets([b.card.id]) == [b.a.id, b.t1.id, b.row.id])
        #expect(b.board.targets([b.card.id, b.row.id]) == [b.a.id, b.t1.id, b.t2.id, b.t3.id])
        // Each target is the thing's turned shape on the canvas, and knows what it is.
        let card = b.store.treeTargets(entered: []).hosts[.screen(b.board.screenID)]?.last
        #expect(card?.shape == b.board.shape(b.card.id))
        #expect(card?.isContainer == true)
        #expect(card?.isLocked == false)
    }

    @Test func aCardOrRowIsPickedWholeUntilGoneInto() {
        let b = CardBoard()
        let clock = TapClock(b.model)
        let onT2 = b.board.middle(b.t2.id)

        b.board.tap(at: onT2)
        #expect(b.model.selection == b.board.thing(b.card.id))
        clock.wait(100)
        b.board.tap(at: onT2)
        #expect(b.model.selection == b.board.thing(b.row.id))
        clock.wait(100)
        b.board.tap(at: onT2)
        #expect(b.model.selection == b.board.thing(b.t2.id))
        #expect(b.model.enteredGroups == [b.card.id, b.row.id])
    }

    @Test func aGapInAContainerPicksIt() throws {
        let b = CardBoard()
        let two = b.board.shape(b.t2.id).rect, three = b.board.shape(b.t3.id).rect
        try #require(three.minX - two.maxX > 2, "the row's gap is between its children")
        let gap = CGPoint(x: (two.maxX + three.minX) / 2, y: two.midY)
        #expect(b.board.shape(b.row.id).contains(gap))

        #expect(b.model.hoverTarget(at: gap) == b.board.thing(b.card.id))
        #expect(TreeTargets.leaf(at: gap, in: b.card.id, content: b.store.tree, index: b.store.index) == nil)

        b.model.selection = b.board.thing(b.t1.id)
        #expect(b.model.enteredGroups == [b.card.id])
        #expect(b.model.hoverTarget(at: gap) == b.board.thing(b.row.id))
        #expect(TreeTargets.leaf(at: b.board.middle(b.t3.id), in: b.card.id, content: b.store.tree, index: b.store.index) == b.t3.id)
    }

    @Test func aTurnedContainersChildIsHitByItsTurnedShape() throws {
        let child = leaf(.button, CGRect(x: 100, y: 100, width: 100, height: 100))
        // Two more in G's far corners, so that its box is 300 square however the rules fit it.
        let corner = leaf(.text, CGRect(x: 0, y: 0, width: 20, height: 20))
        let far = leaf(.text, CGRect(x: 280, y: 280, width: 20, height: 20))
        var g = container(.group, frame: CGRect(x: 0, y: 200, width: 300, height: 300), [corner, child, far])
        g.rotation = 45
        let board = TreeBoard([g])
        let shape = board.shape(child.id)
        try #require(abs(shape.degrees - 45) < 1e-9)
        let centre = shape.centre
        // Out along an axis, past its upright box but inside its turned one: a diamond reaching 70.7 points out.
        let inside = CGPoint(x: centre.x + 65, y: centre.y)
        // Towards a corner of its upright box, which the turned one doesn't reach.
        let outside = CGPoint(x: centre.x + 45, y: centre.y + 45)
        #expect(!shape.rect.contains(inside) && shape.contains(inside))
        #expect(shape.rect.contains(outside) && !shape.contains(outside))

        #expect(TreeTargets.leaf(at: inside, in: g.id, content: board.store.tree, index: board.store.index) == child.id)
        #expect(TreeTargets.leaf(at: outside, in: g.id, content: board.store.tree, index: board.store.index) == nil)
        #expect(board.model.hoverTarget(at: inside) == board.thing(child.id))
        #expect(board.model.hoverTarget(at: outside) == board.thing(g.id), "a gap in G's own turned box")

        // Gone into, the child's own target is turned too.
        board.model.selection = board.thing(corner.id)
        #expect(board.targets([g.id]) == [corner.id, child.id, far.id])
        #expect(board.model.hoverTarget(at: inside) == board.thing(child.id))
        #expect(board.model.hoverTarget(at: outside) == .screen(board.screenID))
    }

    // MARK: Hidden and locked

    @Test func hiddenThingsAreLookedThroughAndLockedOnesCanBeGoneInto() {
        // A lies behind the whole card.
        let hidden = CardBoard(a: CGRect(x: 0, y: 180, width: 300, height: 160))
        let onT1 = hidden.board.middle(hidden.t1.id)
        #expect(hidden.board.shape(hidden.a.id).contains(onT1))
        #expect(hidden.model.hoverTarget(at: onT1) == hidden.board.thing(hidden.t1.id))
        hidden.store.update(hidden.card.id) { $0.isHidden = true }
        #expect(hidden.board.targets() == [hidden.a.id])
        #expect(hidden.board.targets([hidden.card.id]) == [hidden.a.id], "nor are what is in it, gone into")
        #expect(hidden.model.hoverTarget(at: onT1) == hidden.board.thing(hidden.a.id))

        let locked = CardBoard()
        let clock = TapClock(locked.model)
        locked.store.update(locked.card.id) { $0.isLocked = true }
        let card = locked.store.treeTargets(entered: []).hosts[.screen(locked.board.screenID)]?.last
        #expect(card?.id == locked.card.id && card?.isLocked == true)
        let onLockedT1 = locked.board.middle(locked.t1.id)
        locked.board.tap(at: onLockedT1)
        #expect(locked.model.selection == locked.board.thing(locked.card.id))
        clock.wait(100)
        locked.board.tap(at: onLockedT1)
        #expect(locked.model.selection == locked.board.thing(locked.t1.id))
        let t1 = locked.store.treeTargets(entered: locked.model.enteredGroups).hosts[.screen(locked.board.screenID)]?
            .first { $0.id == locked.t1.id }
        #expect(t1?.isLocked == true, "locked by the card above it")
    }

    /// F14: an empty row has a box to pick, and a card has a look of its own; a free group with nothing showing has neither.
    @Test func anEmptyRowAndACardWithEverythingHiddenCanBeTouched() {
        let empty = container(.group, rowLayout(), frame: CGRect(x: 20, y: 100, width: 200, height: 44), [])
        var x = leaf(.text, CGRect(x: 16, y: 16, width: 100, height: 20)), y = leaf(.text, CGRect(x: 16, y: 50, width: 100, height: 20))
        x.isHidden = true
        y.isHidden = true
        let card = container(.card, frame: CGRect(x: 20, y: 200, width: 200, height: 100), [x, y])
        var p = leaf(.text, CGRect(x: 0, y: 0, width: 100, height: 20)), q = leaf(.text, CGRect(x: 0, y: 40, width: 100, height: 20))
        p.isHidden = true
        q.isHidden = true
        let group = container(.group, frame: CGRect(x: 20, y: 400, width: 100, height: 60), [p, q])
        let board = TreeBoard([empty, card, group])
        #expect(board.store.node(empty.id)?.children.isEmpty == true, "an empty row stays")

        #expect(board.targets() == [empty.id, card.id])
        #expect(board.model.hoverTarget(at: board.middle(empty.id)) == board.thing(empty.id))
        #expect(board.model.hoverTarget(at: board.middle(card.id)) == board.thing(card.id))
        #expect(board.model.hoverTarget(at: CGPoint(x: 40, y: 410)) == .screen(board.screenID))
        board.tap(at: board.middle(empty.id))
        #expect(board.model.selection == board.thing(empty.id))
    }

    @Test func aLockedDrawingIsTheCanvasesLastTarget() throws {
        var locked = try #require(LayerNode.drawing([OrderBoard.stroke(from: CGPoint(x: 520, y: 400), to: CGPoint(x: 640, y: 460))]))
        locked.isLocked = true
        let note = leaf(.stickyNote, CGRect(x: 500, y: 380, width: 140, height: 130))
        let loose = try #require(LayerNode.drawing([OrderBoard.stroke(from: CGPoint(x: 800, y: 400), to: CGPoint(x: 900, y: 460))]))
        let board = TreeBoard([], canvas: [locked, note, loose])
        let middle = board.middle(locked.id)
        #expect(board.shape(note.id).contains(middle), "they overlap there")

        #expect(board.store.treeTargets(entered: []).hosts[.canvas]?.map(\.id) == [note.id, locked.id])
        #expect(board.model.hoverTarget(at: middle) == board.thing(locked.id))
        #expect(board.model.hoverTarget(at: middle, skippingDrawings: true) == board.thing(note.id))
    }

    /// Voice looks through a container's gaps to the things in it, as it did through a group's: a card's padding
    /// included, which the projection held as a group's gap (fix round 1, I1). A tap there still picks the card.
    @Test func voiceLooksThroughACardsPaddingAsThroughAnyGap() throws {
        var card = container(.card, columnLayout(), frame: CGRect(x: 40, y: 200, width: 0, height: 0), fits: true, [fittingText("One")])
        card.padding = LayerNode.Padding(all: 16)
        let behind = leaf(.text, CGRect(x: 0, y: 180, width: 300, height: 120), text: "Behind")
        let onItsOwn = TreeBoard([card])
        let shape = onItsOwn.shape(card.id)
        try #require(shape.rect.width > 32 && shape.rect.height > 32)
        let padding = CGPoint(x: shape.rect.minX + 8, y: shape.rect.midY)
        #expect(TreeTargets.leaf(at: padding, in: card.id, content: onItsOwn.store.tree, index: onItsOwn.store.index) == nil)

        #expect(onItsOwn.model.hoverTarget(at: padding) == onItsOwn.thing(card.id), "a tap there picks the card")
        #expect(onItsOwn.model.hoverTarget(at: padding, skippingDrawings: true) == .screen(onItsOwn.screenID))

        let overSomething = TreeBoard([behind, card])
        #expect(overSomething.shape(behind.id).contains(padding))
        #expect(overSomething.model.hoverTarget(at: padding, skippingDrawings: true) == overSomething.thing(behind.id))

        // On the open canvas, off the screen, with nothing beneath, there is nothing to point at.
        var aside = card
        aside.frame.origin = CGPoint(x: 600, y: 200)
        let floating = TreeBoard([], canvas: [aside])
        let canvasPadding = CGPoint(x: floating.shape(card.id).rect.minX + 8, y: floating.shape(card.id).rect.midY)
        #expect(floating.model.hoverTarget(at: canvasPadding) == floating.thing(card.id))
        #expect(floating.model.hoverTarget(at: canvasPadding, skippingDrawings: true) == nil)
    }

    // MARK: The lasso and the box

    @Test func theLassoPicksTopLevelContainersWhole() throws {
        let b = CardBoard()
        let card = b.board.shape(b.card.id).rect
        #expect(b.store.things(enclosedBy: b.board.loop(round: card.insetBy(dx: -5, dy: -5))) == [b.board.thing(b.card.id)])

        // Round less than half of it, t1 and t2 inside whole: neither the card nor anything in it alone.
        let part = CGRect(x: card.minX - 5, y: card.minY - 5,
                          width: max(b.board.shape(b.t1.id).rect.maxX, b.board.shape(b.t2.id).rect.maxX) + 3 - (card.minX - 5),
                          height: card.height + 10)
        try #require((part.maxX - card.minX) / card.width < 0.45)
        #expect(b.store.things(enclosedBy: b.board.loop(round: part)).isEmpty)

        // All but the bottom of the screen: the screen itself.
        let screen = try #require(b.store.canvasFrame(of: .screen(b.board.screenID)))
        let most = CGRect(x: screen.minX - 5, y: screen.minY - 5, width: screen.width + 10, height: screen.height * 0.95 + 5)
        #expect(b.store.things(enclosedBy: b.board.loop(round: most)) == [.screen(b.board.screenID)])
    }

    // MARK: The summary

    @Test func aContainersSummaryNamesItsLayout() throws {
        let text = leaf(.text, CGRect(x: 20, y: 20, width: 200, height: 24))
        let aRow = container(.group, rowLayout(), frame: CGRect(x: 20, y: 60, width: 220, height: 44), [fittingText("Row")])
        let card = container(.card, frame: CGRect(x: 20, y: 120, width: 353, height: 120), [leaf(.text, CGRect(x: 16, y: 16, width: 80, height: 20))])
        let aColumn = container(.group, columnLayout(), frame: CGRect(x: 20, y: 260, width: 200, height: 100), [fittingText("Column")])
        let grid = container(.group, .grid(LayerNode.Grid(columns: 2)), frame: CGRect(x: 20, y: 380, width: 200, height: 100),
                             [fittingText("One"), fittingText("Two")])
        let overlay = container(.group, .overlay(LayerNode.Alignment()), frame: CGRect(x: 20, y: 500, width: 100, height: 100),
                                [fittingText("Over")])
        let group = container(.group, frame: CGRect(x: 20, y: 620, width: 200, height: 80),
                              [leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20)), leaf(.text, CGRect(x: 0, y: 40, width: 80, height: 20))])
        let board = TreeBoard([text, aRow, card, aColumn, grid, overlay, group])
        func summary(_ id: UUID) -> String? {
            board.model.selection = board.thing(id)
            return SelectionSummary.value(for: board.model)
        }

        #expect(summary(aRow.id) == "Row · 220 × 44")
        #expect(summary(card.id) == "Card · 353 × 120")
        #expect(summary(aColumn.id) == "Column · 200 × 100")
        #expect(summary(grid.id) == "Grid · 200 × 100")
        #expect(summary(overlay.id) == "Overlay · 100 × 100")
        let box = try #require(board.store.node(group.id)?.frame)
        #expect(summary(group.id) == "Group · \(Int(box.width)) × \(Int(box.height))")
        #expect(summary(text.id) == "200 × 24")

        board.model.selection = .screen(board.screenID)
        #expect(SelectionSummary.value(for: board.model) == "Screen · 393 × 852")
        board.model.selection = CanvasSelection([board.thing(text.id), board.thing(aRow.id)])
        #expect(SelectionSummary.value(for: board.model) == "2 items · 220 × 84")
        board.model.selection = nil
        #expect(SelectionSummary.value(for: board.model) == nil)
    }

    // MARK: What it costs

    /// Review Focus 2, F11: what can be touched, what the pen is over and what a tap picks are read from the tree.
    @Test func findingTargetsDoesNotLower() {
        let b = CardBoard()
        let screen = b.board.screenID
        let onT2 = b.board.middle(b.t2.id)
        var round = 0
        func change() {
            round += 1
            b.store.update(b.a.id) { $0.name = "A \(round)" }
        }

        // The per-version memo is stale after a change, so a read of the projection lowers: the counter is live.
        change()
        let live = TreeProjection.lowerings(of: screen)
        _ = b.store.screens
        #expect(TreeProjection.lowerings(of: screen) - live == 1)

        let before = TreeProjection.lowerings(of: screen)
        for _ in 0..<3 {
            change()
            #expect(b.store.treeTargets(entered: b.model.enteredGroups).hosts[.screen(screen)]?.isEmpty == false)
            change()
            #expect(b.model.hoverTarget(at: onT2) == b.board.thing(b.t2.id))
            change()
            b.model.pick(b.model.hoverTarget(at: onT2))
        }
        #expect(TreeProjection.lowerings(of: screen) - before == 0)
    }

    /// F10: ten reads build the targets at most once, and after a change exactly once more.
    @Test func targetsAreBuiltOncePerVersionAndEntered() {
        let b = CardBoard()
        let start = CanvasWork.targetPasses
        for _ in 0..<10 { _ = b.store.treeTargets(entered: []) }
        #expect(CanvasWork.targetPasses - start <= 1)

        b.store.update(b.a.id) { $0.name = "Changed" }
        let changed = CanvasWork.targetPasses
        for _ in 0..<10 { _ = b.store.treeTargets(entered: []) }
        #expect(CanvasWork.targetPasses - changed == 1)

        let entered = CanvasWork.targetPasses
        for _ in 0..<10 { _ = b.store.treeTargets(entered: [b.card.id]) }
        #expect(CanvasWork.targetPasses - entered == 1, "another set gone into is worked out again, once")
    }

    // MARK: Locking and hiding

    /// Ruling D: Unlock unlocks the locked containers above what is selected, in one step.
    @Test func unlockingAChildOfALockedCardUnlocksTheCard() {
        let b = CardBoard()
        b.store.update(b.card.id) { $0.isLocked = true }
        b.store.update(b.row.id) { $0.isLocked = true }
        b.model.selection = b.board.thing(b.t2.id)
        #expect(b.model.isSelectionLocked)
        let locked = b.store.tree

        b.model.setSelectionLocked(false)

        #expect(b.store.node(b.card.id)?.isLocked == false)
        #expect(b.store.node(b.row.id)?.isLocked == false)
        #expect(b.store.node(b.t2.id)?.isLocked == false)
        #expect(!b.model.isSelectionLocked)
        b.board.undo.undo()
        #expect(b.store.tree == locked, "one step")

        // A Layers row's toggle on a thing locked only by its card unlocks the card, and never locks the thing.
        b.model.toggleLock(b.board.ref(b.t1.id))
        #expect(b.store.node(b.card.id)?.isLocked == false)
        #expect(b.store.node(b.t1.id)?.isLocked == false)
        b.model.toggleLock(b.board.ref(b.t1.id))
        #expect(b.store.node(b.t1.id)?.isLocked == true)

        // Lock writes each thing's own flag.
        b.model.selection = b.board.thing(b.card.id)
        b.model.setSelectionLocked(true)
        #expect(b.store.node(b.card.id)?.isLocked == true)
        #expect(b.store.node(b.t2.id)?.isLocked == false)
    }

    @Test func hidingAContainerDropsWhatIsInItFromTheSelection() {
        let b = CardBoard()
        b.model.selection = CanvasSelection([b.board.thing(b.a.id), b.board.thing(b.t1.id), b.board.thing(b.t3.id)])

        b.model.toggleHidden(b.board.ref(b.row.id))
        #expect(b.store.node(b.row.id)?.isHidden == true)
        #expect(b.model.selection == CanvasSelection([b.board.thing(b.a.id), b.board.thing(b.t1.id)]))

        b.model.toggleHidden(b.board.ref(b.card.id))
        #expect(b.model.selection == b.board.thing(b.a.id))
        b.model.toggleHidden(b.board.ref(b.card.id))
        #expect(b.store.node(b.card.id)?.isHidden == false)
        #expect(b.model.selection == b.board.thing(b.a.id))
    }
}
