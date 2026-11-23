import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The spec's budgets for a change on the tree (§13), held on every run: one change through the
/// store on a screen of 100 nodes takes under 16 ms at the 95th percentile, and a frame of a drag
/// lays out only the containers on the path from what it moves to its screen's root.
@MainActor
@Suite("A store change's budget")
struct StoreChangeBudgetTests {
    private static let runs = 50

    // MARK: Building screens

    /// A node as generation makes one: its words, and its kind's starting sizing.
    private static func generated(_ kind: ElementKind, _ words: String = "") -> LayerNode {
        var node = LayerNode(kind: kind)
        node.content.text = words
        (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
        return node
    }

    /// A node of a fixed size.
    private static func fixed(_ kind: ElementKind, _ frame: CGRect) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        return node
    }

    /// A container that lays its children out, sized to fit.
    private static func laidOut(_ layout: LayerNode.Layout, at origin: CGPoint = .zero, _ children: [LayerNode]) -> LayerNode {
        var node = LayerNode(kind: .group)
        node.layout = layout
        node.frame = CGRect(origin: origin, size: .zero)
        node.width = LayerNode.Sizing(.fit)
        node.height = LayerNode.Sizing(.fit)
        node.children = children
        return node
    }

    private static let column = LayerNode.Layout.stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .fill))
    private static let row = LayerNode.Layout.stack(LayerNode.Stack(axis: .horizontal, spacing: 8, alignment: .center))

    private static func containers(in node: LayerNode) -> [UUID] {
        guard node.isContainer else { return [] }
        return [node.id] + node.children.flatMap(containers)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
    }

    /// The p50 and p95 of `runs` timed runs of `operation`, in milliseconds, printed as a BENCH line.
    /// `tidy` runs after each, untimed.
    private func measure(_ name: String, _ operation: (Int) -> Void, tidy: (Int) -> Void = { _ in }) -> (p50: Double, p95: Double) {
        var times: [Double] = []
        for run in 0..<Self.runs {
            let start = ContinuousClock.now
            operation(run)
            times.append(Self.milliseconds(ContinuousClock.now - start))
            tidy(run)
        }
        let sorted = times.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
        print(String(format: "BENCH tree %@ p50=%.3f p95=%.3f", name, p50, p95))
        return (p50, p95)
    }

    // MARK: Budgets

    /// An iPhone screen whose root is a column of 25 rows, each a row of a text, a body, a toggle
    /// and a divider: 100 things in all. A leaf moved in a row there is laid back by it (My call 20,
    /// a column root's exception), so the move times the whole change and its laying back.
    @Test func aStoreChangeOnAHundredNodeScreenIsWithinBudget() throws {
        let model = AppModel(document: LayerDocument())
        let store = model.store
        var screen = TreeScreen(name: "Settings", origin: CGPoint(x: 100, y: 50), scale: 1, deviceID: nil)
        screen.root.layout = Self.column
        screen.root.children = (0..<25).map { index in
            var item = Self.laidOut(Self.row, [Self.generated(.text, "Label \(index)"), Self.generated(.body, "What setting \(index) does"),
                                               Self.generated(.toggle), Self.generated(.divider)])
            item.width = LayerNode.Sizing(.fill(weight: 1))
            return item
        }
        let screenID = store.addScreen(screen)
        let root = try #require(store.tree.screens.first { $0.id == screenID }?.root)
        try #require(root.children.count == 25)
        #expect(root.children.reduce(0) { $0 + $1.children.count } == 100)

        // What the runs change: row 12's text (moved and edited) and its body (resized), and what
        // is added to row 12 and taken away again after each run.
        let row = root.children[12]
        let text = DesignStore.ElementRef(host: .screen(screenID), element: row.children[0].id)
        let body = DesignStore.ElementRef(host: .screen(screenID), element: row.children[1].id)

        let laidOut = try #require(store.node(text.element)).frame
        let move = measure("move") { _ in store.update(text) { $0.frame.origin.x += 1 } }
        #expect(store.node(text.element)?.frame == laidOut, "laid back by its row")
        let resize = measure("resize") { _ in store.update(body) { $0.frame.size.width += 1 } }
        let edit = measure("text") { _ in store.update(text) { $0.text += "a" } }
        var added: UUID?
        let add = measure("add") { run in
            let node = Self.generated(.text, "Added \(run)")
            added = store.add(node, to: .node(row.id), at: nil) ? node.id : nil
        } tidy: { _ in
            if let added { store.delete(nodes: [added]) }
        }

        let bodyWidth = try #require(store.node(row.children[1].id)).frame.width
        #expect(bodyWidth > row.children[1].frame.width, "the body was resized")
        #expect(store.node(row.children[0].id)?.content.text.hasSuffix("a") == true, "the text was edited")
        #expect(added != nil, "a text was added to the row")
        #expect(store.node(row.id)?.children.count == 4, "and taken away again")
        for (name, result) in [("move", move), ("resize", resize), ("text", edit), ("add", add)] {
            #expect(result.p95 < 16, "\(name): p95 \(result.p95) ms")
        }
    }

    /// A leaf dragged on a screen whose root is free, among a row, a free group and a card that lays
    /// out a row of its own: each of the 60 frames lays out at most the screen's root, which holds the
    /// leaf, and none of the other containers (F8: each container's own count).
    @Test func aLeafDragLaysOutOnlyItsDirtyPath() throws {
        let model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.tool = .select
        model.store.updateCanvas { $0.snapsToGuides = false }

        let dragged = Self.fixed(.text, CGRect(x: 20, y: 60, width: 200, height: 20))
        let listRow = Self.laidOut(Self.row, at: CGPoint(x: 20, y: 120), [Self.generated(.text, "Wi-Fi"), Self.generated(.toggle)])
        var group = Self.fixed(.group, CGRect(x: 20, y: 220, width: 10, height: 10))
        group.layout = .free
        group.width = LayerNode.Sizing(.fit)
        group.height = LayerNode.Sizing(.fit)
        group.children = [Self.fixed(.shape, CGRect(x: 0, y: 0, width: 60, height: 40)), Self.fixed(.shape, CGRect(x: 80, y: 20, width: 40, height: 40))]
        var card = Self.generated(.card)
        card.frame = CGRect(x: 20, y: 320, width: 300, height: 10)
        card.layout = Self.column
        card.padding = LayerNode.Padding(all: 16)
        card.children = [Self.generated(.body, "Inside a card"), Self.laidOut(Self.row, [Self.generated(.text, "A"), Self.generated(.button, "B")])]
        var screen = TreeScreen(name: "Free", origin: CGPoint(x: 100, y: 50), scale: 0.5, deviceID: nil)
        screen.root.children = [dragged, listRow, group, card]
        let screenID = model.store.addScreen(screen)
        let root = try #require(model.store.tree.screens.first { $0.id == screenID }?.root)
        #expect(root.resolvedLayout == .free)
        let others = Self.containers(in: root).filter { $0 != root.id }
        #expect(others.count == 4, "the row, the group, the card and its row")

        let ref = DesignStore.ElementRef(host: .screen(screenID), element: dragged.id)
        let drags = CanvasDrags()
        model.drags = drags
        let owner = CanvasDrags.Owner()
        let rootBefore = LayoutEngine.timesLaidOut(root.id), othersBefore = others.map(LayoutEngine.timesLaidOut)
        for frame in 1...60 {
            let (element, placement) = try #require(model.store.resolve(ref))
            drags.moveElement(ref, from: element.frame, placement: placement, by: CGSize(width: CGFloat(frame), height: 0),
                              startingAt: CGPoint(x: 150, y: 150), owner: owner, model: model) {
                drags.moveRule(for: element, placement: placement, on: model.store.screen(screenID), model: model)
            }
            // Read back after each frame, as drawing the screen does.
            _ = model.store.screens
        }
        let rootLaid = LayoutEngine.timesLaidOut(root.id) - rootBefore
        let othersLaid = zip(others.map(LayoutEngine.timesLaidOut), othersBefore).map(-)
        let moved = try #require(model.store.node(dragged.id)).frame
        drags.dropElement(ref, findsNewHome: false, owner: owner, model: model)

        // 60 points across the glass, on a screen drawn at half size.
        let across: CGFloat = 20 + 120
        #expect(moved.minX == across, "the leaf went across with the finger: \(moved.minX)")
        #expect(rootLaid <= 60, "the root was laid out \(rootLaid) times in 60 frames")
        #expect(othersLaid == others.map { _ in 0 }, "the screen's other containers were laid out \(othersLaid) times")
    }
}
