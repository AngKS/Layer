import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct LayoutEngineTests {
    private let measure = TextMeasure.shared

    // MARK: - Building trees

    /// A shape with fixed sizing, at the origin.
    private func shape(_ width: CGFloat, _ height: CGFloat) -> LayerNode {
        var node = LayerNode(kind: .shape)
        node.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return node
    }

    /// A shape that fills its row's width by `weight`.
    private func filling(_ weight: CGFloat, minimum: CGFloat? = nil, maximum: CGFloat? = nil) -> LayerNode {
        var node = shape(0, 40)
        node.width = LayerNode.Sizing(.fill(weight: weight), minimum: minimum, maximum: maximum)
        return node
    }

    private func stack(
        _ axis: LayerNode.Axis, spacing: CGFloat = 0, alignment: LayerNode.CrossAlignment = .start,
        justify: LayerNode.Justify = .start, size: CGSize, children: [LayerNode]
    ) -> LayerNode {
        var node = LayerNode(kind: .group)
        node.layout = .stack(LayerNode.Stack(axis: axis, spacing: spacing, alignment: alignment, justify: justify))
        node.frame = CGRect(origin: .zero, size: size)
        node.children = children
        return node
    }

    private func grid(
        columns: Int, columnSpacing: CGFloat = 0, rowSpacing: CGFloat = 0, size: CGSize, children: [LayerNode]
    ) -> LayerNode {
        var node = LayerNode(kind: .group)
        node.layout = .grid(LayerNode.Grid(
            columns: columns, columnSpacing: columnSpacing, rowSpacing: rowSpacing,
            alignment: LayerNode.Alignment(horizontal: .start, vertical: .start)))
        node.frame = CGRect(origin: .zero, size: size)
        node.children = children
        return node
    }

    private func overlay(_ horizontal: LayerNode.Edge3, _ vertical: LayerNode.Edge3, size: CGSize, children: [LayerNode]) -> LayerNode {
        var node = LayerNode(kind: .group)
        node.layout = .overlay(LayerNode.Alignment(horizontal: horizontal, vertical: vertical))
        node.frame = CGRect(origin: .zero, size: size)
        node.children = children
        return node
    }

    private func fitting(_ node: LayerNode) -> LayerNode {
        var node = node
        node.width = LayerNode.Sizing(.fit)
        node.height = LayerNode.Sizing(.fit)
        return node
    }

    private func laidOut(_ node: LayerNode) -> (node: LayerNode, diagnostics: [LayoutDiagnostic]) {
        var node = node
        var diagnostics: [LayoutDiagnostic] = []
        LayoutEngine.layOut(&node, previous: nil, measure: measure, diagnostics: &diagnostics)
        return (node, diagnostics)
    }

    private func frames(in node: LayerNode) -> [CGRect] {
        node.children.flatMap { [$0.frame] + frames(in: $0) }
    }

    // MARK: - Stacks

    @Test func aColumnStacksChildrenWithSpacingAndPadding() {
        var column = stack(.vertical, spacing: 12, alignment: .start, size: CGSize(width: 393, height: 400),
                           children: [shape(100, 40), shape(200, 20)])
        column.padding = LayerNode.Padding(all: 16)
        column.height = LayerNode.Sizing(.fit)

        let (laid, diagnostics) = laidOut(column)
        #expect(laid.children[0].frame == CGRect(x: 16, y: 16, width: 100, height: 40))
        #expect(laid.children[1].frame == CGRect(x: 16, y: 68, width: 200, height: 20))
        #expect(laid.frame == column.frame)
        #expect(diagnostics.isEmpty)
        #expect(LayoutEngine.size(of: column, proposal: ProposedSize(width: 393, height: nil), measure: measure).height == 104)
    }

    @Test func fillingChildrenShareTheRestByWeight() {
        let row = stack(.horizontal, size: CGSize(width: 300, height: 40), children: [shape(100, 40), filling(1), filling(3)])
        let laid = laidOut(row).node
        #expect(laid.children.map(\.frame.width) == [100, 50, 150])
        #expect(laid.children.map(\.frame.minX) == [0, 100, 150])
    }

    @Test func minimumAndMaximumClampAFillingChild() {
        let capped = stack(.horizontal, size: CGSize(width: 300, height: 40),
                           children: [shape(100, 40), filling(1), filling(3, maximum: 120)])
        let laid = laidOut(capped).node
        #expect(laid.children.map(\.frame.width) == [100, 50, 120])
        #expect(laid.children.map(\.frame.minX) == [0, 100, 150])

        let raised = stack(.horizontal, size: CGSize(width: 300, height: 40),
                           children: [shape(100, 40), filling(1, minimum: 70), filling(3)])
        #expect(laidOut(raised).node.children.map(\.frame.width) == [100, 70, 150])
    }

    @Test func crossAxisAlignmentPlacesAndStretches() {
        func placed(_ alignment: LayerNode.CrossAlignment, _ child: LayerNode) -> CGRect {
            let row = stack(.horizontal, alignment: alignment, size: CGSize(width: 300, height: 100), children: [child])
            return laidOut(row).node.children[0].frame
        }
        #expect(placed(.start, shape(50, 40)) == CGRect(x: 0, y: 0, width: 50, height: 40))
        #expect(placed(.center, shape(50, 40)) == CGRect(x: 0, y: 30, width: 50, height: 40))
        #expect(placed(.end, shape(50, 40)) == CGRect(x: 0, y: 60, width: 50, height: 40))

        // A symbol is 44 high by nature (a shape's 100 would match the row), so only a stretch makes it 100.
        var fit = LayerNode(kind: .symbol)
        fit.frame = CGRect(x: 0, y: 0, width: 50, height: 40)
        fit.height = LayerNode.Sizing(.fit)
        #expect(placed(.start, fit) == CGRect(x: 0, y: 0, width: 50, height: 44))
        #expect(placed(.fill, fit) == CGRect(x: 0, y: 0, width: 50, height: 100))
        #expect(placed(.fill, shape(50, 40)) == CGRect(x: 0, y: 0, width: 50, height: 40))

        var fill = fit
        fill.height = LayerNode.Sizing(.fill(weight: 1))
        #expect(placed(.center, fill) == CGRect(x: 0, y: 0, width: 50, height: 100))
    }

    @Test func justifySpreadsTheLeftover() {
        func xs(_ justify: LayerNode.Justify) -> [CGFloat] {
            let row = stack(.horizontal, justify: justify, size: CGSize(width: 300, height: 50),
                            children: [shape(50, 50), shape(50, 50), shape(50, 50)])
            let laid = laidOut(row).node
            #expect(laid.children.map(\.frame.width) == [50, 50, 50])
            return laid.children.map(\.frame.minX)
        }
        #expect(xs(.spaceBetween) == [0, 125, 250])
        #expect(xs(.spaceAround) == [25, 125, 225])
        #expect(xs(.spaceEvenly) == [38, 125, 213])
        #expect(xs(.center) == [75, 125, 175])
        #expect(xs(.start) == [0, 50, 100])
        #expect(xs(.end) == [150, 200, 250])
    }

    @Test func justifyIsIgnoredWhenAChildFills() {
        for justify in [LayerNode.Justify.spaceBetween, .center, .end] {
            // Even when the filling child is capped and leaves room over.
            let row = stack(.horizontal, justify: justify, size: CGSize(width: 300, height: 40),
                            children: [shape(50, 40), filling(1, maximum: 100), shape(50, 40)])
            let laid = laidOut(row).node
            #expect(laid.children.map(\.frame.width) == [50, 100, 50])
            #expect(laid.children.map(\.frame.minX) == [0, 50, 150])
        }

        // A hidden filling child doesn't count.
        var hidden = filling(1)
        hidden.isHidden = true
        let row = stack(.horizontal, justify: .spaceBetween, size: CGSize(width: 300, height: 40),
                        children: [shape(50, 40), hidden, shape(50, 40)])
        let laid = laidOut(row).node
        #expect([laid.children[0].frame.minX, laid.children[2].frame.minX] == [0, 250])
    }

    // MARK: - Grids and overlays

    @Test func aGridFillsRowByRowWithEqualColumns() {
        let cells = grid(columns: 2, columnSpacing: 10, rowSpacing: 8, size: CGSize(width: 210, height: 68),
                         children: Array(repeating: shape(100, 30), count: 4))
        let (laid, diagnostics) = laidOut(cells)
        #expect(laid.children.map(\.frame.origin) == [
            CGPoint(x: 0, y: 0), CGPoint(x: 110, y: 0), CGPoint(x: 0, y: 38), CGPoint(x: 110, y: 38)
        ])
        #expect(laid.children.allSatisfy { $0.frame.size == CGSize(width: 100, height: 30) })
        #expect(diagnostics.isEmpty)
    }

    @Test func aGridRowIsAsTallAsItsTallestCell() {
        let cells = grid(columns: 2, columnSpacing: 10, rowSpacing: 8, size: CGSize(width: 210, height: 200),
                         children: [shape(100, 30), shape(100, 50), shape(100, 20)])
        let laid = laidOut(cells).node
        #expect(laid.children[2].frame.origin == CGPoint(x: 0, y: 50 + 8))
    }

    @Test func aFittingGridWithFewerChildrenThanColumnsKeepsEveryColumn() {
        var cells = fitting(grid(columns: 3, columnSpacing: 10, size: .zero, children: [shape(100, 30), shape(100, 30)]))
        let ideal = LayoutEngine.size(of: cells, proposal: ProposedSize(width: nil, height: nil), measure: measure)
        #expect(ideal == CGSize(width: 3 * 100 + 2 * 10, height: 30))

        cells.frame.size = ideal
        let (laid, diagnostics) = laidOut(cells)
        #expect(laid.children.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 100, height: 30), CGRect(x: 110, y: 0, width: 100, height: 30)
        ])
        #expect(!laid.children[0].frame.intersects(laid.children[1].frame))
        #expect(diagnostics.isEmpty)
    }

    @Test func aGridChildWiderThanItsColumnIsReported() {
        let cells = grid(columns: 2, size: CGSize(width: 100, height: 40), children: [shape(80, 40), shape(80, 40)])
        let (laid, diagnostics) = laidOut(cells)
        #expect(diagnostics == [LayoutDiagnostic(node: cells.id, kind: .overflow)])
        #expect(laid.children.map(\.frame.width) == [80, 80])
    }

    @Test func anOverlayAlignsEveryChild() {
        let corner = overlay(.end, .end, size: CGSize(width: 200, height: 200), children: [shape(50, 50), shape(20, 10)])
        let laid = laidOut(corner).node
        #expect(laid.children[0].frame == CGRect(x: 150, y: 150, width: 50, height: 50))
        #expect(laid.children[1].frame == CGRect(x: 180, y: 190, width: 20, height: 10))

        let fitted = fitting(overlay(.center, .center, size: .zero, children: [shape(80, 20), shape(40, 60)]))
        #expect(LayoutEngine.size(of: fitted, proposal: ProposedSize(width: nil, height: nil), measure: measure)
            == CGSize(width: 80, height: 60))
        #expect(LayoutEngine.size(of: fitted, proposal: ProposedSize(width: 393, height: 852), measure: measure)
            == CGSize(width: 80, height: 60))
    }

    // MARK: - Nesting

    @Test func cardsAndColumnsNest() {
        var card = LayerNode(kind: .card)
        card.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 8))
        card.padding = LayerNode.Padding(all: 16)
        card.width = LayerNode.Sizing(.fill(weight: 1))
        card.height = LayerNode.Sizing(.fit)
        card.children = [shape(100, 20), shape(100, 20)]

        var root = stack(.vertical, size: CGSize(width: 393, height: 852), children: [card])
        root.padding = LayerNode.Padding(all: 20)

        let laid = laidOut(root).node
        #expect(laid.children[0].frame == CGRect(x: 20, y: 20, width: 353, height: 16 + 20 + 8 + 20 + 16))
        #expect(laid.children[0].children.map(\.frame.origin) == [CGPoint(x: 16, y: 16), CGPoint(x: 16, y: 44)])
    }

    @Test func laidOutChildrenNeverOverlap() {
        var text = LayerNode(kind: .text)
        text.content.text = "Hello"
        var stretch = shape(0, 30)
        stretch.width = LayerNode.Sizing(.fill(weight: 1))
        let row = fitting(stack(.horizontal, spacing: 8, alignment: .center, size: .zero,
                                children: [shape(80, 40), fitting(text), stretch]))

        var image = LayerNode(kind: .image)
        image.width = LayerNode.Sizing(.fill(weight: 1))
        image.height = LayerNode.Sizing(.fit)
        var title = LayerNode(kind: .title)
        title.content.text = "Totals"
        let cells = fitting(grid(columns: 2, columnSpacing: 12, rowSpacing: 12, size: .zero,
                                 children: [shape(60, 60), image, fitting(LayerNode(kind: .symbol)), fitting(title)]))

        var root = stack(.vertical, spacing: 16, size: CGSize(width: 393, height: 852), children: [row, cells])
        root.padding = LayerNode.Padding(all: 20)
        let (laid, diagnostics) = laidOut(root)
        #expect(diagnostics.isEmpty)
        #expect(laid.children.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        #expect(laid.children.flatMap(\.children).allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })

        func expectNoOverlap(in node: LayerNode) {
            for (i, a) in node.children.enumerated() {
                for b in node.children[(i + 1)...] {
                    #expect(!a.frame.intersects(b.frame), "\(a.kind) \(a.frame) overlaps \(b.kind) \(b.frame)")
                }
                expectNoOverlap(in: a)
            }
        }
        expectNoOverlap(in: laid)
    }

    @Test func textInAColumnWrapsToTheColumnWidth() {
        var body = LayerNode(kind: .body)
        body.content.text = String(repeating: "A body of text that wraps across the column. ", count: 6)
        body.width = LayerNode.Sizing(.fill(weight: 1))
        body.height = LayerNode.Sizing(.fit)
        let column = stack(.vertical, size: CGSize(width: 300, height: 800), children: [body])

        let frame = laidOut(column).node.children[0].frame
        let wrapped = TextMeasure.shared.size(of: body.content.text, fontSize: 15, weight: .regular, width: 300)
        let oneLine = TextMeasure.shared.size(of: "A", fontSize: 15, weight: .regular, width: nil)
        #expect(frame.width == 300)
        #expect(frame.height == wrapped.height)
        #expect(frame.height > 2 * oneLine.height)
    }

    // MARK: - Reports and awkward input

    @Test func overflowIsReportedNotCorrected() {
        let row = stack(.horizontal, size: CGSize(width: 100, height: 40), children: [shape(80, 40), shape(80, 40)])
        let (laid, diagnostics) = laidOut(row)
        #expect(diagnostics == [LayoutDiagnostic(node: row.id, kind: .overflow)])
        #expect(laid.children.map(\.frame.width) == [80, 80])
        #expect(laid.children.map(\.frame.minX) == [0, 80])
    }

    @Test func anUnbreakableWordIsReportedTooWide() {
        var word = LayerNode(kind: .body)
        word.content.text = String(repeating: "x", count: 400)
        word.width = LayerNode.Sizing(.fill(weight: 1))
        word.height = LayerNode.Sizing(.fit)
        var wrapping = word
        wrapping.id = UUID()
        wrapping.content.text = "Short words that wrap across several lines in a narrow column."
        let column = stack(.vertical, spacing: 8, size: CGSize(width: 120, height: 2000), children: [word, wrapping])

        let (laid, diagnostics) = laidOut(column)
        #expect(diagnostics == [LayoutDiagnostic(node: word.id, kind: .textTooWide)])
        #expect(laid.children[0].frame.width == 120)
        #expect(laid.children[1].frame.width == 120)

        // A sticky note's words wrap inside its 12-point inset.
        var note = LayerNode(kind: .stickyNote)
        note.frame = CGRect(x: 0, y: 0, width: 150, height: 150)
        note.content.text = String(repeating: "x", count: 40)
        var shortNote = note
        shortNote.id = UUID()
        shortNote.content.text = "A short note"
        let notes = stack(.vertical, spacing: 8, size: CGSize(width: 150, height: 400), children: [note, shortNote])
        #expect(laidOut(notes).diagnostics == [LayoutDiagnostic(node: note.id, kind: .textTooWide)])
    }

    @Test func hiddenChildrenTakeNoSpace() {
        var hidden = shape(50, 30)
        hidden.frame.origin = CGPoint(x: 7, y: 9)
        hidden.isHidden = true
        let column = stack(.vertical, spacing: 10, size: CGSize(width: 200, height: 200),
                           children: [shape(50, 40), hidden, shape(50, 20)])
        let laid = laidOut(column).node
        #expect(laid.children[2].frame.minY == laid.children[0].frame.maxY + 10)
        #expect(laid.children[1].frame == hidden.frame)
    }

    @Test func anEmptyContainerFitsItsPadding() {
        var hidden = shape(50, 50)
        hidden.isHidden = true
        let containers = [
            stack(.vertical, spacing: 12, size: .zero, children: []),
            stack(.horizontal, spacing: 12, size: .zero, children: []),
            grid(columns: 3, columnSpacing: 10, rowSpacing: 10, size: .zero, children: []),
            overlay(.center, .center, size: .zero, children: []),
            stack(.vertical, spacing: 12, size: .zero, children: [hidden, hidden]),
        ]
        for container in containers {
            var container = fitting(container)
            container.padding = LayerNode.Padding(all: 16)
            for proposal in [ProposedSize(width: nil, height: nil), ProposedSize(width: 393, height: 852)] {
                #expect(LayoutEngine.size(of: container, proposal: proposal, measure: measure) == CGSize(width: 32, height: 32))
            }
        }
    }

    @Test func badNumbersNeverMakeABadFrame() {
        var picky = shape(100, 40)
        picky.width = LayerNode.Sizing(.fit, minimum: .infinity)
        picky.height = LayerNode.Sizing(.fit, minimum: .nan, maximum: -3)
        let broken = shape(.nan, -10)
        let one = grid(columns: 0, size: CGSize(width: 100, height: 30), children: Array(repeating: shape(10, 10), count: 3))
        let twelve = grid(columns: 50, size: CGSize(width: 393, height: 20), children: Array(repeating: shape(10, 10), count: 13))
        var weightless = shape(10, 0)
        weightless.height = LayerNode.Sizing(.fill(weight: .nan), minimum: -.infinity, maximum: .nan)

        var root = stack(.vertical, spacing: .nan, size: CGSize(width: 393, height: 852),
                         children: [shape(100, 40), picky, broken, one, twelve, weightless])
        root.padding = LayerNode.Padding(all: -5)
        let laid = laidOut(root).node

        #expect(frames(in: laid).allSatisfy {
            [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height].allSatisfy(\.isFinite)
        })
        let size = LayoutEngine.size(of: picky, proposal: ProposedSize(width: .nan, height: .infinity), measure: measure)
        #expect(size.width.isFinite && size.height.isFinite)

        // Spacing and padding act as 0; bad minimums and maximums as none (a shape is 100 x 100 by nature).
        #expect(laid.children[0].frame == CGRect(x: 0, y: 0, width: 100, height: 40))
        #expect(laid.children[1].frame == CGRect(x: 0, y: 40, width: 100, height: 100))
        #expect(laid.children[2].frame == CGRect(x: 0, y: 140, width: 0, height: 0))
        #expect(laid.children[3].frame.minY == 140)

        // Columns act as 1 and 12.
        #expect(laid.children[3].children.map(\.frame.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 0, y: 20)])
        let dozen = laid.children[4].children
        #expect(dozen[..<12].allSatisfy { $0.frame.minY == 0 })
        #expect(Set(dozen[..<12].map(\.frame.minX)).count == 12)
        #expect(dozen[12].frame.origin == CGPoint(x: 0, y: 10))
    }
}
