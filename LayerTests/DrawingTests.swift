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

        let drawing = try #require(DesignElement.drawing(strokes))

        #expect(drawing.kind == .drawing)
        #expect(drawing.frame == area)
        #expect(drawing.strokeCount == 2)
        #expect(drawing.canvasStrokes.map(\.key) == strokes.map(\.key))
        #expect(close(try #require(InkGeometry.bounds(of: drawing.canvasStrokes)), area))
    }

    @Test func movingADrawingsFrameMovesItsInk() throws {
        var drawing = try #require(DesignElement.drawing(cross(at: CGPoint(x: 400, y: 300))))
        let ink = drawing.ink

        drawing.frame.origin = CGPoint(x: 1000, y: 50)

        #expect(drawing.ink == ink, "the ink itself is untouched")
        #expect(close(try #require(InkGeometry.bounds(of: drawing.canvasStrokes)), drawing.frame))
    }

    @Test func resizingADrawingsFrameStretchesItsInk() throws {
        var drawing = try #require(DesignElement.drawing(cross(at: CGPoint(x: 400, y: 300))))

        drawing.frame.size = CGSize(width: drawing.frame.width * 2, height: drawing.frame.height * 0.5)

        #expect(close(try #require(InkGeometry.bounds(of: drawing.canvasStrokes)), drawing.frame, within: 1))
    }

    @Test func noStrokesMakeNoDrawing() {
        #expect(DesignElement.drawing([]) == nil)
    }

    @Test func strokesThatTouchAreOneDrawingAndThoseApartAreSeparate() {
        let here = cross(at: CGPoint(x: 100, y: 100))
        let there = cross(at: CGPoint(x: 900, y: 600))
        let groups = InkGeometry.groups([here[0], there[0], here[1], there[1]])
        #expect(groups.map { $0.map(\.key) }.sorted { $0[0] < $1[0] } == [here.map(\.key), there.map(\.key)])
    }

    @Test func inkSavedAsOneDrawingForTheBoardBecomesDrawingsOnTheOpenCanvas() throws {
        var content = DesignContent()
        content.adopt(PKDrawing(strokes: cross(at: CGPoint(x: 100, y: 100)) + cross(at: CGPoint(x: 900, y: 600))))

        #expect(content.elements.map(\.kind) == [.drawing, .drawing])
        #expect(content.elements.allSatisfy { $0.parent == nil && $0.scale == 1 })
        #expect(content.floating.count == 2)
        #expect(content.visibleInk.strokes.count == 4)
    }
}

@Suite("Keeping drawings and the ink canvas in step")
struct DrawingSyncTests {
    /// The canvas as it is once it shows `content`.
    private func canvas(showing content: DesignContent, with sync: inout DrawingSync, holding current: [PKStroke] = []) -> [PKStroke] {
        sync.strokes(showing: content, on: current) ?? current
    }

