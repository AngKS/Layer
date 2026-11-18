import CoreGraphics
import os
import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import Layer

private func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, text: String? = nil) -> DesignElement {
    DesignElement(kind: kind, frame: CGRect(x: x, y: y, width: width, height: height), text: text ?? kind.placeholder, tint: Theme.accent)
}

/// The finished screen from the reference demo.
private func demoScreen() -> DesignScreen {
    DesignScreen(name: "Screen 1", origin: CGPoint(x: 400, y: 100), scale: 0.75, elements: [
        element(.button, 20, 744, 353, 50),
        element(.title, 82, 112, 228, 40),
        element(.image, 30, 184, 333, 368),
        element(.body, 48, 580, 297, 44),
    ])
}

/// A store wired to an undo manager that, like a test, isn't driven by a run loop.
@MainActor
private func makeStore() -> (store: DesignStore, undo: UndoManager) {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore()
    store.undoManager = undo
    return (store, undo)
}

/// Sketches of two phone screens side by side, and of a title near the top of a screen.
private let leftScreenSketch = CGRect(x: 470, y: 125, width: 270, height: 584)
private let rightScreenSketch = CGRect(x: 1000, y: 125, width: 270, height: 584)
private let titleSketch = CGRect(x: 150, y: 112, width: 96, height: 40)

private func center(_ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
}

private func isClose(_ a: CGPoint, _ b: CGPoint, within tolerance: CGFloat = 1) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

@Suite("Laying out elements")
struct ElementLayoutTests {
    @Test func newElementsTakeTheirStandardSizeCentredAtTheSketchedHeight() {
        let title = ElementLayout.frame(for: .title, sketch: titleSketch)
        #expect(title == CGRect(x: 82.5, y: 112, width: 228, height: 40))

        let image = ElementLayout.frame(for: .image, sketch: CGRect(x: 34, y: 186, width: 326, height: 364))
        #expect(image.size == CGSize(width: 333, height: 368))
        #expect(ElementLayout.isCentered(image))
    }

    @Test func elementsStayClearOfTheStatusBarAndHomeIndicator() {
        let high = ElementLayout.frame(for: .title, sketch: CGRect(x: 100, y: 5, width: 96, height: 30))
        #expect(high.minY >= DeviceFrame.iPhone.safeTop)

        let low = ElementLayout.frame(for: .button, sketch: CGRect(x: 20, y: 830, width: 340, height: 40))
        #expect(low.maxY <= DeviceFrame.iPhone.size.height - DeviceFrame.iPhone.safeBottom)
    }

    @Test func aScreenIsCentredOnItsSketchAndAsTallAsItWasDrawn() {
        let placement = ElementLayout.screenPlacement(for: leftScreenSketch)
        #expect(abs(placement.scale - 584.0 / 852.0) < 0.001)
        #expect(abs(placement.origin.x + 393 * placement.scale / 2 - leftScreenSketch.midX) <= 1)

        // Drawn while zoomed far out or far in, a screen can be much larger or smaller.
        #expect(ElementLayout.screenPlacement(for: CGRect(x: 0, y: 0, width: 900, height: 1900)).scale > 2)
        #expect(ElementLayout.screenPlacement(for: CGRect(x: 0, y: 0, width: 20, height: 40)).scale == 0.15)
    }

    @Test func movingSnapsToTheCentreLineAndMayLeaveTheScreen() {
        let frame = CGRect(x: 40, y: 300, width: 228, height: 40)
        #expect(ElementLayout.moved(frame, by: CGSize(width: 40, height: 0), snapsToCenter: true).minX == 82.5)
        #expect(ElementLayout.moved(frame, by: CGSize(width: 40, height: 0), snapsToCenter: false).minX == 80)
        #expect(ElementLayout.moved(frame, by: CGSize(width: -500, height: 900), snapsToCenter: true).origin == CGPoint(x: -460, y: 1200))
    }

    @Test func resizingDragsOneCornerAndKeepsAMinimumSize() {
        let frame = CGRect(x: 48, y: 580, width: 297, height: 44)
        let narrower = ElementLayout.resized(frame, from: .bottomRight, by: CGSize(width: -49, height: 8), kind: .body)
        #expect(narrower == CGRect(x: 48, y: 580, width: 248, height: 52))

        let collapsed = ElementLayout.resized(frame, from: .topLeft, by: CGSize(width: 900, height: 900), kind: .body)
        #expect(collapsed.size == CGSize(width: 32, height: 16))
        #expect(collapsed.maxX == frame.maxX)
    }

    @Test func spacingIsMeasuredToNeighboursAndScreenEdges() throws {
        let screen = demoScreen()
        let image = try #require(screen.elements.first { $0.kind == .image })
        let guides = SpacingGuides.measure(image, in: screen)
        #expect(guides.top.distance == 32)
        #expect(guides.bottom.distance == 28)
        #expect(guides.left.distance == 30)
        #expect(guides.right.distance == 30)
        #expect(guides.isCentered)
    }
}

@Suite("Showing the canvas")
struct ViewportTests {
    private let view = CGSize(width: 1210, height: 834)

    @Test func pointsConvertBetweenTheViewAndTheCanvasAndBack() {
        let viewport = Viewport(offset: CGPoint(x: 1000, y: 2000), scale: 2)
        #expect(viewport.canvasPoint(for: CGPoint(x: 100, y: 50)) == CGPoint(x: 550, y: 1025))
        #expect(viewport.viewPoint(for: CGPoint(x: 550, y: 1025)) == CGPoint(x: 100, y: 50))
        #expect(viewport.viewRect(for: CGRect(x: 550, y: 1025, width: 10, height: 20)) == CGRect(x: 100, y: 50, width: 20, height: 40))
        #expect(viewport.visibleRect(in: view) == CGRect(x: 500, y: 1000, width: 605, height: 417))
    }

    @Test func fittingShowsEverythingCentredWithoutZoomingPastFullSize() {
        let small = CGRect(x: 9000, y: 9000, width: 300, height: 400)
        let cozy = Viewport.fitting(small, in: view)
        #expect(cozy.scale == 1)
        #expect(isClose(cozy.canvasPoint(for: CGPoint(x: view.width / 2, y: view.height / 2)), center(small)))

        let wide = CGRect(x: 5000, y: 5000, width: 6000, height: 1000)
        let far = Viewport.fitting(wide, in: view)
        #expect(far.scale < 0.2)
        #expect(far.visibleRect(in: view).contains(wide))

        let vast = CGRect(x: 0, y: 0, width: 20_000, height: 20_000)
        #expect(Viewport.fitting(vast, in: view).scale == Viewport.zoomRange.lowerBound)
    }

    @Test func fittingKeepsToThePartOfTheViewLeftClear() {
        // A narrow window with two rows of bar across the top and controls along the bottom.
        let clear = CGRect(x: 0, y: 160, width: 374, height: 580)
        let phone = CGRect(x: 9000, y: 9000, width: 260, height: 575)
        let viewport = Viewport.fitting(phone, within: clear)
        #expect(viewport.scale < 1)
        #expect(clear.insetBy(dx: 11, dy: 11).contains(viewport.viewRect(for: phone)))
        #expect(isClose(viewport.viewPoint(for: center(phone)), CGPoint(x: clear.midX, y: clear.midY)))

        // With room to spare it stays at full size, in the middle of the clear part.
        let roomy = CGRect(x: 0, y: 94, width: 1210, height: 648)
        let full = Viewport.fitting(phone, within: roomy)
        #expect(full.scale == 1)
        #expect(isClose(full.viewPoint(for: center(phone)), CGPoint(x: roomy.midX, y: roomy.midY)))
    }
}

