import CoreGraphics
import Foundation
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
        #expect(refused == "There is no dropdown here. E2 is the button “Sign in”.")
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
        #expect(bench.box.deleteScreen(screen: "S1", named: "checkout screen") == "There is no checkout screen here. S1 is “Login”.")
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

    // MARK: Undo

    @Test func aHeldEditIsOneUndoStep() throws {
        let bench = bench()
        let before = bench.app.store.content
        let undo = try #require(bench.app.store.undoManager)
        bench.app.store.beginHeldEdit()
        _ = bench.box.styleElement(element: "E2", look: "green")
        _ = bench.box.setText(element: "E2", text: "Continue")
        _ = bench.box.alignElement(element: "E3", alignment: "centre")
        // Nothing can be undone piecemeal while the command is still under way.
        #expect(!undo.canUndo)
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
