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

    @Test func sixteenPointsOfFingerOrTenDegreesOfBarrelIsAStop() {
        #expect(Scrubber.steps(forDrag: 40, pointsPerStep: ZoomStops.pointsPerStop) == 2)
        #expect(Scrubber.steps(forRoll: .degrees(25), degreesPerStep: ZoomStops.degreesPerStop) == 2)
    }
}