@Suite("Keeping the design")
@MainActor
struct DesignStoreTests {
    @Test func sketchesBecomeScreensAndElementsAndEachCanBeUndoneAndRedone() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        #expect(screen.name == "Screen 1")

        let sketch = screen.canvasRect(for: titleSketch)
        #expect(store.screen(under: sketch)?.id == screen.id)
        let title = try #require(store.addElement(.title, from: sketch, to: screen.id))
        #expect(title.text == "Title")
        #expect(title.frame == CGRect(x: 82.5, y: 112, width: 228, height: 40))

        undo.undo()
        #expect(store.screens.first?.elements.isEmpty == true)
        undo.undo()
        #expect(store.screens.isEmpty)
        #expect(!undo.canUndo)

        undo.redo()
        undo.redo()
        #expect(store.screens.first?.elements.map(\.id) == [title.id])
    }

    @Test func aGradualEditUndoesAsOneStep() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        let title = try #require(store.addElement(.title, from: screen.canvasRect(for: titleSketch), to: screen.id))
        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: title.id)

        store.beginEdit()
        for step in 1...20 {
            store.update(ref) { $0.frame.origin.y = 112 + CGFloat(step) }
        }
        store.endEdit()
        #expect(store.screens[0].elements[0].frame.minY == 132)

        undo.undo()
        #expect(store.screens[0].elements[0].frame.minY == 112)
        undo.redo()
        #expect(store.screens[0].elements[0].frame.minY == 132)
    }

    /// Undo pressed while a spoken command or a generation holds its step open. It used to
    /// take back the step before, and lose the command's first change with it; the command's
    /// close then put that earlier step back, so undo behaved as redo.
    @Test func undoWhileAnEditIsHeldTakesBackWhatItHasDoneSoFar() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        let title = try #require(store.addElement(.title, from: screen.canvasRect(for: titleSketch), to: screen.id))
        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: title.id)
        let before = store.content

        store.beginHeldEdit()
        store.update(ref) { $0.text = "One" }
        undo.undo()
        // The command's change so far is what goes; the title added before it stays.
        #expect(store.content == before)
        store.update(ref) { $0.text = "Two" }
        store.endHeldEdit()
        #expect(store.resolve(ref)?.element.text == "Two")

        undo.undo()
        #expect(store.content == before)
        undo.undo()
        #expect(store.screens.first?.elements.isEmpty == true)
    }

    @Test func redoWhileAnEditIsHeldStillRedoes() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        _ = try #require(store.addElement(.title, from: screen.canvasRect(for: titleSketch), to: screen.id))
        let withTitle = store.content
        undo.undo()

        store.beginHeldEdit()
        undo.redo()
        #expect(store.content == withTitle)
        store.updateScreen(screen.id) { $0.name = "Renamed" }
        store.endHeldEdit()
        undo.undo()
        #expect(store.content == withTitle)
    }

    /// The history moves on with every step made, undone or redone, and not otherwise.
    @Test func theHistoryMarkMovesWithEveryStep() throws {
        let (store, undo) = makeStore()
        let start = store.historyMark
        let screen = store.addScreen(from: leftScreenSketch)
        let afterAdd = store.historyMark
        #expect(afterAdd != start)
        store.setTitle("Quiet", undoable: false)
        #expect(store.historyMark == afterAdd)
        store.beginHeldEdit()
        store.updateScreen(screen.id) { $0.name = "One" }
        let inEdit = store.historyMark
        store.updateScreen(screen.id) { $0.name = "Two" }
        store.endHeldEdit()
        #expect(store.historyMark == inEdit, "a held edit is one step, however many changes")
        undo.undo()
        #expect(store.historyMark != inEdit)
    }

    @Test func anEditThatChangesNothingLeavesNoUndoStep() {
        let (store, undo) = makeStore()
        store.beginEdit()
        store.endEdit()
        #expect(!undo.canUndo)
    }

    @Test func everyChangeIsReportedIncludingUndo() {
        let (store, undo) = makeStore()
        var reported: [Int] = []
        store.onChange = { reported.append($0.screens.count) }

        store.addScreen(from: leftScreenSketch)
        undo.undo()
        #expect(reported == [1, 0])
    }

    @Test func movingAScreenTakesItsElementsWithIt() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        let title = try #require(store.addElement(.title, from: screen.canvasRect(for: titleSketch), to: screen.id))
        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: title.id)
        let before = try #require(store.resolve(ref)).placement.canvasRect(for: title.frame)

        store.updateScreen(screen.id) { $0.origin.x += 300 }
        let after = try #require(store.resolve(ref)).placement.canvasRect(for: title.frame)
        #expect(after == before.offsetBy(dx: 300, dy: 0))

        undo.undo()
        #expect(store.screens[0].origin == screen.origin)
    }

    @Test func anElementDroppedOffItsScreenFloatsWhereItWasDropped() throws {
        let (store, _) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        let title = try #require(store.addElement(.title, from: screen.canvasRect(for: titleSketch), to: screen.id))
        let onScreen = DesignStore.ElementRef(host: .screen(screen.id), element: title.id)

        store.update(onScreen) { $0.frame.origin.x += 900 }
        let dropped = try #require(store.resolve(onScreen))
        let droppedAt = dropped.placement.canvasRect(for: dropped.element.frame)

        let home = store.rehost(onScreen)
        #expect(home == DesignStore.ElementRef(host: .canvas, element: title.id))
        #expect(store.screens[0].elements.isEmpty)
        let floating = try #require(store.floating.first)
        #expect(floating.scale == screen.scale)
        #expect(floating.element.frame.size == title.frame.size)
        #expect(isClose(center(floating.canvasFrame), center(droppedAt)))
    }

    @Test func anElementDroppedOnAnotherScreenJoinsItAndTheMoveUndoes() throws {
        let (store, undo) = makeStore()
        let left = store.addScreen(from: leftScreenSketch)
        let right = store.addScreen(from: rightScreenSketch)
        let title = try #require(store.addElement(.title, from: left.canvasRect(for: titleSketch), to: left.id))
        let ref = DesignStore.ElementRef(host: .screen(left.id), element: title.id)

        // Drag it across to the middle of the other screen.
        let target = left.placement.localPoint(for: center(right.canvasFrame))
        store.beginEdit()
        store.update(ref) { $0.frame.origin = CGPoint(x: target.x - 114, y: target.y - 20) }
        let home = store.rehost(ref)
        store.endEdit()

        #expect(home == DesignStore.ElementRef(host: .screen(right.id), element: title.id))
        #expect(store.screens[0].elements.isEmpty)
        let moved = try #require(store.screens[1].elements.first)
        #expect(moved.frame.size == CGSize(width: 228, height: 40))
        #expect(isClose(center(right.canvasRect(for: moved.frame)), center(right.canvasFrame)))
        #expect(store.rehost(home) == home, "an element that hasn't moved stays where it lives")

        undo.undo()
        #expect(store.screens[0].elements.map(\.frame) == [title.frame])
        #expect(store.screens[1].elements.isEmpty)
    }

    @Test func aSymbolLandsOnTheScreenUnderItOrOnTheOpenCanvas() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)

        let onScreen = store.place(DesignStore.newElement(.symbol, symbol: "heart.fill"), centeredAt: center(screen.canvasFrame))
        #expect(onScreen.host == .screen(screen.id))
        let heart = try #require(store.resolve(onScreen))
        #expect(heart.element.symbol == "heart.fill")
        #expect(heart.element.frame.size == CGSize(width: 44, height: 44))
        #expect(isClose(center(heart.placement.canvasRect(for: heart.element.frame)), center(screen.canvasFrame)))

        let elsewhere = CGPoint(x: 3000, y: 2500)
        let onCanvas = store.place(DesignStore.newElement(.symbol, symbol: "star"), centeredAt: elsewhere)
        #expect(onCanvas.host == .canvas)
        #expect(isClose(center(try #require(store.floating.first).canvasFrame), elsewhere))

        store.delete(onCanvas)
        #expect(store.floating.isEmpty)
        undo.undo()
        #expect(store.floating.count == 1)
    }

    @Test func aDeviceFrameIsAddedAtItsOwnSizeAndElementsKeepTheirMarginsOnIt() throws {
        let (store, _) = makeStore()
        let iPad = try #require(DeviceFrame.all.first { $0.id == "ipad" })
        let screen = store.addScreen(iPad, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 0.5))
        #expect(screen.size == CGSize(width: 820, height: 1180))
        #expect(screen.canvasFrame == CGRect(x: 100, y: 100, width: 410, height: 590))

        // A button on a phone has 20-point margins; it keeps them on the wider screen.
        let button = try #require(store.addElement(.button, from: screen.canvasRect(for: CGRect(x: 100, y: 1000, width: 600, height: 60)), to: screen.id))
        #expect(button.frame.minX == 20)
        #expect(button.frame.width == 780)
        #expect(button.frame.maxY <= iPad.size.height - iPad.safeBottom)

        // Sketched screens are iPhones, and say nothing more about it in the file.
        #expect(store.addScreen(from: leftScreenSketch).deviceID == nil)
        #expect(DeviceFrame.named("no-such-device") == .iPhone)
    }

    @Test func aStickyNoteStaysOnTheCanvasEvenOverAScreen() throws {
        let (store, _) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        let note = store.place(DesignStore.newElement(.stickyNote), centeredAt: center(screen.canvasFrame))
        #expect(note.host == .canvas)
        #expect(store.rehost(note) == note)
        #expect(try #require(store.floating.first).element.tint == Theme.stickyNote)

        // Typed text does join the screen it is put on.
        let text = store.place(DesignStore.newElement(.text), centeredAt: center(screen.canvasFrame))
        #expect(text.host == .screen(screen.id))
        #expect(try #require(store.resolve(text)).element.text == "Text")
    }

    @Test func aBoardIsNamedAndCanvasSettingsChangeWithUndo() {
        let (store, undo) = makeStore()
        store.setTitle("  Checkout Flow \n")
        #expect(store.title == "Checkout Flow")
        store.setTitle("   ")
        #expect(store.title == nil)
        undo.undo()
        #expect(store.title == "Checkout Flow")

        store.updateCanvas { $0.gridStyle = .lines }
        #expect(store.canvas.gridStyle == .lines)
        undo.undo()
        #expect(store.canvas == CanvasSettings())
    }

    @Test func aNameTheAppSuggestsAddsNoUndoStep() {
        let (store, undo) = makeStore()
        store.setTitle("Suggested", undoable: false)
        #expect(store.title == "Suggested")
        #expect(!undo.canUndo)
    }

    @Test func theContentBoundsCoverEverythingInTheDesign() throws {
        let (store, _) = makeStore()
        #expect(store.contentBounds == nil)

        let screen = store.addScreen(from: leftScreenSketch)
        store.place(DesignStore.newElement(.symbol, symbol: "star"), centeredAt: CGPoint(x: 3000, y: 2500))
        let bounds = try #require(store.contentBounds)
        #expect(bounds.contains(screen.canvasFrame))
        #expect(bounds.contains(CGPoint(x: 3000, y: 2500)))

        store.deleteScreen(screen.id)
        #expect(store.screens.isEmpty)
    }
}

