import CoreGraphics
import Foundation
import Testing
@testable import Layer

private let fieldSketch = CGRect(x: 30, y: 300, width: 330, height: 44)

@MainActor
private func makeModel() -> (model: AppModel, screen: TreeScreen.ID, undo: UndoManager) {
    let model = AppModel(document: LayerDocument())
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
    return (model, screen.id, undo)
}

private func leaf(_ kind: ElementKind, _ frame: CGRect) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    node.content.text = kind.placeholder
    return node
}

private func suggestion(for id: UUID, on screen: TreeScreen.ID, kind: ElementKind) throws -> KindSuggestion {
    let observation = try #require(SketchAnalyzer.observe(SketchSamples.strokes([SketchSamples.box(fieldSketch, radius: 10)])))
    // Its own rect is wrong on purpose: the node remembers where it was drawn.
    return KindSuggestion(ref: DesignStore.ElementRef(host: .screen(screen), element: id), kind: kind, sketch: .zero,
                          observation: observation)
}

@MainActor
private func rootChildren(_ store: DesignStore, _ screen: TreeScreen.ID) throws -> [LayerNode] {
    try #require(store.treeScreen(screen)).root.children
}

@Suite("Did you mean, from the node's own bounds") @MainActor
struct DidYouMeanTests {
    @Test func acceptingReLaysOutFromTheNodesOriginalBounds() throws {
        let (model, screen, _) = makeModel()
        let field = try #require(model.store.addSketched(.textField, from: fieldSketch, confidence: 0.6, decidedBy: .rules))
        model.offer(try suggestion(for: field, on: screen, kind: .button))

        model.acceptSuggestion()

        let (fresh, freshScreen, _) = makeModel()
        let expected = try #require(fresh.store.addSketched(.button, from: fieldSketch, confidence: 1, decidedBy: .rules))
        let button = try #require(model.store.node(field))
        #expect(button.kind == .button)
        #expect(button.frame == fresh.store.node(expected)?.frame)
        #expect(try rootChildren(model.store, screen).map(\.id) == [field])
        _ = freshScreen
    }

    @Test func theIntentSaysThePersonChose() throws {
        let (model, screen, _) = makeModel()
        let field = try #require(model.store.addSketched(.textField, from: fieldSketch, confidence: 0.6, decidedBy: .rules))
        let before = try #require(model.store.node(field)?.sketch)
        model.offer(try suggestion(for: field, on: screen, kind: .button))

        model.acceptSuggestion()

        let intent = try #require(model.store.node(field)?.sketch)
        #expect(intent.decidedBy == .asked)
        #expect(intent.confidence == 1)
        #expect(intent.originalBounds == before.originalBounds)
        #expect(intent.normalizedBounds == before.normalizedBounds)
        #expect(intent.placement == before.placement)
    }

