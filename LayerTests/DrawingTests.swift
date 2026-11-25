import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

/// A straight pen stroke between two canvas points. Each gets a later creation date,
/// which is how strokes are told apart.
private nonisolated(unsafe) var lastStrokeDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func stroke(from start: CGPoint, to end: CGPoint) -> PKStroke {
    lastStrokeDate = lastStrokeDate.addingTimeInterval(1)
    let points = (0...10).map { step in
        let t = CGFloat(step) / 10
        return PKStrokePoint(
            location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
            timeOffset: Double(step) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
        )
    }
    return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: lastStrokeDate))
}

/// An X drawn at a place on the canvas: two strokes that cross.
private func cross(at origin: CGPoint, size: CGFloat = 60) -> [PKStroke] {
    [
        stroke(from: origin, to: CGPoint(x: origin.x + size, y: origin.y + size)),
        stroke(from: CGPoint(x: origin.x + size, y: origin.y), to: CGPoint(x: origin.x, y: origin.y + size)),
    ]
}

private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.5) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

@Suite("Drawings as elements")
struct DrawingElementTests {
    @Test func aDrawingCoversItsStrokesAndGivesThemBackWhereTheyWere() throws {
        let strokes = cross(at: CGPoint(x: 400, y: 300))
        let area = try #require(InkGeometry.bounds(of: strokes))

        let drawing = try #require(LayerNode.drawing(strokes))

        #expect(drawing.kind == .drawing)
        #expect(drawing.frame == area)
        #expect(drawing.strokeCount == 2)
        #expect(drawing.canvasStrokes.map(\.key) == strokes.map(\.key))
        #expect(close(try #require(InkGeometry.bounds(of: drawing.canvasStrokes)), area))
    }

    @Test func movingADrawingsFrameMovesItsInk() throws {
        var drawing = try #require(LayerNode.drawing(cross(at: CGPoint(x: 400, y: 300))))
        let ink = drawing.content.ink

        drawing.frame.origin = CGPoint(x: 1000, y: 50)

        #expect(drawing.content.ink == ink, "the ink itself is untouched")
        #expect(close(try #require(InkGeometry.bounds(of: drawing.canvasStrokes)), drawing.frame))
    }

    @Test func resizingADrawingsFrameStretchesItsInk() throws {
        var drawing = try #require(LayerNode.drawing(cross(at: CGPoint(x: 400, y: 300))))

        drawing.frame.size = CGSize(width: drawing.frame.width * 2, height: drawing.frame.height * 0.5)

        #expect(close(try #require(InkGeometry.bounds(of: drawing.canvasStrokes)), drawing.frame, within: 1))
    }

    @Test func noStrokesMakeNoDrawing() {
        #expect(LayerNode.drawing([]) == nil)
    }

    @Test func strokesThatTouchAreOneDrawingAndThoseApartAreSeparate() {
        let here = cross(at: CGPoint(x: 100, y: 100))
        let there = cross(at: CGPoint(x: 900, y: 600))
        let groups = InkGeometry.groups([here[0], there[0], here[1], there[1]])
        #expect(groups.map { $0.map(\.key) }.sorted { $0[0] < $1[0] } == [here.map(\.key), there.map(\.key)])
    }

    @Test func inkSavedAsOneDrawingForTheBoardBecomesDrawingsOnTheOpenCanvas() throws {
        var content = TreeContent()
        content.adopt(PKDrawing(strokes: cross(at: CGPoint(x: 100, y: 100)) + cross(at: CGPoint(x: 900, y: 600))))

        #expect(content.listedEverywhere.map(\.kind) == [.drawing, .drawing])
        #expect(content.listedEverywhere.allSatisfy { node in content.canvas.contains { $0.id == node.id } && node.scale == 1 })
        #expect(content.canvasLeaves.count == 2)
        #expect(content.visibleInk.strokes.count == 4)
    }
}

@Suite("Keeping drawings and the ink canvas in step")
struct DrawingSyncTests {
    /// The canvas as it is once it shows `content`.
    private func canvas(showing content: TreeContent, with sync: inout DrawingSync, holding current: [PKStroke] = []) -> [PKStroke] {
        sync.strokes(showing: content, on: current) ?? current
    }

