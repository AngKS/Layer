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

    private func ref(_ id: UUID, in login: TreeFixture.Login) throws -> NodeRef {
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
        #expect(added.host == NodeRef.Host.canvas)
        #expect(store.node(added.node)?.scale == 0.5)
        #expect(store.ownFrame(added.node) == CGRect(x: 80, y: 120, width: 200, height: 160))
        #expect(store.index[added.node]?.hostShape.rect == CGRect(x: 40, y: 60, width: 100, height: 80))
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

    /// A row child given a position whose centre falls in its own slot is kept there by the row: Siri says so, with
    /// `laidOut`, and never "Moved". Nothing is kept, a size given with the position included, and nothing is offered to
    /// undo. Move to Screen onto its own screen goes the same way (plan 6 final review A, I1).
    @Test func aRowChildMovedWithinItsOwnSlotIsRefused() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let label = try ref(login.label, in: login)
        let shown = try #require(store.index[login.label]?.hostShape.rect)
        let siri = systemUndo()
        let before = store.tree

        let kept = #expect(throws: LayerIntentError.self) {
            try MoveElementIntent.move(label, in: login.model, x: Double(shown.minX) + 5, y: nil, width: nil, height: nil,
                                       undoManager: siri)
        }
        #expect(isLaidOut(kept))
        #expect(said(kept) == Self.laidOutLine)
        #expect(store.tree == before)

        // The size alone would be kept, as resizing a row child is, but the position can't be.
        let resized = #expect(throws: LayerIntentError.self) {
            try MoveElementIntent.move(label, in: login.model, x: Double(shown.minX) + 5, y: nil, width: 90, height: nil,
                                       undoManager: siri)
        }
        #expect(isLaidOut(resized))
        #expect(store.tree == before)

        let onItsScreen = #expect(throws: LayerIntentError.self) {
            _ = try MoveElementToScreenIntent.move(label, toScreen: login.screen, x: Double(shown.minX) + 5, y: nil,
                                                   in: login.model, undoManager: siri)
        }
        #expect(isLaidOut(onItsScreen))
        #expect(store.tree == before)
        #expect(!login.undo.canUndo)
        #expect(!siri.canUndo)
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

    /// Siri's Align lines up what sits in a free parent with its screen, as the popover's Align does: a leaf on the free
    /// root, one in a free card, and one in a turned card by the box round its turned shape, each its own step, "Align".
    /// A column screen's child, which its root places, is refused and nothing changes (plan 6 final review C, I1).
    @Test func aligningThingsInFreeParentsLinesThemUpWithTheScreen() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        func seen(_ id: UUID) throws -> CGRect { try #require(store.index[id]?.hostShape.bounds) }

        try AlignElementIntent.align(try ref(login.title, in: login), in: login.model, .left, undoManager: nil)
        #expect(try seen(login.title).minX == 0)
        #expect(login.undo.undoActionName == "Align")
        try AlignElementIntent.align(try ref(login.about, in: login), in: login.model, .right, undoManager: nil)
        #expect(try seen(login.about).maxX == 393)
        #expect(store.parent(of: login.about) == .node(login.card))
        store.update(login.card) { $0.rotation = 30 }
        try AlignElementIntent.align(try ref(login.body, in: login), in: login.model, .bottom, undoManager: nil)
        // Its corner goes on whole points of the screen, as any thing placed does, so its turned box is within half a
        // point of the edge.
        let bottom = try seen(login.body).maxY
        #expect(abs(bottom - 852) <= 0.5, "\(bottom)")
        #expect(store.parent(of: login.body) == .node(login.card))

        let t1 = text("One"), t2 = text("Two")
        let (model, _, screen) = columnScreen([t1, t2])
        let child = try #require(model.store.ref(of: t2.id))
        let before = model.store.tree
        let refused = #expect(throws: LayerIntentError.self) {
            try AlignElementIntent.align(child, in: model, .left, undoManager: nil)
        }
        #expect(isLaidOut(refused))
        #expect(model.store.tree == before)
        #expect(model.store.treeScreen(screen)?.root.children.map(\.id) == [t1.id, t2.id])
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

        #expect(added.host == NodeRef.Host.screen(login.screen))
        #expect(store.ownFrame(added.node)?.minY == 367, "the toggle's maxY 351, and 16")
        #expect(store.ownFrame(added.node) == expected)
    }

    @Test func addingToAColumnScreenAppendsIt() throws {
        let t1 = text("One"), t2 = text("Two")
        let (model, _, screen) = columnScreen([t1, t2])
        let store = model.store
        var more = LayerNode.standard(.text)
        more.content.text = "More"

        let added = try AddElementIntent.add(more, to: .screen(screen), in: model, x: 40, y: 600, width: 200, height: nil,
                                             undoManager: nil)

        #expect(store.treeScreen(screen)?.root.children.map(\.id) == [t1.id, t2.id, added.node])
        let node = try #require(store.node(added.node))
        #expect(node.content.text == "More")
        #expect(node.width.mode == .fixed)
        #expect(node.frame.width == 200)
        #expect(store.ownFrame(added.node)?.minX == 20)
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
                return { login.model.store.update(added.node) { $0.content.text = "By hand" } }
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
                return { login.model.store.update(copy.node) { $0.content.text = "By hand" } }
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
            Write(name: "Align") { login, _, siri in
                try AlignElementIntent.align(try ref(login.about, in: login), in: login.model, .left, undoManager: siri)
                return { login.model.store.update(login.about) { $0.frame.origin.x += 5 } }
            },
            Write(name: "Arrange") { login, _, siri in
                try ArrangeElementIntent.arrange(try ref(login.about, in: login), in: login.model, .forward, undoManager: siri)
                return { login.model.store.reorder([.node(login.card): [login.about, login.body]]) }
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

        #expect(moved == NodeRef(host: .screen(second), node: login.about))
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

    /// A teal picture 64 × 32, as a file gives one.
    private func picture() throws -> ImageImport.Prepared {
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        let data = try #require(drawn.pngData())
        return try #require(ImageImport.prepare(data))
    }

    /// Brings the fixture's design to 5,000 nodes with a screen of texts, its root among them.
    private func fill(_ login: TreeFixture.Login) throws {
        let store = login.model.store
        let room = TreeRules.maximumNodes - store.index.count - 1
        let texts = (0..<room).map { _ in LayerNode.leaf(.text, frame: CGRect(x: 20, y: 100, width: 80, height: 20), text: "Text") }
        store.addFreeScreen(texts, name: "Crowd", origin: CGPoint(x: 2_000, y: 0))
        try #require(store.index.count == TreeRules.maximumNodes)
        login.undo.removeAllActions()
    }

    /// Add Picture in a full design, on the open canvas or on a screen, hands back nothing and says the design is full.
    /// Nothing is written: what was selected isn't moved to the X and Y the picture was given (plan 6 final review A, I2).
    @Test func aPictureAddedToAFullDesignIsRefusedAsTooLarge() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model, store = model.store
        try fill(login)
        model.selection = .element(try ref(login.title, in: login))
        let picture = try picture()
        let before = store.tree
        func isTooLarge(_ error: LayerIntentError?) -> Bool {
            error.map { if case .designTooLarge = $0 { true } else { false } } == true
        }

        #expect(model.placeGeneratedImage(picture, for: ImagePlaygroundRequest(target: .newImage(onScreen: nil))) == nil)
        let onCanvas = #expect(throws: LayerIntentError.self) {
            _ = try AddImageFileIntent.add(picture, for: ImagePlaygroundRequest(target: .newImage(onScreen: nil)), in: model,
                                           x: 300, y: 300, width: nil, height: nil, undoManager: nil)
        }
        #expect(isTooLarge(onCanvas))
        let onScreen = #expect(throws: LayerIntentError.self) {
            _ = try AddImageFileIntent.add(picture, for: ImagePlaygroundRequest(target: .newImage(onScreen: login.screen)), in: model,
                                           x: 300, y: 300, width: nil, height: nil, undoManager: nil)
        }
        #expect(isTooLarge(onScreen))
        #expect(store.tree == before)
        #expect(!login.undo.canUndo)
    }

    // MARK: - Task 5's review, carried to Task 10

    private func isDeviceNotFound(_ error: LayerIntentError?, named name: String) -> Bool {
        error.map { if case .deviceNotFound(let said) = $0 { said == name } else { false } } == true
    }

    /// M1: one of the design's own devices that can't be used (`problems`, which a file can hold, though the device
    /// picker never makes one) is refused by its name, as a name the design has no device for is, by each action that
    /// takes a Custom Device, before anything is written.
    @Test func aCustomDeviceThatCantBeUsedIsRefusedByName() async throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model, store = model.store
        let sliver = DeviceFrame.custom(name: "Sliver", size: CGSize(width: 1, height: 1920), family: .other)
        #expect(!sliver.problems.isEmpty)
        store.updateCanvas { $0.customDevices.append(sliver) }
        try #require(store.tree.settings.customDevice(named: "Sliver") != nil)
        login.undo.removeAllActions()
        let before = store.tree
        let design = try #require(DesignActions.snapshot(of: model)).entity

        #expect(isDeviceNotFound(#expect(throws: LayerIntentError.self) {
            try DesignActions.device(.iPhone, custom: " Sliver ", in: model)
        }, named: "Sliver"))
        let changed = #expect(throws: LayerIntentError.self) {
            try ChangeScreenDeviceIntent.change(login.screen, to: .iPhone, custom: "Sliver", in: model, undoManager: nil)
        }
        #expect(isDeviceNotFound(changed, named: "Sliver"))
        #expect(said(changed) == "This design has no device called “Sliver”. Make one with Custom Size… in the device picker.")

        let add = AddScreenIntent()
        add.design = design
        add.device = .iPhone
        add.customDevice = "Sliver"
        let added = await #expect(throws: LayerIntentError.self) { _ = try await add.perform() }
        #expect(isDeviceNotFound(added, named: "Sliver"))

        let built = await #expect(throws: LayerIntentError.self) {
            _ = try await BuildScreenIntent.build("title: Lobby", on: nil, name: "Lobby", device: .iPhone, custom: "Sliver",
                                                  in: model, undoManager: nil)
        }
        #expect(isDeviceNotFound(built, named: "Sliver"))

        let settings = UpdateCanvasSettingsIntent()
        settings.design = design
        settings.customSketchDevice = "Sliver"
        let set = await #expect(throws: LayerIntentError.self) { _ = try await settings.perform() }
        #expect(isDeviceNotFound(set, named: "Sliver"))

        #expect(store.tree == before)
        #expect(!login.undo.canUndo)
    }

    /// M2: Duplicate Screen copies a screen in one step, and with no room for the copy says the design is full, not that
    /// the screen has gone; the words read right after a copy.
    @Test func aScreenCopiedIntoAFullDesignIsRefusedAsTooLarge() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model, store = model.store

        let copy = try DuplicateScreenIntent.duplicate(login.screen, in: model, undoManager: nil)
        #expect(store.treeScreen(copy)?.name == "Login Copy")
        login.undo.undo()
        #expect(store.treeScreen(copy) == nil)
        #expect(!login.undo.canUndo, "one step")

        // A screen of texts that brings the design to 5,000 nodes, its root among them.
        let room = TreeRules.maximumNodes - store.index.count - 1
        let texts = (0..<room).map { _ in LayerNode.leaf(.text, frame: CGRect(x: 20, y: 100, width: 80, height: 20), text: "Text") }
        store.addFreeScreen(texts, name: "Crowd", origin: CGPoint(x: 2_000, y: 0))
        try #require(store.index.count == TreeRules.maximumNodes)
        login.undo.removeAllActions()
        let before = store.tree

        let refused = #expect(throws: LayerIntentError.self) {
            try DuplicateScreenIntent.duplicate(login.screen, in: model, undoManager: nil)
        }
        #expect(refused.map { if case .designTooLarge = $0 { true } else { false } } == true)
        #expect(said(refused) == "That would make the design larger than Layer keeps: more than \(TreeRules.maximumNodes.formatted()) things, or nested more than \(TreeRules.maximumDepth) deep. Nothing was changed.")
        #expect(store.tree == before)
        #expect(!login.undo.canUndo)

        let gone = #expect(throws: LayerIntentError.self) {
            try DuplicateScreenIntent.duplicate(TreeScreen.ID(), in: model, undoManager: nil)
        }
        #expect(gone.map { if case .screenNotFound = $0 { true } else { false } } == true)
    }

    /// A screen on one of the design's own devices that a file held broken (`problems`) is still copied by Duplicate
    /// Screen, keeping its device, in one step: a copy chooses no new device. Siri never says the design is full when it
    /// isn't (plan 6, Task 11 fix round, I1).
    @Test func aScreenOnADeviceThatCantBeUsedIsStillDuplicated() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model, store = model.store
        let sliver = DeviceFrame.custom(name: "Sliver", size: CGSize(width: 1, height: 1920), family: .other)
        #expect(!sliver.problems.isEmpty)
        // As a file holds them: the store makes no new screen on the device.
        let thin = TreeScreen(name: "Thin", origin: CGPoint(x: 2_000, y: 0), scale: 1, deviceID: sliver.id)
        store.changeTree(writing: 0) {
            $0.settings.customDevices.append(sliver)
            $0.screens.append(thin)
        }
        login.undo.removeAllActions()

        let copy = try DuplicateScreenIntent.duplicate(thin.id, in: model, undoManager: nil)
        #expect(store.treeScreen(copy)?.name == "Thin Copy")
        #expect(store.device(of: copy) == sliver)
        login.undo.undo()
        #expect(store.treeScreen(copy) == nil)
        #expect(!login.undo.canUndo, "one step")
    }

    /// Build Screen asked for a new screen on a device that can't be used (`problems`), such as a New Screens device a
    /// file held broken, throws `deviceNotFound` with its name before anything is read or written, never
    /// `designTooLarge` (Task 11 fix round, I2).
    @Test func aBuildOnADeviceThatCantBeUsedIsRefusedByName() async throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model, store = model.store
        let sliver = DeviceFrame.custom(name: "Sliver", size: CGSize(width: 1, height: 1920), family: .other)
        store.changeTree(writing: 0) { $0.settings.customDevices.append(sliver) }
        login.undo.removeAllActions()
        let before = store.tree

        let built = await #expect(throws: LayerIntentError.self) {
            _ = try await BuildScreenIntent.build("title: Lobby", on: nil, name: "Lobby", device: sliver, in: model,
                                                  undoManager: nil)
        }
        #expect(isDeviceNotFound(built, named: "Sliver"))
        #expect(store.tree == before)
        #expect(!login.undo.canUndo)
    }

    /// M5: Move to Screen onto the open canvas at X and Y, in canvas points, puts the thing's corner there, drawn as large
    /// as it was, in one step. `MovingTests` moves one off a screen where it is, and refuses a sticky note a screen.
    @Test func movingOntoTheOpenCanvasPutsItsCornerWhereAsked() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store

        let moved = try MoveElementToScreenIntent.move(try ref(login.title, in: login), toScreen: nil, x: 600, y: 400,
                                                       in: login.model, undoManager: nil)

        #expect(moved == NodeRef(host: .canvas, node: login.title))
        #expect(store.canvasRect(of: login.title) == CGRect(x: 600, y: 400, width: 228, height: 40))
        login.undo.undo()
        #expect(store.ref(of: login.title)?.host == .screen(login.screen))
        #expect(!login.undo.canUndo, "one step")
    }

    /// M6: Build Screen looks up its Custom Device only for a new screen, the one build that uses it, so a rebuild isn't
    /// refused for a name it wouldn't use.
    @Test func aRebuildLooksUpNoCustomDevice() async throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model

        let rebuilt = try await BuildScreenIntent.build("title: Again", on: login.screen, name: nil, device: .iPhone, custom: "Wall",
                                                        in: model, undoManager: nil)
        #expect(rebuilt == login.screen)
        #expect(model.store.screenLeaves(login.screen).contains { $0.content.text == "Again" })

        let refused = await #expect(throws: LayerIntentError.self) {
            _ = try await BuildScreenIntent.build("title: New", on: nil, name: nil, device: .iPhone, custom: "Wall", in: model,
                                                  undoManager: nil)
        }
        #expect(isDeviceNotFound(refused, named: "Wall"))
    }

    /// M7: a screen's subtitle names its device as Siri and Shortcuts show it (`deviceName`): a built-in by the name
    /// Siri gives it, never its own trademarked one (F23), and one of the design's own by the name it was given.
    @Test func aScreensSubtitleNamesItsDeviceAsSiriShowsIt() throws {
        let (login, _, second) = try withKioskAndASecondScreen()
        let store = login.model.store
        _ = try ChangeScreenDeviceIntent.change(login.screen, to: .iPhone, custom: "Kiosk", in: login.model, undoManager: nil)
        let settings = store.tree.settings
        func subtitle(_ id: TreeScreen.ID) throws -> String? {
            let screen = try #require(store.treeScreen(id))
            let entity = ScreenEntity(design: "design", designName: "Design", screen: screen, settings: settings)
            return entity.displayRepresentation.subtitle.map { String(localized: $0) }
        }

        #expect(try subtitle(login.screen) == "Kiosk · Design")
        #expect(try subtitle(second) == "\(DeviceChoice.displayName(of: .iPhone)) · Design")
        // Written out, so that a change to the built-in's Siri name shows here (plan 6, Task 10 review minor 2).
        #expect(try subtitle(second) == "Phone · Design")
        #expect(try subtitle(second) != "iPhone · Design")
    }
}