    @Test func aRemadeNodeSavesNoTintAndKeepsNameLockAndWords() throws {
        let (model, screen, _) = makeModel()
        let field = try #require(model.store.addSketched(.textField, from: fieldSketch, confidence: 0.6, decidedBy: .rules) { node in
            node.name = "Email"
            node.isLocked = true
            node.content.text = "Sign in"
        })
        model.offer(try suggestion(for: field, on: screen, kind: .button))

        model.acceptSuggestion()

        let button = try #require(model.store.node(field))
        #expect(button.name == "Email" && button.isLocked)
        #expect(button.content.text == "Sign in")
        #expect(button.style.tint == nil)
    }

    @Test func aNodeInACardIsReLaidInTheCard() throws {
        let (model, screen, _) = makeModel()
        let inside = CGRect(x: 40, y: 310, width: 300, height: 44)
        let field = try #require(model.store.addSketched(.textField, from: inside, confidence: 0.6, decidedBy: .rules))
        let card = try #require(model.store.addSketched(.card, from: CGRect(x: 20, y: 280, width: 350, height: 120),
                                                        confidence: 0.9, decidedBy: .rules))
        let cardNode = try #require(model.store.node(card))
        #expect(cardNode.children.map(\.id) == [field])
        model.offer(try suggestion(for: field, on: screen, kind: .button))

        model.acceptSuggestion()

        let held = try #require(model.store.node(card))
        #expect(held.children.map(\.id) == [field])
        #expect(try rootChildren(model.store, screen).map(\.id) == [card])
        let local = CGRect(x: inside.minX - cardNode.frame.minX, y: inside.minY - cardNode.frame.minY,
                           width: inside.width, height: inside.height)
        let stand = DeviceFrame.custom(name: "card", size: cardNode.frame.size, family: DeviceFrame.iPhone.family)
        #expect(held.children[0].frame == ElementLayout.sketched(.button, sketch: local, on: stand, among: []).frame)
    }

    @Test func aNodeInARowKeepsItsPlaceInTheRow() throws {
        let (model, screen, _) = makeModel()
        var row = LayerNode(kind: .group)
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 12))
        row.width = LayerNode.Sizing(.fit)
        row.height = LayerNode.Sizing(.fit)
        row.frame = CGRect(x: 20, y: 300, width: 340, height: 44)
        let device = DeviceFrame.iPhone
        row.children = (0..<3).map { slot in
            var field = leaf(.textField, CGRect(x: 112 * slot, y: 0, width: 100, height: 44))
            field.width = LayerNode.Sizing(.fixed); field.height = LayerNode.Sizing(.fixed)
            field.sketch = LayerNode.SketchIntent(sketched: CGRect(x: 20 + 112 * slot, y: 300, width: 100, height: 44),
                                                  on: device.size, margin: device.margin, confidence: 0.6, decidedBy: .rules)
            return field
        }
        #expect(model.store.add(row, to: .screen(screen)))
        let middle = row.children[1].id
        model.offer(try suggestion(for: middle, on: screen, kind: .button))

        model.acceptSuggestion()

        let after = try #require(model.store.node(row.id))
        #expect(after.children.map(\.id) == row.children.map(\.id))
        #expect(after.children[1].kind == .button)
        #expect(after.children[1].sketch?.originalBounds == CGRect(x: 132, y: 300, width: 100, height: 44))
        #expect(after.children[0].kind == .textField && after.children[2].kind == .textField)
    }

    @Test func aCardThatBecomesAButtonGivesBackWhatItHeld() throws {
        let (model, screen, _) = makeModel()
        let first = leaf(.text, CGRect(x: 40, y: 310, width: 100, height: 30))
        let second = leaf(.text, CGRect(x: 40, y: 350, width: 100, height: 30))
        #expect(model.store.add(first, to: .screen(screen)))
        #expect(model.store.add(second, to: .screen(screen)))
        let card = try #require(model.store.addSketched(.card, from: CGRect(x: 20, y: 280, width: 350, height: 120),
                                                        confidence: 0.9, decidedBy: .rules))
        #expect(model.store.node(card)?.children.map(\.id) == [first.id, second.id])
        model.offer(try suggestion(for: card, on: screen, kind: .button))

        model.acceptSuggestion()

        #expect(try rootChildren(model.store, screen).map(\.id) == [card, first.id, second.id])
        #expect(model.store.node(card)?.kind == .button)
        #expect(model.store.node(card)?.children.isEmpty == true)
        #expect(model.store.placed(first.id)?.frame == first.frame)
        #expect(model.store.placed(second.id)?.frame == second.frame)
    }

    @Test func aButtonThatBecomesACardTakesWhatItEncloses() throws {
        let (model, screen, _) = makeModel()
        let button = try #require(model.store.addSketched(.button, from: CGRect(x: 20, y: 280, width: 350, height: 120),
                                                          confidence: 0.6, decidedBy: .rules))
        let text = leaf(.text, CGRect(x: 40, y: 310, width: 100, height: 30))
        #expect(model.store.add(text, to: .screen(screen)))
        model.offer(try suggestion(for: button, on: screen, kind: .card))

        model.acceptSuggestion()

        let card = try #require(model.store.node(button))
        #expect(card.kind == .card)
        #expect(card.children.map(\.id) == [text.id])
        #expect(card.style.tint == nil)
        #expect(model.store.placed(text.id)?.frame == text.frame)
        #expect(try rootChildren(model.store, screen).map(\.id) == [button])
    }

    @Test func aNodeWithoutASketchIsLaidOutFromTheFallback() throws {
        let (model, screen, _) = makeModel()
        let plain = leaf(.textField, CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(model.store.add(plain, to: .screen(screen)))

        #expect(model.store.changeKind(of: plain.id, to: .button) == nil)
        #expect(model.store.changeKind(of: plain.id, to: .button, fallback: fieldSketch) == plain.id)

        let (fresh, _, _) = makeModel()
        let expected = try #require(fresh.store.addSketched(.button, from: fieldSketch, confidence: 1, decidedBy: .rules))
        #expect(model.store.node(plain.id)?.frame == fresh.store.node(expected)?.frame)
        #expect(model.store.node(plain.id)?.sketch?.originalBounds == fieldSketch)
    }

    @Test func theChangeIsOneUndoStep() throws {
        let (model, screen, undo) = makeModel()
        let card = try #require(model.store.addSketched(.card, from: CGRect(x: 20, y: 280, width: 350, height: 120),
                                                        confidence: 0.9, decidedBy: .rules))
        let before = try #require(model.store.treeScreen(screen)).root
        model.offer(try suggestion(for: card, on: screen, kind: .button))
        model.acceptSuggestion()
        undo.undo()
        #expect(try #require(model.store.treeScreen(screen)).root == before)
    }

    @Test func theOfferStillLastsEightSeconds() {
        #expect(AppModel.suggestionLifetime == .seconds(8))
        #expect(AppModel.suggestionLifetime == StructureConventions.offerLifetime)
    }

    @Test func aCorrectionIsStillLogged() async throws {
        let (model, screen, _) = makeModel()
        let field = try #require(model.store.addSketched(.textField, from: fieldSketch, confidence: 0.6, decidedBy: .rules))
        let log = SketchReadingLog.shared
        let entry = await log.record(placementKind: "onScreen", existingKinds: [], existingFrames: [], screenSize: [393, 852],
                                     strokes: [], candidates: ["textField", "button"], scores: [0.55, 0.45],
                                     chosen: "textField", escalated: true, decidedBy: "rules")
        await log.link(element: field, toEntry: entry)
        model.offer(try suggestion(for: field, on: screen, kind: .button))

        model.acceptSuggestion()

        var corrected: String?
        for _ in 0..<50 where corrected == nil {
            corrected = await log.allEntries().first { $0.id == entry }?.correctedTo
            if corrected == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(corrected == "button")
    }
}
