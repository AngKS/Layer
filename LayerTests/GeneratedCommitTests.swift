import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// A store holding one iPhone screen whose root is an empty column, laid out as a file read lays it out, with an
/// undo history of its own.
@MainActor
private func makeStore() -> (store: DesignStore, undo: UndoManager, screen: TreeScreen.ID) {
    var tree = TreeContent()
    var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: "iphone")
    screen.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 24))
    tree.screens = [screen]
    TreeRules.apply(to: &tree, after: nil)
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore(content: DesignContent(tree: tree))
    store.undoManager = undo
    return (store, undo, screen.id)
}

private func outline(_ text: String) -> LayerNode { Outline.parse(text, isComplete: true) }

private func containers(in node: LayerNode) -> [UUID] {
    (node.isContainer ? [node.id] : []) + node.children.flatMap(containers)
}

/// The store's commit of a root laid out off the main actor: one change, laying nothing out when the screen is still
/// the root it was laid out over (plan 3, call 6).
@Suite("Generated commits")
@MainActor
struct GeneratedCommitTests {
    #if DEBUG
    @Test func aCommitOverTheSameScreenLaysNothingOut() throws {
        let (store, undo, id) = makeStore()
        let base = try #require(store.root(of: id))
        let merge = TreeReconciler().merged(outline("title: Settings\nbutton: Save"), over: base)
        let laid = TreeRules.laidOut(merge.root, deviceID: "iphone", settings: store.tree.settings, previous: base)
        let laidOut = containers(in: laid).map(LayoutEngine.timesLaidOut)
        let commits = GenerationWork.commits(on: id)

        #expect(store.commitGenerated(laid, on: id, laidOutOver: base))

        #expect(containers(in: laid).map(LayoutEngine.timesLaidOut) == laidOut)
        #expect(containers(in: laid).first == base.id)
        #expect(store.root(of: id) == laid)
        #expect(store.root(of: id)?.leafCount == 2)
        #expect(GenerationWork.commits(on: id) == commits + 1)
        undo.undo()
        #expect(store.root(of: id) == base)
        #expect(store.root(of: id)?.leafCount == 0)
        #expect(!undo.canUndo)
    }

    @Test func aStaleBaseGivesNoHint() throws {
        let (store, _, id) = makeStore()
        let base = try #require(store.root(of: id))
        let merge = TreeReconciler().merged(outline("title: Settings\nbutton: Save"), over: base)
        let laid = TreeRules.laidOut(merge.root, deviceID: "iphone", settings: store.tree.settings, previous: base)
        let another = TreeRules.laidOut(outline("title: Other"), deviceID: "iphone", settings: store.tree.settings,
                                        previous: nil)
        let laidOut = LayoutEngine.timesLaidOut(base.id)

        #expect(store.commitGenerated(laid, on: id, laidOutOver: another))

        #expect(LayoutEngine.timesLaidOut(base.id) == laidOut + 1)
        #expect(store.root(of: id) == laid)
    }

    @Test func addingLaidOutScreensIsOneStepAndLaysNothingOut() throws {
        let (store, undo, id) = makeStore()
        let before = store.tree
        func laidOutScreen(_ text: String, x: CGFloat) -> TreeScreen {
            var screen = TreeScreen(name: text, origin: CGPoint(x: x, y: 0), scale: 1, deviceID: "iphone")
            var root = outline(text)
            root.id = screen.root.id
            screen.root = TreeRules.laidOut(root, deviceID: "iphone", settings: store.tree.settings, previous: nil)
            return screen
        }
        let screens = [laidOutScreen("title: Login\nbutton: Sign in", x: 500), laidOutScreen("title: Home", x: 1000)]
        let laidOut = screens.map { LayoutEngine.timesLaidOut($0.root.id) }
        let commits = screens.map { GenerationWork.commits(on: $0.id) }

        let ids = store.addLaidOutScreens(screens)

        #expect(ids == screens.map(\.id))
        #expect(screens.map { LayoutEngine.timesLaidOut($0.root.id) } == laidOut)
        #expect(screens.map { store.root(of: $0.id) } == screens.map(\.root))
        #expect(screens.map { GenerationWork.commits(on: $0.id) } == commits.map { $0 + 1 })
        #expect(store.tree.screens.map(\.id) == [id] + ids)
        undo.undo()
        #expect(store.tree == before)
        #expect(!undo.canUndo)
    }