@Suite("Selecting and placing things")
@MainActor
struct AppModelTests {
    private func makeModel() -> (model: AppModel, undo: UndoManager) {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = AppModel(document: LayerDocument())
        model.store.undoManager = undo
        model.canvasSize = CGSize(width: 1210, height: 834)
        return (model, undo)
    }

    @Test func tappingAScreenSelectsItAndTappingEmptyCanvasLetsGo() {
        let (model, _) = makeModel()
        let screen = model.store.addScreen(from: leftScreenSketch)
        model.tool = .select
        model.viewport = Viewport(offset: CGPoint(x: 200, y: 100), scale: 2)

        model.canvasTapped(at: model.viewport.viewPoint(for: center(screen.canvasFrame)))
        #expect(model.selection == .screen(screen.id))
        #expect(model.selectedScreen?.id == screen.id)

        model.canvasTapped(at: model.viewport.viewPoint(for: CGPoint(x: 5000, y: 5000)))
        #expect(model.selection == nil)
    }

    @Test func textNotesFramesAndPicturesAreAddedInTheMiddleOfTheViewAndSelected() throws {
        let (model, _) = makeModel()
        model.viewport = Viewport(offset: CGPoint(x: 4000, y: 3000), scale: 1)
        let middle = model.viewport.canvasPoint(for: CGPoint(x: 605, y: 417))

        let iPad = try #require(DeviceFrame.all.first { $0.id == "ipad" })
        model.addFrame(iPad)
        let frame = try #require(model.store.screens.last)
        // A frame, unlike text, a note or a picture, comes in unselected.
        #expect(model.selection == nil)
        #expect(model.tool == .select)
        #expect(isClose(center(frame.canvasFrame), middle, within: 2))
        #expect(frame.canvasFrame.height <= 834 - 200, "the frame should fit in the view")

        model.addText()
        #expect(model.selectedElement?.element.kind == .text)
        #expect(model.selectedElement?.ref.host == .screen(frame.id))
        #expect(model.isEditingText)

        model.addStickyNote()
        #expect(model.selectedElement?.element.kind == .stickyNote)
        #expect(model.selectedElement?.ref.host == .canvas)

        let picture = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let png = try #require(picture.pngData())
        let prepared = try #require(ImageImport.prepare(png))
        model.addImage(prepared)
        let image = try #require(model.selectedElement?.element)
        #expect(image.kind == .image)
        #expect(image.frame.width / image.frame.height == 2)
        #expect(model.images.image(image.imageID) != nil)
        let imageID = try #require(image.imageID)
        #expect(model.document.current.images.keys.contains(imageID.uuidString))
    }

    @Test func aBoardGetsANameOnceItHasSomethingOnIt() async throws {
        let (model, _) = makeModel()
        #expect(model.store.title == nil)
        model.addFrame(.iPhone)
        for _ in 0..<200 where model.store.title == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let title = try #require(model.store.title)
        #expect(!title.isEmpty)

        // The name is suggested once; later additions leave it alone.
        model.store.setTitle("Mine")
        model.addText()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.store.title == "Mine")
    }

    @Test func aSymbolIsAddedInTheMiddleOfTheViewSelectedForDragging() throws {
        let (model, _) = makeModel()
        model.viewport = Viewport(offset: CGPoint(x: 4000, y: 3000), scale: 0.5)

        model.addSymbol("bolt.fill")
        #expect(model.tool == .select)
        let selected = try #require(model.selectedElement)
        #expect(selected.element.symbol == "bolt.fill")
        let middle = model.viewport.canvasPoint(for: CGPoint(x: 605, y: 417))
        #expect(isClose(center(selected.placement.canvasRect(for: selected.element.frame)), middle))
    }

    @Test func undoingOrDeletingTheSelectedThingClearsTheSelection() throws {
        let (model, undo) = makeModel()
        let screen = model.store.addScreen(from: leftScreenSketch)
        let title = try #require(model.store.addElement(.title, from: screen.canvasRect(for: titleSketch), to: screen.id))
        model.tool = .select
        model.selection = .element(.init(host: .screen(screen.id), element: title.id))

        undo.undo()
        #expect(model.selection == nil)

        model.selection = .screen(screen.id)
        model.deleteSelection()
        #expect(model.selection == nil)
        #expect(model.store.screens.isEmpty)
    }

    @Test func leavingTheSelectToolLetsGoOfTheSelection() {
        let (model, _) = makeModel()
        let screen = model.store.addScreen(from: leftScreenSketch)
        model.tool = .select
        model.selection = .screen(screen.id)
        model.tool = .draw
        #expect(model.selection == nil)
    }
}

