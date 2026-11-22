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
        board.store.update(board.b) { $0.frame.origin.x += 40 }
        let after = try #require(board.model.selectionShape)
        for _ in 0..<50 { _ = board.model.selectionShape }
        #expect(CanvasWork.turnSessionsFormed - grown <= 1, "formed \(CanvasWork.turnSessionsFormed - grown)")
        #expect(after != before)
        #expect(after == board.store.canvasShape(of: .element(g)))
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

            let written = CodeWork.generated
            for step in 0..<30 {
                board.store.update(board.a) { $0.frame.origin.x += step.isMultiple(of: 2) ? 1 : -1 }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(CodeWork.generated - written == 0, "code written \(CodeWork.generated - written) times over 30 frames")
        }
    }
}

extension PerformanceFixTests {
    @Test func theSharedCodeIsWhatTheGeneratorGivesForTheScreen() async throws {
        let board = OrderBoard()
        let screens = board.store.screens
        let screen = try #require(screens.first)
        let settings = board.store.canvas.code
        let shared = SharedSwiftUICode(screen: screen, among: screens, settings: settings)

        let written = CodeWork.generated
        let data = try await shared.exported(as: .utf8PlainText)
        #expect(CodeWork.generated - written == 1, "written when shared, once")
        #expect(data == Data(SwiftUICodeGenerator.code(for: screen, among: screens, settings: settings).utf8))
        let asString = try await "x".exported(as: .utf8PlainText)
        #expect(asString == Data("x".utf8), "as a String shares it")
    }
}

// MARK: What can be touched (finding 3)

extension PerformanceFixTests {
    /// What `targetElements` was before: a group is a target when something in it shows, found
    /// by walking its leaves, each looked up on its own.
    private func referenceTargets(_ store: DesignStore, entered: Set<DesignElement.ID>) -> [DesignStore.ElementRef.Host: [DesignElement.ID]] {
        let content = store.content
        var found: [DesignStore.ElementRef.Host: [DesignElement.ID]] = [:]
        for element in content.elements {
            guard !element.isHidden, element.isPickedByItsFrame else { continue }
            if element.kind == .group, !content.leaves(of: element.id).contains(where: { !content.isHiddenWithItsGroups($0.id) }) { continue }
            if element.group != nil, !DesignContent.groups(above: element, find: content.element(_:)).allSatisfy({ entered.contains($0.id) && !$0.isHidden }) { continue }
            guard element.kind != .group || !entered.contains(element.id) else { continue }
            found[element.parent.map { .screen($0) } ?? .canvas, default: []].append(element.id)
        }
        return found
    }

    @Test func workingOutWhatCanBeTouchedWalksNoGroupsLeaves() {
        let board = OrderBoard()
        let inner = board.group(board.b, board.c)
        board.group(inner, board.d)
        board.group(board.note1, board.note2)
        board.group(board.a, board.e)

        let walks = GroupWork.leafWalks
        let found = board.store.targetElements(entered: [])
        #expect(GroupWork.leafWalks - walks == 0, "leaves walked \(GroupWork.leafWalks - walks) times for 4 groups")
        #expect(found.values.joined().count > 0)
    }

    @Test func whatCanBeTouchedIsAsItWasForGroupsHiddenAndGoneInto() {
        let board = OrderBoard()
        let inner = board.group(board.b, board.c, named: "inner")
        let outer = board.group(inner, board.d, named: "outer")
        let notes = board.group(board.note1, board.note2, named: "notes")
        let empty = board.group(board.a, board.e, named: "empty")

        func same(_ label: String, entered: Set<DesignElement.ID> = []) {
            let now = board.store.targetElements(entered: entered).mapValues { $0.map(\.id) }
            let was = referenceTargets(board.store, entered: entered)
            #expect(now == was, "\(label)")
        }
        same("nothing hidden")
        same("outer gone into", entered: [outer.element])
        same("outer and inner gone into", entered: [outer.element, inner.element])
        board.store.update(board.b) { $0.isHidden = true }
        same("one of two members hidden", entered: [])
        board.store.update(board.c) { $0.isHidden = true }
        same("inner has nothing showing", entered: [])
        same("inner has nothing showing, outer gone into", entered: [outer.element])
        board.store.update(board.d) { $0.isHidden = true }
        same("outer has nothing showing")
        board.store.update(notes) { $0.isHidden = true }
        same("a hidden group")
        board.store.update(notes) { $0.isHidden = false }
        board.store.update(board.note1) { $0.isHidden = true }
        board.store.update(board.note2) { $0.isHidden = true }
        same("members of notes hidden")
        board.store.update(empty) { $0.isHidden = true }
        board.store.update(board.a) { $0.isHidden = false }
        same("a hidden group over a shown member", entered: [empty.element])
        // Per host as well.
        for host in [DesignStore.ElementRef.Host.screen(board.screen), .canvas] {
            let per = board.store.targets(on: host, entered: [outer.element]).map(\.element)
            let all = board.store.targetElements(entered: [outer.element])[host]?.map(\.id) ?? []
            #expect(Set(per) == Set(all))
        }
    }
}
