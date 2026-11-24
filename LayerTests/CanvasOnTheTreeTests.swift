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
    let store = DesignStore(content: DesignContent(tree: tree))
    store.undoManager = undo
    return (store, undo)
}

/// An app showing `tree`, laid out as a file read lays it out.
@MainActor
private func makeModel(_ tree: TreeContent) -> AppModel {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    return model
}

private func leaf(_ kind: ElementKind = .text, _ frame: CGRect, text: String = "Text") -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    node.content.text = text
    return node
}

/// A text sized to fit its words on both axes, as one in a row usually is.
private func fittingText(_ text: String) -> LayerNode {
    var node = leaf(.text, .zero, text: text)
    node.width = LayerNode.Sizing(.fit)
    node.height = LayerNode.Sizing(.fit)
    return node
}

/// A container, fixed at `frame` unless it `fits` what it holds.
private func container(_ kind: ElementKind = .group, _ layout: LayerNode.Layout? = nil, frame: CGRect = .zero,
                       fits: Bool = false, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.layout = layout
    node.frame = frame
    if fits {
        node.width = LayerNode.Sizing(.fit)
        node.height = LayerNode.Sizing(.fit)
    }
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

private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// The canvas's reads and writes on the tree (plan 4, Task 1): a node's own pose and placement from the
/// index, a frame placed through its parent's inverse, and the selection read without lowering the design.
@Suite("The canvas on the tree")
@MainActor
struct CanvasOnTheTreeTests {
    // MARK: Own poses

    @Test func ownPosesAddUpThroughUprightContainers() throws {
        let x = leaf(.text, CGRect(x: 10, y: 20, width: 30, height: 40))
        let y = leaf(.text, CGRect(x: 0, y: 0, width: 10, height: 10))
        let g = container(frame: CGRect(x: 100, y: 200, width: 50, height: 50), [x, y])
        let (store, _) = makeStore(design([screen([g])]))

        let pose = try #require(store.index.ownPose(of: x.id, in: store.tree))

        #expect(pose.frame == CGRect(x: 110, y: 220, width: 30, height: 40))
        #expect(pose.degrees == 0)
    }

    @Test func ownPosesTurnWithTheirContainer() throws {
        let child = leaf(.text, CGRect(x: 0, y: 0, width: 20, height: 20))
        let other = leaf(.text, CGRect(x: 100, y: 50, width: 20, height: 20))
        var g = container(frame: CGRect(x: 100, y: 100, width: 200, height: 100), [child, other])
        g.rotation = 90
        let (store, _) = makeStore(design([screen([g])]))

        let pose = try #require(store.index.ownPose(of: child.id, in: store.tree))

        #expect(abs(pose.frame.midX - 240) < 1e-9 && abs(pose.frame.midY - 60) < 1e-9)
        #expect(pose.frame.size == CGSize(width: 20, height: 20))
        #expect(pose.degrees == 90)
    }

    @Test func aCanvasNodesOwnPoseIsInItsOwnPoints() throws {
        var note = leaf(.stickyNote, CGRect(x: 100, y: 100, width: 150, height: 150))
        note.scale = 0.5
        let (store, _) = makeStore(design([], canvas: [note]))

        let pose = try #require(store.index.ownPose(of: note.id, in: store.tree))

        #expect(pose.frame == CGRect(x: 100, y: 100, width: 150, height: 150))
        #expect(store.index.placement(of: note.id, in: store.tree) == Placement(origin: .zero, scale: 0.5))
    }

    // MARK: Placing

    @Test func placingAFreeChildWritesOnlyIt() throws {
        let x = leaf(.text, CGRect(x: 10, y: 20, width: 30, height: 40))
        let y = leaf(.text, CGRect(x: 0, y: 0, width: 10, height: 10))
        let g = container(frame: CGRect(x: 100, y: 200, width: 50, height: 50), [x, y])
        let (store, _) = makeStore(design([screen([g])]))
        let sibling = try #require(store.node(y.id))
        let written = ListWork.elementsWritten, lowered = TreeProjection.lowerings

        store.place(x.id, at: CGRect(x: 130, y: 250, width: 30, height: 40))

        #expect(store.node(x.id)?.frame == CGRect(x: 30, y: 50, width: 30, height: 40))
        #expect(store.node(y.id) == sibling)
        #expect(ListWork.elementsWritten - written == 1)
        #expect(TreeProjection.lowerings - lowered == 0)
    }

    @Test func placingAContainerCarriesItsSubtree() throws {
        let x = leaf(.text, CGRect(x: 10, y: 20, width: 30, height: 40))
        let y = leaf(.text, CGRect(x: 0, y: 0, width: 10, height: 10))
        let g = container(frame: CGRect(x: 100, y: 200, width: 50, height: 50), [x, y])
        let (store, _) = makeStore(design([screen([g])]))
        let before = try #require(store.node(g.id))
        let own = try #require(store.index.ownPose(of: g.id, in: store.tree))

        store.place(g.id, at: own.frame.offsetBy(dx: 10, dy: 0))

        let after = try #require(store.node(g.id))
        #expect(after.frame.origin == CGPoint(x: before.frame.minX + 10, y: before.frame.minY))
        #expect(after.children.map(\.frame) == before.children.map(\.frame))
    }

    @Test func placingUnderATurnedContainerLandsWhereAsked() throws {
        var x = leaf(.text, CGRect(x: 10, y: 10, width: 20, height: 20))
        x.rotation = 10
        let y = leaf(.text, CGRect(x: 60, y: 40, width: 20, height: 20))
        var g = container(frame: CGRect(x: 100, y: 100, width: 120, height: 80), [x, y])
        g.rotation = 30
        let (store, _) = makeStore(design([screen([g])]))
        let asked = CGRect(x: 150, y: 140, width: 20, height: 20)

        store.place(x.id, at: asked)

        let pose = try #require(store.index.ownPose(of: x.id, in: store.tree))
        #expect(close(pose.frame, asked, within: 1e-6))
        #expect(store.node(x.id)?.rotation == 10)
        #expect(abs(pose.degrees - 40) < 1e-9)
    }

    @Test func placingARowChildFollowsMyCall20() throws {
        let t1 = fittingText("Hello"), t2 = fittingText("There")
        let strip = container(.group, row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), fits: true, [t1, t2])

        // A size change fixes that axis, and the row keeps it.
        let (sized, _) = makeStore(design([screen([strip])]))
        let own = try #require(sized.index.ownPose(of: t1.id, in: sized.tree)).frame
        sized.place(t1.id, at: CGRect(origin: own.origin, size: CGSize(width: own.width + 40, height: own.height)))
        let wider = try #require(sized.node(t1.id))
        #expect(wider.width.mode == .fixed)
        #expect(wider.height.mode == .fit)
        #expect(wider.frame.width == own.width + 40)
        #expect(sized.parent(of: t1.id) == .node(strip.id))

        // A new origin takes it out to the free root, where it was put, fixed both ways.
        let (moved, _) = makeStore(design([screen([strip])]))
        let screenID = try #require(moved.tree.screens.first?.id)
        let from = try #require(moved.index.ownPose(of: t1.id, in: moved.tree)).frame
        let asked = CGRect(x: from.minX + 30, y: from.minY + 200, width: from.width, height: from.height)
        moved.place(t1.id, at: asked)
        let out = try #require(moved.node(t1.id))
        #expect(moved.parent(of: t1.id) == .screen(screenID))
        #expect(moved.tree.screens.first?.root.children.last?.id == t1.id)
        #expect(moved.index.ownPose(of: t1.id, in: moved.tree)?.frame == asked)
        #expect(out.width.mode == .fixed && out.height.mode == .fixed)

        // In a column root there is nowhere to take it out to: the origin is dropped and the engine lays it
        // back, while a size change still fixes its axis (F20).
        let (laidOut, _) = makeStore(design([screen([strip], layout: column())]))
        let before = try #require(laidOut.node(t1.id))
        let there = try #require(laidOut.index.ownPose(of: t1.id, in: laidOut.tree)).frame
        laidOut.place(t1.id, at: there.offsetBy(dx: 30, dy: 30))
        #expect(laidOut.parent(of: t1.id) == .node(strip.id))
        #expect(laidOut.node(t1.id) == before)
        laidOut.place(t1.id, at: CGRect(origin: there.origin, size: CGSize(width: there.width + 40, height: there.height)))
        let fixed = try #require(laidOut.node(t1.id))
        #expect(fixed.width.mode == .fixed)
        #expect(fixed.frame.width == there.width + 40)
        #expect(laidOut.parent(of: t1.id) == .node(strip.id))
    }

    // MARK: Grouping

    @Test func groupableTakesAMinimum() throws {
        let t = leaf(.text, CGRect(x: 20, y: 400, width: 80, height: 20))
        let a = leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))
        let b = leaf(.text, CGRect(x: 0, y: 40, width: 80, height: 20))
        let g = container(frame: CGRect(x: 20, y: 100, width: 80, height: 60), [a, b])
        let (store, _) = makeStore(design([screen([t, g])]))
        let screenID = try #require(store.tree.screens.first?.id)
        func thing(_ node: LayerNode) -> CanvasSelection { .element(.init(host: .screen(screenID), element: node.id)) }
        let both = try #require(CanvasSelection([thing(a), thing(b)]))

        #expect(store.groupable(thing(t), minimum: 2, refusingAllOfAFreeGroup: true) == nil)
        #expect(store.groupable(thing(t), minimum: 1, refusingAllOfAFreeGroup: true) == [t.id])
        #expect(store.groupable(both, minimum: 2, refusingAllOfAFreeGroup: true) == nil)
        #expect(store.groupable(both, minimum: 2, refusingAllOfAFreeGroup: false) == [a.id, b.id])
    }

    // MARK: Reading the selection

    @Test func refsComeFromTheIndex() throws {
        let text = leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))
        let card = container(.card, column(), fits: true, [text, leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))])
        var note = leaf(.stickyNote, CGRect(x: 600, y: 0, width: 150, height: 150))
        note.scale = 0.5
        let (store, _) = makeStore(design([screen([card])], canvas: [note]))
        let s = try #require(store.tree.screens.first)

        #expect(store.ref(of: text.id) == DesignStore.ElementRef(host: .screen(s.id), element: text.id))
        #expect(store.ref(of: note.id) == DesignStore.ElementRef(host: .canvas, element: note.id))
        #expect(store.ref(of: s.root.id) == nil)
        #expect(store.ref(of: UUID()) == nil)
    }

    @Test func theCanvasReadsTheSelectionWithoutLowering() throws {
        let text = leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))
        let card = container(.card, column(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), fits: true,
                             [text, leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))])
        let model = makeModel(design([screen([card])]))
        let screenID = try #require(model.store.tree.screens.first?.id)
        let selection = CanvasSelection.element(.init(host: .screen(screenID), element: text.id))
        model.selection = selection

        // The per-version memo is stale after a change, so a read of the projection lowers: the counter is live.
        model.store.update(text.id) { $0.content.text = "One" }
        let live = TreeProjection.lowerings
        _ = model.store.screens
        #expect(TreeProjection.lowerings - live == 1)

        model.store.update(text.id) { $0.content.text = "Two" }
        let before = TreeProjection.lowerings
        for round in 0..<10 {
            #expect(model.selectedNode?.node.id == text.id)
            #expect(model.selectedThings == [selection])
            #expect(model.selectedLeafNodes.map(\.node.id) == [text.id])
            #expect(model.store.canvasShape(of: selection) != nil)
            #expect(!model.isSelectionLocked)
            model.store.update(text.id) { $0.content.text = "Round \(round)" }
        }
        #expect(TreeProjection.lowerings - before == 0)
    }

    @Test func aContainerStandsForItsLeaves() throws {
        let t1 = fittingText("One"), t2 = fittingText("Two"), t3 = fittingText("Three")
        let card = container(.card, column(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), fits: true,
                             [t1, container(.group, row(), fits: true, [t2, t3])])
        let model = makeModel(design([screen([card])]))
        let screenID = try #require(model.store.tree.screens.first?.id)

        model.selection = .element(.init(host: .screen(screenID), element: card.id))

        #expect(model.selectedLeafNodes.map(\.node.id) == [t1.id, t2.id, t3.id])
    }

    @Test func aLaidOutChildIsPlacedAsLaidOut() throws {
        let c1 = leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))
        let stack = container(.group, column(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), fits: true,
                              [c1, leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))])
        let free = leaf(.text, CGRect(x: 20, y: 400, width: 80, height: 20))
        let (store, _) = makeStore(design([screen([stack, free])]))

        let laidOut = try #require(store.placed(c1.id))
        let loose = try #require(store.placed(free.id))

        #expect(laidOut.isLaidOut)
        #expect(laidOut.parentLayout == column())
        #expect(!loose.isLaidOut)
        #expect(loose.parentLayout == .free)
        #expect(loose.frame == CGRect(x: 20, y: 400, width: 80, height: 20))
        #expect(loose.placement == Placement(origin: .zero, scale: 1))
    }

    // MARK: Screens

    @Test func aCustomFrameFromTheLibraryMakesAScreenOfIt() throws {
        try withOwnSettings { settings in
            let model = AppModel(document: LayerDocument(), settings: settings)
            model.canvasSize = CGSize(width: 1210, height: 834)
            model.viewport = Viewport(offset: .zero, scale: 1)
            let watch = DeviceFrame.custom(name: "Watch", size: CGSize(width: 198, height: 242), family: .watch)
            model.store.updateCanvas { $0.customDevices = [watch] }

            model.addAsset(Asset(content: .frame(watch.id), name: watch.name, tab: .wireframes, section: "Custom", terms: []))

            let screen = try #require(model.store.tree.screens.last)
            #expect(screen.deviceID == watch.id)
            #expect(screen.root.frame == CGRect(x: 0, y: 0, width: 198, height: 242))
        }
    }

    @Test func aScreensOwnFieldsChangeInOneStep() throws {
        let (store, undo) = makeStore(design([screen([leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20)),
                                                      leaf(.text, CGRect(x: 0, y: 0, width: 80, height: 20))],
                                                     layout: column())]))
        let id = try #require(store.tree.screens.first?.id)
        let children = try #require(store.treeScreen(id)?.root.children)

        store.updateTreeScreen(id) { screen in
            screen.name = "Settings"
            // What the root holds isn't the screen's own: it stays as it is.
            screen.root.children.removeAll()
        }

        #expect(store.treeScreen(id)?.name == "Settings")
        #expect(store.treeScreen(id)?.root.children == children)
        undo.undo()
        #expect(store.treeScreen(id)?.name == "Screen")
        #expect(!undo.canUndo)
    }
}
