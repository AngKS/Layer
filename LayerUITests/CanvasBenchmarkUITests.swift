import XCTest

/// A repeatable workout for the canvas, measured: the same pans, zooms, frame drags and
/// Magic Pen strokes every run, so that two builds can be compared fairly. It is slow, so
/// it only runs when asked for:
///
///     TEST_RUNNER_LAYER_BENCHMARK=1 xcodebuild test -configuration Release \
///       -only-testing:LayerUITests/CanvasBenchmarkUITests ...
///
/// Compare the CPU time it reports between builds; the clock time is mostly the script's
/// own waiting.
@MainActor
final class CanvasBenchmarkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LAYER_BENCHMARK"] != nil, "set TEST_RUNNER_LAYER_BENCHMARK=1 to run")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-convertsAutomatically", "NO"]
    }

    func testCanvasWorkout() {
        openNewDesign()
        // A board with something on it: three phone frames.
        for _ in 0..<3 {
            control("Library").tap()
            app.buttons["Wireframes"].tap()
            let iPhone = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'iPhone'")).firstMatch
            XCTAssertTrue(iPhone.waitForExistence(timeout: 5))
            iPhone.tap()
            sleep(1)
        }
        // Select mode: a finger on empty canvas pans.
        control("Draw").tap()
        point(CGPoint(x: 120, y: 700)).tap()

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
            workout()
        }
    }

    private func workout() {
        // Pans, there and back.
        for _ in 0..<3 {
            drag(CGPoint(x: 160, y: 420), CGPoint(x: 420, y: 560))
            drag(CGPoint(x: 420, y: 560), CGPoint(x: 160, y: 420))
        }
        // Zooms in and out, by the zoom's menu.
        for level in ["200%", "100%", "50%", "100%"] {
            control("Zoom").tap()
            app.buttons[level].tap()
            usleep(400_000)
        }
        // A frame dragged by its name and back.
        let label = app.staticTexts["Screen 1"]
        if label.exists {
            let start = CGPoint(x: label.frame.midX, y: label.frame.midY)
            drag(start, CGPoint(x: start.x + 160, y: start.y + 40))
            drag(CGPoint(x: start.x + 160, y: start.y + 40), start)
        }
        // Magic Pen strokes on open canvas, then back to selecting.
        control("Draw").tap()
        for row in 0..<6 {
            let y = 300 + CGFloat(row) * 40
            drag(CGPoint(x: 80, y: y), CGPoint(x: 220, y: y + 20))
        }
        control("Draw").tap()
        point(CGPoint(x: 120, y: 700)).tap()
    }

    // MARK: Helpers

    private func openNewDesign() {
        app.launch()
        XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 45))
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", "New Design"))
        sleep(2)
        var newDesign: XCUIElement?
        for _ in 0..<30 where newDesign == nil {
            newDesign = (0..<buttons.count).map(buttons.element(boundBy:)).first { $0.exists && $0.isHittable }
            if newDesign == nil { usleep(300_000) }
        }
        newDesign?.tap()
        XCTAssertTrue(control("Draw").waitForExistence(timeout: 20))
        sleep(2)
    }

    private func control(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func point(_ location: CGPoint) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: location.x, dy: location.y))
    }

    private func drag(_ start: CGPoint, _ end: CGPoint) {
        point(start).press(forDuration: 0.05, thenDragTo: point(end), withVelocity: .default, thenHoldForDuration: 0.05)
    }
}
