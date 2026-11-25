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

    /// One thing in a row is lined up by the row's alignment, as the Format panel's Align does (2026-11-26): an alignment
    /// the row has a use for is set on it, as one step, and the reply says what the person sees change; one along the row
    /// changes nothing, and the refusal names the row and the alignments it takes, for one child or two.
    @Test func aLaidOutChildIsAlignedByItsRow() throws {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.alignElement(element: "E6", alignment: "bottom") == "Aligned E5's contents to the bottom.")
        #expect(!bench.box.lastFailed)
        #expect(bench.store.node(bench.login.row)?.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .end)))
        #expect(bench.store.parent(of: bench.login.label) == .node(bench.login.row))
        bench.login.undo.undo()
        #expect(bench.store.tree == before)
        #expect(!bench.login.undo.canUndo)

        let rowTakes = "which aligns what it holds only to the top, vertical centre or bottom."
        #expect(bench.box.alignElement(element: "E6", alignment: "left") == "E6 is in the row E5, \(rowTakes)")
        #expect(bench.box.lastFailed)
        #expect(bench.box.alignElement(element: "E6, E7", alignment: "right") == "E6 and E7 are in the row E5, \(rowTakes)")
        #expect(bench.box.lastFailed)
        #expect(bench.store.tree == before)
    }

    /// A screen whose root lays out a column: one thing on it is lined up by the column's alignment, which the reply
    /// names by the screen's handle, and top, middle and bottom are along the column.
    @Test func aLaidOutScreensChildIsAlignedByItsColumn() throws {
        let bench = bench { login in
            let root = login.model.store.treeScreen(login.screen)?.root.id
            root.map { login.model.store.setLayout($0, .stack(LayerNode.Stack(axis: .vertical, spacing: 24))) }
            login.undo.removeAllActions()
        }
        let root = try #require(bench.store.treeScreen(bench.login.screen)?.root.id)
        let before = bench.store.tree
        #expect(bench.box.alignElement(element: "E1", alignment: "top")
            == "E1 is in the column S1, which aligns what it holds only to the left, centre or right.")
        #expect(bench.store.tree == before)

        #expect(bench.box.alignElement(element: "E1", alignment: "centre") == "Aligned S1's contents to the centre.")
        #expect(bench.store.node(root)?.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 24, alignment: .center)))
        bench.login.undo.undo()
        #expect(bench.store.tree == before)
        #expect(!bench.login.undo.canUndo)
    }

    /// `placeElement` towards an edge of the screen is an align ("an edge is what was meant"), so a row's child follows
    /// the one rule there too (Ruling 6, 2026-11-26): the row's alignment, as one step, or, along the row, a refusal
    /// naming what the row takes. So does a placement by another thing that the person didn't ask for, which the
    /// on-device model makes of "move it down"; asked for one, it is a place, which the row gives.
    @Test func placingARowChildAtAnEdgeAlignsTheRow() throws {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.placeElement(element: "E6", relation: "above", target: "S1") == "Aligned E5's contents to the top.")
        #expect(bench.store.node(bench.login.row)?.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .start)))
        #expect(bench.store.parent(of: bench.login.label) == .node(bench.login.row))
        bench.login.undo.undo()
        #expect(bench.store.tree == before)
        #expect(!bench.login.undo.canUndo)

        #expect(bench.box.placeElement(element: "E6", relation: "left of", target: "S1")
            == "E6 is in the row E5, which aligns what it holds only to the top, vertical centre or bottom.")
        #expect(bench.box.lastFailed)
        #expect(bench.store.tree == before)

        // "Move the Wi-Fi label down" names no other thing to go by: E1 as the target is taken as the bottom edge.
        bench.box.spokenCommand = "Move the Wi-Fi label down"
        #expect(bench.box.placeElement(element: "E6", relation: "below", target: "E1") == "Aligned E5's contents to the bottom.")
        #expect(bench.store.node(bench.login.row)?.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .end)))
        bench.login.undo.undo()
        #expect(bench.store.tree == before)
        #expect(!bench.login.undo.canUndo)

        bench.box.spokenCommand = "Put the Wi-Fi label below the title"
        #expect(bench.box.placeElement(element: "E6", relation: "below", target: "E1") == Self.rowChildLine)
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
        model.selection = .element(.init(host: .screen(bench.login.screen), node: bench.login.row))
        #expect(CanvasPicture.capture(from: model, handles: bench.handles).selectionInWords == "E5, the row on S1")
        model.selection = .element(.init(host: .screen(bench.login.screen), node: bench.login.card))
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

    /// A file's device that can't be one (`DeviceFrame.problems`), reached by its name or as the design's New Screens
    /// device, makes no screen, and voice says so rather than "Made the screen …" (review I1).
    @Test func aNewScreenOnADeviceThatCantBeUsedIsRefused() async throws {
        let huge = DeviceFrame.custom(name: "Huge", size: CGSize(width: 1e300, height: 1e300), family: .other)
        let bench = bench { login in
            login.model.store.changeTree(writing: 0) { $0.settings.customDevices.append(huge) }
        }
        let line = "Couldn't make a Huge screen (1000000 × 1000000). Width is 1 to 4,000 points. Height is 1 to 4,000 points."
        #expect(try await bench.box.createScreen(name: "Shop", description: "a shop", device: "Huge") == line)
        #expect(bench.box.lastFailed)
        // By the person's own words, when the model names no device.
        bench.box.spokenCommand = "a shop screen on the huge"
        #expect(try await bench.box.createScreen(name: "Shop", description: "a shop", device: nil) == line)
        // As the device new screens are made on.
        bench.box.spokenCommand = nil
        bench.store.changeTree(writing: 0) { $0.settings.sketchDeviceID = huge.id }
        #expect(try await bench.box.createScreen(name: "Shop", description: "a shop", device: nil) == line)
        #expect(bench.store.tree.screens.count == 1)
        #expect(bench.login.model.generation == nil)
    }

    @Test func aNewScreenIsMadeOnTheDesignsOwnDeviceByName() async throws {
        let kiosk = DeviceFrame.custom(name: "Kiosk", size: CGSize(width: 1080, height: 1920), family: .other)
        let bench = bench { $0.model.store.addCustomDevice(kiosk) }
        let made = try #require(bench.store.tree.settings.customDevices.first)
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        bench.login.model.screenStream = { _ in stream }
        // Written in full before it starts: the screen it makes is there, on its device, once it has finished.
        feed.yield(.screen(Outline.parse("title: Shop\n", isComplete: true)))
        feed.finish()
        let line = try await bench.box.createScreen(name: "Shop", description: "a shop", device: "the kiosk")
        #expect(!bench.box.lastFailed, "\(line)")
        #expect(bench.store.tree.screens.last?.name == "Shop")
        #expect(bench.store.tree.screens.last?.deviceID == made.id)
    }

    // MARK: A container's size (review M1): as the Format panel's W and H

    @Test func aContainersWidthOrHeightScalesItInProportion() throws {
        let bench = bench()
        #expect(bench.box.moveElement(element: "E2", x: nil, y: nil, width: "706", height: nil, takeOut: nil) == "Resized the card.")
        #expect(bench.store.ownFrame(bench.login.card) == CGRect(x: 20, y: 140, width: 706, height: 320))
        #expect(bench.store.node(bench.login.about)?.frame.size == CGSize(width: 400, height: 48))

        let tall = self.bench()
        _ = tall.box.moveElement(element: "E2", x: nil, y: nil, width: nil, height: "320", takeOut: nil)
        #expect(tall.store.ownFrame(tall.login.card) == CGRect(x: 20, y: 140, width: 706, height: 320))
    }

    /// Given both, the width decides, as the panel's fields do: a width as it is with a new height changes nothing.
    @Test func aContainersWidthAsItIsWithANewHeightChangesNothing() {
        let bench = bench()
        let before = bench.store.tree
        _ = bench.box.moveElement(element: "E2", x: nil, y: nil, width: "353", height: "200", takeOut: nil)
        #expect(bench.store.tree == before)
    }

    /// A row in a free parent is scaled in proportion too, and fixed on both axes, as the panel fixes it.
    @Test func aRowResizedInAFreeParentIsScaledAndFixedBothWays() throws {
        let bench = bench()
        _ = bench.box.moveElement(element: "E5", x: nil, y: nil, width: "286", height: nil, takeOut: nil)
        let row = try #require(bench.store.node(bench.login.row))
        #expect(row.width.mode == .fixed)
        #expect(row.height.mode == .fixed)
        #expect(bench.store.ownFrame(bench.login.row)?.size == CGSize(width: 286, height: 62))
        #expect(row.children.map(\.id) == [bench.login.label, bench.login.toggle])
    }

    // MARK: Width words (review M4)

    /// "Make the row full width" stretches the row, not what it holds.
    @Test func aWidthWordGoesToTheContainerNamed() throws {
        let first = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 80, height: 24), text: "Wi-Fi")
        let second = LayerNode.leaf(.toggle, frame: CGRect(x: 0, y: 0, width: 51, height: 31))
        let row = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 12)), children: [first, second])
        let bench = bench { login in
            login.model.store.addColumnScreen([row], name: "Settings", origin: CGPoint(x: 2000, y: 0))
        }
        let handle = bench.handles.handle(forNode: row.id)
        #expect(bench.box.styleElement(element: handle, look: "full width") == "Restyled the row.")
        let styled = try #require(bench.store.node(row.id))
        #expect(styled.width.mode == .fill(weight: 1))
        #expect(styled.children.map(\.width.mode) == [.fixed, .fixed])
        #expect(bench.store.ownFrame(row.id)?.width == 353)
    }

    /// A width word where it changes nothing is said so, and isn't kept: on a leaf in a free parent, and fill on a
    /// container in one. The rest of the look still goes on.
    @Test func aWidthWordWhereItChangesNothingIsSaidSo() throws {
        let bench = bench()
        let before = bench.store.tree
        let leaf = "E1 isn't in a row, column or grid, so fill and fit don't apply to it. To change its width, call moveElement with a width."
        #expect(bench.box.styleElement(element: "E1", look: "full width") == leaf)
        #expect(bench.box.lastFailed)
        #expect(bench.box.styleElement(element: "E5", look: "fill")
            == "E5 isn't in a row, column or grid, so fill doesn't apply to it. To change its width, call moveElement with a width.")
        #expect(bench.store.tree == before)

        #expect(bench.box.styleElement(element: "E1", look: "blue, full width") == "Restyled the title “Welcome”. " + leaf)
        let title = try #require(bench.store.node(bench.login.title))
        #expect(title.style.tint == ColourWords.named["blue"])
        #expect(title.width.mode == .fixed)

        // A container's fit is as wide as what it holds, wherever it is.
        _ = bench.box.styleElement(element: "E2", look: "fit")
        #expect(bench.store.node(bench.login.card)?.width.mode == .fit)
    }

    // MARK: Taking out, adding and looks: the other outcomes (review M7)

    /// The frame's middle falls in its own row, past the toggle: it goes there, after the toggle.
    @Test func takingOutIntoItsOwnRowMovesItThere() throws {
        let bench = bench()
        #expect(bench.box.moveElement(element: "E6", x: "112", y: "324", width: nil, height: nil, takeOut: "yes")
            == "Moved E6 to another place in E5.")
        #expect(bench.store.node(bench.login.row)?.children.map(\.id) == [bench.login.toggle, bench.login.label])
    }

    @Test func takingOutToWhereItIsChangesNothing() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.moveElement(element: "E6", x: "20", y: "324", width: nil, height: nil, takeOut: "yes") == "E6 is there already.")
        #expect(!bench.box.lastFailed)
        #expect(bench.store.tree == before)
    }

    /// In a row on a column screen, a frame that falls nowhere it could go is refused: the column has no free top to
    /// take it out to.
    @Test func takingOutWhereThereIsNowhereToGoIsRefused() {
        let first = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 80, height: 24), text: "Wi-Fi")
        let second = LayerNode.leaf(.toggle, frame: CGRect(x: 0, y: 0, width: 51, height: 31))
        let row = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 12)), children: [first, second])
        let bench = bench { login in
            login.model.store.addColumnScreen([row], name: "Settings", origin: CGPoint(x: 2000, y: 0))
        }
        let handle = bench.handles.handle(forNode: first.id), holder = bench.handles.handle(forNode: row.id)
        let before = bench.store.tree
        #expect(bench.box.moveElement(element: handle, x: "40", y: "5000", width: nil, height: nil, takeOut: "yes")
            == "\(handle) is in the row \(holder), which places it. To change its place in \(holder), call reorder.")
        #expect(bench.store.tree == before)
    }

    @Test func addingLeftOfOrAboveARowChildPutsItBefore() throws {
        let left = bench()
        _ = left.box.addElement(screen: nil, kind: "text", text: "Bluetooth", look: nil, relation: "left of", target: "E6")
        let leftRow = try #require(left.store.node(left.login.row))
        #expect(leftRow.children.map(\.content.text) == ["Bluetooth", "Wi-Fi", ""])

        let above = bench()
        _ = above.box.addElement(screen: nil, kind: "text", text: "Bluetooth", look: nil, relation: "above", target: "E7")
        let aboveRow = try #require(above.store.node(above.login.row))
        #expect(aboveRow.children.first?.id == above.login.label)
        #expect(aboveRow.children[1].content.text == "Bluetooth")
        #expect(aboveRow.children.last?.id == above.login.toggle)
    }

    /// A row that holds nothing has nothing to take a look: said so, not "Restyled".
    @Test func aLookOnAnEmptyRowSaysNothingChanged() {
        let empty = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 12)),
                                        frame: CGRect(x: 20, y: 500, width: 0, height: 0), children: [])
        let bench = bench { login in
            login.model.store.add(empty, to: .screen(login.screen))
        }
        let handle = bench.handles.handle(forNode: empty.id)
        let before = bench.store.tree
        #expect(bench.box.styleElement(element: handle, look: "blue") == "\(handle) holds nothing, so nothing was restyled.")
        #expect(bench.box.lastFailed)
        #expect(bench.store.tree == before)
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

    /// A spoken command reads and writes the tree (F18). Its check that the design was never lowered to the flat list
    /// went with the list (plan 6, Task 11, clause (s)).
    ///
    /// The command is one typed for the screen, which shows nothing it changes.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandWorksOnTheTree() async throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        // Out of its file and out of the open designs, so that nothing else reads it while the command awaits its model
        // (F17).
        login.model.fileURL = nil
        OpenDesigns.shared.closed(login.model)
        let agent = VoiceAgent(model: login.model, testModel: ScriptedLanguageModel(script: [
            "make the wi-fi row blue": [
                ScriptedLanguageModel.Step(tool: "styleElement", arguments: #"{"element":"E5","look":"blue"}"#),
                ScriptedLanguageModel.Step(tool: "moveElement", arguments: #"{"element":"E2","x":"30"}"#),
            ],
        ]))
        let outcome = await agent.run("Make the Wi-Fi row blue", about: .screenEdit(login.screen))
        #expect(outcome.problem == nil)
        #expect(store.node(login.label)?.style.tint == ColourWords.named["blue"])
        #expect(store.ownFrame(login.card)?.minX == 30)
    }

    /// The same command said to the whole canvas, not typed for one screen: each tool shows what it changed, selecting it
    /// through `DesignActions.reveal`, which reads the tree (plan 6, Task 7 review M5). Its check that nothing lowered the
    /// design went with the flat list (Task 11, clause (s)).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandToTheWholeCanvasWorksOnTheTree() async throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        // Out of its file and out of the open designs, as above (F17).
        login.model.fileURL = nil
        OpenDesigns.shared.closed(login.model)
        let agent = VoiceAgent(model: login.model, testModel: ScriptedLanguageModel(script: [
            "make the wi-fi row blue": [
                ScriptedLanguageModel.Step(tool: "styleElement", arguments: #"{"element":"E5","look":"blue"}"#),
                ScriptedLanguageModel.Step(tool: "moveElement", arguments: #"{"element":"E2","x":"30"}"#),
            ],
        ]))
        let outcome = await agent.run("Make the Wi-Fi row blue")
        #expect(outcome.problem == nil)
        #expect(store.node(login.label)?.style.tint == ColourWords.named["blue"])
        #expect(store.ownFrame(login.card)?.minX == 30)
        // What the last tool changed is shown, and so selected: the card it moved.
        #expect(login.model.selection == .element(NodeRef(host: .screen(login.screen), node: login.card)))
    }
}
