import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The iPad the tests move screens to: 820 × 1180, margin 32. The iPhone is 393 × 852, margin 20.
private let iPad = DeviceFrame.named("ipad")

/// A node of `kind` at `frame`, fixed both ways.
private func node(_ frame: CGRect, _ kind: ElementKind = .button) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    return node
}

/// The frames `DeviceReflow` gives `children` of a free root going from `old` to `new`.
private func reflowed(_ children: [LayerNode], from old: DeviceFrame = .iPhone, to new: DeviceFrame = iPad) -> [UUID: CGRect] {
    var root = LayerNode(kind: .group)
    root.frame = CGRect(origin: .zero, size: old.size)
    root.children = children
    return DeviceReflow.frames(for: root, from: old, to: new)
}

/// A free screen on `deviceID` holding `children`.
private func freeScreen(_ children: [LayerNode], on deviceID: String? = nil) -> TreeScreen {
    var screen = TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: deviceID)
    screen.root.children = children
    return screen
}

/// An app showing `screens`, laid out as a file read lays them out, with an undo history of its own.
@MainActor
private func makeModel(_ screens: [TreeScreen], devices: [DeviceFrame] = []) -> (model: AppModel, undo: UndoManager) {
    var tree = TreeContent()
    tree.settings.customDevices = devices
    tree.screens = screens
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    return (model, undo)
}

/// A device change follows each thing's placement intent on a free screen, and lays a column screen out again: the
/// same from the device picker, Siri and voice, and when a device of the design's own is edited (spec §5, plan 5's
/// call 9, pre-flight F3).
@Suite("Device changes by placement intent")
@MainActor
struct DeviceReflowTests {
    // MARK: - Each intent, iPhone to iPad

    @Test func leadingKeepsItsLeftInset() {
        let leading = node(CGRect(x: 20, y: 300, width: 170, height: 120))
        #expect(reflowed([leading]).isEmpty, "what doesn't move isn't listed")
    }

    @Test func trailingKeepsItsRightInset() {
        let trailing = node(CGRect(x: 203, y: 300, width: 170, height: 120))
        #expect(reflowed([trailing]) == [trailing.id: CGRect(x: 630, y: 300, width: 170, height: 120)])
    }

    @Test func centredStaysCentred() {
        let centred = node(CGRect(x: 96, y: 80, width: 200, height: 40))
        #expect(reflowed([centred]) == [centred.id: CGRect(x: 310, y: 80, width: 200, height: 40)])
    }

    @Test func proportionalScalesItsXAndWidth() throws {
        var wide = node(CGRect(x: 20, y: 700, width: 353, height: 50))
        let onIPad = try #require(reflowed([wide])[wide.id])
        #expect(onIPad == CGRect(x: 42, y: 700, width: 737, height: 50))
        wide.frame = onIPad
        #expect(reflowed([wide], from: iPad, to: .iPhone)[wide.id] == CGRect(x: 20, y: 700, width: 353, height: 50))
    }

    @Test func fixedStaysPut() {
        #expect(reflowed([node(CGRect(x: 230, y: 400, width: 51, height: 31))]).isEmpty)
    }

    /// `fixedStaysPut`'s frame, saved as drawn at the trailing edge: its right inset is kept.
    @Test func aSavedIntentWinsOverTheFrame() {
        var saved = node(CGRect(x: 230, y: 400, width: 51, height: 31))
        saved.sketch = LayerNode.SketchIntent(originalBounds: saved.frame, normalizedBounds: .zero, confidence: 1,
                                              decidedBy: .rules, placement: .trailing)
        #expect(reflowed([saved]) == [saved.id: CGRect(x: 657, y: 400, width: 51, height: 31)])
    }

    @Test func lockedStaysPut() {
        var locked = node(CGRect(x: 203, y: 300, width: 170, height: 120))
        locked.isLocked = true
        #expect(reflowed([locked]).isEmpty)
    }

