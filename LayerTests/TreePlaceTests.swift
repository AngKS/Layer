import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

/// A store holding `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeStore(_ tree: TreeContent) -> (store: DesignStore, undo: UndoManager) {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore(content: DesignContent(tree: tree))
    store.undoManager = undo
    return (store, undo)
}

/// A text of a fixed size.
private func leaf(_ width: CGFloat, _ height: CGFloat = 20, at origin: CGPoint = .zero) -> LayerNode {
    var node = LayerNode(kind: .text)
    node.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
    node.content.text = "Text"
    return node
}

/// A container sized to fit on both axes.
private func container(_ layout: LayerNode.Layout?, at origin: CGPoint = .zero, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: .group)
    node.layout = layout
    node.frame = CGRect(origin: origin, size: .zero)
    node.width = LayerNode.Sizing(.fit)
    node.height = LayerNode.Sizing(.fit)
    node.children = children
    return node
}

/// An iPhone screen with a free root, at `origin` on the canvas, drawn at `scale`.
private func screen(_ children: [LayerNode], at origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeScreen {
    var screen = TreeScreen(name: "Screen", origin: origin, scale: scale, deviceID: nil)
    screen.root.children = children
    return screen
}

private func design(_ screens: [TreeScreen], canvas: [LayerNode] = []) -> TreeContent {
    var content = TreeContent()
    content.screens = screens
    content.canvas = canvas
    return content
}

private func row(spacing: CGFloat = 8) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .horizontal, spacing: spacing))
}

private func isNear(_ a: CGPoint, _ b: CGPoint, within tolerance: CGFloat) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

/// Order, hosts, moving, resizing and turning on the tree: a row or another laid-out container
/// moves, lands, resizes and turns as one piece, its children laid out in it, and the order of a
/// parent's children is written with each drawing keeping its index (plan 2, Task 11).
@Suite("Order, hosts and moves on the tree")
@MainActor
struct TreePlaceTests {
    #if DEBUG
    @Test func aRowDraggedMovesWhole() throws {
        let r = container(row(), at: CGPoint(x: 20, y: 100), [leaf(60), leaf(50), leaf(70)])
        let (store, _) = makeStore(design([screen([r])]))
        let screenID = try #require(store.tree.screens.first?.id)
        let ref = DesignStore.ElementRef(host: .screen(screenID), element: r.id)
        let before = try #require(store.node(r.id))
        let box = try #require(store.canvasFrame(of: .element(ref)))

        let start = ListWork.elementsWritten
        store.position([.element(ref): CGPoint(x: box.minX + 30, y: box.minY + 40)])
        let written = ListWork.elementsWritten - start

        #expect(written == 1, "the row is written alone, once: \(written)")
        let after = try #require(store.node(r.id))
        #expect(store.parent(of: r.id) == .screen(screenID))
        #expect(after.layout == row())
        #expect(after.frame == before.frame.offsetBy(dx: 30, dy: 40))
        #expect(after.children.map(\.id) == before.children.map(\.id))
        #expect(after.children.map(\.frame) == before.children.map(\.frame), "its children ride along, laid out as they were")
    }
    #endif

    @Test func bringForwardIsOffInARowButOnInAnOverlay() throws {
        let (a, b, c) = (leaf(60), leaf(50), leaf(70))
        let r = container(row(), at: CGPoint(x: 20, y: 100), [a, b, c])
        let (p, q) = (leaf(80, 40), leaf(40, 20))
        let o = container(.overlay(LayerNode.Alignment()), at: CGPoint(x: 20, y: 300), [p, q])
        let (store, _) = makeStore(design([screen([r, o])]))
        let screenID = try #require(store.tree.screens.first?.id)
        func ref(_ node: LayerNode) -> DesignStore.ElementRef { .init(host: .screen(screenID), element: node.id) }

        // A row's children have one order, the row's own: the layout's, never stepped through by hand (My call 15).
        for arrangement in DesignStore.Arrangement.allCases {
            #expect(!store.canArrange(ref(b), arrangement))
        }
        store.arrange(.element(ref(b)), .forward)
        #expect(store.node(r.id)?.children.map(\.id) == [a.id, b.id, c.id])

        // An overlay's children are stacked, so they are arranged as a free container's are.
        #expect(store.canArrange(ref(p), .forward))
        #expect(!store.canArrange(ref(q), .forward))
        store.arrange(.element(ref(p)), .forward)
        #expect(store.node(o.id)?.children.map(\.id) == [q.id, p.id])

        // The row itself is one thing among the root's children.
        #expect(store.canArrange(ref(r), .front))
        store.arrange(.element(ref(r)), .front)
        #expect(store.tree.screens.first?.root.children.map(\.id) == [o.id, r.id])
    }