    @Test func strokesDrawnOnAnEmptyCanvasBecomeADrawing() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))

        let changes = sync.changes(for: strokes, in: content)
        changes.apply(to: &content)

        #expect(changes.drawings.count == 1)
        #expect(changes.removed.isEmpty)
        let drawing = try #require(content.canvas.first)
        #expect(drawing.kind == .drawing)
        #expect(drawing.strokeCount == 2)
        #expect(sync.drawing(owning: strokes[0].key) == drawing.id)
        // The canvas already shows what the design now holds: nothing to put there.
        let toShow = sync.strokes(showing: content, on: strokes)
        #expect(toShow == nil)
    }

    @Test func aStrokeThatTouchesADrawingJoinsItAndOneApartStartsAnother() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        var strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let first = try #require(content.canvas.first)

        strokes.append(stroke(from: CGPoint(x: 430, y: 300), to: CGPoint(x: 430, y: 360)))
        sync.changes(for: strokes, in: content).apply(to: &content)
        #expect(content.canvas.map(\.id) == [first.id])
        #expect(content.canvas.first?.strokeCount == 3)

        strokes.append(stroke(from: CGPoint(x: 1200, y: 800), to: CGPoint(x: 1300, y: 800)))
        sync.changes(for: strokes, in: content).apply(to: &content)
        #expect(content.canvas.count == 2)
        #expect(content.canvas.map(\.strokeCount) == [3, 1])
    }

    @Test func nothingIsWorkedOutAgainForDrawingsThatDidNotChange() {
        var sync = DrawingSync()
        var content = TreeContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)

        let again = sync.changes(for: strokes, in: content)
        #expect(again.isEmpty)
    }

    @Test func erasingAllOfADrawingsStrokesRemovesTheDrawing() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        let kept = cross(at: CGPoint(x: 100, y: 100))
        let erased = cross(at: CGPoint(x: 900, y: 600))
        sync.changes(for: kept + erased, in: content).apply(to: &content)
        #expect(content.canvas.count == 2)
        let gone = try #require(sync.drawing(owning: erased[0].key))

        let changes = sync.changes(for: kept, in: content)
        changes.apply(to: &content)

        #expect(changes.removed == [gone])
        #expect(content.canvas.count == 1)
    }

    @Test func aDrawingKeepsItsNameWhenAStrokeIsAdded() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        var strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let id = try #require(content.canvas.first?.id)
        content.update(id) { $0.name = "Arrow" }

        strokes.append(stroke(from: CGPoint(x: 430, y: 300), to: CGPoint(x: 430, y: 360)))
        sync.changes(for: strokes, in: content).apply(to: &content)

        #expect(content.node(id)?.name == "Arrow")
        #expect(content.node(id)?.strokeCount == 3)
    }

    @Test func aMovedDrawingIsShownWhereItNowIs() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let id = try #require(content.canvas.first?.id)

        content.update(id) { $0.frame.origin.x += 500 }
        let toShow = sync.strokes(showing: content, on: strokes)
        let shown = try #require(toShow)

        #expect(shown.map(\.key) == strokes.map(\.key), "the same strokes, in the same order")
        #expect(close(try #require(InkGeometry.bounds(of: shown)), try #require(content.node(id)).frame))
        // Now that the canvas shows it, the two agree again.
        let more = sync.strokes(showing: content, on: shown)
        #expect(more == nil)
        let changes = sync.changes(for: shown, in: content)
        #expect(changes.isEmpty)
    }

    @Test func lockedAndHiddenDrawingsAreKeptOffTheCanvasAndComeBack() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        let first = cross(at: CGPoint(x: 100, y: 100))
        let second = cross(at: CGPoint(x: 900, y: 600))
        var held = first + second
        sync.changes(for: held, in: content).apply(to: &content)
        let locked = try #require(sync.drawing(owning: first[0].key))
        let hidden = try #require(sync.drawing(owning: second[0].key))

        content.update(locked) { $0.isLocked = true }
        held = canvas(showing: content, with: &sync, holding: held)
        #expect(held.map(\.key) == second.map(\.key), "a locked drawing is out of the eraser's reach")
        // Its strokes leaving the canvas is not the drawing being erased.
        let afterLocking = sync.changes(for: held, in: content)
        #expect(afterLocking.isEmpty)
        #expect(content.node(locked) != nil)

        content.update(hidden) { $0.isHidden = true }
        held = canvas(showing: content, with: &sync, holding: held)
        #expect(held.isEmpty)

        content.update(locked) { $0.isLocked = false }
        content.update(hidden) { $0.isHidden = false }
        held = canvas(showing: content, with: &sync, holding: held)
        #expect(Set(held.map(\.key)) == Set((first + second).map(\.key)))
        let afterAll = sync.changes(for: held, in: content)
        #expect(afterAll.isEmpty)
    }

    @Test func aDeletedDrawingLeavesTheCanvas() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let id = try #require(content.canvas.first?.id)

        content.canvas.removeAll { $0.id == id }

        let toShow = sync.strokes(showing: content, on: strokes)
        #expect(toShow?.isEmpty == true)
    }
}

