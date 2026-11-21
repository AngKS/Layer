import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The format panel's run of quick changes is one step, ended by a pause after its last change.
/// What is done meanwhile that isn't the panel's own is a step of its own: it used to join
/// the panel's step, so one Undo took back both (audit M14).
@MainActor
@Suite("The format panel's step")
struct PanelStepTests {
    @MainActor private struct Board {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        let first: DesignStore.ElementRef
        let second: DesignStore.ElementRef
        var store: DesignStore { model.store }

        init() {
            let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
            let placed = model.store.setElements([
                DesignElement(kind: .button, frame: CGRect(x: 40, y: 300, width: 200, height: 50), text: "One", tint: RGBColor(hex: 0x000000)),
                DesignElement(kind: .button, frame: CGRect(x: 40, y: 400, width: 200, height: 50), text: "Two", tint: RGBColor(hex: 0x000000)),
            ], on: screen, replacing: true)
            (first, second) = (placed[0], placed[1])
            undo.groupsByEvent = false
            model.store.undoManager = undo
            // The pause doesn't run out during a test unless it waits for it.
            model.adjustmentPause = .seconds(30)
        }

        func tint(of ref: DesignStore.ElementRef) -> RGBColor? {
            store.resolve(ref)?.element.tint
        }
    }

    @Test func aDeleteRightAfterAColourChangeIsAStepOfItsOwn() {
        let board = Board()
        board.model.selection = .element(board.first)
        board.model.adjusting { board.store.update(board.first) { $0.tint = RGBColor(hex: 0xFF0000) } }
        board.model.deleteSelection()
        #expect(board.store.resolve(board.first) == nil)

        board.undo.undo()
        #expect(board.tint(of: board.first) == RGBColor(hex: 0xFF0000), "Undo puts back what was deleted, with its new colour")
        board.undo.undo()
        #expect(board.tint(of: board.first) == RGBColor(hex: 0x000000))
    }

    @Test func aColourChangedOnAnotherSelectionIsAStepOfItsOwn() {
        let board = Board()
        board.model.selection = .element(board.first)
        board.model.adjusting { board.store.update(board.first) { $0.tint = RGBColor(hex: 0xFF0000) } }
        board.model.selection = .element(board.second)
        board.model.adjusting { board.store.update(board.second) { $0.tint = RGBColor(hex: 0x0000FF) } }

        board.undo.undo()
        #expect(board.tint(of: board.second) == RGBColor(hex: 0x000000))
        #expect(board.tint(of: board.first) == RGBColor(hex: 0xFF0000), "the first change is a step of its own")
    }

    /// An action on several things in the pause is one step of its own: it used to be one
    /// step per thing, since it neither joined the panel's step nor made one of its own
    /// (review I2).
    @Test func duplicatingSeveralThingsRightAfterAColourChangeIsOneStep() {
        let board = Board()
        let things = CanvasSelection([.element(board.first), .element(board.second)])
        board.model.selection = things
        board.model.adjusting {
            for ref in [board.first, board.second] { board.store.update(ref) { $0.tint = RGBColor(hex: 0xFF0000) } }
        }
        let count = board.store.content.elements.count
        board.model.duplicateSelection()
        #expect(board.store.content.elements.count == count + 2)

        board.undo.undo()
        #expect(board.store.content.elements.count == count, "one Undo takes back both copies")
        #expect(board.tint(of: board.first) == RGBColor(hex: 0xFF0000), "and leaves the colour")
        board.undo.undo()
        #expect(board.tint(of: board.first) == RGBColor(hex: 0x000000))
    }

    @Test func deletingAScreenAndAnElementRightAfterAColourChangeIsOneStep() {
        let board = Board()
        let other = board.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 400, y: 50), scale: 0.5)).id
        board.undo.removeAllActions()
        board.model.selection = CanvasSelection([.element(board.second), .screen(other)])
        board.model.adjusting { board.store.update(board.second) { $0.tint = RGBColor(hex: 0xFF0000) } }
        board.model.deleteSelection()
        #expect(board.store.screen(other) == nil && board.store.resolve(board.second) == nil)

        board.undo.undo()
        #expect(board.store.screen(other) != nil && board.store.resolve(board.second) != nil, "one Undo brings both back")
        #expect(board.tint(of: board.second) == RGBColor(hex: 0xFF0000), "with the colour")
    }

    /// The panel's run of changes is still one step.
    @Test func aRunOfChangesInThePanelIsOneStep() {
        let board = Board()
        board.model.selection = .element(board.first)
        for hex in [0x110000, 0x220000, 0x330000] {
            board.model.adjusting { board.store.update(board.first) { $0.tint = RGBColor(hex: UInt32(hex)) } }
        }
        board.undo.undo()
        #expect(board.tint(of: board.first) == RGBColor(hex: 0x000000))
        #expect(!board.undo.canUndo)
    }
}
