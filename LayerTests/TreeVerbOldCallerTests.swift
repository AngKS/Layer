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

private func leaf(_ frame: CGRect, _ kind: ElementKind = .text) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    node.content.text = "Text"
    return node
}

/// A container sized to fit on both axes.
private func container(_ layout: LayerNode.Layout?, frame: CGRect = .zero, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: .group)
    node.layout = layout
    node.frame = frame
    node.width = LayerNode.Sizing(.fit)
    node.height = LayerNode.Sizing(.fit)
    node.children = children
    return node
}

/// An iPhone screen at the canvas's origin, drawn at its own size.
private func design(_ children: [LayerNode], layout: LayerNode.Layout? = nil) -> TreeContent {
    var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
    screen.root.layout = layout
    screen.root.children = children
    var content = TreeContent()
    content.screens = [screen]
    return content
}

private func column(spacing: CGFloat = 12) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .vertical, spacing: spacing))
}

private func row(spacing: CGFloat = 8) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .horizontal, spacing: spacing))
}

/// Delete, duplicate, group and ungroup, which today's callers reach through `ElementRef`s and
/// selections, made with the tree's verbs, so that a row or a card survives them (plan 2, Task 10).
@Suite("Old callers on the tree's verbs")
@MainActor
struct TreeVerbOldCallerTests {
    @Test func ungroupingAGroupInsideARowJoinsTheRow() throws {
        let a = leaf(CGRect(x: 0, y: 0, width: 60, height: 20))
        let t1 = leaf(CGRect(x: 0, y: 0, width: 50, height: 20))
        let t2 = leaf(CGRect(x: 60, y: 0, width: 40, height: 20))
        let g = container(nil, [t1, t2])
        let c = leaf(CGRect(x: 0, y: 0, width: 70, height: 20))
        let r = container(row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), [a, g, c])
        let (store, undo) = makeStore(design([r]))
        let screenID = try #require(store.tree.screens.first?.id)
        func ref(_ id: UUID) -> DesignStore.ElementRef { .init(host: .screen(screenID), element: id) }

        let members = try #require(store.ungroup(ref(g.id)))

        #expect(members == CanvasSelection([t1, t2].map { .element(ref($0.id)) }))
        let laid = try #require(store.node(r.id))
        #expect(laid.layout == row())
        #expect(laid.children.map(\.id) == [a.id, t1.id, t2.id, c.id])
        // Laid out along the row, 8 apart.
        for (before, after) in zip(laid.children, laid.children.dropFirst()) {
            #expect(after.frame.minX == before.frame.maxX + 8)
        }

