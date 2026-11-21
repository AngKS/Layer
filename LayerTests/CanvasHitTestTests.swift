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

/// Ink is drawn over every element, and hover and a tap with the palette up already pick the
/// drawing where its ink crosses an element. A finger in Select, which lands on the element's
/// own target first, does the same: what it picks or moves is what is drawn on top (audit C3).
@MainActor
@Suite("Ink over an element")
struct InkOverAnElementTests {
    /// A line of ink drawn with a pen straight across the board's button, through its middle.
    private func inkAcrossTheButton(on board: HitBoard) throws -> (coordinator: InkCanvas.Coordinator, drawing: DesignStore.ElementRef) {
        let coordinator = InkCanvas.Coordinator(model: board.model)
        board.model.ink = coordinator
        let middle = board.middle(of: .element(board.button))
        coordinator.appendInk([[CGPoint(x: middle.x - 120, y: middle.y), CGPoint(x: middle.x + 120, y: middle.y)]], ink: PKInk(.pen, color: .black), width: 4)
        let drawing = try #require(board.store.floating.first { $0.element.kind == .drawing })
        return (coordinator, .init(host: .canvas, element: drawing.id))
    }

    @Test func aTapOnInkOverAnElementPicksTheDrawing() throws {
        let board = HitBoard()
        let (coordinator, drawing) = try inkAcrossTheButton(on: board)
        board.model.tool = .select
        let middle = board.middle(of: .element(board.button))
        // Hover already finds the drawing there.
        #expect(board.model.hoverTarget(at: middle) == .element(drawing))

        board.model.targetTapped(.element(board.button), at: middle)
        #expect(board.model.selection == .element(drawing))
        // Off the ink, the button's own target picks the button.
        board.model.targetTapped(.element(board.button), at: CGPoint(x: middle.x, y: middle.y + 22))
        #expect(board.model.selection == .element(board.button))
        _ = coordinator
    }

    @Test func aDragFromInkOverAnElementMovesTheDrawing() throws {
        let board = HitBoard()
        let (coordinator, drawing) = try inkAcrossTheButton(on: board)
        board.model.tool = .select
        board.store.updateCanvas { $0.snapsToGuides = false }
        let drags = CanvasDrags()
        board.model.drags = drags
        let owner = CanvasDrags.Owner()
        let found = try #require(board.store.resolve(board.button))
        let screen = board.store.screen(board.screen)
        let buttonBefore = board.store.canvasFrame(of: .element(board.button))
        let inkBefore = try #require(board.store.canvasFrame(of: .element(drawing)))
        let start = board.middle(of: .element(board.button))
        let undo = UndoManager()
        undo.groupsByEvent = false
        board.store.undoManager = undo
        let mark = board.store.historyMark

        for step in 1...4 {
            drags.moveOnTarget(board.button, element: found.element, placement: found.placement, on: screen, by: CGSize(width: 10 * step, height: 0), startingAt: start, owner: owner, model: board.model)
        }
        drags.dropOnTarget(board.button, startingAt: start, owner: owner, model: board.model)

        #expect(board.store.canvasFrame(of: .element(board.button)) == buttonBefore)
        let inkAfter = try #require(board.store.canvasFrame(of: .element(drawing)))
        #expect(abs(inkAfter.minX - (inkBefore.minX + 40)) < 0.5)
        #expect(board.model.selection == .element(drawing))
        // The whole drag is one step, which undo takes back.
        #expect(board.store.historyMark == mark + 1)
        undo.undo()
        #expect(board.store.canvasFrame(of: .element(drawing)) == inkBefore)
        _ = coordinator
    }

    /// The drawing found under a drag's start is kept for that drag alone. A later drag on the
    /// same target from exactly the same point, where the ink no longer is, moves the
    /// element: it moved the drawing it had found before (review m5).
    @Test func aLaterDragFromTheSamePointLooksAgain() throws {
        let board = HitBoard()
        let (coordinator, drawing) = try inkAcrossTheButton(on: board)
        board.model.tool = .select
        board.store.updateCanvas { $0.snapsToGuides = false }
        let drags = CanvasDrags()
        board.model.drags = drags
        let owner = CanvasDrags.Owner()
        let found = try #require(board.store.resolve(board.button))
        let screen = board.store.screen(board.screen)
        let start = board.middle(of: .element(board.button))

        // Drawing taken well away from the button.
        drags.moveOnTarget(board.button, element: found.element, placement: found.placement, on: screen, by: CGSize(width: 0, height: 200), startingAt: start, owner: owner, model: board.model)
        drags.dropOnTarget(board.button, startingAt: start, owner: owner, model: board.model)
        let inkMoved = board.store.canvasFrame(of: .element(drawing))
        let buttonBefore = try #require(board.store.canvasFrame(of: .element(board.button)))

        let now = try #require(board.store.resolve(board.button))
        drags.moveOnTarget(board.button, element: now.element, placement: now.placement, on: screen, by: CGSize(width: 30, height: 0), startingAt: start, owner: owner, model: board.model)
        drags.dropOnTarget(board.button, startingAt: start, owner: owner, model: board.model)
        #expect(board.store.canvasFrame(of: .element(drawing)) == inkMoved)
        let buttonAfter = try #require(board.store.canvasFrame(of: .element(board.button)))
        #expect(abs(buttonAfter.minX - (buttonBefore.minX + 30)) < 0.5)
        _ = coordinator
    }

