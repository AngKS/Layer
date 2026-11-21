import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

@Suite("Handles for a call")
@MainActor
struct VoiceHandlesTests {
    @Test func handlesAreStableAndForgiving() {
        let handles = VoiceHandles()
        let (first, second, screen) = (UUID(), UUID(), UUID())
        #expect(handles.handle(forElement: first) == "E1")
        #expect(handles.handle(forElement: second) == "E2")
        #expect(handles.handle(forElement: first) == "E1")
        #expect(handles.handle(forScreen: screen) == "S1")
        #expect(handles.handle(forScreen: screen) == "S1")

        #expect(handles.element("E1") == first)
        #expect(handles.element("e1") == first)
        #expect(handles.element(" E1 ") == first)
        #expect(handles.element("#E1") == first)
        #expect(handles.element("E 2") == second)
        #expect(handles.screen("s1") == screen)

        // One kind's handle is never taken for the other's, and unknown ones are nobody's.
        #expect(handles.element("S1") == nil)
        #expect(handles.screen("E1") == nil)
        #expect(handles.element("E9") == nil)
        #expect(handles.element("the button") == nil)

        // Numbers only go up, so a handle is never handed to something else later.
        #expect(handles.handle(forElement: UUID()) == "E3")
    }
}

@Suite("The canvas as a model is told it")
@MainActor
struct CanvasPictureTests {
    @Test func thePictureListsScreensAndElements() throws {
        let (app, screen) = VoiceFixture.login()
        let button = try #require(app.store.screen(screen)?.elements.first { $0.kind == .button })
        app.selection = .element(.init(host: .screen(screen), element: button.id))
        let picture = CanvasPicture.capture(from: app, handles: VoiceHandles())
        #expect(picture.hasScreens)
        let text = picture.text(.full)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix(#"S1 "Login" 393x852"#) })
        #expect(lines.contains { $0.contains(#"E1 title "Welcome back" x20 y75 w353 h41"#) })
        #expect(lines.contains { $0.contains(#"E2 button "Sign in" x20 y420 w353 h50"#) && $0.contains("[selected]") })
        #expect(lines.contains { $0.contains("E3 image x20 y500 w200 h200") })
        #expect(lines.filter { $0.contains("[selected]") }.count == 1)
    }

    /// Ink is an element like any other in the design, and a board can hold hundreds of
    /// drawings. They are the Pencil's: a model is told nothing of them, so it has no
    /// handle to change one by, and the on-device model's little room isn't spent on them.
    @Test func drawingsAreLeftOutOfWhatAModelIsTold() throws {
        let (app, _) = VoiceFixture.login()
        let points: [PKStrokePoint] = (0...10).map { (step: Int) -> PKStrokePoint in
            let along = CGFloat(100 + step * 6)
            return PKStrokePoint(
                location: CGPoint(x: along, y: along), timeOffset: TimeInterval(step) * 0.01,
                size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        app.store.addFloating(try #require(DesignElement.drawing([stroke])), scale: 1)
        #expect(app.store.floating.count == 1)

        let handles = VoiceHandles()
        let picture = CanvasPicture.capture(from: app, handles: handles)

        #expect(picture.loose.isEmpty)
        #expect(picture.screens.first?.elements.map(\.kind) == ["title", "button", "image"])
        #expect(!picture.text(.full).contains("drawing"))
        // Nothing was given the next handle on the quiet.
        #expect(handles.element("E4") == nil)
    }

    /// With several things selected, "these" are all of them.
    @Test func everythingSelectedIsMarkedSelected() throws {
        let (app, screen) = VoiceFixture.login()
        let elements = try #require(app.store.screen(screen)?.elements)
        app.selection = .several([
            .element(.init(host: .screen(screen), element: elements[0].id)),
            .element(.init(host: .screen(screen), element: elements[2].id)),
        ])
        let picture = CanvasPicture.capture(from: app, handles: VoiceHandles())
        #expect(picture.screens.first?.elements.map(\.isSelected) == [true, false, true])
    }

    @Test func elementsAreListedFromTheTopWhateverOrderTheyWereMadeIn() throws {
        let (app, screen) = VoiceFixture.login()
        _ = app.store.setElements([
            DesignElement(kind: .body, frame: CGRect(x: 20, y: 10, width: 353, height: 20), text: "Above it all", tint: Theme.accent),
        ], on: screen, replacing: false)
        let text = CanvasPicture.capture(from: app, handles: VoiceHandles()).text(.full)
        let above = try #require(text.range(of: "Above it all"))
        let title = try #require(text.range(of: "Welcome back"))
        #expect(above.lowerBound < title.lowerBound)
        #expect(text.contains(#"E1 body "Above it all""#))
    }

    @Test func theCompactPictureSummarisesOtherScreens() throws {
        let (app, login) = VoiceFixture.login()
        let profile = app.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 4400, y: 4000), scale: 0.6))
        app.store.updateScreen(profile.id) { $0.name = "Profile" }
        _ = app.store.setElements([
            DesignElement(kind: .title, frame: CGRect(x: 20, y: 75, width: 353, height: 41), text: "Your profile", tint: Theme.accent),
            DesignElement(kind: .button, frame: CGRect(x: 20, y: 420, width: 353, height: 50), text: "Edit profile", tint: Theme.accent),
        ], on: profile.id, replacing: true)
        let title = try #require(app.store.screen(login)?.elements.first)
        app.selection = .element(.init(host: .screen(login), element: title.id))

        let picture = CanvasPicture.capture(from: app, handles: VoiceHandles())
        let compact = picture.text(.compact)
        #expect(compact.contains(#"E1 title "Welcome back""#))
        let summary = try #require(compact.split(separator: "\n").first { $0.hasPrefix(#"S2 "Profile""#) })
        #expect(summary.hasSuffix("2 elements"))
        #expect(!compact.contains("Edit profile"))
        // In full, nothing is left out.
        #expect(picture.text(.full).contains("Edit profile"))
    }

    /// The pencil points at an element on a screen that isn't the one mostly in view: that
    /// screen is the one told in full, or the model can't see what it was pointed at.
    @Test func theCompactPictureShowsThePointedAtScreenInFull() throws {
        var picture = CanvasPicture()
        picture.screens = [
            .init(handle: "S1", name: "Login", size: CGSize(width: 393, height: 852), visibleShare: 0.9, elements: [
                .init(handle: "E1", kind: "title", text: "Welcome back"),
            ]),
            .init(handle: "S2", name: "Trip", size: CGSize(width: 393, height: 852), visibleShare: 0.1, elements: [
                .init(handle: "E2", kind: "button", text: "Save itinerary", isSelected: true),
            ]),
        ]
        let compact = picture.text(.compact)
        #expect(compact.contains(#"E2 button "Save itinerary""#))
        #expect(!compact.contains("Welcome back"))
        #expect(picture.selectionInWords == #"E2, the button "Save itinerary" on S2"#)
    }

    @Test func aSelectedScreenIsToldByName() {
        var picture = CanvasPicture()
        picture.screens = [.init(handle: "S1", name: "Login", size: CGSize(width: 393, height: 852), isSelected: true)]
        #expect(picture.selectionInWords == #"S1, the screen "Login""#)
        picture.screens[0].isSelected = false
        #expect(picture.selectionInWords == nil)
    }

    @Test func anEmptyCanvasSaysSo() {
        let picture = CanvasPicture.capture(from: AppModel(document: LayerDocument()), handles: VoiceHandles())
        #expect(!picture.hasScreens)
        #expect(picture.text(.full) == "The canvas has no screens yet.")
        #expect(picture.text(.compact) == "The canvas has no screens yet.")
        #expect(CanvasPicture.empty.text(.full) == "The canvas has no screens yet.")
    }
}

@Suite("What a spoken command can do")
@MainActor
struct VoiceToolsTests {
    private struct Bench {
        let app: AppModel
        let screen: DesignScreen.ID
        let handles: VoiceHandles
        let box: VoiceToolbox

