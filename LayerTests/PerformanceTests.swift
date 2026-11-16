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
