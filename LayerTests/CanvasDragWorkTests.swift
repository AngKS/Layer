import CoreGraphics
import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import Layer

private func stroke(from start: CGPoint, length: CGFloat) -> PKStroke {
    let points: [PKStrokePoint] = (0..<12).map { (index: Int) -> PKStrokePoint in
        let x: CGFloat = start.x + length * CGFloat(index) / 11
        let y: CGFloat = start.y + CGFloat(index % 3)
        return PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(index) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: InkGeometry.newStrokeDate()))
}

/// A busy board: a phone screen with 40 lines of text, drawn at half size at (100, 50), and
/// 20 drawings of 10 strokes each on the open canvas beside it, 200 strokes in all.
@MainActor
private struct BusyBoard {
    let model = AppModel(document: LayerDocument())
    let screen: TreeScreen.ID
    let lines: [NodeRef]
    static let strokes = 200

    var store: DesignStore { model.store }

    init() {
        model.canvasSize = CGSize(width: 1210, height: 834)
        screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
        lines = model.store.add((0..<40).map { index in
            LayerNode.leaf(.text, frame: CGRect(x: 20, y: 60 + CGFloat(index) * 19, width: 200, height: 16), text: "Line \(index)", tint: Theme.accent)
        }, onScreen: screen)
        for index in 0..<20 {
            let corner = CGPoint(x: 700 + CGFloat(index % 4) * 120, y: 80 + CGFloat(index / 4) * 140)
            let strokes = (0..<10).map { line in stroke(from: CGPoint(x: corner.x, y: corner.y + CGFloat(line) * 9), length: 80) }
            model.store.addOnCanvas(LayerNode.drawing(strokes)!, scale: 1)
        }
        model.store.updateCanvas { $0.snapsToGuides = false }
        model.tool = .select
    }

    /// Lines 5, 6 and 7 put in a group, as Group does.
    func groupThreeLines() -> NodeRef? {
        store.group(CanvasSelection(lines[5...7].map { CanvasSelection.element($0) })!)
    }

    /// One frame of a finger dragging a group's target `dx` across the glass since it landed.
    func drag(_ drags: CanvasDrags, group: NodeRef, by dx: CGFloat, owner: CanvasDrags.Owner) {
        guard store.placed(group) != nil else { return }
        drags.moveOnTarget(group, by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 150, y: 150), owner: owner, model: model)
    }

    /// Out 30 points across the glass and back again, a point a frame: 60 frames, each of
    /// which moves what is dragged.
    static let outAndBack = Array(1...30) + Array((0...29).reversed())

    /// One frame of a finger dragging `ref` `dx` across the glass since it landed.
    func drag(_ drags: CanvasDrags, _ ref: NodeRef, by dx: CGFloat, owner: CanvasDrags.Owner) {
        guard store.placed(ref) != nil else { return }
        drags.moveNode(ref, by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 150, y: 150), owner: owner, model: model) { placed in
            drags.moveRule(for: placed, model: model)
        }
    }
}

/// A design change made during a drag does what that change needs, not whole-board work on
/// every frame (audit C6): the ink isn't read out of PencilKit unless a drawing changed, and
/// no task is put off for every frame to see whether what is dragged is still there.
@MainActor
@Suite("What a drag's frames cost")
struct CanvasDragWorkTests {
    @Test func aDragOfAnElementReadsNoInkAndPutsOffNoTaskPerFrame() throws {
        let board = BusyBoard()
        let coordinator = InkCanvas.Coordinator(model: board.model)
        board.model.ink = coordinator
        #expect(coordinator.documentCanvas.drawing.strokes.count == BusyBoard.strokes)
        let drags = CanvasDrags()
        board.model.drags = drags
        let owner = CanvasDrags.Owner()

        let (read0, checks0) = (CanvasWork.strokesRead, CanvasWork.dragChecks)
        for frame in 1...60 { board.drag(drags, board.lines[5], by: CGFloat(frame), owner: owner) }
        drags.dropElement(board.lines[5], findsNewHome: true, owner: owner, model: board.model)
        let read = CanvasWork.strokesRead - read0, checks = CanvasWork.dragChecks - checks0

        // 60 × 200 then (12,000): the whole canvas's strokes on every frame. And a task for
        // every frame (60).
        #expect(read == 0, "strokes read out of PencilKit during a 60-frame drag: \(read)")
        #expect(checks == 0, "checks put off during a 60-frame drag: \(checks)")
        #expect(coordinator.documentCanvas.drawing.strokes.count == BusyBoard.strokes, "the ink is still all there")
        #expect(!board.store.isEditing)
    }