@Suite("Saving and opening designs")
@MainActor
struct DesignFileTests {
    private func sampleFile() -> DesignFile {
        var content = DesignContent()
        content.screens = [demoScreen()]
        content.floating = [
            FloatingElement(
                element: DesignElement(kind: .symbol, frame: CGRect(x: 900, y: 700, width: 44, height: 44), text: "", tint: Theme.inkTint, symbol: "heart.fill"),
                scale: 0.75
            ),
        ]
        content.title = "Onboarding"
        content.canvas.gridStyle = .lines

        let points = SketchSamples.wave(CGRect(x: 100, y: 100, width: 200, height: 30), humps: 4).enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: 0)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: .now))
        return DesignFile(content: content, drawing: PKDrawing(strokes: [stroke]))
    }

    @Test func aDesignSurvivesBeingSavedAndOpened() throws {
        let file = sampleFile()
        let reopened = try DesignFile(wrapper: file.wrapper())
        #expect(reopened.content == file.content)
        #expect(reopened.drawing.strokes.count == 1)
        #expect(reopened.drawing.bounds == file.drawing.bounds)
        #expect(reopened.version == DesignFile.currentVersion)
    }

    @Test func aDesignIsWrittenAsAPackageWithItsPartsApart() throws {
        var file = sampleFile()
        let picture = UUID()
        file.content.floating[0].element.imageID = picture
        file.images = [picture.uuidString: Data([1, 2, 3])]
        file.preview = Data([9, 8, 7])
        file.fileName = "Onboarding"

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Onboarding.layer")
        try file.wrapper().write(to: url, options: .atomic, originalContentsURL: nil)

        // The ink is one file for each drawing, named by the drawing.
        let drawing = try #require(file.content.elements.first { $0.kind == .drawing })
        for part in ["design.json", "ink/\(drawing.id.uuidString)", "images/\(picture.uuidString)", "QuickLook/Thumbnail.jpg"] {
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(part).path), "\(part) should be in the package")
        }
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("drawing.data").path))
        let reopened = try DesignFile(wrapper: FileWrapper(url: url))
        #expect(reopened.content == file.content)
        #expect(reopened.drawing.bounds == file.drawing.bounds)
        #expect(reopened.images == file.images)
        #expect(reopened.preview == file.preview)
        #expect(reopened.fileName == "Onboarding")
    }

    @Test func savingAgainLeavesThePartsThatHaveNotChangedAlone() throws {
        var file = sampleFile()
        let picture = UUID()
        file.content.floating[0].element.imageID = picture
        file.images = [picture.uuidString: Data([1, 2, 3])]
        let first = try file.wrapper()

        // Only the design changes: the ink and the picture on disk are handed back as they are.
        file.content.title = "Renamed"
        let second = try file.wrapper(replacing: first)
        #expect(second.fileWrappers?["drawing.data"] === first.fileWrappers?["drawing.data"])
        #expect(second.fileWrappers?["images"]?.fileWrappers?[picture.uuidString] === first.fileWrappers?["images"]?.fileWrappers?[picture.uuidString])
        #expect(second.fileWrappers?["design.json"] !== first.fileWrappers?["design.json"])
        #expect(try DesignFile(wrapper: second).content.title == "Renamed")
    }

    @Test func aDesignSavedBeforeFloatingElementsAndSymbolsStillOpens() throws {
        let older = """
            {"version":1,"drawing":"\(PKDrawing().dataRepresentation().base64EncodedString())","content":{
              "accent":{"red":0.8,"green":0.42,"blue":0.34},"branchName":"feat/older","comments":[],
              "screens":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Screen 1","origin":[400,100],"scale":0.75,
                "elements":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"title","frame":[[82,112],[228,40]],
                  "text":"Title","tint":{"red":0.8,"green":0.42,"blue":0.34}}]}]}}
            """
        // Version 1 designs were a single file rather than a package.
        let file = try DesignFile(wrapper: FileWrapper(regularFileWithContents: Data(older.utf8)))
        #expect(file.content.title == nil)
        #expect(file.content.floating.isEmpty)
        let title = try #require(file.content.screens.first?.elements.first)
        #expect(title.kind == .title)
        #expect(title.symbol == nil)
    }

    @Test func picturesNothingShowsAreLeftOutOfTheSavedFile() throws {
        var file = sampleFile()
        let shown = UUID()
        file.content.floating[0].element.imageID = shown
        file.images = [shown.uuidString: Data([1, 2, 3]), UUID().uuidString: Data([4, 5, 6])]

        let reopened = try DesignFile(wrapper: file.wrapper())
        #expect(reopened.images == [shown.uuidString: Data([1, 2, 3])])
    }

    @Test func aFileFromANewerVersionIsRefusedRatherThanHalfRead() throws {
        var file = sampleFile()
        file.version = DesignFile.currentVersion + 1
        let saved = try file.wrapper()
        #expect(throws: DesignFile.ReadError.self) { try DesignFile(wrapper: saved) }
    }

    @Test func somethingThatIsNotADesignFailsToOpen() {
        #expect(throws: (any Error).self) { try DesignFile(wrapper: FileWrapper(regularFileWithContents: Data("not a design".utf8))) }
        #expect(throws: (any Error).self) { try DesignFile(wrapper: FileWrapper(directoryWithFileWrappers: [:])) }
    }

    @Test func aDocumentSavesWhatTheModelLastToldIt() throws {
        let document = LayerDocument()
        let model = AppModel(document: document)
        // Empty, apart from the model a new design starts with.
        var empty = DesignContent()
        empty.canvas.model = ModelPreferences.defaultChoice
        #expect(document.current.content == empty)
        #expect(document.current.drawing.strokes.isEmpty)

        model.store.addScreen(from: leftScreenSketch)
        // Ink drawn on the canvas becomes a drawing in the design.
        var sync = DrawingSync()
        let strokes = sampleFile().drawing.strokes
        model.inkChanged(sync.changes(for: strokes, in: model.store.content))

        let snapshot = try document.snapshot(contentType: .layerDesign)
        #expect(snapshot.content.screens.map(\.name) == ["Screen 1"])
        #expect(snapshot.content.floating.map(\.element.kind) == [.drawing])
        #expect(snapshot.drawing.strokes.map(\.key) == strokes.map(\.key))

        // What is written to disk opens as the same design.
        #expect(try DesignFile(wrapper: snapshot.wrapper()).content == snapshot.content)
    }

    @Test func openingADesignShowsItsContent() throws {
        let file = sampleFile()
        let document = LayerDocument()
        document.update { $0 = file }
        let model = AppModel(document: document)
        #expect(model.store.content == file.content)
    }
}

