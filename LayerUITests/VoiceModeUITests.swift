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

    /// Every test here narrows the window, and the system keeps a window's size from one
    /// launch to the next, even across reinstalls. Left narrow, it would have every later
    /// UI test open in a phone-sized window, where their controls are folded into menus.
    /// So the window is put back as wide as the screen.
    override func tearDown() async throws {
        if app.state != .runningForeground {
            // A fresh launch, without the call a test asked for.
            app = XCUIApplication()
            app.launchArguments = ["-convertsAutomatically", "NO"]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
            sleep(2)
        }
        resizeWindow(toWidth: screenWidth)
        shoot("restored")
        XCTAssertEqual(app.windows.firstMatch.frame.width, screenWidth, accuracy: 12, "the window should be left as wide as the screen")
        app.terminate()
    }

    func testThePhoneButtonStartsACallInANarrowWindow() {
        openNewDesign(arguments: ["-convertsAutomatically", "NO"])
        // The window comes back the size it was left. Full screen there is no phone
        // button: the corner belongs to the pencil palette.
        resizeWindow(toWidth: screenWidth)
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

    #if targetEnvironment(simulator)
    /// The simulator has no speech recognition. Tapping the phone button there says so,
    /// and leaves no call up and no microphone on.
    func testThePhoneButtonSaysWhenTheSimulatorCannotHear() {
        openNewDesign(arguments: ["-convertsAutomatically", "NO"])
        resizeWindow(toWidth: 375)
        // A new design opens with Draw on, and the pencil bar lies over the corner.
        if app.buttons["Magic Pen"].firstMatch.waitForExistence(timeout: 3) { chooseTool("Draw") }
        XCTAssertTrue(control("Start voice mode").waitForExistence(timeout: 5))
        control("Start voice mode").tap()
        // The system asks about the microphone the first time.
        allowWhatTheSystemAsks(within: 4)
        let notice = app.alerts["Voice Mode"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "the call should say why it can't start")
        XCTAssertTrue(notice.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Speech recognition")).firstMatch.exists)
        shoot("narrow-no-speech")
        notice.buttons["OK"].tap()
        XCTAssertTrue(control("Start voice mode").waitForExistence(timeout: 5), "the phone button should be back")
        XCTAssertFalse(control("End voice mode").exists)
        XCTAssertTrue(control("Zoom").exists)
    }
    #endif

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

    /// In a narrow window the pencil bar lies across the bottom, over the corner the phone
    /// button is in. Flicking the bar aside puts it away, and Draw in the menu brings it back.
    func testFlickingThePencilBarAsidePutsItAway() {
        openNewDesign(arguments: ["-convertsAutomatically", "NO"])
        resizeWindow(toWidth: 375)
        let pen = app.buttons["Magic Pen"].firstMatch
        if !pen.waitForExistence(timeout: 3) { chooseTool("Draw") }
        XCTAssertTrue(pen.waitForExistence(timeout: 5), "Draw should put the pencil bar up")
        XCTAssertFalse(control("Start voice mode").exists, "with Draw on there should be no phone button, not one under the bar")
        shoot("narrow-bar-up")

        // A flick along the bar, starting on it.
        let bar = pen.frame
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").coordinate(withNormalizedOffset: .zero)
        let start = screen.withOffset(CGVector(dx: bar.midX + 60, dy: bar.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 170, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)

        XCTAssertTrue(wait(forGone: pen), "a flick aside should put the pencil bar away")
        XCTAssertTrue(control("Start voice mode").isHittable, "the corner should be the phone button's again")
        shoot("narrow-bar-flicked")

        // Draw in the menu brings it back, and a flick down puts it away again.
        chooseTool("Draw")
        XCTAssertTrue(pen.waitForExistence(timeout: 5), "Draw should bring the pencil bar back")
        let again = screen.withOffset(CGVector(dx: pen.frame.midX + 60, dy: pen.frame.midY))
        again.press(forDuration: 0.05, thenDragTo: again.withOffset(CGVector(dx: 0, dy: 70)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(wait(forGone: pen), "a flick down should put the pencil bar away")
    }

    /// The real agent and its tools, with a model that calls the tools the script names.
    func testASpokenCommandChangesTheCanvas() {
        let spoken = "make the sign in button green and say ahoy => styleElement element=E2 look=green && setText element=E2 text=Ahoy"
        openNewDesign(arguments: [
            "-convertsAutomatically", "NO", "-LayerVoiceDemoDesign", "login",
            "-LayerVoiceDemo", spoken, "-LayerVoiceDemoFreeze", "done",
        ])
        resizeWindow(toWidth: 375)
        XCTAssertTrue(control("End voice mode").waitForExistence(timeout: 15), "the call should be up")
        // The pill says what the last tool did, and the canvas shows it.
        XCTAssertTrue(wait(for: caption, toHave: "label CONTAINS %@", "Reworded the button"), "the pill should say what was done")
        XCTAssertTrue(app.staticTexts["Ahoy"].waitForExistence(timeout: 5), "the button on the canvas should say Ahoy")
        sleep(1)
        shoot("narrow-command-done")
        control("End voice mode").tap()
        XCTAssertTrue(control("Start voice mode").waitForExistence(timeout: 5))
        // One undo takes the whole command back: both its changes.
        XCTAssertTrue(control("Undo").waitForExistence(timeout: 5), "a spoken command should be undoable")
        control("Undo").tap()
        XCTAssertTrue(app.staticTexts["Sign in"].waitForExistence(timeout: 5), "undo should put the button's words back")
        XCTAssertFalse(app.staticTexts["Ahoy"].exists)
        shoot("narrow-command-undone")
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

    /// The simulator's scripted squeeze (`PencilDemo`) over the open canvas: the pencil's
    /// bubble opens with Squeeze to Talk on, as it is until turned off. Turned off in the
    /// board's Magic Pen tab, the listen stops; and launched with it off, nothing opens.
    func testSqueezeToTalkOffLeavesTheSqueezeAlone() {
        // Held, which keeps listening for up to a minute: a toggle gives up after 20 s of quiet.
        let squeeze = "600,450,-,hold => make it blue => Made it blue"
        let bubble = app.descendants(matching: .any).matching(identifier: "pencil bubble").firstMatch
        openNewDesign(arguments: ["-convertsAutomatically", "NO", "-LayerPencilDemo", squeeze, "-LayerVoiceDemoFreeze", "listening"])
        XCTAssertTrue(bubble.waitForExistence(timeout: 20), "a squeeze should open the bubble while Squeeze to Talk is on")
        shoot("squeeze-to-talk-on")
        setSqueezeToTalk(false)
        XCTAssertTrue(wait(forGone: bubble), "turning Squeeze to Talk off should stop the listen")
        shoot("squeeze-to-talk-turned-off")
        // Back on, as the app is left: the tab's toggle is the app's setting, kept between launches.
        setSqueezeToTalk(true)
        app.terminate()

        openNewDesign(arguments: [
            "-convertsAutomatically", "NO", "-LayerPencilDemo", squeeze, "-LayerVoiceDemoFreeze", "listening",
            "-squeezesToTalk", "NO",
        ])
        XCTAssertFalse(bubble.waitForExistence(timeout: 12), "with Squeeze to Talk off a squeeze should open nothing")
        shoot("squeeze-to-talk-off")
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

    private func wait(forGone element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Says yes to the system's questions about the microphone, however many are waiting.
    private func allowWhatTheSystemAsks(within seconds: TimeInterval) {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label == %@", "Allow")).firstMatch
        var wait = seconds
        for _ in 0..<6 where allow.waitForExistence(timeout: wait) {
            allow.tap()
            wait = 1
        }
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

    /// Turns Squeeze to Talk on or off in the board's Magic Pen tab, and closes the menu.
    private func setSqueezeToTalk(_ isOn: Bool) {
        control("Board title").tap()
        let tab = app.segmentedControls.buttons["Magic Pen"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "the board menu should have a Magic Pen tab")
        tab.tap()
        let toggle = app.switches["Squeeze to Talk"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the Magic Pen tab should have Squeeze to Talk")
        if ((toggle.value as? String) == "1") != isOn {
            let knob = toggle.switches.firstMatch
            (knob.exists ? knob : toggle).tap()
        }
        XCTAssertTrue(wait(for: toggle, toHave: "value == %@", isOn ? "1" : "0", timeout: 5), "Squeeze to Talk should be \(isOn ? "on" : "off")")
        app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        XCTAssertTrue(wait(forGone: app.segmentedControls.firstMatch), "the board menu should close")
    }

    private func openNewDesign(arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
        // A question about the microphone left over from an earlier run would be in the way.
        allowWhatTheSystemAsks(within: 2)
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

    /// How wide the screen is in landscape, where these tests run. The springboard's frame
    /// is the screen upright whatever the orientation, so its width is the short side.
    private var screenWidth: CGFloat {
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").frame
        return max(screen.width, screen.height)
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
