import UIKit
import XCTest

/// A2UI pasted from the add menu becomes a screen, and what wasn't brought in as it was written is said (plan 3,
/// Task 10).
@MainActor
final class A2UIImportUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The official A2UI login form (LayerTests/Fixtures/A2UI/a2ui-scaffold-simple-login-form.json), written out here:
    /// the fixtures are in the unit tests' bundle, not this one (F19). Its button has an action, which Layer never runs.
    private static let loginForm = #"""
        {"name":"Simple Login Form","messages":[
          {"version":"1.0","createSurface":{"surfaceId":"gallery-simple-login-form","catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json","sendDataModel":true}},
          {"version":"1.0","updateComponents":{"surfaceId":"gallery-simple-login-form","components":[
            {"id":"root","component":"Column","children":["form_title","username_field","password_field","submit_button"],"justify":"start","align":"stretch"},
            {"id":"form_title","component":"Text","text":"## Login"},
            {"id":"username_field","component":"TextField","label":"Username","value":{"@path":"/username"},"variant":"shortText"},
            {"id":"password_field","component":"TextField","label":"Password","value":{"@path":"/password"},"variant":"obscured"},
            {"id":"submit_button","component":"Button","child":"submit_label","variant":"primary",
             "action":{"event":{"name":"login_submitted","context":{"user":{"@path":"/username"},"pass":{"@path":"/password"}}}}},
            {"id":"submit_label","component":"Text","text":"Sign In"}]}}]}
        """#

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-convertsAutomatically", "NO"]
    }

    func testPastingA2UIMakesAScreenAndSaysWhatWasLeftOut() {
        openNewDesign()
        UIPasteboard.general.string = Self.loginForm

        control("Add Image").tap()
        let paste = app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the paperclip should offer Paste in its A2UI section")
        XCTAssertTrue(app.buttons["Import A2UI…"].exists, "and Import A2UI… beside it")
        paste.tap()

        let actions = app.staticTexts["Actions aren't run in Layer"]
        XCTAssertTrue(actions.waitForExistence(timeout: 15), "the sheet should say the button's action isn't run")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "A2UI import sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Done"].tap()
        XCTAssertTrue(waitForDisappearance(of: actions), "Done should close the sheet")
        XCTAssertTrue(app.staticTexts["Login"].firstMatch.waitForExistence(timeout: 5), "the screen should be named from its title")
    }

    func testImportA2UIOpensFiles() {
        openNewDesign()
        control("Add Image").tap()
        let importA2UI = app.buttons["Import A2UI…"].firstMatch
        XCTAssertTrue(importA2UI.waitForExistence(timeout: 5), "the paperclip should offer Import A2UI…")
        importA2UI.tap()
        // The one Files picker the paperclip has, opened for A2UI rather than for an image.
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10) || app.buttons["Cancel"].waitForExistence(timeout: 5),
                      "Files should open to pick A2UI")
    }

    // MARK: - Helpers

    private func openNewDesign() {
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
        XCTAssertTrue(control("Draw").waitForExistence(timeout: 20), "creating a design should open its canvas")
    }

    private func control(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
