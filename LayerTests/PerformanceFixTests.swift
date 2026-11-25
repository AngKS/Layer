import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Layer

/// Counter tests for the contained fixes of the 2026-11-23 performance review: each holds one
/// piece of per-frame work to what a frame needs, as `CanvasDragWorkTests` does for the drag.
/// They have no awaits, so that the counters they read are theirs alone.
@MainActor
struct PerformanceFixTests {
    // MARK: Turn sessions (finding 1)

    @Test func aSelectedGroupFormsOneTurnSessionForAnyNumberOfReadsOfItsShape() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.selection = .element(g)

        let formed = CanvasWork.turnSessionsFormed
        var shape: TurnedRect?
        for _ in 0..<50 {
            shape = board.model.selectionShape
            _ = board.model.knobViewPoint
            _ = board.model.selectionTurn
            _ = board.model.canTurnSelection
        }
        #expect(CanvasWork.turnSessionsFormed - formed <= 1, "formed \(CanvasWork.turnSessionsFormed - formed)")
        let before = try #require(shape)

        // A change to the design is read as it is: one more session, and a new outline.
        let grown = CanvasWork.turnSessionsFormed
        board.store.update(board.b.node) { $0.frame.origin.x += 40 }
        let after = try #require(board.model.selectionShape)
        for _ in 0..<50 { _ = board.model.selectionShape }
        #expect(CanvasWork.turnSessionsFormed - grown <= 1, "formed \(CanvasWork.turnSessionsFormed - grown)")
        #expect(after != before)
        #expect(after == board.store.canvasShape(of: .element(g)))
    }

    @Test func theSelectedThingsAreListedOnceForAnyNumberOfReads() {
        let board = OrderBoard()
        board.model.selection = CanvasSelection([.element(board.a), .element(board.c)])
        let listed = CanvasWork.thingsListed
        for _ in 0..<50 { _ = board.model.selectedThings }
        #expect(CanvasWork.thingsListed - listed <= 1, "listed \(CanvasWork.thingsListed - listed) times")
        board.store.update(board.a.node) { $0.frame.origin.x += 3 }
        _ = board.model.selectedThings
        #expect(CanvasWork.thingsListed - listed <= 2)
    }

    /// What the outline and the turn are, read through the kept ones, against ones formed afresh.
    private func expectFresh(_ board: OrderBoard, _ label: String) {
        guard let selection = board.model.selection else { return }
        #expect(board.model.selectedThings == board.store.things(in: selection), "things, \(label)")
        let isGroup: Bool
        if case .element(let ref) = selection { isGroup = board.store.node(ref.node)?.kind == .group } else { isGroup = false }
        guard selection.isSeveral || isGroup else { return }
        let fresh = TurnSession.form(for: selection, in: board.store)
        if let fresh {
            #expect(board.model.selectionShape == fresh.shape, "shape, \(label)")
            if selection.isSeveral { #expect(board.model.selectionTurn == Rotation.normalized(fresh.turned), "turn, \(label)") }
        }
    }

    @Test func theKeptOutlineFollowsUndoLocksHidingAndMembership() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.selection = .element(g)
        expectFresh(board, "formed")

        board.undo.groupsByEvent = false
        board.undo.beginUndoGrouping()
        board.store.update(board.b.node) { $0.frame.origin.x += 60 }
        board.undo.endUndoGrouping()
        expectFresh(board, "moved")
        let moved = board.model.selectionShape
        board.undo.undo()
        expectFresh(board, "undone")
        #expect(board.model.selectionShape != moved)
        board.undo.redo()
        expectFresh(board, "redone")
        #expect(board.model.selectionShape == moved)

        board.store.update(board.b.node) { $0.isLocked = true }
        expectFresh(board, "member locked")
        board.store.update(board.b.node) { $0.isHidden = true }
        expectFresh(board, "member hidden")
        board.store.update(g.node) { $0.isLocked = true }
        expectFresh(board, "group locked")
        #expect(!board.model.canTurnSelection)
        board.store.update(g.node) { $0.isLocked = false }
        #expect(board.model.canTurnSelection)

        // A member added to the group and one taken out.
        board.store.move(board.a.node, to: .node(g.node))
        expectFresh(board, "member added")
        board.store.move(board.d.node, to: .screen(board.screen))
        expectFresh(board, "member taken out")

        // Several things selected, and one of them changed.
        board.model.selection = CanvasSelection([.element(board.a), .element(board.c), .element(board.e)])
        expectFresh(board, "several")
        board.store.update(board.c.node) { $0.isLocked = true }
        expectFresh(board, "several, one locked")
        board.store.update(board.e.node) { $0.rotation = 20 }
        expectFresh(board, "several, one turned")
        board.store.delete(board.a)
        expectFresh(board, "several, one deleted")
    }

    @Test func severalThingsSelectedFormOneTurnSessionToo() throws {
        let board = OrderBoard()
        board.model.selection = CanvasSelection([.element(board.a), .element(board.c)])
        let formed = CanvasWork.turnSessionsFormed
        for _ in 0..<50 { _ = board.model.selectionShape; _ = board.model.selectedThings }
        #expect(CanvasWork.turnSessionsFormed - formed <= 1, "formed \(CanvasWork.turnSessionsFormed - formed)")
        #expect(board.model.selectedThings == [.element(board.a), .element(board.c)])
        board.model.selection = .element(board.c)
        #expect(board.model.selectedThings == [.element(board.c)])
    }
}