@Suite("Generating SwiftUI")
struct CodeGenerationTests {
    @Test func theDemoScreenBecomesAVerticalStackInReadingOrder() {
        let code = SwiftUICodeGenerator.code(for: demoScreen(), settings: CodeSettings(includesPreview: false))
        let expected = """
            import SwiftUI

            struct Screen1: View {
                var body: some View {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Title")
                            .font(.title.bold())
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        Image("photo")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 333, height: 368)
                            .clipShape(.rect(cornerRadius: 16))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                        Text("A short description goes here, a line or two that says what this is.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .frame(width: 297)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                        Spacer()
                        Button {
                        } label: {
                            Text("Continue")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Color(red: 0.80, green: 0.42, blue: 0.34), in: .capsule)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 53)
                    .padding(.bottom, 24)
                }
            }
            """
        #expect(code == expected)
        #expect(SwiftUICodeGenerator.fileName(for: demoScreen()) == "Screen1.swift")
    }

    @Test func aSymbolOnAScreenBecomesASystemImage() throws {
        var screen = DesignScreen(name: "Screen 2", origin: .zero, scale: 1)
        var heart = element(.symbol, 174.5, 200, 44, 44)
        heart.symbol = "heart.fill"
        heart.tint = Theme.inkTint
        screen.elements = [element(.title, 82.5, 112, 228, 40), heart]

        let lines = SwiftUICodeGenerator.code(for: screen).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let image = try #require(lines.firstIndex(of: #"Image(systemName: "heart.fill")"#))
        #expect(Array(lines[image...].prefix(6)) == [
            #"Image(systemName: "heart.fill")"#,
            ".resizable()",
            ".scaledToFit()",
            ".frame(width: 44, height: 44)",
            ".frame(maxWidth: .infinity)",
            ".padding(.top, 32)",
        ])
    }

    @Test func anElementsOwnStylingIsWrittenIntoItsCode() {
        var screen = DesignScreen(name: "Screen 3", origin: .zero, scale: 1)
        var title = element(.title, 82.5, 112, 228, 40)
        title.fontSize = 34
        title.fontWeight = .semibold
        title.textColor = RGBColor(hex: 0x3366FF)
        title.opacity = 0.5
        var button = element(.button, 20, 744, 353, 50)
        button.cornerRadius = 12
        screen.elements = [title, button]

        let lines = SwiftUICodeGenerator.code(for: screen).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains(".font(.system(size: 34, weight: .semibold))"))
        #expect(lines.contains(".foregroundStyle(Color(red: 0.20, green: 0.40, blue: 1.00))"))
        #expect(lines.contains(".opacity(0.5)"))
        #expect(lines.contains(".background(Color(red: 0.80, green: 0.42, blue: 0.34), in: .rect(cornerRadius: 12))"))
    }

    @Test func aScreenOfAnotherDeviceUsesThatDevicesEdges() {
        var screen = DesignScreen(name: "Tablet", origin: .zero, scale: 1, deviceID: "ipad")
        screen.elements = [element(.title, 296, 100, 228, 40)]
        let code = SwiftUICodeGenerator.code(for: screen)
        // The iPad's status bar keeps 24 points clear, and the title is centred on 820.
        #expect(code.contains(".padding(.top, 76)"))
        #expect(code.contains(".multilineTextAlignment(.center)"))
    }

    @Test func textIsEscapedAndAnEmptyScreenStillCompiles() {
        var screen = DesignScreen(name: "Screen 2", origin: .zero, scale: 1)
        #expect(SwiftUICodeGenerator.code(for: screen).contains("Color.clear"))

        screen.elements = [element(.title, 82, 112, 228, 40, text: "Say \"hi\"\\now")]
        #expect(SwiftUICodeGenerator.code(for: screen).contains(#"Text("Say \"hi\"\\now")"#))
    }

    @Test func codeIsColouredByTokenKind() {
        let tokens = SwiftHighlighter.tokens(in: "    .frame(width: 333, alignment: .leading) // Text(\"Hi\")")
        #expect(tokens.contains(.init(text: "frame", kind: .method)))
        #expect(tokens.contains(.init(text: "333", kind: .number)))
        #expect(tokens.contains(.init(text: "Text", kind: .type)))
        #expect(tokens.contains(.init(text: "\"Hi\"", kind: .string)))
        #expect(!tokens.contains { $0.text == "leading" && $0.kind != .plain })
        #expect(SwiftHighlighter.tokens(in: "struct Screen1: View {").first == .init(text: "struct", kind: .keyword))
    }
}

@Suite("Offering symbols")
struct SymbolCatalogTests {
    @Test func everySymbolOnOfferExistsAndIsOfferedOnce() {
        let names = SymbolCatalog.categories.flatMap(\.symbols)
        let missing = names.filter { UIImage(systemName: $0) == nil }
        #expect(missing.isEmpty, "not SF Symbols: \(missing)")
        #expect(Set(names).count == names.count, "offered twice: \(names.filter { name in names.count { $0 == name } > 1 })")
        #expect(names.count > 150)
    }

    @Test func searchNarrowsToNamesContainingEveryWord() {
        #expect(SymbolCatalog.matching("").count == SymbolCatalog.categories.count)
        let hearts = SymbolCatalog.matching("heart fill").flatMap(\.symbols)
        #expect(hearts == ["heart.fill"])
        #expect(SymbolCatalog.matching("no such symbol").isEmpty)
    }
}