@Suite("Drawings in the design")
@MainActor
struct DrawingStoreTests {
    private func storeWithDrawing() throws -> (store: DesignStore, undo: UndoManager, ref: DesignStore.ElementRef) {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = DesignStore()
        store.undoManager = undo
        var sync = DrawingSync()
        let changes = sync.changes(for: cross(at: CGPoint(x: 400, y: 300)), in: store.tree)
        store.apply { changes.apply(to: &$0) }
        let drawing = try #require(store.tree.canvas.first)
        return (store, undo, DesignStore.ElementRef(host: .canvas, element: drawing.id))
    }

    @Test func inkDrawnOnTheCanvasIsAnUndoStepOfTheDesigns() throws {
        let (store, undo, ref) = try storeWithDrawing()
        #expect(store.tree.canvasLeaves.map(\.kind) == [.drawing])
        let drawn = store.placed(ref)?.node

        undo.undo()
        #expect(store.tree.canvasLeaves.isEmpty)
        undo.redo()
        #expect(store.placed(ref)?.node == drawn, "redo brings back the same drawing, not another like it")
    }

    @Test func aDrawingIsLockedHiddenCopiedAndDeletedLikeAnyElement() throws {
        let (store, undo, ref) = try storeWithDrawing()

        store.update(ref.element) { $0.isLocked = true }
        #expect(store.placed(ref)?.node.isLocked == true)

        let copy = try #require(store.duplicate(ref))
        #expect(store.tree.canvasLeaves.map(\.kind) == [.drawing, .drawing])
        #expect(store.placed(copy)?.node.strokeCount == 2)
        #expect(store.placed(copy)?.frame.size == store.placed(ref)?.frame.size)
        #expect(store.placed(copy)?.node.isLocked == false)

        store.delete(ref)
        #expect(store.tree.canvasLeaves.map(\.id) == [copy.element])
        undo.undo()
        #expect(store.tree.canvasLeaves.count == 2)
    }

    @Test func aCopiedDrawingHasStrokesOfItsOwn() throws {
        let (store, _, ref) = try storeWithDrawing()
        let copy = try #require(store.duplicate(ref))
        let original = try #require(store.placed(ref)?.node)
        let copied = try #require(store.placed(copy)?.node)
        let keys = (original.canvasStrokes + copied.canvasStrokes).map(\.key)
        #expect(Set(keys).count == 4, "no two strokes on the canvas may be taken for the same one")

        // On the canvas, with a stroke then drawn elsewhere, the two stay two drawings.
        var sync = DrawingSync()
        let toShow = sync.strokes(showing: store.tree, on: [])
        var held = try #require(toShow)
        held.append(stroke(from: CGPoint(x: 1500, y: 900), to: CGPoint(x: 1600, y: 900)))
        var content = store.tree
        sync.changes(for: held, in: content).apply(to: &content)
        #expect(content.canvas.map(\.strokeCount) == [2, 2, 1])
        #expect(content.node(original.id)?.frame == original.frame)
        #expect(content.node(copied.id)?.frame == copied.frame)
    }

