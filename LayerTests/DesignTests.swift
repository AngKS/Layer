import CoreGraphics
import os
import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import Layer

private func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, text: String? = nil) -> LayerNode {
    .leaf(kind, frame: CGRect(x: x, y: y, width: width, height: height), text: text ?? kind.placeholder, tint: Theme.accent)
}

/// What the finished screen from the reference demo holds.
private func demoElements() -> [LayerNode] {
    [
        element(.button, 20, 744, 353, 50),
        element(.title, 82, 112, 228, 40),
        element(.image, 30, 184, 333, 368),
        element(.body, 48, 580, 297, 44),
    ]
}

/// The finished screen from the reference demo, on a free root.
private func demoScreen() -> TreeScreen {
    var root = LayerNode(kind: .group)
    root.children = demoElements()
    return TreeScreen(name: "Screen 1", origin: CGPoint(x: 400, y: 100), scale: 0.75, deviceID: nil, root: root)
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
        let elements = demoElements()
        let image = try #require(elements.first { $0.kind == .image })
        let others = elements.filter { $0.id != image.id && !$0.isHidden }.map(\.frame)
        let guides = SpacingGuides.measure(image.frame, among: others, in: CGRect(origin: .zero, size: DeviceFrame.iPhone.size))
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

        let sketch = screen.placement.canvasRect(for: titleSketch)
        #expect(store.screenID(under: sketch) == screen.id)
        let title = try #require(store.sketched(.title, from: sketch, to: screen.id))
        #expect(store.node(title.id)?.content.text == "Title")
        #expect(title.frame == CGRect(x: 82.5, y: 112, width: 228, height: 40))

        undo.undo()
        #expect(store.shownLeaves(onScreenAt: 0)?.isEmpty == true)
        undo.undo()
        #expect(store.tree.screens.isEmpty)
        #expect(!undo.canUndo)

        undo.redo()
        undo.redo()
        #expect(store.shownLeaves(onScreenAt: 0)?.map(\.id) == [title.id])
    }

    @Test func aGradualEditUndoesAsOneStep() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        let title = try #require(store.sketched(.title, from: screen.placement.canvasRect(for: titleSketch), to: screen.id))
        let ref = NodeRef(host: .screen(screen.id), node: title.id)

        store.beginEdit()
        for step in 1...20 {
            store.update(ref.node) { $0.frame.origin.y = 112 + CGFloat(step) }
        }
        store.endEdit()
        #expect(store.shownLeaves(onScreenAt: 0)?.first?.frame.minY == 132)

        undo.undo()
        #expect(store.shownLeaves(onScreenAt: 0)?.first?.frame.minY == 112)
        undo.redo()
        #expect(store.shownLeaves(onScreenAt: 0)?.first?.frame.minY == 132)
    }

    /// Undo pressed while a spoken command or a generation holds its step open. It used to
    /// take back the step before, and lose the command's first change with it; the command's
    /// close then put that earlier step back, so undo behaved as redo.
    @Test func undoWhileAnEditIsHeldTakesBackWhatItHasDoneSoFar() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        let title = try #require(store.sketched(.title, from: screen.placement.canvasRect(for: titleSketch), to: screen.id))
        let ref = NodeRef(host: .screen(screen.id), node: title.id)
        let before = store.tree

        store.beginHeldEdit()
        store.actingForCommand { store.update(ref.node) { $0.content.text = "One" } }
        undo.undo()
        // The command's change so far is what goes; the title added before it stays.
        #expect(store.tree == before)
        store.actingForCommand { store.update(ref.node) { $0.content.text = "Two" } }
        store.endHeldEdit()
        #expect(store.node(ref.node)?.content.text == "Two")

        undo.undo()
        #expect(store.tree == before)
        undo.undo()
        #expect(store.shownLeaves(onScreenAt: 0)?.isEmpty == true)
    }

    @Test func redoWhileAnEditIsHeldStillRedoes() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        _ = try #require(store.sketched(.title, from: screen.placement.canvasRect(for: titleSketch), to: screen.id))
        let withTitle = store.tree
        undo.undo()

        store.beginHeldEdit()
        undo.redo()
        #expect(store.tree == withTitle)
        store.actingForCommand { store.updateTreeScreen(screen.id) { $0.name = "Renamed" } }
        store.endHeldEdit()
        undo.undo()
        #expect(store.tree == withTitle)
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
        store.actingForCommand { store.updateTreeScreen(screen.id) { $0.name = "One" } }
        let inEdit = store.historyMark
        store.actingForCommand { store.updateTreeScreen(screen.id) { $0.name = "Two" } }
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
        let title = try #require(store.sketched(.title, from: screen.placement.canvasRect(for: titleSketch), to: screen.id))
        let ref = NodeRef(host: .screen(screen.id), node: title.id)
        let before = try #require(store.placed(ref)).placement.canvasRect(for: title.frame)

        store.updateTreeScreen(screen.id) { $0.origin.x += 300 }
        let after = try #require(store.placed(ref)).placement.canvasRect(for: title.frame)
        #expect(after == before.offsetBy(dx: 300, dy: 0))

        undo.undo()
        #expect(store.tree.screens[0].origin == screen.origin)
    }

    @Test func anElementDroppedOffItsScreenFloatsWhereItWasDropped() throws {
        let (store, _) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)
        let title = try #require(store.sketched(.title, from: screen.placement.canvasRect(for: titleSketch), to: screen.id))
        let onScreen = NodeRef(host: .screen(screen.id), node: title.id)

        store.update(onScreen.node) { $0.frame.origin.x += 900 }
        let dropped = try #require(store.placed(onScreen))
        let droppedAt = dropped.placement.canvasRect(for: dropped.frame)

        let home = store.rehost(onScreen)
        #expect(home == NodeRef(host: .canvas, node: title.id))
        #expect(store.screenLeaves(screen.id).isEmpty)
        let floating = try #require(store.tree.canvas.first)
        #expect(floating.scale == screen.scale)
        #expect(floating.frame.size == title.frame.size)
        #expect(isClose(center(try #require(store.canvasRect(of: floating.id))), center(droppedAt)))
    }

    @Test func anElementDroppedOnAnotherScreenJoinsItAndTheMoveUndoes() throws {
        let (store, undo) = makeStore()
        let left = store.addScreen(from: leftScreenSketch)
        let right = store.addScreen(from: rightScreenSketch)
        let title = try #require(store.sketched(.title, from: left.placement.canvasRect(for: titleSketch), to: left.id))
        let ref = NodeRef(host: .screen(left.id), node: title.id)

        // Drag it across to the middle of the other screen.
        let target = left.placement.localPoint(for: center(right.canvasFrame(on: right.device)))
        store.beginEdit()
        store.update(ref.node) { $0.frame.origin = CGPoint(x: target.x - 114, y: target.y - 20) }
        let home = store.rehost(ref)
        store.endEdit()

        #expect(home == NodeRef(host: .screen(right.id), node: title.id))
        #expect(store.screenLeaves(left.id).isEmpty)
        let moved = try #require(store.shownLeaves(on: right.id).first)
        #expect(moved.frame.size == CGSize(width: 228, height: 40))
        #expect(isClose(center(right.placement.canvasRect(for: moved.frame)), center(right.canvasFrame(on: right.device))))
        #expect(store.rehost(home) == home, "an element that hasn't moved stays where it lives")

        undo.undo()
        #expect(store.shownLeaves(on: left.id).map(\.frame) == [title.frame])
        #expect(store.screenLeaves(right.id).isEmpty)
    }

    @Test func aSymbolLandsOnTheScreenUnderItOrOnTheOpenCanvas() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: leftScreenSketch)

        let onScreen = try #require(store.place(LayerNode.standard(.symbol, symbol: "heart.fill"), centredAt: center(screen.canvasFrame(on: screen.device))))
        #expect(onScreen.host == .screen(screen.id))
        let heart = try #require(store.placed(onScreen))
        #expect(heart.node.content.symbol == "heart.fill")
        #expect(heart.frame.size == CGSize(width: 44, height: 44))
        #expect(isClose(center(heart.placement.canvasRect(for: heart.frame)), center(screen.canvasFrame(on: screen.device))))

        let elsewhere = CGPoint(x: 3000, y: 2500)
        let onCanvas = try #require(store.place(LayerNode.standard(.symbol, symbol: "star"), centredAt: elsewhere))
        #expect(onCanvas.host == .canvas)
        #expect(isClose(center(try #require(store.tree.canvas.first.flatMap { store.canvasRect(of: $0.id) })), elsewhere))

        store.delete(onCanvas)
        #expect(store.tree.canvas.isEmpty)
        undo.undo()
        #expect(store.tree.canvas.count == 1)
    }

    @Test func aDeviceFrameIsAddedAtItsOwnSizeAndElementsKeepTheirMarginsOnIt() throws {
        let (store, _) = makeStore()
        let iPad = try #require(DeviceFrame.all.first { $0.id == "ipad" })
        let screen = store.addScreen(iPad, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 0.5))
        #expect(screen.device.size == CGSize(width: 820, height: 1180))
        #expect(screen.canvasFrame(on: screen.device) == CGRect(x: 100, y: 100, width: 410, height: 590))

        // A button on a phone has 20-point margins; it keeps them on the wider screen.
        let button = try #require(store.sketched(.button, from: screen.placement.canvasRect(for: CGRect(x: 100, y: 1000, width: 600, height: 60)), to: screen.id))
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
        let note = try #require(store.place(LayerNode.standard(.stickyNote), centredAt: center(screen.canvasFrame(on: screen.device))))
        #expect(note.host == .canvas)
        #expect(store.rehost(note) == note)
        #expect(try #require(store.tree.canvas.first).style.tint == Theme.stickyNote)

        // Typed text does join the screen it is put on.
        let text = try #require(store.place(LayerNode.standard(.text), centredAt: center(screen.canvasFrame(on: screen.device))))
        #expect(text.host == .screen(screen.id))
        #expect(try #require(store.placed(text)).node.content.text == "Text")
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

    /// A name the app gives the board has no step, so no undo takes it away: not one of a
    /// step made before it, nor of a step under way as it came (M4).
    @Test func undoLeavesANameTheAppGaveTheBoard() {
        let (store, undo) = makeStore()
        store.addScreen(from: leftScreenSketch)
        store.setTitle("Suggested", undoable: false)
        undo.undo()
        #expect(store.tree.screens.isEmpty)
        #expect(store.title == "Suggested")
        undo.redo()
        #expect(store.title == "Suggested")

        let screen = store.tree.screens[0]
        store.beginEdit()
        store.updateTreeScreen(screen.id) { $0.name = "Home" }
        store.setTitle("Login", undoable: false)
        store.updateTreeScreen(screen.id) { $0.name = "Start" }
        store.endEdit()
        undo.undo()
        #expect(store.treeScreen(screen.id)?.name == "Screen 1")
        #expect(store.title == "Login")
    }

    /// A name given since by something that isn't a step, the file renamed in Files for
    /// instance, is the board's name now: undoing the naming it replaced leaves it (M4).
    @Test func undoingANamingLeavesANameGivenSinceWithoutAStep() {
        let (store, undo) = makeStore()
        store.setTitle("Login")
        store.setTitle("Client pitch", undoable: false)
        undo.undo()
        #expect(store.title == "Client pitch")
        undo.redo()
        #expect(store.title == "Client pitch")
    }

    @Test func theContentBoundsCoverEverythingInTheDesign() throws {
        let (store, _) = makeStore()
        #expect(store.contentBounds == nil)

        let screen = store.addScreen(from: leftScreenSketch)
        store.place(LayerNode.standard(.symbol, symbol: "star"), centredAt: CGPoint(x: 3000, y: 2500))
        let bounds = try #require(store.contentBounds)
        #expect(bounds.contains(screen.canvasFrame(on: screen.device)))
        #expect(bounds.contains(CGPoint(x: 3000, y: 2500)))

        store.deleteScreen(screen.id)
        #expect(store.tree.screens.isEmpty)
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

        model.canvasTapped(at: model.viewport.viewPoint(for: center(screen.canvasFrame(on: screen.device))))
        #expect(model.selection == .screen(screen.id))
        #expect(model.selectedScreenID == screen.id)

        model.canvasTapped(at: model.viewport.viewPoint(for: CGPoint(x: 5000, y: 5000)))
        #expect(model.selection == nil)
    }

    @Test func textNotesFramesAndPicturesAreAddedInTheMiddleOfTheViewAndSelected() throws {
        let (model, _) = makeModel()
        model.viewport = Viewport(offset: CGPoint(x: 4000, y: 3000), scale: 1)
        let middle = model.viewport.canvasPoint(for: CGPoint(x: 605, y: 417))

        let iPad = try #require(DeviceFrame.all.first { $0.id == "ipad" })
        model.addFrame(iPad)
        let frame = try #require(model.store.tree.screens.last)
        let frameOnCanvas = try #require(model.store.canvasFrame(ofScreen: frame.id))
        // A frame, unlike text, a note or a picture, comes in unselected.
        #expect(model.selection == nil)
        #expect(model.tool == .select)
        #expect(isClose(center(frameOnCanvas), middle, within: 2))
        #expect(frameOnCanvas.height <= 834 - 200, "the frame should fit in the view")

        model.addText()
        #expect(model.selectedNode?.node.kind == .text)
        #expect(model.selectedNode?.ref.host == .screen(frame.id))
        #expect(model.isEditingText)

        model.addStickyNote()
        #expect(model.selectedNode?.node.kind == .stickyNote)
        #expect(model.selectedNode?.ref.host == .canvas)

        let picture = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let png = try #require(picture.pngData())
        let prepared = try #require(ImageImport.prepare(png))
        model.addImage(prepared)
        let image = try #require(model.selectedNode)
        #expect(image.node.kind == .image)
        #expect(image.frame.width / image.frame.height == 2)
        #expect(model.images.image(image.node.content.imageID) != nil)
        let imageID = try #require(image.node.content.imageID)
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
        let selected = try #require(model.selectedNode)
        #expect(selected.node.content.symbol == "bolt.fill")
        let middle = model.viewport.canvasPoint(for: CGPoint(x: 605, y: 417))
        #expect(isClose(center(selected.placement.canvasRect(for: selected.frame)), middle))
    }

    @Test func undoingOrDeletingTheSelectedThingClearsTheSelection() throws {
        let (model, undo) = makeModel()
        let screen = model.store.addScreen(from: leftScreenSketch)
        let title = try #require(model.store.sketched(.title, from: screen.placement.canvasRect(for: titleSketch), to: screen.id))
        model.tool = .select
        model.selection = .element(.init(host: .screen(screen.id), node: title.id))

        undo.undo()
        #expect(model.selection == nil)

        model.selection = .screen(screen.id)
        model.deleteSelection()
        #expect(model.selection == nil)
        #expect(model.store.tree.screens.isEmpty)
    }

    /// A generation that wrote only an empty card has written nothing: its screen goes as it ends, as one that wrote no
    /// line at all does. An empty row, column or card holds no element.
    @Test func aGenerationThatWroteOnlyAnEmptyCardLeavesNoScreen() async throws {
        let (model, _) = makeModel()
        model.suggestsTitle = false
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        model.screenStream = { _ in stream }
        model.generateScreen(from: "a settings screen")
        let screen = try #require(model.generation?.screenID)
        var written = Outline.parse("card:\n  text: About", isComplete: true)
        try #require(written.children.first?.kind == .card)
        written.children[0].children = []
        feed.yield(.screen(written))
        // Merged and laid out off the main actor first: given time, as a run of every suite at once is slow.
        #expect(await eventually(within: .seconds(10)) { model.store.treeScreen(screen)?.root.children.first?.kind == .card })
        #expect(model.store.treeScreen(screen)?.root.leafCount == 0)

        feed.finish()
        await model.waitForGeneration()

        #expect(model.store.treeScreen(screen) == nil)
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
        var content = TreeContent()
        content.screens = [demoScreen()]
        var heart = LayerNode.leaf(.symbol, frame: CGRect(x: 900, y: 700, width: 44, height: 44), text: "", tint: Theme.inkTint, symbol: "heart.fill")
        heart.scale = 0.75
        content.canvas = [heart]
        content.title = "Onboarding"
        content.settings.gridStyle = .lines

        let points = SketchSamples.wave(CGRect(x: 100, y: 100, width: 200, height: 30), humps: 4).enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: 0)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: .now))
        var file = DesignFile()
        file.content = content
        file.content.adopt(PKDrawing(strokes: [stroke]))
        return file
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
        file.content.canvas[0].content.imageID = picture
        file.images = [picture.uuidString: Data([1, 2, 3])]
        file.preview = Data([9, 8, 7])
        file.fileName = "Onboarding"

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Onboarding.layer")
        try file.wrapper().write(to: url, options: .atomic, originalContentsURL: nil)

        // The ink is one file for each drawing, named by the drawing.
        let drawing = try #require(file.content.canvas.first { $0.kind == .drawing })
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
        file.content.canvas[0].content.imageID = picture
        file.images = [picture.uuidString: Data([1, 2, 3])]
        let first = try file.wrapper()

        // Only the design changes: the ink and the picture on disk are handed back as they are.
        file.content.title = "Renamed"
        let second = try file.wrapper(replacing: first)
        let drawing = try #require(file.content.canvas.first { $0.kind == .drawing }).id.uuidString
        let firstInk = try #require(first.fileWrappers?["ink"]?.fileWrappers?[drawing])
        #expect(second.fileWrappers?["ink"]?.fileWrappers?[drawing] === firstInk)
        #expect(second.fileWrappers?["images"]?.fileWrappers?[picture.uuidString] === first.fileWrappers?["images"]?.fileWrappers?[picture.uuidString])
        #expect(second.fileWrappers?["design.json"] !== first.fileWrappers?["design.json"])
        #expect(try DesignFile(wrapper: second).content.title == "Renamed")
    }

    @Test func picturesNothingShowsAreLeftOutOfTheSavedFile() throws {
        var file = sampleFile()
        let shown = UUID()
        file.content.canvas[0].content.imageID = shown
        file.images = [shown.uuidString: Data([1, 2, 3]), UUID().uuidString: Data([4, 5, 6])]

        let reopened = try DesignFile(wrapper: file.wrapper())
        #expect(reopened.images == [shown.uuidString: Data([1, 2, 3])])
    }

    /// A package as a newer Layer might save it: an image and a drawing this version can't
    /// read (a text alignment it doesn't know), their picture and ink, a picture nothing
    /// shows, and a folder of a kind it has never heard of.
    private func packageFromANewerLayer() throws -> (package: FileWrapper, picture: UUID, drawing: UUID, orphan: UUID) {
        let picture = UUID(), drawing = UUID(), orphan = UUID()
        let elements: [[String: Any]] = [
            ["id": UUID().uuidString, "kind": "image", "imageID": picture.uuidString, "style": ["textAlignment": "justified"],
             "frame": [[0, 0], [10, 10]], "rotation": 30, "blur": 4, "scale": 1],
            ["id": drawing.uuidString, "kind": "drawing", "style": ["textAlignment": "justified"],
             "frame": [[0, 0], [10, 10]], "scale": 1],
        ]
        let manifest = try JSONSerialization.data(withJSONObject: ["version": 4, "content": ["screens": [], "canvas": elements]])
        let package = FileWrapper(directoryWithFileWrappers: [
            "design.json": FileWrapper(regularFileWithContents: manifest),
            "images": FileWrapper(directoryWithFileWrappers: [
                picture.uuidString: FileWrapper(regularFileWithContents: Data([1, 2, 3])),
                orphan.uuidString: FileWrapper(regularFileWithContents: Data([4, 5, 6])),
            ]),
            "ink": FileWrapper(directoryWithFileWrappers: [drawing.uuidString: FileWrapper(regularFileWithContents: Data([5, 5, 5]))]),
            "fonts": FileWrapper(directoryWithFileWrappers: ["Brand.otf": FileWrapper(regularFileWithContents: Data([7, 7]))]),
        ])
        return (package, picture, drawing, orphan)
    }

    @Test func savingKeepsThePictureAndInkOfElementsThisVersionCannotRead() throws {
        let (package, picture, drawing, orphan) = try packageFromANewerLayer()
        let file = try DesignFile(wrapper: package)
        #expect(file.content.listedEverywhere.isEmpty, "neither element can be read here")

        // Saved over the file it came from, and written afresh, as a copy to share is.
        for saved in [try file.wrapper(replacing: package), try file.wrapper()] {
            #expect(saved.fileWrappers?["images"]?.fileWrappers?[picture.uuidString]?.regularFileContents == Data([1, 2, 3]))
            #expect(saved.fileWrappers?["ink"]?.fileWrappers?[drawing.uuidString]?.regularFileContents == Data([5, 5, 5]))
            #expect(saved.fileWrappers?["fonts"]?.fileWrappers?["Brand.otf"]?.regularFileContents == Data([7, 7]))
            // A picture nothing shows, read or not, still goes.
            #expect(saved.fileWrappers?["images"]?.fileWrappers?[orphan.uuidString] == nil)

            // And again, from what was saved.
            let again = try DesignFile(wrapper: saved).wrapper()
            #expect(again.fileWrappers?["images"]?.fileWrappers?[picture.uuidString] != nil)
            #expect(again.fileWrappers?["ink"]?.fileWrappers?[drawing.uuidString] != nil)
            #expect(again.fileWrappers?["fonts"]?.fileWrappers?["Brand.otf"] != nil)
            let manifest = try #require(again.fileWrappers?["design.json"]?.regularFileContents)
            let root = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
            let written = try #require((root["content"] as? [String: Any])?["canvas"] as? [[String: Any]])
            #expect(written.first?["rotation"] as? Double == 30)
            #expect(written.first?["blur"] as? Double == 4)
        }
    }

    /// The JSON object of a saved package's design.
    private func manifest(of package: FileWrapper) throws -> [String: Any] {
        let data = try #require(package.fileWrappers?["design.json"]?.regularFileContents)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func keysThisVersionDoesNotKnowSurviveASave() throws {
        var button = LayerNode.standard(.button)
        button.rotation = 30
        var holder = LayerNode(kind: .group)
        holder.children = [button]
        var file = DesignFile()
        file.content.screens = [TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: nil, root: holder)]
        let mask = UUID()
        file.images = [mask.uuidString: Data([1, 2, 3])]

        // A newer Layer adds keys of its own at every level, one of them naming a picture,
        // and saves the design's model in a shape this version can't read.
        var root = try manifest(of: file.wrapper())
        var saved = try #require(root["content"] as? [String: Any])
        var screens = try #require(saved["screens"] as? [[String: Any]])
        var screenRoot = try #require(screens[0]["root"] as? [String: Any])
        var elements = try #require(screenRoot["children"] as? [[String: Any]])
        elements[0]["skew"] = 12
        elements[0]["maskImageID"] = mask.uuidString
        elements[0]["shadowStyle"] = ["blur": 8, "colour": "#000000"]
        screenRoot["children"] = elements
        screens[0]["root"] = screenRoot
        screens[0]["background"] = "#FFFFFF"
        saved["screens"] = screens
        var settings = try #require(saved["settings"] as? [String: Any])
        settings["rulers"] = true
        settings["model"] = ["provider": ["name": "future"]]
        saved["settings"] = settings
        saved["groups"] = [["members": [button.id.uuidString]]]
        root["content"] = saved
        root["designID"] = "B7F0"
        let newer = FileWrapper(directoryWithFileWrappers: [
            "design.json": FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: root)),
            "images": FileWrapper(directoryWithFileWrappers: [mask.uuidString: FileWrapper(regularFileWithContents: Data([1, 2, 3]))]),
        ])

        var read = try DesignFile(wrapper: newer)
        #expect(read.content.listedEverywhere.first?.rotation == 30)
        #expect(read.content.settings.model == nil, "a model this version can't read is no choice here")

        let written = try read.wrapper(replacing: newer)
        let again = try manifest(of: written)
        #expect(again["designID"] as? String == "B7F0")
        let content2 = try #require(again["content"] as? [String: Any])
        #expect((content2["groups"] as? [[String: Any]])?.first?["members"] as? [String] == [button.id.uuidString])
        let screen2 = try #require((content2["screens"] as? [[String: Any]])?.first)
        let element = try #require(((screen2["root"] as? [String: Any])?["children"] as? [[String: Any]])?.first)
        #expect(element["rotation"] as? Double == 30)
        #expect(element["skew"] as? Double == 12)
        #expect((element["shadowStyle"] as? [String: Any])?["blur"] as? Double == 8)
        #expect(screen2["background"] as? String == "#FFFFFF")
        let settings2 = try #require(content2["settings"] as? [String: Any])
        #expect(settings2["rulers"] as? Bool == true)
        #expect(((settings2["model"] as? [String: Any])?["provider"] as? [String: Any])?["name"] as? String == "future")
        // The picture only the new key names is kept with it.
        #expect(written.fileWrappers?["images"]?.fileWrappers?[mask.uuidString] != nil)

        // A model chosen here is written in place of the one this version couldn't read.
        read.content.settings.model = .appleIntelligence
        let chosen = try #require((try manifest(of: read.wrapper())["content"] as? [String: Any])?["settings"] as? [String: Any])
        #expect((chosen["model"] as? [String: Any])?["provider"] as? String == ModelChoice.appleIntelligence.provider)
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
        var empty = TreeContent()
        empty.settings.model = ModelPreferences.defaultChoice
        #expect(document.current.content == empty)
        #expect(document.current.drawing.strokes.isEmpty)

        model.store.addScreen(from: leftScreenSketch)
        // Ink drawn on the canvas becomes a drawing in the design.
        var sync = DrawingSync()
        let strokes = sampleFile().drawing.strokes
        model.inkChanged(sync.changes(for: strokes, in: model.store.tree))

        let snapshot = try document.snapshot(contentType: .layerDesign)
        #expect(snapshot.content.screens.map(\.name) == ["Screen 1"])
        #expect(snapshot.content.canvasLeaves.map(\.kind) == [.drawing])
        #expect(snapshot.drawing.strokes.map(\.key) == strokes.map(\.key))

        // What is written to disk opens as the same design.
        #expect(try DesignFile(wrapper: snapshot.wrapper()).content == snapshot.content)
    }

    @Test func theSharedDesignFileHasTheLatestEdit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Untitled 4.layer")
        try DesignFile().wrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        let model = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        model.fileURL = url

        // Changed since the system last saved it, then shared as the share menu shares it.
        model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        #expect(ShareItem.offered(for: model) == [.picture, .designFile])
        let shared = try #require(try await ShareItem.designFile.file(for: model))
        defer { try? FileManager.default.removeItem(at: shared.deletingLastPathComponent()) }

        #expect(shared.lastPathComponent == "Untitled 4.layer")
        #expect(try DesignFile.content(at: shared).screens.count == 1)
        let copy = try DesignFile(wrapper: FileWrapper(url: shared))
        #expect(copy.preview != nil, "with a picture of the board as it is")
        // The design's own file is left to the system to save.
        #expect(try DesignFile.content(at: url).screens.isEmpty)

        // Once the share sheet closes, the copy goes.
        ShareItem.designFile.cleanUp(shared)
        #expect(!FileManager.default.fileExists(atPath: shared.deletingLastPathComponent().path))
        model.close()
    }

    @Test func copiesToShareLeaveNoFoldersBehind() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // One copy from a share sheet whose closing went unheard an hour ago, and one that
        // another window may be sharing now.
        let old = temporary.appendingPathComponent("Design-old"), recent = temporary.appendingPathComponent("Design-recent")
        for folder in [old, recent] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: old.path)

        let model = AppModel(document: LayerDocument(file: DesignFile()))
        model.fileURL = temporary.appendingPathComponent("Shop.layer")
        let shared = try await model.fileToShare(in: temporary)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))

        // A copy that can't be written leaves nothing behind: its name is too long here.
        let unwritable = AppModel(document: LayerDocument(file: DesignFile()))
        unwritable.fileURL = temporary.appendingPathComponent(String(repeating: "a", count: 300) + ".layer")
        await #expect(throws: (any Error).self) { try await unwritable.fileToShare(in: temporary) }
        let left = try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("Design-") }
        #expect(Set(left) == ["Design-recent", shared.deletingLastPathComponent().lastPathComponent])
        model.close()
        unwritable.close()
    }

    @Test func openingADesignShowsItsContent() throws {
        let file = sampleFile()
        let document = LayerDocument()
        document.update { $0 = file }
        let model = AppModel(document: document)
        #expect(model.store.tree == file.content)
    }
}

