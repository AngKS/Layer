import CoreGraphics
import Foundation
import Testing
@testable import Layer

// MARK: - Building

/// An `AppModel` with an iPhone screen at (0, 0), scale 1, at zoom 1, and an undo manager.
@MainActor
private func makeModel() -> (model: AppModel, screen: TreeScreen.ID, undo: UndoManager) {
    let model = AppModel(document: LayerDocument())
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    // No word is read out of the strokes: what they are is the shape's alone.
    model.engine.readHandwriting = { _ in nil }
    return (model, model.store.addEmptyScreen(.iPhone, at: Placement(origin: .zero, scale: 1)), undo)
}

private func leaf(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = CGRect(x: x, y: y, width: width, height: height)
    if kind.hasText { node.content.text = kind.placeholder }
    return node
}

private func text(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 100, _ height: CGFloat = 24) -> LayerNode {
    leaf(.text, x, y, width, height)
}

private func image(_ x: CGFloat, _ y: CGFloat) -> LayerNode { leaf(.image, x, y, 160, 120) }

/// A card drawn with the Magic Pen at `frame`, free, holding `children`.
private func sketchedCard(_ frame: CGRect, holding children: [LayerNode]) -> LayerNode {
    var card = LayerNode(kind: .card)
    card.frame = frame
    card.padding = LayerNode.Padding(all: 16)
    card.sketch = LayerNode.SketchIntent(sketched: frame, on: DeviceFrame.iPhone.size, margin: DeviceFrame.iPhone.margin,
                                         confidence: 0.95, decidedBy: .rules)
    card.children = children
    return card
}

@MainActor
private func rootChildren(_ model: AppModel, _ screen: TreeScreen.ID) -> [LayerNode] {
    model.store.treeScreen(screen)?.root.children ?? []
}

