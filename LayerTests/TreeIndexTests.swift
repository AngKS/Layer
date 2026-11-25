import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Tree index")
struct TreeIndexTests {
    private static func profile() throws -> TreeContent {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "design-profile", withExtension: "json"))
        return try TreeManifest.decode(try Data(contentsOf: url)).content
    }

    private static func count(_ node: LayerNode) -> Int {
        1 + node.children.reduce(0) { $0 + count($1) }
    }

    private static func ids(_ node: LayerNode) -> [UUID] {
        [node.id] + node.children.flatMap(ids)
    }

    private static func node(_ kind: ElementKind, _ frame: CGRect) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        return node
    }

    private static func screenContent(_ root: (inout LayerNode) -> Void, origin: CGPoint = .zero, scale: CGFloat = 1) -> (TreeContent, TreeScreen) {
        var screen = TreeScreen(name: "S", origin: origin, scale: scale, deviceID: nil)
        root(&screen.root)
        var content = TreeContent()
        content.screens = [screen]
        return (content, screen)
    }

    @Test func everyNodeHasAnEntry() throws {
        let content = try Self.profile()
        let index = TreeIndex(content)
        let all = content.screens.flatMap { Self.ids($0.root) } + content.canvas.flatMap(Self.ids)
        #expect(index.count == all.count)
        #expect(index.count == content.screens.reduce(0) { $0 + Self.count($1.root) } + content.canvas.reduce(0) { $0 + Self.count($1) })
        for id in all {
            #expect(index.node(id, in: content)?.id == id)
        }
    }

    @Test func aScreensRootIsAtDepthZero() throws {
        let content = try Self.profile()
        let index = TreeIndex(content)
        let screen = try #require(content.screens.first)
        let root = try #require(index[screen.root.id])
        #expect(root.host == .screen(screen.id))
        #expect(root.parent == nil)
        #expect(root.depth == 0)
        #expect(root.path.isEmpty)
    }

    @Test func aChildOfATurnedContainerHasItsTurnedPose() {
        var child = Self.node(.body, CGRect(x: 0, y: 0, width: 20, height: 20))
        child.id = UUID()
        var group = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 100))
        group.rotation = 90
        group.children = [child]
        let (content, _) = Self.screenContent { $0.children = [group] }
        let index = TreeIndex(content)
        let entry = index[child.id]
        #expect(entry?.hostShape.degrees == 90)
        let centre = entry?.hostShape.centre ?? .zero
        #expect(abs(centre.x - 240) < 0.001 && abs(centre.y - 60) < 0.001)
        #expect(entry?.depth == 2)
        #expect(entry?.parent == group.id)
    }

    @Test func lockAndHideComeFromAncestors() {
        let grandchild = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10))
        var child = Self.node(.group, CGRect(x: 0, y: 0, width: 50, height: 50))
        child.children = [grandchild]
        var card = Self.node(.card, CGRect(x: 0, y: 0, width: 100, height: 100))
        card.isLocked = true
        card.children = [child]
        let hiddenChild = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10))
        var row = Self.node(.group, CGRect(x: 0, y: 200, width: 100, height: 50))
        row.isHidden = true
        row.children = [hiddenChild]
        let (content, _) = Self.screenContent { $0.children = [card, row] }
        let index = TreeIndex(content)
        #expect(index[grandchild.id]?.isLockedWithAncestors == true)
        #expect(index[grandchild.id]?.isHiddenWithAncestors == false)
        #expect(index[hiddenChild.id]?.isHiddenWithAncestors == true)
        #expect(index[hiddenChild.id]?.isLockedWithAncestors == false)
    }

    @Test func canvasNodesUseTheirScale() {
        var note = Self.node(.stickyNote, CGRect(x: 100, y: 100, width: 150, height: 150))
        note.scale = 0.5
        var content = TreeContent()
        content.canvas = [note]
        let index = TreeIndex(content)
        #expect(index[note.id]?.hostShape.rect == CGRect(x: 50, y: 50, width: 75, height: 75))
        #expect(index[note.id]?.host == .canvas)
        #expect(index[note.id]?.depth == 0)
        #expect(index.node(note.id, in: content)?.id == note.id)
    }

    @Test func aScreenNodesCanvasShapeGoesThroughTheScreen() {
        let node = Self.node(.body, CGRect(x: 20, y: 40, width: 100, height: 50))
        let (content, _) = Self.screenContent({ $0.children = [node] }, origin: CGPoint(x: 1000, y: 0), scale: 0.5)
        let index = TreeIndex(content)
        let shape = index.canvasShape(of: node.id, in: content)
        #expect(shape?.rect == CGRect(x: 1010, y: 20, width: 50, height: 25))
        #expect(index.canvasShape(of: UUID(), in: content) == nil)
    }

    @Test func ancestorsAreNearestFirst() {
        let leaf = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10))
        var inner = Self.node(.group, CGRect(x: 0, y: 0, width: 50, height: 50))
        inner.children = [leaf]
        var outer = Self.node(.card, CGRect(x: 0, y: 0, width: 100, height: 100))
        outer.children = [inner]
        let (content, screen) = Self.screenContent { $0.children = [outer] }
        let index = TreeIndex(content)
        #expect(index.ancestors(of: leaf.id) == [inner.id, outer.id, screen.root.id])
        #expect(index.ancestors(of: screen.root.id).isEmpty)
        #expect(index.ancestors(of: UUID()).isEmpty)
    }

    /// Only a damaged design has two nodes of one id: the first keeps the entry, and what the
    /// second holds is still indexed where it is.
    @Test func aSecondNodeOfOneIDLeavesTheFirstsEntryAndWhatItHoldsIsIndexed() throws {
        let shared = UUID()
        var first = Self.node(.group, CGRect(x: 0, y: 0, width: 100, height: 100))
        first.id = shared
        first.children = [Self.node(.body, CGRect(x: 10, y: 10, width: 20, height: 20))]
        var second = Self.node(.group, CGRect(x: 300, y: 0, width: 100, height: 100))
        second.id = shared
        let inside = Self.node(.body, CGRect(x: 10, y: 10, width: 20, height: 20))
        second.children = [inside]
        var content = TreeContent()
        content.canvas = [first, second]

        let index = TreeIndex(content)

        #expect(index[shared]?.path == [0])
        let entry = try #require(index[inside.id])
        #expect(entry.path == [1, 0])
        #expect(entry.hostShape.rect == CGRect(x: 310, y: 10, width: 20, height: 20))
        #expect(index.node(inside.id, in: content) == inside)
        // The first, what it holds, and what the second holds.
        #expect(index.count == 3)
    }

    @Test func aLargeDesignIsIndexedQuickly() {
        var content = TreeContent()
        for s in 0..<10 {
            var cards: [LayerNode] = []
            for c in 0..<50 {
                var card = Self.node(.card, CGRect(x: 0, y: CGFloat(c) * 10, width: 300, height: 10))
                card.children = (0..<9).map { Self.node(.body, CGRect(x: CGFloat($0), y: 0, width: 10, height: 10)) }
                cards.append(card)
            }
            var screen = TreeScreen(name: "S\(s)", origin: CGPoint(x: CGFloat(s) * 500, y: 0), scale: 0.5, deviceID: nil)
            screen.root.children = cards
            content.screens.append(screen)
        }
        // 10 screens x (1 root + 50 cards + 450 leaves) = 5,010 nodes
        var times: [Duration] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let index = TreeIndex(content)
            times.append(ContinuousClock.now - start)
            #expect(index.count == 5010)
        }
        #expect(times.sorted()[2] < .milliseconds(50))
    }
}