    @Test func aDrawingStaysOnTheOpenCanvas() throws {
        let (store, _, ref) = try storeWithDrawing()
        let screen = store.addFreeScreen([], origin: CGPoint(x: 300, y: 200))
        #expect(store.move(ref, toScreen: screen, origin: .zero) == nil)
        #expect(store.rehost(ref) == ref)
    }
}

@Suite("Saving drawings")
struct DrawingFileTests {
    private func fileWithDrawing() -> DesignFile {
        DesignFile(drawing: PKDrawing(strokes: cross(at: CGPoint(x: 400, y: 300))))
    }

    @Test func aDrawingsInkIsSavedBesideTheDesignUnderItsIdentifier() throws {
        let file = fileWithDrawing()
        let drawing = try #require(file.content.canvas.first)

        let package = try file.wrapper()

        let ink = try #require(package.fileWrappers?[DesignPackage.ink]?.fileWrappers)
        #expect(ink[drawing.id.uuidString]?.regularFileContents == drawing.content.ink)
        #expect(package.fileWrappers?["drawing.data"] == nil, "ink is no longer one drawing for the whole board")
        // The design file itself lists the drawing without its ink.
        let design = try #require(package.fileWrappers?[DesignPackage.design]?.regularFileContents)
        #expect(!String(decoding: design, as: UTF8.self).contains("\"ink\""))
    }

    @Test func aSavedDrawingReadsBackWithItsInk() throws {
        let file = fileWithDrawing()
        let reopened = try DesignFile(wrapper: try file.wrapper())
        #expect(reopened.content == file.content)
        #expect(reopened.drawing.strokes.count == 2)
    }

    @Test func inkThatHasNotChangedKeepsItsFileOnTheNextSave() throws {
        var file = fileWithDrawing()
        let first = try file.wrapper()
        let name = try #require(file.content.canvas.first?.id.uuidString)

        file.content.title = "Renamed"
        let second = try file.wrapper(replacing: first)

        #expect(second.fileWrappers?[DesignPackage.ink]?.fileWrappers?[name] === first.fileWrappers?[DesignPackage.ink]?.fileWrappers?[name])
    }
}

@Suite("Turned drawings")
struct TurnedDrawingTests {
    private func turnedCross(by degrees: Double) throws -> (TreeContent, LayerNode) {
        var content = TreeContent()
        var drawing = try #require(LayerNode.drawing(cross(at: CGPoint(x: 400, y: 300))))
        drawing.setRotation(degrees)
        drawing.scale = 1
        content.canvas.append(drawing)
        return (content, drawing)
    }

    @Test func aTurnedDrawingsInkIsTurnedAboutItsMiddle() throws {
        var drawing = try #require(LayerNode.drawing([stroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100))]))
        drawing.setRotation(90)
        let bounds = try #require(InkGeometry.bounds(of: drawing.canvasStrokes))
        #expect(abs(bounds.midX - 150) <= 1)
        #expect(abs(bounds.midY - 100) <= 1)
        #expect(bounds.height >= 99)
        #expect(bounds.width <= 6)
    }

    @Test func stretchingATurnedDrawingNeverShearsIt() throws {
        var drawing = try #require(LayerNode.drawing(cross(at: CGPoint(x: 400, y: 300))))
        drawing.setRotation(30)
        drawing.frame.size.width *= 2
        for stroke in drawing.canvasStrokes {
            let t = stroke.transform
            #expect(abs(t.a * t.c + t.b * t.d) < 1e-6)
        }
    }

