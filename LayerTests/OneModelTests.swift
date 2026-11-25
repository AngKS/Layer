import CoreGraphics
import Foundation
import Testing
@testable import Layer

// One model (plan 6, Task 11): the flat list, its views and the projection are gone. The store holds the tree itself, a
// file reads as the tree, a ref names a node, and Siri's undo and the store's own still go through the tree.

@Suite("One model")
@MainActor
struct OneModelTests {
    private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    @Test func theStoreHoldsTheTreeItself() {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store

        let held: TreeContent = store.content

        #expect(held == store.tree)
        #expect(held.screens.map(\.id) == [login.screen])
    }

    @Test func aFileReadsAsTheTree() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("One Model.layer")
        try login.model.document.current.wrapper().write(to: url, options: .atomic, originalContentsURL: nil)

        let read: TreeContent = try DesignFile.content(at: url)

        // The rules run on read, and the fixture was laid out by them already: what is read is what the store holds.
        #expect(read == store.tree)
    }

    @Test func aRefNamesANode() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let ref = NodeRef(host: .screen(login.screen), node: login.about)
        let onCanvas = NodeRef(host: .canvas, node: login.note)

        for ref in [ref, onCanvas] {
            let key = EntityKey.element(design: login.designID, host: ref.host, element: ref.node)
            let parsed = try #require(EntityKey.parseElement(key))
            #expect(parsed.design == login.designID)
            #expect(parsed.ref == ref)
        }
        #expect(login.model.store.ref(of: login.about) == ref)
        #expect(login.model.store.ref(of: login.note) == onCanvas)
    }

    @Test func siriUndoStillTakesBack() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model, store = model.store
        let siri = UndoManager()
        siri.groupsByEvent = false
        let before = store.tree
        let title = NodeRef(host: .screen(login.screen), node: login.title)

        try MoveElementIntent.move(title, in: model, x: 40, y: 90, width: nil, height: nil, undoManager: siri)
        #expect(store.ownFrame(login.title) == CGRect(x: 40, y: 90, width: 228, height: 40))
        #expect(store.tree != before)

        let taken = try #require(model.takenActions.last)
        #expect(taken.canTakeBack(from: store.content))
        taken.takeBack()

        #expect(store.tree == before)
    }

    @Test func undoAndRedoStillGoThroughTheTree() throws {
        var big = LayerNode(kind: .shape)
        big.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        var small = LayerNode(kind: .text)
        small.content.text = "Hello"
        small.frame = CGRect(x: 50, y: 25, width: 100, height: 50)
        var group = LayerNode(kind: .group)
        group.width = LayerNode.Sizing(.fit)
        group.height = LayerNode.Sizing(.fit)
        group.rotation = 30
        group.frame = CGRect(x: 100, y: 100, width: 200, height: 100)
        group.children = [big, small]
        var root = LayerNode(kind: .group)
        root.children = [group]
        var tree = TreeContent()
        tree.screens = [TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: nil, root: root)]
        TreeRules.apply(to: &tree, after: nil)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = DesignStore(content: tree)
        store.undoManager = undo
        let before = store.content
        let ref = NodeRef(host: .screen(tree.screens[0].id), node: group.id)

        func node(_ id: UUID, in tree: TreeContent) throws -> LayerNode {
            try #require(TreeIndex(tree).node(id, in: tree))
        }
        let groupBefore = try node(group.id, in: before).frame
        let box = try #require(store.canvasFrame(of: .element(ref)))

        store.position([CanvasSelection.element(ref): CGPoint(x: box.minX + 10, y: box.minY)])

        let after = store.content
        #expect(close(try node(group.id, in: after).frame, groupBefore.offsetBy(dx: 10, dy: 0)))
        #expect(try node(group.id, in: after).rotation == 30)
        #expect(close(try node(big.id, in: after).frame, try node(big.id, in: before).frame))
        #expect(close(try node(small.id, in: after).frame, try node(small.id, in: before).frame))

        undo.undo()
        #expect(store.content == before)
        #expect(close(try node(group.id, in: store.content).frame, groupBefore))

        undo.redo()
        #expect(store.content == after)
        #expect(close(try node(group.id, in: store.content).frame, try node(group.id, in: after).frame))
    }
}