// MARK: - Kept across changes

extension TreeIndexTests {
    /// A design with something of every sort an entry depends on: a free screen holding a turned card with a row in it,
    /// a column screen of rows, and on the canvas a group drawn at half size, a turned text and a sticky note.
    private static func mixedDesign() -> (content: TreeContent, ids: MixedIDs) {
        let label = node(.text, CGRect(x: 0, y: 0, width: 80, height: 24))
        let toggle = node(.toggle, CGRect(x: 0, y: 0, width: 51, height: 31))
        var row = node(.group, CGRect(x: 16, y: 60, width: 10, height: 10))
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8, alignment: .center))
        (row.width, row.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
        row.children = [label, toggle]
        let about = node(.body, CGRect(x: 16, y: 16, width: 200, height: 24))
        var card = node(.card, CGRect(x: 20, y: 140, width: 300, height: 160))
        card.rotation = 15
        card.children = [about, row]
        let title = node(.title, CGRect(x: 20, y: 80, width: 228, height: 40))
        var free = TreeScreen(name: "Free", origin: CGPoint(x: 0, y: 0), scale: 1, deviceID: nil)
        free.root.children = [title, card]

        var column = TreeScreen(name: "Column", origin: CGPoint(x: 500, y: 0), scale: 0.5, deviceID: nil)
        column.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .fill))
        column.root.children = (0..<4).map { number in
            var item = node(.group, .zero)
            item.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
            (item.width, item.height) = (LayerNode.Sizing(.fill(weight: 1)), LayerNode.Sizing(.fit))
            item.children = [node(.text, CGRect(x: 0, y: 0, width: 60 + CGFloat(number), height: 24)),
                             node(.toggle, CGRect(x: 0, y: 0, width: 51, height: 31))]
            return item
        }

        var group = node(.group, CGRect(x: 100, y: 1000, width: 200, height: 100))
        group.scale = 0.5
        group.children = [node(.shape, CGRect(x: 0, y: 0, width: 60, height: 40)), node(.shape, CGRect(x: 80, y: 20, width: 40, height: 40))]
        var turned = node(.text, CGRect(x: 400, y: 1000, width: 120, height: 24))
        turned.rotation = 30
        turned.scale = 1
        var note = node(.stickyNote, CGRect(x: 600, y: 1000, width: 150, height: 150))
        note.scale = 1

        var content = TreeContent()
        content.screens = [free, column]
        content.canvas = [group, turned, note]
        TreeRules.apply(to: &content, after: nil)
        return (content, MixedIDs(free: free.id, column: column.id, title: title.id, card: card.id, row: row.id, label: label.id,
                                  toggle: toggle.id, about: about.id, columnRows: column.root.children.map(\.id), group: group.id,
                                  shapes: group.children.map(\.id), turned: turned.id, note: note.id))
    }

    private struct MixedIDs {
        var free, column, title, card, row, label, toggle, about: UUID
        var columnRows: [UUID]
        var group: UUID
        var shapes: [UUID]
        var turned, note: UUID
    }

    /// The store keeps its index across changes and brings it up to date where the design changed: after every change
    /// of a run that moves, turns, locks, hides, retypes, restyles, adds, deletes, reparents, reorders, wraps, unwraps,
    /// rescales, duplicates, adds and takes away a screen, undoes, redoes and puts back a whole design, the index it
    /// gives is the one a fresh build of the design gives.
    @MainActor
    @Test func theStoresKeptIndexIsAFreshBuildAfterEveryChange() throws {
        let (content, ids) = Self.mixedDesign()
        let store = DesignStore(content: content)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        var checked = 0
        func check(_ what: String) {
            let kept = store.index, fresh = TreeIndex(store.tree)
            #expect(kept == fresh, "after \(what)")
            #expect(kept.count == fresh.count, "after \(what)")
            checked += 1
        }
        check("nothing")
        store.update(ids.title) { $0.frame.origin.x += 7 }
        check("a move")
        store.update(ids.card) { $0.rotation = 40 }
        check("a container turned")
        store.update(ids.card) { $0.isLocked = true }
        check("a container locked")
        store.update(ids.row) { $0.isHidden = true }
        check("a row hidden")
        store.update(ids.row) { $0.isHidden = false }
        check("a row shown")
        store.update(ids.label) { $0.content.text = "A much longer label than before" }
        check("a text in a row")
        store.update(ids.toggle) { $0.style.tint = RGBColor(hex: 0xFF3B30) }
        check("a look")
        let added = Self.node(.text, CGRect(x: 0, y: 0, width: 40, height: 24))
        #expect(store.add(added, to: .node(ids.columnRows[1]), at: 0))
        check("an add to a row")
        store.delete(nodes: [ids.about])
        check("a delete")
        #expect(store.move(added.id, to: .node(ids.columnRows[3])))
        check("a move to another row")
        #expect(store.move(ids.title, to: .canvas))
        check("a move to the canvas")
        store.reorder([.screen(ids.column): Array(ids.columnRows.reversed())])
        check("a reorder")
        let wrapper = try #require(store.wrap(Array(ids.columnRows[0...1]), in: .group, layout: .free))
        check("a wrap")
        #expect(!store.unwrap(wrapper).isEmpty)
        check("an unwrap")
        store.update(ids.group) { $0.scale = 0.75 }
        check("a canvas node's scale")
        store.update(ids.turned) { $0.rotation = 0 }
        check("a canvas node turned upright")
        _ = try #require(store.duplicate(node: ids.group))
        check("a duplicate")
        var screen = TreeScreen(name: "Added", origin: CGPoint(x: 1000, y: 0), scale: 1, deviceID: nil)
        screen.root.children = [Self.node(.body, CGRect(x: 20, y: 20, width: 100, height: 40))]
        _ = try #require(store.addScreen(screen))
        check("a screen added")
        store.deleteScreen(ids.free)
        check("a screen taken away")
        undo.undo()
        check("an undo")
        undo.undo()
        check("another undo")
        undo.redo()
        check("a redo")
        store.restore(content)
        check("a whole design put back")
        #expect(checked == 24)
    }

    /// Brought up to date in place where only frames, angles, locks and hides change; and refused, to be built again,
    /// for an index of a design that holds an id twice, and for a change that gives an id twice.
    @Test func anIndexIsBroughtUpToDateOnlyWhereItCanBe() {
        let (content, ids) = Self.mixedDesign()
        var moved = content
        moved.screens[0].root.children[1].frame.origin.y += 30
        moved.screens[0].root.children[1].isLocked = true
        moved.canvas[0].scale = 2
        var index = TreeIndex(content)
        let refreshed = index.refresh(from: content, to: moved)
        #expect(refreshed)
        #expect(index == TreeIndex(moved))
        #expect(index[ids.label]?.isLockedWithAncestors == true)

        var twice = moved
        var copy = twice.canvas[1]
        copy.frame.origin.x += 500
        twice.canvas.append(copy)
        var refused = TreeIndex(moved)
        let givenTwice = refused.refresh(from: moved, to: twice)
        #expect(!givenTwice, "a change that gives an id twice")
        let damaged = TreeIndex(twice)
        #expect(!damaged.isClean)
        var fromDamaged = damaged
        let fromTwice = fromDamaged.refresh(from: twice, to: moved)
        #expect(!fromTwice, "an index of a design holding an id twice")
    }
}

private final class BundleMarker {}