    @Test func erasingPartOfATurnedDrawingLeavesTheRestWhereItWas() throws {
        // An L with a third stroke down its right side: what is left once that is
        // erased sits off the middle of the frame, and at 20 degrees one turn can't be
        // mistaken for two.
        var content = TreeContent()
        var drawing = try #require(LayerNode.drawing([
            stroke(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 460, y: 300)),
            stroke(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 400, y: 360)),
            stroke(from: CGPoint(x: 460, y: 300), to: CGPoint(x: 460, y: 420)),
        ]))
        drawing.setRotation(20)
        drawing.scale = 1
        content.canvas.append(drawing)
        var sync = DrawingSync()
        let first = sync.strokes(showing: content, on: [])
        let shown = try #require(first)
        let kept = Array(shown.dropLast())

        sync.changes(for: kept, in: content).apply(to: &content)

        let after = try #require(content.node(drawing.id))
        #expect(after.resolvedRotation == 20)
        #expect(after.strokeCount == 2)
        func ends(_ stroke: PKStroke) -> [CGPoint] {
            [stroke.path.first!, stroke.path.last!].map { $0.location.applying(stroke.transform) }
        }
        for before in kept {
            let now = try #require(after.canvasStrokes.first { $0.key == before.key })
            for (a, b) in zip(ends(before), ends(now)) {
                #expect(abs(a.x - b.x) <= 0.5 && abs(a.y - b.y) <= 0.5)
            }
        }
    }

    /// A rub of the eraser still to be followed as a turn lands on the same drawing (two
    /// hands, or a spoken command mid-rub): its strokes on the canvas still lie at the angle
    /// they were last placed at. They go back upright by that angle, not the new one, so the
    /// difference isn't turned into the ink, and the turn's angle stays.
    @Test func inkFollowedAsATurnLandsGoesBackUprightByTheAngleItLies() throws {
        var content = TreeContent()
        var drawing = try #require(LayerNode.drawing([
            stroke(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 460, y: 300)),
            stroke(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 400, y: 360)),
            stroke(from: CGPoint(x: 460, y: 300), to: CGPoint(x: 460, y: 420)),
        ]))
        drawing.setRotation(20)
        drawing.scale = 1
        content.canvas.append(drawing)
        var sync = DrawingSync()
        let first = sync.strokes(showing: content, on: [])
        let kept = Array(try #require(first).dropLast())
        // The turn lands before the canvas has shown it.
        content.update(drawing.id) { $0.rotation = 50 }

        sync.changes(for: kept, in: content).apply(to: &content)

        let after = try #require(content.node(drawing.id))
        #expect(after.resolvedRotation == 50)
        #expect(after.strokeCount == 2)
        func ends(_ stroke: PKStroke) -> [CGPoint] {
            [stroke.path.first!, stroke.path.last!].map { $0.location.applying(stroke.transform) }
        }
        // Its ink is still upright: the L's arms lie along its own axes.
        var upright = after
        upright.setRotation(0)
        for arm in upright.canvasStrokes.map(ends) {
            #expect(min(abs(arm[0].x - arm[1].x), abs(arm[0].y - arm[1].y)) <= 0.5, "\(arm) is askew")
        }
        // At the angle the canvas showed, it is where the rub left it.
        var asShown = after
        asShown.setRotation(20)
        for before in kept {
            let now = try #require(asShown.canvasStrokes.first { $0.key == before.key })
            for (a, b) in zip(ends(before), ends(now)) {
                #expect(abs(a.x - b.x) <= 0.5 && abs(a.y - b.y) <= 0.5)
            }
        }
    }

    @Test func aStrokeThatJoinsATurnedDrawingStaysWhereItWasDrawn() throws {
        var (content, drawing) = try turnedCross(by: 30)
        var sync = DrawingSync()
        let first = sync.strokes(showing: content, on: [])
        let shown = try #require(first)
        let area = try #require(InkGeometry.bounds(of: shown))
        let added = stroke(from: CGPoint(x: area.midX, y: area.midY), to: CGPoint(x: area.maxX + 40, y: area.midY))
        let all = shown + [added]
        sync.changes(for: all, in: content).apply(to: &content)

        let after = try #require(content.node(drawing.id))
        #expect(content.canvas.count == 1)
        #expect(after.strokeCount == 3)
        #expect(after.resolvedRotation == 30)
        let bounds = try #require(InkGeometry.bounds(of: after.canvasStrokes))
        let expected = try #require(InkGeometry.bounds(of: all))
        #expect(close(bounds, expected))
    }

    @Test func turningADrawingRedrawsItsInkTurned() throws {
        var (content, drawing) = try turnedCross(by: 0)
        var sync = DrawingSync()
        let first = sync.strokes(showing: content, on: [])
        let shown = try #require(first)
        content.update(drawing.id) { $0.rotation = 45 }
        drawing = try #require(content.node(drawing.id))

        let next = sync.strokes(showing: content, on: shown)
        let redrawn = try #require(next)
        let bounds = try #require(InkGeometry.bounds(of: redrawn))
        let expected = try #require(InkGeometry.bounds(of: drawing.canvasStrokes))
        #expect(close(bounds, expected))
        #expect(redrawn.count == 2)
    }
}