    @Test func strokesDrawnOnAnEmptyCanvasBecomeADrawing() throws {
        var sync = DrawingSync()
        var content = DesignContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))

        let changes = sync.changes(for: strokes, in: content)
        changes.apply(to: &content)

        #expect(changes.drawings.count == 1)
        #expect(changes.removed.isEmpty)
        let drawing = try #require(content.elements.first)
        #expect(drawing.kind == .drawing)
        #expect(drawing.strokeCount == 2)
        #expect(sync.drawing(owning: strokes[0].key) == drawing.id)
        // The canvas already shows what the design now holds: nothing to put there.
        let toShow = sync.strokes(showing: content, on: strokes)
        #expect(toShow == nil)
    }

    @Test func aStrokeThatTouchesADrawingJoinsItAndOneApartStartsAnother() throws {
        var sync = DrawingSync()
        var content = DesignContent()
        var strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let first = try #require(content.elements.first)

        strokes.append(stroke(from: CGPoint(x: 430, y: 300), to: CGPoint(x: 430, y: 360)))
        sync.changes(for: strokes, in: content).apply(to: &content)
        #expect(content.elements.map(\.id) == [first.id])
        #expect(content.elements.first?.strokeCount == 3)

        strokes.append(stroke(from: CGPoint(x: 1200, y: 800), to: CGPoint(x: 1300, y: 800)))
        sync.changes(for: strokes, in: content).apply(to: &content)
        #expect(content.elements.count == 2)
        #expect(content.elements.map(\.strokeCount) == [3, 1])
    }

    @Test func nothingIsWorkedOutAgainForDrawingsThatDidNotChange() {
        var sync = DrawingSync()
        var content = DesignContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)

        let again = sync.changes(for: strokes, in: content)
        #expect(again.isEmpty)
    }

    @Test func erasingAllOfADrawingsStrokesRemovesTheDrawing() throws {
        var sync = DrawingSync()
        var content = DesignContent()
        let kept = cross(at: CGPoint(x: 100, y: 100))
        let erased = cross(at: CGPoint(x: 900, y: 600))
        sync.changes(for: kept + erased, in: content).apply(to: &content)
        #expect(content.elements.count == 2)
        let gone = try #require(sync.drawing(owning: erased[0].key))

        let changes = sync.changes(for: kept, in: content)
        changes.apply(to: &content)

        #expect(changes.removed == [gone])
        #expect(content.elements.count == 1)
    }

    @Test func aDrawingKeepsItsNameWhenAStrokeIsAdded() throws {
        var sync = DrawingSync()
        var content = DesignContent()
        var strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let id = try #require(content.elements.first?.id)
        content.update(id) { $0.name = "Arrow" }

        strokes.append(stroke(from: CGPoint(x: 430, y: 300), to: CGPoint(x: 430, y: 360)))
        sync.changes(for: strokes, in: content).apply(to: &content)

        #expect(content.element(id)?.name == "Arrow")
        #expect(content.element(id)?.strokeCount == 3)
    }

    @Test func aMovedDrawingIsShownWhereItNowIs() throws {
        var sync = DrawingSync()
        var content = DesignContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let id = try #require(content.elements.first?.id)

        content.update(id) { $0.frame.origin.x += 500 }
        let toShow = sync.strokes(showing: content, on: strokes)
        let shown = try #require(toShow)

        #expect(shown.map(\.key) == strokes.map(\.key), "the same strokes, in the same order")
        #expect(close(try #require(InkGeometry.bounds(of: shown)), try #require(content.element(id)).frame))
        // Now that the canvas shows it, the two agree again.
        let more = sync.strokes(showing: content, on: shown)
        #expect(more == nil)
        let changes = sync.changes(for: shown, in: content)
        #expect(changes.isEmpty)
    }

    @Test func lockedAndHiddenDrawingsAreKeptOffTheCanvasAndComeBack() throws {
        var sync = DrawingSync()
        var content = DesignContent()
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
        #expect(content.element(locked) != nil)

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
        var content = DesignContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let id = try #require(content.elements.first?.id)

        content.remove([id])

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
        let store = DesignStore(content: DesignContent())
        store.undoManager = undo
        var sync = DrawingSync()
        let changes = sync.changes(for: cross(at: CGPoint(x: 400, y: 300)), in: store.content)
        store.apply { changes.apply(to: &$0) }
        let drawing = try #require(store.floating.first)
        return (store, undo, DesignStore.ElementRef(host: .canvas, element: drawing.id))
    }

    @Test func inkDrawnOnTheCanvasIsAnUndoStepOfTheDesigns() throws {
        let (store, undo, ref) = try storeWithDrawing()
        #expect(store.floating.map(\.element.kind) == [.drawing])
        let drawn = store.resolve(ref)?.element

        undo.undo()
        #expect(store.floating.isEmpty)
        undo.redo()
        #expect(store.resolve(ref)?.element == drawn, "redo brings back the same drawing, not another like it")
    }

    @Test func aDrawingIsLockedHiddenCopiedAndDeletedLikeAnyElement() throws {
        let (store, undo, ref) = try storeWithDrawing()

        store.update(ref) { $0.isLocked = true }
        #expect(store.resolve(ref)?.element.isLocked == true)

        let copy = try #require(store.duplicate(ref))
        #expect(store.floating.map(\.element.kind) == [.drawing, .drawing])
        #expect(store.resolve(copy)?.element.strokeCount == 2)
        #expect(store.resolve(copy)?.element.frame.size == store.resolve(ref)?.element.frame.size)
        #expect(store.resolve(copy)?.element.isLocked == false)

        store.delete(ref)
        #expect(store.floating.map(\.id) == [copy.element])
        undo.undo()
        #expect(store.floating.count == 2)
    }

    @Test func aCopiedDrawingHasStrokesOfItsOwn() throws {
        let (store, _, ref) = try storeWithDrawing()
        let copy = try #require(store.duplicate(ref))
        let original = try #require(store.resolve(ref)?.element)
        let copied = try #require(store.resolve(copy)?.element)
        let keys = (original.canvasStrokes + copied.canvasStrokes).map(\.key)
        #expect(Set(keys).count == 4, "no two strokes on the canvas may be taken for the same one")

        // On the canvas, with a stroke then drawn elsewhere, the two stay two drawings.
        var sync = DrawingSync()
        let toShow = sync.strokes(showing: store.content, on: [])
        var held = try #require(toShow)
        held.append(stroke(from: CGPoint(x: 1500, y: 900), to: CGPoint(x: 1600, y: 900)))
        var content = store.content
        sync.changes(for: held, in: content).apply(to: &content)
        #expect(content.elements.map(\.strokeCount) == [2, 2, 1])
        #expect(content.element(original.id)?.frame == original.frame)
        #expect(content.element(copied.id)?.frame == copied.frame)
    }

    @Test func aDrawingStaysOnTheOpenCanvas() throws {
        let (store, _, ref) = try storeWithDrawing()
        let screen = store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 300, y: 200), scale: 1))
        #expect(store.move(ref, toScreen: screen.id, origin: .zero) == nil)
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
        let drawing = try #require(file.content.elements.first)

        let package = try file.wrapper()

        let ink = try #require(package.fileWrappers?[DesignPackage.ink]?.fileWrappers)
        #expect(ink[drawing.id.uuidString]?.regularFileContents == drawing.ink)
        #expect(package.fileWrappers?[DesignPackage.drawing] == nil, "ink is no longer one drawing for the whole board")
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
        let name = try #require(file.content.elements.first?.id.uuidString)

        file.content.title = "Renamed"
        let second = try file.wrapper(replacing: first)

        #expect(second.fileWrappers?[DesignPackage.ink]?.fileWrappers?[name] === first.fileWrappers?[DesignPackage.ink]?.fileWrappers?[name])
    }

    @Test func aPackageSavedWithAllItsInkAsOneDrawingOpensWithDrawings() throws {
        let manifest = try JSONSerialization.data(withJSONObject: ["version": 2, "content": ["screens": [], "floating": []]])
        let whole = PKDrawing(strokes: cross(at: CGPoint(x: 100, y: 100)) + cross(at: CGPoint(x: 900, y: 600)))
        let package = FileWrapper(directoryWithFileWrappers: [
            DesignPackage.design: FileWrapper(regularFileWithContents: manifest),
            DesignPackage.drawing: FileWrapper(regularFileWithContents: whole.dataRepresentation()),
        ])

        let file = try DesignFile(wrapper: package)

        #expect(file.content.elements.map(\.kind) == [.drawing, .drawing])
        #expect(file.drawing.strokes.count == 4)
    }
}

