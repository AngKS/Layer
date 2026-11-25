import CoreGraphics
import Foundation
import Testing
@testable import Layer

@MainActor
private func makeStore() -> (store: DesignStore, undo: UndoManager) {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore()
    store.undoManager = undo
    return (store, undo)
}

private let titleSketch = CGRect(x: 150, y: 112, width: 96, height: 40)
private let boxSketch = CGRect(x: 30, y: 300, width: 330, height: 44)
private let noteSketch = CGRect(x: 1200, y: 100, width: 150, height: 150)

@Suite("One list of elements")
@MainActor
struct FlatStoreTests {
    /// Two screens side by side with a title on the first, a note on the open canvas, and
    /// a button on the second, added in that order.
    private func board() throws -> (store: DesignStore, undo: UndoManager, first: TreeScreen.ID, second: TreeScreen.ID,
                                    title: (id: UUID, frame: CGRect), note: NodeRef, button: (id: UUID, frame: CGRect)) {
        let (store, undo) = makeStore()
        let first = try #require(store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))).id
        let second = try #require(store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 500, y: 0), scale: 1))).id
        let title = try #require(store.sketched(.title, from: titleSketch, to: first))
        let note = try #require(store.placeLoose(.stickyNote, sketchedAs: noteSketch))
        let button = try #require(store.sketched(.button, from: boxSketch.offsetBy(dx: 500, dy: 0), to: second))
        return (store, undo, first, second, title, note, button)
    }

    /// What is on each host, back to front, as the design keeps it. The tree holds no order
    /// between hosts, so the one list is read host by host (F4).
    private func lists(on hosts: [TreeScreen.ID?], in store: DesignStore) -> [[UUID]] {
        hosts.map { store.tree.listed(on: $0).map(\.id) }
    }

    @Test func everythingOnTheBoardIsInOneListAndSaysWhatItIsOn() throws {
        let (store, _, first, second, title, note, button) = try board()

        #expect(Set(store.tree.listedEverywhere.map(\.id)) == [title.id, note.node, button.id])
        let lists = [first, nil, second].map(store.tree.listed(on:))
        #expect(lists.map { $0.map(\.id) } == [[title.id], [note.node], [button.id]])
        #expect(lists.map { $0.map { store.hostScreen(of: $0.id) } } == [[first], [nil], [second]])
        // On the open canvas an element says how large it is drawn; on a screen the screen does.
        #expect(lists.map { $0.map(\.scale) } == [[nil], [store.looseScale], [nil]])
    }

    @Test func theScreensAndTheOpenCanvasAreViewsOfTheList() throws {
        let (store, _, _, _, title, note, button) = try board()
        #expect(store.tree.screens.map { store.screenLeaves($0.id).map(\.id) } == [[title.id], [button.id]])
        #expect(store.tree.canvasLeaves.map(\.id) == [note.node])
        #expect(store.tree.canvas.first?.scale == store.looseScale)
    }

    @Test func anElementIsFoundByItsIdentifierAlone() throws {
        let (store, _, _, second, _, _, button) = try board()
        #expect(store.node(button.id)?.id == button.id)
        #expect(store.ownFrame(button.id) == button.frame)
        #expect(store.hostScreen(of: button.id) == second)
        #expect(store.node(UUID()) == nil)
    }

    @Test func movingToAnotherScreenChangesWhatItIsOnAndPutsItOnTopThere() throws {
        let (store, _, first, second, title, note, button) = try board()
        let ref = NodeRef(host: .screen(first), node: title.id)

        let moved = try #require(store.move(ref, toScreen: second, origin: CGPoint(x: 20, y: 80)))

        #expect(moved == NodeRef(host: .screen(second), node: title.id))
        #expect(store.hostScreen(of: title.id) == second)
        #expect(lists(on: [first, second, nil], in: store) == [[], [button.id, title.id], [note.node]])
        #expect(store.tree.screens.map { store.screenLeaves($0.id).map(\.id) } == [[], [button.id, title.id]])
    }

    @Test func leavingAScreenForTheOpenCanvasKeepsTheSizeItWasDrawnAt() throws {
        let (store, _, first, _, title, _, _) = try board()
        let ref = NodeRef(host: .screen(first), node: title.id)

        let moved = try #require(store.move(ref, toScreen: nil, origin: nil))

        #expect(moved.host == .canvas)
        let loose = try #require(store.node(title.id))
        #expect(store.hostScreen(of: title.id) == nil)
        #expect(loose.scale == store.treeScreen(first)?.scale)
        #expect(store.ownFrame(title.id)?.size == title.frame.size)
    }

