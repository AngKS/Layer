import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// A store holding `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeStore(_ tree: TreeContent) -> (store: DesignStore, undo: UndoManager) {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore(content: tree)
    store.undoManager = undo
    return (store, undo)
}

private func leaf(_ frame: CGRect, text: String) -> LayerNode {
    var node = LayerNode(kind: .text)
    node.frame = frame
    node.content.text = text
    return node
}

/// A free group sized to fit on both axes, as the rules keep one: its box is round what it holds.
private func group(_ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: .group)
    node.width = LayerNode.Sizing(.fit)
    node.height = LayerNode.Sizing(.fit)
    node.children = children
    return node
}

/// One free iPhone screen holding `children`, drawn at `origin` and `scale`.
private func design(_ children: [LayerNode], origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeContent {
    var screen = TreeScreen(name: "Screen", origin: origin, scale: scale, deviceID: nil)
    screen.root.children = children
    var content = TreeContent()
    content.screens = [screen]
    return content
}

/// Undo among other edits, on the tree: each step takes back only what it changed itself. A
/// free group fitted again round what it holds gives the rest of what it holds new numbers in
/// its space without moving any of it, which is no change of theirs; and a container another
/// edit made going away leaves what was put in it on its screen (plan 2's final review).
@Suite("Undo among other edits on the tree")
@MainActor
struct UndoAmongEditsTests {
    /// Where a node is on its host, in the host's points.
    private func place(of id: UUID, in store: DesignStore) -> CGRect? {
        store.index[id]?.hostShape.rect
    }

    /// The app makes group K round X while X is put into K by hand; the app's step goes on
    /// after. Undone, both steps give back the design they started from, X on its screen
    /// throughout, never on the canvas.
    @Test func aNodePutInAGroupTheAppMadeStaysOnItsScreenWhenBothAreUndone() throws {
        let x = leaf(CGRect(x: 40, y: 300, width: 60, height: 40), text: "X")
        let (store, undo) = makeStore(design([x], origin: CGPoint(x: 400, y: 0), scale: 0.5))
        let start = store.tree
        let screenID = try #require(start.screens.first?.id)
        let y1 = leaf(CGRect(x: 20, y: 250, width: 30, height: 30), text: "Y1")
        let y2 = leaf(CGRect(x: 150, y: 400, width: 30, height: 30), text: "Y2")
        let k = group([y1, y2])

        let app = store.beginEdit(by: .app)
        store.act(for: app) { #expect(store.add(k, to: .screen(screenID))) }
        #expect(store.move(x.id, to: .node(k.id)))
        store.act(for: app) { store.update(y1.id) { $0.content.text = "Renamed" } }
        store.endEdit(app)
        #expect(store.parent(of: x.id) == .node(k.id))

        undo.undo()
        #expect(store.tree.canvas.isEmpty)
        undo.undo()

        #expect(store.tree.canvas.isEmpty)
        #expect(store.tree == start)
    }

    /// The app makes group K, and X is put into K by hand before the app's edit ends. Putting a
    /// thing into K meets the step that made K, so the app's step isn't lifted above it as it
    /// ends: undo takes X out first, then K goes, and nothing lands on the canvas on the way.
    @Test func aStepThatMadeAGroupStaysBelowOneThatPutSomethingInIt() throws {
        let x = leaf(CGRect(x: 40, y: 300, width: 60, height: 40), text: "X")
        let (store, undo) = makeStore(design([x], origin: CGPoint(x: 400, y: 0), scale: 0.5))
        let start = store.tree
        let screenID = try #require(start.screens.first?.id)
        let k = group([leaf(CGRect(x: 20, y: 250, width: 30, height: 30), text: "Y1"),
                       leaf(CGRect(x: 150, y: 400, width: 30, height: 30), text: "Y2")])

        let app = store.beginEdit(by: .app)
        store.act(for: app) { #expect(store.add(k, to: .screen(screenID))) }
        #expect(store.move(x.id, to: .node(k.id)))
        store.endEdit(app)
        #expect(!store.isLastStep(app))

        undo.undo()
        #expect(store.parent(of: x.id) == .screen(screenID))
        #expect(store.node(k.id) != nil)
        undo.undo()

        #expect(store.tree == start)
    }

    /// Group G holds Y and X. The app renames Y, a drag then takes X past G's left edge, so G
    /// is fitted round them again and Y's numbers in G change though Y doesn't move, and the
    /// app then resizes Y. Undoing the drag puts X back and leaves Y as the app left it: its
    /// size, its name and its place on the screen.
    @Test func undoingADragThatRefittedAGroupKeepsAnotherEditToASibling() throws {
        let y = leaf(CGRect(x: 100, y: 100, width: 50, height: 50), text: "Y")
        let x = leaf(CGRect(x: 150, y: 150, width: 50, height: 50), text: "X")
        let g = group([y, x])
        let (store, undo) = makeStore(design([g]))
        #expect(place(of: g.id, in: store) == CGRect(x: 100, y: 100, width: 100, height: 100))

        let app = store.beginEdit(by: .app)
        store.act(for: app) { store.update(y.id) { $0.content.text = "Named" } }
        let drag = store.beginEdit()
        store.act(for: drag) { store.update(x.id) { $0.frame.origin.x = -50 } }
        #expect(place(of: x.id, in: store) == CGRect(x: 50, y: 150, width: 50, height: 50))
        #expect(store.node(y.id)?.frame.origin == CGPoint(x: 50, y: 0))
        store.act(for: app) { store.update(y.id) { $0.frame.size = CGSize(width: 80, height: 80) } }
        store.endEdit(drag)
        store.endEdit(app)
        #expect(store.isLastStep(drag))

        undo.undo()

        #expect(place(of: x.id, in: store) == CGRect(x: 150, y: 150, width: 50, height: 50))
        #expect(place(of: y.id, in: store) == CGRect(x: 100, y: 100, width: 80, height: 80))
        #expect(store.node(y.id)?.content.text == "Named")
        #expect(place(of: g.id, in: store) == CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    /// Siri moves Y, in group G; by hand, X is then dragged past G's left edge, which fits G
    /// round them again. "Undo that" still puts Y back where it was on the screen, and leaves X
    /// where the drag put it.
    @Test func siriTakesBackAMoveAfterASiblingWasDragged() throws {
        let y = leaf(CGRect(x: 100, y: 100, width: 50, height: 50), text: "Y")
        let x = leaf(CGRect(x: 150, y: 150, width: 50, height: 50), text: "X")
        let (store, _) = makeStore(design([group([y, x])]))

        let before = store.content
        store.asOwnStep { store.update(y.id) { $0.frame.origin.x += 10 } }
        let after = store.content
        #expect(place(of: y.id, in: store) == CGRect(x: 110, y: 100, width: 50, height: 50))
        store.update(x.id) { $0.frame.origin.x = -60 }
        #expect(place(of: x.id, in: store) == CGRect(x: 50, y: 150, width: 50, height: 50))

        store.asOwnStep { store.apply { $0.takeBack(after, to: before) } }

        #expect(place(of: y.id, in: store) == CGRect(x: 100, y: 100, width: 50, height: 50))
        #expect(place(of: x.id, in: store) == CGRect(x: 50, y: 150, width: 50, height: 50))
    }
}
