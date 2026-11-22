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
