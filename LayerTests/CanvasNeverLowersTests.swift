import CoreGraphics
import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import Layer

extension HostedWindowSuites {
    /// The canvas as a person uses it, with the Layers and Format panels open, never lowers the design to the
    /// projection's list: not as an edit is drawn, nor on any frame of a drag, a lift or a screen's drag (plan 4,
    /// Task 12; F9, F11, F13). `TreeProjection.lowerings(of:)` is the check, read for this board's own screen.
    @MainActor
    @Suite("The canvas never lowers the projection", .serialized)
    struct CanvasNeverLowersTests {
        /// A screen whose root is free, holding a card, a row of three and 40 lines of text; or, with
        /// `linesAreDrawings`, the card and the row, and 40 drawings of one stroke each on the open canvas beside it.
        @MainActor
        private struct Board {
            let model: AppModel
            let screen: TreeScreen.ID
            let card: UUID
            let cardText: UUID
            let row: UUID
            let rowChildren: [UUID]
            let lines: [UUID]

            var store: DesignStore { model.store }

            init(linesAreDrawings: Bool) {
                func text(_ words: String, _ frame: CGRect) -> LayerNode {
                    var node = LayerNode(kind: .text)
                    node.frame = frame
                    node.content.text = words
                    return node
                }
                var card = LayerNode(kind: .card)
                card.frame = CGRect(x: 20, y: 60, width: 200, height: 80)
                card.children = [text("Card", CGRect(x: 16, y: 16, width: 120, height: 20))]
                var row = LayerNode(kind: .group)
                row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
                row.frame = CGRect(x: 20, y: 160, width: 256, height: 40)
                row.children = ["A", "B", "C"].map { text($0, CGRect(x: 0, y: 0, width: 80, height: 40)) }
                var screen = TreeScreen(name: "Screen", origin: CGPoint(x: 340, y: 40), scale: 1, deviceID: nil)
                screen.root.children = [card, row]
                var canvas: [LayerNode] = []
                let lines: [LayerNode]
                if linesAreDrawings {
                    lines = (0..<40).compactMap { index in
                        let y = 60 + CGFloat(index) * 18
                        return LayerNode.drawing([Self.stroke(from: CGPoint(x: 800, y: y), to: CGPoint(x: 900, y: y + 6), index: index)])
                    }
                    canvas = lines
                } else {
                    lines = (0..<40).map { index in text("Line \(index)", CGRect(x: 20, y: 220 + CGFloat(index) * 15, width: 200, height: 12)) }
                    screen.root.children += lines
                }
                var tree = TreeContent()
                tree.screens = [screen]
                tree.canvas = canvas
                TreeRules.apply(to: &tree, after: nil)
                model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
                model.tool = .select
                model.store.updateCanvas { $0.snapsToGuides = false }
                self.screen = screen.id
                self.card = card.id
                cardText = card.children[0].id
                self.row = row.id
                rowChildren = row.children.map(\.id)
                self.lines = lines.map(\.id)
            }

            /// A pen stroke between two canvas points, made at a time of its own so that its key is too.
            static func stroke(from start: CGPoint, to end: CGPoint, index: Int) -> PKStroke {
                let points = (0...10).map { step in
                    let t = CGFloat(step) / 10
                    return PKStrokePoint(
                        location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                        timeOffset: Double(step) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                    )
                }
                let made = Date(timeIntervalSinceReferenceDate: 820_000_000 + Double(index))
                return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: made))
            }