    /// Off the ink, a drag on the element's target moves the element, as before.
    @Test func aDragOffTheInkMovesTheElement() throws {
        let board = HitBoard()
        let (coordinator, drawing) = try inkAcrossTheButton(on: board)
        board.model.tool = .select
        board.store.updateCanvas { $0.snapsToGuides = false }
        let drags = CanvasDrags()
        board.model.drags = drags
        let owner = CanvasDrags.Owner()
        let found = try #require(board.store.resolve(board.button))
        let screen = board.store.screen(board.screen)
        let buttonBefore = try #require(board.store.canvasFrame(of: .element(board.button)))
        let inkBefore = board.store.canvasFrame(of: .element(drawing))
        let middle = board.middle(of: .element(board.button))
        let start = CGPoint(x: middle.x, y: middle.y + 22)

        drags.moveOnTarget(board.button, element: found.element, placement: found.placement, on: screen, by: CGSize(width: 30, height: 0), startingAt: start, owner: owner, model: board.model)
        drags.dropOnTarget(board.button, startingAt: start, owner: owner, model: board.model)

        #expect(board.store.canvasFrame(of: .element(drawing)) == inkBefore)
        let buttonAfter = try #require(board.store.canvasFrame(of: .element(board.button)))
        #expect(abs(buttonAfter.minX - (buttonBefore.minX + 30)) < 0.5)
        #expect(board.model.selection == .element(board.button))
        _ = coordinator
    }
}

extension HostedWindowSuites {
    /// The canvas takes first responder, for the palette and the system's undo gestures, when the
    /// tool, the palette or the window changes. Work done in the background, a sketch converted or
    /// dissolving, mustn't take it from a field being typed in (audit C5).
    @MainActor
    @Suite("The canvas and the keyboard")
    struct CanvasFocusTests {
        @Test func aSketchTakenAwayLeavesTheKeyboardWithTheFieldBeingTypedIn() async throws {
            let model = AppModel(document: LayerDocument())
            let coordinator = InkCanvas.Coordinator(model: model)
            model.ink = coordinator
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            let container = UIView(frame: window.bounds)
            let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
            window.addSubview(container)
            window.addSubview(field)
            window.makeKeyAndVisible()
            defer {
                field.resignFirstResponder()
                coordinator.hidePalette()
                window.isHidden = true
            }
            for canvas in coordinator.canvases {
                canvas.frame = container.bounds
                container.addSubview(canvas)
            }
            // Coming to the window, the canvas takes first responder.
            #expect(coordinator.documentCanvas.isFirstResponder)

            // A name is being typed when a rejected sketch dissolves, and when a conversion lands.
            #expect(field.becomeFirstResponder())
            coordinator.removeSketch([])
            #expect(field.isFirstResponder)
            coordinator.clearSketch()
            #expect(field.isFirstResponder)

            // Typing over, picking a tool takes first responder again.
            field.resignFirstResponder()
            coordinator.apply(.select)
            #expect(coordinator.documentCanvas.isFirstResponder)
        }
    }
}

extension HostedWindowSuites {
    /// In Draw the palette shows only while the canvas is first responder, so it goes while a
    /// field has the keyboard. When typing ends it comes back: the canvas takes first responder
    /// again, but never from a field still being typed in (audit C5, follow-up).
    @MainActor
    @Suite("The palette and typing")
    struct PaletteAndTypingTests {
        @Test func thePaletteComesBackWhenTypingEndsInDraw() async throws {
            let model = AppModel(document: LayerDocument())
            let coordinator = InkCanvas.Coordinator(model: model)
            model.ink = coordinator
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            let container = UIView(frame: window.bounds)
            let name = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
            let note = UITextView(frame: CGRect(x: 20, y: 80, width: 200, height: 80))
            window.addSubview(container)
            window.addSubview(name)
            window.addSubview(note)
            window.makeKeyAndVisible()
            defer {
                name.resignFirstResponder()
                note.resignFirstResponder()
                coordinator.hidePalette()
                window.isHidden = true
            }
            for canvas in coordinator.canvases {
                canvas.frame = container.bounds
                container.addSubview(canvas)
            }
            coordinator.apply(.draw)
            #expect(coordinator.documentCanvas.isFirstResponder)

            // While a name is typed the palette is away, and stays away whatever the canvas does.
            #expect(name.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(50))
            coordinator.removeSketch([])
            try await Task.sleep(for: .milliseconds(50))
            #expect(name.isFirstResponder)
            #expect(!coordinator.documentCanvas.isFirstResponder)

            // Typing goes on in another field: still nothing for the canvas.
            #expect(note.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(50))
            #expect(note.isFirstResponder)
            #expect(!coordinator.documentCanvas.isFirstResponder)

            // The keyboard is put away: the canvas, and its palette, are back.
            note.resignFirstResponder()
            try await Task.sleep(for: .milliseconds(50))
            #expect(coordinator.documentCanvas.isFirstResponder, "the palette should be back once typing ends in Draw")
        }

