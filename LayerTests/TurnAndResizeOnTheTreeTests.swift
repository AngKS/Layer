import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// An app showing `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeModel(_ tree: TreeContent) -> (model: AppModel, undo: UndoManager) {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    return (model, undo)
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

/// A container, fixed at `frame` unless it `fits` what it holds, turned `degrees`.
private func container(_ kind: ElementKind = .group, _ layout: LayerNode.Layout? = nil, frame: CGRect = .zero,
                       fits: Bool = false, turned degrees: Double? = nil, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.layout = layout
    node.frame = frame
    node.rotation = degrees
    if fits {
        node.width = LayerNode.Sizing(.fit)
        node.height = LayerNode.Sizing(.fit)
    }
    node.children = children
    return node
}

/// An iPhone screen drawn at `origin` on the canvas, `scale` canvas points to each of its own.
private func screen(_ children: [LayerNode], origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeScreen {
    var screen = TreeScreen(name: "Screen", origin: origin, scale: scale, deviceID: nil)
    screen.root.children = children
    return screen
}

private func design(_ screens: [TreeScreen]) -> TreeContent {
    var content = TreeContent()
    content.screens = screens
    return content
}

private func row(spacing: CGFloat = 8) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .horizontal, spacing: spacing))
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

@MainActor
private extension AppModel {
    /// What the selection names for the node `id`, where the index has it.
    func ref(_ id: UUID) throws -> DesignStore.ElementRef {
        try #require(store.ref(of: id))
    }

    /// The node's middle on the canvas.
    func canvasCentre(of id: UUID) throws -> CGPoint {
        try #require(store.placed(id)).canvasShape.centre
    }

    /// The node's own frame, in its parent's space.
    func ownFrame(of id: UUID) -> CGRect? {
        store.node(id)?.frame
    }

    /// One turn of the knob, by `degrees`, unsnapped.
    func knobTurn(_ degrees: Double...) {
        beginTurn()
        for angle in degrees { turnSelection(by: angle, snaps: false) }
        endTurn()
    }
}

/// Turning and resizing on the tree (plan 4, Task 5): a container turns whole, setting only its angle; several things
/// turn about a pivot fixed as they are selected, each written through its parent's inverse; a laid-out child turns in
/// place and its handles fix only the axis they changed; a free container's handles scale what it holds.
@Suite("Turning and resizing on the tree")
@MainActor
struct TurnAndResizeOnTheTreeTests {
    // MARK: Turning

    @Test func aContainerTurnedAloneSetsOnlyItsAngle() throws {
        let a = leaf(.text, CGRect(x: 16, y: 16, width: 100, height: 24))
        let b = leaf(.text, CGRect(x: 16, y: 52, width: 100, height: 24))
        let card = container(.card, frame: CGRect(x: 20, y: 100, width: 200, height: 100), [a, b])
        let (model, undo) = makeModel(design([screen([card])]))
        let before = model.store.tree
        let cardFrame = model.ownFrame(of: card.id)
        let texts = [a, b].map { model.ownFrame(of: $0.id) }
        model.selection = .element(try model.ref(card.id))

        model.knobTurn(30)

        #expect(model.store.node(card.id)?.rotation == 30)
        #expect(model.ownFrame(of: card.id) == cardFrame, "it turns about its own middle")
        #expect([a, b].map { model.ownFrame(of: $0.id) } == texts)
        #expect([a, b].map { model.store.node($0.id)?.rotation } == [nil, nil])
        #expect(undo.undoActionName == "Rotate")
        undo.undo()
        #expect(model.store.tree == before)
        #expect(!undo.canUndo, "the turn was one step")
    }

    @Test func severalThingsTurnAboutTheFixedPivotAndBackExactly() throws {
        let button = leaf(.button, CGRect(x: 240, y: 300, width: 120, height: 44), text: "Go")
        let text = leaf(.text, CGRect(x: 16, y: 16, width: 100, height: 24))
        let card = container(.card, frame: CGRect(x: 20, y: 100, width: 200, height: 100), turned: 15, [text])
        let (model, _) = makeModel(design([screen([button, card], origin: CGPoint(x: 100, y: 50), scale: 0.5)]))
        let before = model.store.tree
        model.selection = CanvasSelection([.element(try model.ref(button.id)), .element(try model.ref(card.id))])
        let pivot = try #require(model.selectionShape).centre
        let centres = try [button.id, card.id].map { try model.canvasCentre(of: $0) }

        #expect(model.beginTurn())
        model.turnSelection(by: 90, snaps: false)
        // Each has gone round the middle of them both, its own whole points apart, not round its own.
        for (id, centre) in zip([button.id, card.id], centres) {
            #expect(distance(try model.canvasCentre(of: id), Rotation.rotate(centre, about: pivot, by: 90)) < 1)
        }
        #expect(model.store.node(button.id)?.rotation == 90)
        #expect(model.store.node(card.id)?.rotation == 105)
        #expect(model.ownFrame(of: text.id) == text.frame, "what the card holds goes round with it")
        #expect(model.store.tree != before)

        model.turnSelection(by: 0, snaps: false)
        model.endTurn()
        #expect(model.store.tree == before)
    }

