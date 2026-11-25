import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

private nonisolated(unsafe) var lastStrokeDate = Date(timeIntervalSinceReferenceDate: 810_000_000)

/// A straight pen stroke between two canvas points, each with a later creation date.
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

private func cross(at origin: CGPoint, size: CGFloat = 60) -> [PKStroke] {
    [
        stroke(from: origin, to: CGPoint(x: origin.x + size, y: origin.y + size)),
        stroke(from: CGPoint(x: origin.x + size, y: origin.y), to: CGPoint(x: origin.x, y: origin.y + size)),
    ]
}

@MainActor
@Suite("Ink on the tree")
struct InkOnTheTreeTests {
    @Test func aStrokeMakesADrawingNodeOnTheCanvas() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        let strokes = cross(at: CGPoint(x: 400, y: 300))

        sync.changes(for: strokes, in: content).apply(to: &content)

        let node = try #require(content.canvas.last)
        #expect(content.canvas.count == 1)
        #expect(node.kind == .drawing)
        #expect(node.scale == 1)
        #expect(node.frame == InkGeometry.bounds(of: strokes))
        #expect(node.content.ink != nil)
        #expect(node.canvasStrokes.count == 2)
        #expect(sync.drawing(owning: strokes[0].key) == node.id)
        #expect(DrawingSync.onCanvas(content).map(\.id) == [node.id])
    }

    @Test func aStrokeNearADrawingJoinsIt() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        var strokes = cross(at: CGPoint(x: 400, y: 300))
        sync.changes(for: strokes, in: content).apply(to: &content)
        let first = try #require(content.canvas.first)

        strokes.append(stroke(from: CGPoint(x: 430, y: 300), to: CGPoint(x: 430, y: 360)))
        sync.changes(for: strokes, in: content).apply(to: &content)

        #expect(content.canvas.map(\.id) == [first.id])
        #expect(content.canvas[0].canvasStrokes.count == 3)
        #expect(content.canvas[0].content.ink != first.content.ink)
    }

    @Test func aDrawingWithNoStrokesLeftGoes() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        let near = cross(at: CGPoint(x: 400, y: 300))
        let far = cross(at: CGPoint(x: 900, y: 700))
        sync.changes(for: near + far, in: content).apply(to: &content)
        let gone = try #require(content.canvas.first?.id)

        let changes = sync.changes(for: far, in: content)
        changes.apply(to: &content)

        #expect(changes.removed == [gone])
        #expect(content.canvas.count == 1)
        #expect(content.canvas.first?.id != gone)
    }

    @Test func aTurnedDrawingKeepsItsAngleWhenExtended() throws {
        var sync = DrawingSync()
        var content = TreeContent()
        var turned = try #require(LayerNode.drawing(cross(at: CGPoint(x: 400, y: 300))))
        turned.rotation = 20
        content.canvas.append(turned)
        let shown = sync.strokes(showing: content, on: [])
        var strokes = try #require(shown)
        let before = try #require(InkGeometry.bounds(of: strokes))

        // A stroke across the top of the cross as it lies turned on the canvas.
        let added = stroke(from: CGPoint(x: before.minX, y: before.minY - 4), to: CGPoint(x: before.maxX, y: before.minY - 4))
        strokes.append(added)
        let changes = sync.changes(for: strokes, in: content)
        changes.apply(to: &content)

        let node = try #require(content.canvas.first)
        #expect(content.canvas.count == 1)
        #expect(node.rotation == 20, "no double turn")
        let now = try #require(InkGeometry.bounds(of: node.canvasStrokes))
        let wanted = try #require(InkGeometry.bounds(of: strokes))
        #expect(abs(now.minX - wanted.minX) < 2 && abs(now.maxX - wanted.maxX) < 2)
        #expect(abs(now.minY - wanted.minY) < 2 && abs(now.maxY - wanted.maxY) < 2)
    }

    #if DEBUG
    @Test func showingDrawingsDoesNotLower() throws {
        let model = AppModel(document: LayerDocument())
        let store = model.store
        let screen = store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1)).id
        var sync = DrawingSync()
        let strokes = cross(at: CGPoint(x: 700, y: 300))
        model.inkChanged(sync.changes(for: strokes, in: store.tree))
        // The canvas already shows what the design now holds.
        let held = strokes
        #expect(sync.strokes(showing: store.tree, on: held) == nil)

        // A change elsewhere, so the store's memo of the lowered design is stale, and proof the counter is live.
        store.updateTreeScreen(screen) { $0.name = "Elsewhere" }
        let live = TreeProjection.lowerings(of: screen)
        _ = store.screens
        #expect(TreeProjection.lowerings(of: screen) == live + 1, "a read of the projection is counted")

        store.updateTreeScreen(screen) { $0.name = "Elsewhere again" }
        let (lowered, counted) = (TreeProjection.lowerings(of: screen), CanvasWork.strokesRead)
        var reads = 0
        let shown = sync.strokes(showing: store.tree, reading: { reads += 1; return held })
        let changes = sync.changes(for: held, in: store.tree)

        #expect(shown == nil)
        #expect(changes.isEmpty)
        #expect(reads == 0, "the canvas's strokes are not read when no drawing changed")
        #expect(CanvasWork.strokesRead == counted)
        #expect(TreeProjection.lowerings(of: screen) == lowered, "following the drawings lowers nothing")
    }
    #endif
}