        @MainActor func element(_ handle: String) -> DesignElement? {
            guard let id = handles.element(handle) else { return nil }
            return app.store.screens.flatMap(\.elements).first { $0.id == id }
        }
    }

    /// The login design, known to a call: S1 with E1 the title, E2 the button, E3 the image.
    private func bench() -> Bench {
        let (app, screen) = VoiceFixture.undoableLogin()
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: app, handles: handles)
        return Bench(app: app, screen: screen, handles: handles, box: VoiceToolbox(model: app, handles: handles))
    }

    @Test func stylingAppliesLookWords() throws {
        let bench = bench()
        let line = bench.box.styleElement(element: "E2", look: "text blue, bold")
        let button = try #require(bench.element("E2"))
        #expect(button.textColor == ColourWords.parse("blue"))
        #expect(button.fontWeight == .bold)
        // The element it changed is the one selected, so "it" means that one next.
        #expect(bench.app.selection == .element(.init(host: .screen(bench.screen), element: button.id)))
        #expect(!line.isEmpty)
        #expect(bench.box.lines == [line])
        #expect(bench.box.failures.isEmpty)
    }

    /// A model can write "nan" where a number goes. A frame with that in it can't be laid out.
    @Test func aSizeThatIsNotANumberIsRefused() throws {
        let bench = bench()
        let before = bench.app.store.content
        #expect(bench.box.moveElement(element: "E3", x: "nan", y: nil, width: nil, height: nil).hasPrefix("I didn't understand the size"))
        #expect(bench.box.moveElement(element: "E3", x: nil, y: nil, width: "inf", height: nil).hasPrefix("I didn't understand the size"))
        #expect(bench.box.moveElement(element: "E3", x: nil, y: "infinity%", width: nil, height: nil).hasPrefix("I didn't understand the size"))
        #expect(bench.app.store.content == before)
    }

    @Test func resizingAcceptsAShareOfTheScreen() throws {
        let bench = bench()
        _ = bench.box.moveElement(element: "E2", x: nil, y: nil, width: "50%", height: nil)
        var button = try #require(bench.element("E2"))
        #expect(button.frame == CGRect(x: 20, y: 420, width: 197, height: 50))
        _ = bench.box.moveElement(element: "E2", x: "0", y: "25%", width: "180", height: "44pt")
        button = try #require(bench.element("E2"))
        #expect(button.frame == CGRect(x: 0, y: 213, width: 180, height: 44))
    }

    @Test func aSizeThatMakesNoSenseChangesNothing() throws {
        let bench = bench()
        let before = bench.app.store.content
        let line = bench.box.moveElement(element: "E2", x: nil, y: nil, width: "wide", height: nil)
        #expect(bench.app.store.content == before)
        #expect(bench.box.failures == [line])
    }

    @Test func aligningCentresOnTheScreen() throws {
        let bench = bench()
        _ = bench.box.alignElement(element: "E3", alignment: "centre")
        // The store keeps positions to whole points, as it does when aligning by hand:
        // a 200-point image on a 393-point screen sits at 97, half a point off true centre.
        #expect(try #require(bench.element("E3")).frame.minX == 97)
        _ = bench.box.alignElement(element: "E3", alignment: "Right")
        #expect(try #require(bench.element("E3")).frame.maxX == 393)
        // "Middle" and "centrally" are how people say centred, and mean side to side
        // as "centre" does. Top to bottom has to be asked for.
        _ = bench.box.alignElement(element: "E3", alignment: "middle")
        #expect(try #require(bench.element("E3")).frame == CGRect(x: 97, y: 500, width: 200, height: 200))
        _ = bench.box.alignElement(element: "E3", alignment: "left")
        _ = bench.box.alignElement(element: "E3", alignment: "centrally")
        #expect(try #require(bench.element("E3")).frame.minX == 97)
        _ = bench.box.alignElement(element: "E3", alignment: "vertical centre")
        #expect(try #require(bench.element("E3")).frame == CGRect(x: 97, y: 326, width: 200, height: 200))
        let before = bench.app.store.content
        let line = bench.box.alignElement(element: "E3", alignment: "sideways")
        #expect(bench.app.store.content == before)
        #expect(bench.box.failures == [line])
    }

    @Test func settingTextChangesTheWords() throws {
        let bench = bench()
        _ = bench.box.setText(element: "E2", text: "Board the ship")
        #expect(try #require(bench.element("E2")).text == "Board the ship")
    }

    /// Measured with the on-device model: asked to change an element's text colour, it
    /// hands the colour over as the element's new words. A colour, in lower case and on
    /// its own, is taken as the colour of the words.
    @Test func aColourGivenAsTheWordsColoursTheWords() throws {
        let bench = bench()
        _ = bench.box.setText(element: "E1", text: "blue")
        var title = try #require(bench.element("E1"))
        #expect(title.text == "Welcome back")
        #expect(title.textColor == ColourWords.parse("blue"))
        _ = bench.box.setText(element: "E1", text: "text white")
        title = try #require(bench.element("E1"))
        #expect(title.text == "Welcome back")
        #expect(title.textColor == ColourWords.parse("white"))
        #expect(bench.box.failures.isEmpty)

        // Written as a label would be, it is the label.
        _ = bench.box.setText(element: "E2", text: "Blue")
        #expect(try #require(bench.element("E2")).text == "Blue")
        _ = bench.box.setText(element: "E2", text: "blue skies ahead")
        #expect(try #require(bench.element("E2")).text == "blue skies ahead")
    }

