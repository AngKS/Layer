import CoreGraphics
import Foundation
import Testing
@testable import Layer

private func leaf(_ frame: CGRect, text: String = "Text") -> LayerNode {
    var node = LayerNode(kind: .text)
    node.frame = frame
    node.content.text = text
    return node
}

private func container(_ layout: LayerNode.Layout?, _ frame: CGRect, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: .group)
    node.layout = layout
    node.frame = frame
    node.children = children
    return node
}

private func rowLayout(spacing: CGFloat = 20) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .horizontal, spacing: spacing))
}

private func columnLayout(spacing: CGFloat = 10) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .vertical, spacing: spacing))
}

/// One iPhone screen at the canvas's origin, drawn at its own size, so that its points are the canvas's.
private func design(_ children: [LayerNode], root layout: LayerNode.Layout? = nil, canvas: [LayerNode] = []) -> TreeContent {
    var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
    screen.root.layout = layout
    screen.root.children = children
    var content = TreeContent()
    content.screens = [screen]
    content.canvas = canvas
    return content
}

/// The row of the brief: at (20, 100) on a free iPhone root at the canvas's origin, holding a, b and c, each 80 × 40,
/// at x 0, 100 and 200.
private struct RowDesign {
    let a = leaf(CGRect(x: 0, y: 0, width: 80, height: 40), text: "A")
    let b = leaf(CGRect(x: 100, y: 0, width: 80, height: 40), text: "B")
    let c = leaf(CGRect(x: 200, y: 0, width: 80, height: 40), text: "C")
    let row: LayerNode
    let content: TreeContent

    var screenID: TreeScreen.ID { content.screens[0].id }
    var index: TreeIndex { TreeIndex(content) }

    init(lockingRow: Bool = false, hidingRow: Bool = false) {
        var row = container(rowLayout(), CGRect(x: 20, y: 100, width: 280, height: 40), [a, b, c])
        row.isLocked = lockingRow
        row.isHidden = hidingRow
        self.row = row
        content = design([row])
    }

    func target(for id: UUID, at point: CGPoint) -> TreeDrop.Target {
        TreeDrop.target(for: id, at: point, centre: point, in: content, index: index)
    }
}

/// The parent a target puts the thing in, or nil for one placed freely.
private func parent(of target: TreeDrop.Target) -> NodeParent? {
    if case .insert(let parent, _, _) = target { parent } else { nil }
}

/// Where one dragged thing would go: the deepest row, column or grid under the finger at its slot, or free (plan 4,
/// Task 4).
@Suite("Where a drop goes")
struct TreeDropTests {
    @Test func aRowsSlotIsByMidX() throws {
        let board = RowDesign()
        let layout = try #require(board.row.layout)

        let slot = TreeDrop.slot(for: CGPoint(x: 150, y: 20), among: board.row.children, skipping: board.a.id, layout: layout)

        #expect(slot == 1)
        var order = board.row.children.filter { $0.id != board.a.id }
        order.insert(board.a, at: slot)
        #expect(order.map(\.id) == [board.b.id, board.a.id, board.c.id])
    }

    @Test func aColumnsSlotIsByMidY() {
        let cells = (0..<3).map { leaf(CGRect(x: 0, y: CGFloat($0) * 40, width: 100, height: 30)) }

        let slot = TreeDrop.slot(for: CGPoint(x: 50, y: 65), among: cells, skipping: cells[0].id, layout: columnLayout())

        #expect(slot == 1)
    }

    @Test func aGridsSlotIsByRowThenX() {
        let origins = [CGPoint(x: 0, y: 0), CGPoint(x: 110, y: 0), CGPoint(x: 0, y: 38), CGPoint(x: 110, y: 38)]
        let cells = origins.map { leaf(CGRect(origin: $0, size: CGSize(width: 100, height: 30))) }
        let grid = LayerNode.Layout.grid(LayerNode.Grid(columns: 2, columnSpacing: 10, rowSpacing: 8))

        let slot = TreeDrop.slot(for: CGPoint(x: 40, y: 50), among: cells, skipping: cells[3].id, layout: grid)

        #expect(slot == 2)
    }

