import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The structure pass's grids, a new card's column, the structures it made growing as more is drawn, and tidying
/// (plan 5, Task 6). The parent is a free iPhone root, the images are `.fixed` and new unless the test says otherwise.
@Suite struct StructureGridTests {
    // MARK: - Building

    private func node(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = CGRect(x: x, y: y, width: width, height: height)
        if kind.hasText { node.content.text = kind.placeholder }
        return node
    }

    private func image(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 160, _ height: CGFloat = 120) -> LayerNode {
        node(.image, x, y, width, height)
    }

    private func text(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 100, _ height: CGFloat = 24) -> LayerNode {
        node(.text, x, y, width, height)
    }

    /// The four cells of `fourBoxesMakeATwoColumnGrid`.
    private func fourBoxes() -> [LayerNode] {
        [image(30, 300), image(203, 300), image(30, 436), image(203, 436)]
    }

    /// A free iPhone root holding `children`.
    private func root(_ children: [LayerNode]) -> LayerNode {
        var root = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil).root
        root.children = children
        return root
    }

    /// A card sketched at (20, 100, 353, 200), free, padded by the card padding, holding `children`.
    private func card(_ children: [LayerNode]) -> LayerNode {
        var card = node(.card, 20, 100, 353, 200)
        card.padding = LayerNode.Padding(all: 16)
        card.sketch = LayerNode.SketchIntent(sketched: card.frame, on: iPhone.size, margin: 20, confidence: 0.95, decidedBy: .rules)
        card.children = children
        return card
    }

    private let iPhone = CGRect(x: 0, y: 0, width: 393, height: 852)

    /// The pass over `parent`, with every child new unless `new` says which are.
    private func infer(_ parent: LayerNode, new: [LayerNode]? = nil, grows: [UUID] = [],
                       mode: StructureInference.Mode = .sketch) -> [StructureInference.Decision] {
        StructureInference.infer(in: parent, new: Set((new ?? parent.children).map(\.id)), grows: Set(grows),
                                 tokens: .standard, mode: mode)
    }

    private func structure(_ decision: StructureInference.Decision?) -> StructureInference.Structure? {
        switch decision {
        case .apply(let structure)?, .offer(let structure)?: structure
        case nil: nil
        }
    }

    private func applied(_ decision: StructureInference.Decision?) -> StructureInference.Structure? {
        if case .apply(let structure)? = decision { structure } else { nil }
    }

    private func isGrid(_ decision: StructureInference.Decision) -> Bool {
        if case .grid = structure(decision)?.kind { true } else { false }
    }

    /// Where a member sits in the parent's space once the structure is built.
    private func frame(of id: UUID, in structure: StructureInference.Structure) -> CGRect? {
        guard let member = structure.container.children.first(where: { $0.id == id }) else { return nil }
        return member.frame.offsetBy(dx: structure.container.frame.minX, dy: structure.container.frame.minY)
    }

    /// The root with the first structure the pass finds among `nodes` built in it, as the pass (or an accepted
    /// offer) builds it, and that structure's container.
    private func built(_ nodes: [LayerNode], beside others: [LayerNode] = []) throws -> (root: LayerNode, container: LayerNode) {
        let parent = root(nodes + others)
        let made = try #require(structure(infer(parent, new: nodes).first))
        let root = try #require(StructureInference.applying(made, to: parent))
        let container = try #require(root.children.first { $0.id == made.container.id })
        return (root, container)
    }

    // MARK: - Grids

    @Test func fourBoxesMakeATwoColumnGrid() throws {
        let boxes = fourBoxes()
        let parent = root(boxes)
        let decisions = infer(parent)
        #expect(decisions.count == 1)
        let grid = try #require(applied(decisions.first))
        #expect(grid.kind == .grid(columns: 2))
        #expect(grid.title == "Make a grid?")
        #expect(grid.members == boxes.map(\.id), "row by row (My call 15)")
        #expect(grid.replacing.isEmpty)
        #expect(grid.container.layout == .grid(LayerNode.Grid(
            columns: 2, columnSpacing: 12, rowSpacing: 16, alignment: LayerNode.Alignment(horizontal: .start, vertical: .start))),
                "13 between the columns on the rhythm is 12; 16 between the rows")
        #expect(grid.container.width.mode == .fit && grid.container.height.mode == .fit)
        #expect(grid.container.frame == CGRect(x: 30, y: 300, width: 332, height: 256))
        #expect(grid.container.children.allSatisfy { $0.width.mode == .fixed && $0.height.mode == .fixed })
        #expect(frame(of: boxes[3].id, in: grid) == CGRect(x: 202, y: 436, width: 160, height: 120))
        #expect(grid.confidence == 1)
        #expect(grid.movement == 1)
        #expect(infer(parent) == decisions, "the pass is deterministic, the container's id included")
    }

    @Test func aGridGrowsFromItsRow() throws {
        let boxes = fourBoxes()
        let made = try built(Array(boxes[0...1]))
        let row = made.container
        #expect(row.children.map(\.id) == [boxes[0].id, boxes[1].id])
        var parent = made.root
        parent.children += boxes[2...3]
        let decisions = infer(parent, new: Array(boxes[2...3]), grows: [row.id])
        #expect(decisions.count == 1)
        let grid = try #require(applied(decisions.first))
        #expect(grid.kind == .grid(columns: 2))
        #expect(grid.members == boxes.map(\.id))
        #expect(grid.replacing == [row.id])
        #expect(grid.confidence >= 0.8)
        #expect(grid.movement <= 1)
    }

    @Test func aRowGrowsLonger() throws {
        let a = text(20, 100), b = text(132, 100), c = text(244, 100)
        let made = try built([a, b])
        let row = made.container
        var parent = made.root
        parent.children.append(c)
        let decisions = infer(parent, new: [c], grows: [row.id])
        #expect(decisions.count == 1)
        let longer = try #require(applied(decisions.first))
        #expect(longer.kind == .row)
        #expect(longer.members == [a.id, b.id, c.id])
        #expect(longer.replacing == [row.id])
        #expect(longer.container.id != row.id)
        #expect(longer.container.frame == CGRect(x: 20, y: 100, width: 324, height: 24))
        #expect(longer.movement == 0)
    }

    @Test func aRowNotInGrowsIsLeftAlone() throws {
        let a = text(20, 100), b = text(132, 100), c = text(244, 100)
        var parent = try built([a, b]).root
        parent.children.append(c)
        #expect(infer(parent, new: [c]).isEmpty, "a row never takes a row (F5)")
    }

    @Test func aGrownStructureMustHoldAllOfIt() throws {
        // A text and a button the pass made a row of; a tall image beside the button is too tall for the text's row,
        // so the only row it could make holds the button and not the text.
        let a = text(20, 100), b = node(.button, 132, 92, 100, 40)
        let made = try built([a, b])
        let row = made.container
        var parent = made.root
        let c = image(244, 82, 100, 60)
        parent.children.append(c)
        #expect(infer(parent, new: [c], grows: [row.id]).isEmpty)
    }

    @Test func anLOfThreeIsNotAGrid() {
        let boxes = Array(fourBoxes()[0...2])
        let decisions = infer(root(boxes))
        #expect(!decisions.contains(where: isGrid))
        #expect(decisions.compactMap { structure($0)?.members } == [[boxes[0].id, boxes[1].id]], "the top two are a row")
    }

    @Test func aGridGrowsIntoAShortLastRow() throws {
        let boxes = fourBoxes()
        let made = try built(boxes)
        let grid = made.container
        var parent = made.root
        #expect(grid.children.map(\.id) == boxes.map(\.id))
        let fifth = image(30, 572)
        parent.children.append(fifth)
        let decisions = infer(parent, new: [fifth], grows: [grid.id])
        #expect(decisions.count == 1)
        let grown = try #require(applied(decisions.first))
        #expect(grown.kind == .grid(columns: 2))
        #expect(grown.members == boxes.map(\.id) + [fifth.id])
        #expect(grown.replacing == [grid.id])
        #expect(grown.container.frame == CGRect(x: 30, y: 300, width: 332, height: 392))
        #expect(grown.confidence == 1)
        #expect(grown.movement == 0)

        // The same fifth beside a grid that may not grow is no grid: the grid isn't one to read as its members.
        #expect(!infer(parent, new: [fifth]).contains(where: isGrid))
    }

    @Test func gridNearMisses() {
        let boxes = fourBoxes()
        // Cell sizes 30% apart.
        var wide = boxes
        wide[3] = image(203, 436, 208, 120)
        #expect(!infer(root(wide)).contains(where: isGrid))
        // A column edge 6 pt off.
        var off = boxes
        off[3] = image(209, 436)
        #expect(!infer(root(off)).contains(where: isGrid))
        // Two images in one cell's place.
        #expect(!infer(root(boxes + [image(206, 440, 150, 110)])).contains(where: isGrid))
    }

    @Test func applyingAGrowthOpensTheOldContainer() throws {
        let boxes = fourBoxes()
        let made = try built(Array(boxes[0...1]))
        let row = made.container
        var parent = made.root
        parent.children += boxes[2...3]
        let grid = try #require(applied(infer(parent, new: Array(boxes[2...3]), grows: [row.id]).first))
        let result = try #require(StructureInference.applying(grid, to: parent))
        #expect(result.children.map(\.id) == [grid.container.id], "the grid, and not the row")
        #expect(!TreeEdit.ids(in: result).contains(row.id))
        let built = result.children[0]
        #expect(built.children.map(\.id) == boxes.map(\.id), "every image keeps its id")
        #expect(built.children.map(\.frame) == grid.container.children.map(\.frame))
        #expect(built.layout == grid.container.layout && built.frame == grid.container.frame)
    }

    // MARK: - A new card's inside

    @Test func threeThingsInANewCardBecomeItsColumn() throws {
        let texts = [text(16, 16, 200, 24), text(16, 56, 200, 24), text(16, 96, 200, 24)]
        let card = card(texts)
        let decisions = infer(card)
        #expect(decisions.count == 1)
        let column = try #require(applied(decisions.first))
        #expect(column.kind == .cardColumn)
        #expect(column.title == "Make a column?")
        #expect(column.parent == card.id)
        #expect(column.members == texts.map(\.id))
        #expect(column.container.id == card.id, "the card itself")
        #expect(column.container.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 16, alignment: .start)))
        #expect(column.container.padding == LayerNode.Padding(all: 16))
        #expect(column.container.frame == card.frame)
        #expect(column.container.sketch == card.sketch)
        #expect(column.container.children.map(\.frame) == texts.map(\.frame))
        #expect(column.movement == 0)

        let applied = try #require(StructureInference.applying(column, to: card))
        #expect(applied.id == card.id && applied.layout == column.container.layout && applied.padding == column.container.padding)
        #expect(applied.children.map(\.id) == texts.map(\.id))
    }

    @Test func aCardsColumnKeepsTheInsetsAsDrawn() throws {
        let texts = [text(30, 16, 200, 24), text(30, 56, 200, 24), text(30, 96, 200, 24)]
        let column = try #require(applied(infer(card(texts)).first))
        #expect(column.kind == .cardColumn)
        #expect(column.container.padding == LayerNode.Padding(top: 16, leading: 30, bottom: 16, trailing: 16),
                "the card's 16 would move them 14 pt")
        #expect(column.movement == 0)
    }

    @Test func aCardsPaddingIsJudgedByHowFarItMovesThings() throws {
        // Both insets 6 pt off: the card's 16 on both sides moves every text hypot(6, 6) ≈ 8.49 pt, so the insets as
        // drawn are kept, and they move nothing.
        let off = [text(22, 22, 200, 24), text(22, 62, 200, 24), text(22, 102, 200, 24)]
        let drawn = try #require(applied(infer(card(off)).first))
        #expect(drawn.kind == .cardColumn)
        #expect(drawn.container.padding == LayerNode.Padding(top: 22, leading: 22, bottom: 16, trailing: 16))
        #expect(drawn.movement == 0)

        // Both 4 pt off: the card's 16 moves each hypot(4, 4) ≈ 5.66 pt, within 8, so it is kept.
        let near = [text(20, 20, 200, 24), text(20, 60, 200, 24), text(20, 100, 200, 24)]
        let padded = try #require(applied(infer(card(near)).first))
        #expect(padded.container.padding == LayerNode.Padding(all: 16))
        #expect(abs(padded.movement - hypot(4, 4)) < 1e-9)
    }

    @Test func twoThingsInACardStayFree() {
        #expect(infer(card([text(16, 16, 200, 24), text(16, 56, 200, 24)])).isEmpty)
        #expect(infer(card([text(16, 16), text(128, 16)])).isEmpty, "a new card's inside is a column or nothing")
    }

    // MARK: - Tidying

    private func login() -> [LayerNode] {
        [node(.title, 20, 75, 353, 41), node(.button, 20, 420, 353, 50), image(20, 500, 200, 200)]
    }

    @Test func tidyingTheLoginMakesOneColumn() throws {
        let login = login()
        let decisions = infer(root(login), new: [], mode: .tidy)
        #expect(decisions.count == 1, "every arrangeable child is new")
        let column = try #require(applied(decisions.first))
        #expect(column.kind == .column)
        #expect(column.members == login.map(\.id))
        #expect(column.container.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 32, alignment: .start)),
                "the median gap, 167, on the rhythm")
        #expect(column.container.frame == CGRect(x: 20, y: 75, width: 353, height: 355))
        #expect(frame(of: login[1].id, in: column)?.minY == 148)
        #expect(frame(of: login[2].id, in: column)?.minY == 230)
        #expect(abs(column.confidence - 0.6175) < 1e-9)
    }

    @Test func tidyingStillLeavesTheUntouchable() throws {
        let login = login()
        var locked = image(20, 720, 120, 100)
        locked.isLocked = true
        let parent = root(login + [locked])
        let decisions = infer(parent, new: [], mode: .tidy)
        #expect(decisions.count == 1)
        let column = try #require(applied(decisions.first))
        #expect(column.members == login.map(\.id))
        #expect(column.container.frame.maxY <= locked.frame.minY, "built above it")
        let result = try #require(StructureInference.applying(column, to: parent))
        #expect(result.children.map(\.id) == [column.container.id, locked.id])
        #expect(result.children[1] == locked, "a root child, unchanged")
    }

    // MARK: - A row the pass built, inside a column

    @Test func aPassBuiltRowInAColumnStillGrowsWithItsText() throws {
        let title = node(.title, 20, 80, 353, 40), label = node(.text, 20, 139, 240, 24)
        let toggle = node(.toggle, 272, 136, 51, 31), button = node(.button, 20, 183, 353, 50)
        let parent = root([title, label, toggle, button])
        let decisions = infer(parent)
        let row = try #require(applied(decisions.first)), column = try #require(applied(decisions.last))
        #expect(row.kind == .row && column.kind == .column)
        let proposed = try #require(column.container.children.first { $0.id == row.container.id })
        #expect(proposed.width.mode == .fit && proposed.height.mode == .fixed, "fit along its own axis (T3 m2)")

        let withRow = try #require(StructureInference.applying(row, to: parent))
        var built = try #require(StructureInference.applying(column, to: withRow))
        #expect(built.children[0].children[1].width.mode == .fit && built.children[0].children[1].height.mode == .fixed)
        // The label's text lengthens, and it fits it.
        built.children[0].children[1].children[0].width = LayerNode.Sizing(.fit)
        built.children[0].children[1].children[0].content.text = "Turn on notifications for every new message"
        var diagnostics: [LayoutDiagnostic] = []
        LayoutEngine.layOut(&built, previous: nil, measure: .shared, diagnostics: &diagnostics)
        let grown = built.children[0].children[1]
        #expect(grown.id == row.container.id)
        #expect(grown.frame.width == grown.children[0].frame.width + 12 + grown.children[1].frame.width)
        #expect(grown.frame.width > 303, "the row grows with its text")
    }
}