    @Test func arrangingReordersOnlyAmongWhatSharesItsScreen() throws {
        let (store, _, first, second, title, note, button) = try board()
        let body = try #require(store.sketched(.body, from: boxSketch, to: first))
        #expect(lists(on: [first, nil, second], in: store) == [[title.id, body.id], [note.node], [button.id]])

        store.arrange(NodeRef(host: .screen(first), node: body.id), .back)

        // The body and the title swap places; the note and the button stay where they are.
        #expect(lists(on: [first, nil, second], in: store) == [[body.id, title.id], [note.node], [button.id]])
        #expect(store.screenLeaves(first).map(\.id) == [body.id, title.id])
    }

    @Test func deletingAScreenTakesWhatIsOnItOutOfTheList() throws {
        let (store, undo, first, second, title, note, button) = try board()

        store.deleteScreen(first)
        #expect(Set(store.tree.listedEverywhere.map(\.id)) == [note.node, button.id])
        #expect(lists(on: [first, nil, second], in: store) == [[], [note.node], [button.id]])

        undo.undo()
        #expect(lists(on: [first, nil, second], in: store) == [[title.id], [note.node], [button.id]])
    }

    @Test func aCopiedScreenBringsCopiesOfWhatIsOnIt() throws {
        let (store, _, first, _, title, _, _) = try board()

        let copy = try #require(store.duplicateScreen(first))

        let copied = store.tree.listedEverywhere.filter { store.hostScreen(of: $0.id) == copy.id }
        #expect(copied.count == 1)
        #expect(copied.first?.kind == .title)
        #expect(copied.first?.id != title.id)
        #expect(store.hostScreen(of: title.id) == first)
    }
}

/// Counts notices, which are posted on the thread that changes the history: here, the main one.
private final class Tally: @unchecked Sendable {
    var count = 0
}

/// A gradual edit's step and the saving it asks for (final fix wave, items 11 and 12).
@Suite("A gradual edit's step")
@MainActor
struct GradualEditStepTests {
    /// Typed and deleted again, or a screen written and taken away: the edit ends where it
    /// began, and leaves no step that undoes nothing. The step before is still on top.
    @Test func anEditThatEndsWhereItBeganLeavesNoStep() throws {
        let (store, undo) = makeStore()
        let screen = try #require(store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400)))
        store.beginEdit()
        store.updateTreeScreen(screen.id) { $0.name = "Settings" }
        store.updateTreeScreen(screen.id) { $0.name = "Screen 1" }
        store.endEdit()
        #expect(undo.canUndo)
        undo.undo()
        #expect(store.tree.screens.isEmpty, "undo takes back the screen added before the edit")
        #expect(!undo.canUndo)
    }

    @Test func anEditThatEndsWhereItBeganOnAnEmptyHistoryLeavesUndoOff() throws {
        let (store, undo) = makeStore()
        store.beginEdit()
        let screen = try #require(store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400)))
        store.deleteScreen(screen.id)
        store.endEdit()
        #expect(!undo.canUndo && !undo.canRedo)
        // The next change is a step as ever, and undoes.
        store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400))
        undo.undo()
        #expect(store.tree.screens.isEmpty)
    }

    /// The app's history groups by event, as a document's does: the step taken out leaves
    /// no empty group behind for Undo to light up for.
    @Test func anEditThatEndsWhereItBeganLeavesNoEmptyGroupWhenGroupedByEvent() async throws {
        let undo = UndoManager()
        let store = DesignStore()
        store.undoManager = undo
        store.beginEdit()
        let screen = try #require(store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400)))
        store.deleteScreen(screen.id)
        store.endEdit()
        // The event's group closes when the run loop turns.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!undo.canUndo)
    }

    /// The same when the edit ends in a later event than its first change, as a failed
    /// generation's does.
    @Test func anEditEndedInALaterEventWhereItBeganLeavesNoStepWhenGroupedByEvent() async throws {
        let undo = UndoManager()
        let store = DesignStore()
        store.undoManager = undo
        store.beginEdit()
        let screen = try #require(store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(undo.canUndo)
        store.deleteScreen(screen.id)
        store.endEdit()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!undo.canUndo)
    }

    /// An edit that changed something still undoes as one step.
    @Test func anEditThatChangedSomethingKeepsItsStep() throws {
        let (store, undo) = makeStore()
        store.beginEdit()
        let screen = try #require(store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400)))
        store.updateTreeScreen(screen.id) { $0.name = "Settings" }
        store.endEdit()
        #expect(undo.canUndo)
        undo.undo()
        #expect(store.tree.screens.isEmpty && !undo.canUndo)
    }

    /// An edit's step goes in at its first change, which is when the system hears there is
    /// something to save. When the edit ends it is told again, so that the rest of a long
    /// edit isn't lost to an autosave made part way through it.
    @Test func theEndOfAnEditInTheHistoryAsksForASave() throws {
        let (store, undo) = makeStore()
        let asked = Tally()
        let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerWillCloseUndoGroup, object: undo, queue: nil) { _ in
            asked.count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.beginEdit()
        let screen = try #require(store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400)))
        let afterFirstChange = asked.count
        #expect(afterFirstChange >= 1)
        store.updateTreeScreen(screen.id) { $0.name = "Settings" }
        #expect(asked.count == afterFirstChange, "later changes join the step without a word")
        store.endEdit()
        #expect(asked.count > afterFirstChange)
    }
}