@Suite("Naming a design's file after its board")
@MainActor
struct DesignFileNameTests {
    /// A folder with one saved design in it, named `name`.
    private func savedDesign(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name).appendingPathExtension("layer")
        try DesignFile().wrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }

    private func exists(_ name: String, beside url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(name).path)
    }

    /// Waits for a rename, which happens off the main thread.
    private func wait(for condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func aTitleBecomesAFileNameLessWhatFileNamesCannotHold() {
        #expect(DesignFileName.fileName(for: "Onboarding") == "Onboarding")
        #expect(DesignFileName.fileName(for: "  Sign in / Sign up: v2  ") == "Sign in - Sign up- v2")
        #expect(DesignFileName.fileName(for: ".hidden") == "hidden")
        #expect(DesignFileName.fileName(for: "Two\nlines") == "Two-lines")
        #expect(DesignFileName.fileName(for: String(repeating: "a", count: 300)).count == 100)
        #expect(DesignFileName.fileName(for: " / ") == "-")
    }

    @Test func aNameThatIsTakenGetsTheNextFreeNumber() {
        let folder = URL(fileURLWithPath: "/designs")
        let taken: Set = ["Onboarding.layer", "Onboarding 2.layer"]
        let url = DesignFileName.unused("Onboarding", extension: "layer", in: folder) { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Onboarding 3.layer")
        let free = DesignFileName.unused("Checkout", extension: "layer", in: folder) { taken.contains($0.lastPathComponent) }
        #expect(free.lastPathComponent == "Checkout.layer")
    }

    @Test func aNewDesignKeepsTheNameItWasGivenUntilItsBoardIsNamed() throws {
        let url = try savedDesign(named: "Untitled 3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(document: LayerDocument())
        model.fileURL = url
        #expect(model.store.title == nil)
        #expect(model.document.current.fileName == "Untitled 3")
        #expect(model.fileURL == url)
    }

    @Test func namingABoardRenamesItsFile() async throws {
        let url = try savedDesign(named: "Untitled")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(document: LayerDocument())
        model.fileURL = url

        model.store.setTitle("Onboarding")
        await wait { model.fileURL?.lastPathComponent == "Onboarding.layer" }
        #expect(model.fileURL?.lastPathComponent == "Onboarding.layer")
        #expect(exists("Onboarding.layer", beside: url))
        #expect(!exists("Untitled.layer", beside: url))
        #expect(model.document.current.fileName == "Onboarding")

        // Undoing the name is a change of name like any other.
        model.store.setTitle("Checkout")
        await wait { model.fileURL?.lastPathComponent == "Checkout.layer" }
        #expect(exists("Checkout.layer", beside: url))
        #expect(!exists("Onboarding.layer", beside: url))
    }

    @Test func aNameAnotherDesignHasGetsANumberWhichTheBoardTakesToo() async throws {
        let url = try savedDesign(named: "Untitled")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try DesignFile().wrapper().write(to: url.deletingLastPathComponent().appendingPathComponent("Onboarding.layer"), options: .atomic, originalContentsURL: nil)
        let model = AppModel(document: LayerDocument())
        model.fileURL = url

        model.store.setTitle("Onboarding")
        await wait { model.fileURL?.lastPathComponent == "Onboarding 2.layer" }
        #expect(model.fileURL?.lastPathComponent == "Onboarding 2.layer")
        #expect(model.store.title == "Onboarding 2")
    }

    @Test func aFileRenamedElsewhereNamesTheBoard() {
        let document = LayerDocument()
        document.update {
            $0.content.title = "Onboarding"
            $0.fileName = "Onboarding"
        }
        let model = AppModel(document: document)
        // The design opens from a file that has since been renamed in Files.
        model.fileURL = URL(fileURLWithPath: "/designs/Client pitch.layer")
        #expect(model.store.title == "Client pitch")
        #expect(document.current.fileName == "Client pitch")
    }

    @Test func aFileNamedBeforeItsBoardHadANameNamesTheBoard() throws {
        // Made, left empty, renamed in Files, opened again: the name is one somebody chose.
        let saved = try DesignFile().wrapper()
        let document = try LayerDocument(file: DesignFile(wrapper: saved))
        let model = AppModel(document: document)
        model.fileURL = URL(fileURLWithPath: "/designs/Client pitch.layer")
        #expect(model.store.title == "Client pitch")
    }

    @Test func aFileWithTheNameItWasCreatedWithDoesNotNameTheBoard() throws {
        for name in ["Untitled", "Untitled 12"] {
            let document = try LayerDocument(file: DesignFile(wrapper: DesignFile().wrapper()))
            let model = AppModel(document: document)
            model.fileURL = URL(fileURLWithPath: "/designs/\(name).layer")
            #expect(model.store.title == nil, "\(name) is not a name anybody chose")
        }
        #expect(DesignFileName.isUntitled("Untitled"))
        #expect(DesignFileName.isUntitled("Untitled 3"))
        #expect(!DesignFileName.isUntitled("Untitled Masterpiece"))
        #expect(!DesignFileName.isUntitled("Onboarding 2"))
        #expect(DesignFileName.withoutNumber("Sans titre 4") == "Sans titre")
        #expect(DesignFileName.withoutNumber("Onboarding") == "Onboarding")
        #expect(DesignFileName.withoutNumber("7") == "7")
    }

    @Test func aDesignWithANameButAnUntitledFileGetsItsFileRenamed() async throws {
        // Designs saved before files followed their boards: a name inside, "Untitled" outside.
        let url = try savedDesign(named: "Untitled 7")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = LayerDocument()
        document.update { $0.content.title = "iPhone Wireframe" }
        let model = AppModel(document: document)
        model.fileURL = url
        await wait { model.fileURL?.lastPathComponent == "iPhone Wireframe.layer" }
        #expect(exists("iPhone Wireframe.layer", beside: url))
        #expect(model.store.title == "iPhone Wireframe")
    }
}

@Suite("Designs in iCloud")
struct CloudFileTests {
    @Test func aVersionKeptAsideIsNamedForTheDeviceItCameFrom() {
        #expect(CloudFile.copyName(for: "Onboarding", savedOn: "Kah Shin’s iPad") == "Onboarding (from Kah Shin’s iPad)")
        #expect(CloudFile.copyName(for: "Onboarding", savedOn: "Studio/Mac: 2") == "Onboarding (from Studio-Mac- 2)")
        #expect(CloudFile.copyName(for: "Onboarding", savedOn: nil) == "Onboarding (other version)")
        #expect(CloudFile.copyName(for: "Onboarding", savedOn: "") == "Onboarding (other version)")
    }

    @Test func aDesignOutsideICloudIsReportedAsOnThisIPadOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("layer")
        try DesignFile().wrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .local = CloudFile.syncState(of: url) else {
            Issue.record("a file in a temporary folder is not in iCloud")
            return
        }
    }

    @Test func aDesignWithNoOtherVersionsHasNothingToSettle() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("layer")
        try DesignFile().wrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await CloudFile.keepConflictingVersions(of: url).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func everyStateSaysWhereTheDesignIsAndWhatToDoAboutIt() {
        #expect(SyncState.upToDate.title == "In iCloud Drive")
        #expect(SyncState.upToDate.detail == nil)
        #expect(SyncState.local(canUseICloud: false).detail?.contains("Sign in to iCloud") == true)
        #expect(SyncState.local(canUseICloud: true).detail?.contains("Move it to iCloud Drive") == true)
        #expect(SyncState.failed("The account is full.").detail == "The account is full.")
        #expect(SyncState.uploading.isInFlux && SyncState.waitingToUpload.isInFlux)
        #expect(!SyncState.upToDate.isInFlux && !SyncState.local(canUseICloud: true).isInFlux)
    }
}

@Suite("Keeping resources in check")
@MainActor
struct ResourceTests {
    @Test func theUndoHistoryIsCappedAtFiftySteps() {
        let store = DesignStore(content: DesignContent())
        let undo = UndoManager()
        // Each edit its own step, as each user action is in the app's run loop.
        undo.groupsByEvent = false
        store.undoManager = undo
        #expect(undo.levelsOfUndo == 50)
        for index in 0..<70 { store.setTitle("Board \(index)") }
        var steps = 0
        while undo.canUndo { undo.undo(); steps += 1 }
        #expect(steps == 50)
    }

    @Test func panningChangesTheOffsetAloneAndZoomingTheScaleAlone() {
        let model = AppModel(document: LayerDocument())
        model.viewport = Viewport(offset: CGPoint(x: 100, y: 200), scale: 1.5)
        #expect(model.scrollOffset == CGPoint(x: 100, y: 200))
        #expect(model.zoomScale == 1.5)
        model.viewport = Viewport(offset: CGPoint(x: 140, y: 200), scale: 1.5)
        #expect(model.zoomScale == 1.5)
        #expect(model.viewport == Viewport(offset: CGPoint(x: 140, y: 200), scale: 1.5))
    }

    @Test func aRefusalOrARamblingAnswerDoesNotNameABoard() {
        #expect(SketchEngine.isUsableTitle("Weekend in Salzburg"))
        #expect(SketchEngine.isUsableTitle("Checkout"))
        #expect(!SketchEngine.isUsableTitle("Sorry, I can't help with that."))
        #expect(!SketchEngine.isUsableTitle("I cannot assist with this request"))
        #expect(!SketchEngine.isUsableTitle("What is this board about?"))
        #expect(!SketchEngine.isUsableTitle("A board for planning a weekend trip to the mountains"))
        #expect(!SketchEngine.isUsableTitle(""))
    }

    @Test func picturesAreDecodedNoLargerThanTheyAreShownAndLetGoWhenNothingShowsThem() throws {
        // A 3000 × 1000 picture, as PNG data.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1000), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        }
        let data = try #require(big.pngData())

        let prepared = try #require(ImageImport.prepare(data))
        #expect(max(prepared.image.size.width * prepared.image.scale, prepared.image.size.height * prepared.image.scale) <= ImageImport.longestSide)

        let id = UUID()
        let library = ImageLibrary([id.uuidString: data])
        let decoded = try #require(library.image(id))
        #expect(max(decoded.size.width, decoded.size.height) <= ImageLibrary.decodedLongestSide)

        // Let go while nothing shows it; decoded again from its data when it is shown again.
        library.keepDecoded([])
        #expect(library.image(id) != nil)
    }
}

/// The system's own document, which saves only when it is told something changed: by the
/// undo manager it shares with the design. Stands in for the one `DocumentGroup` makes.
@MainActor
private func systemDocument(for model: AppModel, groupsByEvent: Bool = false) -> (system: UIDocument, undo: UndoManager) {
    let system = UIDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let undo = UndoManager()
    undo.groupsByEvent = groupsByEvent
    system.undoManager = undo
    model.store.undoManager = undo
    return (system, undo)
}

/// What an autosave does: the design is taken as it stands and written, and the system's
/// document has nothing left unsaved.
@MainActor
private func autosave(_ model: AppModel, _ system: UIDocument) throws {
    _ = try model.document.snapshot(contentType: .layerDesign)
    system.updateChangeCount(.cleared)
}

@Suite("Closing a design")
@MainActor
struct ClosingTests {
    /// A colour tapped in the format panel joins the step it opened until the panel's pause
    /// ends it. Saved meanwhile, and the design closed before the pause was over, the change
    /// after the save told the system nothing and was lost.
    @Test func aChangeInTheFormatPanelJustBeforeClosingIsSaved() async throws {
        let model = AppModel(document: LayerDocument())
        let (system, _) = systemDocument(for: model)
        model.store.addScreen(from: leftScreenSketch)
        model.adjusting { model.store.updateCanvas { $0.background = RGBColor(hex: 0xFF0000) } }
        #expect(system.hasUnsavedChanges)
        try autosave(model, system)

        model.adjusting { model.store.updateCanvas { $0.background = RGBColor(hex: 0x0000FF) } }
        await model.prepareToClose()

        #expect(system.hasUnsavedChanges)
        #expect(!model.store.isEditing)
        #expect(try model.document.snapshot(contentType: .layerDesign).content.canvas.background == RGBColor(hex: 0x0000FF))
    }

    /// The name settled at close, the file's name and the picture for the browser are
    /// written without an undo step: they still have to reach the disk.
    @Test func whatClosingWritesWithoutAnUndoStepIsSaved() throws {
        let model = AppModel(document: LayerDocument())
        let (system, undo) = systemDocument(for: model)
        model.store.addScreen(from: leftScreenSketch)
        try autosave(model, system)
        let mark = model.store.historyMark
        let couldUndo = undo.canUndo

        model.store.setTitle("Checkout", undoable: false)
        model.document.update { $0.fileName = "Checkout" }
        model.close()

        #expect(system.hasUnsavedChanges)
        // Told without a step of its own: the history is as it was.
        #expect(model.store.historyMark == mark)
        #expect(undo.canUndo == couldUndo)
    }

    @Test func aDesignOpenedAndClosedUntouchedIsNotSavedAgain() throws {
        let model = AppModel(document: LayerDocument(file: DesignFile()))
        let (system, _) = systemDocument(for: model)
        model.close()
        #expect(!system.hasUnsavedChanges)
    }

    /// Going to the background tells the system about the picture it drew, without
    /// touching the history: the redo stack and the oldest step of a full one are kept.
    @Test func leavingTheScreenKeepsRedoAndTheOldestStep() throws {
        let model = AppModel(document: LayerDocument())
        let (system, undo) = systemDocument(for: model)
        let start = model.store.content
        for step in 0..<DesignStore.undoLevels {
            model.store.setTitle("Board \(step)")
        }
        undo.undo()
        #expect(undo.canRedo)
        try autosave(model, system)
        model.document.update { $0.fileName = "Board" }

        model.leavingTheScreen()

        #expect(system.hasUnsavedChanges)
        #expect(undo.canRedo)
        undo.redo()
        for _ in 0..<DesignStore.undoLevels { undo.undo() }
        #expect(model.store.content == start)
    }

    /// The undo manager the system gives a design groups changes by event. Told outside any
    /// group, the system has to know at once, and undo must not gain an empty step.
    @Test func tellingTheSystemToSaveAddsNoStepToUndo() throws {
        let model = AppModel(document: LayerDocument(file: DesignFile()))
        let (system, undo) = systemDocument(for: model, groupsByEvent: true)
        model.store.markNeedsSaving()
        #expect(system.hasUnsavedChanges)
        #expect(!undo.canUndo)
        #expect(undo.groupsByEvent)
    }
}

/// The format panel makes a run of quick changes one step, ended by a pause. The pause
/// is the panel's own: it doesn't end an edit something else began meanwhile.
@Suite("Changes made in the format panel")
@MainActor
struct FormatPanelEditTests {
    /// Waits for the panel's pause to end the edit. Main-actor tests from other suites run
    /// in between, so a fixed sleep can come round before the pause has.
    private func pauseEnds(_ model: AppModel) async throws -> Bool {
        for _ in 0..<100 where model.store.isEditing {
            try await Task.sleep(for: .milliseconds(20))
        }
        return !model.store.isEditing
    }
    private func makeModel() -> (model: AppModel, undo: UndoManager, screen: DesignScreen) {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = AppModel(document: LayerDocument())
        model.store.undoManager = undo
        model.adjustmentPause = .milliseconds(20)
        return (model, undo, model.store.addScreen(from: leftScreenSketch))
    }

    @Test func thePanelsPauseEndsItsOwnEdit() async throws {
        let (model, undo, screen) = makeModel()
        let before = model.store.content
        model.adjusting { model.store.updateScreen(screen.id) { $0.name = "Checkout" } }
        model.adjusting { model.store.updateScreen(screen.id) { $0.name = "Checkout 2" } }
        #expect(model.store.isEditing)
        #expect(try await pauseEnds(model))
        undo.undo()
        #expect(model.store.content == before)
    }

    /// A drag begun just after a colour was tapped: the pause used to end the drag's edit
    /// halfway, and every later move of the drag was an undo step of its own.
    @Test func aDragBegunDuringThePanelsPauseIsStillOneStep() async throws {
        let (model, undo, screen) = makeModel()
        let before = model.store.content
        model.adjusting { model.store.updateScreen(screen.id) { $0.name = "Checkout" } }
        model.store.beginEdit()
        model.store.updateScreen(screen.id) { $0.origin.x += 10 }
        try await Task.sleep(for: .milliseconds(150))
        model.store.updateScreen(screen.id) { $0.origin.x += 10 }
        model.store.updateScreen(screen.id) { $0.origin.x += 10 }
        #expect(model.store.isEditing)
        model.store.endEdit()

        undo.undo()
        #expect(model.store.content == before)
    }

    /// A spoken command holds its step open. A panel change made just before it, or during
    /// it, used to leave the step open for good once the command ended: the panel's pause
    /// didn't end what it took for another's edit, and the hold left the step for the "edit
    /// by hand" the panel had begun. Every later change then joined that one step.
    @Test(arguments: [true, false])
    func aPanelChangeAroundASpokenCommandLeavesNoEditOpen(panelFirst: Bool) async throws {
        let (model, _, screen) = makeModel()
        let panel = { model.adjusting { model.store.updateScreen(screen.id) { $0.name = "Checkout" } } }
        if panelFirst {
            panel()
            model.store.beginHeldEdit()
        } else {
            model.store.beginHeldEdit()
            panel()
        }
        model.store.updateScreen(screen.id) { $0.origin.x += 10 }
        try await Task.sleep(for: .milliseconds(150))
        model.store.endHeldEdit()
        #expect(try await pauseEnds(model))

        // The next change is a step of its own.
        let mark = model.store.historyMark
        model.store.updateScreen(screen.id) { $0.origin.y += 10 }
        #expect(model.store.historyMark == mark + 1)
    }

    /// The command ends before the panel's pause: the step the hold left open for the
    /// panel's edit by hand is the panel's to end.
    @Test func aPanelChangeInACommandThatEndsBeforeThePauseLeavesNoEditOpen() async throws {
        let (model, _, screen) = makeModel()
        model.adjustmentPause = .milliseconds(200)
        model.store.beginHeldEdit()
        model.adjusting { model.store.updateScreen(screen.id) { $0.name = "Checkout" } }
        model.store.updateScreen(screen.id) { $0.origin.x += 10 }
        model.store.endHeldEdit()
        #expect(model.store.isEditing, "the panel's edit goes on until its pause")
        #expect(try await pauseEnds(model))

        let mark = model.store.historyMark
        model.store.updateScreen(screen.id) { $0.origin.y += 10 }
        #expect(model.store.historyMark == mark + 1)
    }

    @Test func aChangeInThePanelDuringADragLeavesTheDragToEndIt() async throws {
        let (model, undo, screen) = makeModel()
        let before = model.store.content
        model.store.beginEdit()
        model.store.updateScreen(screen.id) { $0.origin.x += 10 }
        model.adjusting { model.store.updateScreen(screen.id) { $0.name = "Checkout" } }
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.store.isEditing)
        model.store.updateScreen(screen.id) { $0.origin.x += 10 }
        model.store.endEdit()

        undo.undo()
        #expect(model.store.content == before)
    }
}