    @Test func theLineLiesInTheGap() {
        let board = RowDesign()

        // a, over the row at its own x 150: between b and c, whose gap runs from 180 to 200 in the row's points.
        let target = board.target(for: board.a.id, at: CGPoint(x: 170, y: 120))

        #expect(target == .insert(into: .node(board.row.id), at: 1,
                                  line: TurnedRect(rect: CGRect(x: 209, y: 100, width: 2, height: 40), degrees: 0)))
    }

    @Test func theDeepestRowUnderThePointTakesIt() {
        let title = leaf(CGRect(x: 20, y: 60, width: 200, height: 40), text: "Title")
        let inRow = [leaf(CGRect(x: 0, y: 0, width: 80, height: 40)), leaf(CGRect(x: 100, y: 0, width: 80, height: 40))]
        let line = container(rowLayout(), CGRect(x: 20, y: 110, width: 180, height: 40), inRow)
        let text = leaf(CGRect(x: 20, y: 160, width: 100, height: 20), text: "Mine")
        let content = design([title, line, text], root: columnLayout())
        let screenID = content.screens[0].id
        let index = TreeIndex(content)

        let overTheRow = TreeDrop.target(for: text.id, at: CGPoint(x: 150, y: 130), centre: CGPoint(x: 150, y: 130),
                                         in: content, index: index)
        let elsewhere = TreeDrop.target(for: text.id, at: CGPoint(x: 200, y: 500), centre: CGPoint(x: 200, y: 500),
                                        in: content, index: index)

        #expect(parent(of: overTheRow) == .node(line.id))
        if case .insert(_, let slot, _) = overTheRow { #expect(slot == 1) }
        #expect(parent(of: elsewhere) == .screen(screenID))
        if case .insert(_, let slot, _) = elsewhere { #expect(slot == 2, "after the title and the row, at the end") }
    }

    @Test func aThingNeverGoesIntoItself() {
        let title = leaf(CGRect(x: 20, y: 60, width: 200, height: 40), text: "Title")
        let inner = container(rowLayout(), CGRect(x: 0, y: 0, width: 80, height: 40), [leaf(CGRect(x: 0, y: 0, width: 80, height: 40))])
        let line = container(rowLayout(), CGRect(x: 20, y: 110, width: 180, height: 40),
                             [inner, leaf(CGRect(x: 100, y: 0, width: 80, height: 40))])
        let content = design([title, line], root: columnLayout())
        let screenID = content.screens[0].id

        // Over the row's own child, which is a row too.
        let target = TreeDrop.target(for: line.id, at: CGPoint(x: 40, y: 130), centre: CGPoint(x: 110, y: 130),
                                     in: content, index: TreeIndex(content))

        #expect(parent(of: target) == .screen(screenID))
    }

    @Test func lockedAndHiddenContainersTakeNothing() {
        let point = CGPoint(x: 170, y: 120)
        for board in [RowDesign(lockingRow: true), RowDesign(hidingRow: true)] {
            let d = leaf(CGRect(x: 20, y: 400, width: 80, height: 40))
            var content = board.content
            content.screens[0].root.children.append(d)
            let target = TreeDrop.target(for: d.id, at: point, centre: point, in: content, index: TreeIndex(content))
            #expect(target == .free(on: .screen(board.screenID)))
        }

        // Locked by a free group round it.
        let board = RowDesign()
        var holder = container(nil, CGRect(x: 0, y: 0, width: 393, height: 300), [board.row])
        holder.isLocked = true
        let d = leaf(CGRect(x: 20, y: 400, width: 80, height: 40))
        let content = design([holder, d])
        let target = TreeDrop.target(for: d.id, at: point, centre: point, in: content, index: TreeIndex(content))
        #expect(target == .free(on: .screen(content.screens[0].id)))
    }

    @Test func offEveryLaidOutContainerItIsFree() {
        let board = RowDesign()

        let onTheRoot = board.target(for: board.a.id, at: CGPoint(x: 200, y: 400))
        let offEveryScreen = board.target(for: board.a.id, at: CGPoint(x: 900, y: 900))

        #expect(onTheRoot == .free(on: .screen(board.screenID)))
        #expect(offEveryScreen == .free(on: .canvas))
    }

    /// F14: an empty row, column or grid is a drop target, at slot 0.
    @Test func anEmptyRowTakesADropAtSlotZero() {
        let empty = container(rowLayout(), CGRect(x: 20, y: 300, width: 120, height: 40), [])
        let text = leaf(CGRect(x: 20, y: 500, width: 100, height: 20))
        let content = design([empty, text])

        let target = TreeDrop.target(for: text.id, at: CGPoint(x: 60, y: 320), centre: CGPoint(x: 60, y: 320),
                                     in: content, index: TreeIndex(content))

        #expect(parent(of: target) == .node(empty.id))
        if case .insert(_, let slot, let line) = target {
            #expect(slot == 0)
            #expect(line == TurnedRect(rect: CGRect(x: 19, y: 300, width: 2, height: 40), degrees: 0))
        }
    }

    /// F15: a row the store would refuse the move into, here one at depth 32, shows no line: the next candidate, the
    /// column round it, takes the thing instead.
    @Test func aContainerTheMoveWouldBeRefusedIntoShowsNoLine() throws {
        let deepRow = container(rowLayout(), CGRect(x: 0, y: 0, width: 200, height: 40), [leaf(CGRect(x: 0, y: 0, width: 80, height: 40))])
        var chain = deepRow
        var columns: [UUID] = []
        for _ in 1..<TreeRules.maximumDepth {
            chain = container(columnLayout(), CGRect(x: 0, y: 0, width: 300, height: 300), [chain])
            columns.append(chain.id)
        }
        let text = leaf(CGRect(x: 20, y: 600, width: 100, height: 20))
        let content = design([chain, text])
        let index = TreeIndex(content)
        try #require(index[deepRow.id]?.depth == TreeRules.maximumDepth)
        let innermost = try #require(columns.first)

        let target = TreeDrop.target(for: text.id, at: CGPoint(x: 50, y: 20), centre: CGPoint(x: 50, y: 20),
                                     in: content, index: index)

        #expect(parent(of: target) != .node(deepRow.id))
        #expect(parent(of: target) == .node(innermost))
    }

    /// A thing let go off every container, its centre over a column screen, takes that column's slot at its centre,
    /// not the end (fix round 1, M3).
    @Test func aThingLetGoWithItsCentreOverAColumnScreenTakesTheSlotThere() throws {
        let cells = (0..<3).map { leaf(CGRect(x: 20, y: 100 + CGFloat($0) * 60, width: 200, height: 40), text: "\($0)") }
        var content = design(cells, root: columnLayout())
        let loose = leaf(CGRect(x: 600, y: 100, width: 80, height: 40))
        content.canvas = [loose]
        let screenID = content.screens[0].id

        // The finger past the screen's right edge (393 wide); the thing's centre on it, between the first two.
        let target = TreeDrop.target(for: loose.id, at: CGPoint(x: 420, y: 170), centre: CGPoint(x: 360, y: 170),
                                     in: content, index: TreeIndex(content))

        guard case .insert(let parent, let slot, _) = target else {
            Issue.record("the column should take it: \(target)")
            return
        }
        #expect(parent == .screen(screenID))
        #expect(slot == 1)
    }

    /// F23: a thing in an overlay, over that overlay, goes back to its own place there, and shows no line.
    @Test func anOverlaysOwnChildGoesBackToItsPlace() {
        let back = leaf(CGRect(x: 0, y: 0, width: 200, height: 100))
        let front = leaf(CGRect(x: 50, y: 30, width: 100, height: 40))
        let overlay = container(.overlay(LayerNode.Alignment()), CGRect(x: 20, y: 100, width: 200, height: 100), [back, front])
        let content = design([overlay])

        let target = TreeDrop.target(for: front.id, at: CGPoint(x: 140, y: 160), centre: CGPoint(x: 150, y: 160),
                                     in: content, index: TreeIndex(content))

        #expect(target == .insert(into: .node(overlay.id), at: 1, line: TreeDrop.noLine))
    }
}
