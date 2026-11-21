import CoreGraphics
import Foundation
import PencilKit
import Testing
import UIKit
@testable import Layer

private func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> DesignElement {
    DesignElement(kind: kind, frame: CGRect(x: x, y: y, width: width, height: height), text: kind.placeholder, tint: Theme.accent)
}

/// A phone screen at (100, 100), drawn at full size, holding a button, with a sticky note on
/// the open canvas beside it. The view shows the canvas unscrolled and unzoomed, so a point
/// in the view is the same point on the canvas.
@MainActor
private struct HitBoard {
    let model: AppModel
    let screen: DesignScreen.ID
    let button: DesignStore.ElementRef
    let note: DesignStore.ElementRef

    var store: DesignStore { model.store }

    init() {
        model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 1)).id
        button = model.store.setElements([element(.button, 20, 300, 353, 50)], on: screen, replacing: true)[0]
        note = model.store.addFloating(element(.stickyNote, 600, 100, 140, 130), scale: 1)
    }

    /// The middle of something, in the view.
    func middle(of thing: CanvasSelection) -> CGPoint {
        let frame = store.canvasFrame(of: thing) ?? .null
        return model.viewport.viewPoint(for: CGPoint(x: frame.midX, y: frame.midY))
    }
}

/// What a touch or the Pencil's hover lands on is what is drawn there: a hidden element
/// isn't drawn, so it can't be hovered, tapped or rested on (audit C2).
@MainActor
@Suite("Hit testing hidden things")
struct HiddenHitTestTests {
    @Test func aHiddenElementOnAScreenIsLookedThrough() {
        let board = HitBoard()
        let point = board.middle(of: .element(board.button))
        #expect(board.model.hoverTarget(at: point) == .element(board.button))
        board.model.toggleHidden(board.button)
        #expect(board.model.hoverTarget(at: point) == .screen(board.screen))
        #expect(board.model.hoverTarget(at: point, skippingDrawings: true) == .screen(board.screen))
    }

    @Test func aHiddenElementOnTheCanvasIsLookedThrough() {
        let board = HitBoard()
        let point = board.middle(of: .element(board.note))
        board.model.toggleHidden(board.note)
        #expect(board.model.hoverTarget(at: point) == nil)
    }

    /// Locked, a drawing is picked by its frame; hidden as well, it isn't drawn at all.
    @Test func aHiddenLockedDrawingIsLookedThrough() {
        let board = HitBoard()
        var ink = DesignStore.newElement(.drawing)
        ink.frame = CGRect(x: 100, y: 380, width: 300, height: 80)
        ink.isLocked = true
        let drawing = board.store.addFloating(ink, scale: 1)
        let point = board.middle(of: .element(board.button))
        #expect(board.model.hoverTarget(at: point) == .element(drawing))
        board.store.update(drawing) { $0.isHidden = true }
        #expect(board.model.hoverTarget(at: point) == .element(board.button))
    }

    /// With the palette up, a finger tap reaches the model for elements too.
    @Test func aFingerTapInDrawDoesntPickAHiddenElement() {
        let board = HitBoard()
        board.model.toggleHidden(board.button)
        board.model.tool = .draw
        board.model.canvasTapped(at: board.middle(of: .element(board.button)))
        #expect(board.model.selection == .screen(board.screen))
    }

    /// A finger resting where a hidden element is rests on the screen under it.
    @Test func aFingerRestingOnAHiddenElementDoesntAddIt() {
        let board = HitBoard()
        board.model.toggleHidden(board.button)
        board.model.tool = .select
        let resting = board.middle(of: .element(board.button))
        board.model.restingFingers = { [resting] }
        board.model.pick(.element(board.note))
        #expect(board.model.selection?.contains(.element(board.button)) == false)
        #expect(board.model.selection == CanvasSelection([.screen(board.screen), .element(board.note)]))
    }

    /// With frame names off, the strip a name would be drawn in is only canvas (audit C14).
    @Test func aScreensNameStripIsOnlyThereWhileNamesAreShown() {
        let board = HitBoard()
        let strip = board.store.screen(board.screen)?.labelFrame ?? .null
        let point = board.model.viewport.viewPoint(for: CGPoint(x: strip.midX, y: strip.midY))
        #expect(board.model.hoverTarget(at: point) == .screen(board.screen))
        board.store.updateCanvas { $0.showsFrameNames = false }
        #expect(board.model.hoverTarget(at: point) == nil)
    }
}
