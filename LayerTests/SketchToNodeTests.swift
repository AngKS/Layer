import CoreGraphics
import Foundation
import Testing
@testable import Layer

@MainActor
private func makeStore(_ device: DeviceFrame = .iPhone, origin: CGPoint = .zero,
                       scale: CGFloat = 1) -> (store: DesignStore, screen: TreeScreen.ID, undo: UndoManager) {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore(content: DesignContent())
    store.undoManager = undo
    let screen = store.addScreen(device, at: Placement(origin: origin, scale: scale))
    return (store, screen.id, undo)
}

@MainActor
private func root(of screen: TreeScreen.ID, in store: DesignStore) throws -> LayerNode {
    try #require(store.treeScreen(screen)).root
}

private func leaf(_ kind: ElementKind, _ frame: CGRect) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    node.content.text = kind.placeholder
    return node
}

/// A row at (20, 300) on the screen, fitting what it holds: two buttons, each fixed at 100 × 44, 12 apart.
private func rowOfTwoButtons() -> LayerNode {
    var row = LayerNode(kind: .group)
    row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 12))
    row.width = LayerNode.Sizing(.fit)
    row.height = LayerNode.Sizing(.fit)
    row.frame = CGRect(x: 20, y: 300, width: 212, height: 44)
    row.children = [leaf(.button, CGRect(x: 0, y: 0, width: 100, height: 44)),
                    leaf(.button, CGRect(x: 112, y: 0, width: 100, height: 44))]
    return row
}

/// An iPhone screen at the canvas's origin, at its own size, holding `children`: the tree with no store round it.
private func screenHolding(_ children: [LayerNode]) -> TreeContent {
    var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
    screen.root.children = children
    var content = TreeContent()
    content.screens = [screen]
    return content
}

/// The box round a thing's turned shape, in its parent's space.
private func shapeBox(_ node: LayerNode) -> CGRect { TreeEdit.shapesBox(of: [node]) ?? node.frame }

/// A thing on a 20-point grid near the top of the screen, sometimes locked, hidden or turned.
private func randomThing(_ random: inout SeededGenerator) -> LayerNode {
    let kind: ElementKind = Bool.random(using: &random) ? .text : .image
    let x = Int.random(in: 0..<15, using: &random), y = Int.random(in: 0..<15, using: &random)
    let width = Int.random(in: 1..<11, using: &random), height = Int.random(in: 1..<11, using: &random)
    var node = leaf(kind, CGRect(x: 20 * x, y: 20 * y, width: 20 * width, height: 20 * height))
    node.isLocked = Double.random(in: 0..<1, using: &random) < 0.3
    node.isHidden = Double.random(in: 0..<1, using: &random) < 0.15
    if Double.random(in: 0..<1, using: &random) < 0.1 { node.rotation = 30 }
    return node
}

/// What goes out of sight when `made`, a card, goes into `root` (a screen's root, its children back to front): each
/// thing that was seen and is wholly hidden by one thing drawn over it after, and the card if it is. Each thing is
/// drawn opaque, as the box round its shape, and a hidden thing isn't drawn. Several things that hide something only
/// together are the accepted case, and aren't looked for.
private func whatGoesOutOfSight(_ made: SketchedNode.Made, into root: LayerNode) -> [String] {
    let things = root.children
    let after = SketchedNode.inserting(made, into: root)
    guard let card = after.children.first(where: { $0.id == made.node.id }) else { return ["the card isn't there"] }
    let taken = Set(card.children.map(\.id))
    let place = Dictionary(uniqueKeysWithValues: things.enumerated().map { ($1.id, $0) })

    // Drawn after, back to front, in the screen's points: the card, then what it holds, where the card is.
    var drawnAfter: [(id: UUID, box: CGRect)] = []
    for child in after.children where !child.isHidden {
        drawnAfter.append((child.id, child.id == card.id ? card.frame : shapeBox(child)))
        if child.id == card.id {
            drawnAfter += card.children.map { ($0.id, shapeBox($0).offsetBy(dx: card.frame.minX, dy: card.frame.minY)) }
        }
    }
    var wrong: [String] = []
    let kept = Set(after.children.flatMap { TreeEdit.ids(in: $0) })
    if kept != Set(things.map(\.id)).union([card.id]) { wrong.append("something was lost") }
    for (id, box) in drawnAfter where id != card.id {
        if let was = place[id], box != shapeBox(things[was]) { wrong.append("thing \(was) moved") }
    }

    func wasSeen(_ index: Int) -> Bool {
        !things[index].isHidden
            && !things[(index + 1)...].contains { !$0.isHidden && shapeBox($0).contains(shapeBox(things[index])) }
    }
    for (position, drawnThing) in drawnAfter.enumerated() {
        let over = drawnAfter[(position + 1)...]
        if drawnThing.id == card.id {
            // What it holds is drawn on it, and hides none of it.
            if over.contains(where: { !taken.contains($0.id) && $0.box.contains(card.frame) }) {
                wrong.append("the card")
            }
            continue
        }
        guard let was = place[drawnThing.id], wasSeen(was) else { continue }
        if over.contains(where: { $0.box.contains(drawnThing.box) }) {
            wrong.append(taken.contains(drawnThing.id) ? "thing \(was), taken" : "thing \(was)")
        }
    }
    return wrong
}

/// Whether some slot among `root`'s children would put `made`, a card, where nothing goes out of sight.
private func someSlotKeepsEverythingInSight(_ made: SketchedNode.Made, in root: LayerNode) -> Bool {
    let slots = root.children.filter { !made.takes.contains($0.id) }.map { Optional($0.id) } + [nil]
    return slots.contains { behind in
        var elsewhere = made
        elsewhere.behind = behind
        return whatGoesOutOfSight(elsewhere, into: root).isEmpty
    }
}

