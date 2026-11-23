import CoreGraphics
import Foundation
import Testing
@testable import Layer

@MainActor
private func makeStore(_ content: DesignContent = DesignContent()) -> (store: DesignStore, undo: UndoManager) {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore(content: content)
    store.undoManager = undo
    return (store, undo)
}

private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.000_001) -> Bool {
    abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance
        && abs(a.height - b.height) < tolerance
}

private func button(_ frame: CGRect = CGRect(x: 20, y: 100, width: 200, height: 50)) -> DesignElement {
    DesignElement(kind: .button, frame: frame, text: "Go", tint: Theme.accent)
}

/// The store keeps the design as a tree: its rules run inside every change, undo and redo, and
/// what hasn't moved onto the tree yet reads and writes it through the projection (plan 2, Task 7).
@Suite("The store on the tree")
@MainActor
struct StoreOnTheTreeTests {
    @Test func theStoreHoldsTheTree() throws {
        let (store, _) = makeStore()
        let screen = store.addScreen(from: CGRect(x: 0, y: 0, width: 393, height: 852))
        let centre = CGPoint(x: screen.canvasFrame.midX, y: screen.canvasFrame.midY)
        store.place(DesignStore.newElement(.button), centeredAt: centre)

        let root = try #require(store.content.tree.screens.first?.root)
        #expect(root.children.map(\.kind) == [.button])
    }

    /// A group and the one member pointed at it, made in one change: the rules at its end
    /// dissolve the group, so the member is on the screen's root, and the change is one step.
    @Test func aGroupOfOneMadeInAChangeIsGoneByItsEnd() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        undo.removeAllActions()
        let item = DesignStore.newElement(.group)
        let member = button()

        store.apply { content in
            content.add(item, to: screen.id)
            content.add(member, to: screen.id)
            content.update(member.id) { $0.group = item.id }
        }

        let root = try #require(store.content.tree.screens.first?.root)
        #expect(root.children.map(\.id) == [member.id])
        #expect(root.children.first?.frame == member.frame)
        #expect(store.element(item.id) == nil)
        #expect(undo.canUndo)
        undo.undo()
        #expect(store.content.tree.screens.first?.root.children.isEmpty == true)
        #expect(!undo.canUndo)
    }

    /// A pointer to a group that never comes waits while the change is made, and is cut when it ends.
    @Test func pendingPointersEndWithTheChange() throws {
        let (store, _) = makeStore()
        let screen = store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let ghost = UUID()
        var member = button()
        member.group = ghost
        var waiting: [UUID: UUID] = [:]

        store.apply { content in
            content.add(member, to: screen.id)
            waiting = content.pendingPointers
        }

        #expect(waiting == [member.id: ghost])
        let root = try #require(store.content.tree.screens.first?.root)
        #expect(root.children.map(\.id) == [member.id])
        #expect(store.content.pendingPointers.isEmpty)
        #expect(store.element(member.id)?.group == nil)
    }

    #if DEBUG
    /// A leaf moved on one free screen lays out that screen's root once, and the other screen's not at all (F8).
    @Test func aLeafEditLaysOutOnlyItsScreen() throws {
        let (store, _) = makeStore()
        let a = store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let b = store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 600, y: 0), scale: 1))
        let onA = store.setElements([button()], on: a.id, replacing: false)
        _ = store.setElements([button()], on: b.id, replacing: false)
        let roots = store.content.tree.screens.map(\.root.id)
        let before = roots.map(LayoutEngine.timesLaidOut)

        store.update(onA[0]) { $0.frame.origin.x += 10 }

        let laid = zip(roots.map(LayoutEngine.timesLaidOut), before).map(-)
        #expect(laid == [1, 0])
    }

    /// Reading the screens, the open canvas and an element ten times each lowers the tree once (F8).
    @Test func theProjectionIsLoweredOncePerVersion() throws {
        let (store, _) = makeStore()
        let screen = store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let refs = store.setElements([button()], on: screen.id, replacing: false)
        store.addFloating(DesignStore.newElement(.stickyNote), scale: 1)
        store.update(refs[0]) { $0.text = "Changed" }
        let before = TreeProjection.lowerings

        for _ in 0..<10 {
            _ = store.screens
            _ = store.floating
            _ = store.element(refs[0].element)
        }

        #expect(TreeProjection.lowerings - before == 1)
    }
    #endif

    /// A free group turned 30, moved with `position`, comes back through undo and goes again
    /// through redo, and its leaves stay where they are in it throughout (F24).
    ///
    /// `position` puts each leaf on whole screen points, and the group's box is fitted round its
    /// leaves out to whole points of its own. So the group is placed where the whole points its
    /// leaves land on, asked to move 10 points right, are a whole-point move in its own turned
    /// space, (9, -5): its leaves, both centred on its middle, then sit exactly where they were in it.
    @Test func undoAndRedoGoThroughTheTree() throws {
        let turn = 30.0 * .pi / 180
        let landed = CGVector(dx: 9 * cos(turn) + 5 * sin(turn), dy: 9 * sin(turn) - 5 * cos(turn))
        var big = LayerNode(kind: .shape)
        big.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        var small = LayerNode(kind: .text)
        small.content.text = "Hello"
        small.frame = CGRect(x: 50, y: 25, width: 100, height: 50)
        var group = LayerNode(kind: .group)
        group.width = LayerNode.Sizing(.fit)
        group.height = LayerNode.Sizing(.fit)
        group.rotation = 30
        group.frame = CGRect(x: 110 - landed.dx, y: 100 - landed.dy, width: 200, height: 100)
        group.children = [big, small]
        var root = LayerNode(kind: .group)
        root.children = [group]
        var tree = TreeContent()
        tree.screens = [TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: nil, root: root)]
        TreeRules.apply(to: &tree, after: nil)
        let (store, undo) = makeStore(DesignContent(tree: tree))
        let before = store.content.tree
        let ref = DesignStore.ElementRef(host: .screen(tree.screens[0].id), element: group.id)

        func node(_ id: UUID, in tree: TreeContent) throws -> LayerNode {
            try #require(TreeIndex(tree).node(id, in: tree))
        }
        func expectLeavesWhereTheyWere(in tree: TreeContent) throws {
            #expect(try node(group.id, in: tree).children.map(\.id) == [big.id, small.id])
            #expect(close(try node(big.id, in: tree).frame, try node(big.id, in: before).frame))
            #expect(close(try node(small.id, in: tree).frame, try node(small.id, in: before).frame))
        }
        let groupBefore = try node(group.id, in: before).frame
        let box = try #require(store.canvasFrame(of: .element(ref)))

        store.position([CanvasSelection.element(ref): CGPoint(x: box.minX + 10, y: box.minY)])

        let after = store.content.tree
        let groupAfter = try node(group.id, in: after).frame
        #expect(close(groupAfter, groupBefore.offsetBy(dx: landed.dx, dy: landed.dy)))
        #expect(try node(group.id, in: after).rotation == 30)
        try expectLeavesWhereTheyWere(in: after)

        undo.undo()
        #expect(store.content.tree.screens[0].root.children.map(\.id) == [group.id])
        #expect(close(try node(group.id, in: store.content.tree).frame, groupBefore))
        try expectLeavesWhereTheyWere(in: store.content.tree)

        undo.redo()
        #expect(close(try node(group.id, in: store.content.tree).frame, groupAfter))
        try expectLeavesWhereTheyWere(in: store.content.tree)
    }
}
