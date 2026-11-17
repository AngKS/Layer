import XCTest

/// Voice mode where it lives: a design in a narrow window. The call is the scripted one
/// (`VoiceDemo`), so nothing here needs a microphone or a model.
///
/// Set `TEST_RUNNER_LAYER_SHOTS` to a folder to have a picture saved at each step.
@MainActor
final class VoiceModeUITests: XCTestCase {
    private var app: XCUIApplication!
    // No apostrophes: one in a launch argument swallows the arguments after it.
    private let script = "make the sign in button blue => Made the button blue; show me the first screen => !No connection to the internet."

    override func setUp() async throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
    }

    func testThePhoneButtonStartsACallInANarrowWindow() {
        openNewDesign(arguments: ["-convertsAutomatically", "NO"])
        // The window comes back the size it was left. Full screen there is no phone
        // button: the corner belongs to the pencil palette.
        resizeWindow(toWidth: XCUIApplication(bundleIdentifier: "com.apple.springboard").frame.width)
        XCTAssertFalse(control("Start voice mode").exists, "the phone button is for the narrow window")
        shoot("full-idle")

        resizeWindow(toWidth: 375)
        shoot("narrow-drawing")
        // With Draw off the pencil bar goes and the corner is the phone button's.
        chooseTool("Draw")
        XCTAssertTrue(control("Start voice mode").waitForExistence(timeout: 5), "a narrow window should offer voice mode")
        XCTAssertTrue(control("Zoom").exists)
        shoot("narrow-idle")

        resizeWindow(toWidth: 675)
        shoot("medium-idle")
        resizeWindow(toWidth: 375)
    }

    func testThePillShowsEachMomentOfACall() {
        for moment in ["listening", "hearing", "working", "done", "problem"] {
            openNewDesign(arguments: ["-convertsAutomatically", "NO", "-LayerVoiceDemo", script, "-LayerVoiceDemoFreeze", moment])
            resizeWindow(toWidth: 375)
            XCTAssertTrue(control("End voice mode").waitForExistence(timeout: 15), "the call should be up (\(moment))")
            // The zoom control and the phone button make way for the pill.
            XCTAssertFalse(control("Zoom").exists, "the zoom control should be hidden during a call (\(moment))")
            XCTAssertFalse(control("Start voice mode").exists)
            if moment != "listening" {
                XCTAssertTrue(caption.waitForExistence(timeout: 20), "the pill should say something (\(moment))")
                if moment == "problem" {
                    XCTAssertTrue(wait(for: caption, toHave: "label CONTAINS %@", "No connection to the internet"), "the second command's problem should be shown")
                } else if moment == "done" {
                    XCTAssertTrue(wait(for: caption, toHave: "label CONTAINS %@", "Made the button blue"))
                }
            }
            sleep(1)
            shoot("narrow-\(moment)")
            if moment == "done" {
                // A call that is up stays up when its window is made wider.
                resizeWindow(toWidth: 675)
                XCTAssertTrue(control("End voice mode").exists, "resizing the window shouldn't hang up")
                shoot("medium-done")
                resizeWindow(toWidth: 375)
            }
            control("End voice mode").tap()
            XCTAssertTrue(control("Start voice mode").waitForExistence(timeout: 5), "hanging up should bring the phone button back (\(moment))")
            XCTAssertTrue(control("Zoom").exists)
            app.terminate()
        }
    }

    func testThePillOnADarkCanvas() {
        openNewDesign(arguments: ["-convertsAutomatically", "NO", "-LayerVoiceDemo", script, "-LayerVoiceDemoFreeze", "done", "-LayerVoiceDemoDark", "YES"])
        resizeWindow(toWidth: 375)
        XCTAssertTrue(wait(for: caption, toHave: "label CONTAINS %@", "Made the button blue"))
        sleep(1)
        shoot("narrow-dark-done")
        control("End voice mode").tap()
        XCTAssertTrue(control("Start voice mode").waitForExistence(timeout: 5))
        shoot("narrow-dark-idle")
    }

    // MARK: Helpers

    private var caption: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "call caption").firstMatch
    }

    private func control(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func wait(for element: XCUIElement, toHave format: String, _ argument: String, timeout: TimeInterval = 25) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Turns a tool on or off, from the bar when there is room for it or from the "…" menu.
    private func chooseTool(_ name: String) {
        let inBar = control(name)
        if inBar.exists, inBar.isHittable {
            inBar.tap()
            return
        }
        control("Tools").tap()
        let item = app.buttons[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the tools menu should offer \(name)")
        item.tap()
    }

    private func openNewDesign(arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
        // A design left open by the last launch comes back; otherwise the browser does.
        if !control("Board title").waitForExistence(timeout: 8) {
            XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 45), "the document browser should appear at launch")
            let buttons = app.buttons.matching(NSPredicate(format: "label == %@", "New Design"))
            sleep(2)
            var newDesign: XCUIElement?
            for _ in 0..<30 where newDesign == nil {
                newDesign = (0..<buttons.count).map(buttons.element(boundBy:)).first { $0.exists && $0.isHittable }
                if newDesign == nil { usleep(300_000) }
            }
            XCTAssertNotNil(newDesign, "the launch screen should offer a new design")
            newDesign?.tap()
        }
        XCTAssertTrue(control("Board title").waitForExistence(timeout: 20), "creating a design should open its canvas")
    }

    /// Drags the window's corner grip until the window is about `target` points wide. The
    /// window grows and shrinks about its middle.
    private func resizeWindow(toWidth target: CGFloat) {
        for _ in 0..<3 {
            let window = app.windows.firstMatch.frame
            let change = (window.width - target) / 2
            guard abs(change) > 12 else { return }
            let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let grip = screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.maxX - 5, dy: window.maxY - 5))
            let destination = grip.withOffset(CGVector(dx: -change, dy: 0))
            grip.press(forDuration: 0.5, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.3)
            sleep(1)
        }
    }

    private func shoot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["LAYER_SHOTS"] else { return }
        let picture = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? picture.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
