import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

/// The Edit menu, the keyboard's shortcuts and the undo HUD name what Undo and Redo take back:
/// "Undo Move" rather than a plain "Undo" (audit C18, M22; Apple best practice 8.4).
@MainActor
@Suite("What Undo calls a step")
struct UndoNameTests {
    @MainActor private struct Board {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        let button: NodeRef
        let drags = CanvasDrags()
        var store: DesignStore { model.store }

        init() {
            let one = LayerNode.leaf(.button, frame: CGRect(x: 40, y: 300, width: 200, height: 50), text: "One", tint: Theme.accent)
            let screen = model.store.addFreeScreen([one], origin: CGPoint(x: 100, y: 50), scale: 0.5)
            button = NodeRef(host: .screen(screen), node: one.id)
            model.store.updateCanvas { $0.snapsToGuides = false }
            model.drags = drags
            undo.groupsByEvent = false
            model.store.undoManager = undo
            model.adjustmentPause = .seconds(30)
        }

        func drag(by dx: CGFloat, findsNewHome: Bool = true) {
            let owner = CanvasDrags.Owner()
            for step in 1...3 {
                drags.moveNode(button, by: CGSize(width: dx * CGFloat(step) / 3, height: 0), startingAt: .zero, findsNewHome: findsNewHome, owner: owner, model: model) { placed in
                    drags.moveRule(for: placed, model: model)
                }
            }
            drags.dropElement(button, findsNewHome: findsNewHome, owner: owner, model: model)
        }
    }

    @Test func aDragIsAMoveAndAHandlesIsAResize() {
        let board = Board()
        board.drag(by: 20)
        #expect(board.undo.undoActionName == "Move")
        board.undo.undo()
        #expect(board.undo.redoActionName == "Move")

        let other = Board()
        other.drag(by: 20, findsNewHome: false)
        #expect(other.undo.undoActionName == "Resize")
    }

    @Test func aTurnIsARotate() {
        let board = Board()
        board.model.selection = .element(board.button)
        #expect(board.model.beginTurn())
        board.model.turnSelection(by: 30, snaps: false)
        board.model.endTurn()
        #expect(board.undo.undoActionName == "Rotate")
    }

    /// A drag that two fingers' twist takes over is one step with the turn, named for both
    /// (review m3): it used to keep "Move", and "Undo Move" took back the turn too.
    @Test(arguments: [false, true])
    func aDragATwistTakesOverIsAMoveAndRotate(groupedByEvent: Bool) {
        let board = Board()
        board.undo.groupsByEvent = groupedByEvent
        board.model.selection = .element(board.button)
        let owner = CanvasDrags.Owner()
        board.drags.moveNode(board.button, by: CGSize(width: 10, height: 0), startingAt: .zero, owner: owner, model: board.model) { placed in
            board.drags.moveRule(for: placed, model: board.model)
        }
        #expect(board.undo.undoActionName == "Move")
        #expect(board.model.beginTwist())
        board.model.twist(by: 30)
        board.model.endTwist()
        #expect(board.undo.undoActionName == "Move and Rotate")
        board.undo.undo()
        #expect(board.undo.redoActionName == "Move and Rotate")
    }

    @Test func aPensUseIsDrawingAndTheErasersIsErase() {
        #expect(InkCanvas.Coordinator.stepName(for: PKInkingTool(.pen)) == "Drawing")
        #expect(InkCanvas.Coordinator.stepName(for: PKEraserTool(.vector)) == "Erase")
    }

    @Test func theFormatPanelsChangesAreFormat() {
        let board = Board()
        board.model.adjusting { board.store.update(board.button.node) { $0.style.tint = RGBColor(hex: 0xFF0000) } }
        #expect(board.undo.undoActionName == "Format")
    }
}
