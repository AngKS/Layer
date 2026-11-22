import Testing
import SwiftUI
@testable import Layer

/// The stops the zoom's ruler steps through.
@MainActor
@Suite("Zoom stops")
struct ZoomStopsTests {
    @Test func theStopsRunFrom10To400Percent() {
        #expect(ZoomStops.percents.count == 15)
        #expect(ZoomStops.percents.first == 10)
        #expect(ZoomStops.percents.last == 400)
        #expect(ZoomStops.scale(at: 8) == 1)
        #expect(ZoomStops.scale(at: -3) == 0.1)
        #expect(ZoomStops.scale(at: 99) == 4)
        for index in ZoomStops.percents.indices {
            #expect(Viewport.zoomRange.contains(ZoomStops.scale(at: index)))
        }
    }

    @Test func aZoomBetweenStopsStartsAtTheNearestByRatio() {
        #expect(ZoomStops.nearestIndex(to: 0.9) == 8)
        #expect(ZoomStops.nearestIndex(to: 1.0) == 8)
        #expect(ZoomStops.nearestIndex(to: 0.8) == 7)
        #expect(ZoomStops.nearestIndex(to: 0.29) == 4)
        #expect(ZoomStops.nearestIndex(to: 1.0 / 3) == 4)
        #expect(ZoomStops.nearestIndex(to: 0.05) == 0)
        #expect(ZoomStops.nearestIndex(to: 5) == 14)
    }

    @Test func voiceOverStepsToTheNextStopAboveOrBelow() {
        #expect(ZoomStops.step(from: 0.9, by: 1) == 1)
        #expect(ZoomStops.step(from: 0.9, by: -1) == 0.75)
        #expect(ZoomStops.step(from: 1, by: 1) == 1.25)
        #expect(ZoomStops.step(from: 1, by: -1) == 0.75)
        #expect(ZoomStops.step(from: 1.0 / 3, by: -1) == 0.25)
        #expect(ZoomStops.step(from: 0.5, by: 2) == 0.75)
        #expect(ZoomStops.step(from: 4, by: 1) == 4)
        #expect(ZoomStops.step(from: 0.1, by: -1) == 0.1)
    }

    @Test func theZoomsRulerStepsThroughStopsAndShowsPercent() {
        var zooms: [CGFloat] = []
        let target = ZoomStops.target(frame: .zero, current: { 0.9 }, zoom: { zooms.append($0) })
        let scrubber = Scrubber()
        scrubber.begin(target)
        #expect(scrubber.value == 8)
        #expect(zooms.isEmpty)
        scrubber.scrub(to: 1)
        scrubber.scrub(to: 2)
        scrubber.scrub(to: -1)
        #expect(zooms == [1.25, 1.5, 0.75])
        scrubber.scrub(to: 50)
        #expect(zooms.last == 4)
        #expect(target.shown(8) == "100%")
        #expect(target.isMajor(8))
        #expect(!target.isMajor(9))
        #expect(target.owner == .zoom)
    }

    /// Undo or Redo coming or going mid-hold moves the zoom control along: it is still the
    /// same hold, not a new scrub that takes the whole drag again from where the zoom is now.
    @Test func aZoomHoldIsOneScrubWhenTheControlMoves() {
        var scale: CGFloat = 1
        var zooms: [CGFloat] = []
        func zoom(at x: CGFloat) -> Scrubber.Target {
            ZoomStops.target(
                frame: CGRect(x: x, y: 770, width: 60, height: 44),
                current: { scale }, zoom: { scale = $0; zooms.append($0) }
            )
        }
        let scrubber = Scrubber()
        var begins = 0
        var ends = 0
        scrubber.onBegin = { begins += 1 }
        scrubber.onEnd = { ends += 1 }

        // Two stops' worth of finger.
        scrubber.fingerDragged(zoom(at: 108), by: 32)
        #expect(zooms == [1.5])
        // Undo appears, and the control is 51 pt along at the next drag event.
        scrubber.fingerDragged(zoom(at: 159), by: 32)
        #expect(zooms == [1.5], "the same hold, so no more stops")
        scrubber.fingerDragged(zoom(at: 159), by: 48)
        #expect(zooms == [1.5, 2])
        #expect(begins == 0 && ends == 0)

        // A finger holding the zoom still puts a Format field's ruler away first.
        scrubber.end()
        let field = Scrubber.Target(
            label: "Opacity", unit: "%", frame: CGRect(x: 0, y: 0, width: 80, height: 32), range: 0...100,
            get: { 50 }, set: { _ in }
        )
        scrubber.begin(field)
        scrubber.fingerDragged(zoom(at: 159), by: 16)
        #expect(scrubber.target?.owner == .zoom)
        #expect(begins == 1 && ends == 1)
    }

    @Test func sixteenPointsOfFingerOrTenDegreesOfBarrelIsAStop() {
        #expect(Scrubber.steps(forDrag: 40, pointsPerStep: ZoomStops.pointsPerStop) == 2)
        #expect(Scrubber.steps(forRoll: .degrees(25), degreesPerStep: ZoomStops.degreesPerStop) == 2)
    }
}