        undo.undo()
        #expect(store.node(r.id)?.children.map(\.id) == [a.id, g.id, c.id])
    }

    @Test func duplicatingARowChildPutsTheCopyNextInTheRow() throws {
        let a = leaf(CGRect(x: 0, y: 0, width: 60, height: 20))
        let b = leaf(CGRect(x: 0, y: 0, width: 50, height: 20))
        let c = leaf(CGRect(x: 0, y: 0, width: 70, height: 20))
        let r = container(row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), [a, b, c])
        let (store, undo) = makeStore(design([r]))
        let screenID = try #require(store.tree.screens.first?.id)

        let copy = try #require(store.duplicate(.init(host: .screen(screenID), element: b.id)))

        #expect(copy.host == .screen(screenID))
        let laid = try #require(store.node(r.id))
        #expect(laid.children.map(\.id) == [a.id, b.id, copy.element, c.id])
        #expect(laid.children[2].frame.minX == laid.children[1].frame.maxX + 8)

        undo.undo()
        #expect(store.node(r.id)?.children.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func deletingARowTakesItsChildrenAndLeavesTheColumnLaidOut() throws {
        let t = leaf(CGRect(x: 0, y: 0, width: 100, height: 20))
        let x = leaf(CGRect(x: 0, y: 0, width: 40, height: 30))
        let y = leaf(CGRect(x: 0, y: 0, width: 40, height: 30))
        let r = container(row(), [x, y])
        let u = leaf(CGRect(x: 0, y: 0, width: 100, height: 20))
        let (store, undo) = makeStore(design([t, r, u], layout: column()))
        let screenID = try #require(store.tree.screens.first?.id)

        store.delete(.init(host: .screen(screenID), element: r.id))

        let root = try #require(store.tree.screens.first?.root)
        #expect(root.layout == column())
        #expect(root.children.map(\.id) == [t.id, u.id])
        #expect(store.node(x.id) == nil && store.node(y.id) == nil)
        #expect(root.children[1].frame.minY == root.children[0].frame.maxY + 12)

        undo.undo()
        #expect(store.tree.screens.first?.root.children.map(\.id) == [t.id, r.id, u.id])
    }

    @Test func aGroupMadeFromTheSelectionIsAFreeWrap() throws {
        let things = (0..<5).map { leaf(CGRect(x: 20 + 30 * CGFloat($0), y: 100 + 50 * CGFloat($0), width: 80, height: 20)) }
        let (store, undo) = makeStore(design(things))
        let screenID = try #require(store.tree.screens.first?.id)
        func ref(_ node: LayerNode) -> DesignStore.ElementRef { .init(host: .screen(screenID), element: node.id) }
        let b = try #require(store.canvasFrame(of: .element(ref(things[1]))))
        let d = try #require(store.canvasFrame(of: .element(ref(things[3]))))
        let selection = try #require(CanvasSelection([.element(ref(things[1])), .element(ref(things[3]))]))

        let g = try #require(store.group(selection))

        #expect(g.host == .screen(screenID))
        let node = try #require(store.node(g.element))
        #expect(node.kind == .group)
        #expect(node.layout == nil)
        #expect(node.width.mode == .fit && node.height.mode == .fit)
        #expect(node.children.map(\.id) == [things[1].id, things[3].id])
        // In the frontmost member's slot, once the members have left theirs.
        #expect(store.tree.screens.first?.root.children.map(\.id) == [things[0].id, things[2].id, g.element, things[4].id])
        // Nothing moves.
        #expect(store.canvasFrame(of: .element(ref(things[1]))) == b)
        #expect(store.canvasFrame(of: .element(ref(things[3]))) == d)
        #expect(store.canvasFrame(of: .element(g)) == b.union(d))

        undo.undo()
        #expect(store.tree.screens.first?.root.children.map(\.id) == things.map(\.id))
    }

    @Test func setElementsReplacingKeepsTheScreensRootLayout() throws {
        let olds = (0..<2).map { _ in leaf(CGRect(x: 0, y: 0, width: 120, height: 20)) }
        let (store, undo) = makeStore(design(olds, layout: column()))
        let screenID = try #require(store.tree.screens.first?.id)
        var title = DesignStore.newElement(.title)
        title.frame = CGRect(x: 5, y: 500, width: 200, height: 40)
        var button = DesignStore.newElement(.button)
        button.frame = CGRect(x: 90, y: 30, width: 160, height: 44)

        let refs = store.setElements([title, button], on: screenID, replacing: true)

        #expect(refs == [title, button].map { DesignStore.ElementRef(host: .screen(screenID), element: $0.id) })
        let root = try #require(store.tree.screens.first?.root)
        #expect(root.layout == column())
        #expect(root.children.map(\.id) == [title.id, button.id])
        // Laid out down the column, from the top of its padding, 12 apart.
        #expect(root.children[0].frame.minY == root.padding.top)
        #expect(root.children[1].frame.minY == root.children[0].frame.maxY + 12)

        undo.undo()
        #expect(store.tree.screens.first?.root.children.map(\.id) == olds.map(\.id))
        #expect(!undo.canUndo)
    }

    // MARK: What the flat list tore apart

    @Test func duplicatingARowCopiesItWhole() throws {
        let r = container(row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0),
                          [leaf(CGRect(x: 0, y: 0, width: 60, height: 20)), leaf(CGRect(x: 0, y: 0, width: 50, height: 20))])
        let (store, undo) = makeStore(design([r]))
        let screenID = try #require(store.tree.screens.first?.id)

        let copy = try #require(store.duplicate(.init(host: .screen(screenID), element: r.id)))

        let original = try #require(store.node(r.id))
        let made = try #require(store.node(copy.element))
        #expect(made.kind == .group)
        #expect(made.layout == row())
        #expect(made.width == original.width && made.height == original.height)
        #expect(made.children.map(\.frame) == original.children.map(\.frame))
        #expect(Set(TreeEdit.ids(in: made)).isDisjoint(with: TreeEdit.ids(in: original)))
        #expect(made.frame.origin == CGPoint(x: original.frame.minX + 16, y: original.frame.minY + 16))
        // On top of what is on the screen.
        #expect(store.tree.screens.first?.root.children.map(\.id) == [r.id, copy.element])

        undo.undo()
        #expect(store.tree.screens.first?.root.children.map(\.id) == [r.id])
    }

    @Test func duplicatingACardKeepsItACard() throws {
        var card = container(nil, frame: CGRect(x: 20, y: 100, width: 0, height: 0), [leaf(CGRect(x: 16, y: 16, width: 80, height: 20))])
        card.kind = .card
        card.padding = LayerNode.Padding(all: 16)
        let (store, _) = makeStore(design([card]))
        let screenID = try #require(store.tree.screens.first?.id)

        let copy = try #require(store.duplicate(.init(host: .screen(screenID), element: card.id)))

        let made = try #require(store.node(copy.element))
        #expect(made.kind == .card)
        #expect(made.padding == LayerNode.Padding(all: 16))
        #expect(made.children.count == 1)
    }

    @Test func aCopiedScreenKeepsItsRootsLayoutAndItsRows() throws {
        let t = leaf(CGRect(x: 0, y: 0, width: 100, height: 20))
        let r = container(row(), [leaf(CGRect(x: 0, y: 0, width: 40, height: 30)), leaf(CGRect(x: 0, y: 0, width: 40, height: 30))])
        let (store, undo) = makeStore(design([t, r], layout: column()))
        let original = try #require(store.tree.screens.first)

        let copy = try #require(store.duplicateScreen(original.id))

        #expect(copy.name == "Screen Copy")
        #expect(copy.origin.x == (store.screen(original.id)?.canvasFrame.maxX ?? 0) + 60)
        let made = try #require(store.tree.screens.first { $0.id == copy.id })
        #expect(made.root.layout == column())
        #expect(made.root.children.map(\.kind) == [.text, .group])
        #expect(made.root.children[1].layout == row())
        #expect(made.root.children.map(\.frame) == original.root.children.map(\.frame))
        #expect(made.root.children[1].children.map(\.frame) == original.root.children[1].children.map(\.frame))
        #expect(Set(TreeEdit.ids(in: made.root)).isDisjoint(with: TreeEdit.ids(in: original.root)))

        undo.undo()
        #expect(store.tree.screens.map(\.id) == [original.id])
    }

    /// The tree keeps a sticky note on the canvas, never on a screen: one given to a screen is put on the
    /// canvas where the screen would have shown it, as the tree's rules put it there before.
    @Test func aNoteGivenToAScreenGoesOnTheCanvasWhereItWouldHaveBeen() throws {
        var tree = design([leaf(CGRect(x: 20, y: 100, width: 120, height: 20))])
        tree.screens[0].origin = CGPoint(x: 100, y: 50)
        tree.screens[0].scale = 0.5
        let (store, undo) = makeStore(tree)
        let screenID = try #require(store.tree.screens.first?.id)
        var title = DesignStore.newElement(.title)
        title.frame = CGRect(x: 20, y: 80, width: 200, height: 40)
        var note = DesignStore.newElement(.stickyNote)
        note.frame = CGRect(x: 40, y: 60, width: 150, height: 150)

        let refs = store.setElements([title, note], on: screenID, replacing: true)

        #expect(refs == [.init(host: .screen(screenID), element: title.id), .init(host: .canvas, element: note.id)])
        #expect(store.tree.screens.first?.root.children.map(\.id) == [title.id])
        let landed = try #require(store.tree.canvas.first { $0.id == note.id })
        #expect(landed.frame == CGRect(x: 40 + 100 / 0.5, y: 60 + 50 / 0.5, width: 150, height: 150))
        #expect(landed.scale == 0.5)

        undo.undo()
        #expect(store.tree.canvas.isEmpty)
        #expect(!undo.canUndo)
    }

    /// A group holding something this build couldn't read has no place to put it, so it isn't
    /// ungrouped: nothing changes.
    @Test func aGroupHoldingAnUnreadChildIsntUngrouped() throws {
        var g = container(nil, frame: CGRect(x: 20, y: 100, width: 0, height: 0),
                          [leaf(CGRect(x: 0, y: 0, width: 50, height: 20)), leaf(CGRect(x: 60, y: 0, width: 40, height: 20))])
        g.unreadChildren = [LayerNode.UnreadChild(index: 1, raw: .object(["kind": .string("hologram")]))]
        let (store, undo) = makeStore(design([g]))
        let screenID = try #require(store.tree.screens.first?.id)
        let before = store.tree

        #expect(store.ungroup(.init(host: .screen(screenID), element: g.id)) == nil)

        #expect(store.tree == before)
        #expect(!undo.canUndo)
    }

    /// A row duplicated and a card deleted through the selection, as the canvas's menus do: the
    /// copy is a row, the card goes whole and comes back a card. A card selected with what is in
    /// it is copied once, what is in it with it.
    @Test func aRowAndACardGoThroughTheSelectionWhole() throws {
        let r = container(row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0),
                          [leaf(CGRect(x: 0, y: 0, width: 60, height: 20)), leaf(CGRect(x: 0, y: 0, width: 50, height: 20))])
        let inside = leaf(CGRect(x: 16, y: 16, width: 80, height: 20))
        var card = container(nil, frame: CGRect(x: 20, y: 300, width: 0, height: 0), [inside])
        card.kind = .card
        card.padding = LayerNode.Padding(all: 16)
        let (store, undo) = makeStore(design([r, card]))
        let screenID = try #require(store.tree.screens.first?.id)
        func ref(_ id: UUID) -> DesignStore.ElementRef { .init(host: .screen(screenID), element: id) }

        let rowAlone = try #require(CanvasSelection([.element(ref(r.id))]))
        let copies = try #require(store.duplicate(rowAlone))
        guard case .element(let copyRef) = copies else {
            Issue.record("One row was copied, as \(copies)")
            return
        }
        let copy = try #require(store.node(copyRef.element))
        #expect(copy.layout == row())
        #expect(copy.children.count == 2)
        undo.undo()

        let cardAndInside = try #require(CanvasSelection([.element(ref(card.id)), .element(ref(inside.id))]))
        #expect(store.duplicate(cardAndInside) != nil)
        let root = try #require(store.tree.screens.first?.root)
        #expect(root.children.count == 3, "the row, the card and one copy of the card")
        #expect(root.children.filter { $0.kind == .card }.allSatisfy { $0.children.count == 1 })
        undo.undo()

        let cardAlone = try #require(CanvasSelection([.element(ref(card.id))]))
        store.delete(cardAlone)
        #expect(store.node(card.id) == nil && store.node(inside.id) == nil)
        undo.undo()
        #expect(store.node(card.id)?.kind == .card)
        #expect(store.node(card.id)?.children.map(\.id) == [inside.id])
    }

    /// A drawing given to a screen goes on the canvas where the screen would have shown it, adding
    /// to what is there as well as replacing it.
    @Test func aDrawingGivenToAScreenGoesOnTheCanvas() throws {
        var tree = design([leaf(CGRect(x: 20, y: 100, width: 120, height: 20))])
        tree.screens[0].origin = CGPoint(x: 100, y: 50)
        tree.screens[0].scale = 0.5
        let (store, _) = makeStore(tree)
        let screenID = try #require(store.tree.screens.first?.id)
        let kept = try #require(store.tree.screens.first?.root.children.first?.id)
        var title = DesignStore.newElement(.title)
        title.frame = CGRect(x: 20, y: 80, width: 200, height: 40)
        let point = { (x: CGFloat, t: TimeInterval) in
            PKStrokePoint(location: CGPoint(x: x, y: x), timeOffset: t, size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point(0, 0), point(40, 0.1)], creationDate: Date()))
        var drawing = try #require(DesignElement.drawing([stroke]))
        drawing.frame.origin = CGPoint(x: 40, y: 60)

        let refs = store.setElements([title, drawing], on: screenID, replacing: false)

        #expect(refs == [.init(host: .screen(screenID), element: title.id), .init(host: .canvas, element: drawing.id)])
        #expect(store.tree.screens.first?.root.children.map(\.id) == [kept, title.id])
        let landed = try #require(store.tree.canvas.first { $0.id == drawing.id })
        #expect(landed.kind == .drawing)
        #expect(landed.frame.origin == CGPoint(x: 40 + 100 / 0.5, y: 60 + 50 / 0.5))
        #expect(landed.scale == 0.5)
    }
}