/// Strokes as the Magic Pen hands them over, keyed 1, 2, … .
private func strokes(_ script: String) throws -> [SketchStroke] {
    try StrokeScript.parse(script).enumerated().map { SketchStroke(key: Double($0.offset + 1), points: $0.element) }
}

@MainActor
private func makeModel() -> (model: AppModel, undo: UndoManager) {
    let model = AppModel(document: LayerDocument())
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    // No word is read out of the strokes: what they are is the shape's alone.
    model.engine.readHandwriting = { _ in nil }
    return (model, undo)
}

/// What a reading becomes on a screen (spec §5, plan 5's calls 6 to 8): a node where its sketch lands, laid out there,
/// remembering its sketch.
@Suite @MainActor struct SketchToNodeTests {
    @Test func aSketchedButtonIsANodeWithItsIntent() throws {
        let (store, screen, _) = makeStore()
        let sketch = CGRect(x: 30, y: 700, width: 330, height: 56)

        let id = try #require(store.addSketched(.button, from: sketch, confidence: 0.91, decidedBy: .rules))

        let node = try #require(try root(of: screen, in: store).children.last)
        #expect(node.id == id)
        #expect(node.kind == .button)
        #expect(node.frame == ElementLayout.sketched(.button, sketch: sketch, on: .iPhone, among: []).frame)
        #expect(node.width.mode == .fixed && node.height.mode == .fixed)
        #expect(node.content.text == "Continue")
        // No colour of its own: its kind's, the accent, is what it is drawn in.
        #expect(node.style.tint == nil)
        #expect(node.resolvedTint == Theme.accent)
        let intent = try #require(node.sketch)
        #expect(intent.originalBounds == sketch)
        #expect(intent.normalizedBounds == CGRect(x: 30.0 / 393, y: 700.0 / 852, width: 330.0 / 393, height: 56.0 / 852))
        #expect(intent.confidence == 0.91)
        #expect(intent.decidedBy == .rules)
        #expect(intent.placement == .proportional)
        #expect(!intent.structureDeclined)
    }