    @Test func aRowResizedBecomesFixedAndReLaysItsChildren() throws {
        let r = container(row(), at: CGPoint(x: 20, y: 100), [leaf(60), leaf(50), leaf(70)])
        let (store, undo) = makeStore(design([screen([r])]))
        let screenID = try #require(store.tree.screens.first?.id)
        let ref = DesignStore.ElementRef(host: .screen(screenID), element: r.id)
        let before = try #require(store.node(r.id))
        #expect(before.frame.size == CGSize(width: 196, height: 20))

        store.resizeGroup(ref, to: CGRect(x: before.frame.minX, y: before.frame.minY, width: 300, height: before.frame.height))

        let after = try #require(store.node(r.id))
        #expect(store.parent(of: r.id) == .screen(screenID))
        #expect(after.layout == row())
        #expect(after.width.mode == .fixed)
        #expect(after.height.mode == .fit, "only the width was changed")
        #expect(after.frame == CGRect(x: before.frame.minX, y: before.frame.minY, width: 300, height: 20))
        #expect(after.children.map(\.id) == before.children.map(\.id))
        #expect(after.children.map(\.frame.size) == before.children.map(\.frame.size), "its children aren't scaled")
        for child in after.children {
            #expect(child.frame.minX >= 0 && child.frame.maxX <= 300, "\(child.frame) lies within the row")
        }
        #expect(after.children.first?.frame.minX == 0)
        for (left, right) in zip(after.children, after.children.dropFirst()) {
            #expect(right.frame.minX == left.frame.maxX + 8, "laid out along the row, 8 apart")
        }

        undo.undo()
        #expect(store.node(r.id) == before)
    }

    @Test func aGroupHoldingARowResizesTheRowAsOnePiece() throws {
        let (a, b) = (leaf(60), leaf(50))
        let r = container(row(), [a, b])
        let t = leaf(100, at: CGPoint(x: 0, y: 40))
        let g = container(nil, at: CGPoint(x: 20, y: 100), [r, t])
        let (store, _) = makeStore(design([screen([g])]))
        let screenID = try #require(store.tree.screens.first?.id)
        let ref = DesignStore.ElementRef(host: .screen(screenID), element: g.id)
        let rowBefore = try #require(store.node(r.id))
        #expect(rowBefore.frame.size == CGSize(width: 118, height: 20))
        let box = try #require(store.groupPose(of: ref)).box
        #expect(box.size == CGSize(width: 118, height: 60))

        store.resizeGroup(ref, to: CGRect(x: box.minX, y: box.minY, width: box.width * 2, height: box.height * 2))

        let rowAfter = try #require(store.node(r.id))
        #expect(rowAfter.layout == row())
        #expect(rowAfter.children.map(\.id) == [a.id, b.id], "the row keeps its children")
        #expect(store.parent(of: r.id) == .node(g.id))
        #expect(store.parent(of: a.id) == .node(r.id) && store.parent(of: b.id) == .node(r.id))
        // Scaled as one piece, about the box, and fixed at its new size; what is in it is laid out again.
        #expect(rowAfter.frame.size == CGSize(width: 236, height: 40))
        #expect(rowAfter.width.mode == .fixed && rowAfter.height.mode == .fixed)
        #expect(rowAfter.children.map(\.frame.size) == rowBefore.children.map(\.frame.size))
        try #require(rowAfter.children.count == 2)
        #expect(rowAfter.children[1].frame.minX == rowAfter.children[0].frame.maxX + 8)
        #expect(store.node(t.id)?.frame.size == CGSize(width: 200, height: 40))
    }

    @Test func aRowTurnedAloneSetsOnlyItsAngle() throws {
        let model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        let r = container(row(), at: CGPoint(x: 20, y: 100), [leaf(60), leaf(50), leaf(70)])
        let added = try #require(model.store.addScreen(screen([r])))
        let ref = DesignStore.ElementRef(host: .screen(added), element: r.id)
        model.selection = .element(ref)
        let before = try #require(model.store.node(r.id))

        #expect(model.beginTurn())
        model.turnSelection(by: 30, snaps: false)
        model.endTurn()

        let after = try #require(model.store.node(r.id))
        #expect(after.rotation == 30)
        #expect(after.layout == row())
        #expect(after.frame == before.frame, "turned about its own middle")
        #expect(after.children.map(\.id) == before.children.map(\.id))
        #expect(after.children.map(\.frame) == before.children.map(\.frame), "its children go round with it, laid out as they were")
        #expect(after.children.allSatisfy { $0.rotation == nil })
    }

