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

private func leaf(_ kind: ElementKind = .text, _ frame: CGRect, text: String = "Text") -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    node.content.text = text
    return node
}

/// A container sized to fit on both axes.
private func container(_ kind: ElementKind = .group, _ layout: LayerNode.Layout? = nil, frame: CGRect = .zero,
                       _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.layout = layout
    node.frame = frame
    node.width = LayerNode.Sizing(.fit)
    node.height = LayerNode.Sizing(.fit)
    node.children = children
    return node
}

/// An iPhone screen at the canvas's origin, drawn at its own size, so that its points are the canvas's.
private func screen(_ children: [LayerNode], layout: LayerNode.Layout? = nil) -> TreeScreen {
    var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
    screen.root.layout = layout
    screen.root.children = children
    return screen
}

private func design(_ screens: [TreeScreen], canvas: [LayerNode] = []) -> TreeContent {
    var content = TreeContent()
    content.screens = screens
    content.canvas = canvas
    return content
}

private func column(spacing: CGFloat = 12) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .vertical, spacing: spacing))
}

private func row(spacing: CGFloat = 8) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .horizontal, spacing: spacing))
}

private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: CGFloat = 0.001) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

/// The store's verbs on the tree, which plan 3 builds on: each is one change, and what the tree
/// can't hold is refused (plan 2, Task 9).
@Suite("The tree's verbs")
@MainActor
struct TreeVerbTests {
    // MARK: Add and replace

    @Test func addingASubtreeKeepsItsIDsAndLaysItOut() throws {
        let title = leaf(.title, CGRect(x: 0, y: 0, width: 200, height: 40), text: "Settings")
        let (store, undo) = makeStore(design([screen([title], layout: column())]))
        var texts = ["One", "Two", "Three"].map { leaf(.text, .zero, text: $0) }
        for index in texts.indices {
            texts[index].width = LayerNode.Sizing(.fit)
            texts[index].height = LayerNode.Sizing(.fit)
        }
        let added = container(.group, row(), texts)
        let screenID = try #require(store.tree.screens.first?.id)
        let before = store.tree

        #expect(store.add(added, to: .screen(screenID)))

        let root = try #require(store.tree.screens.first?.root)
        let kept = try #require(root.children.last)
        #expect(root.children.map(\.id) == [title.id, added.id])
        #expect(TreeEdit.ids(in: kept) == TreeEdit.ids(in: added))
        // The engine's frames, as a full layout of the same tree gives them.
        var expected = before
        expected.screens[0].root.children.append(added)
        TreeRules.apply(to: &expected, after: nil)
        #expect(root == expected.screens[0].root)
        #expect(kept.children.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })

        undo.undo()
        #expect(store.tree == before)
        #expect(!undo.canUndo)
    }

    @Test func replacingAScreensChildrenIsOneStep() throws {
        let olds = (0..<3).map { leaf(.text, CGRect(x: 20, y: 100 + 40 * CGFloat($0), width: 120, height: 20)) }
        let news = (0..<2).map { leaf(.button, CGRect(x: 20, y: 300 + 60 * CGFloat($0), width: 160, height: 44)) }
        let (store, undo) = makeStore(design([screen(olds)]))
        let screenID = try #require(store.tree.screens.first?.id)

        #expect(store.replaceChildren(of: .screen(screenID), with: news))
        #expect(store.tree.screens.first?.root.children.map(\.id) == news.map(\.id))

        undo.undo()
        #expect(store.tree.screens.first?.root.children.map(\.id) == olds.map(\.id))
        #expect(!undo.canUndo)
    }