    @Test func aSketchedLeafHasNoColourOfItsOwnAndLooksAsItDid() throws {
        let (store, _, _) = makeStore()
        let button = try #require(store.addSketched(.button, from: CGRect(x: 30, y: 700, width: 330, height: 56),
                                                    confidence: 1, decidedBy: .rules))
        let title = try #require(store.addSketched(.title, from: CGRect(x: 150, y: 112, width: 96, height: 40),
                                                   confidence: 1, decidedBy: .rules))

        for id in [button, title] {
            #expect(store.node(id)?.style.tint == nil)
            #expect(store.node(id)?.resolvedTint == Theme.accent)
        }
        // Exported as it would be with the accent written on each: the kind's own colour needs no saying.
        var given = store.tree
        given.screens[0].root.children = given.screens[0].root.children.map { node in
            var tinted = node
            tinted.style.tint = Theme.accent
            return tinted
        }
        let settings = CodeSettings(includesPreview: false)
        let exported = SwiftUICodeGenerator.files(for: store.tree, settings: settings)
        let withAccent = SwiftUICodeGenerator.files(for: given, settings: settings)
        #expect(!exported.isEmpty)
        #expect(exported.map(\.source) == withAccent.map(\.source))
    }

    @Test func onAHalfScaleScreenTheIntentIsInScreenPoints() throws {
        let (store, screen, _) = makeStore(origin: CGPoint(x: 1000, y: 0), scale: 0.5)

        let id = try #require(store.addSketched(.button, from: CGRect(x: 1015, y: 350, width: 165, height: 28),
                                                confidence: 0.91, decidedBy: .rules))

        let node = try #require(store.node(id))
        let drawn = CGRect(x: 30, y: 700, width: 330, height: 56)
        #expect(node.sketch?.originalBounds == drawn)
        #expect(node.frame == ElementLayout.sketched(.button, sketch: drawn, on: .iPhone, among: []).frame)
        #expect(try root(of: screen, in: store).children.map(\.id) == [id])
    }

    @Test func aTitleTakesItsSizeFromHowTallItWasDrawn() throws {
        let (store, _, _) = makeStore()
        let small = try #require(store.addSketched(.title, from: CGRect(x: 120, y: 150, width: 160, height: 24),
                                                   confidence: 1, decidedBy: .rules))
        let usual = try #require(store.addSketched(.title, from: CGRect(x: 120, y: 300, width: 160, height: 44),
                                                   confidence: 1, decidedBy: .rules))
        let large = try #require(store.addSketched(.title, from: CGRect(x: 120, y: 450, width: 160, height: 64),
                                                   confidence: 1, decidedBy: .rules))

        #expect(store.node(small)?.style.fontSize == ElementLayout.titleTwoSize)
        #expect(store.node(usual)?.style.fontSize == nil)
        #expect(store.node(large)?.style.fontSize == ElementLayout.largeTitleSize)
    }

    @Test func inAFreeCardItIsPlacedInTheCardsSpace() throws {
        let (store, screen, _) = makeStore()
        var card = LayerNode(kind: .card)
        card.frame = CGRect(x: 20, y: 100, width: 353, height: 200)
        card.children = [leaf(.text, CGRect(x: 20, y: 10, width: 100, height: 20))]
        #expect(store.add(card, to: .screen(screen)))
        let held = try #require(store.node(card.id)).children.map(\.frame)

        let id = try #require(store.addSketched(.text, from: CGRect(x: 60, y: 140, width: 120, height: 24),
                                                confidence: 1, decidedBy: .rules))

        let inCard = try #require(store.node(card.id))
        #expect(inCard.children.last?.id == id)
        let standIn = DeviceFrame.custom(name: "Card", size: CGSize(width: 353, height: 200), family: .phone)
        let laid = ElementLayout.sketched(.text, sketch: CGRect(x: 40, y: 40, width: 120, height: 24), on: standIn, among: held)
        #expect(store.node(id)?.frame == laid.frame)
        #expect(store.node(id)?.style.textAlignment == laid.alignment)
        // What it remembers is in the screen's points, on the screen's device.
        #expect(store.node(id)?.sketch?.originalBounds == CGRect(x: 60, y: 140, width: 120, height: 24))
        #expect(try root(of: screen, in: store).children.map(\.id) == [card.id])
    }

    @Test func aContainerNarrowerThanItsMarginsStillGivesItAWidth() throws {
        let (store, screen, _) = makeStore()
        var group = LayerNode(kind: .group)
        group.frame = CGRect(x: 180, y: 400, width: 30, height: 60)
        group.children = [leaf(.symbol, CGRect(x: 0, y: 0, width: 30, height: 30)), leaf(.symbol, CGRect(x: 0, y: 30, width: 30, height: 30))]
        #expect(store.add(group, to: .screen(screen)))

        // A button drawn across the screen, its middle in the group: the group's 30 points are less than a button's margins.
        let id = try #require(store.addSketched(.button, from: CGRect(x: 100, y: 410, width: 200, height: 40),
                                                confidence: 1, decidedBy: .rules))

        #expect(store.node(group.id)?.children.last?.id == id)
        let frame = try #require(store.node(id)?.frame)
        #expect(frame.size.width == ElementKind.button.spec.minimumSize.width)
        #expect(frame.midX == 20)
    }

    @Test func inARowItTakesItsSlotAndItsSiblingsSize() throws {
        let (store, screen, _) = makeStore()
        let row = rowOfTwoButtons()
        #expect(store.add(row, to: .screen(screen)))

        // Between the two buttons, whose middles are at 70 and 182 on the screen.
        let button = try #require(store.addSketched(.button, from: CGRect(x: 101, y: 304, width: 50, height: 36),
                                                    confidence: 1, decidedBy: .rules))

        let laidOut = try #require(store.node(row.id))
        #expect(laidOut.children.map(\.id) == [row.children[0].id, button, row.children[1].id])
        let added = try #require(store.node(button))
        #expect(added.width.mode == .fixed && added.height.mode == .fixed)
        #expect(added.frame.size == CGSize(width: 100, height: 44))
        #expect(added.sketch?.originalBounds == CGRect(x: 101, y: 304, width: 50, height: 36))

        // A text, with no text in the row to match, takes the sizing a text starts with.
        let text = try #require(store.addSketched(.text, from: CGRect(x: 30, y: 310, width: 30, height: 24),
                                                  confidence: 1, decidedBy: .rules))
        #expect(store.node(row.id)?.children.first?.id == text)
        let natural = NaturalSize.defaultSizing(for: .text)
        #expect(store.node(text)?.width == natural.width)
        #expect(store.node(text)?.height == natural.height)
    }

    @Test func aCardTakesWhatItEncloses() throws {
        let (store, screen, undo) = makeStore()
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        // Its last 4 points are past the card's drawn bottom: 60 of its 64 are inside.
        let body = leaf(.body, CGRect(x: 20, y: 160, width: 353, height: 64))
        #expect(store.add(title, to: .screen(screen)))
        #expect(store.add(body, to: .screen(screen)))
        let before = try root(of: screen, in: store)

        let card = try #require(store.asOwnStep {
            store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120), confidence: 0.95, decidedBy: .rules)
        })

        let after = try root(of: screen, in: store)
        #expect(after.children.map(\.id) == [card])
        let made = try #require(store.node(card))
        #expect(made.kind == .card)
        #expect(made.children.map(\.id) == [title.id, body.id])
        #expect(store.placed(title.id)?.frame == title.frame)
        #expect(store.placed(body.id)?.frame == body.frame)
        // The drawn box, grown to hold what it took.
        #expect(made.frame == CGRect(x: 10, y: 100, width: 373, height: 124))
        #expect(made.width.mode == .fixed && made.height.mode == .fixed)
        #expect(made.layout == nil)
        #expect(made.padding == LayerNode.Padding(all: 16))
        #expect(made.style.tint == nil)
        #expect(made.content.text == "")
        #expect(made.sketch?.originalBounds == CGRect(x: 10, y: 100, width: 373, height: 120))
        #expect(made.sketch?.confidence == 0.95)

        undo.undo()
        #expect(try root(of: screen, in: store) == before)
        #expect(store.placed(title.id)?.frame == title.frame)
        #expect(store.placed(body.id)?.frame == body.frame)
    }

    @Test func aCardInARowTakesNothing() throws {
        let (store, screen, _) = makeStore()
        let row = rowOfTwoButtons()
        #expect(store.add(row, to: .screen(screen)))

        // Over the second button and past it, its centre in the row after that button's middle.
        let card = try #require(store.addSketched(.card, from: CGRect(x: 150, y: 296, width: 100, height: 52),
                                                  confidence: 0.95, decidedBy: .rules))

        let laidOut = try #require(store.node(row.id))
        #expect(laidOut.children.map(\.id) == [row.children[0].id, row.children[1].id, card])
        #expect(store.node(card)?.children.isEmpty == true)
        #expect(try root(of: screen, in: store).children.map(\.id) == [row.id])
        // As drawn: the row places it, at its drawn size.
        #expect(store.node(card)?.frame.size == CGSize(width: 100, height: 52))
        #expect(store.node(card)?.width.mode == .fixed)
        #expect(store.node(card)?.height.mode == .fixed)
    }

    @Test func aCardInAColumnKeepsItsDrawnBox() throws {
        let (store, screen, _) = makeStore()
        // A screen laid out as a column, as a generated one is, holding a title.
        store.updateTreeScreen(screen) { $0.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 16)) }
        #expect(store.add(leaf(.title, CGRect(x: 0, y: 0, width: 393, height: 40)), to: .screen(screen)))

        let empty = try #require(store.addSketched(.card, from: CGRect(x: 40, y: 300, width: 200, height: 120),
                                                   confidence: 0.6, decidedBy: .rules))
        let card = try #require(store.node(empty))
        #expect(card.height.mode == .fixed && card.width.mode == .fixed)
        #expect(card.frame.size == CGSize(width: 200, height: 120))

        // Drawn across the screen, between its margins, it is as wide as the column.
        let across = try #require(store.addSketched(.card, from: CGRect(x: 25, y: 500, width: 345, height: 80),
                                                    confidence: 0.6, decidedBy: .rules))
        let wide = try #require(store.node(across))
        #expect(wide.sketch?.placement == .proportional)
        #expect(wide.width.mode == .fill(weight: 1))
        #expect(wide.height.mode == .fixed)
        // The column on a screen lies inside the screen's margins.
        let column = DeviceFrame.iPhone.size.width - 2 * DeviceFrame.iPhone.margin
        #expect(wide.frame.size == CGSize(width: column, height: 80))
        #expect(try root(of: screen, in: store).children.map(\.id).suffix(2) == [empty, across])
    }

    /// Call 6, as plan 5's final review ruled it (B1 and its follow-up): an outline round two fields of a column the pass
    /// built makes a card holding both, in the column where they were. The card is the person's own, so it has the
    /// design's card padding round them: the fields before it don't move, and the field after it moves down by exactly
    /// the padding it adds.
    @Test func aCardRoundTwoFieldsOfABuiltColumnTakesThemWhereTheyAre() async throws {
        let (model, undo) = makeModel()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1)).id
        let fields = (0..<4).map { leaf(.textField, CGRect(x: 20, y: 100 + 60 * CGFloat($0), width: 353, height: 44)) }
        for field in fields { #expect(model.store.add(field, to: .screen(screen))) }
        model.structurePass(over: fields.map(\.id))
        let column = try #require(model.store.treeScreen(screen)?.root.children.first)
        try #require(column.sketch?.decidedBy == .structure)
        try #require(column.children.map(\.id) == fields.map(\.id))
        let before = fields.map { model.store.placed($0.id)?.frame }

        // Round the second and third, 10 pt clear of them.
        let outline = try strokes("box 10 150 373 124 16")
        let drawn = try #require(SketchAnalyzer.observe(outline)).bounds
        model.sketchChanged(outline)
        model.convertNow()
        // With no ink canvas here, the sketch is taken away by hand, as the canvas does once it is read.
        model.sketchChanged([])
        await model.waitForConversions()

        let after = try #require(model.store.node(column.id))
        #expect(after.children.count == 3)
        let card = try #require(after.children.dropFirst().first)
        #expect(card.kind == .card)
        #expect(after.children.map(\.id) == [fields[0].id, card.id, fields[3].id])
        #expect(card.children.map(\.id) == [fields[1].id, fields[2].id])
        // It holds them as the column did, padded as a card is, and fits them.
        let padding = DesignTokens.standard.card.padding
        #expect(card.layout == column.layout)
        #expect(card.padding == LayerNode.Padding(all: padding))
        #expect(card.width.mode == .fit && card.height.mode == .fit)
        #expect(card.frame == CGRect(x: 0, y: 60, width: 353 + 2 * padding, height: 104 + 2 * padding))
        let now = fields.map { model.store.placed($0.id)?.frame }
        #expect(now[0] == before[0])
        #expect(now[1] == before[1]?.offsetBy(dx: padding, dy: padding))
        #expect(now[2] == before[2]?.offsetBy(dx: padding, dy: padding))
        #expect(now[3] == before[3]?.offsetBy(dx: 0, dy: 2 * padding))
        #expect(card.style.tint == nil)
        #expect(card.sketch?.originalBounds == drawn)

        undo.undo()
        #expect(model.store.node(column.id)?.children.map(\.id) == fields.map(\.id))
        #expect(fields.map { model.store.placed($0.id)?.frame } == before)
    }

    /// In a row, the card is a row of what it takes, at their slot, padded: the button after it moves along by exactly
    /// the padding it adds (B1 and its follow-up).
    @Test func aCardRoundMembersOfARowHoldsThemAsTheRowDid() throws {
        let (store, screen, undo) = makeStore()
        var row = rowOfTwoButtons()
        row.children.append(leaf(.button, CGRect(x: 224, y: 0, width: 100, height: 44)))
        #expect(store.add(row, to: .screen(screen)))
        let buttons = row.children.map(\.id)
        let before = buttons.map { store.placed($0)?.frame }

        // Round the first two, at (20, 300) and (132, 300) on the screen; the third is at (244, 300).
        let card = try #require(store.asOwnStep {
            store.addSketched(.card, from: CGRect(x: 12, y: 290, width: 228, height: 64), confidence: 0.95, decidedBy: .rules)
        })

        #expect(store.node(row.id)?.children.map(\.id) == [card, buttons[2]])
        let made = try #require(store.node(card))
        #expect(made.children.map(\.id) == [buttons[0], buttons[1]])
        let padding = DesignTokens.standard.card.padding
        #expect(made.layout == row.layout)
        #expect(made.padding == LayerNode.Padding(all: padding))
        #expect(made.frame == CGRect(x: 0, y: 0, width: 212 + 2 * padding, height: 44 + 2 * padding))
        let now = buttons.map { store.placed($0)?.frame }
        #expect(now[0] == before[0]?.offsetBy(dx: padding, dy: padding))
        #expect(now[1] == before[1]?.offsetBy(dx: padding, dy: padding))
        #expect(now[2] == before[2]?.offsetBy(dx: 2 * padding, dy: 0))

        undo.undo()
        #expect(store.node(row.id)?.children.map(\.id) == buttons)
    }

    /// A card round one cell of a grid takes it in its cell, padded. Round two, it would move each cell after them back a
    /// cell, so it lands round the grid instead and goes behind it, and nothing moves (B1 and its follow-up).
    @Test func aCardTakesOneCellOfAGridAndLiesBehindTwo() throws {
        let (store, screen, _) = makeStore()
        var grid = LayerNode(kind: .group)
        grid.layout = .grid(LayerNode.Grid(columns: 2, columnSpacing: 12, rowSpacing: 16,
                                           alignment: LayerNode.Alignment(horizontal: .start, vertical: .start)))
        (grid.width, grid.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
        grid.frame = CGRect(x: 30, y: 300, width: 332, height: 256)
        grid.children = [(0, 0), (172, 0), (0, 136), (172, 136)].map { x, y in
            leaf(.image, CGRect(x: x, y: y, width: 160, height: 120))
        }
        #expect(store.add(grid, to: .screen(screen)))
        let cells = grid.children.map(\.id)
        let before = cells.map { store.placed($0)?.frame }

        // Round the second cell, at (202, 300) on the screen.
        let one = try #require(store.addSketched(.card, from: CGRect(x: 196, y: 294, width: 172, height: 132),
                                                 confidence: 0.95, decidedBy: .rules))
        #expect(store.node(grid.id)?.children.map(\.id) == [cells[0], one, cells[2], cells[3]])
        let padding = DesignTokens.standard.card.padding
        let held = try #require(store.node(one))
        #expect(held.children.map(\.id) == [cells[1]])
        #expect(held.padding == LayerNode.Padding(all: padding))
        #expect(held.frame.size == CGSize(width: 160 + 2 * padding, height: 120 + 2 * padding))
        #expect(store.placed(cells[0])?.frame == before[0])
        let card = try #require(store.placed(one)?.frame)
        #expect(store.placed(cells[1])?.frame == CGRect(x: card.minX + padding, y: card.minY + padding, width: 160, height: 120))

        // Round the first row: the first cell, and the card holding the second.
        let firstRow = try #require(store.placed(cells[0])?.frame).union(card)
        let laidOut = cells.map { store.placed($0)?.frame }
        let two = try #require(store.addSketched(.card, from: firstRow.insetBy(dx: -10, dy: -10),
                                                 confidence: 0.95, decidedBy: .rules))
        #expect(try root(of: screen, in: store).children.map(\.id) == [two, grid.id])
        #expect(store.node(two)?.children.isEmpty == true)
        #expect(store.node(grid.id)?.children.map(\.id) == [cells[0], one, cells[2], cells[3]])
        #expect(cells.map { store.placed($0)?.frame } == laidOut)
    }

    /// What a card takes in a column is one unbroken run: round two fields with a locked one between them, it lands
    /// round the column and goes behind it, and nothing moves (B1).
    @Test func aCardRoundALockedMemberOfAColumnLiesBehindIt() throws {
        let (store, screen, _) = makeStore()
        var column = LayerNode(kind: .group)
        column.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 16))
        (column.width, column.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
        column.frame = CGRect(x: 20, y: 100, width: 353, height: 224)
        column.children = (0..<4).map { leaf(.textField, CGRect(x: 0, y: 60 * CGFloat($0), width: 353, height: 44)) }
        column.children[1].isLocked = true
        #expect(store.add(column, to: .screen(screen)))
        let fields = column.children.map(\.id)
        let before = fields.map { store.placed($0)?.frame }

        // Round the first three, and so not round the column.
        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 90, width: 373, height: 184),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(try root(of: screen, in: store).children.map(\.id) == [card, column.id])
        #expect(store.node(card)?.children.isEmpty == true)
        #expect(store.node(column.id)?.children.map(\.id) == fields)
        #expect(fields.map { store.placed($0)?.frame } == before)
    }

    @Test func aCardLeavesLockedThingsWhereTheyAre() throws {
        let (store, screen, _) = makeStore()
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        var body = leaf(.body, CGRect(x: 20, y: 160, width: 353, height: 50))
        body.isLocked = true
        #expect(store.add(title, to: .screen(screen)))
        #expect(store.add(body, to: .screen(screen)))

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        // The card goes behind the locked body, which it can't take, so the body is still seen.
        #expect(try root(of: screen, in: store).children.map(\.id) == [card, body.id])
        #expect(store.node(card)?.children.map(\.id) == [title.id])
        #expect(store.node(card)?.frame == CGRect(x: 10, y: 100, width: 373, height: 120))
        #expect(store.placed(body.id)?.frame == body.frame)
        #expect(store.placed(title.id)?.frame == title.frame)
    }

    @Test func aCardOverALockedBackgroundIsInFrontOfIt() throws {
        let (store, screen, _) = makeStore()
        var background = leaf(.image, CGRect(x: 0, y: 0, width: 393, height: 852))
        background.isLocked = true
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        #expect(store.add(background, to: .screen(screen)))
        #expect(store.add(title, to: .screen(screen)))

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.children.map(\.id) == [title.id])
        #expect(try root(of: screen, in: store).children.map(\.id) == [background.id, card])
    }

    @Test func aCardStaysInFrontOfABackgroundWhateverIsBehindIt() throws {
        let (store, screen, _) = makeStore()
        // Partly under the card, but behind the background, which already hides it.
        let note = leaf(.text, CGRect(x: 250, y: 205, width: 100, height: 50))
        var background = leaf(.image, CGRect(x: 0, y: 0, width: 393, height: 852))
        background.isLocked = true
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        for node in [note, background, title] { #expect(store.add(node, to: .screen(screen))) }

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(try root(of: screen, in: store).children.map(\.id) == [note.id, background.id, card])
    }

    @Test func aTitleOverALockedImageStaysInFrontOfIt() throws {
        let (store, screen, _) = makeStore()
        // A locked hero image with a title over it. The card is drawn round the title and past the image's bottom, so
        // it overlaps the image without lying on it whole.
        var image = leaf(.image, CGRect(x: 0, y: 0, width: 393, height: 200))
        image.isLocked = true
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        #expect(store.add(image, to: .screen(screen)))
        #expect(store.add(title, to: .screen(screen)))

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 160),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.children.map(\.id) == [title.id])
        // The title, in the card now, is still in front of the image it was over.
        #expect(try root(of: screen, in: store).children.map(\.id) == [image.id, card])
        #expect(store.placed(title.id)?.frame == title.frame)
        #expect(store.placed(image.id)?.frame == image.frame)
    }

    @Test func aHiddenThingIsNoBackground() throws {
        let (store, screen, _) = makeStore()
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        // Wholly inside the card drawn below, and locked, so the card leaves it where it is.
        var note = leaf(.text, CGRect(x: 20, y: 160, width: 353, height: 40))
        note.isLocked = true
        // As big as the screen, but hidden: it isn't drawn, so the card doesn't lie on it.
        var hidden = leaf(.image, CGRect(x: 0, y: 0, width: 393, height: 852))
        hidden.isHidden = true
        for node in [title, note, hidden] { #expect(store.add(node, to: .screen(screen))) }

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.children.map(\.id) == [title.id])
        // The card goes behind the locked note, which is still seen.
        #expect(try root(of: screen, in: store).children.map(\.id) == [card, note.id, hidden.id])
    }

    @Test func aHiddenThingUnderWhatItTakesKeepsItInFrontOfNothing() throws {
        let (store, screen, _) = makeStore()
        // Wholly inside the card drawn below, and locked, so the card leaves it where it is.
        var note = leaf(.text, CGRect(x: 20, y: 160, width: 353, height: 40))
        note.isLocked = true
        // Behind the title and overlapping it, but hidden: the card needn't stay in front of it.
        var hidden = leaf(.image, CGRect(x: 20, y: 100, width: 200, height: 60))
        hidden.isHidden = true
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        for node in [note, hidden, title] { #expect(store.add(node, to: .screen(screen))) }

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.children.map(\.id) == [title.id])
        // The card goes behind the locked note, which is still seen.
        #expect(try root(of: screen, in: store).children.map(\.id) == [card, note.id, hidden.id])
    }

    /// The limit, accepted: where no single slot keeps everything in sight, the card may hide something. For instance,
    /// a thing the card would cover whole lay behind a thing that holds what the card takes: the card must be in front
    /// of the one and behind the other. Several things that only together cover something aren't looked for either.
    @Test func aCardDrawnAmongThingsHidesNothingThatWasSeen() {
        // Small arrangements on a 20-point grid, the same every run: things that overlap, some locked, hidden or
        // turned, and a card drawn among them.
        var random = SeededGenerator(seed: 2026_11_25)
        var wrong: [String] = []
        for arrangement in 0..<10_000 {
            let things = (0..<Int.random(in: 1...5, using: &random)).map { _ in randomThing(&random) }
            let x = Int.random(in: 0..<10, using: &random), y = Int.random(in: 0..<10, using: &random)
            let width = Int.random(in: 2..<11, using: &random), height = Int.random(in: 2..<11, using: &random)
            let drawn = CGRect(x: 20 * x, y: 20 * y, width: 20 * width, height: 20 * height)
            let content = screenHolding(things)
            guard let made = SketchedNode.make(.card, sketch: drawn, in: content, index: TreeIndex(content),
                                               confidence: 1, decidedBy: .rules)
            else {
                wrong.append("\(arrangement): no card")
                continue
            }
            let root = content.screens[0].root
            let found = whatGoesOutOfSight(made, into: root)
            // Only a plain "thing N" going out of sight is excused, and only where no slot would keep it in sight:
            // a loss, a move or a missing card never depends on the slot, and fails whatever the slots allow.
            let isPlainThing: (String) -> Bool = { $0.hasPrefix("thing ") && Int($0.dropFirst("thing ".count)) != nil }
            if !found.isEmpty, !found.allSatisfy(isPlainThing) || someSlotKeepsEverythingInSight(made, in: root) {
                wrong.append("\(arrangement): \(found.joined(separator: ", "))")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) arrangements hide something they needn't, first \(wrong.prefix(5))")
    }

    @Test func aLockedBadgeTuckedUnderATitleStaysInSight() throws {
        let (store, screen, _) = makeStore()
        // Locked, so the card leaves it where it is; behind the title's corner, and wholly inside the card drawn below.
        var badge = leaf(.image, CGRect(x: 300, y: 140, width: 30, height: 30))
        badge.isLocked = true
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        #expect(store.add(badge, to: .screen(screen)))
        #expect(store.add(title, to: .screen(screen)))

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.children.map(\.id) == [title.id])
        // In front of the card it would be lost under, the badge, which lay behind the title, now covers its corner: the order
        // flipped, and no slot can avoid that.
        #expect(try root(of: screen, in: store).children.map(\.id) == [card, badge.id])
        #expect(store.placed(badge.id)?.frame == badge.frame)
    }

    @Test func anOrdinaryThingPartlyUnderACardStaysInFrontOfIt() throws {
        let (store, screen, _) = makeStore()
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        // 15 of its 50 points tall are under the card drawn below: too little to take.
        let text = leaf(.text, CGRect(x: 250, y: 205, width: 100, height: 50))
        #expect(store.add(title, to: .screen(screen)))
        #expect(store.add(text, to: .screen(screen)))

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.children.map(\.id) == [title.id])
        #expect(try root(of: screen, in: store).children.map(\.id) == [card, text.id])
        #expect(store.placed(text.id)?.frame == text.frame)
    }

    @Test func aCardGoesBehindALockedThingPartlyUnderIt() throws {
        let (store, screen, _) = makeStore()
        let title = leaf(.title, CGRect(x: 20, y: 112, width: 353, height: 40))
        // 40 of its 100 points tall are under the card drawn below: too little to take, and locked besides.
        var image = leaf(.image, CGRect(x: 250, y: 180, width: 100, height: 100))
        image.isLocked = true
        #expect(store.add(title, to: .screen(screen)))
        #expect(store.add(image, to: .screen(screen)))

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.children.map(\.id) == [title.id])
        #expect(try root(of: screen, in: store).children.map(\.id) == [card, image.id])
        #expect(store.placed(image.id)?.frame == image.frame)
    }

    @Test func aCardGoesBehindATurnedThingInTheBoxItGrewTo() throws {
        let (store, screen, _) = makeStore()
        // 280 of its 300 points tall are inside the card drawn below: the card takes it, and grows 20 points down.
        let image = leaf(.image, CGRect(x: 20, y: 120, width: 200, height: 300))
        // Turned, below the drawn card but inside the box it grows to.
        var symbol = leaf(.symbol, CGRect(x: 250, y: 405, width: 10, height: 10))
        symbol.rotation = 45
        #expect(store.add(image, to: .screen(screen)))
        #expect(store.add(symbol, to: .screen(screen)))

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 300),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.frame == CGRect(x: 10, y: 100, width: 373, height: 320))
        #expect(store.node(card)?.children.map(\.id) == [image.id])
        #expect(try root(of: screen, in: store).children.map(\.id) == [card, symbol.id])
    }

    @Test func aCardGoesBehindTheBackmostThingItCantTake() throws {
        let (store, screen, _) = makeStore()
        let behind = leaf(.text, CGRect(x: 20, y: 400, width: 100, height: 20))
        var turned = leaf(.image, CGRect(x: 40, y: 112, width: 100, height: 60))
        turned.rotation = 10
        let title = leaf(.title, CGRect(x: 160, y: 112, width: 200, height: 40))
        var hidden = leaf(.body, CGRect(x: 20, y: 170, width: 353, height: 40))
        hidden.isHidden = true
        for node in [behind, turned, title, hidden] { #expect(store.add(node, to: .screen(screen))) }

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        // What wasn't under it stays behind it; the turned image and the hidden body, which it can't take, stay in front.
        #expect(try root(of: screen, in: store).children.map(\.id) == [behind.id, card, turned.id, hidden.id])
        #expect(store.node(card)?.children.map(\.id) == [title.id])
    }

    @Test func aGroupInsideBecomesTheCardsChild() throws {
        let (store, screen, _) = makeStore()
        var group = LayerNode(kind: .group)
        group.frame = CGRect(x: 20, y: 112, width: 200, height: 40)
        group.children = [leaf(.symbol, CGRect(x: 0, y: 0, width: 40, height: 40)), leaf(.text, CGRect(x: 52, y: 10, width: 148, height: 20))]
        let body = leaf(.body, CGRect(x: 20, y: 160, width: 353, height: 50))
        #expect(store.add(group, to: .screen(screen)))
        #expect(store.add(body, to: .screen(screen)))
        let held = try #require(store.node(group.id)).children

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(try root(of: screen, in: store).children.map(\.id) == [card])
        #expect(store.node(card)?.children.map(\.id) == [group.id, body.id])
        // The person's group is as it was, where it was.
        #expect(store.node(group.id)?.children == held)
        #expect(store.placed(group.id)?.frame == group.frame)
        #expect(store.placed(body.id)?.frame == body.frame)
    }

    @Test func aCardTakesNothingThatWouldGoPastDepth32() throws {
        /// A sketched card, which a card drawn round it may take, holding cards one inside the next, `levels` below it.
        func sketchedCard(_ frame: CGRect, levels: Int) -> LayerNode {
            var inner: LayerNode?
            for _ in 0..<levels {
                var card = LayerNode(kind: .card)
                card.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
                card.children = inner.map { [$0] } ?? []
                inner = card
            }
            var card = LayerNode(kind: .card)
            card.frame = frame
            card.children = inner.map { [$0] } ?? []
            card.sketch = LayerNode.SketchIntent(sketched: frame, on: DeviceFrame.iPhone.size, margin: 20,
                                                 confidence: 0.95, decidedBy: .rules)
            return card
        }
        let (store, screen, _) = makeStore()
        // On the screen's root, at depth 1: inside a new card at depth 2, the deeper one would reach 33.
        let shallow = sketchedCard(CGRect(x: 20, y: 112, width: 353, height: 40), levels: 30)
        let deep = sketchedCard(CGRect(x: 20, y: 160, width: 353, height: 50), levels: 31)
        #expect(store.add(shallow, to: .screen(screen)))
        #expect(store.add(deep, to: .screen(screen)))

        let card = try #require(store.addSketched(.card, from: CGRect(x: 10, y: 100, width: 373, height: 120),
                                                  confidence: 0.95, decidedBy: .rules))

        #expect(store.node(card)?.children.map(\.id) == [shallow.id])
        // What it can't take stays in front of it.
        #expect(try root(of: screen, in: store).children.map(\.id) == [card, deep.id])
        #expect(store.index[shallow.id]?.depth == 2)
    }

    @Test func theSecondButtonIsBorderedCancel() throws {
        let (store, _, _) = makeStore()
        let first = try #require(store.addSketched(.button, from: CGRect(x: 24, y: 700, width: 160, height: 50),
                                                   confidence: 1, decidedBy: .rules))
        let second = try #require(store.addSketched(.button, from: CGRect(x: 210, y: 704, width: 160, height: 46),
                                                    confidence: 1, decidedBy: .rules))

        #expect(store.node(first)?.content.buttonLook == nil)
        #expect(store.node(first)?.content.text == "Continue")
        #expect(store.node(second)?.content.buttonLook == .bordered)
        #expect(store.node(second)?.content.text == "Cancel")
    }

    @Test func adjustFinishesItInTheSameChange() throws {
        let (store, screen, undo) = makeStore()
        let id = try #require(store.addSketched(.toggle, from: CGRect(x: 300, y: 400, width: 51, height: 31),
                                                confidence: 1, decidedBy: .rules) { $0.content.isOn = false })
        #expect(store.node(id)?.content.isOn == false)

        undo.undo()
        #expect(try root(of: screen, in: store).children.isEmpty)
    }

    @Test func offEveryScreenNothingIsAdded() throws {
        let (store, _, _) = makeStore()
        let before = store.tree
        #expect(store.addSketched(.button, from: CGRect(x: 2000, y: 2000, width: 300, height: 50),
                                  confidence: 1, decidedBy: .rules) == nil)
        #expect(store.tree == before)
        #expect(store.screenID(under: CGRect(x: 2000, y: 2000, width: 300, height: 50)) == nil)
    }

    @Test func aReadingsNeighboursAreTheScreensLeavesWhereTheyAre() throws {
        let (store, screen, _) = makeStore(origin: CGPoint(x: 500, y: 0), scale: 0.5)
        var hidden = leaf(.text, CGRect(x: 20, y: 400, width: 100, height: 20))
        hidden.isHidden = true
        var card = LayerNode(kind: .card)
        card.frame = CGRect(x: 20, y: 100, width: 353, height: 200)
        card.children = [leaf(.image, CGRect(x: 16, y: 16, width: 100, height: 80))]
        #expect(store.add(card, to: .screen(screen)))
        #expect(store.add(hidden, to: .screen(screen)))

        #expect(store.screenID(under: CGRect(x: 510, y: 50, width: 20, height: 20)) == screen)
        let neighbours = store.sketchNeighbours(on: screen)
        #expect(neighbours == [ExistingElement(kind: .image, frame: CGRect(x: 36, y: 116, width: 100, height: 80)),
                               ExistingElement(kind: .text, frame: CGRect(x: 20, y: 400, width: 100, height: 20))])
    }

    @Test func aConversionMakesANodeWithItsReading() async throws {
        let (model, undo) = makeModel()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        #expect(model.viewport.scale == 1)
        let sketch = try strokes("pill 30 700 330 56")
        let observation = try #require(SketchAnalyzer.observe(sketch))
        let request = SketchRequest(observation: observation,
                                    placement: .onScreen(local: observation.bounds, existing: [], size: DeviceFrame.iPhone.size),
                                    strokes: sketch.map(\.points))
        let top = try #require(request.scoredReadings.first)
        #expect(top.reading == .element(.button))

        model.sketchChanged(sketch)
        model.convertNow()
        #expect(await eventually(within: .seconds(10)) { model.store.treeScreen(screen.id)?.root.children.count == 1 })
        // With no ink canvas here, the sketch is taken away by hand, as the canvas does once it is read.
        model.sketchChanged([])
        await model.waitForConversions()

        let node = try #require(model.store.treeScreen(screen.id)?.root.children.last)
        #expect(node.kind == .button)
        #expect(node.sketch?.decidedBy == .rules)
        #expect(node.sketch?.confidence == top.score)
        #expect(node.sketch?.originalBounds == observation.bounds)

        undo.undo()
        #expect(model.store.treeScreen(screen.id)?.root.children.isEmpty == true)
    }

    @Test func aSketchOnTheCanvasRemembersItsBounds() async throws {
        let (model, _) = makeModel()
        let sketch = [SketchStroke(key: 1, points: StrokeScript.wave(CGRect(x: 100, y: 100, width: 200, height: 30), humps: 3))]
        let observation = try #require(SketchAnalyzer.observe(sketch))

        model.sketchChanged(sketch)
        model.convertNow()
        #expect(await eventually(within: .seconds(10)) { model.store.tree.canvas.count == 1 })
        model.sketchChanged([])
        await model.waitForConversions()

        let node = try #require(model.store.tree.canvas.first)
        #expect(node.kind == .text)
        #expect(node.sketch?.originalBounds == observation.bounds)
        #expect(node.sketch?.normalizedBounds == .zero)
        #expect(node.sketch?.placement == .fixed)
        #expect(node.sketch?.decidedBy == .rules)
    }

    @Test func aSketchOnAFullDesignIsLeftUnread() async throws {
        // A screen's root and 4,999 things on the open canvas: 5,000 nodes, as many as a design holds.
        let full = (0..<4999).map { leaf(.text, CGRect(x: 2000 + CGFloat($0 % 50) * 30, y: CGFloat($0 / 50) * 30, width: 20, height: 20)) }

        let (store, screen, _) = makeStore()
        #expect(store.replaceChildren(of: .canvas, with: full))
        #expect(store.index.count == TreeRules.maximumNodes)
        #expect(store.addSketched(.button, from: CGRect(x: 30, y: 700, width: 330, height: 56),
                                  confidence: 1, decidedBy: .rules) == nil)
        #expect(try root(of: screen, in: store).children.isEmpty)

        let (model, _) = makeModel()
        let onModel = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        #expect(model.store.replaceChildren(of: .canvas, with: full.map(TreeEdit.copyWithNewIDs)))
        model.sketchChanged(try strokes("pill 30 700 330 56"))
        model.convertNow()
        await model.waitForConversions()

        #expect(model.store.treeScreen(onModel.id)?.root.children.isEmpty == true)
        // Still on the canvas, and read: nothing is waiting to read it again.
        #expect(model.hasSketch)
        #expect(!model.isBusy)
    }
}