extension HostedWindowSuites {
    @MainActor
    @Suite("The share menu during a drag", .serialized)
    struct ShareMenuWorkTests {
        @Test func theShareMenuWritesNoCodeUntilSomethingIsShared() async throws {
            let board = OrderBoard()
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
            window.rootViewController = UIHostingController(rootView: ShareMenu().environment(board.model))
            window.isHidden = false
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(200))

            // Counted for this board's screen alone: suites alongside write code for their own.
            let screen = board.screen
            let written = CodeWork.generated(for: screen)
            for step in 0..<30 {
                board.store.update(board.a.node) { $0.frame.origin.x += step.isMultiple(of: 2) ? 1 : -1 }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(CodeWork.generated(for: screen) - written == 0, "code written \(CodeWork.generated(for: screen) - written) times over 30 frames")
        }
    }
}

extension PerformanceFixTests {
    @Test func theSharedCodeIsWhatTheGeneratorGivesForTheScreen() async throws {
        let board = OrderBoard()
        let tree = board.store.tree
        let screen = try #require(tree.screens.first)
        let settings = tree.settings.code
        let context = SwiftUICodeGenerator.Context(tree)
        let shared = SharedSwiftUICode(screen: screen, context: context, settings: settings)

        // The counter is shared with suites that run alongside this one across an await, so it
        // is the share menu's own test that holds the count to nothing.
        let data = try await shared.exported(as: .utf8PlainText)
        #expect(data == Data(SwiftUICodeGenerator.code(for: screen, in: context, settings: settings).utf8))
        let asString = try await "x".exported(as: .utf8PlainText)
        #expect(asString == Data("x".utf8), "as a String shares it")
    }
}

// MARK: What can be touched (finding 3)

extension PerformanceFixTests {
    /// What `targetElements` was before: a group is a target when something in it shows, found
    /// by walking its leaves, each looked up on its own.
    private func referenceTargets(_ store: DesignStore, entered: Set<UUID>) -> [NodeRef.Host: [UUID]] {
        let content = store.tree
        var found: [NodeRef.Host: [UUID]] = [:]
        for node in content.listedEverywhere {
            guard !node.isHidden, node.kind != .drawing || node.isLocked else { continue }
            if node.kind == .group, !node.leaves.contains(where: { !store.isHiddenWithItsContainers($0.id) }) { continue }
            if store.container(of: node.id) != nil,
               !content.containers(above: node.id).allSatisfy({ entered.contains($0) && content.node($0)?.isHidden == false }) { continue }
            guard node.kind != .group || !entered.contains(node.id) else { continue }
            found[store.hostScreen(of: node.id).map { .screen($0) } ?? .canvas, default: []].append(node.id)
        }
        return found
    }