/// Each on the screen's root, in front, one step each.
@MainActor
private func add(_ nodes: [LayerNode], to screen: TreeScreen.ID, in model: AppModel) {
    for node in nodes { #expect(model.store.add(node, to: .screen(screen))) }
}

@MainActor
private func isDeclined(_ id: UUID, in model: AppModel) -> Bool {
    model.store.node(id)?.sketch?.structureDeclined == true
}

/// Strokes as the Magic Pen hands them over, keyed `first`, `first` + 1, … .
private func strokes(_ script: String, from first: Double) throws -> [SketchStroke] {
    try StrokeScript.parse(script).enumerated().map { SketchStroke(key: first + Double($0.offset), points: $0.element) }
}

/// One batch: every sketch in `script` read at once, as when the pen rests once, and waited for.
@MainActor
private func draw(_ script: String, on model: AppModel, keys first: Double = 1) async throws {
    model.sketchChanged(try strokes(script, from: first))
    model.convertNow()
    // With no ink canvas here, the sketch is taken away by hand, as the canvas does once it is read.
    model.sketchChanged([])
    await model.waitForConversions()
}

/// "Make a row?" offered over three 100 × 24 texts at x 20, 124 and 254 (gaps 4 and 30): `aRaggedRowIsOffered`'s.
@MainActor
private func raggedRow(in model: AppModel, on screen: TreeScreen.ID) -> [LayerNode] {
    let texts = [text(20, 100), text(124, 100), text(254, 100)]
    add(texts, to: screen, in: model)
    model.structurePass(over: texts.map(\.id))
    return texts
}

private func observation(of sketch: CGRect) throws -> SketchObservation {
    try #require(SketchAnalyzer.observe(SketchSamples.strokes([SketchSamples.box(sketch, radius: 10)])))
}

/// The structure pass after a batch of readings settles (spec §5, plan 5's calls 1, 2, 11 and 12): what it is sure of is
/// built with the last reading, what it isn't is offered, and what the person declined is never offered again.
@Suite @MainActor struct StructurePassTests {
    // MARK: - Built with the conversion

    @Test func aRowDrawnInOneBatchUndoesWithItsLastReading() async throws {
        let (model, screen, undo) = makeModel()
        try await draw("box 40 300 140 120 8; cross 40 300 140 120; box 213 300 140 120 8; cross 213 300 140 120", on: model)

        let root = rootChildren(model, screen)
        #expect(root.count == 1)
        let row = try #require(root.first)
        #expect(row.kind == .group)
        #expect(row.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .center)))
        #expect(row.sketch?.decidedBy == .structure)
        #expect(row.children.map(\.kind) == [.image, .image])

        // The last reading and the row are one step: what was read first stays where it was drawn.
        undo.undo()
        let left = rootChildren(model, screen)
        #expect(left.map(\.kind) == [.image])
        let drawnAlone = [CGRect(x: 30, y: 300, width: 160, height: 120), CGRect(x: 203, y: 300, width: 160, height: 120)]
        #expect(left.first.map { drawnAlone.contains($0.frame) } == true)
        undo.undo()
        #expect(rootChildren(model, screen).isEmpty)
    }

    /// The container carries the intent `build` writes for it, not the one it was proposed with (plan 5, Task 3's
    /// review): its frame on the screen, through any card round it, its placement read from that, and the structure's
    /// confidence.
    @Test func aBuiltStructureRemembersWhereItIsOnTheScreen() throws {
        let (model, screen, _) = makeModel()
        let device = DeviceFrame.iPhone
        let a = text(20, 100), b = text(132, 100)
        add([a, b], to: screen, in: model)
        model.structurePass(over: [a.id, b.id])

        let row = try #require(rootChildren(model, screen).first)
        #expect(row.children.map(\.id) == [a.id, b.id])
        let intent = try #require(row.sketch)
        #expect(intent.decidedBy == .structure)
        #expect(intent.originalBounds == CGRect(x: 20, y: 100, width: 212, height: 24))
        #expect(intent.originalBounds == row.frame, "the root's space is the screen's")
        #expect(intent.normalizedBounds == CGRect(x: 20 / device.size.width, y: 100 / device.size.height,
                                                  width: 212 / device.size.width, height: 24 / device.size.height))
        #expect(intent.placement == .of(row.frame, screenWidth: device.size.width, margin: device.margin))
        #expect(intent.confidence == 1)
        #expect(!intent.structureDeclined)

        // In a card at (40, 400), holding a text from before besides the two new ones.
        let c = text(16, 16), d = text(128, 16)
        let card = sketchedCard(CGRect(x: 40, y: 400, width: 300, height: 200), holding: [text(16, 150), c, d])
        add([card], to: screen, in: model)
        model.structurePass(over: [c.id, d.id])
        let inCard = try #require(model.store.node(card.id)?.children.first { $0.kind == .group })
        #expect(inCard.children.map(\.id) == [c.id, d.id])
        #expect(inCard.frame == CGRect(x: 16, y: 16, width: 212, height: 24))
        #expect(inCard.sketch?.originalBounds == CGRect(x: 56, y: 416, width: 212, height: 24))
        #expect(inCard.sketch?.decidedBy == .structure)
    }

    @Test func aRaggedRowIsOfferedNotBuilt() throws {
        let (model, screen, undo) = makeModel()
        let texts = [text(20, 100), text(124, 100), text(254, 100)]
        add(texts, to: screen, in: model)
        let before = rootChildren(model, screen)
        let mark = model.store.historyMark

        model.structurePass(over: texts.map(\.id))

        #expect(rootChildren(model, screen) == before)
        #expect(model.shownStructureOffer?.structure.title == "Make a row?")
        #expect(model.shownStructureOffer?.screen == screen)
        #expect(model.store.historyMark == mark, "an offer is no step")

        model.acceptStructureOffer()
        #expect(model.structureOffer == nil)
        let row = try #require(rootChildren(model, screen).first)
        #expect(rootChildren(model, screen).count == 1)
        #expect(row.children.map(\.id) == texts.map(\.id))
        guard case .stack(let stack) = row.resolvedLayout else {
            Issue.record("not a row: \(row.resolvedLayout)")
            return
        }
        #expect(stack.axis == .horizontal)
        #expect(stack.spacing == 16, "the median gap, 17, on the rhythm (F6)")
        #expect(undo.undoActionName == "Make Row")

        undo.undo()
        #expect(rootChildren(model, screen) == before)
    }

    /// A reading the model settled on that the rules didn't list has confidence 0 (plan 5, Task 2): that says nothing of
    /// how sure the pass is of a structure, which is how they lie.
    @Test func aModelNamedReadingIsTakenWhateverItsScore() throws {
        func readByTheModel(_ node: LayerNode) -> LayerNode {
            var node = node
            node.sketch = LayerNode.SketchIntent(sketched: node.frame, on: DeviceFrame.iPhone.size, margin: 20, confidence: 0,
                                                 decidedBy: .model)
            return node
        }
        let (model, screen, _) = makeModel()
        let a = readByTheModel(text(20, 100)), b = readByTheModel(text(132, 100))
        add([a, b], to: screen, in: model)
        model.structurePass(over: [a.id, b.id])
        #expect(rootChildren(model, screen).first?.children.map(\.id) == [a.id, b.id])
    }

    // MARK: - Nothing moved more than 8 pt, nothing hidden (plan 5's final review)

    /// A new card's column and the row it then makes with a card beside it are one step: the texts the card holds move
    /// (−5, −5) in its column, and the row would move the card (−1, −2) more, 9.2 pt in all. The 8 pt limit is on the
    /// furthest any leaf moves in the step (A1), so the row is offered, not built. The card's column stays built.
    @Test func aCardsColumnAndTheRowItWouldJoinMoveNothingMoreThan8Points() throws {
        let (model, screen, _) = makeModel()
        let beside = sketchedCard(CGRect(x: 20, y: 300, width: 170, height: 140), holding: [])
        let texts = [text(21, 21, 120, 24), text(21, 61, 120, 24), text(21, 101, 120, 24)]
        let card = sketchedCard(CGRect(x: 203, y: 304, width: 170, height: 140), holding: texts)
        add([beside, card], to: screen, in: model)
        let drawn = try texts.map { try #require(model.store.placed($0.id)?.frame) }

        model.structurePass(over: [card.id])

        #expect(rootChildren(model, screen).map(\.id) == [beside.id, card.id], "no row is built")
        #expect(model.store.node(card.id)?.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 16, alignment: .start)),
                "the card's column is built")
        let offer = try #require(model.structureOffer)
        #expect(offer.structure.kind == .row)
        #expect(offer.structure.members == [beside.id, card.id])
        #expect(offer.structure.movement > StructureConventions.furthestAutomaticMove, "measured from where the texts were drawn")
        for (text, was) in zip(texts, drawn) {
            let now = try #require(model.store.placed(text.id)?.frame)
            #expect(hypot(now.minX - was.minX, now.minY - was.minY) <= StructureConventions.furthestAutomaticMove)
        }
    }

    /// A badge drawn on an image's corner, after it, stays in front of the row the image goes into with an image drawn
    /// beside it (A2): the row takes the frontmost member's slot only where that hides nothing seen.
    @Test func aBadgeOnAnEarlierMemberStaysInSight() throws {
        let (model, screen, _) = makeModel()
        let first = image(30, 300), badge = leaf(.symbol, 150, 306, 32, 20), second = image(203, 300)
        add([first, badge, second], to: screen, in: model)

        model.structurePass(over: [second.id])

        let root = rootChildren(model, screen)
        #expect(root.count == 2)
        let row = try #require(root.first)
        #expect(row.children.map(\.id) == [first.id, second.id])
        #expect(root.last?.id == badge.id, "in front of the row, so the image doesn't cover it")
        #expect(model.store.node(badge.id)?.frame == badge.frame, "where it was drawn")
    }

    /// A full-screen background, locked or not, is no obstacle to the pass (plan 5's final review, follow-up to A5): it
    /// holds both neighbours of each gap, so it lies under them. A field drawn under two makes a column, and an image
    /// drawn as a grid's fourth cell makes the grid.
    @Test(arguments: [false, true])
    func aBackgroundIsNoObstacle(locked: Bool) throws {
        var background = leaf(.shape, 0, 0, 393, 852)
        background.isLocked = locked
        let (model, screen, _) = makeModel()
        let fields = [leaf(.textField, 20, 100, 353, 48), leaf(.textField, 20, 172, 353, 48), leaf(.textField, 20, 244, 353, 48)]
        add([background] + fields, to: screen, in: model)
        model.structurePass(over: [fields[2].id])
        #expect(rootChildren(model, screen).map(\.id).first == background.id)
        #expect(rootChildren(model, screen).last?.children.map(\.id) == fields.map(\.id))

        let (gridModel, gridScreen, _) = makeModel()
        let cells = [image(30, 300), image(203, 300), image(30, 436), image(203, 436)]
        add([background] + cells, to: gridScreen, in: gridModel)
        gridModel.structurePass(over: [cells[3].id])
        let grid = rootChildren(gridModel, gridScreen).last
        #expect(grid?.layout?.isGrid == true)
        #expect(grid?.children.map(\.id) == cells.map(\.id))
    }

    /// A background reached from what a batch drew doesn't bring in all it lies under: the pass still looks only near
    /// the new node. Fields 200 pt apart up the screen, regular as they are, aren't taken into a column with one drawn
    /// 200 pt under the last.
    @Test func aBackgroundBringsNothingFarIntoTheNeighbourhood() throws {
        let (model, screen, _) = makeModel()
        let background = leaf(.shape, 0, 0, 393, 852)
        let fields = [100, 300, 500, 700].map { leaf(.textField, 20, CGFloat($0), 353, 48) }
        add([background] + fields, to: screen, in: model)
        let before = rootChildren(model, screen)

        model.structurePass(over: [fields[3].id])

        #expect(rootChildren(model, screen) == before)
        #expect(model.structureOffer == nil)
    }

    // MARK: - Declines

    @Test func decliningMarksThemAndTheyAreNeverOfferedAgain() throws {
        let (model, screen, undo) = makeModel()
        let texts = raggedRow(in: model, on: screen)
        #expect(model.structureOffer != nil)
        let couldUndo = undo.canUndo
        let mark = model.store.historyMark

        model.declineStructureOffer()

        #expect(model.structureOffer == nil)
        for member in texts {
            let intent = try #require(model.store.node(member.id)?.sketch)
            #expect(intent.structureDeclined)
            #expect(intent.decidedBy == .structure, "one with no intent gets one that carries the mark")
            #expect(intent.originalBounds == member.frame)
        }
        #expect(undo.canUndo == couldUndo)
        #expect(model.store.historyMark == mark, "a decline is no step")

        let before = rootChildren(model, screen)
        model.structurePass(over: texts.map(\.id))
        #expect(model.structureOffer == nil)
        #expect(rootChildren(model, screen) == before)
    }

    @Test func anUngroupedStructureIsDeclined() throws {
        let (model, screen, _) = makeModel()
        let a = text(20, 100), b = text(132, 100)
        add([a, b], to: screen, in: model)
        model.structurePass(over: [a.id, b.id])
        let row = try #require(rootChildren(model, screen).first)
        #expect(row.sketch?.decidedBy == .structure)

        #expect(model.store.ungroup(NodeRef(host: .screen(screen), node: row.id)) != nil)

        #expect(rootChildren(model, screen).map(\.id) == [a.id, b.id])
        #expect(isDeclined(a.id, in: model))
        #expect(isDeclined(b.id, in: model))
        model.structurePass(over: [a.id, b.id])
        #expect(rootChildren(model, screen).map(\.id) == [a.id, b.id])
        #expect(model.structureOffer == nil)
    }

    /// Taking a member out of a row the pass made declines it, whichever verb takes it (call 11, F4): the canvas's drop
    /// (`move`), the Layers panel (`moveLayer`), and a lift let go where nothing takes it (`takeOut`). What stays isn't.
    @Test func takingOneOutOfARowDeclinesIt() throws {
        let (model, screen, undo) = makeModel()
        let a = text(20, 100), b = text(132, 100), c = text(244, 100)
        add([a, b, c], to: screen, in: model)
        model.structurePass(over: [a.id, b.id, c.id])
        let row = try #require(rootChildren(model, screen).first)
        #expect(row.children.map(\.id) == [a.id, b.id, c.id])

        #expect(model.store.move(a.id, to: .screen(screen)))
        #expect(isDeclined(a.id, in: model))
        #expect(!isDeclined(b.id, in: model) && !isDeclined(c.id, in: model))

        #expect(model.store.moveLayer(b.id, to: .screen(screen), before: nil))
        #expect(model.store.parent(of: b.id) == .screen(screen))
        #expect(isDeclined(b.id, in: model))
        #expect(!isDeclined(c.id, in: model))

        #expect(model.store.takeOut(c.id, to: .screen(screen), centredAt: CGPoint(x: 200, y: 600)))
        #expect(model.store.parent(of: c.id) == .screen(screen))
        #expect(isDeclined(c.id, in: model))

        // The mark is part of the lift's step (plan 5's final review, A9): undoing it puts it back in the row, undeclined.
        undo.undo()
        #expect(model.store.parent(of: c.id) == .node(row.id))
        #expect(!isDeclined(c.id, in: model))
    }

    /// A decline a change makes is part of that change's step (plan 5's final review, A9): undoing the move that took a
    /// member out of a column the pass built takes the mark away with it, and redo puts it back. Ungrouping the column
    /// is the same.
    @Test func undoingWhatDeclinedTakesTheMarksAway() throws {
        let (model, screen, undo) = makeModel()
        let fields = [text(20, 100, 353, 48), text(20, 172, 353, 48), text(20, 244, 353, 48)]
        add(fields, to: screen, in: model)
        model.structurePass(over: fields.map(\.id))
        let column = try #require(rootChildren(model, screen).first)
        #expect(column.children.map(\.id) == fields.map(\.id))

        #expect(model.store.move(fields[2].id, to: .screen(screen)))
        #expect(isDeclined(fields[2].id, in: model))
        undo.undo()
        #expect(model.store.parent(of: fields[2].id) == .node(column.id))
        #expect(!fields.contains { isDeclined($0.id, in: model) }, "no member is declined")
        undo.redo()
        #expect(model.store.parent(of: fields[2].id) == .screen(screen))
        #expect(isDeclined(fields[2].id, in: model))
        undo.undo()

        #expect(model.store.ungroup(NodeRef(host: .screen(screen), node: column.id)) != nil)
        #expect(fields.allSatisfy { isDeclined($0.id, in: model) })
        undo.undo()
        #expect(model.store.node(column.id)?.children.map(\.id) == fields.map(\.id))
        #expect(!fields.contains { isDeclined($0.id, in: model) }, "no member is declined")
        undo.redo()
        #expect(fields.allSatisfy { isDeclined($0.id, in: model) })
    }

    /// The decline check told which hosts hold a structure the pass made, as the store tells it from its index (sweep
    /// item 6), finds what it finds when it looks everywhere: a member taken out of the row to its screen, to another
    /// screen or to the canvas, and nothing for a change on a screen or the canvas that holds no such row.
    @Test func theDeclineCheckToldWhereStructuresAreFindsWhatItFindsLookingEverywhere() throws {
        var row = LayerNode(kind: .group)
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
        row.frame = CGRect(x: 20, y: 100, width: 10, height: 10)
        (row.width, row.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
        row.sketch = LayerNode.SketchIntent(sketched: row.frame, on: DeviceFrame.iPhone.size, margin: DeviceFrame.iPhone.margin,
                                            confidence: 1, decidedBy: .structure)
        row.children = [text(0, 0), text(0, 0), text(0, 0)]
        var withRow = TreeScreen(name: "A", origin: .zero, scale: 1, deviceID: nil)
        withRow.root.children = [row, text(20, 300)]
        var plain = TreeScreen(name: "B", origin: CGPoint(x: 600, y: 0), scale: 1, deviceID: nil)
        plain.root.children = [text(20, 100), text(20, 200)]
        var group = LayerNode(kind: .group)
        group.frame = CGRect(x: 0, y: 1200, width: 100, height: 100)
        group.scale = 1
        group.children = [text(0, 0), text(0, 40)]
        var before = TreeContent()
        before.screens = [withRow, plain]
        before.canvas = [group]
        TreeRules.apply(to: &before, after: nil)
        let structures = TreeIndex(before).hostsWithStructures
        #expect(structures == [.screen(withRow.id)])

        let member = before.screens[0].root.children[0].children[1]
        let changes: [(String, (inout TreeContent) -> Void, Bool)] = [
            ("a member taken out to its screen", { $0.screens[0].root.children[0].children.remove(at: 1); $0.screens[0].root.children.append(member) }, true),
            ("a member taken to another screen", { $0.screens[0].root.children[0].children.remove(at: 1); $0.screens[1].root.children.append(member) }, true),
            ("a member taken to the canvas", { $0.screens[0].root.children[0].children.remove(at: 1); $0.canvas.append(member) }, true),
            ("a text moved on the plain screen", { $0.screens[1].root.children[0].frame.origin.x += 10 }, false),
            ("a text moved in the canvas group", { $0.canvas[0].children[0].frame.origin.x += 10 }, false),
            ("a member moved in its row", { $0.screens[0].root.children[0].children[1].content.text = "Moved" }, false),
        ]
        for (what, change, declines) in changes {
            var after = before
            change(&after)
            let everywhere = DesignStore.takenOutOfStructures(from: before, to: after)
            #expect(DesignStore.takenOutOfStructures(from: before, to: after, structures: structures) == everywhere, "after \(what)")
            #expect(everywhere == (declines ? [member.id] : []), "after \(what)")
        }
        #expect(DesignStore.takenOutOfStructures(from: before, to: before, structures: []).isEmpty)
    }

    @Test func undoingABuiltRowDeclinesNothing() throws {
        let (model, screen, undo) = makeModel()
        let a = text(20, 100), b = text(132, 100)
        add([a, b], to: screen, in: model)
        model.structurePass(over: [a.id, b.id])
        #expect(rootChildren(model, screen).first?.children.map(\.id) == [a.id, b.id])

        undo.undo()

        #expect(rootChildren(model, screen).map(\.id) == [a.id, b.id])
        #expect(rootChildren(model, screen).map(\.frame) == [a.frame, b.frame])
        #expect(!isDeclined(a.id, in: model) && !isDeclined(b.id, in: model))
    }

    @Test func buildingAGridFromARowDeclinesNothing() throws {
        let (model, screen, _) = makeModel()
        let boxes = [image(30, 300), image(203, 300), image(30, 436), image(203, 436)]
        add(Array(boxes[0...1]), to: screen, in: model)
        model.structurePass(over: [boxes[0].id, boxes[1].id])
        let row = try #require(rootChildren(model, screen).first)
        #expect(row.children.map(\.id) == [boxes[0].id, boxes[1].id])

        add(Array(boxes[2...3]), to: screen, in: model)
        model.structurePass(over: [boxes[2].id, boxes[3].id])

        let grid = try #require(rootChildren(model, screen).first)
        #expect(rootChildren(model, screen).count == 1)
        #expect(grid.layout?.isGrid == true)
        #expect(grid.children.map(\.id) == boxes.map(\.id))
        #expect(model.store.node(row.id) == nil)
        for box in boxes { #expect(!isDeclined(box.id, in: model)) }
    }

    // MARK: - The offer

    @Test(arguments: ["deleted", "moved", "resized", "turned", "reparented", "screen moved"])
    func theOfferGoesWhenAMemberIsDeletedOrMoved(change: String) throws {
        let (model, screen, _) = makeModel()
        let texts = raggedRow(in: model, on: screen)
        #expect(model.structureOffer != nil)
        // A change to something else on the screen leaves it.
        let elsewhere = text(20, 700)
        add([elsewhere], to: screen, in: model)
        model.store.update(elsewhere.id) { $0.frame.origin.y += 20 }
        #expect(model.structureOffer != nil)

        switch change {
        case "deleted": model.store.delete(nodes: [texts[0].id])
        case "moved": model.store.update(texts[1].id) { $0.frame.origin.y += 100 }
        case "resized": model.store.update(texts[1].id) { $0.frame.size.width -= 40 }
        case "turned": model.store.update(texts[2].id) { $0.rotation = 15 }
        case "reparented": #expect(model.store.wrap([texts[2].id], in: .card, layout: .free) != nil)
        default: model.store.updateTreeScreen(screen) { $0.origin.x += 200 }
        }

        #expect(model.structureOffer == nil)
        #expect(model.shownStructureOffer == nil)
    }

    @Test func aStructureOfferWaitsForTheKindSuggestion() throws {
        let (model, screen, _) = makeModel()
        let fieldSketch = CGRect(x: 30, y: 600, width: 330, height: 44)
        let field = try #require(model.store.addSketched(.textField, from: fieldSketch, confidence: 0.6, decidedBy: .rules))
        model.offer(KindSuggestion(ref: NodeRef(host: .screen(screen), node: field), kind: .button,
                                   sketch: fieldSketch, observation: try observation(of: fieldSketch)))

        _ = raggedRow(in: model, on: screen)

        let offer = try #require(model.structureOffer)
        #expect(model.suggestion != nil)
        #expect(model.shownStructureOffer == nil)
        model.dismissSuggestion()
        #expect(model.shownStructureOffer == offer)
    }

    /// An offer already showing that a later "Did you mean" hides waits for it (call 12, Task 9 m2): its time stops while
    /// it is hidden, and goes on once it shows again.
    @Test func anOfferHiddenByADidYouMeanWaitsForIt() throws {
        let (model, screen, _) = makeModel()
        let fieldSketch = CGRect(x: 30, y: 600, width: 330, height: 44)
        let field = try #require(model.store.addSketched(.textField, from: fieldSketch, confidence: 0.6, decidedBy: .rules))
        _ = raggedRow(in: model, on: screen)
        let offer = try #require(model.shownStructureOffer)
        #expect(model.structureOfferExpiry != nil, "its time runs while it shows")

        model.offer(KindSuggestion(ref: NodeRef(host: .screen(screen), node: field), kind: .button,
                                   sketch: fieldSketch, observation: try observation(of: fieldSketch)))

        #expect(model.shownStructureOffer == nil)
        #expect(model.structureOffer == offer)
        #expect(model.structureOfferExpiry == nil, "hidden, its time stops")
        let left = model.structureOfferTimeLeft
        #expect(left < StructureConventions.offerLifetime && left > .seconds(7), "what it has left is kept")
        model.dismissSuggestion()
        #expect(model.shownStructureOffer == offer)
        #expect(model.structureOfferExpiry != nil, "shown again, it goes on")
    }

    /// A grid offered in place of a row the pass built is refused once the row is no longer as it was built (Task 6 m1):
    /// a thing put into the row, or a new name for it. Built, the grid would have let what the row gained go loose.
    @Test(arguments: ["grown", "renamed"])
    func aStaleGrowthOfferIsRefused(change: String) throws {
        let (model, screen, _) = makeModel()
        let a = image(30, 300), b = image(203, 300)
        add([a, b], to: screen, in: model)
        model.structurePass(over: [a.id, b.id])
        let row = try #require(rootChildren(model, screen).first)
        #expect(row.children.map(\.id) == [a.id, b.id])
        // Rows 16 and 18 apart, and one 2 pt lower: sure enough to offer, not to build.
        let c = image(30, 436), d = image(202, 438)
        add([c, d], to: screen, in: model)
        model.structurePass(over: [c.id, d.id])
        let offer = try #require(model.structureOffer)
        #expect(offer.structure.title == "Make a grid?")
        #expect(offer.structure.replacing == [row.id])

        let e = image(374, 300)
        switch change {
        case "grown": #expect(model.store.add(e, to: .node(row.id)))
        default: model.store.update(row.id) { $0.name = "Gallery" }
        }
        #expect(model.structureOffer == offer, "none of what it offers has moved")
        let before = model.store.tree

        model.acceptStructureOffer()

        #expect(model.structureOffer == nil)
        #expect(model.store.tree == before, "nothing is built, and nothing goes loose")
    }

    /// The pass lining up the thing a "Did you mean" is about is the app's own doing, not the person's: the suggestion
    /// stays, as it would have had the pass moved nothing.
    @Test func aKindSuggestionStaysWhenThePassLinesItsNodeUp() throws {
        let (model, screen, _) = makeModel()
        // 13 apart: on the rhythm's 12 the second moves a point.
        let a = text(20, 100), b = text(133, 100)
        add([a, b], to: screen, in: model)
        let sketch = CGRect(x: 133, y: 100, width: 100, height: 24)
        model.offer(KindSuggestion(ref: NodeRef(host: .screen(screen), node: b.id), kind: .button,
                                   sketch: sketch, observation: try observation(of: sketch)))

        model.structurePass(over: [a.id, b.id])

        let row = try #require(rootChildren(model, screen).first)
        #expect(row.children.map(\.id) == [a.id, b.id])
        #expect(model.store.placed(b.id)?.frame.minX == 132)
        #expect(model.suggestion != nil)
        // Moved by the person, it goes, as before.
        model.store.update(row.id) { $0.frame.origin.y += 50 }
        #expect(model.suggestion == nil)
    }

    // MARK: - What it never touches

    /// Locked, hidden, turned and declined texts and a free group of two the person made, each where it would line up
    /// with a new text, are never taken (F11). The same things, plain, would be: a row and a column round the new one.
    @Test func lockedHiddenTurnedDrawnAndThePersonsAreNeverTouched() throws {
        func arrangement(plain: Bool) -> (around: [LayerNode], new: LayerNode) {
            var hidden = text(38, 300), locked = text(262, 300), turned = text(150, 264), declined = text(150, 336)
            let upper = text(150, 372), lower = text(150, 408)
            guard !plain else { return ([hidden, locked, turned, declined, upper, lower], text(150, 300)) }
            hidden.isHidden = true
            locked.isLocked = true
            turned.rotation = 10
            declined.sketch = LayerNode.SketchIntent(sketched: declined.frame, on: DeviceFrame.iPhone.size, margin: 20,
                                                     confidence: 1, decidedBy: .rules)
            declined.sketch?.structureDeclined = true
            var group = LayerNode(kind: .group)
            group.frame = CGRect(x: 150, y: 372, width: 100, height: 60)
            group.width = LayerNode.Sizing(.fit)
            group.height = LayerNode.Sizing(.fit)
            group.children = [text(0, 0), text(0, 36)]
            return ([hidden, locked, turned, declined, group], text(150, 300))
        }

        let (model, screen, _) = makeModel()
        let untouchable = arrangement(plain: false)
        add(untouchable.around + [untouchable.new], to: screen, in: model)
        let before = rootChildren(model, screen)
        model.structurePass(over: [untouchable.new.id])
        #expect(rootChildren(model, screen) == before)
        #expect(model.structureOffer == nil)

        // The control: plain, each is taken by what is built or offered.
        let (plainModel, plainScreen, _) = makeModel()
        let plain = arrangement(plain: true)
        add(plain.around + [plain.new], to: plainScreen, in: plainModel)
        plainModel.structurePass(over: [plain.new.id])
        let built = rootChildren(plainModel, plainScreen).filter { $0.kind == .group }.flatMap { TreeEdit.ids(in: $0) }
        let offered = plainModel.structureOffer.map { offer in
            offer.structure.members.flatMap { id in plainModel.store.node(id).map(TreeEdit.ids(in:)) ?? [id] }
        } ?? []
        let taken = Set(built + offered)
        for thing in plain.around { #expect(taken.contains(thing.id)) }
    }

    /// Nothing is built past depth 32 (F9, plan 5's Task 3 m1): the pass is told how deep its container is, and `build`
    /// itself refuses a structure that would go past it.
    @Test func aPassStopsAtDepth32() throws {
        func nested(_ levels: Int, holding inner: [LayerNode]) -> (outer: LayerNode, innermost: UUID) {
            var node = sketchedCard(CGRect(x: 0, y: 0, width: 393, height: 400), holding: inner)
            let innermost = node.id
            for _ in 1..<levels { node = sketchedCard(CGRect(x: 0, y: 0, width: 393, height: 400), holding: [node]) }
            return (node, innermost)
        }

        // Innermost card at depth 30: its texts at 31, a row's members at 32.
        let (model, screen, _) = makeModel()
        let a = text(16, 16), b = text(128, 16)
        let thirty = nested(30, holding: [text(16, 300), a, b])
        add([thirty.outer], to: screen, in: model)
        #expect(model.store.index[thirty.innermost]?.depth == 30)
        model.structurePass(over: [a.id, b.id])
        #expect(model.store.node(thirty.innermost)?.children.contains { $0.kind == .group } == true)

        // At depth 31 a row would put its members at 33.
        let (deep, deepScreen, _) = makeModel()
        let c = text(16, 16), d = text(128, 16)
        let thirtyOne = nested(31, holding: [text(16, 300), c, d])
        add([thirtyOne.outer], to: deepScreen, in: deep)
        #expect(deep.store.index[thirtyOne.innermost]?.depth == 31)
        let before = deep.store.tree
        deep.structurePass(over: [c.id, d.id])
        #expect(deep.store.tree == before)
        #expect(deep.structureOffer == nil)

        // A row proposed as if the card were on the screen's root is refused by `build`.
        let card = try #require(deep.store.node(thirtyOne.innermost))
        let row = try #require(StructureInference.infer(in: card, new: [c.id, d.id], tokens: .standard).first.map { decision in
            switch decision { case .apply(let structure), .offer(let structure): structure }
        })
        #expect(row.kind == .row)
        #expect(deep.store.build(row) == nil)
        #expect(deep.store.tree == before)
    }

    // MARK: - Growing

    @Test func aGridDrawnCellByCellIsOneGrid() async throws {
        let (model, screen, _) = makeModel()
        let cells = ["box 40 300 140 120 8; cross 40 300 140 120", "box 213 300 140 120 8; cross 213 300 140 120",
                     "box 40 436 140 120 8; cross 40 436 140 120", "box 213 436 140 120 8; cross 213 436 140 120"]

        try await draw(cells[0], on: model, keys: 1)
        let first = try #require(rootChildren(model, screen).first)
        #expect(first.kind == .image)

        try await draw(cells[1], on: model, keys: 11)
        let row = try #require(rootChildren(model, screen).first)
        #expect(rootChildren(model, screen).count == 1)
        guard case .stack(let stack) = row.resolvedLayout else {
            Issue.record("not a row: \(row.resolvedLayout)")
            return
        }
        #expect(stack.axis == .horizontal)
        #expect(row.children.first?.id == first.id)
        let second = try #require(row.children.last)

        try await draw(cells[2], on: model, keys: 21)
        #expect(rootChildren(model, screen).count == 2, "the third alone makes nothing")
        #expect(rootChildren(model, screen).first?.id == row.id)
        let third = try #require(rootChildren(model, screen).last)
        #expect(third.kind == .image)

        try await draw(cells[3], on: model, keys: 31)
        let root = rootChildren(model, screen)
        #expect(root.count == 1)
        let grid = try #require(root.first)
        #expect(grid.layout?.isGrid == true)
        #expect(grid.children.count == 4)
        #expect(grid.children.allSatisfy { $0.kind == .image })
        #expect(Array(grid.children.map(\.id).prefix(3)) == [first.id, second.id, third.id])
        #expect(model.store.node(row.id) == nil, "no row is left")
    }

    // MARK: - Cost

    /// F7: one pass that builds a row on a screen of 100 things lays out the row and the root at most once each, and
    /// nothing else.
    @Test func aPassLaysOutOnlyWhatItBuilt() throws {
        let (model, screen, _) = makeModel()
        var things: [LayerNode] = []
        var cards: [UUID] = []
        for index in 0..<10 {
            var card = LayerNode(kind: .card)
            card.frame = CGRect(x: 10 + CGFloat(index % 5) * 76, y: 20 + CGFloat(index / 5) * 70, width: 70, height: 60)
            card.children = [text(2, 2, 30, 20), text(36, 2, 30, 20), text(2, 32, 30, 20), text(36, 32, 30, 20)]
            cards.append(card.id)
            things.append(card)
        }
        for index in 0..<48 {
            things.append(text(10 + CGFloat(index % 8) * 47, 170 + CGFloat(index / 8) * 40, 40, 20))
        }
        let a = text(20, 780), b = text(132, 780)
        things += [a, b]
        #expect(things.count + 40 == 100)
        #expect(model.store.replaceChildren(of: .screen(screen), with: things))
        let rootID = try #require(model.store.treeScreen(screen)?.root.id)
        let rootBefore = LayoutEngine.timesLaidOut(rootID)
        let cardsBefore = cards.map(LayoutEngine.timesLaidOut)

        model.structurePass(over: [a.id, b.id])

        let row = try #require(rootChildren(model, screen).first { $0.kind == .group })
        #expect(row.children.map(\.id) == [a.id, b.id])
        #expect(LayoutEngine.timesLaidOut(row.id) <= 1)
        #expect(LayoutEngine.timesLaidOut(rootID) - rootBefore <= 1)
        #expect(cards.map(LayoutEngine.timesLaidOut) == cardsBefore)
    }

    /// F15: with a "Did you mean" up, a change elsewhere on its screen is checked against it from the tree. The check that
    /// it never lowered the design went with the flat list (plan 6, Task 11, clause (s)).
    @Test func theSuggestionsPlaceIsReadFromTheTree() throws {
        let (model, screen, _) = makeModel()
        let fieldSketch = CGRect(x: 30, y: 300, width: 330, height: 44)
        let field = try #require(model.store.addSketched(.textField, from: fieldSketch, confidence: 0.6, decidedBy: .rules))
        let other = text(20, 700)
        add([other], to: screen, in: model)
        model.offer(KindSuggestion(ref: NodeRef(host: .screen(screen), node: field), kind: .button,
                                   sketch: fieldSketch, observation: try observation(of: fieldSketch)))
        var round = 0
        func change() {
            round += 1
            model.store.update(other.id) { $0.name = "Other \(round)" }
        }

        for _ in 0..<3 {
            change()
            model.store.update(other.id) { $0.frame.origin.y += 4 }
        }
        #expect(model.suggestion != nil)
    }
}

private extension LayerNode.Layout {
    var isGrid: Bool {
        if case .grid = self { true } else { false }
    }
}
