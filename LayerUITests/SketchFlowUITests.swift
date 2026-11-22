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
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == \'228 × 40\'", timeout: 5), "the title should be selected at its standard size")
        XCTAssertTrue(control("Format").waitForExistence(timeout: 5), "with something selected the paintbrush is back")
        control("Format").tap()
        XCTAssertTrue(control("Font size").waitForExistence(timeout: 5), "the format panel should show the title's text settings")
        let handle = onScreen((82.5 + 228, 112 + 40))
        stroke(CGPoint(x: handle.x + 6, y: handle.y + 6), CGPoint(x: handle.x + 6, y: handle.y + 30))
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH '228 × '", timeout: 5))
        XCTAssertNotEqual(selectionElement.value as? String, "228 × 40", "dragging the corner handle should have made the title taller")

        // Draw brings the palette back.
        control("Draw").tap()
        XCTAssertTrue(app.buttons["Magic Pen"].waitForExistence(timeout: 5))
    }

    func testPaletteInkIsOrdinaryInkSharesUndoAndIsSaved() throws {
        openNewDesign()
        XCTAssertFalse(control("Format").exists, "with nothing selected there is nothing to format")

        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))

        // The palette's Pen draws ordinary ink: the same zigzag is not a sketch to convert.
        choosePaletteTool("Pen")
        zigzag()
        convert()
        XCTAssertFalse(app.staticTexts["Title"].exists, "ink from the Pen is not a Magic Pen sketch")

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
        let field = app.textFields["Board name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "tapping the name should offer to change it")
        XCTAssertTrue(app.buttons["Canvas"].exists && app.buttons["Magic Pen"].exists, "with the canvas settings below, in tabs")
        // At the end of the name, so that deleting removes all of it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name + "\n")
        XCTAssertTrue(waitForDisappearance(of: field), "finishing the name should close the menu")
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

    func testTheSelectionPopoverLocksDuplicatesAndDeletes() {
        openNewDesign()
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))
        control("Draw").tap()

        // Selecting a frame brings up its actions.
        let label = app.staticTexts["Screen 1"]
        point(CGPoint(x: label.frame.minX + 100, y: label.frame.maxY + 250)).tap()
        XCTAssertTrue(control("Lock").waitForExistence(timeout: 5), "a selected frame should offer to lock it")
        XCTAssertTrue(control("Duplicate").exists)
        XCTAssertTrue(control("Delete selection").exists)

        // Locked, it stays put when dragged, and offers nothing but unlocking.
        control("Lock").tap()
        XCTAssertTrue(control("Unlock").waitForExistence(timeout: 5))
        XCTAssertFalse(control("Delete selection").exists, "a locked frame can't be deleted")
        let before = label.frame
        stroke(CGPoint(x: before.midX, y: before.midY), CGPoint(x: before.midX + 120, y: before.midY))
        XCTAssertEqual(label.frame.minX, before.minX, accuracy: 2, "a locked frame should not move")
        control("Unlock").tap()
        XCTAssertTrue(control("Lock").waitForExistence(timeout: 5))

        // Duplicating makes a second frame, selected; deleting removes it again.
        control("Duplicate").tap()
        XCTAssertTrue(app.staticTexts["Screen 1 Copy"].waitForExistence(timeout: 5), "the copy should appear beside the frame")
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Screen 1 Copy · 393'", timeout: 5), "the copy should be selected")
        // The actions move over to the copy; let them arrive.
        sleep(1)
        control("Delete selection").tap()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["Screen 1 Copy"]))
        XCTAssertTrue(label.exists)
    }

    /// A change made just before the app goes to the background reaches the disk with the
    /// save the system makes as the app goes, in SwiftUI's own document, not only in a
    /// plain `UIDocument` as the unit tests check. The app is then ended without coming back.
    func testAChangeIsKeptWhenTheAppGoesToTheBackgroundAndIsEnded() {
        app.launchArguments += ["-fingerDraws", "NO"]
        openNewDesign()
        addFrame("iPhone")
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 5))

        // Named, so the browser can find it again.
        let name = "Kept \(Int(Date().timeIntervalSince1970) % 100_000)"
        let title = control("Board title")
        title.tap()
        let field = app.textFields["Board name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "tapping the name should offer to change it")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name + "\n")
        XCTAssertTrue(waitForDisappearance(of: field), "finishing the name should close the menu")
        XCTAssertTrue(wait(for: title, toHave: "value == '\(name)'"))

        // A second frame, moments before the app goes: well inside the system's 15 s or so
        // before an autosave, so only the save on leaving can write it.
        addFrame("iPad")
        XCTAssertTrue(app.staticTexts["Screen 2"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()

        app.launch()
        if !control("Draw").waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 45))
            let listed = app.cells.matching(labelContaining(name)).firstMatch
            XCTAssertTrue(listed.waitForExistence(timeout: 20), "the browser should list the design as \(name)")
            sleep(2)
            listed.tap()
        }
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 20), "the design should open")
        XCTAssertTrue(app.staticTexts["Screen 2"].waitForExistence(timeout: 5), "the frame added just before leaving should have been saved")
    }

    func testWithAPencilAroundAFingerSelectsAndPansWhileThePaletteIsUp() {
        // As once Apple Pencil has been seen: the Pencil draws and a finger doesn't.
        app.launchArguments += ["-fingerDraws", "NO"]
        openNewDesign()
        addFrame("iPhone")
        let label = app.staticTexts["Screen 1"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        control("Draw").tap()
        XCTAssertTrue(app.buttons["Magic Pen"].waitForExistence(timeout: 5), "the palette should be up")

        // A finger tap on the frame selects it, palette and all.
        point(CGPoint(x: 150, y: 650)).tap()
        point(CGPoint(x: label.frame.minX + 100, y: label.frame.maxY + 250)).tap()
        XCTAssertTrue(control("Delete selection").waitForExistence(timeout: 5), "a finger tap should select the frame")
        XCTAssertTrue(app.buttons["Magic Pen"].exists, "the palette should stay up")

        // A finger tap on empty canvas lets go; a finger drag across it pans rather than draws.
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: control("Delete selection")))
        let before = label.frame
        stroke(CGPoint(x: 150, y: 420), CGPoint(x: 230, y: 500))
        sleep(1)
        XCTAssertGreaterThan(label.frame.minX - before.minX, 40, "a finger should pan the canvas")
    }

    func testTheCanvasPansZoomsLocksAndFramesCanBeMoved() {
        openNewDesign()
        box(sketch)
        convert()
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
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Screen 1 · 393'", timeout: 5), "tapping a frame should select it")
        before = label.frame
        stroke(middle, CGPoint(x: middle.x - 150, y: middle.y + 40))
        XCTAssertEqual(label.frame.minX, before.minX - 150, accuracy: 4)
        XCTAssertEqual(label.frame.minY, before.minY + 40, accuracy: 4)

        // A frame can also be dragged by its name without selecting it first.
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement), "tapping empty canvas should deselect")
        before = label.frame
        stroke(CGPoint(x: before.midX, y: before.midY), CGPoint(x: before.midX + 90, y: before.midY))
        XCTAssertEqual(label.frame.minX, before.minX + 90, accuracy: 4)

        // Undo puts the frame back where it was.
        app.buttons.matching(identifier: "arrow.uturn.backward").firstMatch.tap()
        XCTAssertTrue(settles(label.frame.minX, at: before.minX), "undo should put the frame back where it was")

        // The library's wireframes add a frame of another device, selected.
        addFrame("iPad")
        // It comes in unselected; tapping its name selects it.
        XCTAssertTrue(app.staticTexts["Screen 2"].waitForExistence(timeout: 5), "an iPad frame should be added")
        XCTAssertFalse(selectionElement.exists, "a new frame comes in unselected")
        app.staticTexts["Screen 2"].tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Screen 2 · 820'", timeout: 5), "the iPad frame should be selected once tapped")
    }

    func testThingsAreAddedFromTheBarAndStyledFromTheFormatPanel() {
        openNewDesign()
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))
        control("Layers").tap()

        // A symbol picked from the library lands in the middle of the view, on the frame, selected.
        control("Library").tap()
        let search = app.textFields["Search the library"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the library should open")
        search.tap()
        search.typeText("heart fill")
        let heart = app.buttons["heart.fill"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        heart.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == \'44 × 44\'", timeout: 5), "the new symbol should be selected")
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
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == \'200 × 24\'", timeout: 5), "new text should be selected")
        point(CGPoint(x: 800, y: 600)).tap()
        point(center).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == \'200 × 24\'", timeout: 5))
        let weight = app.buttons.matching(labelBeginning("Weight")).firstMatch
        if !weight.exists { control("Format").tap() }
        XCTAssertTrue(weight.waitForExistence(timeout: 5), "the format panel should offer the text's weight")
        weight.tap()
        app.buttons["Bold"].tap()
        app.buttons["Code"].tap()
        XCTAssertTrue(app.staticTexts.matching(labelContaining("weight: .bold")).firstMatch.waitForExistence(timeout: 5), "the weight should reach the code")
        XCTAssertTrue(app.staticTexts.matching(labelContaining("Image(systemName: \"heart.fill\")")).firstMatch.exists)
        app.buttons.matching(NSPredicate(format: "label == 'Layers' AND identifier == ''")).firstMatch.tap()

        // A sticky note stays on the canvas even over a frame, and can be deleted.
        control("Sticky note").tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == \'150 × 150\'", timeout: 5))
        XCTAssertTrue(app.staticTexts["Sticky Note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Canvas"].exists, "a sticky note belongs to the canvas, not the frame")
        // A new note opens ready to be typed in; that is put away before anything else can be tapped.
        point(open).tap()
        if selectionElement.value as? String != "150 × 150" { point(center).tap() }
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == \'150 × 150\'", timeout: 5), "the note should still be selected")
        control("Delete selection").tap()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["Sticky Note"]))

        // Sharing offers the code and a picture of the board.
        control("Share").tap()
        XCTAssertTrue(app.buttons["SwiftUI Code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Image of Board"].exists)
    }

    func testImagesComeFromImagePlaygroundPhotosOrFiles() {
        openNewDesign()
        control("Add Image").tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 5), "the paperclip should offer Photos")
        XCTAssertTrue(app.buttons["Files"].exists, "the paperclip should offer Files")
        // Image Playground is offered only where Apple Intelligence can run it, which the
        // Simulator can't.
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Add Image menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Files"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10) || app.buttons["Cancel"].waitForExistence(timeout: 5), "Files should open to pick an image")
    }

    func testASelectedDrawingBecomesWhatItsPromptSays() {
        openNewDesign()
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))

        // A wide box in ordinary ink near the bottom of the screen, selected.
        choosePaletteTool("Pen")
        box(CGRect(origin: onScreen((30, 730)), size: CGSize(width: 333 * screenScale, height: 56 * screenScale)))
        control("Draw").tap()
        point(onScreen((196, 730))).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Drawing'", timeout: 5), "tapping the ink should select it")

        // Its popover takes a prompt, and the sparkle turns it into what the prompt names.
        let prompt = app.textFields["Prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "a selected drawing should offer a prompt")
        XCTAssertTrue(control("Delete selection").exists)
        prompt.tap()
        // The full stop commits the last word on keyboards that compose text, such as Pinyin.
        prompt.typeText("a button saying Go.")
        control("Convert drawing").tap()
        XCTAssertTrue(app.staticTexts["Go"].waitForExistence(timeout: 10), "the drawing should become a button labelled Go")
        XCTAssertTrue(wait(for: selectionElement, toHave: "NOT (value BEGINSWITH 'Drawing')", timeout: 5), "the button should be selected, not the ink")
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
        let readout = selectionElement
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "tapping ink should select the drawing")

        // Dragging moves it: afterwards it is found at its new place and not at its old one.
        XCTAssertTrue(showsInk(near: CGPoint(x: 260, y: 440)), "the ink should be drawn where it was drawn")
        stroke(CGPoint(x: 260, y: 440), CGPoint(x: 560, y: 300))
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: readout))
        // And it is drawn there: the ink itself moves, not only what a tap finds.
        XCTAssertTrue(showsInk(near: CGPoint(x: 560, y: 300)), "the ink should be drawn at its new place")
        XCTAssertFalse(showsInk(near: CGPoint(x: 260, y: 440)), "and no longer at its old one")
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

    /// Ink is drawn over the elements under it, so where it crosses one a finger in Select
    /// picks and moves the drawing, as the Pencil's hover outlines it (audit C3).
    func testInkOverAnElementIsWhatATapPicksAndADragMoves() {
        let button = addAButtonAndOpenTheFormatPanel()
        // A stroke across the left half of the button, drawn with nothing selected: a finger
        // on a selected element in Draw moves it.
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement))
        control("Draw").tap()
        choosePaletteTool("Pen")
        let left = CGPoint(x: button.centre.x - 90, y: button.centre.y)
        stroke(left, CGPoint(x: button.centre.x + 10, y: button.centre.y))
        control("Draw").tap()

        // On the ink, a tap picks the drawing; on the button clear of it, the button. A tap
        // adds to what is selected, so empty canvas lets go of the drawing between them.
        point(CGPoint(x: button.centre.x - 40, y: button.centre.y)).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == 'Drawing · 1 stroke'", timeout: 5), "a tap on ink over the button should pick the drawing")
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement))
        point(CGPoint(x: button.centre.x + 80, y: button.centre.y)).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == '\(button.value)'", timeout: 5), "a tap on the button away from the ink should pick the button")

        // With the button selected, a drag that starts on the ink moves the drawing, not it.
        let moved = CGVector(dx: 0, dy: 160)
        stroke(CGPoint(x: button.centre.x - 40, y: button.centre.y), CGPoint(x: button.centre.x - 40 + moved.dx, y: button.centre.y + moved.dy))
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == 'Drawing · 1 stroke'", timeout: 5), "the drag should have picked up the drawing")
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(showsInk(near: CGPoint(x: left.x + 50 + moved.dx, y: left.y + moved.dy)), "the ink should be drawn where it was dragged")
        point(CGPoint(x: button.centre.x + 80, y: button.centre.y)).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == '\(button.value)'", timeout: 5), "the button should have stayed where it was")
        attach("ink-over-a-button")
    }

    /// A selected drawing is dragged by its whole box, but a tap inside the box, off its ink,
    /// reaches what lies under it: here a button that a line drawn across the screen's corner
    /// has in its box. The box used to swallow the tap (audit C12).
    func testATapInsideASelectedDrawingsBoxPicksWhatIsUnderIt() {
        let button = addAButtonAndOpenTheFormatPanel()
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement))
        control("Draw").tap()
        choosePaletteTool("Pen")
        // A line from above the button's left to below its right: its box holds the button,
        // and it passes 40 points or more from where the button is tapped below.
        let centre = button.centre
        stroke(CGPoint(x: centre.x - 150, y: centre.y - 100), CGPoint(x: centre.x + 150, y: centre.y + 100))
        control("Draw").tap()

        point(CGPoint(x: centre.x - 120, y: centre.y - 80)).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == 'Drawing · 1 stroke'", timeout: 5), "a tap on the ink should pick the drawing")
        // The tap reaches the button inside the box, and adds it to the drawing.
        point(CGPoint(x: centre.x + 80, y: centre.y)).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH '2 items'", timeout: 5), "a tap on the button inside the drawing's box should pick the button")
        attach("tap-inside-a-drawings-box")
    }

    /// A screen selected with other things is dragged by its whole area, but a tap there
    /// reaches what lies under it: an element on it takes the screen's place, and its empty
    /// area lets go of everything. The area used to take the screen out of the selection.
    func testATapOnAScreenSelectedWithOtherThingsReachesWhatIsOnIt() {
        let button = addAButtonAndOpenTheFormatPanel()
        // A drawing off the screen, to select with it.
        control("Draw").tap()
        choosePaletteTool("Pen")
        stroke(CGPoint(x: 120, y: 420), CGPoint(x: 240, y: 470))
        control("Draw").tap()
        point(CGPoint(x: 180, y: 445)).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == 'Drawing · 1 stroke'", timeout: 5), "a tap on the ink should pick the drawing")
        let name = app.staticTexts["Screen 1"]
        name.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH '2 items'", timeout: 5), "a tap on the screen's name should add the screen")
        let withTheScreen = selectionSize

        // On the screen's button: the button takes the screen's place beside the drawing.
        point(button.centre).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH '2 items'", timeout: 5), "a tap on the button should replace the screen with it")
        XCTAssertLessThan(selectionSize.height, withTheScreen.height - 100, "the drawing and the button should cover less than the drawing and the screen")

        // Added again, the screen folds the button in. A tap on its empty area lets go of all.
        name.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH '2 items'", timeout: 5), "a tap on the screen's name should add it again")
        point(CGPoint(x: button.centre.x, y: button.centre.y - 150)).tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement), "a tap on the screen's empty area should let go of everything")
        attach("tap-on-a-screen-among-several")
    }

    /// In Draw the palette goes while text is typed, and comes back as the keyboard goes
    /// (audit C5, follow-up).
    func testThePaletteComesBackWhenTypingEndsInDraw() {
        // With a pencil about, a finger taps to select while the palette is up.
        app.launchArguments += ["-fingerDraws", "NO"]
        openNewDesign()
        // New text is selected and opened for typing, with the palette put away.
        control("Text").tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == '200 × 24'", timeout: 5), "new text should be selected")
        app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        let palette = app.buttons["Magic Pen"].firstMatch
        control("Draw").tap()
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "Draw should bring up the palette")
        let window = app.windows.firstMatch.frame
        point(CGPoint(x: window.midX, y: window.midY)).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == '200 × 24'", timeout: 5), "a finger tap in Draw should select the text")

        // Typed into, the palette makes way for the keyboard.
        control("Edit text").tap()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Edit text should open the text's popover")
        let field = popover.textViews.firstMatch.exists ? popover.textViews.firstMatch : popover.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" there")
        XCTAssertTrue(waitForDisappearance(of: palette), "the palette should make way while text is typed")

        // The popover is closed and the keyboard goes: the palette is back.
        app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: popover))
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "the palette should come back once typing ends in Draw")
        attach("palette-after-typing")
    }

    func testADrawingIsALayerThatCanBeHiddenLockedAndCopied() {
        openNewDesign()

        // Two strokes with the Pen, crossing, clear of where the layers panel opens.
        choosePaletteTool("Pen")
        stroke(CGPoint(x: 780, y: 400), CGPoint(x: 900, y: 480))
        stroke(CGPoint(x: 900, y: 400), CGPoint(x: 780, y: 480))
        let ink = CGPoint(x: 840, y: 440)
        let empty = CGPoint(x: 700, y: 650)
        control("Draw").tap()
        point(ink).tap()
        let readout = selectionElement
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "tapping ink should select the drawing")

        // It is a layer like any other, listed under the canvas.
        control("Layers").tap()
        let row = app.buttons["Drawing"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the drawing should be listed as a layer")

        // Hidden, its ink leaves the canvas and can't be picked there. Shown, it is back.
        control("Hide Drawing").tap()
        point(ink).tap()
        XCTAssertFalse(readout.waitForExistence(timeout: 2), "a hidden drawing can't be picked on the canvas")
        control("Show Drawing").tap()
        point(ink).tap()
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "shown again, the drawing should be back where it was")

        // Locked, it is still there to be picked, and offers only to be unlocked.
        control("Lock").tap()
        XCTAssertTrue(control("Unlock").waitForExistence(timeout: 5), "a locked drawing should offer to unlock")
        point(empty).tap()
        XCTAssertTrue(waitForDisappearance(of: readout))
        point(ink).tap()
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "a locked drawing should still be on the canvas")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "locked-drawing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        control("Unlock").tap()

        // Copied, there are two drawings.
        XCTAssertTrue(control("Duplicate").waitForExistence(timeout: 5))
        control("Duplicate").tap()
        let rows = app.buttons.matching(NSPredicate(format: "label == %@", "Drawing"))
        XCTAssertTrue(wait(for: rows.element(boundBy: 1), toHave: "exists == true", timeout: 5), "the copy should be listed as a layer too")
    }

    func testUndoGoesBackThroughMovingADrawingAndThroughDrawingIt() {
        openNewDesign()

        // Two strokes with the Pen, crossing, make one drawing.
        choosePaletteTool("Pen")
        stroke(CGPoint(x: 780, y: 400), CGPoint(x: 900, y: 480))
        stroke(CGPoint(x: 900, y: 400), CGPoint(x: 780, y: 480))
        let crossing = CGPoint(x: 840, y: 440)
        // On the first stroke only, away from where the second crosses it.
        let firstStroke = CGPoint(x: 795, y: 410)
        let empty = CGPoint(x: 700, y: 650)
        control("Draw").tap()
        point(crossing).tap()
        let readout = selectionElement
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "tapping ink should select the drawing")

        // Moving the drawing is a change to the design; drawing its strokes was PencilKit's.
        stroke(crossing, CGPoint(x: 1000, y: 300))
        point(empty).tap()
        XCTAssertTrue(waitForDisappearance(of: readout))
        let undo = app.buttons.matching(identifier: "arrow.uturn.backward").firstMatch
        let redo = app.buttons.matching(identifier: "arrow.uturn.forward").firstMatch

        // The first undo takes back the move.
        undo.tap()
        point(crossing).tap()
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "undo should move the drawing back")
        point(empty).tap()

        // The next takes back the second stroke, leaving a drawing of one.
        undo.tap()
        point(firstStroke).tap()
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 1 stroke'", timeout: 5), "undo should take back the second stroke")
        point(empty).tap()

        // The next takes back the first, and the drawing with it.
        undo.tap()
        point(firstStroke).tap()
        XCTAssertFalse(readout.waitForExistence(timeout: 2), "undo should take back the first stroke, and so the drawing")

        // Redo brings both strokes back as one drawing.
        redo.tap()
        redo.tap()
        point(crossing).tap()
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "redo should bring the drawing back")
    }

    func testSeveralThingsAreBoxedLinedUpMovedAndDeletedTogether() {
        openNewDesign()

        // Two drawings well apart, each two crossing strokes of the Pen.
        choosePaletteTool("Pen")
        stroke(CGPoint(x: 200, y: 400), CGPoint(x: 320, y: 480))
        stroke(CGPoint(x: 320, y: 400), CGPoint(x: 200, y: 480))
        stroke(CGPoint(x: 780, y: 300), CGPoint(x: 900, y: 380))
        stroke(CGPoint(x: 900, y: 300), CGPoint(x: 780, y: 380))
        let empty = CGPoint(x: 700, y: 650)
        control("Draw").tap()

        // A finger that rests on the canvas and then drags pulls out a box, which selects
        // what it holds: both drawings, as one selection.
        point(CGPoint(x: 150, y: 250)).press(forDuration: 0.9, thenDragTo: point(CGPoint(x: 950, y: 540)))
        let readout = selectionElement
        XCTAssertTrue(wait(for: readout, toHave: "value BEGINSWITH '2 items'", timeout: 5), "the box should select both drawings")
        let apart = selectionSize
        XCTAssertGreaterThan(apart.width, 600, "the two drawings start well apart")
        let boxed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        boxed.name = "several-selected"
        boxed.lifetime = .keepAlways
        add(boxed)

        // Their popover lines them up with each other: left edges together, they cover
        // the width of one of them, and are as far apart down the canvas as before.
        control("Align").tap()
        app.buttons["Align Left"].tap()
        XCTAssertTrue(wait(for: readout, toHave: "value BEGINSWITH '2 items'", timeout: 5))
        for _ in 0..<20 where selectionSize.width > 200 { usleep(150_000) }
        XCTAssertLessThan(selectionSize.width, 200, "lined up by their left edges, the two should sit one above the other")
        XCTAssertEqual(selectionSize.height, apart.height, accuracy: 3, "lining up across shouldn't move anything down")
        XCTAssertTrue(showsInk(near: CGPoint(x: 260, y: 340)), "the drawing that moved should be drawn where it now is")
        XCTAssertFalse(showsInk(near: CGPoint(x: 840, y: 340)), "and no longer where it was")

        // The format panel has settings for them together.
        control("Format selection").tap()
        XCTAssertTrue(app.staticTexts["2 Items"].waitForExistence(timeout: 5), "the format panel should be for both")
        XCTAssertTrue(control("Distribute Horizontally").exists)
        XCTAssertFalse(control("Distribute Horizontally").isEnabled, "two things have nothing to be spaced between")
        let formatted = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        formatted.name = "several-format"
        formatted.lifetime = .keepAlways
        add(formatted)
        control("Format selection").tap()

        // Dragging one moves both: each is found 200 across and 100 down from where it was.
        stroke(CGPoint(x: 260, y: 440), CGPoint(x: 460, y: 540))
        XCTAssertTrue(wait(for: readout, toHave: "value BEGINSWITH '2 items'", timeout: 5), "they should stay selected after the drag")
        point(empty).tap()
        XCTAssertTrue(waitForDisappearance(of: readout))
        point(CGPoint(x: 460, y: 440)).tap()
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "the drawing that wasn't under the finger should have moved too")
        point(empty).tap()
        point(CGPoint(x: 260, y: 340)).tap()
        XCTAssertFalse(readout.waitForExistence(timeout: 2), "and should have left where it was")

        // The move is one step to undo.
        app.buttons.matching(identifier: "arrow.uturn.backward").firstMatch.tap()
        point(CGPoint(x: 260, y: 340)).tap()
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "one undo should put both back")
        point(empty).tap()

        // Boxed again and deleted, both are gone.
        point(CGPoint(x: 150, y: 250)).press(forDuration: 0.9, thenDragTo: point(CGPoint(x: 950, y: 540)))
        XCTAssertTrue(wait(for: readout, toHave: "value BEGINSWITH '2 items'", timeout: 5))
        control("Delete selection").tap()
        XCTAssertTrue(waitForDisappearance(of: readout))
        for place in [CGPoint(x: 260, y: 440), CGPoint(x: 260, y: 340)] {
            point(place).tap()
            XCTAssertFalse(readout.waitForExistence(timeout: 2), "both drawings should be gone")
        }
    }

    func testTheLassoPicksThingsAndLeavesNoInk() {
        openNewDesign()

        // A drawing: two crossing strokes of the Pen.
        choosePaletteTool("Pen")
        stroke(CGPoint(x: 780, y: 400), CGPoint(x: 900, y: 480))
        stroke(CGPoint(x: 900, y: 400), CGPoint(x: 780, y: 480))
        let crossing = CGPoint(x: 840, y: 440)

        // With the palette's lasso in hand, a tap on the ink picks the drawing.
        choosePaletteTool("Lasso")
        point(crossing).tap()
        let readout = selectionElement
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "a tap of the lasso should pick the drawing")

        // What the lasso picked can be dragged with the lasso still in hand.
        stroke(crossing, CGPoint(x: 640, y: 340))
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5))

        // A line drawn with the lasso goes round nothing: it lets go of the drawing, and
        // leaves no ink behind.
        stroke(CGPoint(x: 300, y: 300), CGPoint(x: 500, y: 400))
        XCTAssertTrue(waitForDisappearance(of: readout), "a lasso round nothing should let go")
        point(CGPoint(x: 400, y: 350)).tap()
        XCTAssertFalse(readout.waitForExistence(timeout: 2), "the lasso should leave no ink where it was drawn")

        // The drawing is where it was dragged to, and no longer where it was drawn.
        point(crossing).tap()
        XCTAssertFalse(readout.waitForExistence(timeout: 2), "the drawing should have left its old place")
        point(CGPoint(x: 640, y: 340)).tap()
        XCTAssertTrue(wait(for: readout, toHave: "value == 'Drawing · 2 strokes'", timeout: 5), "the drawing should be where the lasso dragged it")
    }

    func testTheLibraryHasTabsAndThingsAreDraggedFromItOntoTheCanvas() {
        openNewDesign()
        control("Library").tap()
        XCTAssertTrue(app.textFields["Search the library"].waitForExistence(timeout: 5), "the library should open")
        for tab in ["Icons", "Wireframes", "Shapes", "Components"] {
            app.buttons[tab].tap()
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "library-\(tab.lowercased())"
            shot.lifetime = .keepAlways
            add(shot)
        }

        // A star dragged from the shapes lands where it is let go, selected. The library
        // gets out of the way of the drop.
        app.buttons["Shapes"].tap()
        let star = app.buttons["Star"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        let target = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.width * 0.25, dy: window.height * 0.6))
        star.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0, thenDragTo: target)
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == '100 × 100'", timeout: 5), "the star should be on the canvas, selected")
        let dropped = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dropped.name = "library-dropped"
        dropped.lifetime = .keepAlways
        add(dropped)

        // Searching for something in another tab goes to it.
        let search = app.textFields["Search the library"]
        if !search.exists { control("Library").tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("toggle")
        XCTAssertTrue(app.buttons["Toggle"].firstMatch.waitForExistence(timeout: 5), "a search for a component should show the components")
        let searched = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        searched.name = "library-search"
        searched.lifetime = .keepAlways
        add(searched)
    }

    func testWithTheLassoInHandAFingerStillTapsAndPans() {
        // As once Apple Pencil has been seen: the Pencil draws the lasso and a finger doesn't.
        app.launchArguments += ["-fingerDraws", "NO"]
        openNewDesign()
        addFrame("iPhone")
        let label = app.staticTexts["Screen 1"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        control("Draw").tap()
        choosePaletteTool("Lasso")

        // A finger tap on the frame selects it, and one on empty canvas lets go.
        point(CGPoint(x: 150, y: 650)).tap()
        point(CGPoint(x: label.frame.minX + 100, y: label.frame.maxY + 250)).tap()
        XCTAssertTrue(control("Delete selection").waitForExistence(timeout: 5), "a finger tap should select the frame")
        point(CGPoint(x: 150, y: 650)).tap()
        XCTAssertTrue(waitForDisappearance(of: control("Delete selection")))

        // A finger drag pans the canvas: it is the Pencil that draws the lasso.
        let before = label.frame
        stroke(CGPoint(x: 150, y: 420), CGPoint(x: 230, y: 500))
        sleep(1)
        XCTAssertGreaterThan(label.frame.minX - before.minX, 40, "a finger should pan the canvas with the lasso in hand")
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
            "Designs", "Board title", "Layers", "Draw", "Text", "Sticky note", "Library", "Add Image",
            "Share", "Zoom out", "Zoom", "Zoom in", "Magic Pen",
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

    func testACloseCallOffersWhatItNearlyWasAndBecomesThatWhenTapped() {
        // The scripted demo draws a screen, then a wide box whose corners are between a
        // text field's and a button's.
        app.launchArguments = ["-LayerDemo", "screen,closeCall"]
        openNewDesign()

        let suggestion = app.buttons.matching(labelBeginning("Did you mean")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 40), "a close call should offer what it nearly was")
        // Which of the two it was read as depends on how large it was drawn; the other is offered.
        let offersTextField = suggestion.label.contains("Text Field")
        let (read, offered) = offersTextField ? ("Continue", "Placeholder") : ("Placeholder", "Continue")
        XCTAssertTrue(app.staticTexts[read].exists, "the box should have become a button or a text field")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "did-you-mean"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        suggestion.tap()
        XCTAssertTrue(app.staticTexts[offered].waitForExistence(timeout: 5), "taking the suggestion should make it what was offered")
        XCTAssertFalse(app.staticTexts[read].exists, "what it was read as should be gone")
        XCTAssertTrue(waitForDisappearance(of: suggestion), "the suggestion should go once it is taken")
    }

    // MARK: Rotation

    func testTheRotationFieldTurnsTheSelection() {
        let button = addAButtonAndOpenTheFormatPanel()
        setRotation(to: "90")

        // Turned a quarter, the button stands on its end: where its right end was is now the
        // screen's own, and the centre is still the button's. A tap on the screen's empty
        // area first lets go of the button, and then selects the screen.
        let end = point(CGPoint(x: button.centre.x + 100, y: button.centre.y))
        end.tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement), "where the button's end was (100 points out from its centre) should hit no button, and let go of it")
        end.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Screen 1'", timeout: 5), "tapped again, the spot should select its screen")
        // The selected screen's own empty area lets go of it, as the canvas does.
        end.tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement), "a tap on the selected screen's empty area should let go of it")
        end.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Screen 1'", timeout: 5))
        // A thing on a selected screen takes the screen's place.
        point(button.centre).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == '\(button.value)'", timeout: 5), "the centre should still select the button")
        attach("rotation-turned-button")
    }

    func testTheKnobTurnsAndADoubleTapStandsItUpright() {
        let button = addAButtonAndOpenTheFormatPanel()
        let knob = control("Rotate")
        XCTAssertTrue(knob.waitForExistence(timeout: 5), "a selected element should offer its knob")

        knob.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: point(CGPoint(x: button.centre.x - 160, y: button.centre.y)))
        XCTAssertTrue(wait(for: control("Rotation"), toHave: "value == '90'", timeout: 5), "the knob, taken level out to the left, should read 90")

        XCTAssertTrue(control("Rotate").waitForExistence(timeout: 5))
        control("Rotate").doubleTap()
        XCTAssertTrue(wait(for: control("Rotation"), toHave: "value == '0'", timeout: 5), "a double tap on the knob should stand it upright")
    }

    func testATurnedDrawingIsDrawnWhereItIs() {
        openNewDesign()
        choosePaletteTool("Pen")
        stroke(CGPoint(x: 300, y: 420), CGPoint(x: 560, y: 420))
        control("Draw").tap()
        point(CGPoint(x: 430, y: 420)).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Drawing'", timeout: 5), "tapping the stroke should select the drawing")
        XCTAssertTrue(showsInk(near: CGPoint(x: 540, y: 420)), "the stroke should be drawn where it was drawn")

        control("Format").tap()
        setRotation(to: "90")
        XCTAssertTrue(showsInk(near: CGPoint(x: 430, y: 310)), "turned a quarter, the stroke should rise above its centre")
        XCTAssertFalse(showsInk(near: CGPoint(x: 540, y: 420)), "and no longer reach its old end")
        attach("rotation-turned-drawing")
    }

    // MARK: Groups

    /// A group's Format panel is its own: the settings of what is in it, rather than one
    /// element's, its lock, and its W, which scales it in proportion. A member of a locked
    /// group, gone into with a double-tap, shows the lock that holds it, and Unlock there
    /// unlocks the group. Copied and deleted from the panel, a group goes with its members.
    func testAGroupHasAFormatPanelOfItsOwn() {
        openNewDesign()
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let centre = CGPoint(x: window.midX, y: window.midY)
        let lower = CGPoint(x: centre.x, y: centre.y + 120)
        let empty = CGPoint(x: 120, y: window.midY)

        // Two buttons, one above the other, selected together and grouped.
        addButtonFromTheLibrary()
        stroke(centre, lower)
        addButtonFromTheLibrary()
        point(lower).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH '2 items'", timeout: 5), "a tap on the first button should add it")
        control("Group").tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Group · '", timeout: 5), "Group should select the new group")
        let size = selectionSize

        // Its panel has its members' settings, not one element's, and its lock.
        control("Format selection").tap()
        XCTAssertNotNil(panelControl("Fill colour"), "the group's panel should have its members' fill")
        XCTAssertNotNil(panelControl("Ungroup"))
        panelControl("Lock")?.tap()
        XCTAssertNotNil(panelControl("Unlock"), "locked from the panel, the panel should offer to unlock it")
        attach("group-format-locked")

        // A member, gone into with a double-tap, is locked by its group, and its panel says so.
        point(centre).doubleTap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "NOT (value BEGINSWITH 'Group') AND value MATCHES '[0-9]+ × [0-9]+'", timeout: 5), "a double-tap should go into the group")
        if panelControl("Unlock", timeout: 1) == nil { control("Format").tap() }
        XCTAssertNotNil(panelControl("Unlock"), "a member of a locked group should show it is locked")
        XCTAssertNil(panelControl("Lock", timeout: 1))
        attach("group-format-member-locked")
        panelControl("Unlock")?.tap()
        XCTAssertNotNil(panelControl("Lock"), "Unlock on the member should unlock the group that held it")

        // The group selected again, its W scales it in proportion.
        point(empty).tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement))
        point(centre).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Group · '", timeout: 5), "a tap on a member should pick its group")
        if panelControl("Ungroup", timeout: 1) == nil { control("Format selection").tap() }
        setNumber("W", to: "\(Int(size.width) * 2)")
        for _ in 0..<20 where abs(selectionSize.height - size.height * 2) > 2 { usleep(150_000) }
        XCTAssertEqual(selectionSize.width, size.width * 2, accuracy: 2, "W should double the group's width")
        XCTAssertEqual(selectionSize.height, size.height * 2, accuracy: 2, "and its height with it")
        attach("group-format-doubled")

        // Copied, then the copy deleted: it goes with its members, leaving the group under them.
        panelControl("Duplicate")?.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Group · '", timeout: 5), "the copy should be selected")
        panelControl("Delete")?.tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement))
        point(centre).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Group · '", timeout: 5), "the copy's members should have gone with it")

        // Deleted, the group leaves nothing behind: a tap there finds the screen.
        if panelControl("Delete", timeout: 1) == nil { control("Format selection").tap() }
        panelControl("Delete")?.tap()
        XCTAssertTrue(waitForDisappearance(of: selectionElement))
        point(centre).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Screen 1'", timeout: 5), "the group's members should have gone with it")
    }

    /// Rows in the Layers panel drag to reorder, into an open group, out of it and onto a closed
    /// group's row, each by a long press then a drag; a quick swipe still scrolls.
    func testLayersPanelRowsDragIntoAndOutOfGroups() {
        openNewDesign()
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let centre = CGPoint(x: window.midX, y: window.midY)
        let lower = CGPoint(x: centre.x, y: centre.y + 120)

        // Two buttons grouped, and a heart symbol in front of the group.
        addButtonFromTheLibrary()
        stroke(centre, lower)
        addButtonFromTheLibrary()
        point(lower).tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH '2 items'", timeout: 5))
        control("Group").tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value BEGINSWITH 'Group · '", timeout: 5))
        control("Library").tap()
        let search = app.textFields["Search the library"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("heart fill")
        let heart = app.buttons["heart.fill"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        heart.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value == '44 × 44'", timeout: 5))
        control("Layers").tap()
        XCTAssertNotNil(layerRow("Symbol"), "the symbol should be listed")
        XCTAssertNotNil(layerRow("Group"), "the group should be listed")
        attach("layers-drag-start")

        // Panel top to bottom: Symbol, Group (closed). Dropped on the closed group's row, the
        // symbol goes inside it.
        XCTAssertTrue(layerOrder(["Symbol", "Group"]), "the symbol should start above the group")
        dragRow("Symbol", onto: "Group")
        // The symbol is selected, so the group it is in opens on it.
        let chevron = app.buttons["Show contents"].firstMatch
        if chevron.waitForExistence(timeout: 2) { chevron.tap() }
        XCTAssertTrue(waitForLayers { self.layerOrder(["Group", "Symbol", "Button", "Button"]) }, "a row dropped on a closed group's row should go inside, at the top; it landed at the top of the group")
        attach("layers-drag-into-group")

        // Inside the group, dragged down below the buttons: still in the group, now at the back.
        dragRow("Symbol", onto: "Button", index: 1, dy: 18)
        XCTAssertTrue(waitForLayers { self.layerOrder(["Group", "Button", "Button", "Symbol"]) }, "a row dropped below the last one in a group should go to its back")
        attach("layers-drag-within-group")

        // Out of the group: dropped above the group's own row.
        dragRow("Symbol", onto: "Group", dy: -14)
        XCTAssertTrue(waitForLayers { self.layerOrder(["Symbol", "Group"]) && self.layerRow("Button") == nil }, "a row dropped above a group's row should leave the group, which closes with nothing selected in it")
        attach("layers-drag-out-of-group")

        // A quick swipe doesn't drag a row: nothing moves.
        let row = layerRow("Group")!
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: -2)))
        XCTAssertTrue(layerOrder(["Symbol", "Group"]), "a quick swipe shouldn't reorder rows")
    }

    /// A row of the Layers panel, which floats at the window's left, by its label; nil when
    /// there is none. The first of several of one name, topmost first, unless `index` says.
    private func layerRow(_ label: String, index: Int = 0) -> XCUIElement? {
        let rows = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minX < 340 && $0.frame.width > 80 }
            .sorted { $0.frame.minY < $1.frame.minY }
        return index < rows.count ? rows[index] : nil
    }

    /// Whether the panel's rows, top to bottom, begin with these.
    private func layerOrder(_ labels: [String]) -> Bool {
        var last: CGFloat = -1
        var seen: [String: Int] = [:]
        for label in labels {
            let n = seen[label, default: 0]
            seen[label] = n + 1
            guard let row = layerRow(label, index: n), row.frame.minY > last else { return false }
            last = row.frame.minY
        }
        return true
    }

    private func waitForLayers(_ condition: () -> Bool) -> Bool {
        for _ in 0..<20 {
            if condition() { return true }
            usleep(250_000)
        }
        return false
    }

    /// Long-presses a row and drags it onto another, `dy` points below the middle of that one.
    private func dragRow(_ label: String, onto target: String, index: Int = 0, dy: CGFloat = 0) {
        guard let from = layerRow(label), let to = layerRow(target, index: index) else { return XCTFail("rows \(label), \(target) should be listed") }
        from.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: to.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).withOffset(CGVector(dx: 0, dy: dy)))
        usleep(800_000)
        attach("layers-after-dragging-\(label)")
    }

    /// Adds a button from the library, which lands selected in the middle of the view.
    private func addButtonFromTheLibrary() {
        control("Library").tap()
        let search = app.textFields["Search the library"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the library should open")
        let component = app.buttons["Button"].firstMatch
        if !component.exists {
            search.tap()
            search.typeText("button")
        }
        XCTAssertTrue(component.waitForExistence(timeout: 5))
        component.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value MATCHES '[0-9]+ × [0-9]+'", timeout: 5), "the new button should be selected")
    }

    /// A control in the Format panel, which floats at the canvas's right, by its label: the
    /// popover over the selection can have one of the same name. Nil when the panel has none.
    private func panelControl(_ label: String, timeout: TimeInterval = 5) -> XCUIElement? {
        let edge = app.windows.firstMatch.frame.maxX - 340
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            if let found = matches.first(where: { $0.exists && $0.isHittable && $0.frame.minX > edge }) { return found }
            usleep(200_000)
        } while Date() < deadline
        return nil
    }

    /// Types a number into one of the Format panel's fields.
    private func setNumber(_ label: String, to value: String) {
        // A key can be dropped when the simulator is busy, so a wrong number is typed again.
        for _ in 0..<3 {
            let field = control(label)
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            let typing = app.textFields[label]
            XCTAssertTrue(typing.waitForExistence(timeout: 5), "tapping the \(label) field should let it be typed in")
            typing.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + value + "\n")
            if wait(for: control(label), toHave: "value == '\(value)'", timeout: 4) { return }
        }
        XCTFail("the field should read \(value), not \(String(describing: control(label).value))")
    }

    /// Adds a button from the library, which lands selected in the middle of the screen, and
    /// opens the format panel. Gives where the button is and what the canvas says of it.
    private func addAButtonAndOpenTheFormatPanel() -> (centre: CGPoint, size: CGSize, value: String) {
        openNewDesign()
        box(sketch)
        convert()
        XCTAssertTrue(app.staticTexts["Screen 1"].waitForExistence(timeout: 10))
        control("Library").tap()
        let search = app.textFields["Search the library"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the library should open")
        search.tap()
        search.typeText("button")
        let component = app.buttons["Button"].firstMatch
        XCTAssertTrue(component.waitForExistence(timeout: 5))
        component.tap()
        XCTAssertTrue(wait(for: selectionElement, toHave: "value MATCHES '[0-9]+ × [0-9]+'", timeout: 5), "the new button should be selected")
        let size = selectionSize
        let value = selectionElement.value as? String ?? ""
        if !control("Rotation").exists { control("Format").tap() }
        XCTAssertTrue(control("Rotation").waitForExistence(timeout: 5), "the format panel should have a Rotation field")
        let window = app.windows.firstMatch.frame
        return (CGPoint(x: window.midX, y: window.midY), size, value)
    }

    private func setRotation(to degrees: String) {
        // A key can be dropped when the simulator is busy, so a wrong number is typed again.
        for _ in 0..<3 {
            let field = control("Rotation")
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            let typing = app.textFields["Rotation"]
            XCTAssertTrue(typing.waitForExistence(timeout: 5), "tapping the Rotation field should let it be typed in")
            typing.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + degrees + "\n")
            if wait(for: control("Rotation"), toHave: "value == '\(degrees)'", timeout: 4) { return }
        }
        XCTFail("the field should read \(degrees), not \(String(describing: control("Rotation").value))")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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

    /// Reads the sketch on the canvas. The tests draw with conversion after a pause off;
    /// switching it on in the board's Magic Pen tab reads what is there after the pause.
    /// The menu is closed at once, so the sketch is read with it closed: a board named
    /// while its menu is open has the menu's old title written back when it closes.
    private func convert() {
        setConvertsAfterAPause(true)
        // The pause of 0.9 s, and the reading itself.
        sleep(2)
        setConvertsAfterAPause(false)
    }

    private func setConvertsAfterAPause(_ isOn: Bool) {
        openMagicPenSettings()
        let toggle = app.switches["Convert After a Pause"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the board menu should have the conversion setting")
        if ((toggle.value as? String) == "1") != isOn {
            let knob = toggle.switches.firstMatch
            (knob.exists ? knob : toggle).tap()
        }
        closeMenu()
    }

    /// Opens the board's menu at its Magic Pen tab.
    private func openMagicPenSettings() {
        control("Board title").tap()
        let tab = app.segmentedControls.buttons["Magic Pen"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "the board menu should have a Magic Pen tab")
        tab.tap()
    }

    /// Closes a popover, such as the board's menu, the way a tap outside it would.
    private func closeMenu() {
        app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: app.segmentedControls.firstMatch))
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

    /// Adds a frame of the device whose name starts with `device`, from the library's wireframes.
    private func addFrame(_ device: String) {
        control("Library").tap()
        let tab = app.buttons["Wireframes"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "the library should open")
        tab.tap()
        let frame = app.buttons.matching(labelBeginning(device)).firstMatch
        XCTAssertTrue(frame.waitForExistence(timeout: 5))
        frame.tap()
    }

    private func labelBeginning(_ prefix: String) -> NSPredicate {
        NSPredicate(format: "label BEGINSWITH %@", prefix)
    }

    private func labelContaining(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    /// What is selected and its size, as the canvas tells VoiceOver: "228 × 40", "Drawing · 2 strokes".
    private var selectionElement: XCUIElement {
        app.descendants(matching: .any)["Selection"]
    }

    /// Whether ink, which is dark, is drawn within a few points of a place in the window.
    /// Read from a picture of the screen: what is drawn, not what a tap would find.
    private func showsInk(near place: CGPoint, within reach: CGFloat = 10) -> Bool {
        // Whatever is gliding into place has a moment to arrive.
        usleep(600_000)
        let window = app.windows.firstMatch.frame
        guard let picture = XCUIScreen.main.screenshot().image.cgImage else { return false }
        // The picture is the screen as the device holds it: upright, or on its side when
        // the iPad is turned, with the window's top along the picture's right edge.
        let isUpright = (picture.width > picture.height) == (window.width > window.height)
        let scale = CGFloat(isUpright ? picture.width : picture.height) / window.width
        let area = CGRect(x: place.x - reach, y: place.y - reach, width: reach * 2, height: reach * 2)
        let pixels = isUpright
            ? CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)
            : CGRect(x: (window.height - area.maxY) * scale, y: area.minX * scale, width: area.height * scale, height: area.width * scale)
        guard let crop = picture.cropping(to: pixels.integral) else { return false }

        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        guard drawn else { return false }
        var dark = 0
        for index in stride(from: 0, to: bytes.count, by: 4) where Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) < 200 {
            dark += 1
        }
        // The dots of the canvas's grid are pale; a stroke through the area is some dozens of dark pixels.
        return dark >= 12
    }

    /// The size at the end of the selection's spoken value: the area several things
    /// cover together, in "2 items · 700 × 180". Zero when it gives no size.
    private var selectionSize: CGSize {
        guard let value = selectionElement.value as? String, let size = value.components(separatedBy: " · ").last else { return .zero }
        let sides = size.components(separatedBy: " × ").compactMap { Double($0) }
        return sides.count == 2 ? CGSize(width: sides[0], height: sides[1]) : .zero
    }

    private func wait(for element: XCUIElement, toHave condition: String, timeout: TimeInterval = 8) -> Bool {
        let met = expectation(for: NSPredicate(format: condition), evaluatedWith: element)
        return XCTWaiter().wait(for: [met], timeout: timeout) == .completed
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        wait(for: element, toHave: "exists == false", timeout: timeout)
    }
}