    @Test func theTextColourHasAnArgumentOfItsOwn() {
        #expect(StyleElementTool.look("bold, 18pt", textColour: "blue") == "bold, 18pt, text blue")
        #expect(StyleElementTool.look(nil, textColour: "white") == "text white")
        #expect(StyleElementTool.look("green", textColour: nil) == "green")
        #expect(StyleElementTool.look(nil, textColour: " ") == "")
    }

    @Test func addingAnElementPutsItBelowTheRest() throws {
        let bench = bench()
        let line = bench.box.addElement(screen: nil, kind: "text field", text: "Email", look: "radius 12")
        let added = try #require(bench.app.store.screen(bench.screen)?.elements.last)
        #expect(added.kind == .textField)
        #expect(added.text == "Email")
        #expect(added.cornerRadius == 12)
        #expect(added.frame.minY > 700)
        // The model is told what to call it from now on.
        #expect(line.contains("E4"))
        #expect(bench.handles.element("E4") == added.id)

        let before = bench.app.store.content
        let unknown = bench.box.addElement(screen: "S1", kind: "hologram", text: nil, look: nil)
        #expect(bench.app.store.content == before)
        #expect(bench.box.failures == [unknown])
    }

    @Test func duplicatingAndDeleting() throws {
        let bench = bench()
        let line = bench.box.duplicateElement(element: "E2")
        #expect(bench.app.store.screen(bench.screen)?.elements.count == 4)
        #expect(line.contains("E4"))
        #expect(try #require(bench.element("E4")).text == "Sign in")
        _ = bench.box.deleteElement(element: "E4", named: "button")
        #expect(bench.app.store.screen(bench.screen)?.elements.count == 3)
        // What is gone can't be named again.
        #expect(bench.box.deleteElement(element: "E4", named: "button") == "There is no E4.")
    }

    @Test func renamingAndDeletingAScreen() {
        let bench = bench()
        _ = bench.box.renameScreen(screen: "S1", name: "Sign In")
        #expect(bench.app.store.screen(bench.screen)?.name == "Sign In")
        _ = bench.box.deleteScreen(screen: "S1", named: "sign in screen")
        #expect(bench.app.store.screens.isEmpty)
        #expect(bench.box.deleteScreen(screen: "S1", named: "sign in screen") == "There is no S1.")
    }

    // MARK: Panning

    /// "Move down a bit" has nothing to be shown: it is the view that moves.
    @Test func theViewPansByDirection() throws {
        let down = try #require(VoiceToolbox.pan(named: "down"))
        #expect(down.name == "down")
        #expect(down.shift == CGVector(dx: 0, dy: 0.6))
        #expect(VoiceToolbox.pan(named: "Up a bit")?.shift == CGVector(dx: 0, dy: -0.3))
        #expect(VoiceToolbox.pan(named: "pan left")?.shift == CGVector(dx: -0.6, dy: 0))
        #expect(VoiceToolbox.pan(named: "scroll right a little")?.shift == CGVector(dx: 0.3, dy: 0))
        // A handle, a word that isn't a direction, and a direction that is part of a name.
        #expect(VoiceToolbox.pan(named: "S2") == nil)
        #expect(VoiceToolbox.pan(named: "all") == nil)
        #expect(VoiceToolbox.pan(named: "the left button") == nil)
        // Down by 0.6 of what is in view puts the middle that much lower on the canvas.
        let view = CGRect(x: 100, y: 200, width: 400, height: 600)
        #expect(VoiceToolbox.centre(of: view, panned: down.shift) == CGPoint(x: 300, y: 860))
    }

    @Test func panningChangesNothingInTheDesign() {
        let bench = bench()
        let before = bench.app.store.content
        #expect(bench.box.pan(direction: "down") == "Moved the view down.")
        #expect(bench.box.pan(direction: "Up a bit") == "Moved the view up a little.")
        // A model that asks to be shown a direction is taken to mean the same.
        #expect(bench.box.show(target: "down") == "Moved the view down.")
        #expect(bench.box.show(target: "left a bit") == "Moved the view left a little.")
        #expect(bench.app.store.content == before)
        #expect(bench.box.failures.isEmpty)
    }

    @Test func panningNeedsAWayToGo() {
        let bench = bench()
        #expect(bench.box.pan(direction: "sideways") == "I can move the view up, down, left or right, not “sideways”.")
        #expect(bench.box.failures.count == 1)
    }

    // MARK: Stacking

    /// "Stack them into a column": one under another from the top one down, in the order
    /// they already stand, left edges together and 12 points apart.
    @Test func stackingPutsElementsOneUnderAnother() throws {
        let bench = bench()
        let before = bench.app.store.content
        let undo = try #require(bench.app.store.undoManager)

        let line = bench.box.stackElements(elements: "E3, E1, E2", direction: "column")

        #expect(try #require(bench.element("E1")).frame == CGRect(x: 20, y: 75, width: 353, height: 41))
        #expect(try #require(bench.element("E2")).frame == CGRect(x: 20, y: 128, width: 353, height: 50))
        #expect(try #require(bench.element("E3")).frame == CGRect(x: 20, y: 190, width: 200, height: 200))
        #expect(line == "Stacked 3 elements in a column.")
        #expect(bench.box.failures.isEmpty)
        // All of them are selected afterwards, so that "them" stays them.
        #expect(bench.app.selectedElements.count == 3)
        // And it is one thing to undo.
        undo.undo()
        #expect(bench.app.store.content == before)
        #expect(!undo.canUndo)
    }

    /// Things left on top of one another, as four new images lined up on one line were
    /// on an iPad, come apart in the order they were named.
    @Test func thingsOnTopOfOneAnotherAreStackedInTheOrderNamed() throws {
        let bench = bench()
        _ = bench.box.moveElement(element: "E1", x: nil, y: "300", width: nil, height: nil)
        _ = bench.box.moveElement(element: "E2", x: nil, y: "300", width: nil, height: nil)
        _ = bench.box.stackElements(elements: "E2 E1", direction: "column")
        #expect(try #require(bench.element("E2")).frame.minY == 300)
        #expect(try #require(bench.element("E1")).frame.minY == 362)
    }

    @Test func stackingInARowGoesAcrossWithTopsTogether() throws {
        let bench = bench()
        _ = bench.box.moveElement(element: "E2", x: nil, y: nil, width: "100", height: nil)
        _ = bench.box.moveElement(element: "E3", x: nil, y: nil, width: "100", height: "100")
        let line = bench.box.stackElements(elements: "E2, E3", direction: "row")
        #expect(try #require(bench.element("E2")).frame == CGRect(x: 20, y: 420, width: 100, height: 50))
        #expect(try #require(bench.element("E3")).frame == CGRect(x: 132, y: 420, width: 100, height: 100))
        #expect(line == "Stacked 2 elements in a row.")
    }