    @Test func aThingInsideATurnedContainerTurnsAboutTheSharedPivot() throws {
        let x = leaf(.text, CGRect(x: 20, y: 10, width: 60, height: 20))
        let other = leaf(.text, CGRect(x: 100, y: 60, width: 80, height: 30))
        let g = container(frame: CGRect(x: 100, y: 100, width: 200, height: 100), turned: 30, [x, other])
        let y = leaf(.text, CGRect(x: 300, y: 400, width: 80, height: 30))
        let (model, _) = makeModel(design([screen([g, y])]))
        model.selection = CanvasSelection([.element(try model.ref(x.id)), .element(try model.ref(y.id))])
        let pivot = try #require(model.selectionShape).centre
        let base = try #require(model.store.placed(x.id))
        #expect(base.degrees == 30)

        model.knobTurn(45)

        let now = try #require(model.store.placed(x.id))
        #expect(distance(now.canvasShape.centre, Rotation.rotate(base.canvasShape.centre, about: pivot, by: 45)) < 1e-6)
        #expect(abs(now.degrees - (base.degrees + 45)) < 1e-9)
        #expect(model.store.node(x.id)?.rotation == 45, "its own angle is the canvas's less its container's")
        #expect(model.store.parent(of: x.id) == .node(g.id))
        #expect(model.store.node(g.id)?.rotation == 30, "the container it is in stays as it was")
        #expect(model.ownFrame(of: other.id) == other.frame)
    }

    @Test func aLaidOutChildTurnsInPlace() throws {
        let (a, b, c) = (fittingText("One"), fittingText("Two"), fittingText("Three"))
        let r = container(.group, row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), fits: true, [a, b, c])
        let (model, _) = makeModel(design([screen([r])]))
        let frames = [r.id, a.id, b.id, c.id].map { model.ownFrame(of: $0) }
        model.selection = .element(try model.ref(b.id))
        #expect(model.canTurnSelection)

        model.knobTurn(20)