            /// Where a thing's middle is in the view, which is where a finger on it lands.
            func start(of id: UUID) -> CGPoint {
                model.viewport.viewPoint(for: store.placed(id)?.canvasShape.centre ?? .zero)
            }
        }

        /// Lets SwiftUI catch up with what has changed.
        private func settle(_ view: UIView, for duration: Duration = .milliseconds(100)) async throws {
            try await Task.sleep(for: duration)
            view.layoutIfNeeded()
        }

        /// One frame of a drag, as touches come in: drawn, then a few milliseconds before the next.
        private func frame(_ view: UIView) async throws {
            view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(4))
        }

        @Test(arguments: [false, true])
        func aDragWithEveryPanelOpenLowersNothing(linesAreDrawings: Bool) async throws {
            let board = Board(linesAreDrawings: linesAreDrawings)
            let model = board.model
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1210, height: 834))
            let host = UIHostingController(rootView: CanvasScreen().environment(model).environment(model.images))
            window.rootViewController = host
            // Shown without being made key, as `CanvasTargetsWorkTests` shows its window: taking the key window from
            // another hosted suite's has SwiftUI building every view in that one.
            window.isHidden = false
            defer { window.isHidden = true }
            model.isLayersOpen = true
            model.panelTab = .layers
            model.selection = .element(try #require(board.store.ref(of: board.card)))
            model.isInspectorOpen = true
            for _ in 0..<40 where model.drags == nil || LayersPanelWork.rows(of: board.card) == 0 || CanvasWork.targetsBuilt(of: board.card) == 0 {
                try await settle(host.view)
            }
            let drags = try #require(model.drags, "the canvas's selection layer is up")
            #expect(LayersPanelWork.rows(of: board.card) >= 1, "the Layers panel lists the card")
            #expect(model.isLayersOpen && model.isInspectorOpen, "both panels are open")

            // The design changed through a tree verb, so the store's kept projection is stale; then proof the counter
            // is live; then changed again, so that nothing measured can be served from what that read kept (F11).
            board.store.update(board.cardText) { $0.content.text = "Changed" }
            let live = TreeProjection.lowerings(of: board.screen)
            _ = board.store.screens
            #expect(TreeProjection.lowerings(of: board.screen) - live == 1, "a read of the projection is counted")
            board.store.update(board.cardText) { $0.content.text = "Changed again" }
            let before = TreeProjection.lowerings(of: board.screen)

            // A line dragged 60 frames, then let go.
            let line = try #require(board.store.ref(of: board.lines[5]))
            let lineStart = board.start(of: line.element)
            let lineOwner = CanvasDrags.Owner()
            for step in 1...60 {
                drags.moveOnTarget(line, by: CGSize(width: CGFloat(step), height: 0), startingAt: lineStart, owner: lineOwner, model: model)
                try await frame(host.view)
            }
            drags.dropOnTarget(line, startingAt: lineStart, owner: lineOwner, model: model)
            try await settle(host.view)
            let afterLine = TreeProjection.lowerings(of: board.screen) - before

            // A child of the row lifted 60 frames, along the row past its last child, and let go there. A lift writes
            // nothing, so the design is changed first (F11).
            board.store.update(board.cardText) { $0.content.text = "Changed for the lift" }
            let child = try #require(board.store.ref(of: board.rowChildren[0]))
            let childStart = board.start(of: child.element)
            let childOwner = CanvasDrags.Owner()
            for step in 1...60 {
                drags.moveOnTarget(child, by: CGSize(width: CGFloat(step) * 3.5 * model.zoomScale, height: 0), startingAt: childStart, owner: childOwner, model: model)
                try await frame(host.view)
            }
            #expect(drags.lift?.ref.element == child.element, "the row's child is lifted")
            drags.dropOnTarget(child, startingAt: childStart, owner: childOwner, model: model)
            try await settle(host.view)
            #expect(board.store.node(board.row)?.children.map(\.id) == [board.rowChildren[1], board.rowChildren[2], board.rowChildren[0]],
                    "let go past the row's last child, it lands at the end")
            let afterLift = TreeProjection.lowerings(of: board.screen) - before

            // The screen dragged 60 frames by its name, then let go.
            let screenStart = model.viewport.viewPoint(for: try #require(board.store.treeScreen(board.screen)).origin)
            let screenOwner = CanvasDrags.Owner()
            for step in 1...60 {
                drags.moveScreen(board.screen, by: CGSize(width: CGFloat(step), height: CGFloat(step) / 2), startingAt: screenStart, owner: screenOwner, model: model)
                try await frame(host.view)
            }
            drags.dropScreen(owner: screenOwner, model: model)
            try await settle(host.view, for: .milliseconds(300))
            let afterScreen = TreeProjection.lowerings(of: board.screen) - before

            let zoom = model.zoomScale
            #expect(board.store.treeScreen(board.screen)?.origin == CGPoint(x: (340 + 60 / zoom).rounded(), y: (40 + 30 / zoom).rounded()),
                    "the screen moved with the finger")
            #expect(afterLine == 0, "lowerings over a 60-frame drag of a line: \(afterLine)")
            #expect(afterLift - afterLine == 0, "lowerings over a 60-frame lift of a row's child: \(afterLift - afterLine)")
            #expect(afterScreen - afterLift == 0, "lowerings over a 60-frame drag of the screen: \(afterScreen - afterLift)")
        }
    }
}