    /// Whether a group has something showing is found from the first leaf showing in it, not by walking every leaf it
    /// holds: one leaf for each of the three groups on top, the nested one's included, where its seven leaves were each
    /// walked before (final review A1 m2: `TreeTargets` never records a leaf walk, so the count it read before was
    /// nothing by construction).
    @Test func workingOutWhatCanBeTouchedWalksNoGroupsLeaves() {
        let board = OrderBoard()
        let inner = board.group(board.b, board.c)
        board.group(inner, board.d)
        board.group(board.note1, board.note2)
        board.group(board.a, board.e)

        let looked = GroupWork.leavesLookedAt
        let found = TreeTargets(board.store.tree, index: board.store.index, entered: []).byHost
        #expect(GroupWork.leavesLookedAt - looked == 3, "leaves looked at for 4 groups holding 7: \(GroupWork.leavesLookedAt - looked)")
        #expect(found.values.joined().count > 0)
    }

    @Test func whatCanBeTouchedIsAsItWasForGroupsHiddenAndGoneInto() {
        let board = OrderBoard()
        let inner = board.group(board.b, board.c, named: "inner")
        let outer = board.group(inner, board.d, named: "outer")
        let notes = board.group(board.note1, board.note2, named: "notes")
        let empty = board.group(board.a, board.e, named: "empty")

        func same(_ label: String, entered: Set<UUID> = []) {
            let now = board.store.treeTargets(entered: entered).byHost.mapValues { $0.map(\.id) }
            let was = referenceTargets(board.store, entered: entered)
            #expect(now == was, "\(label)")
        }
        same("nothing hidden")
        same("outer gone into", entered: [outer.node])
        // Per host as well: each host's targets, in order, are the reference walk's (final review A1 m2: the loop
        // compared the targets with themselves, and ran once nothing on either host could be touched).
        let reference = referenceTargets(board.store, entered: [outer.node])
        for host in [NodeRef.Host.screen(board.screen), .canvas] {
            let per = board.store.treeTargets(entered: [outer.node]).refs(on: host).map(\.node)
            #expect(!per.isEmpty, "\(host) has things to touch")
            #expect(per == reference[host] ?? [], "\(host)")
        }
        same("outer and inner gone into", entered: [outer.node, inner.node])
        board.store.update(board.b.node) { $0.isHidden = true }
        same("one of two members hidden", entered: [])
        board.store.update(board.c.node) { $0.isHidden = true }
        same("inner has nothing showing", entered: [])
        same("inner has nothing showing, outer gone into", entered: [outer.node])
        board.store.update(board.d.node) { $0.isHidden = true }
        same("outer has nothing showing")
        board.store.update(notes.node) { $0.isHidden = true }
        same("a hidden group")
        board.store.update(notes.node) { $0.isHidden = false }
        board.store.update(board.note1.node) { $0.isHidden = true }
        board.store.update(board.note2.node) { $0.isHidden = true }
        same("members of notes hidden")
        board.store.update(empty.node) { $0.isHidden = true }
        board.store.update(board.a.node) { $0.isHidden = false }
        same("a hidden group over a shown member", entered: [empty.node])
    }
}

// MARK: The window's hover recogniser (finding 9)

extension HostedWindowSuites {
    @MainActor
    @Suite("The pencil bridge's window recogniser", .serialized)
    struct PencilBridgeWorkTests {
        @Test func theWindowCarriesTheHoverRecogniserOnlyWhileARulerCanUseIt() async throws {
            let scrubber = Scrubber()
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            let baseline = window.gestureRecognizers?.filter { $0 is UIHoverGestureRecognizer }.count ?? 0
            window.rootViewController = UIHostingController(rootView: PencilBridge(scrubber: scrubber))
            window.isHidden = false
            defer { window.isHidden = true }
            func hovers() -> Int { (window.gestureRecognizers?.filter { $0 is UIHoverGestureRecognizer }.count ?? 0) - baseline }
            /// Waits, up to two seconds, for the window to carry `count` of the bridge's recognisers.
            func settle(toward count: Int) async throws {
                for _ in 0..<100 where hovers() != count { try await Task.sleep(for: .milliseconds(20)) }
            }
            // Idle from the start: given time to be wrong, since a recogniser would come on first.
            try await Task.sleep(for: .milliseconds(150))
            #expect(hovers() == 0, "idle, the window has \(hovers()) hover recognisers of the bridge's")

            let field = ScrubbedField(0)
            scrubber.begin(field.target("Rotation", at: CGRect(x: 0, y: 0, width: 80, height: 32)))
            try await settle(toward: 1)
            #expect(hovers() == 1, "with a ruler up there is one")

            scrubber.end()
            try await settle(toward: 0)
            #expect(hovers() == 0, "and none once it is put away")

            scrubber.hovered = field.target("Rotation", at: CGRect(x: 0, y: 0, width: 80, height: 32))
            try await settle(toward: 1)
            #expect(hovers() == 1, "the pencil over a field, which a squeeze would scrub, has it ready")
            scrubber.hovered = nil
            try await settle(toward: 0)
            #expect(hovers() == 0)
        }
    }
}

