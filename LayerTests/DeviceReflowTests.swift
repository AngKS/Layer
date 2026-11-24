import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The iPad the tests move screens to: 820 × 1180, margin 32. The iPhone is 393 × 852, margin 20.
private let iPad = DeviceFrame.named("ipad")

/// A node of `kind` at `frame`, fixed both ways.
private func node(_ frame: CGRect, _ kind: ElementKind = .button) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    return node
}

/// The frames `DeviceReflow` gives `children` of a free root going from `old` to `new`.
private func reflowed(_ children: [LayerNode], from old: DeviceFrame = .iPhone, to new: DeviceFrame = iPad) -> [UUID: CGRect] {
    var root = LayerNode(kind: .group)
    root.frame = CGRect(origin: .zero, size: old.size)
    root.children = children
    return DeviceReflow.frames(for: root, from: old, to: new)
}

/// A free screen on `deviceID` holding `children`.
private func freeScreen(_ children: [LayerNode], on deviceID: String? = nil) -> TreeScreen {
    var screen = TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: deviceID)
    screen.root.children = children
    return screen
}

/// An app showing `screens`, laid out as a file read lays them out, with an undo history of its own.
@MainActor
private func makeModel(_ screens: [TreeScreen], devices: [DeviceFrame] = []) -> (model: AppModel, undo: UndoManager) {
    var tree = TreeContent()
    tree.settings.customDevices = devices
    tree.screens = screens
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    return (model, undo)
}

/// A device change follows each thing's placement intent on a free screen, and lays a column screen out again: the
/// same from the device picker, Siri and voice, and when a device of the design's own is edited (spec §5, plan 5's
/// call 9, pre-flight F3).
@Suite("Device changes by placement intent")
@MainActor
struct DeviceReflowTests {
    // MARK: - Each intent, iPhone to iPad

    @Test func leadingKeepsItsLeftInset() {
        let leading = node(CGRect(x: 20, y: 300, width: 170, height: 120))
        #expect(reflowed([leading]).isEmpty, "what doesn't move isn't listed")
    }

    @Test func trailingKeepsItsRightInset() {
        let trailing = node(CGRect(x: 203, y: 300, width: 170, height: 120))
        #expect(reflowed([trailing]) == [trailing.id: CGRect(x: 630, y: 300, width: 170, height: 120)])
    }

    @Test func centredStaysCentred() {
        let centred = node(CGRect(x: 96, y: 80, width: 200, height: 40))
        #expect(reflowed([centred]) == [centred.id: CGRect(x: 310, y: 80, width: 200, height: 40)])
    }

    @Test func proportionalScalesItsXAndWidth() throws {
        var wide = node(CGRect(x: 20, y: 700, width: 353, height: 50))
        let onIPad = try #require(reflowed([wide])[wide.id])
        #expect(onIPad == CGRect(x: 42, y: 700, width: 737, height: 50))
        wide.frame = onIPad
        #expect(reflowed([wide], from: iPad, to: .iPhone)[wide.id] == CGRect(x: 20, y: 700, width: 353, height: 50))
    }

    @Test func fixedStaysPut() {
        #expect(reflowed([node(CGRect(x: 230, y: 400, width: 51, height: 31))]).isEmpty)
    }

    /// `fixedStaysPut`'s frame, saved as drawn at the trailing edge: its right inset is kept.
    @Test func aSavedIntentWinsOverTheFrame() {
        var saved = node(CGRect(x: 230, y: 400, width: 51, height: 31))
        saved.sketch = LayerNode.SketchIntent(originalBounds: saved.frame, normalizedBounds: .zero, confidence: 1,
                                              decidedBy: .rules, placement: .trailing)
        #expect(reflowed([saved]) == [saved.id: CGRect(x: 657, y: 400, width: 51, height: 31)])
    }

    @Test func lockedStaysPut() {
        var locked = node(CGRect(x: 203, y: 300, width: 170, height: 120))
        locked.isLocked = true
        #expect(reflowed([locked]).isEmpty)
    }

    /// A proportional node stood on end moves its centre with the screen's width, and keeps its size and its angle.
    @Test func aTurnedNodeKeepsItsSize() throws {
        var turned = node(CGRect(x: 20, y: 700, width: 353, height: 50))
        turned.rotation = 90
        let screen = freeScreen([turned])
        let (model, _) = makeModel([screen])

        model.store.changeDevice(of: screen.id, to: iPad)

        let after = try #require(model.store.node(turned.id))
        #expect(after.frame.size == CGSize(width: 353, height: 50))
        #expect(after.rotation == 90)
        #expect(abs(after.frame.midX - 196.5 * 820 / 393) <= 0.5, "its centre moves by the screen's ratio")
        #expect(CGRect(origin: .zero, size: iPad.size).contains(TurnedRect(rect: after.frame, degrees: 90).bounds))
    }

    // MARK: - iPad to iPhone