/// What the popover and the panels ask of the selection, and what their taps do (Ungroup, Arrange, Align, Duplicate, a
/// drop in the Layers panel, a frame added from the library), read and write the tree: none of it lowers the design to
/// the projection's list (plan 4, Task 12; the carries from Tasks 6 and 8, and fix round 1). Synchronous on the main
/// actor, so no other suite adds to the count meanwhile.
@MainActor
@Suite("The selection's controls lower nothing")
struct ControlsLowerNothingTests {
    @Test func theGroupArrangeAlignAndDuplicateControlsALayersDropAndALibraryFrameLowerNothing() throws {
        func text(_ words: String, _ frame: CGRect) -> LayerNode {
            var node = LayerNode(kind: .text)
            node.frame = frame
            node.content.text = words
            return node
        }
        var card = LayerNode(kind: .card)
        card.frame = CGRect(x: 20, y: 60, width: 200, height: 80)
        card.children = [text("Card", CGRect(x: 16, y: 16, width: 120, height: 20))]
        var group = LayerNode(kind: .group)
        group.frame = CGRect(x: 20, y: 200, width: 200, height: 60)
        group.children = [text("One", CGRect(x: 0, y: 0, width: 200, height: 20)), text("Two", CGRect(x: 0, y: 40, width: 200, height: 20))]
        let line = text("Line", CGRect(x: 20, y: 400, width: 200, height: 20))
        var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: nil)
        screen.root.children = [card, group, line]
        var tree = TreeContent()
        tree.screens = [screen]
        TreeRules.apply(to: &tree, after: nil)
        let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
        model.canvasSize = CGSize(width: 1210, height: 834)
        let store = model.store
        let cardRef = try #require(store.ref(of: card.id)), lineRef = try #require(store.ref(of: line.id))

        // Changed through a tree verb, the count shown to be live, and changed again (F11).
        store.update(line.id) { $0.content.text = "Changed" }
        let live = TreeProjection.lowerings(of: screen.id)
        _ = store.screens
        #expect(TreeProjection.lowerings(of: screen.id) - live == 1, "a read of the projection is counted")
        store.update(line.id) { $0.content.text = "Changed again" }
        let before = TreeProjection.lowerings(of: screen.id)

        // What the popover and the Format panel ask, the card selected, then the screen.
        model.selection = .element(cardRef)
        #expect(model.canUngroupSelection, "a card is taken apart as a group is")
        #expect(model.canArrangeSelection(.front))
        #expect(!model.groupSelectionSpansHosts)
        _ = model.selectionViewRect
        model.selection = CanvasSelection([.element(cardRef), .element(lineRef)])
        #expect(!model.groupSelectionSpansHosts)
        model.selection = .screen(screen.id)
        #expect(model.selectionViewRect != nil)

        // Their taps: Send to Back, Align of one thing (a leaf, then a container, which goes whole), a row dropped into
        // the group in Layers, Ungroup, a frame from the library, Duplicate of the screen.
        model.selection = .element(lineRef)
        model.arrangeSelection(.back)
        #expect(store.treeScreen(screen.id)?.root.children.first?.id == line.id, "sent to the back")
        model.lineUpSelection(.left)
        #expect(store.placed(line.id)?.frame == CGRect(x: 0, y: 400, width: 200, height: 20), "aligned to the screen's left")
        model.selection = .element(cardRef)
        model.lineUpSelection(.right)
        #expect(store.placed(card.id)?.frame == CGRect(x: 193, y: 60, width: 200, height: 80), "aligned to the screen's right")
        #expect(store.placed(card.children[0].id)?.frame.minX == 209, "what the card holds goes with it")
        model.selection = .element(lineRef)
        #expect(store.moveLayer(line.id, to: .node(group.id), before: nil), "dropped into the group's list")
        #expect(store.parent(of: line.id) == .node(group.id))
        model.selection = .element(cardRef)
        model.ungroupSelection()
        #expect(store.node(card.id) == nil, "Ungroup takes the card apart")
        let added = model.addFrame(.iPhone)
        #expect(store.tree.screens.map(\.name) == ["Screen", "Screen 2"], "a library frame is named by the screens' count")
        #expect(added.name == "Screen 2")
        model.selection = .screen(screen.id)
        model.duplicateSelection()
        #expect(store.tree.screens.count == 3, "the screen is copied")

        #expect(TreeProjection.lowerings(of: screen.id) - before == 0,
                "lowerings over the controls' reads and taps: \(TreeProjection.lowerings(of: screen.id) - before)")
    }
}