// MARK: The zoom ruler's pieces (finding 8)

extension PerformanceFixTests {
    @Test func aPencilMovingOverTheZoomControlMakesItsRulerOnce() {
        let scrubber = Scrubber()
        let frame = CGRect(x: 500, y: 760, width: 100, height: 44)
        let made = ZoomWork.targetsMade
        let sets = ZoomWork.majorSetsBuilt
        for _ in 0..<100 {
            ZoomStops.hover(scrubber, frame: frame) { ZoomStops.target(frame: frame, current: { 1 }, zoom: { _ in }) }
        }
        #expect(ZoomWork.targetsMade - made == 1, "rulers made \(ZoomWork.targetsMade - made) for 100 moves")
        #expect(scrubber.hovered?.owner == .zoom && scrubber.hovered?.frame == frame)

        // Moved, the control is found where it now is; and a hover on a panel field's is let go of.
        let moved = frame.offsetBy(dx: 20, dy: 0)
        ZoomStops.hover(scrubber, frame: moved) { ZoomStops.target(frame: moved, current: { 1 }, zoom: { _ in }) }
        #expect(scrubber.hovered?.frame == moved)
        let field = ScrubbedField(0)
        scrubber.hovered = field.target("Rotation", at: moved)
        ZoomStops.hover(scrubber, frame: moved) { ZoomStops.target(frame: moved, current: { 1 }, zoom: { _ in }) }
        #expect(scrubber.hovered?.owner == .zoom)

        // Each ruler made shares the set of marks.
        let before = ZoomWork.majorSetsBuilt
        for _ in 0..<50 { _ = ZoomStops.target(frame: frame, current: { 1 }, zoom: { _ in }) }
        #expect(ZoomWork.majorSetsBuilt - before == 0, "mark sets built \(ZoomWork.majorSetsBuilt - before) for 50 rulers")
        _ = sets
    }
}

// MARK: Deleting (finding 15)

extension PerformanceFixTests {
    @Test func deletingAGroupStartsOneTaskForTheReadingLog() {
        let board = OrderBoard()
        let members = [board.a, board.b, board.c, board.d]
        let g = board.group(members[0], members[1], members[2], members[3], named: "four")

        let before = CanvasWork.readingLogTasks
        board.store.delete(g)
        #expect(CanvasWork.readingLogTasks - before == 1, "tasks started \(CanvasWork.readingLogTasks - before) for 5 elements")
        #expect(board.store.node(g.node) == nil && board.store.node(board.c.node) == nil)

        let again = CanvasWork.readingLogTasks
        board.store.delete([board.note1, board.note2])
        #expect(CanvasWork.readingLogTasks - again == 1)
        board.store.delete(board.e)
        #expect(CanvasWork.readingLogTasks - again == 2)
    }

    @Test func theLogMarksEveryDeletedReadingFromOneNote() async {
        let log = SketchReadingLog(fileURL: nil)
        var elements: [UUID] = []
        for _ in 0..<3 {
            let entry = await log.record(
                placementKind: "button", existingKinds: [], existingFrames: [], screenSize: nil,
                strokes: [], candidates: ["button"], scores: [1], chosen: "button", escalated: false, decidedBy: "test"
            )
            let element = UUID()
            await log.link(element: element, toEntry: entry)
            elements.append(element)
        }
        await log.noteDeleted(Set(elements.prefix(2)))
        let entries = await log.allEntries()
        #expect(entries.map { $0.correctedAfter != nil } == [true, true, false])
    }
}
