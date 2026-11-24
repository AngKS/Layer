import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// Voice's "tidy up" (spec §5, plan 5's call 10): the structure pass in its tidy mode over a screen's free root and its
/// sketched free cards, every arrangeable thing new, what it builds laid out by the engine (plan 5, Task 10).
@Suite
@MainActor
struct TidyTests {
    // MARK: - Building

    private func node(_ kind: ElementKind, _ frame: CGRect) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        if kind.hasText { node.content.text = kind.placeholder }
        return node
    }

    /// The login, as `VoiceFixture.login()` has it: a title, a button and an image on a free iPhone root.
    private func login() -> [LayerNode] {
        [node(.title, CGRect(x: 20, y: 75, width: 353, height: 41)),
         node(.button, CGRect(x: 20, y: 420, width: 353, height: 50)),
         node(.image, CGRect(x: 20, y: 500, width: 200, height: 200))]
    }

    /// An app showing one iPhone screen whose root holds `children` (free unless `layout` says), laid out as a file
    /// read lays it out, with an undo history of its own.
    private func makeModel(_ children: [LayerNode], layout: LayerNode.Layout? = nil) -> (model: AppModel, screen: TreeScreen.ID, undo: UndoManager) {
        var screen = TreeScreen(name: "Login", origin: .zero, scale: 1, deviceID: nil)
        screen.root.children = children
        if let layout { screen.root.layout = layout }
        var tree = TreeContent()
        tree.screens = [screen]
        TreeRules.apply(to: &tree, after: nil)
        let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        return (model, screen.id, undo)
    }

    private func root(of screen: TreeScreen.ID, in model: AppModel) throws -> LayerNode {
        try #require(model.store.treeScreen(screen)?.root)
    }

    // MARK: - Tidying

    @Test func tidyingTheLoginMakesOneColumn() throws {
        let login = login()
        let (model, screen, _) = makeModel(login)
        #expect(model.store.tidy(screen))
        let root = try root(of: screen, in: model)
        #expect(root.children.count == 1)
        let column = try #require(root.children.first)
        #expect(column.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 32, alignment: .start)))
        #expect(column.sketch?.decidedBy == .structure)
        #expect(column.children.map(\.id) == login.map(\.id), "the title, the button and the image, ids kept")
        let frames = login.compactMap { model.store.placed($0.id)?.frame }
        #expect(frames.map(\.minY) == [75, 148, 230])
        #expect(frames.allSatisfy { $0.minX == 20 })
    }

    @Test func aTidyScreenHasNothingLeftToTidy() throws {
        let (model, screen, _) = makeModel(login())
        #expect(model.store.tidy(screen))
        let tidied = try root(of: screen, in: model)
        #expect(!model.store.tidy(screen))
        #expect(try root(of: screen, in: model) == tidied)
    }

    @Test func aColumnScreenHasNothingToTidy() throws {
        let (model, screen, _) = makeModel(login(), layout: .stack(LayerNode.Stack(axis: .vertical, spacing: 12)))
        let before = model.store.content
        #expect(!model.store.tidy(screen))
        #expect(model.store.content == before)
    }

    @Test func tidyingLeavesTheUntouchableAlone() throws {
        let login = login()
        var locked = node(.image, CGRect(x: 20, y: 720, width: 120, height: 100))
        locked.isLocked = true
        let (model, screen, _) = makeModel(login + [locked])
        #expect(model.store.tidy(screen))
        let root = try root(of: screen, in: model)
        #expect(root.children.count == 2)
        #expect(root.children.last?.id == locked.id, "a root child still")
        #expect(model.store.node(locked.id)?.frame == locked.frame, "where it was")
        #expect(root.children.first?.children.map(\.id) == login.map(\.id))
    }

    /// One step: one undo takes the column away and puts the three back where they were.
    @Test func tidyingIsOneStep() throws {
        let (model, screen, undo) = makeModel(login())
        let before = model.store.content
        #expect(model.store.tidy(screen))
        undo.undo()
        #expect(model.store.content == before)
        #expect(!undo.canUndo)
    }

    /// A card the person sketched, free, is tidied inside too: the three things it holds become its column, with the
    /// card's padding.
    @Test func aSketchedCardIsTidiedInside() throws {
        var card = node(.card, CGRect(x: 20, y: 100, width: 353, height: 200))
        card.padding = LayerNode.Padding(all: 16)
        card.sketch = LayerNode.SketchIntent(sketched: card.frame, on: CGSize(width: 393, height: 852), margin: 20,
                                             confidence: 0.95, decidedBy: .rules)
        let texts = [node(.text, CGRect(x: 18, y: 16, width: 200, height: 24)),
                     node(.text, CGRect(x: 14, y: 60, width: 200, height: 24)),
                     node(.text, CGRect(x: 16, y: 98, width: 200, height: 24))]
        card.children = texts
        let (model, screen, _) = makeModel([card])
        #expect(model.store.tidy(screen))
        let tidied = try #require(model.store.node(card.id))
        #expect(tidied.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 16, alignment: .start)))
        #expect(tidied.padding == LayerNode.Padding(all: 16))
        #expect(tidied.children.map(\.id) == texts.map(\.id))
    }

    // MARK: - Its cost

    /// Six hundred texts and images, 120 × 80 on a 140 × 100 lattice, each a few points off its place: Task 8 measured
    /// tidying them at 32.6 seconds. It takes under 300 ms in the simulator, unoptimised, measured up to three times
    /// while it is over (F19).
    @Test(.timeLimit(.minutes(1))) func tidyingSixHundredThingsIsQuick() throws {
        var seed: UInt64 = 7
        func offset() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(Int(seed >> 33) % 7 - 3)
        }
        var root = LayerNode(kind: .group)
        root.frame = CGRect(x: 0, y: 0, width: 3400, height: 2540)
        root.children = (0..<600).map { index in
            let (column, row) = (index % 24, index / 24)
            return node(index.isMultiple(of: 2) ? .text : .image,
                        CGRect(x: 20 + CGFloat(column) * 140 + offset(), y: 20 + CGFloat(row) * 100 + offset(),
                               width: 120, height: 80))
        }
        let budget: Duration = .milliseconds(300)
        var times: [Duration] = []
        var decisions: [StructureInference.Decision] = []
        for _ in 0..<3 where !Task.isCancelled {
            let start = ContinuousClock.now
            decisions = StructureInference.infer(in: root, new: [], tokens: .standard, mode: .tidy)
            times.append(ContinuousClock.now - start)
            if times.last! < budget { break }
        }
        #expect(times.contains { $0 < budget }, "tidying 600 things took \(times)")
        #expect(decisions.count >= 25, "a structure for each line at least")
    }
}