    @Test func goingSmallerClampsButFixedOverhangs() throws {
        let leading = node(CGRect(x: 40, y: 100, width: 500, height: 60), .image)
        let fixed = node(CGRect(x: 500, y: 300, width: 100, height: 100), .image)
        #expect(reflowed([leading, fixed], from: iPad, to: .iPhone) == [leading.id: CGRect(x: 0, y: 100, width: 500, height: 60)])

        let screen = freeScreen([leading, fixed], on: iPad.id)
        let (model, _) = makeModel([screen])
        model.store.changeDevice(of: screen.id, to: .iPhone)

        let root = try #require(model.store.treeScreen(screen.id)?.root)
        #expect(root.children.map(\.frame) == [CGRect(x: 0, y: 100, width: 500, height: 60),
                                               CGRect(x: 500, y: 300, width: 100, height: 100)])
        #expect(TreeValidator.check(root, on: .iPhone).contains(TreeValidator.Issue(node: fixed.id, kind: .clipped)))
    }

    // MARK: - A column screen

    @Test func aColumnScreenIsLaidOutAgain() throws {
        var filling = node(CGRect(x: 0, y: 0, width: 100, height: 50))
        filling.width = LayerNode.Sizing(.fill(weight: 1))
        var screen = TreeScreen(name: "Column", origin: .zero, scale: 1, deviceID: nil)
        screen.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12))
        screen.root.children = [filling]
        let (model, _) = makeModel([screen])

        model.store.changeDevice(of: screen.id, to: iPad)

        let root = try #require(model.store.treeScreen(screen.id)?.root)
        #expect(model.store.treeScreen(screen.id)?.deviceID == "ipad")
        #expect(root.frame == CGRect(x: 0, y: 0, width: 820, height: 1180))
        let laid = try #require(root.children.first)
        #expect(laid.frame.minX == 32)
        #expect(laid.frame.width == 756)
    }

    // MARK: - One step, every path

    @Test func aDeviceChangeIsOneUndoStep() throws {
        let screen = freeScreen(Self.things())
        let (model, undo) = makeModel([screen])
        let before = try #require(model.store.treeScreen(screen.id))

        model.store.changeDevice(of: screen.id, to: iPad)
        #expect(model.store.treeScreen(screen.id)?.root.children.map(\.frame) == Self.onIPad)
        #expect(model.store.treeScreen(screen.id)?.deviceID == "ipad")

        undo.undo()
        #expect(model.store.treeScreen(screen.id) == before)
        #expect(!undo.canUndo)
    }

    @Test func everyPathChangesTheDeviceTheSameWay() async throws {
        // The device picker's: plan 4's `DevicePicker` calls `setDevice(of:to:)`.
        let pickedScreen = freeScreen(Self.things())
        let picked = makeModel([pickedScreen])
        picked.model.store.setDevice(of: pickedScreen.id, to: "ipad")

        // Siri's, on a design open in its window.
        let askedScreen = freeScreen(Self.things())
        let asked = makeModel([askedScreen])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        asked.model.fileURL = folder.appendingPathComponent("Reflow.layer")
        defer { asked.model.close() }
        let intent = ChangeScreenDeviceIntent()
        intent.screen = try #require(DesignActions.snapshot(of: asked.model)?.screens.first { $0.screenID == askedScreen.id })
        intent.device = .iPad
        _ = try await intent.perform()

        // Voice's.
        let spokenScreen = freeScreen(Self.things())
        let spoken = makeModel([spokenScreen])
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: spoken.model, handles: handles)
        let line = VoiceToolbox(model: spoken.model, handles: handles).changeScreenDevice(screen: "S1", device: "iPad")
        #expect(line == "Made S1 an iPad screen (820 × 1180).")

        for ((model, undo), id) in [(picked, pickedScreen.id), (asked, askedScreen.id), (spoken, spokenScreen.id)] {
            let changed = try #require(model.store.treeScreen(id))
            #expect(changed.deviceID == "ipad")
            #expect(changed.root.children.map(\.frame) == Self.onIPad)
            undo.undo()
            #expect(model.store.treeScreen(id)?.deviceID == nil)
            #expect(model.store.treeScreen(id)?.root.children.map(\.frame) == Self.things().map(\.frame))
            #expect(!undo.canUndo, "one step")
        }
    }

    /// Editing a device of the design's own changes the size of every screen on it, and each free one's contents
    /// follow their intents from the device's old size, in the edit's one step (F3).
    @Test func editingACustomDeviceReflowsItsFreeScreens() throws {
        let board = DeviceFrame.custom(name: "Board", size: CGSize(width: 393, height: 852), family: .phone)
        let trailing = node(CGRect(x: 203, y: 300, width: 170, height: 120))
        let screen = freeScreen([trailing], on: board.id)
        let (model, undo) = makeModel([screen], devices: [board])
        var draft = CustomDeviceDraft(from: board, named: board.name)
        draft.width = 820
        draft.height = 1180
        let edited = try #require(draft.device(id: board.id))

        model.store.updateCustomDevice(edited)

        #expect(model.store.treeScreen(screen.id)?.root.frame.size == CGSize(width: 820, height: 1180))
        #expect(model.store.node(trailing.id)?.frame == CGRect(x: 630, y: 300, width: 170, height: 120))
        undo.undo()
        #expect(model.store.tree.settings.customDevices == [board])
        #expect(model.store.node(trailing.id)?.frame == CGRect(x: 203, y: 300, width: 170, height: 120))
        #expect(!undo.canUndo, "one step")
    }

    // MARK: - Fixtures

    /// Trailing, centred, proportional, leading and fixed, on an iPhone screen. New ids each time.
    private static func things() -> [LayerNode] {
        [CGRect(x: 203, y: 300, width: 170, height: 120), CGRect(x: 96, y: 80, width: 200, height: 40),
         CGRect(x: 20, y: 700, width: 353, height: 50), CGRect(x: 20, y: 500, width: 170, height: 120),
         CGRect(x: 230, y: 400, width: 51, height: 31)].map { node($0) }
    }

    /// Where `things()` go on an iPad.
    private static let onIPad = [
        CGRect(x: 630, y: 300, width: 170, height: 120), CGRect(x: 310, y: 80, width: 200, height: 40),
        CGRect(x: 42, y: 700, width: 737, height: 50), CGRect(x: 20, y: 500, width: 170, height: 120),
        CGRect(x: 230, y: 400, width: 51, height: 31),
    ]
}