    @Test func addsTheTreeCantHoldAreRefused() throws {
        let text = leaf(.text, CGRect(x: 20, y: 100, width: 80, height: 20))
        let notes = container(.group, frame: CGRect(x: 600, y: 0, width: 300, height: 150),
                              [leaf(.stickyNote, CGRect(x: 0, y: 0, width: 150, height: 150)),
                               leaf(.stickyNote, CGRect(x: 150, y: 0, width: 150, height: 150))])
        let (store, undo) = makeStore(design([screen([text])], canvas: [notes]))
        let screenID = try #require(store.tree.screens.first?.id)
        let before = store.tree
        var again = leaf(.text, CGRect(x: 20, y: 200, width: 80, height: 20))
        again.id = text.id
        let drawing = leaf(.drawing, CGRect(x: 0, y: 0, width: 40, height: 40))

        #expect(!store.add(again, to: .screen(screenID)))
        #expect(!store.add(leaf(.stickyNote, CGRect(x: 0, y: 0, width: 150, height: 150)), to: .screen(screenID)))
        #expect(!store.add(drawing, to: .node(notes.id)))
        #expect(!store.add(leaf(.text, .zero), to: .screen(UUID())))
        #expect(!store.add(leaf(.text, .zero), to: .node(text.id)))
        #expect(!store.replaceChildren(of: .screen(screenID), with: [leaf(.text, .zero), again, again]))

        #expect(store.tree == before)
        #expect(!undo.canUndo)
        #expect(store.add(drawing, to: .canvas))
    }

    @Test func aScreenIsAddedInOneStepAndOnlyOnce() throws {
        let (store, undo) = makeStore(design([]))
        var made = TreeScreen(name: "Made", origin: CGPoint(x: 500, y: 0), scale: 0.5, deviceID: nil)
        made.root.layout = column()
        made.root.children = [leaf(.title, CGRect(x: 0, y: 0, width: 200, height: 40), text: "Hello")]

        #expect(store.addScreen(made) == made.id)
        #expect(store.addScreen(made) == nil)

        #expect(store.tree.screens.map(\.id) == [made.id])
        #expect(store.device(of: made.id) == .iPhone)
        undo.undo()
        #expect(store.tree.screens.isEmpty)
        #expect(!undo.canUndo)
    }

    @Test func anUpdateKeepsTheIDAndWhatIsHeld() throws {
        let a = leaf(.text, CGRect(x: 0, y: 0, width: 40, height: 20))
        let b = leaf(.text, CGRect(x: 0, y: 40, width: 40, height: 20))
        let g = container(.group, frame: CGRect(x: 20, y: 100, width: 40, height: 60), [a, b])
        let (store, undo) = makeStore(design([screen([g])]))

        store.update(g.id) { node in
            node.id = UUID()
            node.children = []
            node.name = "Pair"
        }

        #expect(store.node(g.id)?.name == "Pair")
        #expect(store.node(g.id)?.children.map(\.id) == [a.id, b.id])
        undo.undo()
        #expect(store.node(g.id)?.name == nil)
    }

    /// A kind changes within its sort: a leaf's to a leaf's, a container's to a container's. A leaf
    /// made a group would be an empty group, which the rules would take away with the leaf; a
    /// container made a leaf would hold what a leaf can't. The rest of the change is made.
    @Test func anUpdateKeepsAKindWithinItsSort() throws {
        let a = leaf(.text, CGRect(x: 0, y: 0, width: 40, height: 20))
        let b = leaf(.text, CGRect(x: 0, y: 40, width: 40, height: 20))
        let g = container(.group, frame: CGRect(x: 20, y: 100, width: 40, height: 60), [a, b])
        let lone = leaf(.text, CGRect(x: 200, y: 200, width: 40, height: 20))
        let (store, _) = makeStore(design([screen([g, lone])]))

        store.update(lone.id) { node in
            node.kind = .group
            node.name = "Was a leaf"
        }
        let kept = try #require(store.node(lone.id))
        #expect(kept.kind == .text)
        #expect(kept.name == "Was a leaf")

        store.update(g.id) { $0.kind = .button }
        #expect(store.node(g.id)?.kind == .group)
        #expect(store.node(g.id)?.children.map(\.id) == [a.id, b.id])

        store.update(lone.id) { $0.kind = .title }
        #expect(store.node(lone.id)?.kind == .title)
        store.update(g.id) { $0.kind = .card }
        #expect(store.node(g.id)?.kind == .card)
        #expect(store.node(g.id)?.children.map(\.id) == [a.id, b.id])
    }