    @Test func layoutAheadIsCountedWhereItRuns() async {
        let root = outline("title: A\nbutton: Go")
        let settings = CanvasSettings()

        _ = await Task.detached {
            TreeRules.laidOut(root, deviceID: "iphone", settings: settings, previous: nil)
        }.value
        let off = GenerationWork.layoutsAhead(of: root.id)
        #expect(off.total == 1)
        #expect(off.onMainThread == 0)

        _ = TreeRules.laidOut(root, deviceID: "iphone", settings: settings, previous: nil)
        let on = GenerationWork.layoutsAhead(of: root.id)
        #expect(on.total == 2)
        #expect(on.onMainThread == 1)
    }
    #endif

    @Test func aCommitToAGoneScreenIsRefused() throws {
        let (store, undo, id) = makeStore()
        let base = try #require(store.root(of: id))
        let laid = TreeRules.laidOut(outline("title: Settings"), deviceID: "iphone", settings: store.tree.settings,
                                     previous: nil)
        let before = store.content

        #expect(!store.commitGenerated(laid, on: UUID(), laidOutOver: base))

        #expect(store.content == before)
        #expect(!undo.canUndo)
    }

    @Test func anIDTheDesignHoldsElsewhereIsRenewedOnceAndThenKept() throws {
        let (store, _, id) = makeStore()
        var elsewhere = TreeScreen(name: "Other", origin: CGPoint(x: 500, y: 0), scale: 1, deviceID: "iphone")
        var text = LayerNode(kind: .text)
        text.frame = CGRect(x: 20, y: 100, width: 80, height: 20)
        elsewhere.root.children = [text]
        #expect(store.addScreen(elsewhere) == elsewhere.id)
        let key = "group:0/title:0"
        func title(in root: LayerNode?) -> LayerNode? {
            root?.children.first?.children.first { $0.source?.key == key }
        }
        var generated = outline("title: Settings")
        generated.children[0].children[0].id = text.id
        var reconciler = TreeReconciler()

        var base = try #require(store.root(of: id))
        var merge = reconciler.merged(generated, over: base)
        var laid = TreeRules.laidOut(merge.root, deviceID: "iphone", settings: store.tree.settings, previous: base)
        #expect(store.commitGenerated(laid, on: id, laidOutOver: base))
        var committed = try #require(store.root(of: id))
        reconciler.record(merge, committed: committed)

        let renewed = try #require(title(in: committed)?.id)
        #expect(renewed != text.id)
        #expect(store.node(text.id) == text)
        if case .node(let recorded, _)? = reconciler.written[key] {
            #expect(recorded == renewed)
        } else {
            Issue.record("The title isn't recorded as written: \(String(describing: reconciler.written[key]))")
        }

        base = committed
        merge = reconciler.merged(outline("title: Settings\nbutton: Save"), over: base)
        laid = TreeRules.laidOut(merge.root, deviceID: "iphone", settings: store.tree.settings, previous: base)
        #expect(store.commitGenerated(laid, on: id, laidOutOver: base))
        committed = try #require(store.root(of: id))
        #expect(title(in: committed)?.id == renewed)
        #expect(committed == laid)
    }

    @Test func laidOutScreensTheTreeCantHoldAreLeftOut() throws {
        let (store, _, id) = makeStore()
        let base = try #require(store.root(of: id))
        var again = TreeScreen(name: "Again", origin: CGPoint(x: 500, y: 0), scale: 1, deviceID: "iphone")
        again.root.children = [base]
        var withANote = TreeScreen(name: "Note", origin: CGPoint(x: 1000, y: 0), scale: 1, deviceID: "iphone")
        withANote.root.children = [LayerNode(kind: .stickyNote)]
        var fine = TreeScreen(name: "Fine", origin: CGPoint(x: 1500, y: 0), scale: 1, deviceID: "iphone")
        fine.root = TreeRules.laidOut(fine.root, deviceID: "iphone", settings: store.tree.settings, previous: nil)
        let before = store.tree.screens.map(\.id)

        let ids = store.addLaidOutScreens([again, withANote, fine, fine])

        #expect(ids == [fine.id])
        #expect(store.tree.screens.map(\.id) == before + [fine.id])
        #expect(store.addLaidOutScreens([again]).isEmpty)
    }
}
