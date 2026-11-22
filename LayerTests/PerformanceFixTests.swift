import CoreGraphics
import Foundation
import Testing
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