@Suite("Turned drawings")
struct TurnedDrawingTests {
    private func turnedCross(by degrees: Double) throws -> (DesignContent, DesignElement) {
        var content = DesignContent()
        var drawing = try #require(DesignElement.drawing(cross(at: CGPoint(x: 400, y: 300))))
        drawing.setRotation(degrees)
        content.add(drawing, to: nil, scale: 1)
        return (content, drawing)
    }

    @Test func aTurnedDrawingsInkIsTurnedAboutItsMiddle() throws {
        var drawing = try #require(DesignElement.drawing([stroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100))]))
        drawing.setRotation(90)
        let bounds = try #require(InkGeometry.bounds(of: drawing.canvasStrokes))
        #expect(abs(bounds.midX - 150) <= 1)
        #expect(abs(bounds.midY - 100) <= 1)
        #expect(bounds.height >= 99)
        #expect(bounds.width <= 6)
    }

    @Test func stretchingATurnedDrawingNeverShearsIt() throws {
        var drawing = try #require(DesignElement.drawing(cross(at: CGPoint(x: 400, y: 300))))
        drawing.setRotation(30)
        drawing.frame.size.width *= 2
        for stroke in drawing.canvasStrokes {
            let t = stroke.transform
            #expect(abs(t.a * t.c + t.b * t.d) < 1e-6)
        }
    }

    @Test func erasingPartOfATurnedDrawingLeavesTheRestWhereItWas() throws {
        var (content, drawing) = try turnedCross(by: 30)
        var sync = DrawingSync()
        let first = sync.strokes(showing: content, on: [])
        let shown = try #require(first)
        sync.changes(for: Array(shown.dropFirst()), in: content).apply(to: &content)

        let after = try #require(content.element(drawing.id))
        #expect(after.resolvedRotation == 30)
        let bounds = try #require(InkGeometry.bounds(of: after.canvasStrokes))
        #expect(close(bounds, shown[1].renderBounds))
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

        let after = try #require(content.element(drawing.id))
        #expect(content.elements.count == 1)
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
        content.update(drawing.id) { $0.setRotation(45) }
        drawing = try #require(content.element(drawing.id))

        let next = sync.strokes(showing: content, on: shown)
        let redrawn = try #require(next)
        let bounds = try #require(InkGeometry.bounds(of: redrawn))
        let expected = try #require(InkGeometry.bounds(of: drawing.canvasStrokes))
        #expect(close(bounds, expected))
        #expect(redrawn.count == 2)
    }
}
