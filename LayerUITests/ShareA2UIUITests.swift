import XCTest

/// The share menu offers the selected screen's A2UI.
@MainActor
final class ShareA2UIUITests: XCTestCase {
    func testTheShareMenuOffersTheScreensA2UI() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-convertsAutomatically", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 45), "the document browser should appear at launch")

        // The launch screen slides into place; its button can't be tapped until it settles.
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", "New Design"))
        sleep(2)
        var newDesign: XCUIElement?
        for _ in 0..<30 where newDesign == nil {
            newDesign = (0..<buttons.count).map(buttons.element(boundBy:)).first { $0.exists && $0.isHittable }
            if newDesign == nil { usleep(300_000) }
        }
        XCTAssertNotNil(newDesign, "the launch screen should offer a new design")
        newDesign?.tap()
        XCTAssertTrue(control(app, "Draw").waitForExistence(timeout: 20), "creating a design should open its canvas")

        // A screen from the library's wireframes.
        control(app, "Library").tap()
        let tab = app.buttons["Wireframes"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "the library should open")
        tab.tap()
        let frame = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "iPhone")).firstMatch
        XCTAssertTrue(frame.waitForExistence(timeout: 5))
        frame.tap()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10), "the screen should be added")

        control(app, "Share").tap()
        XCTAssertTrue(app.buttons["A2UI JSON"].waitForExistence(timeout: 5), "the share menu should offer the screen's A2UI")
    }

    private func control(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
