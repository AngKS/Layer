import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The tree's test builders and the design Tasks 3–8 share (plan 6, Task 1), and what Siri and voice both need, written
/// once before the lanes are cut (F13): where a new leaf goes, what a new leaf is, the drag rule for a frame in host
/// points, and a design's own device found by its name.
@MainActor
@Suite("Tree builders")
struct TreeBuildersTests {
    /// An undo history of its own for `store`, starting empty.
    @discardableResult
    private func giveUndo(to store: DesignStore) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return undo
    }

    // MARK: Leaves and containers

    @Test func aLeafIsFixedAndKeepsItsKindsOwnTint() {
        let leaf = LayerNode.leaf(.text, frame: CGRect(x: 20, y: 80, width: 200, height: 24), text: "Hi")
        #expect(leaf.width.mode == .fixed)
        #expect(leaf.height.mode == .fixed)
        #expect(leaf.style.tint == nil)
        #expect(leaf.children.isEmpty)

        let row = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 12)), padding: 8, children: [leaf])
        #expect(row.kind == .group)
        #expect(row.width.mode == .fit)
        #expect(row.height.mode == .fit)
        #expect(row.padding == LayerNode.Padding(all: 8))
        #expect(row.children.map(\.id) == [leaf.id])
    }

    // MARK: Screens

    @Test func aFreeScreenHoldsWhatItWasGiven() throws {
        let store = DesignStore()
        let undo = giveUndo(to: store)
        let a = LayerNode.leaf(.title, frame: CGRect(x: 20, y: 80, width: 228, height: 40), text: "Welcome")
        let b = LayerNode.leaf(.button, frame: CGRect(x: 20, y: 420, width: 353, height: 50), text: "Sign in")

        let screen = store.addFreeScreen([a, b])

        let root = try #require(store.treeScreen(screen)?.root)
        #expect(root.children.map(\.id) == [a.id, b.id])
        #expect(root.layout == nil)
        #expect(store.ownFrame(a.id) == CGRect(x: 20, y: 80, width: 228, height: 40))
        #expect(store.treeScreen(screen)?.name == "Screen 1")
        undo.undo()
        #expect(store.tree.screens.isEmpty)
        #expect(!undo.canUndo)
    }

    @Test func aColumnScreenLaysItsChildrenOut() throws {
        let store = DesignStore()
        let first = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 100, height: 24), text: "One")
        let second = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 100, height: 24), text: "Two")

        let screen = store.addColumnScreen([first, second])

        #expect(store.treeScreen(screen)?.root.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 24)))
        let one = try #require(store.ownFrame(first.id)), two = try #require(store.ownFrame(second.id))
        #expect(one.minX == 20)
        #expect(two.minY == one.maxY + 24)
    }

    @Test func aNodeOnTheCanvasKeepsItsScale() throws {
        let store = DesignStore()
        let note = LayerNode.leaf(.stickyNote, frame: CGRect(x: 600, y: 100, width: 150, height: 150), text: "Idea")

        let id = store.addCanvasNode(note, scale: 0.5)

        #expect(id == note.id)
        #expect(store.tree.canvas.map(\.id) == [note.id])
        #expect(store.tree.canvas.first?.scale == 0.5)
        #expect(store.ownFrame(id) == CGRect(x: 600, y: 100, width: 150, height: 150))
    }

    // MARK: The fixture

    @Test func screenLeavesAreDepthFirst() {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        #expect(store.screenLeaves(login.screen).map(\.id) == [login.title, login.about, login.body, login.label, login.toggle])
        #expect(store.tree.canvasLeaves.map(\.id) == [login.note])
        #expect(store.screenLeaves(UUID()).isEmpty)
    }

    @Test func theFixtureIsAsDescribed() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let screen = try #require(store.treeScreen(login.screen))
        #expect(screen.name == "Login")
        #expect(screen.origin == .zero)
        #expect(screen.scale == 1)
        #expect(store.device(of: login.screen) == .iPhone)
        #expect(login.model.zoomScale == 1)
        #expect(screen.root.layout == nil)
        #expect(screen.root.children.map(\.id) == [login.title, login.card, login.row])
        #expect(store.ownFrame(login.title) == CGRect(x: 20, y: 80, width: 228, height: 40))

        let card = try #require(store.node(login.card))
        #expect(card.kind == .card)
        #expect(card.layout == nil)
        #expect(card.padding == LayerNode.Padding(all: 16))
        #expect(card.width.mode == .fixed && card.height.mode == .fixed)
        #expect(store.ownFrame(login.card) == CGRect(x: 20, y: 140, width: 353, height: 160))
        #expect(store.ownFrame(login.about) == CGRect(x: 36, y: 156, width: 200, height: 24))
        #expect(store.ownFrame(login.body) == CGRect(x: 36, y: 188, width: 321, height: 40))

        let row = try #require(store.node(login.row))
        #expect(row.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .center)))
        #expect(row.width.mode == .fit && row.height.mode == .fit)
        #expect(store.ownFrame(login.row) == CGRect(x: 20, y: 320, width: 143, height: 31))
        // Centred in the row it is 3.5 down, and the engine puts a laid-out frame on whole points (F7).
        #expect(store.ownFrame(login.label) == CGRect(x: 20, y: 324, width: 80, height: 24))
        #expect(store.ownFrame(login.toggle) == CGRect(x: 112, y: 320, width: 51, height: 31))
        #expect(store.node(login.toggle)?.content.isOn == true)

        #expect(store.node(login.note)?.content.text == "Idea")
        #expect(store.index[login.note]?.hostShape.rect == CGRect(x: 300, y: 50, width: 75, height: 75))

        let file = try #require(login.model.fileURL)
        #expect(file.pathExtension == "layer")
        #expect(login.designID == DesignLibrary.id(for: file))
        #expect(OpenDesigns.shared.model(forDesign: login.designID) === login.model)
        #expect(store.undoManager === login.undo)
        #expect(!login.undo.canUndo)
    }

    // MARK: Where a new leaf goes, and what it is

    @Test func aNewElementGoesWhereItWentBefore() throws {
        let store = DesignStore()
        let screen = store.addFreeScreen([.leaf(.title, frame: CGRect(x: 20, y: 80, width: 228, height: 40), text: "Welcome")])
        // What `DesignActions.frameForNewElement` gave for a button on this screen, recorded before it moved (F16).
        let recorded = CGRect(x: 20, y: 136, width: 353, height: 50)

        let frame = try #require(store.newElementFrame(.button, on: screen))

        #expect(frame == recorded)
        #expect(frame.minY == 136)
        #expect(store.newElementFrame(.button, on: UUID()) == nil)
    }

    /// F28: a card padded below its last leaf keeps its padding; the new leaf goes below the card whole.
    @Test func aNewElementGoesBelowACardWhole() throws {
        let store = DesignStore()
        let text = LayerNode.leaf(.text, frame: CGRect(x: 16, y: 16, width: 200, height: 44), text: "Ends at 140")
        let card = LayerNode.container(.card, frame: CGRect(x: 20, y: 80, width: 353, height: 200), width: .init(.fixed),
                                       height: .init(.fixed), padding: 16, children: [text])
        let screen = store.addFreeScreen([card])
        #expect(store.ownFrame(text.id)?.maxY == 140)
        #expect(store.ownFrame(card.id)?.maxY == 280)

        #expect(store.newElementFrame(.button, on: screen)?.minY == 296)
    }

    @Test func aStandardLeafIsTodaysNewElement() {
        let button = LayerNode.standard(.button)
        #expect(button.kind == .button)
        #expect(button.content.text == ElementKind.button.placeholder)
        #expect(button.style.tint == ElementKind.button.spec.tint)
        #expect(button.frame == CGRect(origin: .zero, size: ElementLayout.size(for: .button, sketch: .zero)))
        #expect(button.frame.size == CGSize(width: 353, height: 50))
        #expect(button.width.mode == .fixed)
        #expect(button.height.mode == .fixed)
        #expect(button.children.isEmpty)

        let heart = LayerNode.standard(.symbol, symbol: "heart.fill")
        #expect(heart.content.symbol == "heart.fill")
        #expect(heart.style.tint == ElementKind.symbol.spec.tint)
        #expect(LayerNode.standard(.button).id != button.id)
    }

    // MARK: The drag rule for a frame in host points

    @Test func aHostFrameFollowsTheDragRule() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store, undo = login.undo
        let before = store.tree

        // In the free card: placed where asked, still in the card.
        #expect(store.move(login.about, toHostFrame: CGRect(x: 60, y: 160, width: 200, height: 24)) == .placed)
        #expect(store.ownFrame(login.about) == CGRect(x: 60, y: 160, width: 200, height: 24))
        #expect(store.parent(of: login.about) == .node(login.card))
        undo.undo()
        #expect(store.tree == before)
        #expect(!undo.canUndo)

        // Out of the row, where nothing lays it out: on top of the screen's root, fixed both ways.
        #expect(store.move(login.label, toHostFrame: CGRect(x: 40, y: 600, width: 80, height: 24)) == .takenOut)
        #expect(store.treeScreen(login.screen)?.root.children.last?.id == login.label)
        #expect(store.ownFrame(login.label) == CGRect(x: 40, y: 600, width: 80, height: 24))
        let taken = try #require(store.node(login.label))
        #expect(taken.width.mode == .fixed && taken.height.mode == .fixed)
        #expect(store.children(of: .node(login.row))?.map(\.id) == [login.toggle])
        undo.undo()
        #expect(store.tree == before)
        #expect(!undo.canUndo)

        // Its centre before the label's middle, inside the row: the row's first.
        #expect(store.move(login.toggle, toHostFrame: CGRect(x: 10, y: 320, width: 51, height: 31)) == .reordered)
        #expect(store.children(of: .node(login.row))?.map(\.id) == [login.toggle, login.label])
        undo.undo()
        #expect(store.tree == before)
        #expect(!undo.canUndo)

        // A size alone: that axis fixed, and it stays in the row.
        #expect(store.move(login.label, toHostFrame: CGRect(x: 20, y: 324, width: 120, height: 24), size: true) == .resized)
        #expect(store.parent(of: login.label) == .node(login.row))
        #expect(store.node(login.label)?.frame.width == 120)
        #expect(store.node(login.label)?.width.mode == .fixed)
        undo.undo()
        #expect(store.tree == before)
        #expect(!undo.canUndo)

        // Into a slot with a new size: reordered, the size fixed on the axis that changed, as one step.
        #expect(store.move(login.toggle, toHostFrame: CGRect(x: 10, y: 320, width: 60, height: 31)) == .reordered)
        #expect(store.children(of: .node(login.row))?.map(\.id) == [login.toggle, login.label])
        let widened = try #require(store.node(login.toggle))
        #expect(widened.frame.width == 60)
        #expect(widened.width.mode == .fixed)
        #expect(store.ownFrame(login.row)?.width == 152)
        undo.undo()
        #expect(store.tree == before)
        #expect(!undo.canUndo)

        // Its own slot with a new size, given as a frame rather than a size alone: resized, still where it was.
        #expect(store.move(login.label, toHostFrame: CGRect(x: 20, y: 324, width: 100, height: 24)) == .resized)
        #expect(store.children(of: .node(login.row))?.map(\.id) == [login.label, login.toggle])
        #expect(store.node(login.label)?.frame.width == 100)
        #expect(store.node(login.label)?.width.mode == .fixed)
        undo.undo()
        #expect(store.tree == before)
        #expect(!undo.canUndo)

        // Where it already is: nothing, and no step.
        #expect(store.move(login.label, toHostFrame: CGRect(x: 20, y: 324, width: 80, height: 24)) == .unchanged)
        #expect(store.tree == before)
        #expect(!undo.canUndo)

        // On a column screen, off the screen: the root lays it out and can't take it freely (F15).
        let column = DesignStore()
        let one = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 100, height: 24), text: "One")
        let two = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 100, height: 24), text: "Two")
        column.addColumnScreen([one, two])
        let columnUndo = giveUndo(to: column)
        let laidOut = column.tree
        #expect(column.move(one.id, toHostFrame: CGRect(x: 500, y: 900, width: 100, height: 24)) == .refused)
        #expect(column.tree == laidOut)
        #expect(!columnUndo.canUndo)
    }

    // MARK: Devices

    @Test func aCustomDeviceIsFoundByItsName() {
        let store = DesignStore()
        let kiosk = store.addCustomDevice(.custom(name: "Kiosk", size: CGSize(width: 1080, height: 1920), family: .other))
        let settings = store.tree.settings

        #expect(settings.customDevice(named: " kiosk ")?.id == kiosk)
        #expect(settings.customDevice(named: "Kiosk")?.name == "Kiosk")
        #expect(settings.customDevice(named: "Wall") == nil)
        // A built-in isn't one of the design's own.
        #expect(settings.customDevice(named: "iPhone") == nil)
    }

    // MARK: The sketch path

    /// A sketch read on its screen adds a leaf of the kind there, and one off every screen adds nothing (F12). Its bridge
    /// to plan 5's wrapper, which gave the same frame on a twin store, went with the wrapper (plan 6, Task 11, clause (s)).
    @Test func sketchedAddsALeafOnItsScreen() throws {
        let store = DesignStore()
        let screen = store.addFreeScreen([])
        let sketch = CGRect(x: 120, y: 150, width: 160, height: 24)

        let made = try #require(store.sketched(.title, from: sketch, to: screen))

        #expect(store.node(made.id)?.kind == .title)
        #expect(store.sketched(.title, from: CGRect(x: 2000, y: 2000, width: 160, height: 24), to: screen) == nil)
    }
}