    #if DEBUG
    /// Where each node is in the tree (the store's index) is worked out again with every version of
    /// the design, so a gesture's frames read it only when a container moves. A drag of several
    /// lines, a twist of them, and a group's handle build it at most once, for the version the
    /// gesture began on; a group dragged, which moves a container on every frame, builds it at most
    /// once for each version. The count is this store's own, in this one synchronous test (F8).
    @Test func aGesturesFramesBuildTheIndexOnlyWhenAContainerMoves() throws {
        let board = BusyBoard()
        let g = try #require(board.groupThreeLines())
        let drags = CanvasDrags()
        board.model.drags = drags
        let lines = try #require(CanvasSelection(board.lines[10...12].map { CanvasSelection.element($0) }))

        // Several lines dragged together, out and back.
        board.model.selection = lines
        let owner = CanvasDrags.Owner()
        let dragStart = board.store.contentVersion
        var built = board.store.timesIndexed
        for dx in BusyBoard.outAndBack {
            drags.moveGroup(by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 150, y: 150), owner: owner, model: board.model)
        }
        let dragVersions = board.store.contentVersion - dragStart + 1, dragged = board.store.timesIndexed - built
        drags.dropGroup(owner: owner, model: board.model)
        // Clause (m), plan 4: the canvas reads the index, so at most one build per version of the design.
        #expect(dragVersions > 1)
        #expect(dragged <= dragVersions, "index built \(dragged) times over \(dragVersions) versions of a 60-frame drag of three lines")

        // The same lines twisted with two fingers, a degree a frame.
        board.model.selection = lines
        let twistStart = board.store.contentVersion
        built = board.store.timesIndexed
        #expect(board.model.beginTwist())
        for degrees in 1...60 { board.model.twist(by: Double(degrees)) }
        let twistVersions = board.store.contentVersion - twistStart + 1, twisted = board.store.timesIndexed - built
        board.model.endTwist()
        // Clause (m), plan 4: the canvas reads the index, so at most one build per version of the design.
        #expect(twistVersions > 1)
        #expect(twisted <= twistVersions, "index built \(twisted) times over \(twistVersions) versions of a 60-frame twist of three lines")

        // The group's corner handle, from the pose taken as it began, a point a frame.
        let resizeStart = board.store.contentVersion
        built = board.store.timesIndexed
        let pose = try #require(board.store.groupPose(of: g))
        for width in 1...60 {
            let size = CGSize(width: pose.box.width + CGFloat(width), height: pose.box.height * (pose.box.width + CGFloat(width)) / pose.box.width)
            board.store.resizeGroup(g, to: CGRect(origin: pose.box.origin, size: size), from: pose)
        }
        let resizeVersions = board.store.contentVersion - resizeStart + 1, resized = board.store.timesIndexed - built
        // Clause (m), plan 4: the canvas reads the index, so at most one build per version of the design.
        #expect(resizeVersions > 1)
        #expect(resized <= resizeVersions, "index built \(resized) times over \(resizeVersions) versions of a 60-frame resize of a group")

