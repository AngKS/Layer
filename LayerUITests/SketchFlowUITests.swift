import XCTest

/// Drives the app the way a person does: from the document browser into a design, drawing
/// with real touches, through conversion, selection, formatting, undo, and back out again.
@MainActor
final class SketchFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Where the tests draw their phone screen, clear of the bars, panels and palette.
    private var sketch = CGRect.zero
    private var screenScale: CGFloat { sketch.height / 852 }
    private var screenOrigin: CGPoint { CGPoint(x: sketch.midX - 393 * screenScale / 2, y: sketch.minY) }

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        // Conversion is triggered by hand here, so pauses between strokes can't split a shape.
        app.launchArguments = ["-convertsAutomatically", "NO"]
    }

    func testMagicPenSketchesBecomeADesignWithCode() {
        openNewDesign()

        // A tall box on the open canvas becomes a phone screen, and the board gets a name.
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10), "the box should become a screen")
        XCTAssertTrue(wait(for: control("Board title"), toHave: "value != 'Untitled'"), "a board with a frame should be named")

        // A zigzag near the top becomes the title.
        zigzag()
        convert()
        XCTAssertTrue(app.staticTexts["Title"].waitForExistence(timeout: 10), "the zigzag should become a title")

        // A box with an X becomes an image; stacked lines become body text; a wide flat box a text field.
        box(CGRect(origin: onScreen((34, 186)), size: CGSize(width: 326 * screenScale, height: 364 * screenScale)))
        stroke(onScreen((70, 220)), onScreen((325, 515)))
        stroke(onScreen((325, 220)), onScreen((70, 515)))
        convert()
        for y in [592, 608, 624] as [CGFloat] { stroke(onScreen((60, y)), onScreen((330, y))) }
        convert()
        XCTAssertTrue(app.staticTexts.matching(labelBeginning("A short description")).firstMatch.waitForExistence(timeout: 10))
        box(CGRect(origin: onScreen((30, 730)), size: CGSize(width: 333 * screenScale, height: 56 * screenScale)))
        convert()
        XCTAssertTrue(app.staticTexts["Placeholder"].waitForExistence(timeout: 10), "the wide box should become a text field")

        // The layers panel lists every layer and shows the generated SwiftUI.
        control("Layers").tap()
        for layer in ["Text Field", "Body", "Image"] {
            XCTAssertTrue(app.staticTexts[layer].waitForExistence(timeout: 5), "\(layer) should be listed as a layer")
        }
        app.buttons["Code"].tap()
        XCTAssertTrue(app.staticTexts.matching(labelContaining("Image(\"photo\")")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(labelContaining("TextField(\"Placeholder\"")).firstMatch.exists)
        control("Layers").tap()

        // With the pencil palette away, tapping an element selects it, the format panel
        // shows its settings, and dragging a handle resizes it.
        control("Draw").tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Magic Pen"]), "the palette should hide outside draw mode")
        point(onScreen((196, 132))).tap()
        XCTAssertTrue(app.staticTexts["228 × 40"].waitForExistence(timeout: 5), "the title should be selected at its standard size")
        XCTAssertTrue(app.staticTexts["Weight"].waitForExistence(timeout: 5), "the format panel should show the title's text settings")
        let handle = onScreen((82.5 + 228, 112 + 40))
        stroke(CGPoint(x: handle.x + 6, y: handle.y + 6), CGPoint(x: handle.x + 6, y: handle.y + 30))
        XCTAssertTrue(app.staticTexts.matching(labelBeginning("228 × ")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["228 × 40"].exists, "dragging the corner handle should have made the title taller")

        // Draw brings the palette back.
        control("Draw").tap()
        XCTAssertTrue(app.buttons["Magic Pen"].waitForExistence(timeout: 5))
    }

    func testPaletteInkIsOrdinaryInkSharesUndoAndIsSaved() throws {
        openNewDesign()
        control("Format").tap()
        let discard = app.buttons["Discard Sketch"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "with nothing selected the format panel shows the canvas settings")

        // A Magic Pen sketch that means nothing can be discarded, or fades away on its own.
        stroke(CGPoint(x: 380, y: 300), CGPoint(x: 460, y: 330))
        XCTAssertTrue(wait(for: discard, toHave: "isEnabled == true"))
        discard.tap()
        XCTAssertTrue(wait(for: discard, toHave: "isEnabled == false"))
        stroke(CGPoint(x: 380, y: 300), CGPoint(x: 460, y: 330))
        convert()
        XCTAssertTrue(wait(for: discard, toHave: "isEnabled == false", timeout: 10), "an unreadable sketch should dissolve")

        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))

        // The palette's Pen draws ordinary ink: the same zigzag is not a sketch to convert.
        choosePaletteTool("Pen")
        zigzag()
        XCTAssertFalse(app.buttons["Convert Sketch Now"].isEnabled, "ink from the Pen is not a Magic Pen sketch")
        XCTAssertFalse(app.staticTexts["Title"].exists)

        // One undo history covers ink strokes and design changes alike.
        let undo = app.buttons.matching(identifier: "arrow.uturn.backward").firstMatch
        let redo = app.buttons.matching(identifier: "arrow.uturn.forward").firstMatch
        for _ in 0..<4 { undo.tap() }
        XCTAssertTrue(app.staticTexts["Screen 1"].exists, "undoing four pen strokes should leave the screen")
        undo.tap()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["Screen 1"]), "the next undo should remove the screen")
        redo.tap()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 5))
        redo.tap()

        // Closing saves, and the browser lists the design by its board's name, not as
        // Untitled. Reopening it from there brings the design back.
        let boardTitle = control("Board title")
        XCTAssertTrue(wait(for: boardTitle, toHave: "value != 'Untitled'", timeout: 15), "a board with a frame should be named")
        let name = try XCTUnwrap(boardTitle.value as? String)
        control("Designs").tap()
        XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 20))
        // A cell reads "name, layer, date, size". What the browser says about a design it
        // has just got back takes a few seconds to catch up.
        let recent = app.cells.matching(labelBeginning(name + ",")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 20), "the browser should list the design as \(name)")
        sleep(2)
        recent.tap()
        let reopened = app.staticTexts["Screen 1"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 20), "the reopened design should still have its screen")
        XCTAssertTrue(wait(for: control("Zoom"), toHave: "value == '100 percent'"), "a design this small should open at full size")
        XCTAssertEqual(reopened.frame.minX, sketch.minX, accuracy: 40, "and in the middle of the view")
        XCTAssertTrue(wait(for: control("Board title"), toHave: "value != 'Untitled'"), "and its name")
    }

    func testTheBrowserListsADesignUnderTheNameItsBoardIsGiven() {
        openNewDesign()
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))
        let title = control("Board title")
        XCTAssertTrue(wait(for: title, toHave: "value != 'Untitled'", timeout: 15), "a board with a frame should be named")

        // Renaming the board renames its file.
        let name = "Checkout \(Int(Date().timeIntervalSince1970) % 100_000)"
        title.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "tapping the name should offer to change it")
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name)
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(wait(for: title, toHave: "value == '\(name)'"))

        // Back in the browser the design is listed under that name, and opens with it.
        control("Designs").tap()
        XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 20))
        let listed = app.cells.matching(labelContaining(name)).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 15), "the browser should list the design as \(name)")
        sleep(2)
        listed.tap()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 20))
        XCTAssertTrue(wait(for: control("Board title"), toHave: "value == '\(name)'"), "the reopened design should have kept its name")
    }

    func testTheCanvasPansZoomsLocksAndFramesCanBeMoved() {
        openNewDesign()
        box(sketch)
        convert()
        control("Format").tap()
        let label = app.staticTexts["Screen 1"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertEqual(zoom, "100 percent")

        // The zoom control jumps to a level, and steps in and out. (Pinching is checked by
        // hand: the pinch XCUITest synthesizes never reaches a PencilKit canvas.)
        let small = label.frame
        control("Zoom").tap()
        app.buttons["200%"].tap()
        XCTAssertTrue(wait(for: control("Zoom"), toHave: "value == '200 percent'"))
        XCTAssertEqual(label.frame.width, small.width * 2, accuracy: 2, "content should grow with the zoom")
        control("Zoom").tap()
        app.buttons["100%"].tap()
        XCTAssertTrue(wait(for: control("Zoom"), toHave: "value == '100 percent'"))
        XCTAssertEqual(label.frame.width, small.width, accuracy: 1)
        control("Zoom in").tap()
        XCTAssertTrue(wait(for: control("Zoom"), toHave: "value == '125 percent'"))
        control("Zoom out").tap()
        XCTAssertTrue(wait(for: control("Zoom"), toHave: "value == '100 percent'"))

        // With the palette away, a one-finger drag across empty canvas pans it.
        control("Draw").tap()
        var before = label.frame
        stroke(CGPoint(x: 150, y: 420), CGPoint(x: 230, y: 500))
        sleep(1)
        XCTAssertGreaterThan(label.frame.minX - before.minX, 60, "the canvas should follow the finger")
        XCTAssertGreaterThan(label.frame.minY - before.minY, 60)

        // A locked canvas stays put.
        control("Zoom").tap()
        app.buttons["Lock Canvas"].tap()
        XCTAssertTrue(wait(for: control("Zoom"), toHave: "value CONTAINS 'locked'"))
        before = label.frame
        stroke(CGPoint(x: 150, y: 420), CGPoint(x: 230, y: 500))
        XCTAssertEqual(label.frame.minX, before.minX, accuracy: 1, "a locked canvas should not pan")
        control("Zoom").tap()
        app.buttons["Lock Canvas"].tap()

        // Tapping a frame selects it; dragging it then moves the frame, not the canvas.
        let middle = CGPoint(x: label.frame.minX + 100, y: label.frame.maxY + 250)
        point(middle).tap()
        XCTAssertTrue(app.staticTexts.matching(labelBeginning("Screen 1 · 393")).firstMatch.waitForExistence(timeout: 5), "tapping a frame should select it")
        before = label.frame
        stroke(middle, CGPoint(x: middle.x - 150, y: middle.y + 40))
        XCTAssertEqual(label.frame.minX, before.minX - 150, accuracy: 4)
        XCTAssertEqual(label.frame.minY, before.minY + 40, accuracy: 4)

        // A frame can also be dragged by its name without selecting it first.
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts.matching(labelBeginning("Screen 1 · 393")).firstMatch), "tapping empty canvas should deselect")
        before = label.frame
        stroke(CGPoint(x: before.midX, y: before.midY), CGPoint(x: before.midX + 90, y: before.midY))
        XCTAssertEqual(label.frame.minX, before.minX + 90, accuracy: 4)

        // Undo puts the frame back where it was.
        app.buttons.matching(identifier: "arrow.uturn.backward").firstMatch.tap()
        XCTAssertTrue(settles(label.frame.minX, at: before.minX), "undo should put the frame back where it was")

        // The frames menu adds a frame of another device, selected.
        control("Frames").tap()
        app.buttons.matching(labelBeginning("iPad")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(labelBeginning("Screen 2 · 820")).firstMatch.waitForExistence(timeout: 5), "an iPad frame should be added and selected")
    }

    func testThingsAreAddedFromTheBarAndStyledFromTheFormatPanel() {
        openNewDesign()
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))
        control("Layers").tap()

        // A symbol picked from the menu lands in the middle of the view, on the frame, selected.
        control("Symbols").tap()
        let search = app.textFields["Search symbols"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the symbols menu should open")
        search.tap()
        search.typeText("heart fill")
        let heart = app.buttons["heart.fill"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        heart.tap()
        XCTAssertTrue(app.staticTexts["44 × 44"].waitForExistence(timeout: 5), "the new symbol should be selected")
        XCTAssertFalse(app.buttons["Magic Pen"].exists, "adding something should put the pencil palette away")
        XCTAssertTrue(app.staticTexts["Symbol"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Canvas"].exists)

        // Dragged off the frame it floats on the open canvas; dragged back it rejoins the frame.
        let window = app.windows.firstMatch.frame
        let center = CGPoint(x: window.midX, y: window.midY)
        let open = CGPoint(x: 800, y: 600)
        stroke(center, open)
        XCTAssertTrue(app.staticTexts["Canvas"].waitForExistence(timeout: 5), "the symbol should be listed on the canvas")
        stroke(open, CGPoint(x: center.x, y: center.y - 120))
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["Canvas"]), "the symbol should be back on the frame")

        // Typed text is added the same way, and restyled from the format panel.
        control("Text").tap()
        XCTAssertTrue(app.staticTexts["200 × 24"].waitForExistence(timeout: 5), "new text should be selected")
        point(CGPoint(x: 800, y: 600)).tap()
        point(center).tap()
        XCTAssertTrue(app.staticTexts["200 × 24"].waitForExistence(timeout: 5))
        let weight = app.buttons.matching(labelBeginning("Weight")).firstMatch
        XCTAssertTrue(weight.waitForExistence(timeout: 5), "the format panel should offer the text's weight")
        weight.tap()
        app.buttons["Bold"].tap()
        app.buttons["Code"].tap()
        XCTAssertTrue(app.staticTexts.matching(labelContaining("weight: .bold")).firstMatch.waitForExistence(timeout: 5), "the weight should reach the code")
        XCTAssertTrue(app.staticTexts.matching(labelContaining("Image(systemName: \"heart.fill\")")).firstMatch.exists)
        app.buttons.matching(NSPredicate(format: "label == 'Layers' AND identifier == ''")).firstMatch.tap()

        // A sticky note stays on the canvas even over a frame, and can be deleted.
        control("Sticky note").tap()
        XCTAssertTrue(app.staticTexts["150 × 150"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sticky Note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Canvas"].exists, "a sticky note belongs to the canvas, not the frame")
        // A new note opens ready to be typed in; that is put away before anything else can be tapped.
        point(open).tap()
        if !app.staticTexts["150 × 150"].exists { point(center).tap() }
        XCTAssertTrue(app.staticTexts["150 × 150"].waitForExistence(timeout: 5), "the note should still be selected")
        control("Delete selection").tap()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["Sticky Note"]))

        // Sharing offers the code and a picture of the board.
        control("Share").tap()
        XCTAssertTrue(app.buttons["SwiftUI Code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Image of Board"].exists)
    }

    func testDrawingsAreSelectedAndMoved() {
        openNewDesign()

        // Two strokes with the Pen, crossing, make one drawing.
        choosePaletteTool("Pen")
        stroke(CGPoint(x: 200, y: 400), CGPoint(x: 320, y: 480))
        stroke(CGPoint(x: 320, y: 400), CGPoint(x: 200, y: 480))

        // With the palette away, tapping it selects both strokes.
        control("Draw").tap()
        point(CGPoint(x: 260, y: 440)).tap()
        let readout = app.staticTexts["Drawing · 2 strokes"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "tapping ink should select the drawing")

        // Dragging moves it: afterwards it is found at its new place and not at its old one.
        stroke(CGPoint(x: 260, y: 440), CGPoint(x: 560, y: 300))
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: readout))
        point(CGPoint(x: 260, y: 440)).tap()
        XCTAssertFalse(readout.waitForExistence(timeout: 2), "the drawing should have left its old place")
        point(CGPoint(x: 560, y: 300)).tap()
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "the drawing should be at its new place")

        // Undo moves it back; deleting removes it.
        app.buttons.matching(identifier: "arrow.uturn.backward").firstMatch.tap()
        point(CGPoint(x: 150, y: 650)).tap()
        point(CGPoint(x: 260, y: 440)).tap()
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "undo should move the drawing back")
        control("Delete selection").tap()
        XCTAssertTrue(waitForDisappearance(of: readout))
        point(CGPoint(x: 260, y: 440)).tap()
        XCTAssertFalse(readout.waitForExistence(timeout: 2), "the drawing should be gone")
    }

    func testTheReferenceDesignFitsTheCanvas() {
        // The scripted demo draws the reference design, letting each sketch convert on its
        // own after a pause, then opens the code panel.
        app.launchArguments = ["-LayerDemo", "all", "-LayerDemoEnd", "code"]
        openNewDesign()

        XCTAssertTrue(app.staticTexts.matching(labelContaining("struct Screen1: View")).firstMatch.waitForExistence(timeout: 40))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height)
        let controls = [
            "Designs", "Board title", "Layers", "Draw", "Text", "Frames", "Sticky note", "Symbols", "Attach image",
            "Share", "Format", "Zoom out", "Zoom", "Zoom in", "Magic Pen",
        ]
        for label in controls {
            XCTAssertTrue(control(label).isHittable, "\(label) should be on screen and tappable")
        }
        for text in ["Screen 1", "Title", "Continue"] {
            XCTAssertTrue(window.contains(app.staticTexts[text].frame), "\(text) should be inside the window")
        }
        XCTAssertNotEqual(control("Board title").value as? String, "Untitled")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "reference-design"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    // MARK: Documents

    /// Launches into the document browser and creates a design, ending on its canvas with
    /// the Magic Pen in hand.
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
        XCTAssertTrue(app.buttons["Magic Pen"].waitForExistence(timeout: 10), "a design should open with the Magic Pen in hand")

        let window = app.windows.firstMatch.frame
        sketch = CGRect(x: window.midX - 130, y: 124, width: 260, height: 560)
    }

    /// Picks a tool from the pencil palette, opening the palette first if it has been
    /// minimised to a corner, where it shows only the tool in hand.
    private func choosePaletteTool(_ name: String) {
        let tool = app.buttons[name].firstMatch
        if !tool.exists { app.buttons["Magic Pen"].firstMatch.tap() }
        XCTAssertTrue(tool.waitForExistence(timeout: 5), "the palette should offer \(name)")
        tool.tap()
    }

    // MARK: Drawing

    /// A canvas point for a point given in the phone screen's own coordinates.
    private func onScreen(_ local: (CGFloat, CGFloat)) -> CGPoint {
        CGPoint(x: screenOrigin.x + local.0 * screenScale, y: screenOrigin.y + local.1 * screenScale)
    }

    private func point(_ location: CGPoint) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: location.x, dy: location.y))
    }

    private func stroke(_ start: CGPoint, _ end: CGPoint) {
        point(start).press(forDuration: 0.05, thenDragTo: point(end), withVelocity: .fast, thenHoldForDuration: 0.05)
    }

    /// Draws a box as four separate strokes, the way many people do.
    private func box(_ rect: CGRect) {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
        for index in corners.indices { stroke(corners[index], corners[(index + 1) % 4]) }
    }

    /// Four short strokes near the top of the phone screen, where a title goes.
    private func zigzag() {
        let points: [(CGFloat, CGFloat)] = [(150, 132), (170, 104), (190, 132), (210, 104), (230, 132)]
        for (start, end) in zip(points, points.dropFirst()) { stroke(onScreen(start), onScreen(end)) }
    }

    /// Reads the sketch on the canvas, from the Magic Pen settings in the format panel.
    private func convert() {
        let button = app.buttons["Convert Sketch Now"]
        if !button.exists { control("Format").tap() }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the format panel should offer to convert the sketch")
        button.tap()
    }

    // MARK: Finding things

    /// Whether a position comes to rest at `expected`. Undo and redo glide things into
    /// place, so a position read straight after them is still on its way.
    private func settles(_ position: @autoclosure () -> CGFloat, at expected: CGFloat, accuracy: CGFloat = 4) -> Bool {
        for _ in 0..<20 where abs(position() - expected) > accuracy { usleep(150_000) }
        return abs(position() - expected) <= accuracy
    }

    /// The zoom control's spoken value, such as "100 percent".
    private var zoom: String? {
        control("Zoom").value as? String
    }

    private func control(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func labelBeginning(_ prefix: String) -> NSPredicate {
        NSPredicate(format: "label BEGINSWITH %@", prefix)
    }

    private func labelContaining(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    private func wait(for element: XCUIElement, toHave condition: String, timeout: TimeInterval = 8) -> Bool {
        let met = expectation(for: NSPredicate(format: condition), evaluatedWith: element)
        return XCTWaiter().wait(for: [met], timeout: timeout) == .completed
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        wait(for: element, toHave: "exists == false", timeout: timeout)
    }
}
