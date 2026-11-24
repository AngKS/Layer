import CoreGraphics
import Foundation
import Testing
@testable import Layer

// The first milestone, from a sketch (spec, Verification; plan 5, Task 11): two zigzags, a box drawn round them and four
// boxes with crosses become a card holding a title and a body, and a two-column grid of images, at once, and the
// screen's code lays them out with `Grid` and gives the card its background.
//
// `design-sketched-milestone.json` under `Fixtures/Designs` is the tree this test ends with, which
// `GeneratedCodeExportTests` writes out for `scripts/check-generated-swiftui.sh` to typecheck. To record it again, run
// this suite with the environment variable TEST_RUNNER_LAYER_RECORD_DESIGN set to a folder on this Mac, then copy
// `design-sketched-milestone.json` from there into `Fixtures/Designs/`.

/// An `AppModel` with an iPhone screen at (0, 0), scale 1, at zoom 1.
@MainActor
private func makeModel() -> (model: AppModel, screen: TreeScreen.ID) {
    let model = AppModel(document: LayerDocument())
    // No word is read out of the strokes: what they are is the shape's alone.
    model.engine.readHandwriting = { _ in nil }
    let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
    return (model, screen.id)
}

/// One batch: every sketch in `script` read at once, as when the pen rests once, and waited for. Its strokes are keyed
/// `first`, `first` + 1, … .
@MainActor
private func draw(_ script: String, on model: AppModel, keys first: Double) async throws {
    let strokes = try StrokeScript.parse(script).enumerated().map { SketchStroke(key: first + Double($0.offset), points: $0.element) }
    model.sketchChanged(strokes)
    model.convertNow()
    // With no ink canvas here, the sketch is taken away by hand, as the canvas does once it is read.
    model.sketchChanged([])
    await model.waitForConversions()
}

@MainActor
private func rootChildren(_ model: AppModel, _ screen: TreeScreen.ID) -> [LayerNode] {
    model.store.treeScreen(screen)?.root.children ?? []
}

/// The lines of `code`, without their indents.
private func lines(of code: String) -> [String] {
    code.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

/// The modifiers written after the closing brace of the view that opens with `opening`, without their indents.
private func modifiers(after opening: String, in code: String) -> [String] {
    let raw = code.components(separatedBy: "\n")
    func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    guard let start = raw.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == opening }),
          let close = raw[(start + 1)...].firstIndex(where: { indent($0) == indent(raw[start]) && $0.hasSuffix("}") })
    else { return [] }
    return raw[(close + 1)...].prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

@Suite @MainActor struct FirstMilestoneTests {
    @Test func aCardAndAGridSketchedBecomeTheTreeAndItsCode() async throws {
        let (model, screen) = makeModel()

        // Two zigzags, each read on its own: conversions read in one batch commit in no fixed order (F12).
        try await draw("wave 140 120 110 30 3", on: model, keys: 1)
        try await draw("wave 30 170 330 34 4", on: model, keys: 11)
        let texts = rootChildren(model, screen)
        #expect(texts.map(\.kind) == [.title, .body])

        // A box drawn round them is a card holding them, as they were.
        try await draw("box 10 100 373 130 16", on: model, keys: 21)
        let held = rootChildren(model, screen)
        #expect(held.map(\.kind) == [.card])
        let card = try #require(held.first)
        #expect(card.children.map(\.kind) == [.title, .body])
        #expect(card.children.map(\.id) == texts.map(\.id))
        #expect(card.layout == nil)

        // Four boxes with crosses, read in one batch, are a two-column grid of images.
        let cells = [(40, 300), (213, 300), (40, 440), (213, 440)].map { x, y in "box \(x) \(y) 140 120 8; cross \(x) \(y) 140 120" }
        try await draw(cells.joined(separator: "; "), on: model, keys: 31)
        let root = rootChildren(model, screen)
        #expect(root.map(\.kind) == [.card, .group])
        #expect(root.first?.id == card.id)
        let grid = try #require(root.last)
        // Aligned (start, start), as the pass makes every grid (plan 5, Task 6): each cell's leading edge and top stay
        // where they were drawn.
        #expect(grid.layout == .grid(LayerNode.Grid(columns: 2, columnSpacing: 12, rowSpacing: 16,
                                                    alignment: LayerNode.Alignment(horizontal: .start, vertical: .start))))
        #expect(grid.children.map(\.kind) == Array(repeating: .image, count: 4))

        // The screen's code lays the grid out in two rows, on the design's rhythm, at its own width, and gives the card
        // its background.
        let tree = model.store.tree
        let treeScreen = try #require(tree.screens.first { $0.id == screen })
        let written = SwiftUICodeGenerator.code(for: treeScreen, in: SwiftUICodeGenerator.Context(tree), settings: CodeSettings())
        let code = lines(of: written)
        let opening = "Grid(alignment: .topLeading, horizontalSpacing: DesignTokens.rhythm[1], verticalSpacing: DesignTokens.rhythm[2]) {"
        #expect(code.contains(opening))
        #expect(code.filter { $0 == "GridRow {" }.count == 2)
        #expect(modifiers(after: opening, in: written).first == ".fixedSize(horizontal: true, vertical: false)")
        #expect(code.contains(".background(.background.secondary, in: .rect(cornerRadius: DesignTokens.cardRadius))"))
        #expect(code.filter { $0 == "enum DesignTokens {" }.count == 1)

        // The design, recorded for the generated code's typecheck: read back, it is the tree it was written from.
        let manifest = try TreeManifest.encode(tree, fileName: "Sketched Milestone")
        #expect(try TreeManifest.decode(manifest).content == tree)
        if let folder = ProcessInfo.processInfo.environment["LAYER_RECORD_DESIGN"] {
            // Written out a line at a time, as the other designs there are, to be read in a review.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let readable = try encoder.encode(JSONDecoder().decode(JSONValue.self, from: manifest))
            #expect(try TreeManifest.decode(readable).content == tree)
            try readable.write(to: URL(fileURLWithPath: folder).appendingPathComponent("design-sketched-milestone.json"))
        }
    }
}