    @Test func aRowDroppedOnAnotherScreenGoesWhole() throws {
        let things = [leaf(60), leaf(50), leaf(70)]
        // Past the first screen's right edge, over the second, which is drawn at half size.
        let r = container(row(), at: CGPoint(x: 500, y: 100), things)
        let first = screen([r])
        let second = screen([], at: CGPoint(x: 480, y: 0), scale: 0.5)
        let (store, undo) = makeStore(design([first, second]))
        let ref = DesignStore.ElementRef(host: .screen(first.id), element: r.id)
        let before = try #require(store.node(r.id))
        let shape = try #require(store.canvasFrame(of: .element(ref)))

        let landed = store.rehost(ref)

        #expect(landed == DesignStore.ElementRef(host: .screen(second.id), element: r.id))
        #expect(store.parent(of: r.id) == .screen(second.id))
        #expect(store.tree.screens.first?.root.children.isEmpty == true)
        let after = try #require(store.node(r.id))
        #expect(after.layout == row())
        #expect(after.children.map(\.id) == things.map(\.id), "every id is as it was")
        #expect(after.children.map(\.frame) == before.children.map(\.frame), "what is in it lands whole")
        #expect(after.frame.size == before.frame.size, "its size in its own points")
        let now = try #require(store.canvasFrame(of: .element(landed)))
        #expect(isNear(CGPoint(x: now.midX, y: now.midY), CGPoint(x: shape.midX, y: shape.midY), within: 0.5),
                "its middle stays where it was dropped")