        /// A tool picked, or a panel's sheet coming and going, while a field has the keyboard
        /// leaves it there: adding from the library puts Draw away, and so do a call starting
        /// and the window changing width (review m1). The palette comes back as typing ends.
        @Test func aToolChangeWhileTypingLeavesTheKeyboard() async throws {
            let model = AppModel(document: LayerDocument())
            let coordinator = InkCanvas.Coordinator(model: model)
            model.ink = coordinator
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            let container = UIView(frame: window.bounds)
            let search = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
            window.addSubview(container)
            window.addSubview(search)
            window.makeKeyAndVisible()
            defer {
                search.resignFirstResponder()
                coordinator.hidePalette()
                window.isHidden = true
            }
            for canvas in coordinator.canvases {
                canvas.frame = container.bounds
                container.addSubview(canvas)
            }
            coordinator.apply(.draw)
            #expect(search.becomeFirstResponder())

            coordinator.apply(.select)
            #expect(search.isFirstResponder)
            coordinator.apply(.draw)
            #expect(search.isFirstResponder)
            coordinator.setHidesPalette(true)
            coordinator.setHidesPalette(false)
            #expect(search.isFirstResponder)

            search.resignFirstResponder()
            try await Task.sleep(for: .milliseconds(50))
            #expect(coordinator.documentCanvas.isFirstResponder, "the palette should be back once typing ends in Draw")
        }

        /// Out of Draw there is no palette to bring back, and the canvas is left as it is.
        @Test func typingEndingOutOfDrawLeavesTheCanvasAlone() async throws {
            let model = AppModel(document: LayerDocument())
            let coordinator = InkCanvas.Coordinator(model: model)
            model.ink = coordinator
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            let container = UIView(frame: window.bounds)
            let name = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
            window.addSubview(container)
            window.addSubview(name)
            window.makeKeyAndVisible()
            defer {
                name.resignFirstResponder()
                coordinator.hidePalette()
                window.isHidden = true
            }
            for canvas in coordinator.canvases {
                canvas.frame = container.bounds
                container.addSubview(canvas)
            }
            coordinator.apply(.select)
            #expect(name.becomeFirstResponder())
            name.resignFirstResponder()
            try await Task.sleep(for: .milliseconds(50))
            #expect(!coordinator.documentCanvas.isFirstResponder)
        }
    }
}

/// A glide of the viewport, zooming to fit or moved by voice, gives way to a finger that
/// starts to pan meanwhile. It went on under the finger, and on its last frame jumped to
/// where it had been going, throwing the pan away (audit C10).
@MainActor
@Suite("A glide and a finger")
struct GlideAndFingerTests {
    /// Driven by hand, a frame at a time, so that the display link can't finish the glide
    /// first or fail to start it: the test fails without the fix, whatever the load.
    @Test func aPanStartedDuringAGlideStopsItAndSettlesTheZoom() {
        let model = AppModel(document: LayerDocument())
        let coordinator = InkCanvas.Coordinator(model: model)
        model.ink = coordinator
        coordinator.zoom(to: 2)
        #expect(coordinator.isGliding)
        // A frame of the glide, part of the way, as its display link sets it.
        coordinator.documentCanvas.zoomScale = 1.4
        coordinator.scrollViewDidZoom(coordinator.documentCanvas)
        #expect(abs(model.zoomScale - 1.4) < 0.001)
        #expect(model.settledScale == 1)

        coordinator.scrollViewWillBeginDragging(coordinator.documentCanvas)
        #expect(!coordinator.isGliding, "the glide went on under the finger")
        // Where it stopped is where the canvas is drawn for: shadows and sharp text come back
        // (review I2). Only the glide's last frame, or a pinch's end, settled it.
        #expect(model.settledScale == model.zoomScale)
    }

    /// Left alone, the glide arrives.
    @Test func aGlideLeftAloneArrives() async throws {
        let model = AppModel(document: LayerDocument())
        let coordinator = InkCanvas.Coordinator(model: model)
        model.ink = coordinator
        coordinator.zoom(to: 2)
        // 0.3 s, on the display's clock, which a busy main thread can hold up.
        for _ in 0..<100 where model.zoomScale != 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.zoomScale == 2)
    }
}
