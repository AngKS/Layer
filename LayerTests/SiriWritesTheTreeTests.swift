import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Layer

// Siri writes the tree (plan 6, Task 5): Add and Move take the numbers Get Design Layout gives, in host points through
// the index; a laid-out child is moved by the drag rule on its own screen; Align and Arrange say why they leave what a
// row, column or grid places; every write is one step with the system's undo; and a device is chosen by name, the
// design's own included. Through the static helpers, as `DesignActionTests` calls them.

@Suite("Siri writes the tree")
@MainActor
struct SiriWritesTheTreeTests {
    /// The global constraints' line for a laid-out child.
    private static let laidOutLine = "That element's place comes from the row, column or grid it's in. Change its order in the Layers panel, or move it out of the container first."

    private func ref(_ id: UUID, in login: TreeFixture.Login) throws -> DesignStore.ElementRef {
        try #require(login.model.store.ref(of: id))
    }

    private func isLaidOut(_ error: LayerIntentError?) -> Bool {
        error.map { if case .laidOut = $0 { true } else { false } } == true
    }

    private func said(_ error: LayerIntentError?) -> String? {
        error.map { String(localized: $0.localizedStringResource) }
    }

    private func close(_ a: CGRect?, _ b: CGRect, within tolerance: CGFloat = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func systemUndo() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    /// A design of its own with one iPhone screen laid out in a column, holding `texts`, with an empty undo history.
    private func columnScreen(_ texts: [LayerNode]) -> (model: AppModel, undo: UndoManager, screen: TreeScreen.ID) {
        let model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        let screen = model.store.addColumnScreen(texts)
        let undo = systemUndo()
        model.store.undoManager = undo
        return (model, undo, screen)
    }

    private func text(_ words: String) -> LayerNode {
        .leaf(.text, frame: CGRect(x: 0, y: 0, width: 100, height: 24), text: words)
    }

    /// The fixture with the design's own device "Kiosk" (1080 × 1920, `.other`) and a second free iPhone screen at
    /// (453, 0), and nothing in its history.
    private func withKioskAndASecondScreen() throws -> (login: TreeFixture.Login, kiosk: String, second: TreeScreen.ID) {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let kiosk = store.addCustomDevice(.custom(name: "Kiosk", size: CGSize(width: 1080, height: 1920), family: .other))
        try #require(!kiosk.isEmpty)
        let second = store.addFreeScreen([], name: "Second", origin: CGPoint(x: 453, y: 0))
        login.undo.removeAllActions()
        return (login, kiosk, second)
    }

    // MARK: - Move

    /// F8: what Get Design Layout says of a node inside a turned card, handed back, is no move at all.
    @Test func aLayoutsFrameMovedBackChangesNothing() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        store.update(login.card) { $0.rotation = 30 }
        login.undo.removeAllActions()

        let snapshot = try #require(DesignActions.snapshot(of: login.model))
        let json = DesignLayoutWriter.json(for: snapshot)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let screens = try #require(root["screens"] as? [[String: Any]])
        let elements = try #require(screens.first { $0["name"] as? String == "Login" }?["elements"] as? [[String: Any]])
        let about = try #require(elements.first { ($0["id"] as? String)?.hasSuffix(login.about.uuidString) == true })
        let x = try #require(about["x"] as? Double), y = try #require(about["y"] as? Double)
        let width = try #require(about["width"] as? Double), height = try #require(about["height"] as? Double)
        #expect(x == 70.1, "written to a tenth: 70.106…")
        let before = store.tree

        try MoveElementIntent.move(try ref(login.about, in: login), in: login.model, x: x, y: y, width: width, height: height,
                                   undoManager: nil)

        #expect(store.tree == before)
        #expect(!login.undo.canUndo)
    }

    @Test func aMoveInsideATurnedCardLandsWhereAsked() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        store.update(login.card) { $0.rotation = 30 }

