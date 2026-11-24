import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// An app showing `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeModel(_ tree: TreeContent) -> (model: AppModel, undo: UndoManager) {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    model.adjustmentPause = .seconds(60)
    return (model, undo)
}

private func text(_ x: CGFloat, _ y: CGFloat, width: CGFloat = 60, height: CGFloat = 24) -> LayerNode {
    var node = LayerNode(kind: .text)
    node.frame = CGRect(x: x, y: y, width: width, height: height)
    node.content.text = "Text"
    return node
}

private func container(_ kind: ElementKind = .group, _ layout: LayerNode.Layout? = nil, frame: CGRect,
                       _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.layout = layout
    node.frame = frame
    node.children = children
    return node
}

private func screen(_ children: [LayerNode]) -> TreeScreen {
    var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
    screen.root.children = children
    return screen
}

private func design(_ screens: [TreeScreen]) -> TreeContent {
    var content = TreeContent()
    content.screens = screens
    return content
}

private let rhythm = DesignTokens.standard.rhythm

/// The Format panel's layout, sizing and card controls (plan 4, Task 7), as the store and the model carry them out.
@Suite("Format panel on the tree")
@MainActor
struct FormatPanelLayoutTests {
    @Test func aFreeCardBecomesARowSortedAndFixed() throws {
        let right = text(200, 10), left = text(20, 10), middle = text(110, 10)
        let card = container(.card, frame: CGRect(x: 0, y: 100, width: 300, height: 60), [right, left, middle])
        let (model, _) = makeModel(design([screen([card])]))
        let store = model.store
        let held = try #require(store.node(card.id))

        store.setLayout(card.id, LayoutChoice.row.layout(from: held.resolvedLayout, children: held.children, rhythm: rhythm))

        let row = try #require(store.node(card.id))
        guard case .stack(let stack) = row.resolvedLayout else { Issue.record("not a stack"); return }
        #expect(stack.axis == .horizontal)
        #expect(row.children.map(\.id) == [left.id, middle.id, right.id])
        for child in row.children {
            #expect(child.width.mode == .fixed && child.height.mode == .fixed)
            #expect(child.frame.size == CGSize(width: 60, height: 24))
        }
    }

    @Test func rowToColumnKeepsSpacingAndAlignment() throws {
        let stack = LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .center, justify: .spaceBetween)
        let row = container(.group, .stack(stack), frame: CGRect(x: 0, y: 100, width: 200, height: 24), [text(0, 0), text(0, 0)])
        let (model, _) = makeModel(design([screen([row])]))
        let held = try #require(model.store.node(row.id))

        let made = LayoutChoice.column.layout(from: held.resolvedLayout, children: held.children, rhythm: rhythm)