/// The Magic Pen's canvas stops taking the Pencil mid-stroke when Draw goes off, by a
/// palette flick, a call or a spoken command. PencilKit may never say that stroke ended,
/// and while the pen was thought down nothing was read again (C-M5).
@Suite("The Magic Pen put away mid-stroke")
@MainActor
struct MagicPenPutAwayTests {
    @Test func thePenIsUpOnceItsCanvasStopsTakingIt() {
        let model = AppModel(document: LayerDocument())
        let coordinator = InkCanvas.Coordinator(model: model)
        coordinator.apply(.draw)
        coordinator.canvasViewDidBeginUsingTool(coordinator.sketchCanvas)
        #expect(model.isPenDown)

        coordinator.apply(.select)
        #expect(!model.isPenDown)
        // And the end, if it does come, changes nothing.
        coordinator.canvasViewDidEndUsingTool(coordinator.sketchCanvas)
        #expect(!model.isPenDown)
    }
}

/// One use of a tool on the document canvas, a pen stroke or a rub of the eraser, is
/// followed at its first change and then once more when it ends: the eraser changes the strokes many times on the way, and
/// each change wrote the whole drawing out again (C-M6).
@Suite("Ink followed once a tool is put down")
@MainActor
struct InkFollowedAtTheEndTests {
    @Test func changesDuringAToolUseAreFollowedWhenItEnds() {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        let coordinator = InkCanvas.Coordinator(model: model)
        let mark = model.store.historyMark

        coordinator.canvasViewDidBeginUsingTool(coordinator.documentCanvas)
        let strokes = cross(at: CGPoint(x: 100, y: 100))
        coordinator.documentCanvas.drawing = PKDrawing(strokes: [strokes[0]])
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
        coordinator.documentCanvas.drawing = PKDrawing(strokes: strokes)
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
        // The first change is followed at once, for the use's step; the rest wait.
        #expect(model.store.tree.canvasLeaves.first?.strokeCount == 1, "followed once more only when the tool is put down")

        coordinator.canvasViewDidEndUsingTool(coordinator.documentCanvas)
        #expect(model.store.tree.canvasLeaves.count == 1)
        #expect(model.store.tree.canvasLeaves.first?.strokeCount == 2)
        #expect(model.store.historyMark == mark + 1)
    }

    /// The design changing mid-use (a spoken command, say) shows its drawings on the canvas:
    /// the ink not yet followed is followed first, not drawn over.
    @Test func inkNotYetFollowedIsKeptWhenTheDesignChangesMidUse() {
        let model = AppModel(document: LayerDocument())
        let coordinator = InkCanvas.Coordinator(model: model)
        model.ink = coordinator
        coordinator.canvasViewDidBeginUsingTool(coordinator.documentCanvas)
        coordinator.documentCanvas.drawing = PKDrawing(strokes: cross(at: CGPoint(x: 100, y: 100)))
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)

