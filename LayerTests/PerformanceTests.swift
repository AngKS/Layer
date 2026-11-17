import CoreGraphics
import PencilKit
import UIKit
import XCTest
@testable import Layer

/// Measured workouts for a few hot paths. `measure` reports wall-clock time per
/// iteration, which is what `xcodebuild test` prints to the log; compare the numbers
/// printed before and after a change to this file's neighbours in `Layer/`.

/// `DesignIndexer.designChanged` is called every time a design's content changes, which
/// includes every frame of a drag, not just when it ends. It must stay cheap however often
/// it is called in a burst.
@MainActor
final class DesignIndexerPerformanceTests: XCTestCase {
    func testManyChangesInARowAreCheapToSchedule() {
        let model = AppModel(document: LayerDocument())
        model.fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).layer")
        defer { model.close() }

        measure {
            for _ in 0..<3000 {
                DesignIndexer.designChanged(model)
            }
        }
    }
}

/// Saving a design re-encodes `drawing.data` every time, even when only the design's
/// screens and elements changed and the ink was left untouched. That should be cheap.
@MainActor
final class DesignFilePerformanceTests: XCTestCase {
    /// A drawing substantial enough that re-encoding it every save would show up.
    private func heavyDrawing(strokeCount: Int = 60) -> PKDrawing {
        let strokes = (0..<strokeCount).map { index in
            let rect = CGRect(x: CGFloat(index % 10) * 40, y: CGFloat(index / 10) * 60, width: 320, height: 40)
            let points = SketchSamples.wave(rect, humps: 6).enumerated().map { offset, point in
                PKStrokePoint(location: point, timeOffset: Double(offset) * 0.008, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: Double(index)))
            return PKStroke(ink: PKInk(.monoline, color: .black), path: path)
        }
        return PKDrawing(strokes: strokes)
    }

    func testSavingAgainAfterAnUnrelatedChangeLeavesTheInkAlone() throws {
        var file = DesignFile(drawing: heavyDrawing())
        var saved = try file.wrapper()

        measure {
            for index in 0..<30 {
                file.content.title = "Board \(index)"
                saved = try! file.wrapper(replacing: saved)
            }
        }
    }
}

/// While a Magic Pen stroke is being drawn, `InkCanvas.Coordinator` is told the sketch
/// changed on every touch event. Only the stroke still being drawn should have to be
/// turned into points again; strokes already finished shouldn't be redone on every touch.
@MainActor
final class InkCanvasPerformanceTests: XCTestCase {
    private func stroke(_ points: [CGPoint], key: Double) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.008, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSinceReferenceDate: key))
        return PKStroke(ink: PKInk(.monoline, color: .black), path: path)
    }

    func testDrawingOneStrokeDoesNotRedoTheStrokesAlreadyOnTheCanvas() {
        let model = AppModel(document: LayerDocument())
        let coordinator = InkCanvas.Coordinator(model: model)

        let finished = (0..<15).map { index in
            stroke(SketchSamples.wave(CGRect(x: 0, y: CGFloat(index) * 50, width: 320, height: 30), humps: 5), key: Double(index))
        }
        let growingPoints = SketchSamples.wave(CGRect(x: 0, y: 900, width: 320, height: 30), humps: 5)
        XCTAssertGreaterThan(growingPoints.count, 50, "the stroke needs enough points to make the workout worth measuring")

        coordinator.sketchCanvas.drawing = PKDrawing(strokes: finished)
        coordinator.canvasViewDrawingDidChange(coordinator.sketchCanvas)

        measure {
            for count in 2...growingPoints.count {
                let growing = stroke(Array(growingPoints.prefix(count)), key: 1000)
                coordinator.sketchCanvas.drawing = PKDrawing(strokes: finished + [growing])
                coordinator.canvasViewDrawingDidChange(coordinator.sketchCanvas)
            }
        }
    }
}

/// Wave 3: the ink on a busy board. Each workout is a hot path that ran on the main
/// thread at the display's rate.
@MainActor
final class InkBoardPerformanceTests: XCTestCase {
    /// `count` strokes in a band at `origin`, each a wave of about 80 points.
    private func strokes(_ count: Int, at origin: CGPoint, firstKey: Double) -> [PKStroke] {
        (0..<count).map { index in
            let rect = CGRect(x: origin.x + CGFloat(index % 5) * 30, y: origin.y + CGFloat(index / 5) * 12, width: 160, height: 10)
            let points = SketchSamples.wave(rect, humps: 4).enumerated().map { offset, point in
                PKStrokePoint(location: point, timeOffset: Double(offset) * 0.008, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: firstKey + Double(index)))
            return PKStroke(ink: PKInk(.pen, color: .black), path: path)
        }
    }

    /// A board of 30 drawings of 40 strokes each, 1200 strokes in all.
    private func board() -> DesignContent {
        var content = DesignContent()
        for index in 0..<30 {
            let origin = CGPoint(x: CGFloat(index % 6) * 400, y: CGFloat(index / 6) * 400)
            let drawing = DesignElement.drawing(strokes(40, at: origin, firstKey: Double(index) * 1000))!
            content.add(drawing, to: nil, scale: 1)
        }
        return content
    }

    /// One drawing dragged across a busy board: every frame the ink canvas is given the
    /// design's drawings again (I5).
    func testDraggingOneDrawingAmongManyRedoesOnlyThatOne() {
        var content = board()
        let dragged = content.elements[0].id
        var sync = DrawingSync()
        var shown = sync.strokes(showing: content, on: []) ?? []

        measure {
            for _ in 0..<30 {
                content.update(dragged) { $0.frame.origin.x += 2 }
                shown = sync.strokes(showing: content, on: shown) ?? shown
            }
        }
    }

    /// A big drawing selected while the canvas pans: the selection's summary is worked out
    /// every frame (I4).
    func testCountingTheStrokesOfASelectedDrawingEveryFrame() {
        let drawing = DesignElement.drawing(strokes(400, at: .zero, firstKey: 0))!
        var total = 0
        measure {
            for _ in 0..<120 { total += drawing.strokeCount }
        }
        XCTAssertEqual(total % 400, 0)
    }

    /// The Pencil hovering over a busy board, at its rate of 120 a second (M1).
    func testHoveringOverABusyBoard() {
        let model = AppModel(document: LayerDocument())
        let coordinator = InkCanvas.Coordinator(model: model)
        let content = board()
        model.store.apply { $0 = content }
        coordinator.showDrawings()
        XCTAssertEqual(coordinator.documentCanvas.drawing.strokes.count, 1200)

        measure {
            for step in 0..<120 {
                _ = coordinator.drawing(at: CGPoint(x: 2300 + CGFloat(step), y: 1900), tolerance: 8)
            }
        }
    }

    /// One more stroke on a drawing that already has many (M6).
    func testAddingAStrokeToABigDrawing() {
        let model = AppModel(document: LayerDocument())
        let coordinator = InkCanvas.Coordinator(model: model)
        let first = strokes(400, at: .zero, firstKey: 0)
        coordinator.documentCanvas.drawing = PKDrawing(strokes: first)
        coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
        var added = first
        var key = 10_000.0

        measure {
            for _ in 0..<10 {
                key += 1
                added += strokes(1, at: CGPoint(x: 20, y: 20), firstKey: key)
                coordinator.documentCanvas.drawing = PKDrawing(strokes: added)
                coordinator.canvasViewDrawingDidChange(coordinator.documentCanvas)
            }
        }
    }
}

