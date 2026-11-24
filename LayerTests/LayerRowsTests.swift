import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Layer

/// A store holding `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeStore(_ tree: TreeContent) -> DesignStore {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore(content: DesignContent(tree: tree))
    store.undoManager = undo
    return store
}

private func leaf(_ name: String, _ kind: ElementKind = .text, locked: Bool = false, hidden: Bool = false) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.name = name
    node.frame = CGRect(x: 10, y: 10, width: 80, height: 30)
    node.content.text = name
    node.isLocked = locked
    node.isHidden = hidden
    return node
}

private func container(_ layout: LayerNode.Layout?, kind: ElementKind = .group, named name: String? = nil, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.name = name
    node.layout = layout
    node.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    node.children = children
    return node
}

private func design(_ children: [LayerNode], root layout: LayerNode.Layout? = nil, canvas: [LayerNode] = []) -> (TreeContent, TreeScreen.ID) {
    var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
    screen.root.layout = layout
    screen.root.children = children
    var content = TreeContent()
    content.screens = [screen]
    content.canvas = canvas
    return (content, screen.id)
}

private func group(named name: String? = nil, _ children: [LayerNode]) -> LayerNode {
    container(nil, named: name, children)
}

private let column = LayerNode.Layout.stack(LayerNode.Stack(axis: .vertical, spacing: 8))
private let row = LayerNode.Layout.stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
private let grid = LayerNode.Layout.grid(LayerNode.Grid(columns: 2))
private let overlay = LayerNode.Layout.overlay(LayerNode.Alignment())

@MainActor
private func lines(_ store: DesignStore, _ host: TreeIndex.Host, open: Set<UUID>) -> [LayerLine] {
    LayerRows.lines(on: host, in: store.tree, index: store.index, open: open)
}

/// The Layers panel's rows, read from the tree (plan 4, Task 8).
@MainActor
@Suite("The rows of the Layers panel")
struct LayerRowsTests {
    @Test func aScreensRowsFollowTheTree() {
        let (a, b, c, d) = (leaf("A"), leaf("B"), leaf("C"), leaf("D"))
        let g = group(named: "G", [b, c])
        let (content, screen) = design([a, g, d])
        let store = makeStore(content)

        let rows = lines(store, .screen(screen), open: [g.id])

        #expect(rows.map(\.id) == [d.id, g.id, c.id, b.id, a.id])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 0])
        #expect(rows.map(\.isOpen) == [false, true, false, false, false])
        #expect(lines(store, .screen(screen), open: []).map(\.id) == [d.id, g.id, a.id], "a closed container hides what it holds")
        #expect(rows[2].list == .node(g.id) && rows[0].list == .screen(screen))
        #expect(rows[0].ref == DesignStore.ElementRef(host: .screen(screen), element: d.id))
    }

    @Test func aColumnsChildrenAreInLayoutOrder() {
        let (x, y, z) = (leaf("x"), leaf("y"), leaf("z"))
        let col = container(column, named: "Col", [x, y, z])
        let (content, screen) = design([col])
        let store = makeStore(content)

        let rows = lines(store, .screen(screen), open: [col.id])

        #expect(rows.map(\.id) == [col.id, x.id, y.id, z.id])
        #expect(rows.map(\.isLayoutOrder) == [false, true, true, true])
    }

    @Test func aScreenWhoseRootIsAColumnListsItsTopLevelInLayoutOrder() {
        let (x, y) = (leaf("x"), leaf("y"))
        let (content, screen) = design([x, y], root: column)
        let rows = lines(makeStore(content), .screen(screen), open: [])
        #expect(rows.map(\.id) == [x.id, y.id])
        #expect(rows.allSatisfy { $0.isLayoutOrder })
    }