        // The group dragged: a container moves on every frame, and the store's memo is read for it.
        let groupOwner = CanvasDrags.Owner()
        let version = board.store.contentVersion
        built = board.store.timesIndexed
        for dx in BusyBoard.outAndBack { board.drag(drags, group: g, by: CGFloat(dx), owner: groupOwner) }
        let versions = board.store.contentVersion - version + 1, groupDragged = board.store.timesIndexed - built
        drags.dropOnTarget(g, startingAt: CGPoint(x: 150, y: 150), owner: groupOwner, model: board.model)
        #expect(versions > 1)
        #expect(groupDragged <= versions, "index built \(groupDragged) times over \(versions) versions of a group's drag")
    }

    /// A drag of several things and a group's corner handle read the tree on every frame, and each frame is a new
    /// version of the design (plan 4 Task 1). Their checks that no frame lowered the design to the flat list went with
    /// the list (plan 6, Task 11, clause (s)).
    @Test func aDragOfSeveralThingsAndAGroupsHandleWriteEveryFrame() throws {
        let board = BusyBoard()
        let g = try #require(board.groupThreeLines())
        let pose = try #require(board.store.groupPose(of: g))
        let drags = CanvasDrags()
        board.model.drags = drags
        let lines = try #require(CanvasSelection(board.lines[10...12].map { CanvasSelection.element($0) }))
        board.model.selection = lines

        // Several lines dragged together, out and back.
        let owner = CanvasDrags.Owner()
        let dragStart = board.store.contentVersion
        for dx in BusyBoard.outAndBack {
            drags.moveGroup(by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 150, y: 150), owner: owner, model: board.model)
        }
        let dragVersions = board.store.contentVersion - dragStart + 1
        drags.dropGroup(owner: owner, model: board.model)
        #expect(dragVersions > 1)

        // The group's corner handle, from the pose taken as it began, a point a frame.
        let resizeStart = board.store.contentVersion
        for width in 1...60 {
            let size = CGSize(width: pose.box.width + CGFloat(width), height: pose.box.height * (pose.box.width + CGFloat(width)) / pose.box.width)
            board.store.resizeGroup(g, to: CGRect(origin: pose.box.origin, size: size), from: pose)
        }
        let resizeVersions = board.store.contentVersion - resizeStart + 1
        #expect(resizeVersions > 1)
    }

    /// Final review A2-I2: a drag of several things with a screen among them writes each of them on the tree, on every
    /// frame: the screen's origin, a text on another screen through its parent, and a text in a row there, taken out of
    /// the row on the first frame (My call 20) and moved freely after. Its checks that nothing lowered the design to the
    /// flat list went with the list (plan 6, Task 11, clause (s)).
    @Test func aDragOfSeveralThingsWithAScreenAmongThemWritesEachOnTheTree() throws {
        func text(_ words: String, _ frame: CGRect) -> LayerNode {
            var node = LayerNode(kind: .text)
            node.frame = frame
            node.content.text = words
            return node
        }
        func fitting(_ words: String) -> LayerNode {
            var node = text(words, .zero)
            node.width = LayerNode.Sizing(.fit)
            node.height = LayerNode.Sizing(.fit)
            return node
        }
        var first = TreeScreen(name: "First", origin: CGPoint(x: 100, y: 50), scale: 0.5, deviceID: nil)
        first.root.children = (0..<3).map { text("Line \($0)", CGRect(x: 20, y: 60 + CGFloat($0) * 30, width: 200, height: 20)) }
        let loose = text("Loose", CGRect(x: 20, y: 60, width: 120, height: 20))
        let (inRow, other) = (fitting("In"), fitting("Row"))
        var row = LayerNode(kind: .group)
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
        row.frame = CGRect(x: 20, y: 200, width: 0, height: 0)
        row.width = LayerNode.Sizing(.fit)
        row.height = LayerNode.Sizing(.fit)
        row.children = [inRow, other]
        var second = TreeScreen(name: "Second", origin: CGPoint(x: 400, y: 50), scale: 0.5, deviceID: nil)
        second.root.children = [loose, row]
        var tree = TreeContent()
        tree.screens = [first, second]
        TreeRules.apply(to: &tree, after: nil)
        let model = AppModel(document: LayerDocument(file: DesignFile(content: tree)))
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.tool = .select
        let store = model.store
        store.updateCanvas { $0.snapsToGuides = false }
        let drags = CanvasDrags()
        model.drags = drags
        model.selection = CanvasSelection([.screen(first.id), .element(try #require(store.ref(of: loose.id))),
                                           .element(try #require(store.ref(of: inRow.id)))])
        #expect(store.parent(of: inRow.id) == .node(row.id))
        let (startScreen, startLoose) = (first.origin, try #require(store.placed(loose.id)).frame.origin)

        // Out 30 points across the glass, a point a frame.
        let owner = CanvasDrags.Owner()
        for dx in 1...30 {
            drags.moveGroup(by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 150, y: 150), owner: owner, model: model)
        }
        // Each went 30 canvas points across: the screen by its origin, the texts by 60 of their screen's half-size points.
        #expect(store.treeScreen(first.id)?.origin == CGPoint(x: startScreen.x + 30, y: startScreen.y))
        #expect(store.placed(loose.id)?.frame.origin == CGPoint(x: startLoose.x + 60, y: startLoose.y))
        #expect(store.parent(of: inRow.id) == .screen(second.id), "taken out of its row")
        drags.dropGroup(owner: owner, model: model)
    }
    #endif

    /// A drawing dragged is shown where it goes on every frame, as before.
    @Test func aDragOfADrawingStillMovesItsInk() throws {
        let board = BusyBoard()
        let coordinator = InkCanvas.Coordinator(model: board.model)
        board.model.ink = coordinator
        let drawing = try #require(board.store.tree.canvas.first { $0.kind == .drawing })
        let ref = NodeRef(host: .canvas, node: drawing.id)
        let area = try #require(board.store.canvasRect(of: drawing.id))
        /// Its strokes, wherever they are now: those in its row that start past `x`.
        func strokes(startingPast x: CGFloat) -> Int {
            coordinator.documentCanvas.drawing.strokes.filter { stroke in
                let bounds = stroke.renderBounds
                return bounds.midY > area.minY && bounds.midY < area.maxY && bounds.minX > x && bounds.minX < area.minX + 40
            }.count
        }
        #expect(strokes(startingPast: area.minX + 20) == 0)
        let drags = CanvasDrags()
        board.model.drags = drags
        let owner = CanvasDrags.Owner()
        for frame in 1...10 {
            board.drag(drags, ref, by: CGFloat(frame) * 3, owner: owner)
            #expect(strokes(startingPast: area.minX + CGFloat(frame) * 3 - 6) == 10, "frame \(frame): its ink is where it has been dragged to")
        }
        drags.dropElement(ref, findsNewHome: true, owner: owner, model: board.model)
    }

    /// With groups on the board every change puts them right as well, and a frame of a drag
    /// writes only what it moves: a group, or one element. Nothing that stays as it was is
    /// written, so nothing is copied for it (C6, M6).
    @Test func aDragFrameWritesOnlyWhatItMoves() throws {
        let board = BusyBoard()
        let g = try #require(board.groupThreeLines())
        let drags = CanvasDrags()
        board.model.drags = drags

        let owner = CanvasDrags.Owner()
        let start = ListWork.elementsWritten
        for dx in BusyBoard.outAndBack { board.drag(drags, group: g, by: CGFloat(dx), owner: owner) }
        let groupWrites = ListWork.elementsWritten - start
        drags.dropOnTarget(g, startingAt: CGPoint(x: 150, y: 150), owner: owner, model: board.model)
        // The group is written alone on each of 60 frames, and its three lines ride along in it
        // (plan 2, call 13).
        print("BENCH drag group frames=60 writes=\(groupWrites)")
        #expect(groupWrites == 60, "elements written during a 60-frame drag of a group of three: \(groupWrites)")
        #expect(!board.store.isEditing)

        // A line outside the group, dragged beside it: only the line is written.
        let other = CanvasDrags.Owner()
        let before = ListWork.elementsWritten
        for dx in BusyBoard.outAndBack { board.drag(drags, board.lines[20], by: CGFloat(dx), owner: other) }
        let lineWrites = ListWork.elementsWritten - before
        drags.dropElement(board.lines[20], findsNewHome: true, owner: other, model: board.model)
        print("BENCH drag line frames=60 writes=\(lineWrites)")
        #expect(lineWrites == 60, "elements written during a 60-frame drag of one line: \(lineWrites)")
    }

    /// Changes made by something else while a drag is under way, a spoken command say, are
    /// checked once after they are made, however many there were.
    @Test func changesMadeBesideADragAreCheckedOnceAfterThem() async throws {
        let board = BusyBoard()
        let drags = CanvasDrags()
        board.model.drags = drags
        let owner = CanvasDrags.Owner()
        board.drag(drags, board.lines[5], by: 10, owner: owner)
        let checks = CanvasWork.dragChecks
        for index in 20..<23 {
            board.store.asOwnStep { board.store.update(board.lines[index].node) { $0.content.text = "Changed" } }
        }
        #expect(CanvasWork.dragChecks - checks == 1)
        for _ in 0..<5 { await Task.yield() }
        #expect(drags.isDragging, "what it drags is still there")
        board.store.asOwnStep { board.store.update(board.lines[5].node) { $0.isLocked = true } }
        for _ in 0..<5 { await Task.yield() }
        #expect(!drags.isDragging, "locked meanwhile, it is let go of")
    }
}

extension HostedWindowSuites {
    /// The canvas's element targets, each with its tap and drag, while an element is dragged.
    @MainActor
    @Suite("The canvas's targets during a drag", .serialized)
    struct CanvasTargetsWorkTests {
        /// Lets SwiftUI catch up with what has changed.
        private func settle(_ view: UIView, for duration: Duration = .milliseconds(100)) async throws {
            try await Task.sleep(for: duration)
            view.layoutIfNeeded()
        }

        /// The targets built for the things in `store`'s design: another suite's canvas, built meanwhile, isn't
        /// counted (F9, clause (k)).
        private func targetsBuilt(in store: DesignStore) -> Int {
            let tree = store.tree
            let ids = tree.screens.flatMap { TreeEdit.ids(in: $0.root) } + tree.canvas.flatMap(TreeEdit.ids(in:))
            return ids.reduce(0) { $0 + CanvasWork.targetsBuilt(of: $1) }
        }

        /// Nudges a line, now and then, until a change to the design builds at most its own
        /// target. For a while after a window first shows, SwiftUI builds every view on every
        /// update whatever it is given (see `LayersPanelWorkTests`).
        private func waitForTargetsToSettle(nudging ref: NodeRef, in model: AppModel, view: UIView) async throws {
            for step in 0..<40 {
                let before = targetsBuilt(in: model.store)
                model.store.update(ref.node) { $0.frame.origin.y += step.isMultiple(of: 2) ? 1 : -1 }
                try await Task.sleep(for: .milliseconds(50))
                if targetsBuilt(in: model.store) - before <= 1 { return }
            }
        }

        private func show(_ board: BusyBoard) async throws -> (UIWindow, UIView) {
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1210, height: 834))
            let host = UIHostingController(rootView: SelectionLayer().environment(board.model))
            window.rootViewController = host
            // Shown without being made key: taking the key window from another hosted suite's
            // has SwiftUI building every view in that one, and in this, on its next updates.
            window.isHidden = false
            let built = targetsBuilt(in: board.store)
            for _ in 0..<20 where targetsBuilt(in: board.store) == built || board.model.drags == nil { try await settle(host.view) }
            return (window, host.view)
        }

        @Test func aDragBuildsOnlyTheTargetOfWhatItMoves() async throws {
            let board = BusyBoard()
            let shown = targetsBuilt(in: board.store)
            let (window, view) = try await show(board)
            defer { window.isHidden = true }
            #expect(targetsBuilt(in: board.store) - shown >= 40, "a target for each line (a drawing has none: its ink is picked)")
            let drags = try #require(board.model.drags)

            // Measured again, up to three times, while something outside has SwiftUI building
            // every view whatever it is given. The targets as they were were all built on every
            // frame each time, so they can't pass by a retry.
            var built = Int.max
            for _ in 0..<3 where built > 70 {
                try await waitForTargetsToSettle(nudging: board.lines[30], in: board.model, view: view)
                let start = targetsBuilt(in: board.store)
                let owner = CanvasDrags.Owner()
                for frame in 1...60 {
                    board.drag(drags, board.lines[5], by: CGFloat(frame), owner: owner)
                    view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(4))
                }
                drags.dropElement(board.lines[5], findsNewHome: true, owner: owner, model: board.model)
                try await settle(view)
                built = targetsBuilt(in: board.store) - start
            }
            // Every target on every frame then: 40 lines, 60 times (2,441 measured); now only the
            // line dragged, once a frame (60).
            #expect(built <= 70, "targets built during a 60-frame drag: \(built)")
        }

        /// Review Focus 6: a group dragged builds its own target, once a frame, and no other.
        /// Its members have none of their own until it is gone into, and nothing else moves.
        @Test func aGroupDragBuildsOnlyItsOwnTarget() async throws {
            let board = BusyBoard()
            let g = try #require(board.groupThreeLines())
            let (window, view) = try await show(board)
            defer { window.isHidden = true }
            let drags = try #require(board.model.drags)

            // Measured again, up to three times, while something outside has SwiftUI building
            // every view, or SwiftUI folds two frames into one update.
            var built = Int.max
            for _ in 0..<3 where built > 70 {
                try await waitForTargetsToSettle(nudging: board.lines[30], in: board.model, view: view)
                let start = targetsBuilt(in: board.store)
                let owner = CanvasDrags.Owner()
                for dx in BusyBoard.outAndBack {
                    board.drag(drags, group: g, by: CGFloat(dx), owner: owner)
                    view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(4))
                }
                drags.dropOnTarget(g, startingAt: CGPoint(x: 150, y: 150), owner: owner, model: board.model)
                try await settle(view)
                built = targetsBuilt(in: board.store) - start
            }
            // The group's own target, once for each of 60 frames.
            #expect((1...70).contains(built), "targets built during a 60-frame drag of a group: \(built)")
        }

        /// A pinch changes the zoom on every frame. The targets' smallest size follows the zoom
        /// the canvas comes to rest at, so a pinch builds none of them until it ends (audit C8).
        @Test func aPinchBuildsTheTargetsOnlyAsItEnds() async throws {
            let board = BusyBoard()
            let (window, view) = try await show(board)
            defer { window.isHidden = true }
            var built = Int.max
            for _ in 0..<3 where built > 0 {
                try await waitForTargetsToSettle(nudging: board.lines[30], in: board.model, view: view)
                let start = targetsBuilt(in: board.store)
                for frame in 1...30 {
                    board.model.zoomScale = 1 + CGFloat(frame) / 50
                    view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(4))
                }
                try await settle(view)
                built = targetsBuilt(in: board.store) - start
                board.model.zoomScale = 1
                try await settle(view)
            }
            // Every target on every frame then: 40 lines, 30 times.
            #expect(built == 0, "targets built during a 30-frame pinch: \(built)")
        }

        /// With the palette up the targets take no touches, and none are built (audit C8).
        @Test func inDrawNoTargetsAreBuilt() async throws {
            let board = BusyBoard()
            let (window, view) = try await show(board)
            defer { window.isHidden = true }
            board.model.tool = .draw
            try await settle(view)
            let start = targetsBuilt(in: board.store)
            for frame in 1...60 {
                board.store.update(board.lines[5].node) { $0.frame.origin.x = 20 + CGFloat(frame) }
                view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(4))
            }
            try await settle(view)
            let inDraw = targetsBuilt(in: board.store) - start
            #expect(inDraw == 0, "targets built in Draw for 60 changes: \(inDraw)")
            board.model.tool = .select
            try await settle(view)
            #expect(targetsBuilt(in: board.store) - start >= 40, "back in Select, every element has its target again")
        }
    }
}