    /// A screen the design can't take is refused with nil, never an id: refused for its id, the id
    /// it brought names the screen already there, and a caller writing to it would write there.
    @Test func aRefusedScreenGivesNoID() throws {
        let (store, _) = makeStore(design([screen([leaf(.title, CGRect(x: 0, y: 0, width: 200, height: 40), text: "First")])]))
        let first = try #require(store.tree.screens.first)
        var sameID = TreeScreen(name: "Another", origin: CGPoint(x: 500, y: 0), scale: 1, deviceID: nil)
        sameID.id = first.id
        var holdingADrawing = TreeScreen(name: "Ink", origin: CGPoint(x: 1000, y: 0), scale: 1, deviceID: nil)
        holdingADrawing.root.children = [leaf(.drawing, CGRect(x: 0, y: 0, width: 50, height: 50))]
        let before = store.tree

        #expect(store.addScreen(sameID) == nil)
        #expect(store.addScreen(holdingADrawing) == nil)

        #expect(store.tree == before)
        #expect(store.tree.screens.first?.name == first.name)
    }

    // MARK: Move

    @Test func movingKeepsThePlaceOnTheCanvasInAFreeParent() throws {
        let x = leaf(.text, CGRect(x: 40, y: 40, width: 20, height: 20))
        let y = leaf(.text, CGRect(x: 0, y: 0, width: 10, height: 10))
        let g = container(.group, frame: CGRect(x: 60, y: 60, width: 60, height: 60), [y, x])
        let (store, _) = makeStore(design([screen([g])]))
        let screenID = try #require(store.tree.screens.first?.id)
        #expect(store.index[x.id]?.hostShape.rect == CGRect(x: 100, y: 100, width: 20, height: 20))
        #expect(store.parent(of: x.id) == .node(g.id))

        #expect(store.move(x.id, to: .screen(screenID)))

        let moved = try #require(store.tree.screens.first?.root.children.first { $0.id == x.id })
        #expect(moved.frame == CGRect(x: 100, y: 100, width: 20, height: 20))
        #expect(store.parent(of: x.id) == .screen(screenID))
    }

    @Test func movingIntoARowTakesTheIndex() throws {
        let cells = (0..<3).map { leaf(.text, CGRect(x: 0, y: 0, width: 40, height: 20), text: "\($0)") }
        let line = container(.group, row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), cells)
        let t = leaf(.text, CGRect(x: 20, y: 300, width: 60, height: 20), text: "T")
        let (store, _) = makeStore(design([screen([line, t])]))
        #expect(store.isLaidOut(line.id))
        #expect(!store.isLaidOut(t.id))

        #expect(store.move(t.id, to: .node(line.id), at: 1))

