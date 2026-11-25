import CoreGraphics
import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

/// Voice's tools act on the tree (plan 6, Task 7): a handle names any node, containers included; a laid-out child is
/// reordered or taken out only when asked (call 8); a look goes to what a group holds, or to a card itself (call 7);
/// a container is deleted whole by its own word; and a device is chosen by name, the design's own included.
///
/// Each test takes the fixture's handles from one capture, as a call does: S1 Login holds E1 the title, E2 the card
/// (E3 "About me", E4 the body), and E5 the row (E6 "Wi-Fi", E7 the toggle); E8 is the sticky note on the canvas.
@MainActor
@Suite("Voice's tools on the tree")
struct VoiceOnTheTreeTests {
    private struct Bench {
        let login: TreeFixture.Login
        let handles: VoiceHandles
        let box: VoiceToolbox
        @MainActor var store: DesignStore { login.model.store }
    }

    /// The fixture, `prepare`d, then captured once for the call's handles, with a toolbox on it.
    private func bench(_ prepare: (TreeFixture.Login) -> Void = { _ in }) -> Bench {
        let login = TreeFixture.loginWithACardAndARow()
        prepare(login)
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: login.model, handles: handles)
        return Bench(login: login, handles: handles, box: VoiceToolbox(model: login.model, handles: handles))
    }

    private static let rowChildLine =
        "E6 is in the row E5, which places it. To change its place in E5, call reorder. To take it out of E5, call moveElement again with takeOut yes and where it goes."

    // MARK: A laid-out child

    @Test func movingARowChildSaysToReorder() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.moveElement(element: "E6", x: "40", y: "600", width: nil, height: nil, takeOut: nil) == Self.rowChildLine)
        #expect(bench.store.tree == before)
        #expect(bench.box.lastFailed)
        // So does a position given with a size: the size alone would be done, and the model would think it was moved.
        #expect(bench.box.moveElement(element: "E6", x: "40", y: nil, width: "120", height: nil, takeOut: "no") == Self.rowChildLine)
        #expect(bench.store.tree == before)
    }

    @Test func takingARowChildOut() throws {
        let bench = bench()
        #expect(bench.box.moveElement(element: "E6", x: "40", y: "600", width: nil, height: nil, takeOut: "yes") == "Took E6 out of E5.")
        let screen = try #require(bench.store.treeScreen(bench.login.screen))
        #expect(screen.root.children.last?.id == bench.login.label)
        #expect(bench.store.ownFrame(bench.login.label) == CGRect(x: 40, y: 600, width: 80, height: 24))
        let label = try #require(bench.store.node(bench.login.label))
        #expect(label.width.mode == .fixed)
        #expect(label.height.mode == .fixed)
        #expect(bench.store.node(bench.login.row)?.children.map(\.id) == [bench.login.toggle])
    }

    @Test func takingOutWithNowhereToGoAsksWhere() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.moveElement(element: "E6", x: nil, y: nil, width: nil, height: nil, takeOut: "yes") == "Say where E6 goes: x and y.")
        #expect(bench.box.moveElement(element: "E6", x: nil, y: nil, width: "120", height: nil, takeOut: "yes") == "Say where E6 goes: x and y.")
        #expect(bench.store.tree == before)
    }

    @Test func resizingARowChildFixesItsWidth() throws {
        let bench = bench()
        let line = bench.box.moveElement(element: "E6", x: nil, y: nil, width: "120", height: nil, takeOut: nil)
        #expect(line == #"Resized the text “Wi-Fi”."#)
        let label = try #require(bench.store.node(bench.login.label))
        #expect(label.width.mode == .fixed)
        #expect(bench.store.ownFrame(bench.login.label)?.width == 120)
        #expect(bench.store.parent(of: bench.login.label) == .node(bench.login.row))
    }

    @Test func aRowChildCanStillTurn() throws {
        let bench = bench()
        let row = try #require(bench.store.node(bench.login.row))
        #expect(bench.box.rotateElement(element: "E6", angle: "20", by: nil) == "Turned E6 to 20°.")
        #expect(bench.store.node(bench.login.label)?.rotation == 20)
        let turned = try #require(bench.store.node(bench.login.row))
        #expect(turned.frame == row.frame)
        #expect(turned.children.map(\.frame) == row.children.map(\.frame))
    }

    @Test func aLaidOutChildCantBeAligned() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.alignElement(element: "E6", alignment: "left")
            == "E6 is in the row E5, which places it. To line things up in E5, call setLayout on E5 with an alignment, such as row centred.")
        #expect(bench.store.tree == before)
    }

    @Test func stackingOrPlacingALaidOutChildSaysToReorder() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.stackElements(elements: "E1, E6", direction: "column") == Self.rowChildLine)
        #expect(bench.box.placeElement(element: "E6", relation: "below", target: "E1") == Self.rowChildLine)
        #expect(bench.store.tree == before)
    }

    /// Several things lined up together: only what is in a free parent moves (spec §10), as the popover's Align does. In
    /// one row, the row's own alignment is what changes.
    @Test func aligningSeveralMovesOnlyWhatIsInAFreeParent() throws {
        let bench = bench()
        let row = try #require(bench.store.node(bench.login.row))
        _ = bench.box.alignElement(element: "E1, E7", alignment: "bottom")
        #expect(!bench.box.lastFailed)
        // The toggle's bottom is the lowest, at 351: the title comes down to it, and the toggle stays in its row.
        #expect(bench.store.ownFrame(bench.login.title)?.maxY == 351)
        #expect(bench.store.parent(of: bench.login.toggle) == .node(bench.login.row))
        #expect(bench.store.node(bench.login.row)?.children.map(\.frame) == row.children.map(\.frame))

        _ = bench.box.alignElement(element: "E6, E7", alignment: "top")
        #expect(!bench.box.lastFailed)
        guard case .stack(let stack)? = bench.store.node(bench.login.row)?.layout else {
            Issue.record("The row is no longer a row")
            return
        }
        #expect(stack.alignment == .start)
        #expect(bench.store.node(bench.login.row)?.children.map(\.id) == [bench.login.label, bench.login.toggle])
    }

    // MARK: Containers

    @Test func aContainerMovesWhole() throws {
        let bench = bench()
        let children = try #require(bench.store.node(bench.login.card)).children.map(\.frame)
        #expect(bench.box.moveElement(element: "E2", x: "30", y: nil, width: nil, height: nil, takeOut: nil) == "Moved the card.")
        #expect(bench.store.ownFrame(bench.login.card)?.minX == 30)
        #expect(bench.store.node(bench.login.card)?.children.map(\.frame) == children)
    }

    @Test func aLookOnAGroupGoesToWhatItHolds() throws {
        let bench = bench()
        let style = try #require(bench.store.node(bench.login.row)).style
        _ = bench.box.styleElement(element: "E5", look: "blue")
        #expect(!bench.box.lastFailed)
        #expect(bench.store.node(bench.login.label)?.style.tint == ColourWords.named["blue"])
        #expect(bench.store.node(bench.login.toggle)?.style.tint == ColourWords.named["blue"])
        #expect(bench.store.node(bench.login.row)?.style == style)
        // One step.
        bench.login.undo.undo()
        #expect(bench.store.node(bench.login.label)?.style.tint == nil)
        #expect(bench.store.node(bench.login.toggle)?.style.tint == nil)
    }

    @Test func aLookOnACardIsTheCards() throws {
        let bench = bench()
        let children = try #require(bench.store.node(bench.login.card)).children
        _ = bench.box.styleElement(element: "E2", look: "#FFEECC, radius 24")
        #expect(!bench.box.lastFailed)
        let card = try #require(bench.store.node(bench.login.card))
        #expect(card.style.tint == RGBColor(hex: 0xFFEECC))
        #expect(card.style.cornerRadius == 24)
        #expect(card.children == children)
    }

    @Test func setTextOnAContainerSaysItHasNoWords() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.setText(element: "E2", text: "Hi") == "E2 is a card, which has no words of its own.")
        #expect(bench.box.setText(element: "E5", text: "Hi") == "E5 is a row, which has no words of its own.")
        #expect(bench.store.tree == before)
    }

    @Test func addingBesideARowChildJoinsTheRow() throws {
        let bench = bench()
        _ = bench.box.addElement(screen: nil, kind: "text", text: "Bluetooth", look: nil, relation: "right of", target: "E6")
        #expect(!bench.box.lastFailed)
        let row = try #require(bench.store.node(bench.login.row))
        #expect(row.children.count == 3)
        #expect(row.children.first?.id == bench.login.label)
        #expect(row.children[1].content.text == "Bluetooth")
        #expect(row.children.last?.id == bench.login.toggle)
    }

    @Test func addingToAColumnScreenAppends() throws {
        var feed: TreeScreen.ID?
        let bench = bench { login in
            let first = LayerNode.leaf(.title, frame: CGRect(x: 0, y: 0, width: 228, height: 40), text: "Today")
            let second = LayerNode.leaf(.body, frame: CGRect(x: 0, y: 0, width: 321, height: 40), text: "Hello world")
            feed = login.model.store.addColumnScreen([first, second], name: "Feed", origin: CGPoint(x: 2000, y: 0))
        }
        let screen = try #require(feed)
        #expect(bench.handles.handle(forScreen: screen) == "S2")
        _ = bench.box.addElement(screen: "S2", kind: "button", text: nil, look: nil, relation: nil, target: nil)
        #expect(!bench.box.lastFailed)
        let root = try #require(bench.store.treeScreen(screen)).root
        #expect(root.children.count == 3)
        #expect(root.children.last?.kind == .button)
    }

    /// A screen's root that lays things out has no free top to take a thing out to (F15).
    @Test func aColumnScreensChildIsReorderedNotTakenOut() throws {
        var feed: TreeScreen.ID?
        let first = LayerNode.leaf(.title, frame: CGRect(x: 0, y: 0, width: 228, height: 40), text: "Today")
        let second = LayerNode.leaf(.body, frame: CGRect(x: 0, y: 0, width: 321, height: 40), text: "Hello world")
        let bench = bench { login in
            feed = login.model.store.addColumnScreen([first, second], name: "Feed", origin: CGPoint(x: 2000, y: 0))
        }
        _ = try #require(feed)
        let handle = bench.handles.handle(forNode: first.id)
        let line = "\(handle) is in the column S2, which places it. To change its place in S2, call reorder."
        let before = bench.store.tree
        #expect(bench.box.moveElement(element: handle, x: "40", y: "600", width: nil, height: nil, takeOut: nil) == line)
        #expect(bench.box.moveElement(element: handle, x: "40", y: "600", width: nil, height: nil, takeOut: "yes") == line)
        #expect(bench.store.tree == before)
    }

    @Test func deletingAContainerNeedsItsWord() {
        let named = bench()
        _ = named.box.deleteElement(element: "E2", named: "card")
        #expect(!named.box.lastFailed)
        #expect(named.store.node(named.login.card) == nil)
        #expect(named.store.node(named.login.about) == nil)
        #expect(named.store.node(named.login.body) == nil)

        let misnamed = bench()
        let before = misnamed.store.tree
        #expect(misnamed.box.deleteElement(element: "E2", named: "button") == "There is no button here. That is the card.")
        #expect(misnamed.store.tree == before)
    }

    /// The selection is told by the word its line and the Layers panel use: a row is a row (Task 6's review).
    @Test func aSelectedContainerIsCalledWhatItIs() {
        let bench = bench()
        let model = bench.login.model
        model.selection = .element(.init(host: .screen(bench.login.screen), element: bench.login.row))
        #expect(CanvasPicture.capture(from: model, handles: bench.handles).selectionInWords == "E5, the row on S1")
        model.selection = .element(.init(host: .screen(bench.login.screen), element: bench.login.card))
        #expect(CanvasPicture.capture(from: model, handles: bench.handles).selectionInWords == "E2, the card on S1")
    }

    // MARK: Devices

    @Test func customDevicesAreChosenByName() throws {
        let kiosk = DeviceFrame.custom(name: "Kiosk", size: CGSize(width: 1080, height: 1920), family: .other)
        let iPadKiosk = DeviceFrame.custom(name: "iPad Kiosk", size: CGSize(width: 1024, height: 1366), family: .tablet)
        let custom = [kiosk, iPadKiosk]
        #expect(VoiceToolbox.device(named: "Kiosk", custom: custom) == kiosk)
        #expect(VoiceToolbox.device(named: "the kiosk screen", custom: custom) == kiosk)
        // A built-in wins over a name the words only contain.
        #expect(VoiceToolbox.device(named: "iPad", custom: custom)?.id == DeviceFrame.named("ipad").id)
        #expect(VoiceToolbox.device(named: "iPad Kiosk", custom: custom) == iPadKiosk)

        let bench = bench { login in
            login.model.store.addCustomDevice(kiosk)
            login.model.store.addCustomDevice(iPadKiosk)
        }
        let made = try #require(bench.store.tree.settings.customDevices.first { $0.name == "Kiosk" })
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "kiosk") == "Made S1 a Kiosk screen (1080 × 1920).")
        #expect(bench.store.treeScreen(bench.login.screen)?.deviceID == made.id)
        // In one step.
        bench.login.undo.undo()
        #expect(bench.store.treeScreen(bench.login.screen)?.deviceID == nil)
        #expect(bench.store.tree.settings.customDevices.count == 2)

        #expect(bench.box.changeScreenDevice(screen: "S1", device: "Wall")
            == "I can make it an iPhone, iPad or Mac screen, or Kiosk, iPad Kiosk, not “Wall”.")
        #expect(bench.box.lastFailed)
    }

    /// A device a file held that can't be one (`DeviceFrame.problems`) is refused by the store: voice says so, rather
    /// than "Made S1 …", and its size is said without trapping.
    @Test func aDeviceThatCantBeUsedIsSaidToBeRefused() {
        let huge = DeviceFrame.custom(name: "Huge", size: CGSize(width: 1e300, height: 1e300), family: .other)
        let bench = bench { login in
            // As a file holds it: one the design is given by hand is refused.
            login.model.store.changeTree(writing: 0) { $0.settings.customDevices.append(huge) }
        }
        let line = bench.box.changeScreenDevice(screen: "S1", device: "Huge")
        #expect(line == "Couldn't make S1 a Huge screen (1000000 × 1000000). Width is 1 to 4,000 points. Height is 1 to 4,000 points.")
        #expect(bench.box.lastFailed)
        #expect(bench.store.treeScreen(bench.login.screen)?.deviceID == nil)
    }

    // MARK: Gone, scoped, and nothing lowered

    @Test func handlesOfGoneThingsSayTheyAreGone() {
        let bench = bench()
        bench.store.delete(nodes: [bench.login.card])
        #expect(bench.box.setText(element: "E3", text: "Hello") == "There is no E3.")
        #expect(bench.box.moveElement(element: "E2", x: "30", y: nil, width: nil, height: nil, takeOut: nil) == "There is no E2.")
    }

    @Test func aScopedEditKeepsToItsScreen() {
        let profileTitle = LayerNode.leaf(.title, frame: CGRect(x: 20, y: 80, width: 228, height: 40), text: "Your profile")
        let bench = bench { login in
            login.model.store.addFreeScreen([profileTitle], name: "Profile", origin: CGPoint(x: 2000, y: 0))
        }
        bench.box.scope = bench.login.screen
        let handle = bench.handles.handle(forNode: profileTitle.id)
        let before = bench.store.tree
        #expect(bench.box.moveElement(element: handle, x: "40", y: "600", width: nil, height: nil, takeOut: nil)
            == "\(handle) isn't on S1 “Login”, the screen this change is for.")
        #expect(bench.store.tree == before)
    }

    private static let supported = "Foundation Models runs models of the app's own from iPadOS 27.2"

    /// A spoken command reads and writes the tree alone: the design is never lowered to its flat list (F18).
    ///
    /// The command is one typed for the screen, which shows nothing it changes: what a tool shows goes through
    /// `DesignActions.reveal`, Siri's, which reads the tree from plan 6's Task 3, in lane B, and the flat list before it.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandLowersNothing() async throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        // Out of its file and out of the open designs. Spotlight's indexing of a design in a file a few seconds after it
        // changes, and what other suites ask Siri of every open design, both snapshot it (`DesignActions.snapshot`),
        // which reads the flat list until plan 6's Task 3 (lane B). Either can land while the command awaits its model.
        // Only the command's own work is counted (F17, F18).
        login.model.fileURL = nil
        OpenDesigns.shared.closed(login.model)
        // The counter is live: a change through a tree verb, then a read of the flat list, lowers the design once.
        store.update(login.title) { $0.content.text = "Hello" }
        let live = TreeProjection.lowerings(of: login.screen)
        _ = store.screens
        #expect(TreeProjection.lowerings(of: login.screen) - live == 1)

        store.update(login.title) { $0.content.text = "Welcome" }
        let agent = VoiceAgent(model: login.model, testModel: ScriptedLanguageModel(script: [
            "make the wi-fi row blue": [
                ScriptedLanguageModel.Step(tool: "styleElement", arguments: #"{"element":"E5","look":"blue"}"#),
                ScriptedLanguageModel.Step(tool: "moveElement", arguments: #"{"element":"E2","x":"30"}"#),
            ],
        ]))
        let before = TreeProjection.lowerings(of: login.screen)
        let outcome = await agent.run("Make the Wi-Fi row blue", about: .screenEdit(login.screen))
        #expect(outcome.problem == nil)
        #expect(TreeProjection.lowerings(of: login.screen) - before == 0)
        #expect(store.node(login.label)?.style.tint == ColourWords.named["blue"])
        #expect(store.ownFrame(login.card)?.minX == 30)
    }
}