@Suite("Saving the list of elements")
struct FlatFormatTests {
    private func element(_ kind: ElementKind, at y: CGFloat = 100) -> LayerNode {
        .leaf(kind, frame: CGRect(x: 20, y: y, width: 200, height: 40), text: kind.placeholder, tint: Theme.accent)
    }

    /// A screen whose free root holds `nodes`, each where its frame puts it.
    private func screen(_ nodes: [LayerNode], origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeScreen {
        var root = LayerNode(kind: .group)
        root.children = nodes
        return TreeScreen(name: "Screen 1", origin: origin, scale: scale, deviceID: nil, root: root)
    }

    /// `node` on the open canvas, drawn `scale` canvas points to each of its own.
    private func loose(_ node: LayerNode, scale: CGFloat) -> LayerNode {
        var drawn = node
        drawn.scale = scale
        return drawn
    }

    private func json(_ content: TreeContent) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
    }

    @Test func aDesignIsSavedAsScreensHoldingTreesAndCanvasNodes() throws {
        var content = TreeContent()
        content.screens = [screen([element(.title), element(.button, at: 200)])]
        content.canvas = [loose(element(.stickyNote), scale: 0.66)]

        let saved = try json(content)

        let screens = try #require(saved["screens"] as? [[String: Any]])
        #expect(screens.count == 1)
        #expect(screens[0]["elements"] == nil, "a screen holds its tree, not a list")
        // What is on the screen is in its root; what is on the open canvas is among the canvas's nodes.
        let children = try #require((screens[0]["root"] as? [String: Any])?["children"] as? [[String: Any]])
        #expect(children.map { $0["kind"] as? String } == ["title", "button"])
        #expect(children.map { $0["scale"] as? Double } == [nil, nil])
        let canvas = try #require(saved["canvas"] as? [[String: Any]])
        #expect(canvas.map { $0["kind"] as? String } == ["stickyNote"])
        #expect(canvas.map { $0["scale"] as? Double } == [0.66])
        #expect((children + canvas).allSatisfy { $0["parent"] == nil })
        #expect(saved["elements"] == nil)
        #expect(saved["floating"] == nil)
    }

    @Test func aSavedDesignReadsBackAsItWas() throws {
        var content = TreeContent()
        content.screens = [screen([element(.title), element(.image, at: 200)], origin: CGPoint(x: 40, y: 60), scale: 0.5)]
        content.canvas = [loose(element(.text), scale: 0.5)]
        content.title = "Sign In"

        let read = try JSONDecoder().decode(TreeContent.self, from: JSONEncoder().encode(content))

        #expect(read == content)
    }

    @Test func anElementOfAKindThisVersionDoesNotKnowIsKeptAndWrittenBackWhereItWas() throws {
        var content = TreeContent()
        let screen = screen([element(.title), element(.button, at: 200)])
        content.screens = [screen]
        var saved = try json(content)
        var screens = try #require(saved["screens"] as? [[String: Any]])
        var root = try #require(screens[0]["root"] as? [String: Any])
        var children = try #require(root["children"] as? [[String: Any]])
        // A later version of Layer put a carousel between the two, and the three in a group.
        let carousel: [String: Any] = ["id": UUID().uuidString, "kind": "carousel", "pages": 3, "frame": [[0, 50], [353, 180]]]
        children.insert(carousel, at: 1)
        let group: [String: Any] = ["id": UUID().uuidString, "kind": "group", "frame": [[20, 100], [353, 230]], "children": children]
        root["children"] = [group]
        screens[0]["root"] = root
        saved["screens"] = screens

        let read = try JSONDecoder().decode(TreeContent.self, from: JSONSerialization.data(withJSONObject: saved))

        // The design opens with what this version understands.
        #expect(read.screens.first.map { read.leaves(on: $0.id).map(\.kind) } == [.title, .button])
        // And saving it loses nothing.
        let writtenScreen = try #require((try json(read)["screens"] as? [[String: Any]])?.first)
        let writtenGroup = try #require(((writtenScreen["root"] as? [String: Any])?["children"] as? [[String: Any]])?.first)
        let written = try #require(writtenGroup["children"] as? [[String: Any]])
        #expect(written.map { $0["kind"] as? String } == ["title", "carousel", "button"])
        #expect(written[1]["pages"] as? Int == 3)
        #expect(writtenScreen["id"] as? String == screen.id.uuidString)
    }
}
