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
        let first: NodeRef
        let second: NodeRef
        var store: DesignStore { model.store }

        init() {
            let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
            let one = LayerNode.leaf(.button, frame: CGRect(x: 40, y: 300, width: 200, height: 50), text: "One", tint: RGBColor(hex: 0x000000))
            let two = LayerNode.leaf(.button, frame: CGRect(x: 40, y: 400, width: 200, height: 50), text: "Two", tint: RGBColor(hex: 0x000000))
            let store = model.store
            store.asOneStep {
                store.add(one, to: .screen(screen))
                store.add(two, to: .screen(screen))
            }
            (first, second) = (.init(host: .screen(screen), node: one.id), .init(host: .screen(screen), node: two.id))
            undo.groupsByEvent = false
            model.store.undoManager = undo
            // The pause doesn't run out during a test unless it waits for it.
            model.adjustmentPause = .seconds(30)
        }

        func tint(of ref: NodeRef) -> RGBColor? {
            store.placed(ref)?.node.resolvedTint
        }
    }

    @Test func aDeleteRightAfterAColourChangeIsAStepOfItsOwn() {
        let board = Board()
        board.model.selection = .element(board.first)
        board.model.adjusting { board.store.update(board.first.node) { $0.style.tint = RGBColor(hex: 0xFF0000) } }
        board.model.deleteSelection()
        #expect(board.store.placed(board.first) == nil)

        board.undo.undo()
        #expect(board.tint(of: board.first) == RGBColor(hex: 0xFF0000), "Undo puts back what was deleted, with its new colour")
        board.undo.undo()
        #expect(board.tint(of: board.first) == RGBColor(hex: 0x000000))
    }

    @Test func aColourChangedOnAnotherSelectionIsAStepOfItsOwn() {
        let board = Board()
        board.model.selection = .element(board.first)
        board.model.adjusting { board.store.update(board.first.node) { $0.style.tint = RGBColor(hex: 0xFF0000) } }
        board.model.selection = .element(board.second)
        board.model.adjusting { board.store.update(board.second.node) { $0.style.tint = RGBColor(hex: 0x0000FF) } }

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
            for ref in [board.first, board.second] { board.store.update(ref.node) { $0.style.tint = RGBColor(hex: 0xFF0000) } }
        }
        let count = board.store.thingCount
        board.model.duplicateSelection()
        #expect(board.store.thingCount == count + 2)

        board.undo.undo()
        #expect(board.store.thingCount == count, "one Undo takes back both copies")
        #expect(board.tint(of: board.first) == RGBColor(hex: 0xFF0000), "and leaves the colour")
        board.undo.undo()
        #expect(board.tint(of: board.first) == RGBColor(hex: 0x000000))
    }

    @Test func deletingAScreenAndAnElementRightAfterAColourChangeIsOneStep() {
        let board = Board()
        let other = board.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 400, y: 50), scale: 0.5)).id
        board.undo.removeAllActions()
        board.model.selection = CanvasSelection([.element(board.second), .screen(other)])
        board.model.adjusting { board.store.update(board.second.node) { $0.style.tint = RGBColor(hex: 0xFF0000) } }
        board.model.deleteSelection()
        #expect(board.store.treeScreen(other) == nil && board.store.placed(board.second) == nil)

        board.undo.undo()
        #expect(board.store.treeScreen(other) != nil && board.store.placed(board.second) != nil, "one Undo brings both back")
        #expect(board.tint(of: board.second) == RGBColor(hex: 0xFF0000), "with the colour")
    }

    /// The panel's run of changes is still one step.
    @Test func aRunOfChangesInThePanelIsOneStep() {
        let board = Board()
        board.model.selection = .element(board.first)
        for hex in [0x110000, 0x220000, 0x330000] {
            board.model.adjusting { board.store.update(board.first.node) { $0.style.tint = RGBColor(hex: UInt32(hex)) } }
        }
        board.undo.undo()
        #expect(board.tint(of: board.first) == RGBColor(hex: 0x000000))
        #expect(!board.undo.canUndo)
    }
}