        model.store.addScreen(from: CGRect(x: 600, y: 100, width: 200, height: 400))
        #expect(coordinator.documentCanvas.drawing.strokes.count == 2)
        coordinator.canvasViewDidEndUsingTool(coordinator.documentCanvas)
        #expect(model.store.tree.canvasLeaves.first?.strokeCount == 2)
    }

    /// The design closes, or the app goes, mid-stroke: the tool's end may never be heard.
    @Test func inkNotYetFollowedGoesIntoTheDesignWhenItCloses() {
        let model = AppModel(document: LayerDocument())
        let coordinator = InkCanvas.Coordinator(model: model)
        model.ink = coordinator
        coordinator.canvasViewDidBeginUsingTool(coordinator.documentCanvas)
        coordinator.documentCanvas.drawing = PKDrawing(strokes: cross(at: CGPoint(x: 100, y: 100)))
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)

        model.close()
        #expect(model.document.current.content.canvasLeaves.first?.strokeCount == 2)
    }

    /// Undo pressed mid-rub takes back the rub so far, and only that, as it did when every
    /// change was followed at once. The ink waiting was dropped, and undo took back the
    /// step before instead.
    @Test func undoMidUseTakesBackTheToolUseSoFar() {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        let coordinator = InkCanvas.Coordinator(model: model)
        model.ink = coordinator
        coordinator.documentCanvas.documentUndoManager = undo
        coordinator.watchHistory(undo)
        defer { coordinator.stopWatchingHistory() }
        model.store.addScreen(from: CGRect(x: 600, y: 100, width: 200, height: 400))

        coordinator.canvasViewDidBeginUsingTool(coordinator.documentCanvas)
        coordinator.documentCanvas.drawing = PKDrawing(strokes: cross(at: CGPoint(x: 100, y: 100)))
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
        undo.undo()

        #expect(model.store.tree.screens.count == 1, "the screen added before stays")
        #expect(model.store.tree.canvasLeaves.isEmpty)
        coordinator.canvasViewDidEndUsingTool(coordinator.documentCanvas)
    }

    /// Undo mid-rub takes back the whole rub so far, and redo puts all of it back.
    @Test func redoAfterUndoMidUsePutsBackEverything() {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        let coordinator = InkCanvas.Coordinator(model: model)
        model.ink = coordinator
        coordinator.documentCanvas.documentUndoManager = undo
        coordinator.watchHistory(undo)
        defer { coordinator.stopWatchingHistory() }

        coordinator.canvasViewDidBeginUsingTool(coordinator.documentCanvas)
        let strokes = cross(at: CGPoint(x: 100, y: 100))
        coordinator.documentCanvas.drawing = PKDrawing(strokes: [strokes[0]])
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
        coordinator.documentCanvas.drawing = PKDrawing(strokes: strokes)
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)

        undo.undo()
        #expect(model.store.tree.canvasLeaves.isEmpty)
        undo.redo()
        #expect(model.store.tree.canvasLeaves.first?.strokeCount == 2)
        coordinator.canvasViewDidEndUsingTool(coordinator.documentCanvas)
    }

    /// Undo mid-use opens a fresh edit with no step in the history yet. Ink drawn after it
    /// and not yet followed can't join a step as redo begins: registered then, it would be
    /// taken for redo's own. It is dropped, and redo puts back what undo took (final fix 14).
    @Test func inkAfterAnUndoMidUseIsNotTakenForRedosStep() {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        let coordinator = InkCanvas.Coordinator(model: model)
        model.ink = coordinator
        coordinator.documentCanvas.documentUndoManager = undo
        coordinator.watchHistory(undo)
        defer { coordinator.stopWatchingHistory() }

        coordinator.canvasViewDidBeginUsingTool(coordinator.documentCanvas)
        let strokes = cross(at: CGPoint(x: 100, y: 100))
        coordinator.documentCanvas.drawing = PKDrawing(strokes: [strokes[0]])
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
        coordinator.documentCanvas.drawing = PKDrawing(strokes: strokes)
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
        undo.undo()
        #expect(model.store.tree.canvasLeaves.isEmpty)
        #expect(model.store.isEditing && !model.store.editIsInHistory)

        // Still in use: more ink, waiting to be followed, and then redo.
        let later = cross(at: CGPoint(x: 600, y: 600))
        coordinator.documentCanvas.drawing = PKDrawing(strokes: later)
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
        undo.redo()
        #expect(model.store.tree.canvasLeaves.count == 1)
        #expect(model.store.tree.canvasLeaves.first?.strokeCount == 2)
        coordinator.canvasViewDidEndUsingTool(coordinator.documentCanvas)
        // Undo once more takes back the use, and nothing else is left in the history.
        undo.undo()
        #expect(model.store.tree.canvasLeaves.isEmpty)
    }
}

