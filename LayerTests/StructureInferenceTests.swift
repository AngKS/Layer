import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The structure pass's rows and columns (plan 5, Task 3). The parent is a free iPhone root, nodes are `.fixed` texts
/// unless named, and every node is new unless the test says otherwise.
@Suite struct StructureInferenceTests {
    // MARK: - Building

    private func node(_ kind: ElementKind = .text, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = CGRect(x: x, y: y, width: width, height: height)
        if kind.hasText { node.content.text = kind.placeholder }
        return node
    }

    private func text(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 100, _ height: CGFloat = 24) -> LayerNode {
        node(.text, x, y, width, height)
    }

    private func field(_ y: CGFloat) -> LayerNode { node(.textField, 20, y, 353, 44) }

    /// A free iPhone root holding `children`.
    private func root(_ children: [LayerNode]) -> LayerNode {
        var root = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil).root
        root.children = children
        return root
    }

    /// The pass over `parent`, with every child new unless `new` says which are.
    private func infer(_ parent: LayerNode, new: [LayerNode]? = nil, tokens: DesignTokens = .standard,
                       mode: StructureInference.Mode = .sketch, depth: Int = 0) -> [StructureInference.Decision] {
        StructureInference.infer(in: parent, new: Set((new ?? parent.children).map(\.id)), tokens: tokens, mode: mode,
                                 depth: depth)
    }

    private func applied(_ decision: StructureInference.Decision?) -> StructureInference.Structure? {
        if case .apply(let structure)? = decision { structure } else { nil }
    }

    private func offered(_ decision: StructureInference.Decision?) -> StructureInference.Structure? {
        if case .offer(let structure)? = decision { structure } else { nil }
    }

    private func stack(_ structure: StructureInference.Structure) -> LayerNode.Stack? {
        if case .stack(let stack) = structure.container.resolvedLayout { stack } else { nil }
    }

    /// Where a member sits in the parent's space once the structure is built.
    private func frame(of id: UUID, in structure: StructureInference.Structure) -> CGRect? {
        guard let member = structure.container.children.first(where: { $0.id == id }) else { return nil }
        return member.frame.offsetBy(dx: structure.container.frame.minX, dy: structure.container.frame.minY)
    }

    private let iPhone = CGRect(x: 0, y: 0, width: 393, height: 852)

    // MARK: - The bars

    @Test func decideFollowsTheBars() {
        typealias S = StructureInference
        #expect(S.decide(confidence: 0.9, rhythmMove: 3, medianMove: 0, mode: .sketch) == .applyRhythm)
        #expect(S.decide(confidence: 0.9, rhythmMove: 12, medianMove: 2, mode: .sketch) == .applyMedian)
        #expect(S.decide(confidence: 0.9, rhythmMove: 12, medianMove: 9, mode: .sketch) == .offer)
        #expect(S.decide(confidence: 0.6, rhythmMove: 0, medianMove: 0, mode: .sketch) == .offer)
        #expect(S.decide(confidence: 0.49, rhythmMove: 0, medianMove: 0, mode: .sketch) == nil)
        #expect(S.decide(confidence: 0.6, rhythmMove: 40, medianMove: 40, mode: .tidy) == .applyRhythm)
        #expect(S.decide(confidence: 0.49, rhythmMove: 0, medianMove: 0, mode: .tidy) == nil)
    }

    // MARK: - Rows

    @Test func twoTextsSideBySideMakeARow() throws {
        let a = text(20, 100), b = text(132, 100)
        let parent = root([a, b])
        let decisions = infer(parent)
        #expect(decisions.count == 1)
        let row = try #require(applied(decisions.first))
        #expect(row.kind == .row)
        #expect(row.parent == parent.id)
        #expect(row.members == [a.id, b.id])
        #expect(row.replacing.isEmpty)
        #expect(row.container.kind == .group)
        #expect(row.container.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .center)))
        #expect(row.container.padding == LayerNode.Padding())
        #expect(row.container.width.mode == .fit && row.container.height.mode == .fit)
        #expect(row.container.frame == CGRect(x: 20, y: 100, width: 212, height: 24))
        #expect(row.container.children.map(\.id) == [a.id, b.id])
        #expect(frame(of: a.id, in: row) == a.frame && frame(of: b.id, in: row) == b.frame)
        #expect(row.confidence == 1)
        #expect(row.movement == 0)
        #expect(infer(parent) == decisions, "the pass is deterministic, the container's id included")
    }

    @Test func rowsAreReadLeftToRight() throws {
        let a = text(20, 100), b = text(132, 100)
        let row = try #require(applied(infer(root([b, a])).first))
        #expect(row.members == [a.id, b.id])
        #expect(row.container.children.map(\.id) == [a.id, b.id])
    }

    @Test func membersAreFixedAtTheirSize() throws {
        var a = text(20, 100)
        a.width = LayerNode.Sizing(.fit)
        let b = text(132, 100)
        let row = try #require(applied(infer(root([a, b])).first))
        let member = try #require(row.container.children.first { $0.id == a.id })
        #expect(member.width.mode == .fixed && member.height.mode == .fixed)
        #expect(member.frame.size == a.frame.size)
    }

    @Test func aRowSnapsItsGapToTheRhythm() throws {
        let a = text(20, 100), b = text(134, 100)
        let decisions = infer(root([a, b]))
        #expect(decisions.count == 1)
        let row = try #require(applied(decisions.first))
        #expect(stack(row)?.spacing == 12, "14 is as near 12 as 16, and the smaller wins")
        #expect(row.movement == 2)
        #expect(row.container.frame == CGRect(x: 20, y: 100, width: 212, height: 24))
        #expect(frame(of: b.id, in: row) == CGRect(x: 132, y: 100, width: 100, height: 24))
    }

    @Test func theRhythmIsTheDesigns() throws {
        var tokens = DesignTokens()
        tokens.rhythm = [4, 10, 20, 40]
        let row = try #require(applied(infer(root([text(20, 100), text(133, 100)]), tokens: tokens).first))
        #expect(stack(row)?.spacing == 10)
        #expect(row.movement == 3)
    }

    @Test func theExactMedianIsTriedBeforeOffering() throws {
        let texts = [20, 96, 172, 248, 324].map { text($0, 100, 56, 24) }
        let decisions = infer(root(texts))
        #expect(decisions.count == 1)
        let row = try #require(applied(decisions.first), "the rhythm's 16 would move the last one 16 pt; the median's 20 moves nothing")
        #expect(row.members == texts.map(\.id))
        #expect(stack(row)?.spacing == 20)
        #expect(row.movement == 0)
        #expect(row.container.frame == CGRect(x: 20, y: 100, width: 360, height: 24))
    }

    @Test func aRaggedRowIsOffered() throws {
        let texts = [text(20, 100), text(124, 100), text(254, 100)]
        let decisions = infer(root(texts))
        #expect(decisions.count == 1)
        let row = try #require(offered(decisions.first))
        #expect(row.kind == .row)
        #expect(row.members == texts.map(\.id))
        #expect(row.confidence == 0.59375, "gaps 4 and 30: 1 − 26 / 64")
        #expect(row.title == "Make a row?")
        #expect(stack(row)?.spacing == 16, "an offer carries the rhythm's spacing: the median gap, 17, on the rhythm")
    }

    @Test func rowNearMissesDontGroup() {
        let a = text(20, 100)
        // A gap of 40.
        #expect(infer(root([a, text(160, 100)])).isEmpty)
        // Heights of 20 and 50, centred on one line.
        #expect(infer(root([text(20, 100, 100, 20), text(132, 85, 100, 50)])).isEmpty)
        // Centres 10 apart, and tops and bottoms too.
        #expect(infer(root([a, text(132, 110)])).isEmpty)
        // A locked divider in the gap.
        var divider = node(.divider, 125, 100, 2, 24)
        divider.isLocked = true
        let b = text(132, 100)
        #expect(infer(root([a, divider, b]), new: [a, b]).isEmpty)
        // Two established texts.
        #expect(infer(root([a, b]), new: []).isEmpty)
        // A partner the pass may not take.
        var locked = b; locked.isLocked = true
        var hidden = b; hidden.isHidden = true
        var turned = b; turned.rotation = 10
        var declined = b
        declined.sketch = LayerNode.SketchIntent(sketched: b.frame, on: iPhone.size, margin: 20, confidence: 1, decidedBy: .rules)
        declined.sketch?.structureDeclined = true
        var persons = node(.group, 132, 100, 100, 24)
        persons.children = [text(0, 0), text(0, 0, 40, 24)]
        for partner in [locked, hidden, turned, declined, persons] {
            #expect(infer(root([a, partner]), new: [a]).isEmpty, "\(partner.kind) locked \(partner.isLocked) hidden \(partner.isHidden)")
        }
        // A partner farther than 48 from the neighbourhood isn't looked at.
        let far = root([a, text(169, 100)])
        #expect(infer(far, new: [a]).isEmpty)
        #expect(StructureInference.neighbourhoodSizes(of: far.id).last == 1)
    }

    // MARK: - Columns

    @Test func threeAlignedFieldsMakeAColumn() throws {
        let fields = [field(200), field(260), field(320)]
        let parent = root(fields)
        let decisions = infer(parent)
        #expect(decisions.count == 1)
        let column = try #require(applied(decisions.first))
        #expect(column.kind == .column)
        #expect(column.title == "Make a column?")
        #expect(column.members == fields.map(\.id))
        #expect(column.container.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 16, alignment: .start)),
                "all three edges tie, so leading (F20)")
        #expect(column.container.frame == CGRect(x: 20, y: 200, width: 353, height: 164))
        #expect(column.confidence == 1)
        #expect(column.movement == 0)
    }

    @Test func twoStackedThingsAreNotAColumn() {
        #expect(infer(root([field(200), field(260)])).isEmpty)
    }

    @Test func irregularGapsAreNotAColumnUnlessTidying() throws {
        let fields = [field(200), field(260), field(328)]
        #expect(infer(root(fields)).isEmpty, "gaps 16 and 24 vary by more than 4")
        let decisions = infer(root(fields), mode: .tidy)
        #expect(decisions.count == 1)
        let column = try #require(applied(decisions.first))
        #expect(stack(column)?.spacing == 16, "20 is as near 16 as 24, and the smaller wins")
        #expect(fields.map { frame(of: $0.id, in: column)?.minY } == [200, 260, 320])
    }

    @Test func aCentredColumnOfUnevenWidthsIsOffered() throws {
        let title = node(.title, 96, 80, 200, 40), field = node(.textField, 20, 136, 353, 44), button = node(.button, 20, 196, 353, 50)
        let decisions = infer(root([title, field, button]))
        #expect(decisions.count == 1)
        let column = try #require(offered(decisions.first))
        #expect(column.members == [title.id, field.id, button.id])
        #expect(stack(column)?.alignment == .center)
        #expect(abs(column.confidence - 0.9375 * 1 * 0.6175) < 1e-9)
        #expect((column.confidence * 10_000).rounded() / 10_000 == 0.5789)
    }

    @Test func aRowInsideAColumnIsBuiltFirst() throws {
        let title = node(.title, 20, 80, 353, 40), label = node(.text, 20, 139, 240, 24)
        let toggle = node(.toggle, 272, 136, 51, 31), button = node(.button, 20, 183, 353, 50)
        let parent = root([title, label, toggle, button])
        let decisions = infer(parent)
        #expect(decisions.count == 2)
        let row = try #require(applied(decisions.first))
        let column = try #require(applied(decisions.last))
        #expect(row.kind == .row && column.kind == .column)
        #expect(row.members == [label.id, toggle.id])
        #expect(stack(row)?.spacing == 12)
        #expect(row.container.frame == CGRect(x: 20, y: 136, width: 303, height: 31))
        #expect(row.confidence >= 0.8)
        #expect(row.movement <= 1)
        #expect(column.members == [title.id, row.container.id, button.id])
        #expect(stack(column)?.spacing == 16)
        #expect(column.container.frame == CGRect(x: 20, y: 80, width: 353, height: 153))

        // Applied in order, the column holds the row.
        let withRow = try #require(StructureInference.applying(row, to: parent))
        let built = try #require(StructureInference.applying(column, to: withRow))
        #expect(built.children.map(\.id) == [column.container.id])
        #expect(built.children[0].children.map(\.id) == [title.id, row.container.id, button.id])
        #expect(built.children[0].children[1].children.map(\.id) == [label.id, toggle.id])
    }

    // MARK: - Applying

    @Test func applyingBuildsInTheFrontmostSlot() throws {
        let x = text(20, 500), a = text(20, 100), y = text(20, 700), b = text(132, 100)
        let parent = root([x, a, y, b])
        let row = try #require(applied(infer(parent, new: [a, b]).first))
        #expect(row.members == [a.id, b.id])
        let built = try #require(StructureInference.applying(row, to: parent))
        #expect(built.children.map(\.id) == [x.id, y.id, row.container.id], "the row takes B's slot")
        let container = built.children[2]
        #expect(container.layout == row.container.layout && container.frame == row.container.frame)
        #expect(container.children.map(\.id) == [a.id, b.id])
        #expect(container.children.map(\.frame) == row.container.children.map(\.frame))
        #expect(container.children.allSatisfy { $0.width.mode == .fixed && $0.height.mode == .fixed })

        var withoutB = parent
        withoutB.children.removeAll { $0.id == b.id }
        #expect(StructureInference.applying(row, to: withoutB) == nil)
    }

    // MARK: - What it looks at, and what it never does

    @Test func thePassLooksOnlyAtTheNeighbourhood() {
        var established: [LayerNode] = []
        for row in 0..<10 {
            for column in 0..<6 { established.append(text(CGFloat(column) * 70, CGFloat(row) * 70, 20, 10)) }
        }
        let new = text(0, 760, 20, 10)
        let parent = root(established + [new])
        #expect(infer(parent, new: [new]).isEmpty)
        #expect(StructureInference.neighbourhoodSizes(of: parent.id).last == 1)
    }

    @Test func aProposalLaysOutNothingItHolds() throws {
        var card = node(.card, 132, 100, 100, 24)
        card.children = [text(8, 4, 40, 16)]
        card.sketch = LayerNode.SketchIntent(sketched: card.frame, on: iPhone.size, margin: 20, confidence: 0.95, decidedBy: .rules)
        let a = text(20, 100)
        let row = try #require(applied(infer(root([a, card]), new: [a]).first))
        #expect(row.members == [a.id, card.id], "a sketched card may sit in a row")
        #expect(row.container.children[1].children == card.children, "what the card holds is as it was")
        #expect(LayoutEngine.timesLaidOut(card.id) == 0)
        #expect(LayoutEngine.timesLaidOut(row.container.id) == 0, "the container is laid out only when it is built (F7)")
    }

    @Test func aRowNeverHoldsARow() {
        var row = node(.group, 20, 100, 212, 24)
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .center))
        row.width = LayerNode.Sizing(.fit)
        row.height = LayerNode.Sizing(.fit)
        row.children = [text(0, 0), text(112, 0)]
        row.sketch = LayerNode.SketchIntent(sketched: row.frame, on: iPhone.size, margin: 20, confidence: 1, decidedBy: .structure)
        let c = text(244, 100)
        #expect(infer(root([row, c]), new: [c]).isEmpty)
    }

    @Test func nothingIsBuiltPastDepth32() throws {
        let a = text(20, 100), b = text(132, 100)
        // A free group at depth 31, inside 30 more, holds them at depth 32.
        var deepest = node(.group, 0, 0, 393, 852)
        deepest.children = [a, b]
        var chain = deepest
        for _ in 1..<31 {
            var outer = node(.group, 0, 0, 393, 852)
            outer.children = [chain]
            chain = outer
        }
        var content = TreeContent()
        content.screens = [TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil, root: root([chain]))]
        let depth = try #require(TreeIndex(content)[deepest.id]?.depth)
        #expect(depth == 31 && TreeIndex(content)[a.id]?.depth == 32)
        #expect(infer(deepest, depth: depth).isEmpty)
        #expect(infer(deepest, depth: depth - 1).count == 1, "a level higher, the same two make a row")
    }
}