    @Test func stackingNeedsSeveralThingsItCanFind() {
        let bench = bench()
        let before = bench.app.store.content
        #expect(bench.box.stackElements(elements: "E1", direction: "column") == "Name two or more elements to stack.")
        #expect(bench.box.stackElements(elements: "E1, E99", direction: "column") == "There is no E99.")
        #expect(bench.box.stackElements(elements: "E1, E2", direction: "pile") == "I can stack in a column or a row, not “pile”.")
        #expect(bench.app.store.content == before)
    }

    // MARK: Devices

    /// On an iPad "an admin dashboard on the MacBook" and "a iPad screen" both made
    /// phone screens: a spoken screen always took the canvas's device.
    @Test func aDeviceIsKnownByWhatItIsCalled() {
        #expect(VoiceToolbox.device(named: "on the MacBook")?.id == "macbook-air")
        #expect(VoiceToolbox.device(named: "MacBook Pro")?.id == "macbook-pro-16")
        #expect(VoiceToolbox.device(named: "Create a iPad screen.")?.id == "ipad")
        #expect(VoiceToolbox.device(named: "iPad mini")?.id == "ipad-mini")
        #expect(VoiceToolbox.device(named: "for the iMac")?.id == "imac")
        #expect(VoiceToolbox.device(named: "an iPhone SE screen")?.id == "iphone-se")
        #expect(VoiceToolbox.device(named: "a phone")?.id == "iphone")
        #expect(VoiceToolbox.device(named: "a login screen") == nil)
        #expect(VoiceToolbox.device(named: "a machine learning dashboard") == nil)
    }

    // MARK: Placing one thing by another

    /// "Move this image below the title": the image goes under it, left edges together,
    /// 12 points apart. Above, left of and right of go the same way.
    @Test func placingPutsOneElementByAnother() throws {
        let bench = bench()
        let line = bench.box.placeElement(element: "E3", relation: "below", target: "E1")
        #expect(try #require(bench.element("E3")).frame == CGRect(x: 20, y: 128, width: 200, height: 200))
        #expect(line == "Put the image below the title “Welcome back”.")

        _ = bench.box.placeElement(element: "E3", relation: "above", target: "E2")
        #expect(try #require(bench.element("E3")).frame == CGRect(x: 20, y: 208, width: 200, height: 200))
        _ = bench.box.placeElement(element: "E3", relation: "right of", target: "E2")
        #expect(try #require(bench.element("E3")).frame.origin == CGPoint(x: 385, y: 420))
        _ = bench.box.placeElement(element: "E3", relation: "beside", target: "E2")
        #expect(try #require(bench.element("E3")).frame.origin == CGPoint(x: 385, y: 420))
        _ = bench.box.placeElement(element: "E3", relation: "left of", target: "E2")
        #expect(try #require(bench.element("E3")).frame.origin == CGPoint(x: -192, y: 420))
        #expect(bench.box.failures.isEmpty)
    }

    /// Asked for "the image to the top", the on-device model reached for this tool and
    /// named the screen. Next to a screen it is in is an edge of it.
    @Test func placingByAScreenIsAligningToItsEdge() throws {
        let bench = bench()
        #expect(bench.box.placeElement(element: "E3", relation: "above", target: "S1").hasPrefix("Aligned the image to the top"))
        #expect(bench.box.placeElement(element: "E3", relation: "left of", target: "S1").hasPrefix("Aligned the image to the left"))
        #expect(bench.box.failures.isEmpty)
    }

    /// "Move the image to the top" went to this tool, "above the title". Unless something
    /// was said of one thing by another, it is an edge of the screen that was meant.
    @Test func placingNeedsToHaveBeenAskedFor() throws {
        let bench = bench()
        bench.box.spokenCommand = "Move the image to the top"
        #expect(bench.box.placeElement(element: "E3", relation: "above", target: "E1").hasPrefix("Aligned the image to the top"))
        bench.box.spokenCommand = "Move this image below the title."
        #expect(bench.box.placeElement(element: "E3", relation: "below", target: "E1") == "Put the image below the title “Welcome back”.")
        #expect(VoiceToolbox.asksToPlace("put the image next to the button"))
        #expect(VoiceToolbox.asksToPlace("Put it to the left of the title"))
        #expect(!VoiceToolbox.asksToPlace("Put the avatar on the left"))
        #expect(!VoiceToolbox.asksToPlace("move it to the top"))
    }

    /// "Add an image below the title": on an iPad the model could only try to place an
    /// image that wasn't there yet. Adding takes where to put it.
    @Test func anElementIsAddedNextToAnother() throws {
        let bench = bench()
        bench.box.spokenCommand = "Can you add an image below the title?"
        let line = bench.box.addElement(screen: "S1", kind: "image", text: nil, look: nil, relation: "below", target: "E1")
        let added = try #require(bench.app.store.screen(bench.screen)?.elements.last)
        #expect(added.kind == .image)
        #expect(added.frame.minX == 20)
        #expect(added.frame.minY == 128)
        #expect(line.hasPrefix("Added an image as E4."))
        #expect(bench.box.lines.last == "Put the image below the title “Welcome back”.")
        #expect(bench.box.failures.isEmpty)
    }