    @Test func anOverlayListsTopmostFirst() {
        let (x, y) = (leaf("x"), leaf("y"))
        let over = container(overlay, [x, y])
        let (content, screen) = design([over])
        let rows = lines(makeStore(content), .screen(screen), open: [over.id])
        #expect(rows.map(\.id) == [over.id, y.id, x.id])
        #expect(rows.dropFirst().allSatisfy { !$0.isLayoutOrder })
    }

    @Test func containersShowTheirLayout() {
        let symbols: [(LayerNode, String)] = [
            (container(row, [leaf("a")]), "rectangle.split.3x1"),
            (container(column, [leaf("a")]), "rectangle.split.1x2"),
            (container(grid, [leaf("a")]), "square.grid.2x2"),
            (container(overlay, [leaf("a")]), "square.stack"),
            (container(nil, kind: .card, [leaf("a")]), ElementKind.card.symbol),
            (group([leaf("a")]), "rectangle.3.group"),
        ]
        for (node, symbol) in symbols {
            #expect(LayerRows.symbol(for: node) == symbol)
            #expect(UIImage(systemName: symbol) != nil, "\(symbol) is a symbol this system has")
        }
        var named = leaf("Star", .symbol)
        named.content.symbol = "star.fill"
        #expect(LayerRows.symbol(for: named) == SystemSymbol.resolve("star.fill"))
        #expect(LayerRows.symbol(for: leaf("T", .text)) == ElementKind.text.symbol)
    }

    @Test func containersAreListedByWhatTheyAre() {
        let nodes = [container(row, [leaf("a"), leaf("b")]), container(column, [leaf("a"), leaf("b")]), container(grid, [leaf("a"), leaf("b")]),
                     container(overlay, [leaf("a"), leaf("b")]), container(nil, kind: .card, [leaf("a"), leaf("b")]), group([leaf("a"), leaf("b")])]
        let (content, screen) = design(nodes)
        let rows = lines(makeStore(content), .screen(screen), open: [])
        #expect(rows.map(\.name) == ["Group", "Card", "Overlay", "Grid", "Column", "Row"])
    }

    // MARK: Dropping

    @MainActor
    private struct Board {
        let store: DesignStore
        let screen: TreeScreen.ID
        let b: LayerNode
        let col: LayerNode
        let x: LayerNode, y: LayerNode, z: LayerNode

        init() {
            (x, y, z) = (leaf("x"), leaf("y"), leaf("z"))
            b = leaf("B")
            col = container(column, named: "Col", [x, y, z])
            let (content, id) = design([b, col])
            screen = id
            store = makeStore(content)
        }

        var columnNames: [String] { store.node(col.id)?.children.compactMap(\.name) ?? [] }

        /// Drops B above `row` in the column's list, or below its last row for nil.
        @MainActor
        func dropB(above row: UUID?) {
            let list = LayerRows.lines(in: .node(col.id), content: store.tree, index: store.index)
            if row == nil {
                store.moveLayerToTop(b.id, of: .node(col.id))
            } else {
                store.moveLayer(b.id, to: .node(col.id), before: LayerRows.before(row, in: list, layoutOrder: true))
            }
        }
    }

    @Test func aRowDroppedInAColumnLandsWhereItWasDropped() {
        let middle = Board()
        middle.dropB(above: middle.y.id)
        #expect(middle.columnNames == ["x", "B", "y", "z"])

        let first = Board()
        first.dropB(above: first.x.id)
        #expect(first.columnNames == ["B", "x", "y", "z"])

        let last = Board()
        last.dropB(above: nil)
        #expect(last.columnNames == ["x", "y", "z", "B"])
    }

    @Test func theBeforeOfADropReadsTheListsOrder() {
        let board = Board()
        let list = LayerRows.lines(in: .node(board.col.id), content: board.store.tree, index: board.store.index)
        #expect(LayerRows.before(board.y.id, in: list, layoutOrder: true) == board.x.id)
        #expect(LayerRows.before(board.x.id, in: list, layoutOrder: true) == nil)
        #expect(LayerRows.before(nil, in: list, layoutOrder: true) == nil)
        #expect(LayerRows.before(board.y.id, in: list, layoutOrder: false) == board.y.id)
    }