        undo.undo()
        #expect(store.parent(of: r.id) == .screen(first.id))
        #expect(store.node(r.id) == before)
    }

    @Test func aDrawingKeepsItsIndexAmongTheCanvasNodes() throws {
        func drawing(at x: CGFloat) throws -> LayerNode {
            try #require(LayerNode.drawing([OrderBoard.stroke(from: CGPoint(x: x, y: 0), to: CGPoint(x: x + 40, y: 40))]))
        }
        func note(at x: CGFloat) -> LayerNode {
            var node = LayerNode(kind: .stickyNote)
            node.frame = CGRect(x: x, y: 100, width: 140, height: 130)
            node.scale = 1
            return node
        }
        let first = try drawing(at: 0), second = try drawing(at: 100)
        let a = note(at: 0), b = note(at: 200)
        let nodes = [first, a, second, b]

        // The notes swapped, each drawing where it was.
        #expect(TreeEdit.reordered(nodes, to: [b.id, a.id]).map(\.id) == [first.id, b.id, second.id, a.id])
        // An order that doesn't hold exactly what is there, the drawings aside, changes nothing.
        #expect(TreeEdit.reordered(nodes, to: [b.id]).map(\.id) == nodes.map(\.id))
        #expect(TreeEdit.reordered(nodes, to: [b.id, a.id, first.id]).map(\.id) == nodes.map(\.id))

        // Arranged on the open canvas: a screen's things are no part of it, and the drawings keep their places.
        let onScreen = leaf(100, at: CGPoint(x: 20, y: 20))
        let (store, _) = makeStore(design([screen([onScreen], at: CGPoint(x: 1000, y: 0))], canvas: nodes))
        store.arrange(.element(.init(host: .canvas, element: a.id)), .front)
        #expect(store.tree.canvas.map(\.id) == [first.id, b.id, second.id, a.id])
        #expect(store.tree.screens.first?.root.children.map(\.id) == [onScreen.id])
    }

    // MARK: Beyond the brief's seven

    /// The Layers panel's move out of a group on the open canvas: the group left with one note
    /// dissolves into its slot, the note lands at the back, and the drawing keeps its index.
    @Test func aLayerMovedOutOfAGroupOnTheCanvasLeavesTheDrawingWhereItIs() throws {
        let drawing = try #require(LayerNode.drawing([OrderBoard.stroke(from: CGPoint(x: 0, y: 300), to: CGPoint(x: 40, y: 340))]))
        func note(at x: CGFloat) -> LayerNode {
            var node = LayerNode(kind: .stickyNote)
            node.frame = CGRect(x: x, y: 100, width: 140, height: 130)
            return node
        }
        var first = note(at: 0)
        first.scale = 1
        let (second, third) = (note(at: 0), note(at: 200))
        var g = container(nil, at: CGPoint(x: 300, y: 0), [second, third])
        g.scale = 1
        let (store, undo) = makeStore(design([], canvas: [first, drawing, g]))
        let before = store.content

        #expect(store.moveLayer(second.id, to: .host(.canvas), before: nil))

        #expect(store.tree.canvas.map(\.id) == [second.id, drawing.id, first.id, third.id])
        #expect(store.node(g.id) == nil)
        undo.undo()
        #expect(store.content == before)
    }

    /// A container in a turned group moves across the canvas as far as it is asked, its distance
    /// turned into the group's axes.
    @Test func aContainerInATurnedGroupMovesAsFarAsAsked() throws {
        let inner = container(nil, [leaf(60), leaf(50, at: CGPoint(x: 0, y: 40))])
        var outer = container(nil, at: CGPoint(x: 100, y: 200), [inner, leaf(80, at: CGPoint(x: 100, y: 0))])
        outer.rotation = 90
        let (store, _) = makeStore(design([screen([outer])]))
        let screenID = try #require(store.tree.screens.first?.id)
        let ref = DesignStore.ElementRef(host: .screen(screenID), element: inner.id)
        let box = try #require(store.canvasFrame(of: .element(ref)))
        let children = try #require(store.node(inner.id)).children

        store.position([.element(ref): CGPoint(x: box.minX + 30, y: box.minY + 10)])

        let now = try #require(store.canvasFrame(of: .element(ref)))
        #expect(isNear(CGPoint(x: now.midX, y: now.midY), CGPoint(x: box.midX + 30, y: box.midY + 10), within: 1))
        #expect(store.node(inner.id)?.children == children, "what is in it rides along")
    }

    /// Siri's Move Element, on the screen it is on, moves a container by its own frame, and what
    /// is in it goes with it.
    @Test func aContainerMovedOnItsOwnScreenGoesWhole() throws {
        let g = container(nil, at: CGPoint(x: 20, y: 100), [leaf(60), leaf(50, at: CGPoint(x: 80, y: 0))])
        let (store, _) = makeStore(design([screen([g])]))
        let screenID = try #require(store.tree.screens.first?.id)
        let ref = DesignStore.ElementRef(host: .screen(screenID), element: g.id)
        let before = try #require(store.node(g.id))

        #expect(store.move(ref, toScreen: screenID, origin: CGPoint(x: 40, y: 300)) == ref)

        let after = try #require(store.node(g.id))
        #expect(after.frame.origin == CGPoint(x: 40, y: 300))
        #expect(after.children == before.children)
    }

    /// A row in a group turned with it is one rigid part: it goes round with the group, and what
    /// is in it stays in it, laid out as it was.
    @Test func aRowInAGroupTurnedWithItStaysWhole() throws {
        let model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        let r = container(row(), [leaf(60), leaf(50)])
        let g = container(nil, at: CGPoint(x: 20, y: 100), [r, leaf(100, at: CGPoint(x: 0, y: 40))])
        let added = try #require(model.store.addScreen(screen([g])))
        model.selection = .element(DesignStore.ElementRef(host: .screen(added), element: g.id))
        let row = try #require(model.store.node(r.id))

        #expect(model.beginTurn())
        model.turnSelection(by: 30, snaps: false)
        model.endTurn()

        let turned = try #require(model.store.node(r.id))
        #expect(model.store.parent(of: r.id) == .node(g.id))
        #expect(turned.layout == row.layout)
        #expect(turned.children.map(\.id) == row.children.map(\.id))
        #expect(turned.children.map(\.frame) == row.children.map(\.frame))
        #expect(model.store.node(g.id)?.rotation == 30)
    }

    /// The rotation field's angle for a row alone turns it about its own middle, as one rigid part:
    /// its frame stays, and what is in it goes round with it, laid out as it was.
    @Test func aRowGivenAnAngleInTheRotationFieldTurnsWhole() throws {
        let model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        let r = container(row(), at: CGPoint(x: 20, y: 100), [leaf(60), leaf(50), leaf(70)])
        let added = try #require(model.store.addScreen(screen([r])))
        let before = try #require(model.store.node(r.id))

        model.setAngle(of: [DesignStore.ElementRef(host: .screen(added), element: r.id)], to: 30)

        let after = try #require(model.store.node(r.id))
        #expect(after.rotation == 30)
        #expect(after.layout == row())
        #expect(after.frame == before.frame)
        #expect(after.children.map(\.frame) == before.children.map(\.frame))
        #expect(model.store.parent(of: r.id) == .screen(added))
    }

    /// The rotation field's angle for a group holding a row turns the group as one piece: the
    /// row, a rigid part of it, stays in it, laid out as it was.
    @Test func aGroupHoldingARowGivenAnAngleInTheRotationFieldKeepsTheRowInIt() throws {
        let model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        let r = container(row(), [leaf(60), leaf(50)])
        let g = container(nil, at: CGPoint(x: 20, y: 100), [r, leaf(100, at: CGPoint(x: 0, y: 40))])
        let added = try #require(model.store.addScreen(screen([g])))
        let row = try #require(model.store.node(r.id))

        model.setAngle(of: [DesignStore.ElementRef(host: .screen(added), element: g.id)], to: 90)

        let turned = try #require(model.store.node(r.id))
        #expect(model.store.parent(of: r.id) == .node(g.id))
        #expect(turned.layout == row.layout)
        #expect(turned.children.map(\.frame) == row.children.map(\.frame))
        #expect(model.store.node(g.id)?.rotation == 90)
    }
}