    @Test func placingNeedsTwoThingsAndAWay() {
        let bench = bench()
        let before = bench.app.store.content
        #expect(bench.box.placeElement(element: "E3", relation: "below", target: "E3").hasPrefix("Name two different elements."))
        #expect(bench.box.placeElement(element: "E3", relation: "inside", target: "E1")
            == "I can put it above, below, left of or right of another, not “inside”.")
        #expect(bench.box.placeElement(element: "E3", relation: "below", target: "E99") == "There is no E99.")
        #expect(bench.app.store.content == before)
    }

    // MARK: Aligning several with one another

    /// "Align the image and the avatar": with two or more named, they line up with one
    /// another, not each with the screen.
    @Test func aligningSeveralLinesThemUpWithOneAnother() throws {
        let bench = bench()
        let line = bench.box.alignElement(element: "E1, E3", alignment: "centre")
        // Through the middle of the area they cover together, 20 to 373 across.
        // The store puts each on a whole point of its own, so within half a point.
        #expect(abs(try #require(bench.element("E3")).frame.midX - 196.5) <= 1)
        #expect(try #require(bench.element("E1")).frame.minX == 20)
        #expect(line == "Lined up 2 elements by their centres.")
        _ = bench.box.alignElement(element: "E2 E3", alignment: "top")
        #expect(try #require(bench.element("E3")).frame.minY == 420)
        #expect(bench.box.failures.isEmpty)
    }

    // MARK: Deleting only when asked to

    /// Three times the on-device model answered a command that said nothing of removing
    /// with a delete: "Can you edit the image to be a section?" deleted the image. A
    /// delete now goes ahead only if what was said asks for one.
    @Test func nothingIsDeletedUnlessRemovingWasAskedFor() throws {
        let bench = bench()
        bench.box.spokenCommand = "Can you edit the image to be a section?"
        #expect(bench.box.deleteElement(element: "E3", named: "image") == "That would have deleted something you didn't ask to remove, so nothing was changed.")
        #expect(bench.element("E3") != nil)
        #expect(bench.box.deleteScreen(screen: "S1", named: "login screen").hasPrefix("That would have deleted something"))
        #expect(bench.app.store.screens.count == 1)

        bench.box.spokenCommand = "get rid of the image"
        _ = bench.box.deleteElement(element: "E3", named: "image")
        #expect(bench.element("E3") == nil)
    }

    @Test func whatAsksForSomethingToBeRemoved() {
        for said in ["Delete the image", "remove it", "get rid of the button", "erase that", "take the title out",
                     "Clear the screen", "bin it", "lose the avatar", "Deleting the logo please", "scrap that screen"] {
            #expect(VoiceToolbox.asksToRemove(said), "\(said)")
        }
        for said in ["Can you edit the image to be a section?", "Make the checkbox blue", "make the dropdown bigger",
                     "move it down", "Take a look at the title"] {
            #expect(!VoiceToolbox.asksToRemove(said), "\(said)")
        }
    }

    // MARK: In the person's words

    /// Handles are between the app and the model. What reaches the pill has none.
    @Test func whatIsShownToThePersonHasNoHandles() throws {
        let bench = bench()
        let made = bench.box.duplicateElement(element: "E2")
        // The model is told the copy's handle, to go on with.
        #expect(made == "Duplicated the button “Sign in” as E4.")
        #expect(bench.box.lines.last == "Duplicated the button “Sign in”.")
        let added = bench.box.addElement(screen: "S1", kind: "image", text: nil, look: nil)
        #expect(added == "Added an image as E5.")
        #expect(bench.box.lines.last == "Added an image.")
    }

    /// With no name to give, the on-device model called new screens "S7" and "S8": the
    /// handles they were about to get. Those and "new" or "another" are no name at all,
    /// and the screen is then named from its description as before.
    @Test func aScreenIsNotNamedByAHandleOrByNothing() {
        #expect(VoiceToolbox.screenName("S7") == nil)
        #expect(VoiceToolbox.screenName(" s 8 ") == nil)
        #expect(VoiceToolbox.screenName("New screen") == nil)
        #expect(VoiceToolbox.screenName("another") == nil)
        #expect(VoiceToolbox.screenName("Screen") == nil)
        #expect(VoiceToolbox.screenName("") == nil)
        #expect(VoiceToolbox.screenName(nil) == nil)
        #expect(VoiceToolbox.screenName("Panda Showcase") == "Panda Showcase")
        #expect(VoiceToolbox.screenName("the Welcome screen") == "Welcome")
        #expect(VoiceToolbox.screenName("new arrivals") == "New arrivals")
    }

    /// The model puts a handle in quotes, or after the word "screen", as often as bare.
    /// On an iPad the pill read: New screen “the screen “S7”” created.
    @Test func aHandleInQuotesOrAfterItsKindReadsNaturally() {
        let bench = bench()
        #expect(bench.box.inWords("New screen “S1” created.") == "New screen “Login” created.")
        #expect(bench.box.inWords("New screen \"S1\" created.") == "New screen “Login” created.")
        #expect(bench.box.inWords("Screen S1 is now shown.") == "Screen “Login” is now shown.")
        #expect(bench.box.inWords("I changed “E2”.") == "I changed the button “Sign in”.")
    }

    /// Something loose on the canvas has no screen to be half of. Told "50%" wasn't
    /// understood, and to try "50%", the model made a sticky note 180 points wide.
    @Test func aShareOfTheScreenIsRefusedPlainlyForSomethingOnNoScreen() throws {
        let bench = bench()
        let note = DesignElement(kind: .stickyNote, frame: CGRect(x: 0, y: 0, width: 200, height: 120), text: "A note", tint: Theme.accent)
        bench.app.store.addFloating(note, scale: 1)
        let handle = bench.handles.handle(forElement: note.id)
        let line = bench.box.moveElement(element: handle, x: nil, y: nil, width: "50%", height: nil)
        #expect(line == "That isn't on a screen, so it can't be a share of one. Give its size in points, such as 180.")
        #expect(bench.app.store.floating.first?.element.frame.width == 200)
        // In points it is resized as anything else is.
        _ = bench.box.moveElement(element: handle, x: nil, y: nil, width: "150", height: nil)
        #expect(bench.app.store.floating.first?.element.frame.width == 150)
    }

    /// A model asked "Which element should I change—E24, E25, or E26?" on an iPad.
    @Test func whatAModelSaysIsPutInThePersonsWords() {
        let bench = bench()
        #expect(bench.box.inWords("Which element should I change—E1, E2, or E3?")
            == "Which element should I change—the title “Welcome back”, the button “Sign in”, or the image?")
        #expect(bench.box.inWords("S1 has three elements.") == "The screen “Login” has three elements.")
        // A handle for nothing is left as it came, and so are words that only look like one.
        #expect(bench.box.inWords("There is no E99.") == "There is no E99.")
        #expect(bench.box.inWords("Done.") == "Done.")
    }

    @Test func showingSelectsWhatIsShown() throws {
        let bench = bench()
        _ = bench.box.show(target: "S1")
        #expect(bench.app.selection == .screen(bench.screen))
        _ = bench.box.show(target: "e3")
        #expect(bench.app.selection == .element(.init(host: .screen(bench.screen), element: try #require(bench.element("E3")).id)))
        #expect(bench.box.show(target: "all") == "Showing everything.")
        #expect(bench.box.show(target: "S9") == "There is no S9.")
        // Showing changes nothing in the design.
        #expect(bench.app.store.undoManager?.canUndo == false)
    }

    @Test func zoomingTakesALevelOrADirection() {
        let bench = bench()
        #expect(bench.box.zoom(to: "150") == "Zoomed to 150%.")
        #expect(bench.box.zoom(to: "50%") == "Zoomed to 50%.")
        #expect(bench.box.zoom(to: "fit") == "Showing everything.")
        #expect(bench.box.failures.isEmpty)
        let line = bench.box.zoom(to: "sideways")
        #expect(bench.box.failures == [line])
    }

    @Test func hangingUpIsAskedOfTheCall() {
        let bench = bench()
        #expect(!bench.box.endsCall)
        _ = bench.box.endCall()
        #expect(bench.box.endsCall)
    }

    // MARK: Deleting only what was named

    /// A small model asked about something that isn't there will sometimes act on
    /// something else. A delete is the one that can't be allowed through: it goes ahead
    /// only when the person's own word for the thing fits the thing.
    @Test func deletingNeedsANameThatFits() throws {
        let bench = bench()
        let before = bench.app.store.content
        let refused = bench.box.deleteElement(element: "E2", named: "dropdown")
        #expect(refused == "There is no dropdown here. That is the button “Sign in”.")
        #expect(bench.box.deleteElement(element: "E2", named: "dropdown button").hasPrefix("There is no dropdown button here."))
        #expect(bench.box.deleteElement(element: "E3", named: "map").hasPrefix("There is no map here."))
        #expect(bench.app.store.content == before)
        #expect(bench.box.failures.count == 3)
        #expect(bench.box.lines.isEmpty)

        // Its kind, the words on it, another word for its kind, or "it" all fit.
        _ = bench.box.deleteElement(element: "E2", named: "the Sign In button")
        #expect(bench.element("E2") == nil)
        _ = bench.box.deleteElement(element: "E3", named: "picture")
        #expect(bench.element("E3") == nil)
        _ = bench.box.deleteElement(element: "E1", named: "it")
        #expect(bench.element("E1") == nil)
    }

    @Test func aModelThatGivesNoNameIsTakenAtItsWord() throws {
        let bench = bench()
        _ = bench.box.deleteElement(element: "E3", named: nil)
        #expect(bench.element("E3") == nil)
    }

    @Test func deletingAScreenNeedsANameThatFits() {
        let bench = bench()
        #expect(bench.box.deleteScreen(screen: "S1", named: "checkout screen") == "There is no checkout screen here. That screen is “Login”.")
        #expect(bench.app.store.screens.count == 1)
        // "This screen", "the first screen" and the like name it by where it is.
        #expect(VoiceNaming.fits("this screen", names: ["login"], words: "Login"))
        #expect(VoiceNaming.fits("the first page", names: ["login"], words: "Login"))
        _ = bench.box.deleteScreen(screen: "S1", named: "the login page")
        #expect(bench.app.store.screens.isEmpty)
    }

    @Test func aNameFitsByKindByWordsOrByBeingNoNameAtAll() {
        let button = ["button", "primary button", "cta"]
        #expect(VoiceNaming.fits("button", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("the sign in button", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("Sign-in", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("CTA", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("that one", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("text field", names: ["text field", "field", "input"], words: "Email"))
        // A word that is neither its kind nor on it doesn't, whatever else is said with it.
        #expect(!VoiceNaming.fits("dropdown", names: button, words: "Sign in"))
        #expect(!VoiceNaming.fits("dropdown button", names: button, words: "Sign in"))
        #expect(!VoiceNaming.fits("slider", names: ["image", "photo", "picture"], words: ""))
        #expect(!VoiceNaming.fits("title", names: button, words: "Sign in"))
    }

    /// What something is like, where it is and which one it is don't name it, so they
    /// can't make a right delete wrong.
    @Test func describingWordsAndNumbersDoNotStopARightDelete() {
        let button = ["button", "primary button", "cta"]
        #expect(VoiceNaming.fits("blue button", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("the big button", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("left button", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("button 2", names: button, words: "Sign in"))
        #expect(VoiceNaming.fits("screen two", names: [], words: "Settings"))
        #expect(VoiceNaming.fits("screen 2", names: [], words: "Settings"))
        #expect(VoiceNaming.fits("the fourth screen", names: [], words: "Settings"))
        // But they don't make a wrong one right.
        #expect(!VoiceNaming.fits("blue dropdown", names: button, words: "Sign in"))
        #expect(!VoiceNaming.fits("second map", names: ["image", "photo"], words: ""))
    }

    /// Speech recognition writes "login" or "log in" as it pleases.
    @Test func wordsRunTogetherOrApartAreTheSameName() {
        #expect(VoiceNaming.fits("login screen", names: [], words: "Log in"))
        #expect(VoiceNaming.fits("log in screen", names: [], words: "Login"))
        #expect(VoiceNaming.fits("signin button", names: ["button"], words: "Sign in"))
        #expect(!VoiceNaming.fits("logout screen", names: [], words: "Log in"))
    }

    @Test func aHandleGivenAsTheNameIsNoNameAtAll() throws {
        let bench = bench()
        _ = bench.box.deleteElement(element: "E3", named: "E3")
        #expect(bench.element("E3") == nil)
        _ = bench.box.deleteScreen(screen: "S1", named: "S1")
        #expect(bench.app.store.screens.isEmpty)
    }

    /// A field is a field whatever is typed in it: "password field" names the one that
    /// says Password, and no other.
    @Test func aFieldIsNotNamedByWhatAnotherFieldIsFor() throws {
        let bench = bench()
        _ = bench.box.addElement(screen: "S1", kind: "text field", text: "Email", look: nil)
        let field = try #require(bench.app.store.screen(bench.screen)?.elements.first { $0.kind == .textField })
        let handle = bench.handles.handle(forElement: field.id)
        #expect(bench.box.deleteElement(element: handle, named: "password field").hasPrefix("There is no password field here."))
        #expect(bench.element(handle) != nil)
        _ = bench.box.deleteElement(element: handle, named: "the email field")
        #expect(bench.element(handle) == nil)
    }

    // MARK: What can't be done

    @Test func anUnknownHandleChangesNothing() {
        let bench = bench()
        let before = bench.app.store.content
        #expect(bench.box.styleElement(element: "E99", look: "blue") == "There is no E99.")
        // Words in place of a handle are sent back with what a handle looks like.
        #expect(bench.box.moveElement(element: "the button", x: nil, y: nil, width: "50%", height: nil).contains("isn't a handle"))
        // A screen's handle isn't an element's.
        #expect(bench.box.setText(element: "S1", text: "Hello") == "There is no element S1.")
        #expect(bench.app.store.content == before)
        #expect(bench.box.failures.count == 3)
        #expect(bench.box.lines.isEmpty)
    }

    @Test func aLockedElementIsRefused() throws {
        let bench = bench()
        let button = try #require(bench.element("E2"))
        bench.app.store.update(.init(host: .screen(bench.screen), element: button.id)) { $0.isLocked = true }
        let before = bench.app.store.content
        for line in [
            bench.box.moveElement(element: "E2", x: nil, y: nil, width: "50%", height: nil),
            bench.box.alignElement(element: "E2", alignment: "left"),
            bench.box.deleteElement(element: "E2", named: "button"),
        ] {
            #expect(line.contains("locked"))
        }
        #expect(bench.app.store.content == before)
        #expect(bench.box.failures.count == 3)
    }

    @Test func editingAnEmptyCanvasSaysThereIsNothing() {
        let app = AppModel(document: LayerDocument())
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: app, handles: handles)
        let box = VoiceToolbox(model: app, handles: handles)
        #expect(box.setText(element: "E1", text: "Hello") == "There is no E1.")
        #expect(box.addElement(screen: nil, kind: "button", text: nil, look: nil) == "There is no screen to add to yet.")
        #expect(app.store.content.screens.isEmpty)
    }

    // MARK: After close, and where new screens go

    /// No screen is started on a design that has closed: its generation would run on with
    /// nothing to stop it, writing to a file the browser has let go of (B-I4).
    @Test func noScreenIsMadeOnceTheDesignHasClosed() async throws {
        let bench = bench()
        bench.app.close()
        let line = try await bench.box.createScreen(name: "Settings", description: "a settings screen")
        #expect(line == AppModel.closedProblem)
        #expect(bench.app.generation == nil && bench.app.store.screens.count == 1)
    }

    /// The command's own anchor puts its screen where the pencil pointed, and only its own:
    /// the next command's screen goes where screens always go (B-M4).
    @Test func aNewScreenGoesWhereItsCommandPointed() async throws {
        let bench = bench()
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        bench.app.screenStream = { _, _, _ in stream }
        let point = CGPoint(x: 9000, y: 9000)
        bench.box.newScreenAnchor = point
        let making = Task { try await bench.box.createScreen(name: "Settings", description: "a settings screen") }
        #expect(await eventually { bench.app.isGenerating })
        #expect(bench.app.store.screens.last?.origin == point)
        feed.finish()
        _ = try await making.value
        bench.box.reset()
        #expect(bench.box.newScreenAnchor == nil)
    }

    // MARK: Turning

    @Test func rotateElementTurnsToAnAngleOrByAnAmount() throws {
        let bench = bench()
        let line = bench.box.rotateElement(element: "E2", angle: "30", by: nil)
        #expect(try #require(bench.element("E2")).rotation == 30)
        #expect(line == "Turned E2 to 30°.")
        _ = bench.box.rotateElement(element: "E2", angle: nil, by: "-45")
        #expect(try #require(bench.element("E2")).rotation == 345)
        // Said with a unit, and the angle wins when both are given.
        _ = bench.box.rotateElement(element: "E2", angle: "45 degrees", by: "10")
        #expect(try #require(bench.element("E2")).rotation == 45)
        _ = bench.box.rotateElement(element: "E2", angle: "90°", by: nil)
        #expect(try #require(bench.element("E2")).rotation == 90)
        _ = bench.box.rotateElement(element: "E2", angle: "0", by: nil)
        #expect(try #require(bench.element("E2")).rotation == nil)
        #expect(bench.box.failures.isEmpty)
    }

    @Test func rotateElementRefusesALockedElementAndNonsense() throws {
        let bench = bench()
        bench.app.store.update(.init(host: .screen(bench.screen), element: try #require(bench.element("E2")).id)) { $0.isLocked = true }
        let before = bench.app.store.content
        #expect(bench.box.rotateElement(element: "E2", angle: "30", by: nil) == "E2 is locked.")
        #expect(bench.box.rotateElement(element: "E1", angle: nil, by: nil) == "Say an angle, such as 45, or how far to turn it, such as 15.")
        #expect(bench.box.rotateElement(element: "E1", angle: "sideways", by: nil) == "I didn't understand the angle “sideways”.")
        #expect(bench.box.rotateElement(element: "E1", angle: "nan", by: nil) == "I didn't understand the angle “nan”.")
        #expect(bench.box.rotateElement(element: "E1", angle: nil, by: "inf") == "I didn't understand the angle “inf”.")
        #expect(bench.app.store.content == before)
        #expect(bench.box.failures.count == 5)
    }

    @Test func aSpokenTurnIsOneUndoStep() throws {
        let bench = bench()
        let before = bench.app.store.content
        let undo = try #require(bench.app.store.undoManager)
        bench.app.store.beginHeldEdit()
        _ = bench.box.rotateElement(element: "E2", angle: "30", by: nil)
        _ = bench.box.rotateElement(element: "E2", angle: nil, by: "15")
        bench.app.store.endHeldEdit()
        #expect(try #require(bench.element("E2")).rotation == 45)
        undo.undo()
        #expect(bench.app.store.content == before)
        #expect(!undo.canUndo)
    }

    @Test func theCanvasDescriptionSaysAnAngleOnlyWhenTurned() throws {
        let bench = bench()
        _ = bench.box.rotateElement(element: "E2", angle: "30", by: nil)
        let text = CanvasPicture.capture(from: bench.app, handles: bench.handles).text(.full)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.contains(#"E2 button "Sign in""#) && $0.contains("w353 h50 turned 30°") })
        #expect(!lines.filter { $0.hasPrefix("E1") || $0.hasPrefix("E3") || $0.contains("E1 ") }.contains { $0.contains("turned") })
        #expect(lines.filter { $0.contains("turned") }.count == 1)
    }

    // MARK: Undo

    @Test func aHeldEditIsOneUndoStep() throws {
        let bench = bench()
        let before = bench.app.store.content
        let undo = try #require(bench.app.store.undoManager)
        bench.app.store.beginHeldEdit()
        _ = bench.box.styleElement(element: "E2", look: "green")
        let mark = bench.app.store.historyMark
        _ = bench.box.setText(element: "E2", text: "Continue")
        _ = bench.box.alignElement(element: "E3", alignment: "centre")
        // Nothing is a step of its own while the command is still under way: it is one
        // step from its first change, which undo would take back whole.
        #expect(bench.app.store.historyMark == mark)
        bench.app.store.endHeldEdit()
        #expect(bench.app.store.content != before)
        undo.undo()
        #expect(bench.app.store.content == before)
        #expect(!undo.canUndo)
    }

    @Test func aHeldEditThatChangesNothingLeavesNoUndoStep() throws {
        let bench = bench()
        bench.app.store.beginHeldEdit()
        _ = bench.box.show(target: "S1")
        bench.app.store.endHeldEdit()
        #expect(try #require(bench.app.store.undoManager).canUndo == false)
    }

    /// A finger can be dragging something while a command runs. The drag is a step of its
    /// own, which the command ending doesn't cut short: it isn't left to make a step of
    /// every move. The command's is its own, and is taken back first, as it was the last
    /// thing done and touched nothing the drag did (V1).
    @Test func aDragBegunDuringACommandIsOneStepWhenTheCommandEndsFirst() throws {
        let bench = bench()
        let store = bench.app.store
        let undo = try #require(store.undoManager)
        let before = store.content
        let image = DesignStore.ElementRef(host: .screen(bench.screen), element: try #require(bench.element("E3")).id)
        store.beginHeldEdit()
        _ = bench.box.styleElement(element: "E2", look: "green")
        store.beginEdit()
        store.update(image) { $0.frame.origin.x = 40 }
        store.endHeldEdit()
        let mark = store.historyMark
        store.update(image) { $0.frame.origin.x = 60 }
        store.update(image) { $0.frame.origin.x = 80 }
        // No move is a step of its own while the finger is still down.
        #expect(store.historyMark == mark)
        store.endEdit()
        undo.undo()
        #expect(try #require(bench.element("E2")).tint == Theme.accent)
        #expect(try #require(bench.element("E3")).frame.origin.x == 80)
        undo.undo()
        #expect(store.content == before)
        #expect(!undo.canUndo)
    }

    /// A drag begun before a command and ended after it is one step, and the command its own.
    @Test func aDragBegunBeforeACommandAndEndedAfterItIsOneStep() throws {
        let bench = bench()
        let store = bench.app.store
        let undo = try #require(store.undoManager)
        let before = store.content
        let image = DesignStore.ElementRef(host: .screen(bench.screen), element: try #require(bench.element("E3")).id)
        store.beginEdit()
        store.update(image) { $0.frame.origin.x = 40 }
        store.beginHeldEdit()
        _ = bench.box.styleElement(element: "E2", look: "green")
        store.endHeldEdit()
        let mark = store.historyMark
        store.update(image) { $0.frame.origin.x = 60 }
        #expect(store.historyMark == mark)
        store.endEdit()
        undo.undo()
        #expect(try #require(bench.element("E2")).tint == Theme.accent)
        #expect(try #require(bench.element("E3")).frame.origin.x == 60)
        undo.undo()
        #expect(store.content == before)
        #expect(!undo.canUndo)
    }

    /// A slider moved and let go while a command runs is a step of its own, and the
    /// command's step is closed when the command ends: a change made next is a step of its own.
    /// The slider goes through the format panel, as a slider does: a run of changes the
    /// panel's pause ends.
    @Test func aSliderMovedAndLetGoDuringACommandLeavesTheStepToTheCommand() async throws {
        let bench = bench()
        let store = bench.app.store
        let undo = try #require(store.undoManager)
        let before = store.content
        let image = DesignStore.ElementRef(host: .screen(bench.screen), element: try #require(bench.element("E3")).id)
        bench.app.adjustmentPause = .milliseconds(20)
        store.beginHeldEdit()
        for width in [180, 160, 140] {
            bench.app.adjusting { store.update(image) { $0.frame.size.width = CGFloat(width) } }
        }
        #expect(await eventually { !store.isEditing }, "the panel's pause ends the slider's step")
        _ = bench.box.styleElement(element: "E2", look: "green")
        store.endHeldEdit()
        #expect(!store.isEditing && !store.isHoldingEdit)
        store.update(image) { $0.frame.origin.y = 520 }
        undo.undo()
        #expect(try #require(bench.element("E3")).frame.origin.y == 500)
        #expect(try #require(bench.element("E3")).frame.size.width == 140)
        undo.undo()
        #expect(try #require(bench.element("E2")).tint == Theme.accent)
        #expect(try #require(bench.element("E3")).frame.size.width == 140)
        undo.undo()
        #expect(store.content == before)
        #expect(!undo.canUndo)
    }

    /// A drag that is over before the command is: a step of its own, and the command another.
    /// The drag used to join the command's step, which a spoken correction then took back
    /// with the command (V1).
    @Test func aDragThatEndsDuringACommandLeavesTheStepToTheCommand() throws {
        let bench = bench()
        let store = bench.app.store
        let undo = try #require(store.undoManager)
        let before = store.content
        let image = DesignStore.ElementRef(host: .screen(bench.screen), element: try #require(bench.element("E3")).id)
        store.beginHeldEdit()
        store.beginEdit()
        store.update(image) { $0.frame.origin.x = 40 }
        store.endEdit()
        _ = bench.box.styleElement(element: "E2", look: "green")
        store.endHeldEdit()
        undo.undo()
        #expect(try #require(bench.element("E2")).tint == Theme.accent)
        #expect(try #require(bench.element("E3")).frame.origin.x == 40)
        undo.undo()
        #expect(store.content == before)
        #expect(!undo.canUndo)
    }

    /// The model's undo takes back what a command did, never what was done by hand: a
    /// model asked to correct a command undid the person's own move instead (review I-2).
    @Test func undoByVoiceNeverTakesBackAChangeByHand() throws {
        let bench = bench()
        let store = bench.app.store
        let image = DesignStore.ElementRef(host: .screen(bench.screen), element: try #require(bench.element("E3")).id)
        store.beginHeldEdit()
        _ = bench.box.styleElement(element: "E2", look: "green")
        store.endHeldEdit()
        store.update(image) { $0.frame.origin.x = 40 }
        store.beginHeldEdit()
        let said = bench.box.undo()
        store.endHeldEdit()
        #expect(said != "Undid the last change.")
        #expect(bench.box.lastFailed)
        #expect(try #require(bench.element("E3")).frame.origin.x == 40)
        #expect(try #require(bench.element("E2")).tint == ColourWords.parse("green"))
    }

    @Test func undoInsideACommandUndoesTheLastCommand() throws {
        let bench = bench()
        let undo = try #require(bench.app.store.undoManager)
        // One command rewords the button.
        bench.app.store.beginHeldEdit()
        _ = bench.box.setText(element: "E2", text: "Continue")
        bench.app.store.endHeldEdit()
        // The next says "undo that, and make it green".
        bench.app.store.beginHeldEdit()
        #expect(bench.box.undo() == "Undid the last change.")
        #expect(try #require(bench.element("E2")).text == "Sign in")
        _ = bench.box.styleElement(element: "E2", look: "green")
        bench.app.store.endHeldEdit()
        #expect(try #require(bench.element("E2")).tint == ColourWords.parse("green"))
        // Which leaves one step to undo: the green.
        undo.undo()
        #expect(try #require(bench.element("E2")).tint == Theme.accent)
        #expect(try #require(bench.element("E2")).text == "Sign in")

        #expect(bench.box.redo() == "Redid the last change.")
        #expect(try #require(bench.element("E2")).tint == ColourWords.parse("green"))
    }

    @Test func undoWithNothingToUndoSaysSo() {
        let bench = bench()
        #expect(bench.box.undo() == "There is nothing to undo.")
        #expect(bench.box.redo() == "There is nothing to redo.")
    }
}