/// Checks of the file overlap: the system says the file changed several times around a
/// conflict and the save after it (C-I7).
@Suite("Checking a design's file")
@MainActor
struct FileCheckTests {
    /// Two checks settling the same conflict at once both copied its versions, as
    /// "Name (from iPad)" and "Name (from iPad) 2".
    @Test func conflictsAreSettledOneAtATime() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).layer")
        let inFlight = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
        let resolve: @Sendable (URL) -> [String] = { _ in
            inFlight.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            Thread.sleep(forTimeInterval: 0.05)
            inFlight.withLock { $0.now -= 1 }
            return []
        }
        async let first = CloudFile.keepConflictingVersions(of: url, resolving: resolve)
        async let second = CloudFile.keepConflictingVersions(of: url, resolving: resolve)
        _ = await (first, second)
        #expect(inFlight.withLock { $0.most } == 1)
    }

    /// A check cut short by the next one still says what it kept aside.
    @Test func versionsKeptByACheckCutShortAreStillMentioned() async throws {
        let model = AppModel(document: LayerDocument())
        defer { model.close() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        model.keepConflictingVersions = { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            guard call == 1 else { return [] }
            try? await Task.sleep(for: .milliseconds(100))
            return ["Board (from iPad)"]
        }
        model.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).layer")
        model.checkFile()
        for _ in 0..<40 where model.keptVersionsNotice == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.keptVersionsNotice?.contains("Board (from iPad)") == true)
    }
}