    @Test func theRefusalsAreTodays() {
        let locked = leaf("Locked", locked: true)
        let held = group(named: "Held", [leaf("h1"), leaf("h2")])
        let target = group(named: "Target", [leaf("t1")])
        let free = leaf("Free")
        var other = TreeScreen(name: "Other", origin: CGPoint(x: 500, y: 0), scale: 1, deviceID: nil)
        other.root.children = [leaf("o1")]
        var drawing = LayerNode(kind: .drawing)
        drawing.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        var (content, screen) = design([locked, held, target, free], canvas: [drawing])
        content.screens.append(other)
        let store = makeStore(content)
        let before = store.tree

        #expect(!store.moveLayer(locked.id, to: .node(target.id), before: nil), "a locked thing stays")
        #expect(!store.moveLayer(free.id, to: .screen(other.id), before: nil), "another screen's list is refused")
        #expect(!store.moveLayer(held.id, to: .node(held.id), before: nil), "a container into itself")
        #expect(!store.moveLayer(drawing.id, to: .screen(screen), before: nil), "a drawing keeps its place")
        #expect(store.tree == before)
    }

    @Test func lockAndHideComeFromAncestors() {
        let child = leaf("child")
        let lockedCard = container(nil, kind: .card, named: "Locked card", [child])
        var locked = lockedCard
        locked.isLocked = true
        let inner = leaf("inner")
        var hiddenRow = container(row, named: "Hidden row", [inner])
        hiddenRow.isHidden = true
        let (content, screen) = design([locked, hiddenRow])
        let rows = lines(makeStore(content), .screen(screen), open: [locked.id, hiddenRow.id])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        let card = byID[locked.id], held = byID[child.id]
        #expect(card?.isLocked == true && card?.isLockedByAncestor == false)
        #expect(held?.isLockedByAncestor == true && held?.isLocked == false)
        #expect(held?.isDimmed == false)
        let hidden = byID[hiddenRow.id], inside = byID[inner.id]
        #expect(hidden?.isHidden == true && hidden?.isDimmed == true)
        #expect(inside?.isDimmed == true && inside?.isHidden == false)
    }

    @Test func theDrawingsSectionListsTheCanvasesDrawingsTopmostFirst() {
        var (d1, d2) = (LayerNode(kind: .drawing), LayerNode(kind: .drawing))
        (d1.frame, d2.frame) = (CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 0, width: 10, height: 10))
        let note = leaf("note", .stickyNote)
        let (content, _) = design([leaf("A")], canvas: [d1, note, d2])
        let store = makeStore(content)

        #expect(LayerRows.drawings(in: store.tree) == [d2.id, d1.id])
        #expect(lines(store, .canvas, open: []).map(\.id) == [note.id], "drawings are left out of the rows")
    }

    @Test func listingDoesNotLower() throws {
        let (a, b) = (leaf("A"), leaf("B"))
        let g = group(named: "G", [a, b])
        let (content, screen) = design([g])
        let store = makeStore(content)
        let open: Set<UUID> = [g.id]

        // The counter is live: a read of the projection after a change lowers it once.
        store.update(a.id) { $0.name = "A2" }
        var lowered = TreeProjection.lowerings(of: screen)
        _ = store.screens
        #expect(TreeProjection.lowerings(of: screen) == lowered + 1)

        store.update(a.id) { $0.name = "A3" }
        lowered = TreeProjection.lowerings(of: screen)
        let rows = lines(store, .screen(screen), open: open)
        _ = LayerRows.drawings(in: store.tree)
        _ = LayerRows.lines(in: .node(g.id), content: store.tree, index: store.index)
        #expect(rows.map(\.name) == ["G", "B", "A3"])
        #expect(TreeProjection.lowerings(of: screen) == lowered, "listing reads the tree and its index")
    }
}
