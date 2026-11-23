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
    let screen: DesignScreen.ID
    let lines: [DesignStore.ElementRef]
    static let strokes = 200

    var store: DesignStore { model.store }

    init() {
        model.canvasSize = CGSize(width: 1210, height: 834)
        screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
        lines = model.store.setElements((0..<40).map { index in
            DesignElement(kind: .text, frame: CGRect(x: 20, y: 60 + CGFloat(index) * 19, width: 200, height: 16), text: "Line \(index)", tint: Theme.accent)
        }, on: screen, replacing: true)
        for index in 0..<20 {
            let corner = CGPoint(x: 700 + CGFloat(index % 4) * 120, y: 80 + CGFloat(index / 4) * 140)
            let strokes = (0..<10).map { line in stroke(from: CGPoint(x: corner.x, y: corner.y + CGFloat(line) * 9), length: 80) }
            model.store.addFloating(DesignElement.drawing(strokes)!, scale: 1)
        }
        model.store.updateCanvas { $0.snapsToGuides = false }
        model.tool = .select
    }

    /// Lines 5, 6 and 7 put in a group, as Group does.
    func groupThreeLines() -> DesignStore.ElementRef? {
        store.group(CanvasSelection(lines[5...7].map { CanvasSelection.element($0) })!)
    }

    /// One frame of a finger dragging a group's target `dx` across the glass since it landed.
    func drag(_ drags: CanvasDrags, group: DesignStore.ElementRef, by dx: CGFloat, owner: CanvasDrags.Owner) {
        guard let (element, placement) = store.resolve(group) else { return }
        drags.moveOnTarget(group, element: element, placement: placement, on: store.screen(screen), by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 150, y: 150), owner: owner, model: model)
    }

    /// Out 30 points across the glass and back again, a point a frame: 60 frames, each of
    /// which moves what is dragged.
    static let outAndBack = Array(1...30) + Array((0...29).reversed())

    /// One frame of a finger dragging `ref` `dx` across the glass since it landed.
    func drag(_ drags: CanvasDrags, _ ref: DesignStore.ElementRef, by dx: CGFloat, owner: CanvasDrags.Owner) {
        guard let (element, placement) = store.resolve(ref) else { return }
        drags.moveElement(ref, from: element.frame, placement: placement, by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 150, y: 150), owner: owner, model: model) {
            drags.moveRule(for: element, placement: placement, on: store.screen(screen), model: model)
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
    /// Each frame of a drag is a new version of the design, and the tree is lowered to its list at most
    /// once for each, by the store's memo. The ink canvas, which follows every change, reads the drawings
    /// off the tree, and nothing else a change sets off lowers the tree again. Both counts are taken on
    /// the main thread alone, in this one synchronous test, so no other test adds to them (F8).
    @Test func aDragLowersTheTreeOnlyThroughTheStoresMemo() throws {
        let board = BusyBoard()
        let coordinator = InkCanvas.Coordinator(model: board.model)
        board.model.ink = coordinator
        let drags = CanvasDrags()
        board.model.drags = drags
        let owner = CanvasDrags.Owner()

        let (version, byStore, everywhere) = (board.store.contentVersion, board.store.timesLowered, TreeProjection.lowerings)
        for frame in 1...60 { board.drag(drags, board.lines[5], by: CGFloat(frame), owner: owner) }
        let versions = board.store.contentVersion - version + 1
        let lowered = board.store.timesLowered - byStore, all = TreeProjection.lowerings - everywhere
        drags.dropElement(board.lines[5], findsNewHome: true, owner: owner, model: board.model)

        #expect(versions > 1)
        #expect(lowered <= versions, "lowered \(lowered) times over \(versions) versions")
        #expect(all == lowered, "lowered \(all - lowered) times outside the store's memo during a 60-frame drag")
    }

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
        var built = board.store.timesIndexed
        for dx in BusyBoard.outAndBack {
            drags.moveGroup(by: CGSize(width: dx, height: 0), startingAt: CGPoint(x: 150, y: 150), owner: owner, model: board.model)
        }
        let dragged = board.store.timesIndexed - built
        drags.dropGroup(owner: owner, model: board.model)
        #expect(dragged <= 1, "index built \(dragged) times during a 60-frame drag of three lines")

        // The same lines twisted with two fingers, a degree a frame.
        board.model.selection = lines
        built = board.store.timesIndexed
        #expect(board.model.beginTwist())
        for degrees in 1...60 { board.model.twist(by: Double(degrees)) }
        let twisted = board.store.timesIndexed - built
        board.model.endTwist()
        #expect(twisted <= 1, "index built \(twisted) times during a 60-frame twist of three lines")

        // The group's corner handle, from the pose taken as it began, a point a frame.
        built = board.store.timesIndexed
        let pose = try #require(board.store.groupPose(of: g))
        for width in 1...60 {
            let size = CGSize(width: pose.box.width + CGFloat(width), height: pose.box.height * (pose.box.width + CGFloat(width)) / pose.box.width)
            board.store.resizeGroup(g, to: CGRect(origin: pose.box.origin, size: size), from: pose)
        }
        let resized = board.store.timesIndexed - built
        #expect(resized <= 1, "index built \(resized) times during a 60-frame resize of a group")

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
    #endif

    /// A drawing dragged is shown where it goes on every frame, as before.
    @Test func aDragOfADrawingStillMovesItsInk() throws {
        let board = BusyBoard()
        let coordinator = InkCanvas.Coordinator(model: board.model)
        board.model.ink = coordinator
        let drawing = try #require(board.store.floating.first { $0.element.kind == .drawing })
        let ref = DesignStore.ElementRef(host: .canvas, element: drawing.id)
        let area = drawing.canvasFrame
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
        #expect(groupWrites == 60, "elements written during a 60-frame drag of a group of three: \(groupWrites)")
        #expect(!board.store.isEditing)

        // A line outside the group, dragged beside it: only the line is written.
        let other = CanvasDrags.Owner()
        let before = ListWork.elementsWritten
        for dx in BusyBoard.outAndBack { board.drag(drags, board.lines[20], by: CGFloat(dx), owner: other) }
        let lineWrites = ListWork.elementsWritten - before
        drags.dropElement(board.lines[20], findsNewHome: true, owner: other, model: board.model)
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
            board.store.asOwnStep { board.store.update(board.lines[index]) { $0.text = "Changed" } }
        }
        #expect(CanvasWork.dragChecks - checks == 1)
        for _ in 0..<5 { await Task.yield() }
        #expect(drags.isDragging, "what it drags is still there")
        board.store.asOwnStep { board.store.update(board.lines[5]) { $0.isLocked = true } }
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

        /// Nudges a line, now and then, until a change to the design builds at most its own
        /// target. For a while after a window first shows, SwiftUI builds every view on every
        /// update whatever it is given (see `LayersPanelWorkTests`).
        private func waitForTargetsToSettle(nudging ref: DesignStore.ElementRef, in model: AppModel, view: UIView) async throws {
            for step in 0..<40 {
                let before = CanvasWork.targetsBuilt
                model.store.update(ref) { $0.frame.origin.y += step.isMultiple(of: 2) ? 1 : -1 }
                try await Task.sleep(for: .milliseconds(50))
                if CanvasWork.targetsBuilt - before <= 1 { return }
            }
        }

        private func show(_ board: BusyBoard) async throws -> (UIWindow, UIView) {
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1210, height: 834))
            let host = UIHostingController(rootView: SelectionLayer().environment(board.model))
            window.rootViewController = host
            // Shown without being made key: taking the key window from another hosted suite's
            // has SwiftUI building every view in that one, and in this, on its next updates.
            window.isHidden = false
            let built = CanvasWork.targetsBuilt
            for _ in 0..<20 where CanvasWork.targetsBuilt == built || board.model.drags == nil { try await settle(host.view) }
            return (window, host.view)
        }

        @Test func aDragBuildsOnlyTheTargetOfWhatItMoves() async throws {
            let board = BusyBoard()
            let shown = CanvasWork.targetsBuilt
            let (window, view) = try await show(board)
            defer { window.isHidden = true }
            #expect(CanvasWork.targetsBuilt - shown >= 40, "a target for each line (a drawing has none: its ink is picked)")
            let drags = try #require(board.model.drags)

            // Measured again, up to three times, while something outside has SwiftUI building
            // every view whatever it is given. The targets as they were were all built on every
            // frame each time, so they can't pass by a retry.
            var built = Int.max
            for _ in 0..<3 where built > 70 {
                try await waitForTargetsToSettle(nudging: board.lines[30], in: board.model, view: view)
                let start = CanvasWork.targetsBuilt
                let owner = CanvasDrags.Owner()
                for frame in 1...60 {
                    board.drag(drags, board.lines[5], by: CGFloat(frame), owner: owner)
                    view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(4))
                }
                drags.dropElement(board.lines[5], findsNewHome: true, owner: owner, model: board.model)
                try await settle(view)
                built = CanvasWork.targetsBuilt - start
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
            for _ in 0..<3 where !(60...70).contains(built) {
                try await waitForTargetsToSettle(nudging: board.lines[30], in: board.model, view: view)
                let start = CanvasWork.targetsBuilt
                let owner = CanvasDrags.Owner()
                for dx in BusyBoard.outAndBack {
                    board.drag(drags, group: g, by: CGFloat(dx), owner: owner)
                    view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(4))
                }
                drags.dropOnTarget(g, startingAt: CGPoint(x: 150, y: 150), owner: owner, model: board.model)
                try await settle(view)
                built = CanvasWork.targetsBuilt - start
            }
            // The group's own target, once for each of 60 frames.
            #expect((60...70).contains(built), "targets built during a 60-frame drag of a group: \(built)")
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
                let start = CanvasWork.targetsBuilt
                for frame in 1...30 {
                    board.model.zoomScale = 1 + CGFloat(frame) / 50
                    view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(4))
                }
                try await settle(view)
                built = CanvasWork.targetsBuilt - start
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
            let start = CanvasWork.targetsBuilt
            for frame in 1...60 {
                board.store.update(board.lines[5]) { $0.frame.origin.x = 20 + CGFloat(frame) }
                view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(4))
            }
            try await settle(view)
            let inDraw = CanvasWork.targetsBuilt - start
            #expect(inDraw == 0, "targets built in Draw for 60 changes: \(inDraw)")
            board.model.tool = .select
            try await settle(view)
            #expect(CanvasWork.targetsBuilt - start >= 40, "back in Select, every element has its target again")
        }
    }
}
