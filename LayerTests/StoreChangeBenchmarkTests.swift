import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// How long one change through the store takes on a screen of 100 nodes: a move, a resize, a text edit, an add and
/// its delete. The screen is an iPhone's free root of 25 rows, each a text, a body, a toggle and a divider at plan 2's
/// frames, built on the tree. It runs only when `LAYER_BENCHMARK` is set (`TEST_RUNNER_LAYER_BENCHMARK=1` on the
/// `xcodebuild` command line) and prints a `BENCH store <op> p50=<ms> p95=<ms>` line for each. The numbers stand beside
/// the ones plan 2's version of this file measured on main (`scripts/measure-semantic-tree.sh --main`); the next read
/// of the screens that version also timed is `StoreChangeBudgetTests`' `BENCH tree <op>+read` on the tree. The same
/// changes and more are timed on a large design too (`BENCH large`, the sweep's). Its tests run one at a time, so that
/// one waiting on Siri's query doesn't time another.
@MainActor
@Suite("Store change benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LAYER_BENCHMARK"] != nil))
struct StoreChangeBenchmarkTests {
    private static let runs = 50

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
    }

    /// The p50 and p95 of a list of times.
    private static func percentiles(_ times: [Double]) -> (p50: Double, p95: Double) {
        let sorted = times.sorted()
        return (sorted[sorted.count / 2], sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1])
    }

    /// The p50 and p95 of `runs` timed runs of `operation`, in milliseconds, printed as a BENCH line.
    private func measure(_ name: String, _ operation: (Int) -> Void) -> (p50: Double, p95: Double) {
        var changes: [Double] = []
        for run in 0..<Self.runs {
            let start = ContinuousClock.now
            operation(run)
            changes.append(Self.milliseconds(ContinuousClock.now - start))
        }
        let change = Self.percentiles(changes)
        print(String(format: "BENCH store %@ p50=%.3f p95=%.3f", name, change.p50, change.p95))
        return change
    }

    @Test func aStoreChangeOnAHundredElementScreen() throws {
        let model = AppModel(document: LayerDocument())
        let store = model.store
        var nodes: [LayerNode] = []
        for row in 0..<25 {
            let y = 60 + 80 * CGFloat(row)
            nodes.append(.leaf(.text, frame: CGRect(x: 20, y: y, width: 228, height: 24), text: "Title \(row)", tint: Theme.accent))
            nodes.append(.leaf(.body, frame: CGRect(x: 20, y: y + 28, width: 353, height: 40), text: "Body \(row)", tint: Theme.accent))
            nodes.append(.leaf(.toggle, frame: CGRect(x: 322, y: y, width: 51, height: 31), tint: Theme.accent))
            nodes.append(.leaf(.divider, frame: CGRect(x: 20, y: y + 72, width: 353, height: 1), tint: Theme.accent))
        }
        let screen = store.addFreeScreen(nodes, name: "Screen", device: .iPhone, origin: CGPoint(x: 100, y: 50))
        try #require(nodes.count == 100)

        // What the runs change: row 12's title (moved and edited) and its body (resized).
        let moved = nodes[48].id, resized = nodes[49].id, texted = nodes[48].id

        let move = measure("move") { _ in store.update(moved) { $0.frame.origin.x += 1 } }
        let resize = measure("resize") { _ in store.update(resized) { $0.frame.size.width += 1 } }
        let text = measure("text") { _ in store.update(texted) { $0.content.text += "a" } }
        let add = measure("add") { run in
            let added = LayerNode.leaf(.text, frame: CGRect(x: 20, y: 2100, width: 228, height: 24), text: "Added \(run)", tint: Theme.accent)
            _ = store.add(added, to: .screen(screen))
            store.delete(nodes: [added.id])
        }

        // A sanity bound, not the budget.
        for result in [move, resize, text, add] {
            #expect(result.p95.isFinite && result.p95 < 1000)
        }
    }

    // MARK: A large design

    /// The p50 and p95 of `runs` timed runs of `operation` on `store`, alone and with the next read of its index, which
    /// the canvas draws from, in milliseconds: printed as `BENCH large <name>` and `BENCH large <name>+read` lines and
    /// returned for the change with the read. `tidy` runs after each, untimed.
    private func measureLarge(_ name: String, reading store: DesignStore, runs: Int = Self.runs, _ operation: (Int) -> Void,
                              tidy: (Int) -> Void = { _ in }) -> (p50: Double, p95: Double) {
        var changes: [Double] = [], withReads: [Double] = []
        for run in 0..<runs {
            let start = ContinuousClock.now
            operation(run)
            let changed = ContinuousClock.now
            _ = store.index
            let read = ContinuousClock.now
            changes.append(Self.milliseconds(changed - start))
            withReads.append(Self.milliseconds(read - start))
            tidy(run)
        }
        let change = Self.percentiles(changes), withRead = Self.percentiles(withReads)
        print(String(format: "BENCH large %@ p50=%.3f p95=%.3f", name, change.p50, change.p95))
        print(String(format: "BENCH large %@+read p50=%.3f p95=%.3f", name, withRead.p50, withRead.p95))
        return withRead
    }

    /// A row of a text, a body, a toggle and a divider, laid out 8 apart and centred across, filling a column's width.
    private static func listRow(_ number: Int, first: ElementKind = .text) -> LayerNode {
        var row = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 8, alignment: .center)), children: [
            .leaf(first, frame: CGRect(x: 0, y: 0, width: 120, height: 24), text: "Label \(number)"),
            .leaf(.body, frame: CGRect(x: 0, y: 0, width: 160, height: 40), text: "What setting \(number) does"),
            .leaf(.toggle, frame: CGRect(x: 0, y: 0, width: 51, height: 31)),
            .leaf(.divider, frame: CGRect(x: 0, y: 0, width: 20, height: 1)),
        ])
        for index in row.children.indices where index < 2 {
            (row.children[index].width, row.children[index].height) = NaturalSize.defaultSizing(for: row.children[index].kind)
        }
        row.width = LayerNode.Sizing(.fill(weight: 1))
        return row
    }

    /// The large design (sweep item 1): 10 iPhone screens of 100 nodes each, side by side, and 45 loose things below
    /// them on the open canvas, laid out by the rules as a file opened is.
    /// - Screens 0, 2, 4, 6 and 8 have a free root holding 25 rows of a text, a body, a toggle and a divider, placed down
    ///   the screen at plan 2's frames: 100 leaves.
    /// - Screens 1, 3, 5, 7 and 9 have a column root of 20 rows (`listRow`), the first row's text a title: 100 nodes.
    /// - The canvas holds 10 sticky notes, 10 texts, 5 free groups of 3 shapes and a row of 4 texts.
    private static func largeDesign() -> TreeContent {
        var tree = TreeContent()
        for number in 0..<10 {
            var screen = TreeScreen(name: "Screen \(number + 1)", origin: CGPoint(x: 100 + 500 * CGFloat(number), y: 50), scale: 1,
                                    deviceID: nil)
            if number.isMultiple(of: 2) {
                for row in 0..<25 {
                    let y = 60 + 80 * CGFloat(row)
                    screen.root.children += [
                        .leaf(.text, frame: CGRect(x: 20, y: y, width: 228, height: 24), text: "Title \(row)", tint: Theme.accent),
                        .leaf(.body, frame: CGRect(x: 20, y: y + 28, width: 353, height: 40), text: "Body \(row)", tint: Theme.accent),
                        .leaf(.toggle, frame: CGRect(x: 322, y: y, width: 51, height: 31), tint: Theme.accent),
                        .leaf(.divider, frame: CGRect(x: 20, y: y + 72, width: 353, height: 1), tint: Theme.accent),
                    ]
                }
            } else {
                screen.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .fill))
                screen.root.children = (0..<20).map { listRow($0, first: $0 == 0 ? .title : .text) }
            }
            tree.screens.append(screen)
        }
        for number in 0..<10 {
            var note = LayerNode.leaf(.stickyNote, frame: CGRect(x: 100 + 170 * CGFloat(number), y: 1100, width: 150, height: 150),
                                      text: "Idea \(number)")
            note.scale = 1
            var text = LayerNode.leaf(.text, frame: CGRect(x: 100 + 170 * CGFloat(number), y: 1300, width: 150, height: 24),
                                      text: "Note \(number)")
            text.scale = 1
            tree.canvas += [note, text]
        }
        for number in 0..<5 {
            var group = LayerNode.container(frame: CGRect(x: 100 + 300 * CGFloat(number), y: 1400, width: 10, height: 10), children: [
                .leaf(.shape, frame: CGRect(x: 0, y: 0, width: 60, height: 40), shape: .rectangle),
                .leaf(.shape, frame: CGRect(x: 80, y: 20, width: 40, height: 40), shape: .ellipse),
                .leaf(.shape, frame: CGRect(x: 140, y: 0, width: 40, height: 60), shape: .rectangle),
            ])
            group.scale = 1
            tree.canvas.append(group)
        }
        var row = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 8)),
                                      frame: CGRect(x: 100, y: 1600, width: 10, height: 10),
                                      children: (0..<4).map { .leaf(.text, frame: CGRect(x: 0, y: 0, width: 80, height: 24), text: "Chip \($0)") })
        row.scale = 1
        tree.canvas.append(row)
        TreeRules.apply(to: &tree, after: nil)
        return tree
    }

    /// One change through the store on the large design (`largeDesign`), whose cost grows with the whole design where a
    /// walk covers every screen (plan 6's final review B, M2): the 100-node screen's move, resize, text and add, on screen
    /// 5 (free) and screen 6 (a column of rows); a look (a toggle's tint); a design token a scrub changes, one nothing is
    /// laid out by (the card's radius) and one some screens are (the title's size); and a frame of a leaf dragged on
    /// screen 5 by the canvas's own drag, as `StoreChangeBudgetTests` drags one, read after each frame as drawing does.
    /// It prints `BENCH large <op>` and `BENCH large <op>+read` lines, and `BENCH large drag` for the frame with its read.
    @Test func aStoreChangeOnALargeDesign() throws {
        let tree = Self.largeDesign()
        #expect(tree.screens.count == 10)
        #expect(tree.screens.allSatisfy { TreeEdit.count(of: $0.root) == 101 }, "100 nodes below each root")
        #expect(tree.canvas.reduce(0) { $0 + TreeEdit.count(of: $1) } == 45)
        let model = AppModel(document: LayerDocument(file: DesignFile(content: tree)))
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.tool = .select
        let store = model.store
        store.updateCanvas { $0.snapsToGuides = false }

        let free = store.tree.screens[4], column = store.tree.screens[5]
        let moved = free.root.children[48].id
        let row = column.root.children[12]
        let (text, body, toggle) = (row.children[0].id, row.children[1].id, row.children[2].id)

        let move = measureLarge("move", reading: store) { _ in store.update(moved) { $0.frame.origin.x += 1 } }
        let resize = measureLarge("resize", reading: store) { _ in
            guard let now = store.node(body) else { return }
            store.resizeLaidOut(body, to: CGSize(width: now.frame.width + 1, height: now.frame.height), from: now)
        }
        let edit = measureLarge("text", reading: store) { _ in store.update(text) { $0.content.text += "a" } }
        var added: UUID?
        let add = measureLarge("add", reading: store) { run in
            let node = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 80, height: 24), text: "Added \(run)")
            added = store.add(node, to: .node(row.id), at: nil) ? node.id : nil
        } tidy: { _ in
            if let added { store.delete(nodes: [added]) }
        }
        let tints = [RGBColor(hex: 0xFF3B30), RGBColor(hex: 0x34C759)]
        let look = measureLarge("look", reading: store) { run in store.update(toggle) { $0.style.tint = tints[run % 2] } }
        let token = measureLarge("token", reading: store) { _ in store.updateCanvas { $0.tokens.card.radius += 1 } }
        let titleSize = measureLarge("titleSize", reading: store) { run in
            store.updateCanvas { $0.tokens.textSizes.title = 28 + CGFloat(run % 2) }
        }

        // A frame of a drag: a leaf on screen 5, a point to the right each frame, read back after each.
        let dragged = free.root.children[49].id
        let ref = NodeRef(host: .screen(free.id), node: dragged)
        let start = model.viewport.viewPoint(for: try #require(store.placed(ref)).canvasShape.centre)
        let drags = CanvasDrags()
        model.drags = drags
        let owner = CanvasDrags.Owner()
        let frames = 60
        var times: [Double] = []
        var frameTrees: [(before: TreeContent, after: TreeContent)] = []
        for frame in 1...frames {
            let before = store.tree
            let begun = ContinuousClock.now
            drags.moveNode(ref, by: CGSize(width: CGFloat(frame) * model.zoomScale, height: 0), startingAt: start, owner: owner,
                           model: model) { placed in
                drags.moveRule(for: placed, model: model)
            }
            _ = store.index
            times.append(Self.milliseconds(ContinuousClock.now - begun))
            frameTrees.append((before, store.tree))
        }
        drags.dropElement(ref, findsNewHome: false, owner: owner, model: model)
        let drag = Self.percentiles(times)
        print(String(format: "BENCH large drag p50=%.3f p95=%.3f", drag.p50, drag.p95))

        // Two of a drag frame's extras, each timed on every frame's own trees: the store's comparison of the design with
        // the one before (`content != oldValue`), and the placement-intent follower (`followPlacements`), on the design
        // as it is and with every leaf on screen 5 a sketch's, so that it has intents to follow.
        func sketched(_ tree: TreeContent) -> TreeContent {
            var tree = tree
            for index in tree.screens[4].root.children.indices {
                let frame = tree.screens[4].root.children[index].frame
                tree.screens[4].root.children[index].sketch = LayerNode.SketchIntent(
                    sketched: frame, on: DeviceFrame.iPhone.size, margin: DeviceFrame.iPhone.margin, confidence: 1, decidedBy: .rules)
            }
            return tree
        }
        var compares: [Double] = [], follows: [Double] = [], sketchedFollows: [Double] = []
        for (before, after) in frameTrees {
            var begun = ContinuousClock.now
            let differs = after != before
            compares.append(Self.milliseconds(ContinuousClock.now - begun) * 1000)
            #expect(differs)
            var followed = after
            begun = ContinuousClock.now
            followed.followPlacements(since: before, written: after)
            follows.append(Self.milliseconds(ContinuousClock.now - begun) * 1000)
            let (was, now) = (sketched(before), sketched(after))
            var followedSketches = now
            begun = ContinuousClock.now
            followedSketches.followPlacements(since: was, written: now)
            sketchedFollows.append(Self.milliseconds(ContinuousClock.now - begun) * 1000)
        }
        for (name, values) in [("compare", compares), ("follow", follows), ("followSketched", sketchedFollows)] {
            let result = Self.percentiles(values)
            print(String(format: "BENCH large %@ p50=%.1fus p95=%.1fus", name, result.p50, result.p95))
        }

        // Where a large container dragged over a screen would go if let go (`TreeDrop.target`, a drag frame's look for its
        // line): a card of 200 texts on the canvas, the finger over screen 6's rows, on the design with the card added.
        var withCard = store.tree
        var card = LayerNode.container(.card, layout: .stack(LayerNode.Stack(axis: .vertical, spacing: 8)),
                                       frame: CGRect(x: 100, y: 2000, width: 300, height: 10),
                                       children: (0..<200).map { .leaf(.text, frame: CGRect(x: 0, y: 0, width: 200, height: 20), text: "Item \($0)") })
        card.scale = 1
        withCard.canvas.append(card)
        let cardIndex = TreeIndex(withCard)
        let screenFrame = withCard.screens[5].canvasFrame(on: withCard.device(of: withCard.screens[5]))
        let over = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        times = []
        var target: TreeDrop.Target?
        for _ in 0..<Self.runs {
            let begun = ContinuousClock.now
            target = TreeDrop.target(for: card.id, at: over, centre: over, in: withCard, index: cardIndex)
            times.append(Self.milliseconds(ContinuousClock.now - begun))
        }
        let dropTarget = Self.percentiles(times)
        print(String(format: "BENCH large dropTarget p50=%.3f p95=%.3f", dropTarget.p50, dropTarget.p95))
        if case .insert? = target {} else {
            Issue.record("the card would go into screen 6's column or a row in it: \(String(describing: target))")
        }

        #expect(store.node(moved)?.frame.minX == free.root.children[48].frame.minX + CGFloat(Self.runs), "the leaf moved each run")
        #expect(store.node(text)?.content.text.hasSuffix("a") == true, "the text was edited")
        #expect(added != nil, "a text was added to the row")
        #expect(store.node(row.id)?.children.count == 4, "and taken away again")
        #expect(store.node(dragged)?.frame.minX == free.root.children[49].frame.minX + CGFloat(frames), "the drag moved the leaf")
        // A sanity bound, not the budget.
        for result in [move, resize, edit, add, look, token, titleSize, drag, dropTarget] {
            #expect(result.p95.isFinite && result.p95 < 1000)
        }
    }

    /// Siri's element query on the large design, open in its window: the elements behind 10 identifiers spread over the
    /// design, as `ElementQuery.entities(for:)` finds them, 20 times. It prints `BENCH large siriElements`.
    @Test func siriElementsOnALargeDesign() async throws {
        let model = AppModel(document: LayerDocument(file: DesignFile(content: Self.largeDesign())))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Large.layer")
        try model.document.current.wrapper().write(to: file, options: .atomic, originalContentsURL: nil)
        model.fileURL = file
        let designID = try #require(model.designID)
        let elements = DesignSnapshot(id: designID, name: "Large", content: model.store.tree, modified: nil).elements
        let ids = (0..<10).map { elements[$0 * elements.count / 10].id }
        var times: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let found = try await ElementQuery().entities(for: ids)
            times.append(Self.milliseconds(ContinuousClock.now - start))
            #expect(found.map(\.id) == ids)
        }
        let result = Self.percentiles(times)
        print(String(format: "BENCH large siriElements p50=%.3f p95=%.3f", result.p50, result.p95))
        #expect(result.p95.isFinite && result.p95 < 1000)
    }
}
