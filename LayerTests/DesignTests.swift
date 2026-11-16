import CoreGraphics
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
        let frame = try #require(model.selectedScreen)
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

        for part in ["design.json", "drawing.data", "images/\(picture.uuidString)", "QuickLook/Thumbnail.jpg"] {
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(part).path), "\(part) should be in the package")
        }
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
        #expect(document.current.content == DesignContent())
        #expect(document.current.drawing.strokes.isEmpty)

        model.store.addScreen(from: leftScreenSketch)
        let drawing = sampleFile().drawing
        model.drawingChanged(drawing)

        let snapshot = try document.snapshot(contentType: .layerDesign)
        #expect(snapshot.content.screens.map(\.name) == ["Screen 1"])
        #expect(snapshot.drawing == drawing)

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
        let code = SwiftUICodeGenerator.code(for: demoScreen())
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
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