/// Generated code for elements that are turned.
struct TurnedCodeTests {
    private func lines(of screen: DesignScreen, settings: CodeSettings = CodeSettings(includesPreview: false)) -> [String] {
        SwiftUICodeGenerator.code(for: screen, settings: settings).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func screen(_ elements: [DesignElement]) -> DesignScreen {
        DesignScreen(name: "Screen 1", origin: .zero, scale: 1, elements: elements)
    }

    private func turned(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, by degrees: Double?) -> DesignElement {
        var item = element(kind, x, y, width, height)
        item.rotation = degrees
        return item
    }

    @Test func anUprightElementHasNoTurnInItsCode() {
        let screen = screen([element(.button, 40, 300, 200, 50)])
        for layout in [CodeSettings.Layout.stack, .absolute] {
            let code = SwiftUICodeGenerator.code(for: screen, settings: CodeSettings(layout: layout, includesPreview: false))
            #expect(!code.contains(".rotationEffect"))
        }
    }

    @Test func exactPositionsTurnBetweenTheFrameAndTheOffset() throws {
        let lines = lines(of: screen([turned(.button, 40, 300, 200, 50, by: 30)]), settings: CodeSettings(layout: .absolute, includesPreview: false))
        #expect(lines.filter { $0.hasPrefix(".rotationEffect") } == [".rotationEffect(.degrees(30))"])
        let frame = try #require(lines.firstIndex { $0.hasPrefix(".frame(width:") })
        let turn = try #require(lines.firstIndex(of: ".rotationEffect(.degrees(30))"))
        let offset = try #require(lines.firstIndex { $0.hasPrefix(".offset(x:") })
        #expect(frame < turn && turn < offset)
    }

    @Test func aStackTurnsAnElementInPlaceBeforeItIsPlaced() throws {
        // A full-width title sets the margin at 20, so the button is inset from it.
        let lines = lines(of: screen([element(.title, 20, 100, 353, 40), turned(.button, 60, 300, 200, 50, by: 15)]))
        let frame = try #require(lines.firstIndex { $0.hasPrefix(".frame(width:") })
        let turn = try #require(lines.firstIndex(of: ".rotationEffect(.degrees(15))"))
        let placement = try #require(lines.firstIndex { $0.hasPrefix(".padding(.leading,") })
        #expect(frame < turn && turn < placement)
    }

    @Test func aFullWidthElementStillTurnsInAStack() {
        let lines = lines(of: screen([turned(.button, 0, 300, 393, 50, by: 5)]))
        #expect(lines.filter { $0 == ".rotationEffect(.degrees(5))" }.count == 1)
    }

    @Test func elementsSideBySideTurnInTheirRow() throws {
        let lines = lines(of: screen([
            turned(.button, 20, 300, 150, 50, by: 10),
            element(.button, 220, 300, 150, 50),
        ]))
        #expect(lines.filter { $0 == ".rotationEffect(.degrees(10))" }.count == 1)
        // Each line's own indent tells where the HStack block ends.
        let raw = SwiftUICodeGenerator.code(for: screen([
            turned(.button, 20, 300, 150, 50, by: 10),
            element(.button, 220, 300, 150, 50),
        ]), settings: CodeSettings(includesPreview: false)).split(separator: "\n").map(String.init)
        let open = try #require(raw.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("HStack") })
        let indent = raw[open].prefix { $0 == " " }
        let close = try #require(raw[open...].firstIndex { $0 == indent + "}" })
        let turn = try #require(raw.firstIndex { $0.contains(".rotationEffect(.degrees(10))") })
        #expect(open < turn && turn < close)
    }

    @Test func aHalfDegreeIsWrittenAsItIs() {
        let lines = lines(of: screen([turned(.button, 40, 300, 200, 50, by: 22.5)]), settings: CodeSettings(layout: .absolute, includesPreview: false))
        #expect(lines.contains(".rotationEffect(.degrees(22.5))"))
    }
}