        #expect(store.node(line.id)?.children.map(\.id) == [cells[0].id, t.id, cells[1].id, cells[2].id])
        #expect(store.parent(of: t.id) == .node(line.id))
    }

    @Test func movingBetweenHostsKeepsItsPlaceOnTheCanvas() throws {
        let t = leaf(.text, CGRect(x: 100, y: 200, width: 40, height: 20))
        var drawn = screen([t])
        drawn.origin = CGPoint(x: 400, y: 100)
        drawn.scale = 0.5
        let (store, _) = makeStore(design([drawn]))

        #expect(store.move(t.id, to: .canvas))

        #expect(store.parent(of: t.id) == .canvas)
        #expect(store.node(t.id)?.scale == 0.5)
        #expect(store.node(t.id)?.frame == CGRect(x: 900, y: 400, width: 40, height: 20))
        #expect(store.index[t.id]?.hostShape.rect == CGRect(x: 450, y: 200, width: 20, height: 10))

        #expect(store.move(t.id, to: .screen(drawn.id)))

        #expect(store.node(t.id)?.scale == nil)
        #expect(store.node(t.id)?.frame == t.frame)
    }

    @Test func movesTheTreeCantHoldAreRefused() throws {
        // A free container holding another, which holds two things.
        let inner = container(.group, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                              [leaf(.text, CGRect(x: 0, y: 0, width: 40, height: 20)), leaf(.text, CGRect(x: 0, y: 40, width: 40, height: 20))])
        let outer = container(.group, frame: CGRect(x: 20, y: 100, width: 200, height: 200),
                              [inner, leaf(.text, CGRect(x: 120, y: 0, width: 40, height: 20))])
        // Columns 1 to 32 deep, the deepest empty: whatever goes in it would be at 33.
        var deepest = container(.group, column(), [])
        for _ in 1..<TreeRules.maximumDepth { deepest = container(.group, column(), [deepest]) }
        let chainIDs = TreeEdit.ids(in: deepest)
        let t = leaf(.text, CGRect(x: 20, y: 400, width: 40, height: 20))
        let note = leaf(.stickyNote, CGRect(x: 600, y: 0, width: 150, height: 150), text: "Note")
        let (store, undo) = makeStore(design([screen([outer, deepest, t])], canvas: [note]))
        let screenID = try #require(store.tree.screens.first?.id)
        let last = try #require(chainIDs.last)
        #expect(store.index[last]?.depth == TreeRules.maximumDepth)
        let before = store.tree

        #expect(!store.move(outer.id, to: .node(inner.id)))
        #expect(!store.move(outer.id, to: .node(outer.id)))
        #expect(!store.move(note.id, to: .screen(screenID)))
        #expect(!store.move(t.id, to: .node(last)))

        #expect(store.tree == before)
        #expect(!undo.canUndo)
        // One level less is held.
        #expect(store.move(t.id, to: .node(chainIDs[chainIDs.count - 2])))
    }

    // MARK: Wrap

    @Test func wrappingInAFreeGroupMovesNothing() throws {
        let a = leaf(.text, CGRect(x: 20, y: 20, width: 50, height: 30))
        let b = leaf(.text, CGRect(x: 100, y: 100, width: 40, height: 40))
        let c = leaf(.text, CGRect(x: 200, y: 50, width: 60, height: 20))
        let (store, undo) = makeStore(design([screen([a, b, c])]))

        let g = try #require(store.wrap([a.id, c.id], in: .group, layout: .free))

        #expect(store.tree.screens.first?.root.children.map(\.id) == [b.id, g])
        let group = try #require(store.node(g))
        #expect(group.children.map(\.id) == [a.id, c.id])
        #expect(group.layout == nil)
        #expect(store.index[a.id]?.hostShape.rect == a.frame)
        #expect(store.index[c.id]?.hostShape.rect == c.frame)
        #expect(group.width.mode == .fit && group.height.mode == .fit)
        #expect(store.index[g]?.hostShape.rect == a.frame.union(c.frame))
        undo.undo()
        #expect(store.tree.screens.first?.root.children.map(\.id) == [a.id, b.id, c.id])
        #expect(!undo.canUndo)
    }

    @Test func wrappingAsARowSortsByXAndFixesSizes() throws {
        var texts = [CGRect(x: 200, y: 100, width: 60, height: 20), CGRect(x: 20, y: 100, width: 50, height: 22),
                     CGRect(x: 110, y: 104, width: 40, height: 18)].map { leaf(.text, $0) }
        for index in texts.indices { texts[index].width = LayerNode.Sizing(.fit) }
        let (store, _) = makeStore(design([screen(texts)]))

        let r = try #require(store.wrap(texts.map(\.id), in: .group, layout: row()))

        let made = try #require(store.node(r))
        #expect(made.children.map(\.id) == [texts[1].id, texts[2].id, texts[0].id])
        #expect(made.children.map(\.frame.size) == [texts[1].frame.size, texts[2].frame.size, texts[0].frame.size])
        #expect(made.children.allSatisfy { $0.width.mode == .fixed && $0.height.mode == .fixed })
        #expect(store.isLaidOut(r))
    }

    @Test func wrappingAsAGridReadsRowByRow() throws {
        let cells = [CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 60), CGPoint(x: 0, y: 60)]
            .map { leaf(.image, CGRect(origin: $0, size: CGSize(width: 50, height: 50))) }
        let (store, _) = makeStore(design([screen(cells)]))

        let grid = try #require(store.wrap(cells.map(\.id), in: .group,
                                           layout: .grid(LayerNode.Grid(columns: 2, columnSpacing: 12, rowSpacing: 12))))

        #expect(store.node(grid)?.children.map(\.id) == [cells[1].id, cells[0].id, cells[3].id, cells[2].id])
    }

    @Test func aCardTakesItsPaddingFromTheDesignsTokens() throws {
        let a = leaf(.text, CGRect(x: 40, y: 100, width: 80, height: 20))
        let b = leaf(.text, CGRect(x: 40, y: 140, width: 80, height: 20))
        var tree = design([screen([a, b])])
        tree.settings.tokens.card.padding = 24
        let (store, _) = makeStore(tree)

        let card = try #require(store.wrap([a.id, b.id], in: .card, layout: column(spacing: 8)))

        #expect(store.node(card)?.kind == .card)
        #expect(store.node(card)?.padding == LayerNode.Padding(all: 24))
    }

    @Test func wrappingThingsOfTwoParentsIsRefused() throws {
        let a = leaf(.text, CGRect(x: 20, y: 20, width: 40, height: 20))
        let b = leaf(.text, CGRect(x: 20, y: 60, width: 40, height: 20))
        let g = container(.group, frame: CGRect(x: 20, y: 100, width: 40, height: 60), [a, b])
        let c = leaf(.text, CGRect(x: 200, y: 100, width: 40, height: 20))
        let (store, undo) = makeStore(design([screen([g, c])]))
        let before = store.tree

        #expect(store.wrap([a.id, c.id], in: .group, layout: .free) == nil)
        #expect(store.wrap([], in: .group, layout: .free) == nil)

        #expect(store.tree == before)
        #expect(!undo.canUndo)
    }

    @Test func wrappingOnTheCanvasTakesTheFrontmostScaleAndMovesNothing() throws {
        var a = leaf(.text, CGRect(x: 0, y: 0, width: 100, height: 50))
        a.scale = 1
        var b = leaf(.text, CGRect(x: 100, y: 100, width: 50, height: 25))
        b.scale = 2
        let (store, _) = makeStore(design([], canvas: [a, b]))

        let g = try #require(store.wrap([a.id, b.id], in: .group, layout: .free))

        #expect(store.node(g)?.scale == 2)
        #expect(store.node(g)?.children.allSatisfy { $0.scale == nil } == true)
        #expect(store.index[a.id]?.hostShape.rect == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(store.index[b.id]?.hostShape.rect == CGRect(x: 200, y: 200, width: 100, height: 50))
        #expect(store.index[g]?.hostShape.rect == CGRect(x: 0, y: 0, width: 300, height: 250))
    }

    // MARK: Unwrap and layout

    @Test func unwrappingBakesTheTurnAndPassesLockAndHideDown() throws {
        var t1 = leaf(.text, CGRect(x: 0, y: 0, width: 60, height: 20))
        t1.rotation = 10
        let t2 = leaf(.text, CGRect(x: 80, y: 40, width: 40, height: 40))
        var g = container(.group, frame: CGRect(x: 100, y: 200, width: 120, height: 80), [t1, t2])
        g.rotation = 90
        g.isLocked = true
        g.isHidden = true
        let (store, undo) = makeStore(design([screen([g])]))
        let centres = try [t1.id, t2.id].map { try #require(store.index[$0]?.hostShape.centre) }

        let released = store.unwrap(g.id)

        #expect(released == [t1.id, t2.id])
        #expect(store.node(g.id) == nil)
        for (id, centre) in zip(released, centres) {
            #expect(close(try #require(store.index[id]?.hostShape.centre), centre))
        }
        #expect(store.node(t1.id)?.rotation == 100)
        #expect(store.node(t2.id)?.rotation == 90)
        #expect([t1.id, t2.id].allSatisfy { store.node($0)?.isLocked == true && store.node($0)?.isHidden == true })
        undo.undo()
        #expect(store.node(g.id)?.children.map(\.id) == [t1.id, t2.id])
    }

    @Test func unwrappingIntoAColumnJoinsAtTheSlot() throws {
        let a = leaf(.text, CGRect(x: 0, y: 0, width: 100, height: 20))
        let t1 = leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))
        let t2 = leaf(.text, CGRect(x: 0, y: 30, width: 80, height: 30))
        let g = container(.group, nil, [t1, t2])
        let c = leaf(.text, CGRect(x: 0, y: 0, width: 100, height: 20))
        let (store, _) = makeStore(design([screen([a, g, c], layout: column(spacing: 12))]))

        #expect(store.unwrap(g.id) == [t1.id, t2.id])

        let root = try #require(store.tree.screens.first?.root)
        #expect(root.children.map(\.id) == [a.id, t1.id, t2.id, c.id])
        for (above, below) in zip(root.children, root.children.dropFirst()) {
            #expect(below.frame.minY == above.frame.maxY + 12)
        }
    }

    @Test func settingAColumnOnAScreenRootSortsTopToBottom() throws {
        var texts = [CGRect(x: 40, y: 300, width: 60, height: 20), CGRect(x: 80, y: 100, width: 90, height: 24),
                     CGRect(x: 20, y: 200, width: 120, height: 30)].map { leaf(.text, $0) }
        for index in texts.indices { texts[index].width = LayerNode.Sizing(.fit) }
        let (store, _) = makeStore(design([screen(texts)]))
        let rootID = try #require(store.tree.screens.first?.root.id)

        store.setLayout(rootID, column())

        let root = try #require(store.tree.screens.first?.root)
        #expect(root.children.map(\.id) == [texts[1].id, texts[2].id, texts[0].id])
        #expect(root.children.map(\.frame.size) == [texts[1].frame.size, texts[2].frame.size, texts[0].frame.size])
        #expect(root.children.allSatisfy { $0.width.mode == .fixed && $0.height.mode == .fixed })
        #expect(store.isLaidOut(rootID))
    }

    // MARK: Reconcile

    #if DEBUG
    @Test func reconcileIsOneChangeAndOneRulesPass() throws {
        let line = container(.group, row(), [leaf(.text, CGRect(x: 0, y: 0, width: 40, height: 20), text: "A"),
                                             leaf(.text, CGRect(x: 0, y: 0, width: 40, height: 20), text: "B")])
        let card = container(.card, column(spacing: 8), [leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20), text: "C")])
        let (store, undo) = makeStore(design([screen([line, card], layout: column())]))
        let screenID = try #require(store.tree.screens.first?.id)
        let rootID = try #require(store.tree.screens.first?.root.id)
        let containers = [rootID, line.id, card.id]
        let before = containers.map(LayoutEngine.timesLaidOut)

        #expect(store.reconcile(screenID) { root in root.children[0].children[0].content.text = "Changed" })

        #expect(zip(containers.map(LayoutEngine.timesLaidOut), before).map(-) == [1, 1, 0])
        #expect(store.node(line.children[0].id)?.content.text == "Changed")
        undo.undo()
        #expect(store.node(line.children[0].id)?.content.text == "A")
        #expect(!undo.canUndo)
        #expect(!store.reconcile(UUID()) { _ in })
    }
    #endif

    @Test func reconcileRefusesWhatGoesDeeperThan32() throws {
        let target = screen([leaf(.text, CGRect(x: 20, y: 100, width: 80, height: 20))])
        let (store, undo) = makeStore(design([target]))
        let before = store.tree
        // A leaf 32 below its top: 33 below the root.
        var deep = leaf(.text, CGRect(x: 0, y: 0, width: 40, height: 20))
        for _ in 0..<TreeRules.maximumDepth { deep = container(.group, column(), [deep]) }
        let tooDeep = deep

        #expect(!store.reconcile(target.id) { root in root.children = [tooDeep] })
        #expect(store.tree == before)
        #expect(!undo.canUndo)
        #expect(store.reconcile(target.id) { root in root.children = [tooDeep.children[0]] })
    }

    @Test func reconcileRefusesADesignOfMoreThan5000Nodes() throws {
        // 2 roots, 1 text and 4,990 leaves: 4,993 nodes.
        let crowd = (0..<4_990).map { _ in leaf(.text, CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let target = screen([leaf(.text, CGRect(x: 20, y: 100, width: 80, height: 20))])
        let (store, undo) = makeStore(design([target, screen(crowd)]))
        let before = store.tree
        func texts(_ count: Int) -> [LayerNode] {
            (0..<count).map { leaf(.text, CGRect(x: 20, y: 140 + 30 * CGFloat($0), width: 80, height: 20)) }
        }

        #expect(!store.reconcile(target.id) { root in root.children += texts(8) })
        #expect(store.tree == before)
        #expect(!undo.canUndo)
        #expect(store.reconcile(target.id) { root in root.children += texts(7) })
        #expect(store.index.count == TreeRules.maximumNodes)
    }

    @Test func reconcileNeverHoldsAnIDTwice() throws {
        let kept = leaf(.text, CGRect(x: 20, y: 100, width: 80, height: 20))
        let elsewhere = leaf(.text, CGRect(x: 20, y: 100, width: 80, height: 20))
        let target = screen([kept])
        let other = screen([elsewhere])
        let (store, _) = makeStore(design([target, other]))
        let rootID = try #require(store.tree.screens.first?.root.id)

        #expect(store.reconcile(target.id) { root in
            var stray = leaf(.button, CGRect(x: 20, y: 200, width: 120, height: 44))
            stray.id = elsewhere.id
            var twin = leaf(.title, CGRect(x: 20, y: 300, width: 120, height: 40))
            twin.id = kept.id
            root.children += [stray, twin]
            root.id = UUID()
        })

        let root = try #require(store.tree.screens.first?.root)
        let ids = root.children.map(\.id)
        #expect(root.id == rootID)
        #expect(ids.count == 3 && Set(ids).count == 3)
        #expect(ids.first == kept.id)
        #expect(!ids.contains(elsewhere.id))
        #expect(root.children.map(\.kind) == [.text, .button, .title])
        #expect(store.index[elsewhere.id]?.host == .screen(other.id))
        #expect(store.index.count == 2 + 4)
    }

    // MARK: Duplicate and delete

    @Test func aDuplicatedContainerHasNewIDsThroughout() throws {
        let inner = container(.card, column(spacing: 8), [leaf(.text, CGRect(x: 0, y: 0, width: 60, height: 20)),
                                                          leaf(.text, CGRect(x: 0, y: 0, width: 60, height: 20))])
        var original = container(.group, frame: CGRect(x: 40, y: 120, width: 0, height: 0),
                                 [leaf(.text, CGRect(x: 0, y: 0, width: 50, height: 20)), inner])
        original.isLocked = true
        let (store, undo) = makeStore(design([screen([original, leaf(.text, CGRect(x: 20, y: 500, width: 40, height: 20))])]))
        let kept = try #require(store.node(original.id))

        let copyID = try #require(store.duplicate(node: original.id))

        let copy = try #require(store.node(copyID))
        #expect(Set(TreeEdit.ids(in: copy)).isDisjoint(with: TreeEdit.ids(in: kept)))
        #expect(TreeEdit.ids(in: copy).count == TreeEdit.ids(in: kept).count)
        #expect(copy.frame == kept.frame.offsetBy(dx: 16, dy: 16))
        #expect(!copy.isLocked)
        // On top of what is on the screen.
        #expect(store.tree.screens.first?.root.children.last?.id == copyID)
        undo.undo()
        #expect(store.node(copyID) == nil)
        #expect(store.duplicate(node: try #require(store.tree.screens.first?.root.id)) == nil)
    }

    @Test func aDuplicatedDrawingHasStrokesOfItsOwn() throws {
        let points = (0...4).map { step in
            PKStrokePoint(location: CGPoint(x: 10 * CGFloat(step), y: 0), timeOffset: 0.01 * Double(step),
                          size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                              path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 700_000_000)))
        var drawing = LayerNode(kind: .drawing)
        drawing.frame = CGRect(x: 100, y: 100, width: 40, height: 4)
        drawing.content.ink = PKDrawing(strokes: [stroke]).dataRepresentation()
        let (store, _) = makeStore(design([], canvas: [drawing]))

        let copy = try #require(store.duplicate(node: drawing.id))

        let ink = try #require(store.node(copy)?.content.ink)
        let keys = try PKDrawing(data: ink).strokes.map(\.key)
        #expect(keys.count == 1)
        #expect(keys != [stroke.key])
        #expect(store.tree.canvas.last?.id == copy)
    }

    #if DEBUG
    @Test func deletingAContainerTakesItsSubtreeAndTellsTheLogOnce() throws {
        let a = leaf(.text, CGRect(x: 0, y: 0, width: 40, height: 20))
        let b = leaf(.text, CGRect(x: 0, y: 40, width: 40, height: 20))
        let g = container(.group, frame: CGRect(x: 20, y: 100, width: 40, height: 60), [a, b])
        let c = leaf(.text, CGRect(x: 200, y: 100, width: 40, height: 20))
        let (store, undo) = makeStore(design([screen([g, c])]))
        let rootID = try #require(store.tree.screens.first?.root.id)
        let tasks = CanvasWork.readingLogTasks

        store.delete(nodes: [g.id, a.id, rootID])

        #expect(CanvasWork.readingLogTasks - tasks == 1)
        #expect(store.tree.screens.first?.root.children.map(\.id) == [c.id])
        #expect([g.id, a.id, b.id].allSatisfy { store.node($0) == nil })
        undo.undo()
        #expect(store.tree.screens.first?.root.children.map(\.id) == [g.id, c.id])
        #expect(!undo.canUndo)
    }
    #endif

    // MARK: Screens

    @Test func aLockedScreensNodesAreNotLockedByIt() throws {
        let text = leaf(.text, CGRect(x: 20, y: 100, width: 80, height: 20))
        var locked = screen([container(.group, frame: CGRect(x: 20, y: 100, width: 80, height: 60),
                                       [text, leaf(.text, CGRect(x: 0, y: 40, width: 80, height: 20))])])
        locked.isLocked = true
        let (store, _) = makeStore(design([locked]))

        #expect(store.index[text.id]?.isLockedWithAncestors == false)
    }

    @Test func aScreenOnACustomDeviceResolvesIt() throws {
        let frame = DeviceFrame.custom(name: "Kiosk", size: CGSize(width: 600, height: 400), family: .other)
        var custom = screen([leaf(.text, CGRect(x: 20, y: 20, width: 80, height: 20))])
        custom.deviceID = frame.id
        var tree = design([custom])
        tree.settings.customDevices = [frame]
        let (store, _) = makeStore(tree)

        #expect(store.device(of: custom.id) == frame)
        #expect(store.screen(custom.id)?.device == frame)
        #expect(store.device(of: UUID()) == nil)
    }

    /// The content's own view of one screen resolves its device as the store's views do.
    @Test func theContentsViewOfAScreenResolvesItsCustomDevice() throws {
        let frame = DeviceFrame.custom(name: "Kiosk", size: CGSize(width: 600, height: 400), family: .other)
        var custom = screen([leaf(.text, CGRect(x: 20, y: 20, width: 80, height: 20))])
        custom.deviceID = frame.id
        var tree = design([custom])
        tree.settings.customDevices = [frame]
        let (store, _) = makeStore(tree)

        #expect(store.content.screen(custom.id)?.device == frame)
        #expect(store.content.screen(custom.id) == store.screen(custom.id))
    }
}