    /// A proportional node stood on end moves its centre with the screen's width, and keeps its size and its angle.
    @Test func aTurnedNodeKeepsItsSize() throws {
        var turned = node(CGRect(x: 20, y: 700, width: 353, height: 50))
        turned.rotation = 90
        let screen = freeScreen([turned])
        let (model, _) = makeModel([screen])

        model.store.changeDevice(of: screen.id, to: iPad)

        let after = try #require(model.store.node(turned.id))
        #expect(after.frame.size == CGSize(width: 353, height: 50))
        #expect(after.rotation == 90)
        #expect(abs(after.frame.midX - 196.5 * 820 / 393) <= 0.5, "its centre moves by the screen's ratio")
        #expect(CGRect(origin: .zero, size: iPad.size).contains(TurnedRect(rect: after.frame, degrees: 90).bounds))
    }

    // MARK: - iPad to iPhone

    @Test func goingSmallerClampsButFixedOverhangs() throws {
        let leading = node(CGRect(x: 40, y: 100, width: 500, height: 60), .image)
        let fixed = node(CGRect(x: 500, y: 300, width: 100, height: 100), .image)
        #expect(reflowed([leading, fixed], from: iPad, to: .iPhone) == [leading.id: CGRect(x: 0, y: 100, width: 500, height: 60)])

        let screen = freeScreen([leading, fixed], on: iPad.id)
        let (model, _) = makeModel([screen])
        model.store.changeDevice(of: screen.id, to: .iPhone)

        let root = try #require(model.store.treeScreen(screen.id)?.root)
        #expect(root.children.map(\.frame) == [CGRect(x: 0, y: 100, width: 500, height: 60),
                                               CGRect(x: 500, y: 300, width: 100, height: 100)])
        #expect(TreeValidator.check(root, on: .iPhone).contains(TreeValidator.Issue(node: fixed.id, kind: .clipped)))
    }

    // MARK: - Moving nothing unasked (fix round 1)

    /// Sent to the iPad and back five times, a centred node is exactly where it started. The iPhone's and the iPad's
    /// widths differ in parity, so its x lands on a half point each way; rounded to even, it doesn't creep right.
    @Test func aCentredNodeDoesNotDriftOverRoundTrips() {
        var centred = node(CGRect(x: 96, y: 80, width: 200, height: 40))
        for _ in 0..<5 {
            centred.frame = reflowed([centred])[centred.id] ?? centred.frame
            #expect(centred.frame == CGRect(x: 310, y: 80, width: 200, height: 40))
            centred.frame = reflowed([centred], from: iPad, to: .iPhone)[centred.id] ?? centred.frame
        }
        #expect(centred.frame == CGRect(x: 96, y: 80, width: 200, height: 40))
    }

    /// A device of the same size moves nothing on a free screen, not even what hangs off the screen or sits on a half
    /// point, whatever its margin or safe areas: a free root isn't inset by either. A column screen on it is still laid
    /// out again by the rules, which do inset it by its safe areas and margin.
    @Test func aDeviceOfTheSameSizeMovesNothingOnAFreeScreen() throws {
        let hanging = node(CGRect(x: 20, y: 800, width: 170, height: 120))
        let halfway = node(CGRect(x: 203.5, y: 300, width: 170, height: 120))
        var draft = CustomDeviceDraft(from: .iPhone, named: "iPhone (Custom)")
        let copy = try #require(draft.device(id: nil))
        #expect(reflowed([hanging, halfway], to: copy).isEmpty)
        draft.margin = 32
        #expect(reflowed([hanging, halfway], to: try #require(draft.device(id: nil))).isEmpty, "a margin alone")
        draft.margin = 20
        draft.safeTop = 20
        draft.safeLeading = 10
        let inset = try #require(draft.device(id: copy.id))
        #expect(reflowed([hanging, halfway], to: inset).isEmpty, "safe areas alone")

        // Through the store: a free screen and a column screen on the device, whose safe areas alone are edited.
        let free = freeScreen([hanging, halfway], on: copy.id)
        var filling = node(CGRect(x: 0, y: 0, width: 100, height: 50))
        filling.width = LayerNode.Sizing(.fill(weight: 1))
        var column = TreeScreen(name: "Column", origin: CGPoint(x: 600, y: 0), scale: 1, deviceID: copy.id)
        column.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12))
        column.root.children = [filling]
        let (model, _) = makeModel([free, column], devices: [copy])
        #expect(model.store.node(filling.id)?.frame.origin == CGPoint(x: 20, y: 79), "inset by the safe top 59 and the margin")

        model.store.updateCustomDevice(inset)

        #expect(model.store.treeScreen(free.id)?.root.children.map(\.frame) == [hanging.frame, halfway.frame])
        let laid = try #require(model.store.node(filling.id))
        // Inset by the new safe top 20 and safe leading 10, and the margin: 393 − 10 − 2 × 20 across.
        #expect(laid.frame.origin == CGPoint(x: 30, y: 40))
        #expect(laid.frame.width == 343)
    }

    /// Save as Device… from the screen's own device, a rename in the Edit Device sheet, and a Save with nothing changed
    /// leave a free screen's things where they are, a thing hanging off the screen and one on a half point included.
    @Test func savingRenamingOrSavingADeviceAgainMovesNothing() throws {
        func things() -> [LayerNode] {
            [node(CGRect(x: 20, y: 800, width: 170, height: 120)), node(CGRect(x: 203.5, y: 300, width: 170, height: 120))]
        }
        let frames = things().map(\.frame)
        let saved = try #require(CustomDeviceDraft(from: .iPhone, named: "iPhone (Custom)").device(id: nil))

        // Save as Device…: the screen takes a copy of its own device.
        let phone = freeScreen(things())
        let (savedAs, _) = makeModel([phone])
        let id = savedAs.store.addCustomDevice(saved, forScreen: phone.id)
        #expect(savedAs.store.treeScreen(phone.id)?.deviceID == id)
        #expect(savedAs.store.treeScreen(phone.id)?.root.children.map(\.frame) == frames)

        // A rename of the device a screen is on, and, in a design of its own, a Save with nothing changed.
        let renamed = try #require(CustomDeviceDraft(from: saved, named: "My Phone").device(id: saved.id))
        for (edit, name) in [(renamed, "My Phone"), (saved, saved.name)] {
            let onSaved = freeScreen(things(), on: saved.id)
            let (edited, _) = makeModel([onSaved], devices: [saved])
            edited.store.updateCustomDevice(edit)
            #expect(edited.store.tree.settings.customDevices.map(\.name) == [name])
            #expect(edited.store.treeScreen(onSaved.id)?.root.children.map(\.frame) == frames, "\(name)")
        }
    }

    // MARK: - What the pass built, what the person moved, and backgrounds (plan 5's final review)

    /// Three fields across an iPhone, which the pass makes a column, still scale with the screen as they would loose
    /// (A3): every member is proportional, so the column fills the iPad's width as they would.
    @Test func fieldsInAPassBuiltColumnFillTheIPad() throws {
        let fields = [200, 272, 344].map { node(CGRect(x: 20, y: $0, width: 353, height: 48), .textField) }
        let screen = freeScreen(fields)
        let (model, _) = makeModel([screen])
        model.structurePass(over: fields.map(\.id))
        let column = try #require(model.store.treeScreen(screen.id)?.root.children.first)
        #expect(column.children.map(\.id) == fields.map(\.id))

        model.store.changeDevice(of: screen.id, to: iPad)

        for field in fields {
            #expect(model.store.placed(field.id)?.frame == CGRect(x: 42, y: field.frame.minY, width: 737, height: 48))
        }
    }

    /// The same column built on an iPad, 737 wide, goes to an iPhone and stays on the screen (A3).
    @Test func aColumnBuiltOnAnIPadStaysOnAnIPhone() throws {
        let fields = [200, 272, 344].map { node(CGRect(x: 42, y: $0, width: 737, height: 48), .textField) }
        let screen = freeScreen(fields, on: iPad.id)
        let (model, _) = makeModel([screen])
        model.structurePass(over: fields.map(\.id))
        let column = try #require(model.store.treeScreen(screen.id)?.root.children.first)
        #expect(column.children.map(\.id) == fields.map(\.id))

        model.store.changeDevice(of: screen.id, to: .iPhone)

        for field in fields {
            #expect(model.store.placed(field.id)?.frame == CGRect(x: 20, y: field.frame.minY, width: 353, height: 48))
        }
        let root = try #require(model.store.treeScreen(screen.id)?.root)
        #expect(!TreeValidator.check(root, on: .iPhone).contains { $0.kind == .clipped })
    }

    /// A button sketched at the left and dragged against the right margin goes to the iPad's right edge (A4): its intent
    /// is read again from where the person put it. Undoing the drag puts the intent back with the frame.
    @Test func aSketchedButtonDraggedRightStaysAtTheRightEdge() throws {
        var button = node(CGRect(x: 20, y: 700, width: 170, height: 50))
        button.sketch = LayerNode.SketchIntent(sketched: button.frame, on: DeviceFrame.iPhone.size,
                                               margin: DeviceFrame.iPhone.margin, confidence: 1, decidedBy: .rules)
        #expect(button.sketch?.placement == .leading)
        let screen = freeScreen([button])
        let (model, undo) = makeModel([screen])

        model.store.place(button.id, at: CGRect(x: 203, y: 700, width: 170, height: 50))
        model.store.changeDevice(of: screen.id, to: iPad)

        #expect(model.store.node(button.id)?.frame == CGRect(x: 630, y: 700, width: 170, height: 50))
        undo.undo()
        undo.undo()
        #expect(model.store.node(button.id) == button)
    }

    /// Only the person's own placing rewrites an intent: a device change keeps every intent it moves things by, even one
    /// the new frame would read otherwise (A4). Saved as centred, a small button at the left goes to x 234 on the iPad,
    /// which reads as fixed there, and comes back to where it was.
    @Test func aDeviceChangeRewritesNoIntent() throws {
        var saved = node(CGRect(x: 20, y: 400, width: 51, height: 31))
        saved.sketch = LayerNode.SketchIntent(originalBounds: saved.frame, normalizedBounds: .zero, confidence: 1,
                                              decidedBy: .rules, placement: .centered)
        let screen = freeScreen([saved])
        let (model, _) = makeModel([screen])

        model.store.changeDevice(of: screen.id, to: iPad)
        #expect(model.store.node(saved.id)?.frame == CGRect(x: 234, y: 400, width: 51, height: 31))
        #expect(model.store.node(saved.id)?.sketch == saved.sketch)
        model.store.changeDevice(of: screen.id, to: .iPhone)
        #expect(model.store.node(saved.id) == saved)
    }

    /// Only the person's moves and resizes rewrite an intent, never the engine's (plan 6's Task P5C): a row put in the
    /// middle reads as centred, and stays so while its text is typed and it grows to the right, far enough that its
    /// frame no longer reads as centred.
    @Test func aRowThatGrowsAsItsTextIsTypedKeepsItsIntent() throws {
        var label = node(CGRect(x: 0, y: 0, width: 20, height: 20), .text)
        label.content.text = "Hi"
        (label.width, label.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
        var row = LayerNode(kind: .group)
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
        (row.width, row.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
        row.frame = CGRect(x: 20, y: 400, width: 20, height: 20)
        row.children = [label]
        row.sketch = LayerNode.SketchIntent(sketched: row.frame, on: DeviceFrame.iPhone.size,
                                            margin: DeviceFrame.iPhone.margin, confidence: 1, decidedBy: .structure)
        #expect(row.sketch?.placement == .leading)
        let screen = freeScreen([row])
        let (model, _) = makeModel([screen])
        let laid = try #require(model.store.node(row.id)?.frame)

        // The person puts it in the middle.
        let middle = CGRect(x: ((DeviceFrame.iPhone.size.width - laid.width) / 2).rounded(), y: 400, width: laid.width,
                            height: laid.height)
        model.store.place(row.id, at: middle)
        #expect(model.store.node(row.id)?.frame == middle)
        #expect(model.store.node(row.id)?.sketch?.placement == .centered)

        model.store.update(label.id) { $0.content.text = "Typed until the row is far wider than it was" }

        let grown = try #require(model.store.node(row.id))
        #expect(grown.frame.minX == middle.minX && grown.frame.width > middle.width + 100)
        #expect(LayerNode.PlacementIntent.of(grown.frame, screenWidth: DeviceFrame.iPhone.size.width,
                                             margin: DeviceFrame.iPhone.margin) != .centered)
        #expect(grown.sketch?.placement == .centered)
    }

    /// The person's resize counts however the engine then fits what was resized (plan 6's Task P5C): a row the pass
    /// built at the left, stretched by its trailing edge across the screen, reads as proportional from then on.
    @Test func aPassBuiltRowStretchedByItsTrailingEdgeTakesItsNewIntent() throws {
        let buttons = [20, 112, 204].map { node(CGRect(x: $0, y: 600, width: 80, height: 44)) }
        let screen = freeScreen(buttons)
        let (model, _) = makeModel([screen])
        model.structurePass(over: buttons.map(\.id))
        let row = try #require(model.store.treeScreen(screen.id)?.root.children.first)
        try #require(row.sketch?.decidedBy == .structure)
        try #require(row.children.map(\.id) == buttons.map(\.id))
        #expect(row.width.mode == .fit)
        #expect(row.sketch?.placement == .leading)

        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: row.id)
        model.store.resizeGroup(ref, to: CGRect(x: 20, y: 600, width: 353, height: 44))

        let stretched = try #require(model.store.node(row.id))
        #expect(stretched.frame == CGRect(x: 20, y: 600, width: 353, height: 44))
        #expect(stretched.sketch?.placement == .proportional)
    }

    /// A card drawn round two fields of a column the pass built is the column's width, and its fields fill it (plan 6's
    /// Task P5C). Going to an iPad and back, the column scales as its fields would loose, the card with it, and the
    /// card's fields with the card, inset by its padding; back on the iPhone everything is where it was, and fits.
    @Test func aColumnHoldingADrawnCardScalesWithTheScreenAndBack() throws {
        let fields = [200, 272, 344, 416].map { node(CGRect(x: 20, y: $0, width: 353, height: 48), .textField) }
        let screen = freeScreen(fields)
        let (model, _) = makeModel([screen])
        model.structurePass(over: fields.map(\.id))
        let column = try #require(model.store.treeScreen(screen.id)?.root.children.first)
        try #require(column.children.map(\.id) == fields.map(\.id))
        // Round the second and third.
        let card = try #require(model.store.addSketched(.card, from: CGRect(x: 10, y: 262, width: 373, height: 140),
                                                        confidence: 0.95, decidedBy: .rules))
        try #require(model.store.node(card)?.children.map(\.id) == [fields[1].id, fields[2].id])
        let padding = DesignTokens.standard.card.padding
        let things = fields.map(\.id) + [card, column.id]
        let onIPhone = things.map { model.store.placed($0)?.frame }
        #expect(model.store.placed(card)?.frame == CGRect(x: 20, y: 272, width: 353, height: 120 + 2 * padding))

        model.store.changeDevice(of: screen.id, to: iPad)

        #expect(model.store.placed(fields[0].id)?.frame == CGRect(x: 42, y: 200, width: 737, height: 48))
        #expect(model.store.placed(card)?.frame == CGRect(x: 42, y: 272, width: 737, height: 120 + 2 * padding))
        #expect(model.store.placed(fields[1].id)?.frame == CGRect(x: 42 + padding, y: 272 + padding,
                                                                  width: 737 - 2 * padding, height: 48))
        #expect(model.store.placed(fields[2].id)?.frame == CGRect(x: 42 + padding, y: 344 + padding,
                                                                  width: 737 - 2 * padding, height: 48))
        #expect(model.store.placed(fields[3].id)?.frame == CGRect(x: 42, y: 416 + 2 * padding, width: 737, height: 48))

        model.store.changeDevice(of: screen.id, to: .iPhone)

        #expect(things.map { model.store.placed($0)?.frame } == onIPhone)
        let root = try #require(model.store.treeScreen(screen.id)?.root)
        #expect(!TreeValidator.check(root, on: .iPhone).contains { $0.kind == .clipped })
    }

    /// A column built on an iPad, holding a card drawn round two of its fields a little inside their ends, goes to an
    /// iPhone and fits it (plan 6's Task P5C): the card is as wide as the column, so it scales with it whatever its drawn
    /// box reads as, here centred, and its fields with it.
    @Test func aColumnBuiltOnAnIPadHoldingACardFitsAnIPhone() throws {
        let fields = [200, 272, 344, 416].map { node(CGRect(x: 42, y: $0, width: 737, height: 48), .textField) }
        let screen = freeScreen(fields, on: iPad.id)
        let (model, _) = makeModel([screen])
        model.structurePass(over: fields.map(\.id))
        let column = try #require(model.store.treeScreen(screen.id)?.root.children.first)
        try #require(column.children.map(\.id) == fields.map(\.id))
        // Round the second and third, 670 wide in the middle, which reads as centred on an iPad.
        let card = try #require(model.store.addSketched(.card, from: CGRect(x: 75, y: 262, width: 670, height: 140),
                                                        confidence: 0.95, decidedBy: .rules))
        try #require(model.store.node(card)?.children.map(\.id) == [fields[1].id, fields[2].id])
        #expect(model.store.node(card)?.sketch?.placement == .centered)
        let padding = DesignTokens.standard.card.padding

        model.store.changeDevice(of: screen.id, to: .iPhone)

        #expect(model.store.placed(fields[0].id)?.frame == CGRect(x: 20, y: 200, width: 353, height: 48))
        #expect(model.store.placed(card)?.frame == CGRect(x: 20, y: 272, width: 353, height: 120 + 2 * padding))
        #expect(model.store.placed(fields[1].id)?.frame == CGRect(x: 20 + padding, y: 272 + padding,
                                                                  width: 353 - 2 * padding, height: 48))
        #expect(model.store.placed(fields[2].id)?.frame == CGRect(x: 20 + padding, y: 344 + padding,
                                                                  width: 353 - 2 * padding, height: 48))
        #expect(model.store.placed(fields[3].id)?.frame == CGRect(x: 20, y: 416 + 2 * padding, width: 353, height: 48))
        let root = try #require(model.store.treeScreen(screen.id)?.root)
        #expect(!TreeValidator.check(root, on: .iPhone).contains { $0.kind == .clipped })
    }

    /// A background that fills the screen fills the new one; a locked one stays (A5, ported from ScreenTidy's
    /// `aBackgroundFillsTheNewDevice`, retired under (o)).
    @Test func aBackgroundFillsTheNewDevice() throws {
        let background = node(CGRect(x: 0, y: 0, width: 393, height: 852), .shape)
        let title = node(CGRect(x: 50, y: 100, width: 228, height: 40), .title)
        #expect(reflowed([background, title])[background.id] == CGRect(origin: .zero, size: iPad.size))
        #expect(reflowed([node(CGRect(origin: .zero, size: iPad.size), .image)], from: iPad, to: .iPhone).values.first
                == CGRect(origin: .zero, size: DeviceFrame.iPhone.size))
        var locked = background
        locked.isLocked = true
        #expect(reflowed([locked, title])[locked.id] == nil)
    }

    /// A deliberate bleed keeps its overhang (A5 with Task 4's M3): a header past the iPhone's top, left and right edges
    /// by 10 spans the iPad's width the same way, and a picture hanging 10 off the right edge, trailing, still does.
    @Test func aBleedKeepsItsOverhang() {
        let header = node(CGRect(x: -10, y: -10, width: 413, height: 200), .image)
        let hanging = node(CGRect(x: 233, y: 300, width: 170, height: 120), .image)
        let onIPad = reflowed([header, hanging])
        #expect(onIPad[header.id] == CGRect(x: -10, y: -10, width: 840, height: 200))
        #expect(onIPad[hanging.id] == CGRect(x: 660, y: 300, width: 170, height: 120))

        var back = header
        back.frame = onIPad[header.id] ?? header.frame
        #expect(reflowed([back], from: iPad, to: .iPhone)[header.id] == header.frame)
    }

    // MARK: - A column screen

    @Test func aColumnScreenIsLaidOutAgain() throws {
        var filling = node(CGRect(x: 0, y: 0, width: 100, height: 50))
        filling.width = LayerNode.Sizing(.fill(weight: 1))
        var screen = TreeScreen(name: "Column", origin: .zero, scale: 1, deviceID: nil)
        screen.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12))
        screen.root.children = [filling]
        let (model, _) = makeModel([screen])

        model.store.changeDevice(of: screen.id, to: iPad)

        let root = try #require(model.store.treeScreen(screen.id)?.root)
        #expect(model.store.treeScreen(screen.id)?.deviceID == "ipad")
        #expect(root.frame == CGRect(x: 0, y: 0, width: 820, height: 1180))
        let laid = try #require(root.children.first)
        #expect(laid.frame.minX == 32)
        #expect(laid.frame.width == 756)
    }

    // MARK: - One step, every path

    @Test func aDeviceChangeIsOneUndoStep() throws {
        let screen = freeScreen(Self.things())
        let (model, undo) = makeModel([screen])
        let before = try #require(model.store.treeScreen(screen.id))

        model.store.changeDevice(of: screen.id, to: iPad)
        #expect(model.store.treeScreen(screen.id)?.root.children.map(\.frame) == Self.onIPad)
        #expect(model.store.treeScreen(screen.id)?.deviceID == "ipad")

        undo.undo()
        #expect(model.store.treeScreen(screen.id) == before)
        #expect(!undo.canUndo)
    }

    @Test func everyPathChangesTheDeviceTheSameWay() async throws {
        // The device picker's: plan 4's `DevicePicker` calls `setDevice(of:to:)`.
        let pickedScreen = freeScreen(Self.things())
        let picked = makeModel([pickedScreen])
        picked.model.store.setDevice(of: pickedScreen.id, to: "ipad")

        // Siri's, on a design open in its window.
        let askedScreen = freeScreen(Self.things())
        let asked = makeModel([askedScreen])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        asked.model.fileURL = folder.appendingPathComponent("Reflow.layer")
        defer { asked.model.close() }
        let intent = ChangeScreenDeviceIntent()
        intent.screen = try #require(DesignActions.snapshot(of: asked.model)?.screens.first { $0.screenID == askedScreen.id })
        intent.device = .iPad
        _ = try await intent.perform()

        // Voice's.
        let spokenScreen = freeScreen(Self.things())
        let spoken = makeModel([spokenScreen])
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: spoken.model, handles: handles)
        let line = VoiceToolbox(model: spoken.model, handles: handles).changeScreenDevice(screen: "S1", device: "iPad")
        #expect(line == "Made S1 an iPad screen (820 × 1180).")

        for ((model, undo), id) in [(picked, pickedScreen.id), (asked, askedScreen.id), (spoken, spokenScreen.id)] {
            let changed = try #require(model.store.treeScreen(id))
            #expect(changed.deviceID == "ipad")
            #expect(changed.root.children.map(\.frame) == Self.onIPad)
            undo.undo()
            #expect(model.store.treeScreen(id)?.deviceID == nil)
            #expect(model.store.treeScreen(id)?.root.children.map(\.frame) == Self.things().map(\.frame))
            #expect(!undo.canUndo, "one step")
        }
    }

    /// Editing a device of the design's own changes the size of every screen on it, and each free one's contents
    /// follow their intents from the device's old size, in the edit's one step (F3).
    @Test func editingACustomDeviceReflowsItsFreeScreens() throws {
        let board = DeviceFrame.custom(name: "Board", size: CGSize(width: 393, height: 852), family: .phone)
        let trailing = node(CGRect(x: 203, y: 300, width: 170, height: 120))
        let screen = freeScreen([trailing], on: board.id)
        let (model, undo) = makeModel([screen], devices: [board])
        var draft = CustomDeviceDraft(from: board, named: board.name)
        draft.width = 820
        draft.height = 1180
        let edited = try #require(draft.device(id: board.id))

        model.store.updateCustomDevice(edited)

        #expect(model.store.treeScreen(screen.id)?.root.frame.size == CGSize(width: 820, height: 1180))
        #expect(model.store.node(trailing.id)?.frame == CGRect(x: 630, y: 300, width: 170, height: 120))
        undo.undo()
        #expect(model.store.tree.settings.customDevices == [board])
        #expect(model.store.node(trailing.id)?.frame == CGRect(x: 203, y: 300, width: 170, height: 120))
        #expect(!undo.canUndo, "one step")
    }

    // MARK: - Fixtures

    /// Trailing, centred, proportional, leading and fixed, on an iPhone screen. New ids each time.
    private static func things() -> [LayerNode] {
        [CGRect(x: 203, y: 300, width: 170, height: 120), CGRect(x: 96, y: 80, width: 200, height: 40),
         CGRect(x: 20, y: 700, width: 353, height: 50), CGRect(x: 20, y: 500, width: 170, height: 120),
         CGRect(x: 230, y: 400, width: 51, height: 31)].map { node($0) }
    }

    /// Where `things()` go on an iPad.
    private static let onIPad = [
        CGRect(x: 630, y: 300, width: 170, height: 120), CGRect(x: 310, y: 80, width: 200, height: 40),
        CGRect(x: 42, y: 700, width: 737, height: 50), CGRect(x: 20, y: 500, width: 170, height: 120),
        CGRect(x: 230, y: 400, width: 51, height: 31),
    ]
}
