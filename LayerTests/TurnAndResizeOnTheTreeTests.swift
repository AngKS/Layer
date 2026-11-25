import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// An app showing `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeModel(_ tree: TreeContent) -> (model: AppModel, undo: UndoManager) {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: tree)))
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

private func design(_ screens: [TreeScreen], canvas: [LayerNode] = []) -> TreeContent {
    var content = TreeContent()
    content.screens = screens
    content.canvas = canvas
    return content
}

private func row(spacing: CGFloat = 8) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .horizontal, spacing: spacing))
}

private func column(spacing: CGFloat = 12) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .vertical, spacing: spacing))
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

@MainActor
private extension AppModel {
    /// What the selection names for the node `id`, where the index has it.
    func ref(_ id: UUID) throws -> NodeRef {
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

    /// One drag of a corner handle on the node `id`, selected, `translation` across the glass at the canvas's zoom, in
    /// a few frames, through the rule the handle itself takes (`CanvasDrags.handleRule`).
    func dragHandle(of id: UUID, _ corner: ElementLayout.Corner, by translation: CGSize) throws {
        let ref = try ref(id)
        selection = .element(ref)
        let drags = CanvasDrags()
        self.drags = drags
        let owner = CanvasDrags.Owner()
        let start = try #require(store.placed(id)).canvasShape.corner(corner)
        for step in 1...4 {
            let part = CGSize(width: translation.width * CGFloat(step) / 4, height: translation.height * CGFloat(step) / 4)
            drags.moveNode(ref, by: part, startingAt: start, findsNewHome: false, owner: owner, model: self) { placed in
                CanvasDrags.handleRule(for: placed, corner: corner)
            }
        }
        drags.dropElement(ref, findsNewHome: false, owner: owner, model: self)
    }

    /// One turn of the knob, by `degrees`, unsnapped.
    func knobTurn(_ degrees: Double...) {
        beginTurn()
        for angle in degrees { turnSelection(by: angle, snaps: false) }
        endTurn()
    }

    /// Turns the one thing `id` on its own, through several angles and back to where it was: in one turn of the knob
    /// that comes back round, and over several turns that add up to none. True when its own frame is exactly as it
    /// was on every frame of it.
    func turnAloneAndBack(_ id: UUID) throws -> Bool {
        let frame = ownFrame(of: id)
        var kept = true
        selection = .element(try ref(id))
        beginTurn()
        for angle in [17.0, 133, 251, 0] {
            turnSelection(by: angle, snaps: false)
            kept = kept && ownFrame(of: id) == frame
        }
        endTurn()
        for angle in [29.0, -73, 44] {
            knobTurn(angle)
            kept = kept && ownFrame(of: id) == frame
        }
        return kept
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

    /// Fix round 1 (I1): turned alone about its own middle, a thing has only its angle written, so turned back it is
    /// exactly as it was, wherever it is: here in a turned container on a screen drawn at (137.3, 59.9), seven tenths
    /// of a point to each of its own, where its middle worked out two ways differs in its last bits.
    @Test func aThingTurnedAloneInATurnedContainerComesBackExactly() throws {
        let texts = [
            leaf(.text, CGRect(x: 52, y: 29, width: 21, height: 49)),
            leaf(.text, CGRect(x: 7, y: 61, width: 133, height: 27)),
            leaf(.text, CGRect(x: 119, y: 3, width: 58, height: 17)),
        ]
        let g = container(frame: CGRect(x: 282, y: 128, width: 215, height: 109), turned: 46, texts)
        let (model, _) = makeModel(design([screen([g], origin: CGPoint(x: 137.3, y: 59.9), scale: 0.7)]))
        let before = model.store.tree

        for id in texts.map(\.id) + [g.id] {
            #expect(try model.turnAloneAndBack(id), "only the angle is written as it turns")
        }

        #expect(model.store.tree == before)
    }

    /// Fix round 2 (N1): turned alone through angles that aren't whole and back to where it began, by the knob, a
    /// thing in a turned container takes its own angle back exactly, though its angle on the canvas less its
    /// container's (63.3 − 46) isn't 17.3 to the last bit. Nothing has changed, so no step is left to undo.
    @Test func aThingTurnedByTheKnobThroughFractionalAnglesAndBackLeavesNothingToUndo() throws {
        var text = leaf(.text, CGRect(x: 52, y: 29, width: 61, height: 23))
        text.rotation = 17.3
        // Two things in it: a free group of one dissolves.
        let other = leaf(.text, CGRect(x: 7, y: 61, width: 133, height: 27))
        let g = container(frame: CGRect(x: 282, y: 128, width: 215, height: 109), turned: 46, [text, other])
        let (model, undo) = makeModel(design([screen([g], origin: CGPoint(x: 137.3, y: 59.9), scale: 0.7)]))
        let before = model.store.tree
        model.selection = .element(try model.ref(text.id))
        #expect(model.store.parent(of: text.id) == .node(g.id))
        #expect(model.store.node(text.id)?.rotation == 17.3)
        #expect(model.store.placed(text.id)?.degrees == 46 + 17.3)

        model.knobTurn(12.7, 133.9, -71.3, 0)

        #expect(model.store.node(text.id)?.rotation == 17.3)
        #expect(model.store.tree == before)
        #expect(!undo.canUndo, "a turn that changed nothing is no step")
    }

    /// Fix round 2 (N1), for two fingers: a twist between the 45s and back puts the thing's own angle back exactly.
    @Test func aThingTwistedThroughFractionalAnglesAndBackLeavesNothingToUndo() throws {
        var text = leaf(.text, CGRect(x: 52, y: 29, width: 61, height: 23))
        text.rotation = 17.3
        // Two things in it: a free group of one dissolves.
        let other = leaf(.text, CGRect(x: 7, y: 61, width: 133, height: 27))
        let g = container(frame: CGRect(x: 282, y: 128, width: 215, height: 109), turned: 46, [text, other])
        let (model, undo) = makeModel(design([screen([g], origin: CGPoint(x: 137.3, y: 59.9), scale: 0.7)]))
        let before = model.store.tree
        model.selection = .element(try model.ref(text.id))
        #expect(model.store.parent(of: text.id) == .node(g.id))

        #expect(model.beginTwist())
        // 76, 97.2 and 52 on the canvas: none within 4 of a 45, so none snaps.
        for degrees in [12.7, 33.9, -11.3, 0] { model.twist(by: degrees) }
        model.endTwist()

        #expect(model.store.node(text.id)?.rotation == 17.3)
        #expect(model.store.tree == before)
        #expect(!undo.canUndo, "a twist that changed nothing is no step")
    }

    /// A screen holding A and B grouped by Group, a free group sized to fit them, at (100, 100), A at its left edge,
    /// and C on the screen's root at (300, 300): A and C selected, turning about (225, 225). Turned 90°, A goes round
    /// past the group's left edge, and the group, hugging what it holds, moves its box and every member's frame in it.
    private func memberOfAGroupAndAThingBeside() throws -> (model: AppModel, before: TreeContent, a: UUID, b: UUID, c: UUID) {
        let a = leaf(.text, CGRect(x: 100, y: 100, width: 50, height: 50), text: "A")
        let b = leaf(.text, CGRect(x: 200, y: 100, width: 50, height: 50), text: "B")
        let c = leaf(.text, CGRect(x: 300, y: 300, width: 50, height: 50), text: "C")
        let (model, _) = makeModel(design([screen([a, b, c])]))
        let pair = try #require(CanvasSelection([.element(try model.ref(a.id)), .element(try model.ref(b.id))]))
        let g = try #require(model.store.group(pair))
        #expect(model.store.node(g.node)?.frame == CGRect(x: 100, y: 100, width: 150, height: 50))
        #expect(model.store.node(g.node)?.width.mode == .fit, "Group makes a group sized to fit")
        #expect(model.ownFrame(of: a.id) == CGRect(x: 0, y: 0, width: 50, height: 50))
        model.selection = CanvasSelection([.element(try model.ref(a.id)), .element(try model.ref(c.id))])
        return (model, model.store.tree, a.id, b.id, c.id)
    }

    /// Final review A2-I1: several things turned and brought back round to where they began, by the knob's Reset, a
    /// twist that snaps back to 0, steps that add up to a whole turn, or the knob turned there and back, are exactly
    /// as they were, though the group one of them is in has moved its box since the turn began. A start is put back
    /// only into a parent as it was; otherwise its frame is worked out where its parent is now.
    @Test func severalThingsTurnedBackRoundLandAsTheyWereThoughTheirGroupMoved() throws {
        // The knob's Reset (its double tap).
        var board = try memberOfAGroupAndAThingBeside()
        let canvasA = try board.model.canvasCentre(of: board.a)
        board.model.rotateSelection(by: 90)
        #expect(board.model.store.tree != board.before)
        #expect(distance(try board.model.canvasCentre(of: board.a), CGPoint(x: 325, y: 125)) < 1e-9)
        board.model.resetSelectionTurn()
        #expect(try board.model.canvasCentre(of: board.a) == canvasA, "Reset: A is back where it began")
        #expect(board.model.store.tree == board.before, "Reset")

        // A twist out past the group's edge and back, snapping to 0 on its last frame.
        board = try memberOfAGroupAndAThingBeside()
        #expect(board.model.beginTwist())
        for degrees in [20.0, 60, 100, 2] { board.model.twist(by: degrees) }
        board.model.endTwist()
        #expect(board.model.store.tree == board.before, "a twist that snaps back to 0")

        // Steps that add up to a whole turn: 90° clockwise, which moves the group's box, then 270°.
        board = try memberOfAGroupAndAThingBeside()
        for degrees in [90.0, 270] { board.model.rotateSelection(by: degrees) }
        #expect(board.model.store.tree == board.before, "steps that add up to a whole turn")

        // The knob turned 90° and back to 0 in one turn.
        board = try memberOfAGroupAndAThingBeside()
        board.model.knobTurn(90, 0)
        #expect(board.model.store.tree == board.before, "the knob there and back")
    }

    /// Final review A2-M3: one thing turned alone and back, at the edge of a turned group sized to fit, which fits round
    /// its turned shape on the way and back again through its own turn, leaves the design exactly as it was, and so no
    /// step to undo.
    @Test func aThingAtTheEdgeOfATurnedFitGroupTurnedAloneAndBackLeavesNothingToUndo() throws {
        let a = leaf(.text, CGRect(x: 0, y: 0, width: 50, height: 50), text: "A")
        let b = leaf(.text, CGRect(x: 100, y: 0, width: 50, height: 50), text: "B")
        let g = container(frame: CGRect(x: 137, y: 211, width: 150, height: 50), fits: true, turned: 33, [a, b])
        let (model, undo) = makeModel(design([screen([g], origin: CGPoint(x: 137.3, y: 59.9), scale: 0.7)]))
        let before = model.store.tree
        model.selection = .element(try model.ref(a.id))

        model.knobTurn(40, 0)
        #expect(model.store.tree == before, "the knob there and back")
        #expect(!undo.canUndo, "a turn that changed nothing is no step")

        #expect(model.beginTwist())
        for degrees in [17.0, 40, 1] { model.twist(by: degrees) }
        #expect(model.store.tree != before, "turned, the group fits round it")
        model.twist(by: 0)
        model.endTwist()
        #expect(model.store.tree == before, "a twist there and back")
        #expect(!undo.canUndo, "a twist that changed nothing is no step")
    }

    /// Final review A2-I1, for a handle: a container in a group sized to fit, at the group's left edge, resized out past
    /// it and back to exactly the box it began as, is exactly as it was, though the group moved its box meanwhile.
    @Test func aContainerInAFitGroupResizedBackToWhereItBeganIsAsItWas() throws {
        let card = container(.card, frame: CGRect(x: 100, y: 100, width: 100, height: 50),
                             [leaf(.text, CGRect(x: 10, y: 10, width: 60, height: 20))])
        let k = leaf(.text, CGRect(x: 250, y: 100, width: 50, height: 50), text: "K")
        let (model, _) = makeModel(design([screen([card, k])]))
        let pair = try #require(CanvasSelection([.element(try model.ref(card.id)), .element(try model.ref(k.id))]))
        let g = try #require(model.store.group(pair))
        #expect(model.store.node(g.node)?.frame == CGRect(x: 100, y: 100, width: 200, height: 50))
        let before = model.store.tree
        let ref = try model.ref(card.id)
        let pose = try #require(model.store.groupPose(of: ref))
        #expect(pose.box == CGRect(x: 100, y: 100, width: 100, height: 50))

        // Half as large again about its bottom-right corner: out past the group's left and top edges.
        model.store.resizeGroup(ref, to: CGRect(x: 50, y: 75, width: 150, height: 75), from: pose)
        #expect(model.store.node(g.node)?.frame.origin == CGPoint(x: 50, y: 75), "the group hugs it")
        model.store.resizeGroup(ref, to: pose.box, from: pose)

        #expect(model.store.placed(card.id)?.frame == pose.box)
        #expect(model.store.tree == before)
    }

    /// Fix round 1 (I1), for ink: a drawing, which goes exactly where it is put, off whole points on the open canvas
    /// drawn at seven tenths (the rules keep drawings off screens), turned alone through several angles and back.
    @Test func aDrawingTurnedAloneOnAScaledCanvasComesBackExactly() throws {
        let frames = [
            CGRect(x: 612.37, y: 288.91, width: 87.13, height: 41.77),
            CGRect(x: 133.71, y: 47.29, width: 211.43, height: 96.07),
            CGRect(x: 401.19, y: 503.83, width: 59.61, height: 140.33),
        ]
        let drawings = frames.map { frame -> LayerNode in
            var drawing = LayerNode(kind: .drawing)
            drawing.frame = frame
            drawing.scale = 0.7
            return drawing
        }
        let (model, _) = makeModel(design([], canvas: drawings))
        let before = model.store.tree
        #expect(model.store.index.placement(of: drawings[0].id, in: before) == Placement(origin: .zero, scale: 0.7))

        for id in drawings.map(\.id) {
            #expect(try model.turnAloneAndBack(id), "only the angle is written as it turns")
        }

        #expect(model.store.tree == before)
    }

    // MARK: Resizing

    /// Fix round 1 (I2): a laid-out child's handle flicked out 40 points and back to within 0.3 of where it began puts
    /// that axis back as it was, its size and its sizing, fit included: each frame is worked out from the start alone.
    @Test func aRowChildsHandleFlickedOutAndBackPutsItBackExactly() throws {
        let (a, b, c) = (fittingText("First"), fittingText("Second"), fittingText("Third"))
        let r = container(.group, row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), fits: true, [a, b, c])
        let (model, _) = makeModel(design([screen([r])]))
        let before = model.store.tree
        let start = try #require(model.store.node(b.id))
        #expect(start.frame.width > 40, "wider than a text's least width, so only the flick changes it")
        let ref = try model.ref(b.id)
        let drags = CanvasDrags()
        model.drags = drags
        let owner = CanvasDrags.Owner()
        func drag(by width: CGFloat) {
            drags.moveNode(ref, by: CGSize(width: width, height: 0), startingAt: CGPoint(x: 1, y: 1), findsNewHome: false,
                           owner: owner, model: model) { placed in
                CanvasDrags.resizeRule(for: placed.node.kind, degrees: placed.degrees, corner: .bottomRight)
            }
        }

        drag(by: 40)
        #expect(model.store.node(b.id)?.frame.width == start.frame.width + 40)
        #expect(model.store.node(b.id)?.width.mode == .fixed)
        drag(by: 0.3)
        drags.dropElement(ref, findsNewHome: false, owner: owner, model: model)

        #expect(model.store.node(b.id)?.width == start.width, "its sizing is as it was: fit")
        #expect(model.store.node(b.id)?.frame.size == start.frame.size)
        #expect(model.store.tree == before)
    }

    @Test func resizingARowChildFixesOnlyTheAxisItChanged() throws {
        let (a, b, c) = (fittingText("One"), fittingText("Two"), fittingText("Three"))
        let r = container(.group, row(), frame: CGRect(x: 20, y: 100, width: 0, height: 0), fits: true, [a, b, c])
        let (model, undo) = makeModel(design([screen([r])]))
        let store = model.store
        let began = try #require(store.node(b.id))
        let start = began.frame.size

        store.resizeLaidOut(b.id, to: CGSize(width: start.width + 40, height: start.height), from: began)

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

    /// Final review A1-I1: a card a column lays out is a laid-out child, so its corner handle dragged straight down
    /// makes it taller and nothing else. Its width keeps filling the column, and only its height becomes fixed.
    @Test func aCardInAColumnDraggedDownByItsHandleChangesOnlyItsHeight() throws {
        var card = container(.card, frame: CGRect(x: 0, y: 0, width: 353, height: 120), [leaf(.text, CGRect(x: 16, y: 16, width: 100, height: 24))])
        card.width = LayerNode.Sizing(.fill(weight: 1))
        let below = leaf(.text, CGRect(x: 0, y: 0, width: 353, height: 24))
        let column = container(.group, column(), frame: CGRect(x: 20, y: 100, width: 353, height: 600), [card, below])
        let (model, undo) = makeModel(design([screen([column])]))
        let start = try #require(model.store.node(card.id))
        #expect(start.frame.size == CGSize(width: 353, height: 120))

        try model.dragHandle(of: card.id, .bottomRight, by: CGSize(width: 0, height: 50))

        let resized = try #require(model.store.node(card.id))
        #expect(resized.frame.height == 170)
        #expect(resized.height.mode == .fixed)
        #expect(resized.width == start.width, "it still fills the column across")
        #expect(resized.frame.width == 353)
        #expect(model.store.parent(of: card.id) == .node(column.id))
        #expect(undo.undoActionName == "Resize")
    }

    /// Final review A1-I1: a row a column lays out resizes on each axis its handle moved, by as much as it moved, and
    /// the axis it didn't keeps its sizing.
    @Test func aRowInAColumnResizesOnlyTheAxesItsHandleMoved() throws {
        let r = container(.group, row(), frame: .zero, fits: true, [fittingText("One"), fittingText("Two")])
        let column = container(.group, column(), frame: CGRect(x: 20, y: 100, width: 353, height: 600), [r])
        let (model, _) = makeModel(design([screen([column])]))
        let start = try #require(model.store.node(r.id))

        try model.dragHandle(of: r.id, .bottomRight, by: CGSize(width: 30, height: 0))

        let across = try #require(model.store.node(r.id))
        #expect(across.frame.width == start.frame.width + 30)
        #expect(across.width.mode == .fixed)
        #expect(across.height == start.height, "its height wasn't changed, so it still fits what it holds")
        #expect(across.frame.height == start.frame.height)

        // Both ways from the corner across: each axis by as much as the handle moved along it, not in proportion.
        let now = across.frame.size
        try model.dragHandle(of: r.id, .topLeft, by: CGSize(width: -10, height: -20))

        let both = try #require(model.store.node(r.id))
        #expect(both.frame.size == CGSize(width: now.width + 10, height: now.height + 20))
        #expect(both.width.mode == .fixed)
        #expect(both.height.mode == .fixed)
        #expect(model.store.parent(of: r.id) == .node(column.id))
    }

    /// Final review A1-I1: a container placed freely keeps its handles' rule, scaling in proportion.
    @Test func aFreeGroupsHandleStillResizesInProportion() throws {
        let a = leaf(.text, CGRect(x: 0, y: 0, width: 100, height: 40))
        let b = leaf(.text, CGRect(x: 100, y: 60, width: 100, height: 40))
        let g = container(frame: CGRect(x: 20, y: 100, width: 200, height: 100), [a, b])
        let (model, _) = makeModel(design([screen([g])]))

        try model.dragHandle(of: g.id, .bottomRight, by: CGSize(width: 0, height: 50))

        #expect(model.store.node(g.id)?.frame == CGRect(x: 20, y: 100, width: 300, height: 150))
        #expect(model.store.node(b.id)?.frame == CGRect(x: 150, y: 90, width: 150, height: 60), "what it holds scales with it")
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
