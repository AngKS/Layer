import CoreGraphics
import Foundation
import Testing
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