@Suite("Generating SwiftUI")
struct CodeGenerationTests {
    @Test func theDemoScreenBecomesAVerticalStackInReadingOrder() {
        let code = SwiftUICodeGenerator.code(forFreeScreenHolding: demoElements(), settings: CodeSettings(includesPreview: false))
        let expected = """
            import SwiftUI

            struct Screen1: View {
                var body: some View {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Title")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
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
        let design = SwiftUICodeGenerator.design(holding: demoElements())
        #expect(SwiftUICodeGenerator.fileName(for: design.screens[0], in: SwiftUICodeGenerator.Context(design)) == "Screen1.swift")
    }

    @Test func aSymbolOnAScreenBecomesASystemImage() throws {
        var heart = element(.symbol, 174.5, 200, 44, 44)
        heart.content.symbol = "heart.fill"
        heart.style.tint = Theme.inkTint
        let screen = [element(.title, 82.5, 112, 228, 40), heart]

        let lines = SwiftUICodeGenerator.code(forFreeScreenHolding: screen, named: "Screen 2").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
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
        var title = element(.title, 82.5, 112, 228, 40)
        title.style.fontSize = 34
        title.style.fontWeight = .semibold
        title.style.textColor = RGBColor(hex: 0x3366FF)
        title.style.opacity = 0.5
        var button = element(.button, 20, 744, 353, 50)
        button.style.cornerRadius = 12
        let screen = [title, button]

        let lines = SwiftUICodeGenerator.code(forFreeScreenHolding: screen, named: "Screen 3").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains(".font(.system(size: 34, weight: .semibold))"))
        #expect(lines.contains(".foregroundStyle(Color(red: 0.20, green: 0.40, blue: 1.00))"))
        #expect(lines.contains(".opacity(0.5)"))
        #expect(lines.contains(".background(Color(red: 0.80, green: 0.42, blue: 0.34), in: .rect(cornerRadius: 12))"))
    }

    @Test func aScreenOfAnotherDeviceUsesThatDevicesEdges() {
        let code = SwiftUICodeGenerator.code(forFreeScreenHolding: [element(.title, 296, 100, 228, 40)], named: "Tablet",
                                             device: DeviceFrame.named("ipad"))
        // The iPad's status bar keeps 24 points clear, and the title is centred on 820.
        #expect(code.contains(".padding(.top, 76)"))
        #expect(code.contains(".multilineTextAlignment(.center)"))
    }

    @Test func textIsEscapedAndAnEmptyScreenStillCompiles() {
        #expect(SwiftUICodeGenerator.code(forFreeScreenHolding: [], named: "Screen 2").contains("Color.clear"))

        let screen = [element(.title, 82, 112, 228, 40, text: "Say \"hi\"\\now")]
        #expect(SwiftUICodeGenerator.code(forFreeScreenHolding: screen, named: "Screen 2").contains(#"Text("Say \"hi\"\\now")"#))
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

    @Test func aBoardNamedAfterItsOwnNumberedFileKeepsThatFile() async throws {
        let url = try savedDesign(named: "Onboarding 2")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try DesignFile().wrapper().write(to: url.deletingLastPathComponent().appendingPathComponent("Onboarding.layer"), options: .atomic, originalContentsURL: nil)

        let moved = try await DesignFileName.rename(url, to: "Onboarding")
        #expect(moved.lastPathComponent == "Onboarding 2.layer")
        #expect(exists("Onboarding 2.layer", beside: url))
        #expect(!exists("Onboarding 3.layer", beside: url))

        // The same through the board: named "Onboarding" over that file, it keeps the file
        // and takes its number, as a name taken by another design does.
        let model = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        model.fileURL = url
        model.store.setTitle("Onboarding")
        await wait { model.store.title == "Onboarding 2" }
        #expect(model.fileURL?.lastPathComponent == "Onboarding 2.layer")
        #expect(model.store.title == "Onboarding 2")
        #expect(!exists("Onboarding 3.layer", beside: url))
    }

    /// A design open in Layer, its board named twice: first by the app, then by hand.
    private func renamedTwice() async throws -> (model: AppModel, undo: UndoManager, url: URL) {
        let url = try savedDesign(named: "Untitled")
        let model = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.fileURL = url
        model.store.setTitle("Login", undoable: false)
        await wait { model.fileURL?.lastPathComponent == "Login.layer" }
        model.store.setTitle("Checkout")
        await wait { model.fileURL?.lastPathComponent == "Checkout.layer" }
        #expect(model.fileURL?.lastPathComponent == "Checkout.layer")
        return (model, undo, url)
    }

    /// Renamed in Files while it is open, the design takes the name. Undoing the naming
    /// by hand before it put the old name back, and the file was renamed back to it (M4).
    @Test func aFileRenamedInFilesIsNotRenamedBackByUndo() async throws {
        let (model, undo, url) = try await renamedTwice()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pitch = url.deletingLastPathComponent().appendingPathComponent("Client pitch.layer")
        try FileManager.default.moveItem(at: try #require(model.fileURL), to: pitch)
        model.fileURL = pitch
        #expect(model.store.title == "Client pitch")

        undo.undo()
        await model.settleFileName()
        #expect(model.store.title == "Client pitch")
        #expect(model.fileURL?.lastPathComponent == "Client pitch.layer")
        #expect(exists("Client pitch.layer", beside: url))
        model.close()
    }

    /// Once a board has had a name, given by hand or by the app, none is suggested for it
    /// again: not after the name is cleared, nor after it is undone. A suggestion then
    /// renamed the file a second time (M4).
    @Test func aBoardThatHasHadANameIsNotGivenASuggestionAgain() async throws {
        let (model, _, url) = try await renamedTwice()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.store.setTitle(nil)
        model.addFrame(.iPhone)
        #expect(model.titleSuggestion == nil)
        #expect(model.store.title == nil)
        model.close()

        // Opened again with its board's name undone, and only its file's name to go on.
        var file = DesignFile()
        file.fileName = "Login"
        let login = url.deletingLastPathComponent().appendingPathComponent("Login.layer")
        try file.wrapper().write(to: login, options: .atomic, originalContentsURL: nil)
        let reopened = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: login))))
        reopened.fileURL = login
        #expect(reopened.store.title == nil)
        reopened.addText()
        #expect(reopened.titleSuggestion == nil)
        reopened.close()
    }

    /// A name given by hand that another design has takes a number, and that is part of
    /// the naming: undoing it takes the number away too, and redoing puts it back.
    /// Undo puts back a name another design has taken meanwhile, so it gets a number. The
    /// number is part of what undo put back: redo still brings back the name given after
    /// it, and undo the number with the name (review m1).
    @Test func redoBringsBackANameAfterUndoPutBackOneThatNeededANumber() async throws {
        let url = try savedDesign(named: "Untitled")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.fileURL = url
        model.store.setTitle("Onboarding")
        await wait { model.fileURL?.lastPathComponent == "Onboarding.layer" }
        model.store.setTitle("Home")
        await wait { model.fileURL?.lastPathComponent == "Home.layer" }
        // Another design takes the first name.
        try DesignFile().wrapper().write(to: url.deletingLastPathComponent().appendingPathComponent("Onboarding.layer"), options: .atomic, originalContentsURL: nil)

        undo.undo()
        await wait { model.store.title == "Onboarding 2" }
        #expect(model.store.title == "Onboarding 2")
        undo.redo()
        #expect(model.store.title == "Home")
        await wait { model.fileURL?.lastPathComponent == "Home.layer" }
        undo.undo()
        #expect(model.store.title == "Onboarding 2")
        undo.undo()
        #expect(model.store.title == nil)
        model.close()
    }

    /// The name shown for a board without one of its own is its file's, as Files and Siri
    /// show it, unless the file still has the name new designs get. A name undone or
    /// cleared showed "Untitled" in the top bar, while the file kept the name (review m2).
    @Test func aBoardWithoutANameIsShownByItsFilesName() async throws {
        let url = try savedDesign(named: "Untitled 3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.fileURL = url
        #expect(model.boardName == "Untitled")
        #expect(model.chosenName == nil)

        model.store.setTitle("Login")
        #expect(model.boardName == "Login")
        await wait { model.fileURL?.lastPathComponent == "Login.layer" }
        undo.undo()
        #expect(model.store.title == nil)
        #expect(model.boardName == "Login")
        #expect(model.chosenName == "Login")
        #expect(DesignActions.snapshot(of: model)?.name == "Login")
        model.close()
    }

    @Test func undoingANameThatNeededANumberTakesTheNumberWithIt() async throws {
        let url = try savedDesign(named: "Untitled")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try DesignFile().wrapper().write(to: url.deletingLastPathComponent().appendingPathComponent("Onboarding.layer"), options: .atomic, originalContentsURL: nil)
        let model = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.fileURL = url

        model.store.setTitle("Onboarding")
        await wait { model.store.title == "Onboarding 2" }
        #expect(model.store.title == "Onboarding 2")
        undo.undo()
        #expect(model.store.title == nil)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(model.store.title == "Onboarding 2")
        model.close()
    }

    @Test func aDesignStillAnswersToItsIdentifierAfterItsFileIsRenamed() async throws {
        let url = try savedDesign(named: "Untitled")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        model.fileURL = url
        model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let before = try #require(model.designID)
        // What a Shortcut holds from its first step: the design, and a screen of it.
        let screen = try #require(DesignActions.snapshot(of: model)?.screens.first)

        model.store.setTitle("Login")
        await wait { model.fileURL?.lastPathComponent == "Login.layer" }
        #expect(model.designID != before)

        #expect(OpenDesigns.shared.model(forDesign: before) === model)
        #expect(try await OpenDesigns.shared.open(design: before) === model)
        let snapshot = await DesignActions.snapshot(design: before)
        #expect(snapshot?.id == before, "the design answers to the identifier it was asked for")
        #expect(snapshot?.screens.map(\.id) == [screen.id])
        #expect(try await DesignActions.screen(screen).model === model)

        // A design made later under the old name is that design, not the renamed one: as
        // soon as its file is there, as when another device syncs it, before it is opened.
        try DesignFile().wrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        #expect(OpenDesigns.shared.model(forDesign: before) == nil)
        #expect(OpenDesigns.shared.currentID(for: before) == before)
        #expect(await DesignActions.snapshot(design: before)?.screens.isEmpty == true)
        let newer = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        newer.fileURL = url
        #expect(OpenDesigns.shared.model(forDesign: before) === newer)
        newer.close()
        model.close()
    }

    @Test func aClosedDesignIsNotListedAgainWhenItsFileMoves() throws {
        let model = AppModel(document: LayerDocument(file: DesignFile()))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.fileURL = folder.appendingPathComponent("A.layer")
        let old = try #require(model.designID)
        model.close()
        // A rename that finishes after the design closed.
        model.fileURL = folder.appendingPathComponent("B.layer")
        #expect(!OpenDesigns.shared.all.contains { $0 === model })
        // The old identifier still leads to the file where it is now.
        #expect(OpenDesigns.shared.currentID(for: old) == model.designID)
    }

    @Test func askingToCloseWhileClosingWaitsForTheCloseToFinish() async throws {
        let url = try savedDesign(named: "Untitled")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(document: LayerDocument(file: try DesignFile(wrapper: FileWrapper(url: url))))
        model.fileURL = url
        // Something else holds the file for a moment, as iCloud can, so the rename the
        // board's new name starts takes a while.
        await withCheckedContinuation { (holding: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: nil) { _ in
                    holding.resume()
                    Thread.sleep(forTimeInterval: 0.6)
                }
            }
        }
        model.store.setTitle("Login")

        // The back button's close waits for the rename; an action asks to close meanwhile.
        let first = Task { await model.prepareToClose() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.isClosed)
        let second = await model.prepareToClose()
        #expect(!second, "only the first close dismisses the design")
        #expect(model.isClosed, "the second waited for the first to finish")
        #expect(await first.value)
    }

    @Test func aDesignPutAwayToOpenAnotherIsReadiedAsTheBackButtonReadiesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // One design shown in the window's controller, another in a window of its own.
        let shown = AppModel(document: LayerDocument()), elsewhere = AppModel(document: LayerDocument())
        shown.fileURL = folder.appendingPathComponent("A.layer")
        elsewhere.fileURL = folder.appendingPathComponent("B.layer")
        let controller = UIViewController(), otherWindow = UIView()
        let canvas = InkCanvas.Coordinator(model: shown), otherCanvas = InkCanvas.Coordinator(model: elsewhere)
        shown.ink = canvas
        elsewhere.ink = otherCanvas
        controller.view.addSubview(canvas.documentCanvas)
        otherWindow.addSubview(otherCanvas.documentCanvas)
        // Edited moments ago: its picture for the document browser isn't drawn yet.
        shown.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        #expect(shown.document.current.preview == nil)

        await OpenDesigns.shared.prepareToPutAway(controller, keeping: nil)
        #expect(shown.isClosed)
        #expect(shown.document.current.preview != nil, "its picture shows the board as it was left")
        #expect(!elsewhere.isClosed)
        elsewhere.close()
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
    /// A board of three screens and 30 drawings of 40 strokes, some 2400 points across.
    private func bigBoard() -> AppModel {
        var content = TreeContent()
        for index in 0..<3 {
            var root = LayerNode(kind: .group)
            root.children = [element(.title, 40, 120, 300, 40)]
            content.screens.append(TreeScreen(name: "Screen \(index + 1)", origin: CGPoint(x: CGFloat(index) * 800, y: 0), scale: 1, deviceID: nil,
                                              root: root))
        }
        for index in 0..<30 {
            let origin = CGPoint(x: CGFloat(index % 6) * 400, y: 900 + CGFloat(index / 6) * 400)
            let strokes = (0..<40).map { stroke in
                let rect = CGRect(x: origin.x + CGFloat(stroke % 5) * 30, y: origin.y + CGFloat(stroke / 5) * 12, width: 160, height: 10)
                let points = SketchSamples.wave(rect, humps: 4).enumerated().map { offset, point in
                    PKStrokePoint(location: point, timeOffset: Double(offset) * 0.008, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: Double(index * 1000 + stroke))))
            }
            if var drawing = LayerNode.drawing(strokes) {
                drawing.scale = 1
                content.canvas.append(drawing)
            }
        }
        let board = content
        let document = LayerDocument()
        document.update { $0.content = board }
        return AppModel(document: document)
    }

    /// The board's views are drawn on the main thread; its ink, the picture and the PNG
    /// aren't, and the main thread is free meanwhile.
    ///
    /// Asked where that work is made, and how long the call held the main thread before
    /// handing it over, against the whole: the main thread is held from the call until the
    /// work starts elsewhere, in one go that nothing else on it can lengthen. Counting the
    /// main thread's turns instead failed now and then, as other tests' work on it, all
    /// running at once, took those turns.
    @Test func aPictureOfABigBoardToShareIsMadeWithoutHoldingUpTheApp() async throws {
        let model = bigBoard()
        let seen = OSAllocatedUnfairLock(initialState: (offTheMainThread: false, mainThreadTookATurn: false, handedOver: ContinuousClock.Instant?.none))
        let start = ContinuousClock.now
        let data = await BoardSnapshot.png(of: model) {
            let isMain = Self.isMainThread()
            let now = ContinuousClock.now
            seen.withLock {
                $0.offTheMainThread = !isMain
                $0.handedOver = now
            }
            // Held on the main thread, this turn would only come once the picture was made.
            await MainActor.run { seen.withLock { $0.mainThreadTookATurn = true } }
        }
        let total = ContinuousClock.now - start
        let png = try #require(data)
        let picture = try #require(UIImage(data: png))
        #expect(max(picture.size.width * picture.scale, picture.size.height * picture.scale) >= 4000)
        #expect(seen.withLock { $0.offTheMainThread }, "the ink, the picture and the PNG are made on another thread")
        #expect(seen.withLock { $0.mainThreadTookATurn }, "the main thread is free while they are")
        // Heavy work moved back before the hand-over, onto the main thread, makes the
        // hold most of the whole.
        let held = try #require(seen.withLock { $0.handedOver }) - start
        #expect(held < total * 0.5, "the main thread was held for \(held) of \(total)")

        // The file to share is the same picture.
        let shared = try #require(await BoardSnapshot.file(of: model))
        defer { try? FileManager.default.removeItem(at: shared) }
        #expect(UIImage(contentsOfFile: shared.path)?.size == picture.size)
    }

    private nonisolated static func isMainThread() -> Bool { Thread.isMainThread }

    @Test func theUndoHistoryIsCappedAtFiftySteps() {
        let store = DesignStore()
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
        #expect(try model.document.snapshot(contentType: .layerDesign).content.settings.background == RGBColor(hex: 0x0000FF))
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
        let start = model.store.tree
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
        #expect(model.store.tree == start)
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
    private func makeModel() -> (model: AppModel, undo: UndoManager, screen: TreeScreen) {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = AppModel(document: LayerDocument())
        model.store.undoManager = undo
        model.adjustmentPause = .milliseconds(20)
        let added = model.store.addScreen(from: leftScreenSketch)
        return (model, undo, model.store.treeScreen(added.id)!)
    }

    @Test func thePanelsPauseEndsItsOwnEdit() async throws {
        let (model, undo, screen) = makeModel()
        let before = model.store.tree
        model.adjusting { model.store.updateTreeScreen(screen.id) { $0.name = "Checkout" } }
        model.adjusting { model.store.updateTreeScreen(screen.id) { $0.name = "Checkout 2" } }
        #expect(model.store.isEditing)
        #expect(try await pauseEnds(model))
        undo.undo()
        #expect(model.store.tree == before)
    }

    /// A drag begun just after a colour was tapped: the pause used to end the drag's edit
    /// halfway, and every later move of the drag was an undo step of its own. The pause
    /// ends the panel's own step; the drag is one step of its own.
    @Test func aDragBegunDuringThePanelsPauseIsStillOneStep() async throws {
        let (model, undo, screen) = makeModel()
        let before = model.store.tree
        let x = screen.origin.x
        model.adjusting { model.store.updateTreeScreen(screen.id) { $0.name = "Checkout" } }
        model.store.beginEdit()
        model.store.updateTreeScreen(screen.id) { $0.origin.x += 10 }
        let mark = model.store.historyMark
        try await Task.sleep(for: .milliseconds(150))
        model.store.updateTreeScreen(screen.id) { $0.origin.x += 10 }
        model.store.updateTreeScreen(screen.id) { $0.origin.x += 10 }
        #expect(model.store.isEditing)
        #expect(model.store.historyMark == mark, "no move is a step of its own")
        model.store.endEdit()

        undo.undo()
        #expect(model.store.treeScreen(screen.id)?.origin.x == x)
        #expect(model.store.treeScreen(screen.id)?.name == "Checkout")
        undo.undo()
        #expect(model.store.tree == before)
    }

    /// A spoken command holds its step open. A panel change made just before it, or during
    /// it, used to leave the step open for good once the command ended: the panel's pause
    /// didn't end what it took for another's edit, and the hold left the step for the "edit
    /// by hand" the panel had begun. Every later change then joined that one step.
    @Test(arguments: [true, false])
    func aPanelChangeAroundASpokenCommandLeavesNoEditOpen(panelFirst: Bool) async throws {
        let (model, _, screen) = makeModel()
        let panel = { model.adjusting { model.store.updateTreeScreen(screen.id) { $0.name = "Checkout" } } }
        if panelFirst {
            panel()
            model.store.beginHeldEdit()
        } else {
            model.store.beginHeldEdit()
            panel()
        }
        model.store.actingForCommand { model.store.updateTreeScreen(screen.id) { $0.origin.x += 10 } }
        try await Task.sleep(for: .milliseconds(150))
        model.store.endHeldEdit()
        #expect(try await pauseEnds(model))

        // The next change is a step of its own.
        let mark = model.store.historyMark
        model.store.updateTreeScreen(screen.id) { $0.origin.y += 10 }
        #expect(model.store.historyMark == mark + 1)
    }

    /// The command ends before the panel's pause: the step the hold left open for the
    /// panel's edit by hand is the panel's to end.
    @Test func aPanelChangeInACommandThatEndsBeforeThePauseLeavesNoEditOpen() async throws {
        let (model, _, screen) = makeModel()
        model.adjustmentPause = .milliseconds(200)
        model.store.beginHeldEdit()
        model.adjusting { model.store.updateTreeScreen(screen.id) { $0.name = "Checkout" } }
        model.store.actingForCommand { model.store.updateTreeScreen(screen.id) { $0.origin.x += 10 } }
        model.store.endHeldEdit()
        #expect(model.store.isEditing, "the panel's edit goes on until its pause")
        #expect(try await pauseEnds(model))

        let mark = model.store.historyMark
        model.store.updateTreeScreen(screen.id) { $0.origin.y += 10 }
        #expect(model.store.historyMark == mark + 1)
    }

    /// A change in the panel during a drag is a step of its own, which the panel's pause
    /// ends while the drag goes on in its own.
    @Test func aChangeInThePanelDuringADragLeavesTheDragToEndIt() async throws {
        let (model, undo, screen) = makeModel()
        let before = model.store.tree
        let x = screen.origin.x
        // The drag's frames are made for its edit, as a canvas drag's are.
        let drag = model.store.beginEdit()
        model.store.act(for: drag) { model.store.updateTreeScreen(screen.id) { $0.origin.x += 10 } }
        model.adjusting { model.store.updateTreeScreen(screen.id) { $0.name = "Checkout" } }
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.store.isEditing)
        let mark = model.store.historyMark
        model.store.act(for: drag) { model.store.updateTreeScreen(screen.id) { $0.origin.x += 10 } }
        #expect(model.store.historyMark == mark, "the move after the pause is still the drag's")
        model.store.endEdit(drag)

        undo.undo()
        #expect(model.store.treeScreen(screen.id)?.name == before.screens.first?.name)
        #expect(model.store.treeScreen(screen.id)?.origin.x == x + 20)
        undo.undo()
        #expect(model.store.tree == before)
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
    private func lines(of screen: [LayerNode], settings: CodeSettings = CodeSettings(includesPreview: false)) -> [String] {
        SwiftUICodeGenerator.code(forFreeScreenHolding: screen, settings: settings).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// What a screen holds, on a free root of its own (`code(forFreeScreenHolding:)`).
    private func screen(_ elements: [LayerNode]) -> [LayerNode] {
        elements
    }

    private func turned(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, by degrees: Double?) -> LayerNode {
        var item = element(kind, x, y, width, height)
        item.rotation = degrees
        return item
    }

    @Test func anUprightElementHasNoTurnInItsCode() {
        let screen = screen([element(.button, 40, 300, 200, 50)])
        for layout in [CodeSettings.Layout.structure, .absolute] {
            let code = SwiftUICodeGenerator.code(forFreeScreenHolding: screen, settings: CodeSettings(layout: layout, includesPreview: false))
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
        let raw = SwiftUICodeGenerator.code(forFreeScreenHolding: screen([
            turned(.button, 20, 300, 150, 50, by: 10),
            element(.button, 220, 300, 150, 50),
        ]), settings: CodeSettings(includesPreview: false)).split(separator: "\n").map(String.init)
        let open = try #require(raw.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("HStack") })
        let indent = raw[open].prefix { $0 == " " }
        let close = try #require(raw[open...].firstIndex { $0 == indent + "}" })
        let turn = try #require(raw.firstIndex { $0.contains(".rotationEffect(.degrees(10))") })
        #expect(open < turn && turn < close)
    }

    /// A bordered, shadowed button inset from a full-width title, which sets the margin.
    private func styledButton(turnedBy degrees: Double?) -> [LayerNode] {
        var button = turned(.button, 60, 300, 200, 50, by: degrees)
        button.style.borderWidth = 2
        button.style.hasShadow = true
        return screen([element(.title, 20, 100, 353, 40), button])
    }

    @Test func aStacksBorderAndShadowTurnWithTheElement() throws {
        let lines = lines(of: styledButton(turnedBy: 15))
        let border = try #require(lines.firstIndex(of: ".overlay {"))
        let shadow = try #require(lines.firstIndex { $0.hasPrefix(".shadow(") })
        let turn = try #require(lines.firstIndex(of: ".rotationEffect(.degrees(15))"))
        let placement = try #require(lines.firstIndex { $0.hasPrefix(".padding(.leading,") })
        #expect(border < turn && shadow < turn && turn < placement)
    }

    @Test func aTurnedCentredTitleIsTurnedBeforeItIsStretched() throws {
        var title = element(.title, 82.5, 112, 228, 40)
        title.rotation = 20
        let lines = lines(of: screen([title, element(.body, 48, 300, 297, 44)]), settings: CodeSettings(includesPreview: false))
        let turn = try #require(lines.firstIndex(of: ".rotationEffect(.degrees(20))"))
        let stretch = try #require(lines.firstIndex(of: ".frame(maxWidth: .infinity)"))
        #expect(turn < stretch)
    }

    /// Upright, an element was placed and then finished, so a centred element's border went
    /// round the full width it was centred in, and an inset one's round its padding too (G7).
    /// It is finished first now, as a turned one is, so the border is round the element.
    @Test func anUprightElementIsFinishedBeforeItIsPlaced() throws {
        var image = element(.image, (393 - 200) / 2, 300, 200, 150)
        image.style.borderWidth = 2
        var title = element(.title, 82.5, 112, 228, 40)
        title.style.borderWidth = 2
        let centred = lines(of: screen([title, image]))
        for kind in ["Text(\"Title\")", "Image("] {
            let start = try #require(centred.firstIndex { $0.hasPrefix(kind) })
            let border = try #require(centred[start...].firstIndex(of: ".overlay {"))
            let placement = try #require(centred[start...].firstIndex(of: ".frame(maxWidth: .infinity)"))
            #expect(border < placement, "\(kind)")
        }
        let inset = lines(of: styledButton(turnedBy: nil))
        let border = try #require(inset.firstIndex(of: ".overlay {"))
        let shadow = try #require(inset.firstIndex { $0.hasPrefix(".shadow(") })
        let placement = try #require(inset.firstIndex { $0.hasPrefix(".padding(.leading,") })
        #expect(border < placement && shadow < placement)
    }

    @Test func anUprightStyledButtonIsWrittenInFull() throws {
        // Finished, then placed (G7): before, the padding that places it came first, and
        // the border went round the padding too.
        let lines = lines(of: styledButton(turnedBy: nil))
        let start = try #require(lines.firstIndex(of: "Button {"))
        #expect(Array(lines[start...].prefix(16)) == [
            "Button {",
            "} label: {",
            "Text(\"Continue\")",
            ".font(.headline)",
            ".foregroundStyle(.white)",
            ".frame(width: 200, height: 50)",
            ".background(Color(red: 0.80, green: 0.42, blue: 0.34), in: .capsule)",
            "}",
            ".overlay {",
            "Capsule()",
            ".strokeBorder(Color(red: 0.17, green: 0.16, blue: 0.15), lineWidth: 2)",
            "}",
            ".shadow(color: .black.opacity(0.18), radius: 10, y: 5)",
            ".padding(.leading, 40)",
            ".padding(.top, 144)",
            "}",
        ])
    }

    @Test func aHalfDegreeIsWrittenAsItIs() {
        let lines = lines(of: screen([turned(.button, 40, 300, 200, 50, by: 22.5)]), settings: CodeSettings(layout: .absolute, includesPreview: false))
        #expect(lines.contains(".rotationEffect(.degrees(22.5))"))
    }
}
