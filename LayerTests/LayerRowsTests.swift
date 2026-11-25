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
    let store = DesignStore(content: tree)
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

        /// Drops B above `row` in the column's list, or below its last row for nil, through the panel's own drop.
        @MainActor
        func dropB(above row: UUID?) {
            LayerRows.drop([b.id], in: .node(col.id), above: row, layoutOrder: true, store: store)
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

    /// Listing reads the tree and its index (F26). The check that it lowered nothing went with the flat list (plan 6,
    /// Task 11, clause (s)).
    @Test func listingReadsTheTree() throws {
        let (a, b) = (leaf("A"), leaf("B"))
        let g = group(named: "G", [a, b])
        let (content, screen) = design([g])
        let store = makeStore(content)
        let open: Set<UUID> = [g.id]

        store.update(a.id) { $0.name = "A3" }
        let rows = lines(store, .screen(screen), open: open)
        _ = LayerRows.drawings(in: store.tree)
        _ = LayerRows.lines(in: .node(g.id), content: store.tree, index: store.index)
        #expect(rows.map(\.name) == ["G", "B", "A3"])
    }

    // MARK: Several rows at once

    /// A column [x, y, z] and a free group [p, q, r] (shown r, q, p), with B and C loose beside them.
    @MainActor
    private struct Several {
        let store: DesignStore
        let b = leaf("B"), c = leaf("C")
        let x = leaf("x"), y = leaf("y"), z = leaf("z")
        let p = leaf("p"), q = leaf("q"), r = leaf("r")
        let col: LayerNode, free: LayerNode

        init() {
            col = container(column, named: "Col", [x, y, z])
            free = group(named: "Free", [p, q, r])
            store = makeStore(design([b, c, col, free]).0)
        }

        func names(_ container: LayerNode) -> [String] { store.node(container.id)?.children.compactMap(\.name) ?? [] }

        func drop(_ ids: [LayerNode], into container: LayerNode, above row: LayerNode?, layoutOrder: Bool) {
            LayerRows.drop(ids.map(\.id), in: .node(container.id), above: row?.id, layoutOrder: layoutOrder, store: store)
        }
    }

    @Test func twoRowsDroppedMidListKeepTheirOrder() {
        let column = Several()
        column.drop([column.b, column.c], into: column.col, above: column.y, layoutOrder: true)
        #expect(column.names(column.col) == ["x", "B", "C", "y", "z"])

        let free = Several()
        // Shown r, B, C, q, p: above q.
        free.drop([free.b, free.c], into: free.free, above: free.q, layoutOrder: false)
        #expect(free.names(free.free) == ["p", "q", "C", "B", "r"])
    }

    @Test func twoRowsDroppedAtTheTopKeepTheirOrder() {
        let column = Several()
        column.drop([column.b, column.c], into: column.col, above: column.x, layoutOrder: true)
        #expect(column.names(column.col) == ["B", "C", "x", "y", "z"])

        let free = Several()
        free.drop([free.b, free.c], into: free.free, above: free.r, layoutOrder: false)
        #expect(free.names(free.free) == ["p", "q", "r", "C", "B"])
    }

    @Test func twoRowsDroppedWhereTheRowAboveOrBelowIsOneOfThemAreNotRefused() {
        // Above z, with y (the row above z) dragged too.
        let column = Several()
        column.drop([column.x, column.y], into: column.col, above: column.z, layoutOrder: true)
        #expect(column.names(column.col) == ["x", "y", "z"])
        let reversed = Several()
        reversed.drop([reversed.y, reversed.x], into: reversed.col, above: reversed.z, layoutOrder: true)
        #expect(reversed.names(reversed.col) == ["y", "x", "z"], "they land in the order given")

        // Above a row that is dragged: it is taken as the next row that stays.
        let onOne = Several()
        onOne.drop([onOne.x, onOne.z], into: onOne.col, above: onOne.x, layoutOrder: true)
        #expect(onOne.names(onOne.col) == ["x", "z", "y"])

        // Free group, shown r, q, p: q and r dragged, dropped above q, taken as above p.
        let free = Several()
        free.drop([free.r, free.q], into: free.free, above: free.q, layoutOrder: false)
        #expect(free.names(free.free) == ["p", "q", "r"], "r above q, as dragged, above p")
    }

    @Test func twoRowsDroppedBelowTheLastRowKeepTheirOrder() {
        let column = Several()
        column.drop([column.b, column.c], into: column.col, above: nil, layoutOrder: true)
        #expect(column.names(column.col) == ["x", "y", "z", "B", "C"])

        let free = Several()
        // Shown r, q, p, B, C.
        free.drop([free.b, free.c], into: free.free, above: nil, layoutOrder: false)
        #expect(free.names(free.free) == ["C", "B", "p", "q", "r"])
    }
}