        #expect(made == .stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .center, justify: .spaceBetween)))
        #expect(LayoutChoice(made) == .column)
        // A grid keeps its columns, and an overlay is centred.
        let grid = LayerNode.Layout.grid(LayerNode.Grid(columns: 3, columnSpacing: 4, rowSpacing: 5))
        #expect(LayoutChoice.grid.layout(from: grid, children: [], rhythm: rhythm) == grid)
        #expect(LayoutChoice.overlay.layout(from: made, children: [], rhythm: rhythm) == .overlay(LayerNode.Alignment()))
        #expect(LayoutChoice.free.layout(from: made, children: [], rhythm: rhythm) == .free)
    }

    @Test func aRunOfLayoutChangesIsOneFormatStep() throws {
        let grid = LayerNode.Grid(columns: 2, columnSpacing: 4, rowSpacing: 4)
        let held = container(.card, .grid(grid), frame: CGRect(x: 0, y: 100, width: 200, height: 100), [text(0, 0), text(0, 0)])
        let (model, undo) = makeModel(design([screen([held])]))
        let store = model.store

        model.adjusting {
            store.updateLayout(held.id) { layout in
                if case .grid(var grid) = layout { grid.columnSpacing = 16; layout = .grid(grid) }
            }
            store.setPadding(held.id, LayerNode.Padding(all: 24))
            store.updateLayout(held.id) { layout in
                if case .grid(var grid) = layout { grid.columns = 3; layout = .grid(grid) }
            }
        }

        let node = try #require(store.node(held.id))
        #expect(node.padding == LayerNode.Padding(all: 24))
        #expect(node.resolvedLayout == .grid(LayerNode.Grid(columns: 3, columnSpacing: 16, rowSpacing: 4)))
        #expect(undo.undoActionName == "Format")
        undo.undo()
        #expect(store.node(held.id)?.resolvedLayout == .grid(grid))
        #expect(store.node(held.id)?.padding == LayerNode.Padding())
        #expect(!undo.canUndo)
    }

    @Test func badLayoutNumbersAreClamped() throws {
        let stack = LayerNode.Stack(axis: .vertical, spacing: 8)
        let column = container(.group, .stack(stack), frame: CGRect(x: 0, y: 100, width: 60, height: 56), [text(0, 0), text(0, 0)])
        let grid = container(.group, .grid(LayerNode.Grid(columns: 2)), frame: CGRect(x: 0, y: 300, width: 60, height: 56), [text(0, 0)])
        let (model, _) = makeModel(design([screen([column, grid])]))
        let store = model.store

        store.updateLayout(column.id) { if case .stack(var s) = $0 { s.spacing = -5; $0 = .stack(s) } }
        #expect(store.node(column.id)?.resolvedLayout == .stack(LayerNode.Stack(axis: .vertical, spacing: 0)))
        store.updateLayout(column.id) { if case .stack(var s) = $0 { s.spacing = 12; $0 = .stack(s) } }
        store.updateLayout(column.id) { if case .stack(var s) = $0 { s.spacing = .nan; $0 = .stack(s) } }
        #expect(store.node(column.id)?.resolvedLayout == .stack(LayerNode.Stack(axis: .vertical, spacing: 0)))

        store.setPadding(column.id, LayerNode.Padding(top: -1, leading: .nan, bottom: 6, trailing: .infinity))
        #expect(store.node(column.id)?.padding == LayerNode.Padding(top: 0, leading: 0, bottom: 6, trailing: 0))

        store.updateLayout(grid.id) { if case .grid(var g) = $0 { g.columns = 40; $0 = .grid(g) } }
        guard case .grid(let wide) = store.node(grid.id)?.resolvedLayout else { Issue.record("not a grid"); return }
        #expect(wide.columns == 12)
        store.updateLayout(grid.id) { if case .grid(var g) = $0 { g.columns = 0; $0 = .grid(g) } }
        guard case .grid(let narrow) = store.node(grid.id)?.resolvedLayout else { Issue.record("not a grid"); return }
        #expect(narrow.columns == 1)

        // A free container stays free.
        let free = container(.group, frame: CGRect(x: 0, y: 500, width: 60, height: 24), [text(0, 0), text(0, 30)])
        let (other, _) = makeModel(design([screen([free])]))
        other.store.updateLayout(free.id) { $0 = .overlay(LayerNode.Alignment()) }
        #expect(other.store.node(free.id)?.resolvedLayout == .free)
    }

    @Test func aRowChildsSizingIsSetPerAxis() throws {
        let child = text(0, 0), beside = text(0, 0)
        let row = container(.group, .stack(LayerNode.Stack(axis: .horizontal, spacing: 8)),
                            frame: CGRect(x: 20, y: 100, width: 300, height: 24), [child, beside])
        let (model, _) = makeModel(design([screen([row])]))
        let store = model.store

        store.setSizing(child.id, axis: .horizontal, .fixed, points: 120)
        #expect(store.node(child.id)?.width.mode == .fixed)
        #expect(store.placed(child.id)?.frame.width == 120)
        #expect(store.node(child.id)?.frame.width == 120)

        store.setSizing(child.id, axis: .horizontal, .fill)
        #expect(store.node(child.id)?.width.mode == .fill(weight: 1))
        store.setSizing(child.id, axis: .vertical, .fit)
        #expect(store.node(child.id)?.height.mode == .fit)
        #expect(store.node(child.id)?.width.mode == .fill(weight: 1))
        store.setSizing(child.id, axis: .horizontal, .fit)
        #expect(store.node(child.id)?.width.mode == .fit)
        #expect(SizingChoice(LayerNode.Sizing(.fill(weight: 2))) == .fill)

        // Fixed with no points is its size now.
        let size = try #require(store.placed(beside.id)).frame.size
        store.setSizing(beside.id, axis: .vertical, .fixed)
        #expect(store.node(beside.id)?.height.mode == .fixed)
        #expect(store.placed(beside.id)?.frame.height == size.height)
    }

    @Test func xAndYAreOffForALaidOutChild() throws {
        let inColumn = text(0, 0), inOverlay = text(0, 0), loose = text(20, 300)
        let column = container(.group, .stack(LayerNode.Stack(axis: .vertical)), frame: CGRect(x: 20, y: 100, width: 60, height: 24), [inColumn])
        let overlay = container(.group, .overlay(LayerNode.Alignment()), frame: CGRect(x: 20, y: 200, width: 60, height: 24), [inOverlay])
        let (model, _) = makeModel(design([screen([column, overlay, loose])]))
        let store = model.store

        #expect(!SizingSection.isPositionEditable(for: try #require(store.placed(inColumn.id))))
        #expect(!SizingSection.isPositionEditable(for: try #require(store.placed(inOverlay.id))))
        #expect(SizingSection.isPositionEditable(for: try #require(store.placed(loose.id))))
    }

    @Test func aScreenOffersFreeAndColumn() {
        #expect(LayoutChoice.choices(forScreenRoot: true) == [.free, .column])
        #expect(LayoutChoice.choices(forScreenRoot: false) == [.free, .row, .column, .grid, .overlay])
    }

    @Test func aCardsFillIsItsOwnUntilReset() throws {
        let card = container(.card, frame: CGRect(x: 20, y: 100, width: 100, height: 60), [text(0, 0)])
        let (model, _) = makeModel(design([screen([card])]))
        let store = model.store
        let tokens = store.tree.settings.tokens
        #expect(store.node(card.id)?.shownFill(tokens: tokens) == tokens.card.fill)

        let red = RGBColor(hex: 0xFF0000)
        model.changeNodes([card.id], where: { $0.kind == .card }) { $0.style.tint = red }
        #expect(store.node(card.id)?.style.tint == red)
        #expect(store.node(card.id)?.shownFill(tokens: tokens) == red)

        model.changeNodes([card.id], where: { $0.kind == .card }) { $0.style.tint = nil }
        #expect(store.node(card.id)?.style.tint == nil)
        #expect(store.node(card.id)?.shownFill(tokens: tokens) == tokens.card.fill)
    }

    @Test func theAlignRowEditsAColumnsAlignment() throws {
        let narrow = text(0, 0, width: 60), wide = text(0, 0, width: 100), loose = text(20, 300)
        let column = container(.group, .stack(LayerNode.Stack(axis: .vertical, spacing: 8)),
                               frame: CGRect(x: 20, y: 100, width: 100, height: 56), [narrow, wide])
        let (model, undo) = makeModel(design([screen([column, loose])]))
        let store = model.store

        // One child of a column: the row sets the column's alignment, and nothing is pulled out of it.
        model.selection = store.ref(of: narrow.id).map(CanvasSelection.element)
        model.lineUpSelection(.centerX)
        #expect(store.node(column.id)?.resolvedLayout == .stack(LayerNode.Stack(axis: .vertical, spacing: 8, alignment: .center)))
        #expect(store.parent(of: narrow.id) == .node(column.id))
        undo.undo()

        // A mixed selection moves what is in a free parent, and leaves a laid-out child where it is.
        let place = try #require(store.placed(narrow.id)).frame
        model.selection = CanvasSelection([narrow.id, loose.id].compactMap(store.ref(of:)).map(CanvasSelection.element))
        #expect(model.canLineUpSelection(.left))
        model.lineUpSelection(.left)
        #expect(store.parent(of: narrow.id) == .node(column.id))
        #expect(store.placed(narrow.id)?.frame == place)
        #expect(store.placed(loose.id)?.frame.minX == place.minX)
    }

    @Test func aScreensFieldsAreWrittenOnTheTree() throws {
        let (model, undo) = makeModel(design([screen([text(20, 100)])]))
        let store = model.store
        let id = try #require(store.tree.screens.first?.id)
        _ = store.screens
        let before = TreeProjection.lowerings
        let step = undo.canUndo

        model.adjusting {
            store.updateTreeScreen(id) { $0.name = "Home" }
            store.updateTreeScreen(id) { $0.scale = 0.5 }
        }

        #expect(TreeProjection.lowerings - before == 0)
        #expect(store.treeScreen(id)?.name == "Home")
        #expect(store.treeScreen(id)?.scale == 0.5)
        #expect(undo.canUndo && !step)
        undo.undo()
        #expect(store.treeScreen(id)?.name == "Screen")
        #expect(store.treeScreen(id)?.scale == 1)
        #expect(!undo.canUndo)
    }
}
