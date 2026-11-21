import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Layer

// What Siri and Shortcuts rely on: reading a written screen, laying it out, finding
// designs and elements again by identifier, and undoing what an action changed.

@Suite("Screen blueprints")
struct ScreenBlueprintTests {
    @Test func readsOneElementPerLine() throws {
        let blueprint = try #require(ScreenBlueprint.parse("""
        title: Welcome back
        text field: Email
        text field: Password
        button: Sign in
        """))
        let items = blueprint.sections.flatMap(\.items)
        #expect(items.map(\.kind) == [.title, .textField, .textField, .button])
        #expect(items.map(\.text) == ["Welcome back", "Email", "Password", "Sign in"])
    }

    @Test func readsRowsSectionsAndLooks() throws {
        let blueprint = try #require(ScreenBlueprint.parse("""
        heading: Settings

        row: button: Cancel | button: Done [blue, bold, radius 12]
        ---
        body: Tap a row to change it [text #333333, 15pt]
        """))
        #expect(blueprint.sections.count == 3)
        #expect(blueprint.sections[1].axis == .horizontal)
        let done = blueprint.sections[1].items[1]
        #expect(done.text == "Done")
        #expect(done.colour == ColourWords.named["blue"])
        #expect(done.weight == .bold)
        #expect(done.cornerRadius == 12)
        let body = blueprint.sections[2].items[0]
        #expect(body.textColour == RGBColor(hex: 0x333333))
        #expect(body.fontSize == 15)
    }

    @Test func understandsSynonymsSymbolsAndBareKinds() throws {
        let blueprint = try #require(ScreenBlueprint.parse("icon: heart.fill; switch; separator; Just some words"))
        let items = blueprint.sections.flatMap(\.items)
        #expect(items.map(\.kind) == [.symbol, .toggle, .divider, .text])
        #expect(items[0].symbol == "heart.fill")
        #expect(items[3].text == "Just some words")
    }

    @Test func nothingToLayOutIsNil() {
        #expect(ScreenBlueprint.parse("   \n---\n") == nil)
    }

    @Test func laysOutTopToBottomInsideTheSafeArea() throws {
        let device = DeviceFrame.iPhone
        let blueprint = try #require(ScreenBlueprint.parse("title: Hi\ntext field: Email\nbutton: Go"))
        let elements = blueprint.layout(on: device)
        #expect(elements.count == 3)
        #expect(elements[0].frame.minY >= device.safeTop)
        for (upper, lower) in zip(elements, elements.dropFirst()) {
            #expect(lower.frame.minY >= upper.frame.maxY, "\(lower.kind) overlaps \(upper.kind)")
        }
        // Fields and buttons run between the 20-point margins.
        #expect(elements[2].frame.minX == 20)
        #expect(elements[2].frame.width == device.size.width - 40)
    }

    @Test func aRowSharesItsWidth() throws {
        let device = DeviceFrame.iPhone
        let blueprint = try #require(ScreenBlueprint.parse("row: button: A | button: B"))
        let elements = blueprint.layout(on: device)
        #expect(elements.count == 2)
        #expect(elements[0].frame.minY == elements[1].frame.minY)
        #expect(elements[0].frame.maxX < elements[1].frame.minX)
        #expect(elements[1].frame.maxX <= device.size.width - 20)
    }
}

@Suite("Entity identifiers")
struct EntityKeyTests {
    @Test func screensRoundTrip() throws {
        let screen = UUID()
        let id = EntityKey.screen(design: "icloud:Folder/Travel.layer", screen: screen)
        let parsed = try #require(EntityKey.parseScreen(id))
        #expect(parsed.design == "icloud:Folder/Travel.layer")
        #expect(parsed.screen == screen)
    }

    @Test func elementsRoundTripOnScreensAndTheCanvas() throws {
        let screen = UUID(), element = UUID()
        let onScreen = try #require(EntityKey.parseElement(EntityKey.element(design: "local:A.layer", host: .screen(screen), element: element)))
        #expect(onScreen.design == "local:A.layer")
        #expect(onScreen.ref == DesignStore.ElementRef(host: .screen(screen), element: element))

        let loose = try #require(EntityKey.parseElement(EntityKey.element(design: "local:A.layer", host: .canvas, element: element)))
        #expect(loose.ref.host == .canvas)
    }

    @Test func designPathsInsideTheLibraryAreRelative() throws {
        let local = DesignLibrary.roots.local
        let url = local.appendingPathComponent("Sub/My Design.layer")
        let id = DesignLibrary.id(for: url)
        #expect(id == "local:Sub/My Design.layer")
        #expect(DesignLibrary.url(for: id)?.standardizedFileURL.path == url.standardizedFileURL.path)
    }
}

@Suite("Colours")
struct ColourTests {
    @Test func namesAndHexCodes() throws {
        #expect(ColourWords.parse("Blue") == ColourWords.named["blue"])
        #expect(ColourWords.parse("#0A84FF") == RGBColor(hex: 0x0A84FF))
        #expect(ColourWords.parse("0a84ff") == RGBColor(hex: 0x0A84FF))
        #expect(ColourWords.parse("not a colour") == nil)
        #expect(try ColourOption.resolve(nil, hex: "#FFFFFF") == RGBColor(hex: 0xFFFFFF))
        #expect(throws: LayerIntentError.self) { try ColourOption.resolve(nil, hex: "#12") }
    }
}

@Suite("Designs on disk")
struct DesignLibraryTests {
    @Test func readsAPackageWithoutItsInk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var file = DesignFile()
        file.content.title = "Travel"
        file.content.screens = [DesignScreen(name: "Login", origin: .zero, scale: 1, elements: [
            DesignStore.newElement(.title),
        ])]
        let url = folder.appendingPathComponent("Travel.layer")
        try file.wrapper().write(to: url, options: .atomic, originalContentsURL: nil)

        let summary = DesignLibrary.read(url)
        #expect(summary.title == "Travel")
        #expect(summary.content.screens.map(\.name) == ["Login"])
        #expect(summary.content.screens[0].elements.count == 1)
    }

    /// A folder with one design in it, named "Trip" on disk and "Travel" inside.
    private func savedDesign() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file = DesignFile()
        file.content.title = "Travel"
        file.content.screens = [DesignScreen(name: "Login", origin: .zero, scale: 1)]
        let url = folder.appendingPathComponent("Trip.layer")
        try file.wrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }

    @Test func aDesignICloudHasNotDownloadedIsListedByItsNameWithoutBeingRead() throws {
        let url = try savedDesign()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Reading it would download it, and wait for that.
        let listed = DesignLibrary.listed(url, isDownloaded: { _ in false })
        #expect(listed.title == "Trip")
        #expect(listed.content.screens.isEmpty)
        #expect(listed.id == DesignLibrary.id(for: url))

        let downloaded = DesignLibrary.listed(url, isDownloaded: { _ in true })
        #expect(downloaded.title == "Travel")
        #expect(downloaded.content.screens.map(\.name) == ["Login"])
        // A design asked for by name is read whatever it takes.
        #expect(DesignLibrary.read(url).title == "Travel")
    }

    @Test func aDesignUnchangedSinceItWasListedIsNotReadAgain() throws {
        let url = try savedDesign()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(DesignLibrary.listed(url, isDownloaded: { _ in true }).title == "Travel")

        // The design inside changes, but its dates are put back as they were.
        let design = url.appendingPathComponent(DesignPackage.design)
        let dates = try [url, design].map { try #require(try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) }
        var renamed = try DesignFile(wrapper: FileWrapper(url: url))
        renamed.content.title = "Holiday"
        try renamed.wrapper().fileWrappers?[DesignPackage.design]?.regularFileContents?.write(to: design)
        for (item, date) in zip([url, design], dates) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
        }
        #expect(DesignLibrary.listed(url, isDownloaded: { _ in true }).title == "Travel")

        // Changed in the usual way, it is read again.
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: design.path)
        #expect(DesignLibrary.listed(url, isDownloaded: { _ in true }).title == "Holiday")
    }
}

@Suite("Actions on an open design")
@MainActor
struct DesignActionTests {
    private func model() -> AppModel {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        return model
    }

    @Test func anEditIsOneUndoStep() throws {
        let model = model()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let blueprint = try #require(ScreenBlueprint.parse("title: A\nbody: B\nbutton: C"))
        DesignActions.edit(model, undoManager: nil, actionName: "Build Screen") {
            model.store.setElements(blueprint.layout(on: screen.device), on: screen.id, replacing: true)
            model.store.updateScreen(screen.id) { $0.name = "Login" }
        }
        #expect(model.store.screen(screen.id)?.elements.count == 3)
        #expect(model.store.screen(screen.id)?.name == "Login")
        model.store.undoManager?.undo()
        #expect(model.store.screen(screen.id)?.elements.isEmpty == true)
        #expect(model.store.screen(screen.id)?.name == screen.name)
    }

    @Test func theActionsOwnUndoPutsTheDesignBack() throws {
        let model = model()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let before = model.store.content
        let siriUndo = UndoManager()
        siriUndo.groupsByEvent = false
        DesignActions.edit(model, undoManager: siriUndo, actionName: "Add Title") {
            var title = DesignStore.newElement(.title)
            title.frame = DesignActions.frameForNewElement(title, on: screen)
            model.store.setElements([title], on: screen.id, replacing: false)
        }
        #expect(model.store.content != before)
        #expect(siriUndo.canUndo)
        siriUndo.undo()
        #expect(model.store.content == before)
    }

    @Test func siriUndoTakesBackOnlyItsOwnAction() {
        let model = model()
        let siri = UndoManager()
        siri.groupsByEvent = false
        DesignActions.edit(model, undoManager: siri, actionName: "Rename Design") { model.store.setTitle("A") }
        // Then a screen is added by hand.
        model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        siri.undo()
        #expect(model.store.title == nil)
        #expect(model.store.screens.count == 1)
        // Taking it back is a step of the design's own, which its Undo can take back in turn.
        model.store.undoManager?.undo()
        #expect(model.store.title == "A")
        #expect(model.store.screens.count == 1)
    }

    @Test func siriUndoLeavesWhatWasChangedSinceAndBringsBackWhatItTookAway() throws {
        let model = model()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let other = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 500, y: 0), scale: 1))
        let title = DesignStore.newElement(.title), button = DesignStore.newElement(.button), note = DesignStore.newElement(.body)
        model.store.setElements([title, button, note], on: screen.id, replacing: false)
        let siri = UndoManager()
        siri.groupsByEvent = false
        let red = RGBColor(hex: 0xFF0000)

        // One action recolours the title and the button, deletes the note, adds a symbol
        // and moves the second screen.
        DesignActions.edit(model, undoManager: siri, actionName: "Restyle") {
            model.store.update(.init(host: .screen(screen.id), element: title.id)) { $0.tint = red }
            model.store.update(.init(host: .screen(screen.id), element: button.id)) { $0.tint = red }
            model.store.delete(.init(host: .screen(screen.id), element: note.id))
            model.store.setElements([DesignStore.newElement(.symbol)], on: screen.id, replacing: false)
            model.store.updateScreen(other.id) { $0.origin.x = 900 }
        }
        // By hand since: the button is given words of its own, and a screen is added.
        model.store.update(.init(host: .screen(screen.id), element: button.id)) { $0.text = "Go" }
        let third = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 1400, y: 0), scale: 1))

        siri.undo()
        let elements = try #require(model.store.screen(screen.id)?.elements)
        #expect(elements.map(\.id) == [title.id, button.id, note.id], "the note is back where it was, the symbol gone")
        #expect(elements[0].tint == title.tint, "the title is as it was")
        #expect(elements[1].tint == red && elements[1].text == "Go", "the button, changed since, is left as it is")
        #expect(model.store.screen(other.id)?.origin.x == 500)
        #expect(model.store.screen(third.id) != nil)
    }

    @Test func siriIsNotOfferedAnUndoOnceTheDesignHasClosed() throws {
        let model = model()
        let siri = UndoManager()
        siri.groupsByEvent = false
        DesignActions.edit(model, undoManager: siri, actionName: "Add Screen") {
            model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        }
        #expect(siri.canUndo)
        model.close()
        // Nothing for Siri to undo, rather than an undo that does nothing and says it did.
        #expect(!siri.canUndo)
        let reopened = AppModel(document: LayerDocument(file: model.document.current))
        if siri.canUndo { siri.undo() }
        #expect(reopened.store.screens.count == 1)
        reopened.close()
    }

    @Test func anUndoWithNothingLeftToTakeBackChangesNothingAndSaysSo() throws {
        let model = model()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let button = DesignStore.newElement(.button)
        model.store.setElements([button], on: screen.id, replacing: false)
        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: button.id)
        let siri = UndoManager()
        siri.groupsByEvent = false

        DesignActions.edit(model, undoManager: siri, actionName: "Style Button") {
            model.store.update(ref) { $0.tint = RGBColor(hex: 0xFF0000) }
        }
        // The button is recoloured again by hand: what Siri changed is gone.
        model.store.update(ref) { $0.tint = RGBColor(hex: 0x00FF00) }
        let now = model.store.content
        siri.undo()
        #expect(model.store.content == now)
        #expect(model.undoNotice?.contains("Style Button") == true)

        // Checked before Siri can be asked, as the app stops being active, such an undo
        // is taken out of Siri's history instead.
        model.undoNotice = nil
        DesignActions.edit(model, undoManager: siri, actionName: "Style Button") {
            model.store.update(ref) { $0.tint = RGBColor(hex: 0x0000FF) }
        }
        model.withdrawTakenActionsWithNothingLeft()
        #expect(siri.canUndo, "the button is still as Siri left it")
        model.store.update(ref) { $0.tint = RGBColor(hex: 0x00FF00) }
        model.withdrawTakenActionsWithNothingLeft()
        #expect(!siri.canUndo)
    }

    @Test func newElementsGoBelowWhatIsThere() {
        let model = model()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        var title = DesignStore.newElement(.title)
        title.frame = DesignActions.frameForNewElement(title, on: screen)
        model.store.setElements([title], on: screen.id, replacing: false)
        let updated = model.store.screen(screen.id)!
        let button = DesignStore.newElement(.button)
        let frame = DesignActions.frameForNewElement(button, on: updated)
        #expect(frame.minY >= title.frame.maxY)
        #expect(frame.maxY <= updated.size.height - updated.device.safeBottom)
    }

    @Test func entitiesDescribeTheDesign() {
        let content = {
            var content = DesignContent()
            content.title = "Shop"
            var button = DesignStore.newElement(.button)
            button.text = "Buy now"
            content.screens = [DesignScreen(name: "Checkout", origin: .zero, scale: 1, elements: [button])]
            return content
        }()
        let snapshot = DesignSnapshot(id: "local:Shop.layer", name: "Shop", content: content, modified: nil)
        #expect(snapshot.entity.screenNames == ["Checkout"])
        #expect(snapshot.screens.first?.summary == "button “Buy now”")
        let element = snapshot.elements.first
        #expect(element?.text == "Buy now")
        #expect(element?.screenName == "Checkout")
        #expect(element.flatMap { EntityKey.parseElement($0.id)?.design } == "local:Shop.layer")
        #expect(DesignDescriber.describe(snapshot).contains("Checkout (iPhone): button “Buy now”"))
    }
}

@Suite("Image Playground")
@MainActor
struct ImagePlaygroundTests {
    private func modelWithScreen() -> (AppModel, DesignScreen) {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.store.setTitle("Wander")
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let blueprint = ScreenBlueprint.parse("title: Plan your trip\nbody: Beaches, cities and mountains\nbutton: Get started\ntext field")!
        model.store.setElements(blueprint.layout(on: screen.device), on: screen.id, replacing: true)
        model.store.updateScreen(screen.id) { $0.name = "Welcome" }
        return (model, model.store.screen(screen.id)!)
    }

    /// A small square picture, as Image Playground hands one back.
    private func picture(width: Int = 64, height: Int = 32) throws -> ImageImport.Prepared {
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let data = try #require(image.pngData())
        return try #require(ImageImport.prepare(data))
    }

    @Test func conceptsTakeThePromptAndTheScreensOwnWords() {
        let (model, screen) = modelWithScreen()
        let request = ImagePlaygroundRequest(target: .newImage(onScreen: screen.id), prompt: "  a lighthouse  ")
        let concepts = model.imageConcepts(for: request)
        #expect(concepts.prompt == "a lighthouse")
        // Placeholder words, such as an untouched text field's, are left out.
        #expect(concepts.context == "Plan your trip. Beaches, cities and mountains. Get started")
        #expect(concepts.title == "Wander – Welcome")
    }

    @Test func aNewImageGoesBelowWhatIsOnTheScreenAndIsSelected() throws {
        let (model, screen) = modelWithScreen()
        let request = ImagePlaygroundRequest(target: .newImage(onScreen: screen.id))
        model.imagePlaygroundRequest = request
        let ref = try #require(model.placeGeneratedImage(try picture(), for: request))
        let placed = try #require(model.store.resolve(ref)?.element)
        #expect(placed.kind == .image)
        #expect(placed.imageID != nil)
        #expect(model.document.current.images[placed.imageID!.uuidString] != nil)
        // Its shape follows the picture's, 2:1 here.
        #expect(placed.frame.width == screen.size.width - 40)
        #expect(placed.frame.height == (placed.frame.width / 2).rounded())
        let lowestBefore = screen.elements.map(\.frame.maxY).max() ?? 0
        #expect(placed.frame.minY >= lowestBefore)
        #expect(model.selection == .element(ref))
        #expect(model.imagePlaygroundRequest == nil)
    }

    @Test func aNewPictureForAnImageKeepsItsPlaceAndUndoes() throws {
        let (model, screen) = modelWithScreen()
        var image = DesignStore.newElement(.image)
        image.frame = CGRect(x: 30, y: 400, width: 200, height: 120)
        let ref = model.store.setElements([image], on: screen.id, replacing: false)[0]

        let request = ImagePlaygroundRequest(target: .replace(ref), prompt: "mountains")
        #expect(model.imageSize(for: request) == CGSize(width: 200, height: 120))
        try #require(model.placeGeneratedImage(try picture(), for: request) == ref)
        let replaced = try #require(model.store.resolve(ref)?.element)
        #expect(replaced.imageID != nil)
        #expect(replaced.frame == image.frame)

        model.store.undoManager?.undo()
        #expect(model.store.resolve(ref)?.element.imageID == nil)
    }
}

@Suite("Stroke scripts")
struct StrokeScriptTests {
    private func observation(_ paths: [[CGPoint]]) -> SketchObservation? {
        SketchAnalyzer.observe(paths.enumerated().map { SketchStroke(key: Double($0.offset), points: $0.element) })
    }

    @Test func readsFreehandPointsAndFillsThemIn() throws {
        let strokes = try StrokeScript.parse("20,40 120,40 120,90")
        #expect(strokes.count == 1)
        let stroke = strokes[0]
        #expect(stroke.first == CGPoint(x: 20, y: 40))
        #expect(stroke.last == CGPoint(x: 120, y: 90))
        // Filled in no more than three points apart, so PencilKit doesn't round the corner off.
        for (a, b) in zip(stroke, stroke.dropFirst()) {
            #expect(hypot(b.x - a.x, b.y - a.y) <= 3.01)
        }
        #expect(stroke.contains(CGPoint(x: 120, y: 40)))
    }

    @Test func readsShapesCommentsAndSemicolons() throws {
        let strokes = try StrokeScript.parse("""
        # an image placeholder
        box 34 186 326 364 radius 40
        cross 34 186 326 364
        // and a title
        wave 150 112 96 40 3; tick 300 640 24 24
        """)
        // The cross is two strokes.
        #expect(strokes.count == 5)
        let box = strokes[0]
        let xs = box.map(\.x), ys = box.map(\.y)
        #expect(abs((xs.min() ?? 0) - 34) < 3 && abs((xs.max() ?? 0) - 360) < 3)
        #expect(abs((ys.min() ?? 0) - 186) < 3 && abs((ys.max() ?? 0) - 550) < 3)
    }

    @Test func readsNegativeAndDecimalNumbers() {
        #expect(StrokeScript.numbers(in: "line -10.5 4 20,-3") == [-10.5, 4, 20, -3])
    }

    @Test func readsJSON() throws {
        let pairs = try StrokeScript.parse("[[[0, 0], [30, 0]], [{\"x\": 5, \"y\": 5}, {\"x\": 5, \"y\": 50}]]")
        #expect(pairs.count == 2)
        #expect(pairs[1].first == CGPoint(x: 5, y: 5))
        #expect(pairs[1].last == CGPoint(x: 5, y: 50))
        let wrapped = try StrokeScript.parse("{\"strokes\": [[[0, 0], [10, 10]]]}")
        #expect(wrapped.count == 1)
    }

    @Test func saysWhichLineItCouldNotRead() {
        #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("box 1 2 3 4\ntriangle 1 2 3") }
        do {
            _ = try StrokeScript.parse("box 1 2 3 4\ntriangle 1 2 3")
        } catch let error as StrokeScript.ParseError {
            #expect(error.line == 2)
            #expect(error.text == "triangle 1 2 3")
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("10,10 20") }
        #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("[[[0, 0]]]") }
    }

    @Test func aScriptedBoxIsReadLikeADrawnOne() throws {
        let observed = try #require(observation(try StrokeScript.parse("box 100 80 260 560 10")))
        guard case .enclosure = observed.form else {
            Issue.record("expected an enclosure, got \(observed.form)")
            return
        }
        let pill = try #require(observation(try StrokeScript.parse("pill 40 500 220 40")))
        guard case .enclosure(let roundness, _) = pill.form else {
            Issue.record("expected an enclosure, got \(pill.form)")
            return
        }
        #expect(roundness > 0.75)
    }
}

@Suite("Look words")
struct LookWordTests {
    @Test func controlsTakeTheirState() throws {
        let blueprint = try #require(ScreenBlueprint.parse("""
        checkbox [off]
        radio [selected]
        progress [40%]
        button: Skip [plain, centre, shadow, border red, opacity 50%]
        """))
        let elements = blueprint.layout(on: .iPhone)
        #expect(elements.map(\.kind) == [.checkbox, .radio, .progress, .button])
        #expect(elements[0].isOn == false)
        #expect(elements[1].isOn == true)
        #expect(elements[2].value == 0.4)
        let skip = elements[3]
        #expect(skip.buttonLook == .plain)
        #expect(skip.textAlignment == .center)
        #expect(skip.hasShadow)
        #expect(skip.borderColor == ColourWords.named["red"])
        #expect(skip.borderWidth == 1)
        #expect(skip.opacity == 0.5)
    }

    @Test func aLookCanBeGivenToAnElementAlone() {
        var element = DesignStore.newElement(.button)
        var item = ScreenBlueprint.Item(kind: .button, text: element.text)
        ScreenBlueprint.applyLook(["Bordered", " #112233", "20pt", "border 3"], to: &item)
        item.applyLook(to: &element)
        #expect(element.buttonLook == .bordered)
        #expect(element.tint == RGBColor(hex: 0x112233))
        #expect(element.fontSize == 20)
        #expect(element.borderWidth == 3)
    }
}

@Suite("Moving things from code")
@MainActor
struct MovingTests {
    private func model() -> AppModel {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        return model
    }

    @Test func anElementMovesToAnotherScreenAndBack() throws {
        let model = model()
        let first = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 0.5))
        let second = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 400, y: 0), scale: 0.5))
        var button = DesignStore.newElement(.button)
        button.frame = CGRect(x: 20, y: 700, width: 353, height: 50)
        let ref = model.store.setElements([button], on: first.id, replacing: false)[0]

        let moved = try #require(model.store.move(ref, toScreen: second.id, origin: CGPoint(x: 20, y: 100)))
        #expect(moved.host == .screen(second.id))
        #expect(model.store.screen(first.id)?.elements.isEmpty == true)
        #expect(model.store.resolve(moved)?.element.frame == CGRect(x: 20, y: 100, width: 353, height: 50))

        model.store.undoManager?.undo()
        #expect(model.store.resolve(ref)?.element.frame == button.frame)
        #expect(model.store.screen(second.id)?.elements.isEmpty == true)
    }

    @Test func offAScreenItKeepsItsPlaceAndSize() throws {
        let model = model()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 0.5))
        var title = DesignStore.newElement(.title)
        title.frame = CGRect(x: 40, y: 80, width: 200, height: 40)
        let ref = model.store.setElements([title], on: screen.id, replacing: false)[0]
        let before = try #require(model.store.resolve(ref)).placement.canvasRect(for: title.frame)

        let moved = try #require(model.store.move(ref, toScreen: nil, origin: nil))
        #expect(moved.host == .canvas)
        let after = try #require(model.store.resolve(moved))
        #expect(after.placement.canvasRect(for: after.element.frame) == before)
    }

    @Test func stickyNotesStayOffScreens() {
        let model = model()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let note = model.store.addFloating(DesignStore.newElement(.stickyNote), scale: 1)
        #expect(model.store.move(note, toScreen: screen.id, origin: .zero) == nil)
        #expect(model.store.floating.count == 1)
    }

    @Test func theLayoutReadsBackAsJSON() throws {
        let model = model()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 10, y: 20), scale: 0.5))
        let blueprint = try #require(ScreenBlueprint.parse("title: Hello\ntoggle [off]"))
        model.store.setElements(blueprint.layout(on: screen.device), on: screen.id, replacing: true)
        model.store.addFloating(DesignStore.newElement(.stickyNote), scale: 0.5)
        let snapshot = DesignSnapshot(id: "local:Test.layer", name: "Test", content: model.store.content, modified: nil)

        let json = DesignLayoutWriter.json(for: snapshot, ink: (count: 3, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let screens = try #require(root["screens"] as? [[String: Any]])
        #expect(screens.count == 1)
        #expect(screens[0]["x"] as? Double == 10)
        #expect(screens[0]["scale"] as? Double == 50)
        let elements = try #require(screens[0]["elements"] as? [[String: Any]])
        #expect(elements.map { $0["kind"] as? String } == ["title", "toggle"])
        #expect(elements[0]["text"] as? String == "Hello")
        #expect(elements[1]["on"] as? Bool == false)
        let id = try #require(elements[0]["id"] as? String)
        #expect(EntityKey.parseElement(id)?.design == "local:Test.layer")
        #expect((root["canvasElements"] as? [[String: Any]])?.count == 1)
        #expect((root["ink"] as? [String: Any])?["strokes"] as? Int == 3)
    }
}