extension HostedWindowSuites {
    /// What a drag frame costs with the canvas up and both panels open: nodes written, element targets built and node
    /// views built, over 60 frames of a line, a free group of three lines and a row's child, for the benchmark doc's
    /// "drag frame" row. It runs only when `LAYER_BENCHMARK` is set (`TEST_RUNNER_LAYER_BENCHMARK=1`), alone, so that no
    /// other suite writes or builds views meanwhile, and prints a `BENCH drag <what> frames=60 writes=… targets=…
    /// nodeViews=…` line for each. Each count is summed over the board's own ids, as the counters' tests sum them (F9).
    @MainActor
    @Suite("Drag frame benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LAYER_BENCHMARK"] != nil))
    struct DragFrameBenchmarkTests {
        private func text(_ words: String, _ frame: CGRect) -> LayerNode {
            var node = LayerNode(kind: .text)
            node.frame = frame
            node.content.text = words
            return node
        }

        @Test func dragFramesWithEveryPanelOpen() async throws {
            var row = LayerNode(kind: .group)
            row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
            row.frame = CGRect(x: 20, y: 160, width: 256, height: 40)
            row.children = ["A", "B", "C"].map { text($0, CGRect(x: 0, y: 0, width: 80, height: 40)) }
            var group = LayerNode(kind: .group)
            group.frame = CGRect(x: 20, y: 60, width: 200, height: 80)
            group.children = (0..<3).map { text("Grouped \($0)", CGRect(x: 0, y: CGFloat($0) * 30, width: 200, height: 20)) }
            let lines = (0..<40).map { text("Line \($0)", CGRect(x: 20, y: 220 + CGFloat($0) * 15, width: 200, height: 12)) }
            var screen = TreeScreen(name: "Screen", origin: CGPoint(x: 340, y: 40), scale: 1, deviceID: nil)
            screen.root.children = [group, row] + lines
            var tree = TreeContent()
            tree.screens = [screen]
            TreeRules.apply(to: &tree, after: nil)
            let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
            model.tool = .select
            model.store.updateCanvas { $0.snapsToGuides = false }
            let ids = TreeEdit.ids(in: screen.root)

            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1210, height: 834))
            let host = UIHostingController(rootView: CanvasScreen().environment(model).environment(model.images))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            model.isLayersOpen = true
            model.selection = .element(try #require(model.store.ref(of: lines[0].id)))
            model.isInspectorOpen = true
            func settle(_ duration: Duration = .milliseconds(100)) async throws {
                try await Task.sleep(for: duration)
                host.view.layoutIfNeeded()
            }
            for _ in 0..<40 where model.drags == nil || CanvasWork.nodeViewsBuilt(of: lines[0].id) == 0 { try await settle() }
            let drags = try #require(model.drags)
            func targets() -> Int { ids.reduce(0) { $0 + CanvasWork.targetsBuilt(of: $1) } }
            func nodeViews() -> Int { ids.reduce(0) { $0 + CanvasWork.nodeViewsBuilt(of: $1) } }
            // For a while after a window first shows, SwiftUI builds every view on every update whatever it is given.
            try await settle(.seconds(2))

            for (what, id, step) in [("line", lines[5].id, CGSize(width: 1, height: 0)), ("group", group.id, CGSize(width: 1, height: 0)),
                                     ("rowChild", row.children[0].id, CGSize(width: 3.5 * model.zoomScale, height: 0))] {
                let ref = try #require(model.store.ref(of: id))
                model.selection = .element(ref)
                try await settle(.milliseconds(500))
                let start = model.viewport.viewPoint(for: try #require(model.store.placed(id)).canvasShape.centre)
                let owner = CanvasDrags.Owner()
                let (written, built, drawn) = (ListWork.elementsWritten, targets(), nodeViews())
                for frame in 1...60 {
                    drags.moveOnTarget(ref, by: CGSize(width: step.width * CGFloat(frame), height: 0), startingAt: start, owner: owner, model: model)
                    host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(4))
                }
                host.view.layoutIfNeeded()
                let counts = (ListWork.elementsWritten - written, targets() - built, nodeViews() - drawn)
                drags.dropOnTarget(ref, startingAt: start, owner: owner, model: model)
                try await settle(.milliseconds(300))
                print("BENCH drag \(what) frames=60 writes=\(counts.0) targets=\(counts.1) nodeViews=\(counts.2)")
            }
        }
    }
}
