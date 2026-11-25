import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct LayoutEngineFreeTests {
    private let measure = TextMeasure.shared

    // MARK: - Building trees

    private func shape(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, turned degrees: Double? = nil) -> LayerNode {
        var node = LayerNode(kind: .shape)
        node.frame = CGRect(x: x, y: y, width: width, height: height)
        node.rotation = degrees
        return node
    }

    /// A free group sized to fit on both axes, as Group makes them.
    private func group(_ frame: CGRect, turned degrees: Double? = nil, children: [LayerNode]) -> LayerNode {
        var node = LayerNode(kind: .group)
        node.layout = .free
        node.width = LayerNode.Sizing(.fit)
        node.height = LayerNode.Sizing(.fit)
        node.frame = frame
        node.rotation = degrees
        node.children = children
        return node
    }

    /// A free screen root, fixed at an iPhone's size.
    private func screen(_ children: [LayerNode]) -> LayerNode {
        var node = LayerNode(kind: .group)
        node.layout = .free
        node.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        node.children = children
        return node
    }

    private func laidOut(_ node: LayerNode, previous: LayerNode? = nil) -> (node: LayerNode, diagnostics: [LayoutDiagnostic]) {
        var node = node
        var diagnostics: [LayoutDiagnostic] = []
        LayoutEngine.layOut(&node, previous: previous, measure: measure, diagnostics: &diagnostics)
        return (node, diagnostics)
    }

    private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Each visible leaf's centre in `node`'s parent's space, through every container's turn.
    private func leafCentres(_ node: LayerNode, into space: CGAffineTransform = .identity) -> [UUID: CGPoint] {
        guard node.isContainer else { return [node.id: centre(node.frame).applying(space)] }
        let inner = node.transformToParent.concatenating(space)
        return node.children.reduce(into: [:]) { centres, child in
            centres.merge(leafCentres(child, into: inner)) { first, _ in first }
        }
    }

    private func frames(in node: LayerNode) -> [CGRect] {
        node.children.flatMap { [$0.frame] + frames(in: $0) }
    }

    // MARK: - Keeping and hugging

    @Test func aFreeContainerKeepsItsChildrensFrames() throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "design-sketch", withExtension: "json"))
        let content = try TreeManifest.decode(try Data(contentsOf: url)).content
        let root = try #require(content.screens.first).root
        #expect(root.resolvedLayout == .free)
        #expect(root.frame.size == CGSize(width: 393, height: 852))
        #expect(root.children.count == 4)

        let (laid, diagnostics) = laidOut(root)
        #expect(laid == root)
        #expect(diagnostics.isEmpty)
    }

    @Test func aFittingFreeGroupHugsItsChildrenAndNothingMoves() {
        let before = group(CGRect(x: 50, y: 50, width: 999, height: 999),
                           children: [shape(10, 10, 20, 20), shape(40, 30, 10, 10)])
        let after = laidOut(before).node

        #expect(after.frame == CGRect(x: 60, y: 60, width: 40, height: 30))
        #expect(after.children.map(\.frame) == [CGRect(x: 0, y: 0, width: 20, height: 20), CGRect(x: 30, y: 20, width: 10, height: 10)])
        for (old, new) in zip(before.children, after.children) {
            #expect(new.frame.applying(after.transformToParent) == old.frame.applying(before.transformToParent))
        }
    }

    @Test func aTurnedFittingFreeGroupKeepsItsChildrenWhereTheyWere() {
        let before = group(CGRect(x: 50, y: 50, width: 999, height: 999), turned: 30,
                           children: [shape(10, 10, 20, 20), shape(40, 30, 10, 10)])
        let after = laidOut(before).node

        #expect(after.frame.size == CGSize(width: 40, height: 30))
        #expect(after.rotation == 30)
        #expect(after.children.map(\.frame) == [CGRect(x: 0, y: 0, width: 20, height: 20), CGRect(x: 30, y: 20, width: 10, height: 10)])
        for (old, new) in zip(before.children, after.children) {
            let was = centre(old.frame).applying(before.transformToParent)
            let now = centre(new.frame).applying(after.transformToParent)
            #expect(distance(was, now) < 0.001, "\(was) moved to \(now)")
        }
    }

    @Test func turnedChildrenAreBoxedByTheirTurnedShapes() {
        let before = group(CGRect(x: 0, y: 0, width: 300, height: 300), children: [shape(10, 10, 100, 20, turned: 90)])
        let after = laidOut(before).node

        // The box's edges are whole points, so a turn's rounding error doesn't widen it.
        #expect(after.frame.size == CGSize(width: 20, height: 100))
        let child = after.children[0]
        let shape = TurnedRect(rect: child.frame, degrees: 90).bounds
        #expect(abs(shape.minX) < 0.001 && abs(shape.minY) < 0.001)
        #expect(abs(shape.width - 20) < 0.001 && abs(shape.height - 100) < 0.001)
        #expect(distance(centre(child.frame).applying(after.transformToParent),
                         centre(before.children[0].frame).applying(before.transformToParent)) < 0.001)
    }

    @Test func nestedFreeGroupsHugFromTheInsideOut() throws {
        let inner = group(CGRect(x: 30, y: 40, width: 500, height: 500), turned: 45,
                          children: [shape(5, 5, 40, 20), shape(60, 50, 30, 30, turned: 15)])
        let outer = group(CGRect(x: 100, y: 120, width: 10, height: 10), turned: 20,
                          children: [inner, shape(200, 10, 50, 50)])
        let root = screen([outer])

        let laid = laidOut(root).node
        let before = leafCentres(root), after = leafCentres(laid)
        #expect(before.count == 3)
        for (id, was) in before {
            let now = try #require(after[id])
            #expect(distance(was, now) < 0.001, "\(was) moved to \(now)")
        }

        // The inner group's turned shape sits inside the outer group's box, which starts at 0.
        let hugged = laid.children[0]
        let shapes = hugged.children.map { TurnedRect(rect: $0.frame, degrees: $0.rotation ?? 0).bounds }
        let box = shapes.dropFirst().reduce(shapes[0]) { $0.union($1) }
        #expect(box.minX >= 0 && box.minY >= 0 && box.minX < 1 && box.minY < 1)
        #expect(box.maxX <= hugged.frame.width && box.maxY <= hugged.frame.height)
        #expect(hugged.frame.width - box.maxX < 1 && hugged.frame.height - box.maxY < 1)

        // Hugging again changes nothing.
        #expect(laidOut(laid).node == laid)
    }

    @Test func hiddenChildrenMoveWithTheGroupButTakeNoSpace() {
        var hidden = shape(300, 300, 50, 50)
        hidden.isHidden = true
        let before = group(CGRect(x: 50, y: 50, width: 999, height: 999), turned: 10,
                           children: [shape(10, 10, 20, 20), hidden])
        let after = laidOut(before).node

        #expect(after.frame.size == CGSize(width: 20, height: 20))
        let was = centre(hidden.frame).applying(before.transformToParent)
        let now = centre(after.children[1].frame).applying(after.transformToParent)
        #expect(distance(was, now) < 0.001)
    }

    @Test func paddingSurroundsTheHuggedContent() {
        var padded = group(CGRect(x: 50, y: 50, width: 999, height: 999), children: [shape(10, 10, 20, 20), shape(40, 30, 10, 10)])
        padded.padding = LayerNode.Padding(all: 8)
        let after = laidOut(padded).node
        #expect(after.frame == CGRect(x: 52, y: 52, width: 56, height: 46))
        #expect(after.children.map(\.frame.origin) == [CGPoint(x: 8, y: 8), CGPoint(x: 38, y: 28)])

        // With nothing visible, it fits its padding, and its children stay where they were.
        var hidden = shape(10, 10, 20, 20)
        hidden.isHidden = true
        var empty = group(CGRect(x: 50, y: 50, width: 999, height: 999), children: [hidden])
        empty.padding = LayerNode.Padding(all: 8)
        let emptied = laidOut(empty).node
        #expect(emptied.frame == CGRect(x: 50, y: 50, width: 16, height: 16))
        #expect(emptied.children[0].frame == hidden.frame)
    }

    @Test func aFittingFreeGroupInAColumnTakesItsHuggedSize() {
        let hugging = group(CGRect(x: 0, y: 0, width: 999, height: 999), children: [shape(10, 10, 20, 20), shape(40, 30, 10, 10)])
        #expect(LayoutEngine.size(of: hugging, proposal: ProposedSize(width: 393, height: nil), measure: measure)
            == CGSize(width: 40, height: 30))

        var column = LayerNode(kind: .group)
        column.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 10))
        column.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        column.children = [shape(0, 0, 50, 40), hugging]
        let laid = laidOut(column).node

        // The column places it; it moves only what it holds.
        #expect(laid.children[1].frame == CGRect(x: 0, y: 50, width: 40, height: 30))
        #expect(laid.children[1].children.map(\.frame.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 20)])
    }

    @Test func badNumbersInAFreeGroupNeverMakeABadFrame() {
        var broken = shape(.nan, 10, .infinity, -20)
        broken.rotation = .nan
        let before = group(CGRect(x: CGFloat.infinity, y: 50, width: CGFloat.nan, height: 999), turned: .nan,
                           children: [broken, shape(10, 10, 20, 20, turned: Double.infinity)])
        let after = laidOut(screen([before])).node
        #expect(([after.frame] + frames(in: after)).allSatisfy {
            [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height].allSatisfy(\.isFinite)
        })
        let turn = after.children[0].transformToParent
        #expect([turn.a, turn.b, turn.c, turn.d, turn.tx, turn.ty].allSatisfy { $0.isFinite })
    }

    // MARK: - Laying out only what changed

    /// A column root holding three cards, each a column holding a body.
    private func columnOfThree() -> LayerNode {
        func card(_ text: String) -> LayerNode {
            var body = LayerNode(kind: .body)
            body.content.text = text
            body.width = LayerNode.Sizing(.fill(weight: 1))
            body.height = LayerNode.Sizing(.fit)
            var card = LayerNode(kind: .card)
            card.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 8))
            card.padding = LayerNode.Padding(all: 16)
            card.width = LayerNode.Sizing(.fill(weight: 1))
            card.height = LayerNode.Sizing(.fit)
            card.children = [body]
            return card
        }
        var root = LayerNode(kind: .group)
        root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 16))
        root.padding = LayerNode.Padding(all: 20)
        root.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        root.children = [card("First"), card("Second"), card("Third")]
        return root
    }

    /// A free screen holding three fitting free groups, each holding a body and a shape.
    private func freeScreenOfThree() -> LayerNode {
        func held(_ text: String, at y: CGFloat) -> LayerNode {
            var body = LayerNode(kind: .body)
            body.content.text = text
            body.frame = CGRect(x: 20, y: y, width: 200, height: 40)
            return group(.zero, children: [body, shape(240, y, 40, 40)])
        }
        return screen([held("First", at: 100), held("Second", at: 200), held("Third", at: 300)])
    }

    @Test func anUnchangedSubtreeIsNotLaidOutAgain() {
        for root in [columnOfThree(), freeScreenOfThree()] {
            // Counted for each container, since suites that run alongside lay out containers of their own.
            let ids = [root.id] + root.children.map(\.id)
            let first = ids.map(LayoutEngine.timesLaidOut)
            let laid = laidOut(root).node
            let second = ids.map(LayoutEngine.timesLaidOut)
            #expect(zip(second, first).map(-) == [1, 1, 1, 1])

            var edited = laid
            edited.children[1].children[0].content.text = "Second, now long enough to wrap onto another line of the card"
            let total = LayoutEngine.containersLaidOut
            let again = laidOut(edited, previous: laid).node
            let third = ids.map(LayoutEngine.timesLaidOut)
            // The root and B; A and C are left as they were.
            #expect(zip(third, second).map(-) == [1, 0, 1, 0])
            #expect(LayoutEngine.containersLaidOut - total >= 2)

            // What is left alone is what laying it all out again would give.
            #expect(again == laidOut(edited).node)
        }
    }

    @Test func aContainerGivenANewSizeIsLaidOutAgain() {
        var column = LayerNode(kind: .group)
        column.layout = .stack(LayerNode.Stack(axis: .vertical, alignment: .fill))
        column.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        column.children = [group(.zero, children: [shape(10, 10, 20, 20), shape(40, 30, 10, 10)])]
        let stretched = laidOut(column).node
        #expect(stretched.children[0].frame == CGRect(x: 0, y: 0, width: 393, height: 30))

        // Unchanged itself, but a free parent gives it the size it hugs.
        var freed = stretched
        freed.layout = .free
        let held = stretched.children[0].id
        let before = LayoutEngine.timesLaidOut(held)
        let hugged = laidOut(freed, previous: stretched).node
        #expect(hugged.children[0].frame == CGRect(x: 0, y: 0, width: 40, height: 30))
        #expect(hugged.children[0].children == stretched.children[0].children)
        #expect(LayoutEngine.timesLaidOut(held) == before + 1)
    }

    @Test func aRowInAFreeScreenKeepsItsPlace() {
        var row = LayerNode(kind: .group)
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
        row.width = LayerNode.Sizing(.fit)
        row.height = LayerNode.Sizing(.fit)
        row.frame = CGRect(x: 40, y: 200, width: 10, height: 10)
        row.children = [shape(0, 0, 50, 30), shape(0, 0, 60, 30)]

        let laid = laidOut(screen([row])).node
        #expect(laid.children[0].frame == CGRect(x: 40, y: 200, width: 118, height: 30))

        var grown = laid
        grown.children[0].children[0].frame.size.width = 90
        let regrown = laidOut(grown, previous: laid).node
        #expect(regrown.children[0].frame == CGRect(x: 40, y: 200, width: 158, height: 30))
        #expect(regrown.children[0].children.map(\.frame.minX) == [0, 98])
    }
}

/// Something in the test bundle to find the bundle by.
private final class BundleMarker {}