        #expect(model.store.node(b.id)?.rotation == 20)
        #expect([r.id, a.id, b.id, c.id].map { model.ownFrame(of: $0) } == frames)
        #expect(model.store.parent(of: b.id) == .node(r.id))
    }

    @Test func aFreeGroupStillHugsAMemberThatTurned() throws {
        let a = leaf(.text, CGRect(x: 0, y: 0, width: 120, height: 40))
        let b = leaf(.text, CGRect(x: 0, y: 60, width: 200, height: 30))
        let g = container(frame: CGRect(x: 40, y: 200, width: 200, height: 90), fits: true, [a, b])
        let (model, _) = makeModel(design([screen([g])]))
        #expect(model.ownFrame(of: g.id)?.size == CGSize(width: 200, height: 90))
        model.selection = .element(try model.ref(a.id))
        let centre = try model.canvasCentre(of: a.id)

        model.knobTurn(45)

        let group = try #require(model.store.node(g.id))
        #expect(group.children.first { $0.id == a.id }?.rotation == 45)
        // Its box is the one round its children's turned shapes, out to whole points.
        let shapes = group.children.map { TurnedRect(rect: $0.frame, degrees: $0.rotation ?? 0).bounds }
        let box = shapes.dropFirst().reduce(shapes[0]) { $0.union($1) }
        let left = (box.minX + 0.001).rounded(.down), top = (box.minY + 0.001).rounded(.down)
        #expect(left == 0 && top == 0, "what it holds starts at its top-left")
        #expect(group.frame.size == CGSize(width: (box.maxX - 0.001).rounded(.up) - left, height: (box.maxY - 0.001).rounded(.up) - top))
        #expect(group.frame.height > 90, "turned, the member takes up more of it")
        #expect(distance(try model.canvasCentre(of: a.id), centre) < 1e-9, "the member turned about its own middle")
    }

    // MARK: Resizing

    @Test func resizingARowChildFixesOnlyTheAxisItChanged() throws {
        let (a, b, c) = (fittingText("One"), fittingText("Two"), fittingText("Three"))
        let r = container(.group, row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), fits: true, [a, b, c])
        let (model, undo) = makeModel(design([screen([r])]))
        let store = model.store
        let start = try #require(store.node(b.id)).frame.size

        store.resizeLaidOut(b.id, to: CGSize(width: start.width + 40, height: start.height), from: start)

        let resized = try #require(store.node(b.id))
        #expect(resized.width.mode == .fixed)
        #expect(resized.frame.width == start.width + 40)
        #expect(resized.height.mode == .fit, "its height wasn't changed")
        // Where it is, the engine says: just after the one before it, and the one after it just after it.
        let (first, last) = (try #require(store.node(a.id)), try #require(store.node(c.id)))
        #expect(resized.frame.minX == first.frame.maxX + 8)
        #expect(last.frame.minX == resized.frame.maxX + 8)
        #expect(store.parent(of: b.id) == .node(r.id))
        #expect(undo.canUndo)
        undo.undo()
        #expect(store.node(b.id)?.width.mode == .fit)
    }

    @Test func aFreeCardResizesWhatItHoldsAsAGroupDoes() throws {
        var text = leaf(.text, CGRect(x: 16, y: 16, width: 100, height: 24))
        text.style.fontSize = 17
        let card = container(.card, frame: CGRect(x: 20, y: 100, width: 200, height: 100), [text])
        let (model, _) = makeModel(design([screen([card])]))
        let store = model.store
        let ref = try model.ref(card.id)
        let pose = try #require(store.groupPose(of: ref))
        #expect(pose.box == CGRect(x: 20, y: 100, width: 200, height: 100))

        store.resizeGroup(ref, to: CGRect(x: 20, y: 100, width: 400, height: 200), from: pose)

        let resized = try #require(store.node(text.id))
        #expect(resized.frame.width == 200)
        #expect(resized.frame == CGRect(x: 32, y: 32, width: 200, height: 48))
        #expect(resized.style.fontSize == 17, "its words stay the size they were")
        #expect(store.node(card.id)?.frame == CGRect(x: 20, y: 100, width: 400, height: 200))
    }

    @Test func theRotationFieldTurnsAnyContainerAsOnePiece() throws {
        let a = leaf(.text, CGRect(x: 16, y: 16, width: 100, height: 24))
        let b = leaf(.text, CGRect(x: 16, y: 52, width: 100, height: 24))
        let card = container(.card, frame: CGRect(x: 20, y: 100, width: 200, height: 100), [a, b])
        let (model, _) = makeModel(design([screen([card])]))
        let ref = try model.ref(card.id)
        let texts = [a, b].map { model.ownFrame(of: $0.id) }
        model.selection = .element(ref)

        model.setGroupRotation(ref, to: 45)

        #expect(model.store.node(card.id)?.rotation == 45)
        #expect(model.ownFrame(of: card.id) == card.frame)
        #expect([a, b].map { model.ownFrame(of: $0.id) } == texts)
    }

    #if DEBUG
    /// F10: a memo's first build is at most one, and the one after a change exactly one.
    @Test func aTurnSessionIsFormedOncePerSelectionAndVersion() throws {
        let x = leaf(.text, CGRect(x: 20, y: 100, width: 80, height: 30))
        let y = leaf(.text, CGRect(x: 200, y: 300, width: 80, height: 30))
        let (model, _) = makeModel(design([screen([x, y])]))
        model.selection = CanvasSelection([.element(try model.ref(x.id)), .element(try model.ref(y.id))])

        let formed = CanvasWork.turnSessionsFormed
        for _ in 0..<10 { _ = model.selectionShape }
        #expect(CanvasWork.turnSessionsFormed - formed <= 1, "formed \(CanvasWork.turnSessionsFormed - formed)")

        model.store.update(x.id) { $0.frame.origin.x += 10 }
        let changed = CanvasWork.turnSessionsFormed
        for _ in 0..<10 { _ = model.selectionShape }
        #expect(CanvasWork.turnSessionsFormed - changed == 1, "formed \(CanvasWork.turnSessionsFormed - changed)")
    }
    #endif
}