        try MoveElementIntent.move(try ref(login.about, in: login), in: login.model, x: 160, y: 150, width: nil, height: nil,
                                   undoManager: nil)

        // `place` is exact under a turned parent: plan 4's `placingUnderATurnedContainerLandsWhereAsked` holds to 1e-6.
        #expect(close(store.index[login.about]?.hostShape.rect, CGRect(x: 160, y: 150, width: 200, height: 24)))
        #expect(store.node(login.about)?.rotation == nil)
        #expect(store.parent(of: login.about) == .node(login.card))
    }

    /// Call 3 on the open canvas: Add and Move take canvas points, each ÷ the node's scale in its own points, and Get
    /// Design Layout's numbers handed back move nothing.
    @Test func onTheCanvasNumbersAreCanvasPoints() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let note = try ref(login.note, in: login)

        // Drawn at 0.5, its own (600, 100, 150, 150) is (300, 50, 75, 75) on the canvas.
        try MoveElementIntent.move(note, in: login.model, x: 300, y: 50, width: 75, height: 75, undoManager: nil)
        #expect(!login.undo.canUndo)
        try MoveElementIntent.move(note, in: login.model, x: 200, y: nil, width: nil, height: nil, undoManager: nil)
        #expect(store.ownFrame(login.note) == CGRect(x: 400, y: 100, width: 150, height: 150))
        #expect(store.index[login.note]?.hostShape.rect == CGRect(x: 200, y: 50, width: 75, height: 75))

        // A new thing on the canvas is drawn as large as the newest screen, here at 0.5.
        store.addFreeScreen([], name: "Small", origin: CGPoint(x: 453, y: 0), scale: 0.5)
        let added = try AddElementIntent.add(.standard(.stickyNote), to: .canvas, in: login.model, x: 40, y: 60, width: 100,
                                             height: 80, undoManager: nil)
        #expect(added.host == DesignStore.ElementRef.Host.canvas)
        #expect(store.node(added.element)?.scale == 0.5)
        #expect(store.ownFrame(added.element) == CGRect(x: 80, y: 120, width: 200, height: 160))
        #expect(store.index[added.element]?.hostShape.rect == CGRect(x: 40, y: 60, width: 100, height: 80))
    }

    @Test func movingARowChildTakesItOutWhereAsked() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store

        try MoveElementIntent.move(try ref(login.label, in: login), in: login.model, x: 40, y: 600, width: nil, height: nil,
                                   undoManager: nil)

        #expect(store.treeScreen(login.screen)?.root.children.last?.id == login.label)
        #expect(store.ownFrame(login.label) == CGRect(x: 40, y: 600, width: 80, height: 24))
        #expect(store.node(login.label)?.width.mode == .fixed)
        #expect(store.node(login.label)?.height.mode == .fixed)
        #expect(store.node(login.row)?.children.map(\.id) == [login.toggle])

        #expect(login.undo.undoActionName == "Move Text")
        login.undo.undo()
        #expect(store.node(login.row)?.children.map(\.id) == [login.label, login.toggle])
        #expect(!login.undo.canUndo, "one step")
    }

    /// F7: the label sits at y 324. Its centre at x 160 is past the toggle's middle, inside the row.
    @Test func movingWithinItsRowReorders() throws {
        let login = TreeFixture.loginWithACardAndARow()

        try MoveElementIntent.move(try ref(login.label, in: login), in: login.model, x: 120, y: 324, width: nil, height: nil,
                                   undoManager: nil)

        #expect(login.model.store.node(login.row)?.children.map(\.id) == [login.toggle, login.label])
    }

    /// F15: a column screen's child is reordered, and has nowhere to be taken out to.
    @Test func onAColumnScreenAMoveReorders() throws {
        let t1 = text("One"), t2 = text("Two"), t3 = text("Three")
        let (model, _, screen) = columnScreen([t1, t2, t3])
        let store = model.store
        let ref = try #require(store.ref(of: t1.id))
        let below = try #require(store.ownFrame(t3.id)).maxY + 10

        try MoveElementIntent.move(ref, in: model, x: nil, y: below, width: nil, height: nil, undoManager: nil)
        #expect(store.treeScreen(screen)?.root.children.map(\.id) == [t2.id, t3.id, t1.id])

        let before = store.tree
        let refused = #expect(throws: LayerIntentError.self) {
            try MoveElementIntent.move(ref, in: model, x: 500, y: 900, width: nil, height: nil, undoManager: nil)
        }
        #expect(isLaidOut(refused))
        #expect(store.tree == before)
    }

    @Test func aLaidOutChildStaysOnItsScreen() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let second = store.addFreeScreen([], name: "Second", origin: CGPoint(x: 453, y: 0))
        let secondBefore = store.treeScreen(second)

        try MoveElementIntent.move(try ref(login.label, in: login), in: login.model, x: 500, y: 100, width: nil, height: nil,
                                   undoManager: nil)

        #expect(store.treeScreen(login.screen)?.root.children.last?.id == login.label)
        #expect(store.ownFrame(login.label) == CGRect(x: 500, y: 100, width: 80, height: 24))
        #expect(store.treeScreen(second) == secondBefore)
    }

    @Test func resizingARowChildFixesItsAxis() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store

        try MoveElementIntent.move(try ref(login.label, in: login), in: login.model, x: nil, y: nil, width: 120, height: nil,
                                   undoManager: nil)

        let label = try #require(store.node(login.label))
        #expect(label.width.mode == .fixed)
        #expect(label.frame.width == 120)
        #expect(label.height.mode == .fixed)
        #expect(label.frame.height == 24)
        #expect(store.node(login.row)?.frame.width == 183)
    }

    // MARK: - Align and Arrange

    /// F14 and My call 15: Align leaves anything a laid-out parent places, an overlay's included; Arrange leaves what a
    /// row, column or grid orders, and arranges in an overlay.
    @Test func alignAndArrangeRefuseALaidOutChild() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let label = try ref(login.label, in: login)
        let before = store.tree

        let aligned = #expect(throws: LayerIntentError.self) {
            try AlignElementIntent.align(label, in: login.model, .left, undoManager: nil)
        }
        #expect(isLaidOut(aligned))
        #expect(said(aligned) == Self.laidOutLine)
        let arranged = #expect(throws: LayerIntentError.self) {
            try ArrangeElementIntent.arrange(label, in: login.model, .forward, undoManager: nil)
        }
        #expect(isLaidOut(arranged))
        #expect(said(arranged) == Self.laidOutLine)
        #expect(store.tree == before)

        let back = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 100, height: 24), text: "Back")
        let front = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 60, height: 24), text: "Front")
        let overlay = LayerNode.container(layout: .overlay(LayerNode.Alignment()), frame: CGRect(x: 20, y: 420, width: 0, height: 0),
                                          children: [back, front])
        #expect(store.add(overlay, to: .screen(login.screen)))
        let backRef = try ref(back.id, in: login)

        try ArrangeElementIntent.arrange(backRef, in: login.model, .forward, undoManager: nil)
        #expect(store.node(overlay.id)?.children.map(\.id) == [front.id, back.id])
        let inOverlay = store.tree
        let alignedInOverlay = #expect(throws: LayerIntentError.self) {
            try AlignElementIntent.align(backRef, in: login.model, .left, undoManager: nil)
        }
        #expect(isLaidOut(alignedInOverlay))
        #expect(store.tree == inOverlay)
    }

    @Test func arrangingInAFreeCardStillWorks() throws {
        let login = TreeFixture.loginWithACardAndARow()

        try ArrangeElementIntent.arrange(try ref(login.about, in: login), in: login.model, .forward, undoManager: nil)

        #expect(login.model.store.node(login.card)?.children.map(\.id) == [login.body, login.about])
    }

    // MARK: - Add

    @Test func addingToAFreeScreenGoesWhereItWent() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let expected = try #require(store.newElementFrame(.button, on: login.screen))

        let added = try AddElementIntent.add(.standard(.button), to: .screen(login.screen), in: login.model, x: nil, y: nil,
                                             width: nil, height: nil, undoManager: nil)

        #expect(added.host == DesignStore.ElementRef.Host.screen(login.screen))
        #expect(store.ownFrame(added.element)?.minY == 367, "the toggle's maxY 351, and 16")
        #expect(store.ownFrame(added.element) == expected)
    }

    @Test func addingToAColumnScreenAppendsIt() throws {
        let t1 = text("One"), t2 = text("Two")
        let (model, _, screen) = columnScreen([t1, t2])
        let store = model.store
        var more = LayerNode.standard(.text)
        more.content.text = "More"

        let added = try AddElementIntent.add(more, to: .screen(screen), in: model, x: 40, y: 600, width: 200, height: nil,
                                             undoManager: nil)

        #expect(store.treeScreen(screen)?.root.children.map(\.id) == [t1.id, t2.id, added.element])
        let node = try #require(store.node(added.element))
        #expect(node.content.text == "More")
        #expect(node.width.mode == .fixed)
        #expect(node.frame.width == 200)
        #expect(store.ownFrame(added.element)?.minX == 20)
    }

    // MARK: - Devices by name

    @Test func aCustomDeviceIsChosenByName() throws {
        let (login, kiosk, _) = try withKioskAndASecondScreen()
        let store = login.model.store

        let toKiosk = try ChangeScreenDeviceIntent.change(login.screen, to: .iPhone, custom: " kiosk ", in: login.model,
                                                          undoManager: nil)

        #expect(store.treeScreen(login.screen)?.deviceID == kiosk)
        #expect(store.treeScreen(login.screen)?.root.frame == CGRect(x: 0, y: 0, width: 1080, height: 1920))
        #expect(toKiosk == "Login is now a Kiosk screen.")
        login.undo.undo()
        #expect(store.treeScreen(login.screen)?.deviceID == nil)
        #expect(!login.undo.canUndo, "one step")
        login.undo.redo()

        let toIPad = try ChangeScreenDeviceIntent.change(login.screen, to: .iPad, custom: nil, in: login.model, undoManager: nil)
        #expect(store.treeScreen(login.screen)?.deviceID == "ipad")
        #expect(toIPad == "Login is now an iPad screen.")
    }

    @Test func anUnknownCustomDeviceIsRefused() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let before = login.model.store.tree

        let refused = #expect(throws: LayerIntentError.self) {
            try ChangeScreenDeviceIntent.change(login.screen, to: .iPhone, custom: "Wall", in: login.model, undoManager: nil)
        }

        #expect(refused.map { if case .deviceNotFound("Wall") = $0 { true } else { false } } == true)
        #expect(said(refused) == "This design has no device called “Wall”. Make one with Custom Size… in the device picker.")
        #expect(login.model.store.tree == before)
    }

    /// F17: the front design's options, read through the model.
    @Test func theOptionsAreTheDesignsOwnDevices() {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        store.addCustomDevice(.custom(name: "Kiosk", size: CGSize(width: 1080, height: 1920), family: .other))
        store.addCustomDevice(.custom(name: "Watch", size: CGSize(width: 198, height: 242), family: .watch))

        #expect(CustomDeviceOptions.names(in: login.model) == ["Kiosk", "Watch"])
    }

    @Test func newScreensCanBeOnACustomDevice() async throws {
        let (login, kiosk, _) = try withKioskAndASecondScreen()
        let model = login.model, store = model.store
        let design = try #require(DesignActions.snapshot(of: model)).entity
        let frame = try #require(store.tree.settings.customDevices.first { $0.id == kiosk })

        let add = AddScreenIntent()
        add.design = design
        add.device = .iPhone
        add.customDevice = "Kiosk"
        _ = try await add.perform()
        #expect(store.tree.screens.last?.deviceID == kiosk)
        #expect(store.tree.screens.last?.root.frame.size == CGSize(width: 1080, height: 1920))

        let built = try await BuildScreenIntent.build("title: Lobby\nbutton: Check in", on: nil, name: "Lobby", device: frame,
                                                      in: model, undoManager: nil)
        #expect(store.treeScreen(built)?.deviceID == kiosk)

        let settings = UpdateCanvasSettingsIntent()
        settings.design = design
        settings.customSketchDevice = "Kiosk"
        _ = try await settings.perform()
        #expect(store.tree.settings.sketchDeviceID == kiosk)
    }

    // MARK: - One step each

    /// A write Siri makes, on a node inside the card or the row, with the system's undo manager; it hands back a hand
    /// edit made later to what it changed.
    private struct Write {
        var name: String
        var act: (TreeFixture.Login, TreeScreen.ID, UndoManager) throws -> () -> Void
    }

    private var writes: [Write] {
        [
            Write(name: "Add") { login, _, siri in
                let added = try AddElementIntent.add(.standard(.button), to: .screen(login.screen), in: login.model, x: nil, y: nil,
                                                     width: nil, height: nil, undoManager: siri)
                return { login.model.store.update(added.element) { $0.content.text = "By hand" } }
            },
            Write(name: "Edit Text") { login, _, siri in
                try EditElementTextIntent.setText("Siri", of: try ref(login.about, in: login), in: login.model, undoManager: siri)
                return { login.model.store.update(login.about) { $0.content.text = "By hand" } }
            },
            Write(name: "Move") { login, _, siri in
                try MoveElementIntent.move(try ref(login.about, in: login), in: login.model, x: 30, y: nil, width: nil, height: nil,
                                           undoManager: siri)
                return { login.model.store.update(login.about) { $0.frame.origin.x += 5 } }
            },
            Write(name: "Move to Screen") { login, second, siri in
                _ = try MoveElementToScreenIntent.move(try ref(login.about, in: login), toScreen: second, x: 40, y: 40,
                                                       in: login.model, undoManager: siri)
                return { login.model.store.update(login.about) { $0.frame.origin.x += 5 } }
            },
            Write(name: "Style") { login, _, siri in
                let style = StyleElementIntent()
                style.colour = .red
                try style.style(try ref(login.about, in: login), in: login.model, undoManager: siri)
                return { login.model.store.update(login.about) { $0.style.tint = RGBColor(hex: 0x00FF00) } }
            },
            Write(name: "Duplicate") { login, _, siri in
                let copy = try DuplicateElementIntent.duplicate(try ref(login.about, in: login), in: login.model, undoManager: siri)
                return { login.model.store.update(copy.element) { $0.content.text = "By hand" } }
            },
            Write(name: "Delete") { login, _, siri in
                try DeleteElementIntent.delete(try ref(login.body, in: login), in: login.model, undoManager: siri)
                // What held it goes by hand, so there is nowhere to put it back.
                return { login.model.store.delete(nodes: [login.card]) }
            },
            Write(name: "Set Hidden") { login, _, siri in
                try SetElementHiddenIntent.setHidden(true, try ref(login.about, in: login), in: login.model, undoManager: siri)
                return { login.model.store.update(login.about) { $0.isHidden = false } }
            },
            Write(name: "Set Locked") { login, _, siri in
                try SetElementLockedIntent.setLocked(true, try ref(login.label, in: login), in: login.model, undoManager: siri)
                return { login.model.store.update(login.label) { $0.isLocked = false } }
            },
            Write(name: "Rename") { login, _, siri in
                try RenameElementIntent.rename(try ref(login.toggle, in: login), to: "Wi-Fi switch", in: login.model, undoManager: siri)
                return { login.model.store.update(login.toggle) { $0.name = "By hand" } }
            },
            Write(name: "Change Screen Device") { login, _, siri in
                _ = try ChangeScreenDeviceIntent.change(login.screen, to: .iPhone, custom: "Kiosk", in: login.model, undoManager: siri)
                return { login.model.store.setDevice(of: login.screen, to: "ipad") }
            },
        ]
    }

    /// F30: each write is one step in the design's history and one in the system's, whose undo puts the design back;
    /// once what it changed is changed again by hand, the system is offered nothing to undo.
    @Test func everyWriteIsOneStepWithSystemUndo() throws {
        for write in writes {
            let (login, _, second) = try withKioskAndASecondScreen()
            let store = login.model.store
            let siri = systemUndo()
            let before = store.tree

            _ = try write.act(login, second, siri)

            #expect(store.tree != before, "\(write.name) changes the design")
            let after = store.tree
            #expect(login.undo.canUndo && siri.canUndo, "\(write.name)")
            login.undo.undo()
            #expect(store.tree == before, "\(write.name): the design's one step")
            #expect(!login.undo.canUndo, "\(write.name): one step in the design's history")
            login.undo.redo()
            #expect(store.tree == after, "\(write.name)")
            siri.undo()
            #expect(store.tree == before, "\(write.name): the system's undo puts it back")
            #expect(!siri.canUndo, "\(write.name): one step in the system's history")

            let (again, _, secondAgain) = try withKioskAndASecondScreen()
            let later = systemUndo()
            let byHand = try write.act(again, secondAgain, later)
            again.model.withdrawTakenActionsWithNothingLeft()
            #expect(later.canUndo, "\(write.name): still as Siri left it")
            byHand()
            again.model.withdrawTakenActionsWithNothingLeft()
            #expect(!later.canUndo, "\(write.name): withdrawn once changed by hand")
        }
    }

    /// F30: Move to Screen takes a thing out of its card, onto the other screen's root where it is asked to go.
    @Test func movingToAnotherScreenTakesItOutOfItsContainer() throws {
        let (login, _, second) = try withKioskAndASecondScreen()
        let store = login.model.store

        let moved = try MoveElementToScreenIntent.move(try ref(login.about, in: login), toScreen: second, x: 40, y: 40,
                                                       in: login.model, undoManager: nil)

        #expect(moved == DesignStore.ElementRef(host: .screen(second), element: login.about))
        #expect(store.parent(of: login.about) == .screen(second))
        #expect(store.ownFrame(login.about) == CGRect(x: 40, y: 40, width: 200, height: 24))
        #expect(store.node(login.about)?.width.mode == .fixed)
        #expect(store.node(login.about)?.height.mode == .fixed)
        #expect(store.node(login.card)?.children.map(\.id) == [login.body])
        login.undo.undo()
        #expect(store.node(login.card)?.children.map(\.id) == [login.about, login.body])
        #expect(!login.undo.canUndo, "one step")
    }

    // MARK: - Pictures

    @Test func aPictureGoesIntoAnImageInACard() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let image = LayerNode.leaf(.image, frame: CGRect(x: 16, y: 96, width: 100, height: 48))
        #expect(store.add(image, to: .node(login.card)))
        let ref = try ref(image.id, in: login)
        let frame = try #require(store.ownFrame(image.id))

        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        let data = try #require(drawn.pngData())
        let picture = try #require(ImageImport.prepare(data))
        let request = ImagePlaygroundRequest(target: .replace(ref))

        #expect(login.model.placeGeneratedImage(picture, for: request) == ref)

        #expect(store.node(image.id)?.content.imageID != nil)
        #expect(store.ownFrame(image.id) == frame)
        #expect(store.parent(of: image.id) == .node(login.card))
    }
}
