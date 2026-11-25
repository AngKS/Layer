import CoreGraphics
import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

/// Voice's structure tools (plan 6, Task 8): `groupElements` puts things in a new group, row, column, grid or card;
/// `setLayout` changes how a container or a screen lays out what it holds; `ungroup` takes one apart, leaving what it held
/// where it is; and `reorder` changes a thing's place among those it shares a parent with.
///
/// Each test takes the handles from one capture, as a call does: S1 Login holds E1 the title, E2 the card (E3 "About me",
/// E4 the body), E5 the row (E6 "Wi-Fi", E7 the toggle), and E8 and E9 the texts "Terms" and "Privacy" below it; E10 is
/// the sticky note on the canvas, so the first container a tool makes is E11.
@MainActor
@Suite("Voice's structure tools")
struct NewVoiceToolsTests {
    private struct Bench {
        let login: TreeFixture.Login
        let x: UUID
        let y: UUID
        let handles: VoiceHandles
        let box: VoiceToolbox
        @MainActor var store: DesignStore { login.model.store }
        @MainActor var root: LayerNode? { store.treeScreen(login.screen)?.root }
    }

    /// The fixture and its two texts, `prepare`d, then captured once for the call's handles, with a toolbox on it. What
    /// `prepare` does is no step.
    private func bench(_ prepare: (TreeFixture.Login, UUID, UUID) -> Void = { _, _, _ in }) -> Bench {
        let (login, x, y) = TreeFixture.loginWithTwoTexts()
        prepare(login, x, y)
        login.undo.removeAllActions()
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: login.model, handles: handles)
        return Bench(login: login, x: x, y: y, handles: handles, box: VoiceToolbox(model: login.model, handles: handles))
    }

    // MARK: groupElements

    /// The 20-point gap ties 16 and 24, and the smaller wins; the texts line up on every edge, and start wins (plan 4,
    /// call 8). The brief's line names the row E10: the fixture's sticky note has that handle, so the row is E11.
    @Test func groupingTwoTextsAsARow() throws {
        let bench = bench()
        #expect(bench.box.groupElements(elements: "E8, E9", as: "row") == "Put E8 and E9 in a row, E11.")
        let row = try #require(bench.root?.children.last)
        #expect(row.kind == .group)
        #expect(row.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 16, alignment: .start)))
        #expect(row.children.map(\.id) == [bench.x, bench.y])
        #expect(row.children.allSatisfy { $0.width.mode == .fixed && $0.height.mode == .fixed })
        #expect(bench.store.ownFrame(bench.x)?.origin == CGPoint(x: 20, y: 400))
        // Made as the popover's Group as makes one, and selected, so that "it" means it next.
        #expect(bench.login.model.selection == .element(DesignStore.ElementRef(host: .screen(bench.login.screen), element: row.id)))
    }

    @Test func threeAreListedAsNamed() {
        let bench = bench()
        #expect(bench.box.groupElements(elements: "E1, E8, E9", as: "column") == "Put E1, E8 and E9 in a column, E11.")
    }

    @Test func aCardCanHoldOne() throws {
        let bench = bench()
        #expect(bench.box.groupElements(elements: "E1", as: "card") == "Put E1 in a card, E11.")
        guard case .node(let id)? = bench.store.parent(of: bench.login.title) else {
            Issue.record("The title isn't in a container")
            return
        }
        let card = try #require(bench.store.node(id))
        #expect(card.kind == .card)
        #expect(card.children.map(\.id) == [bench.login.title])
    }

    @Test func thingsOfTwoParentsArentGrouped() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.groupElements(elements: "E1, E3", as: "row") == "E1 and E3 aren't in the same place, so they can't be grouped.")
        #expect(bench.store.tree == before)
        #expect(bench.box.lastFailed)
    }

    @Test func anUnknownShapeIsRefused() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.groupElements(elements: "E8, E9", as: "pile") == "I can group them as a group, row, column, grid or card, not “pile”.")
        #expect(bench.store.tree == before)
    }

    @Test func tooFewOrLockedAreRefused() {
        let bench = bench { login, x, _ in login.model.store.update(x) { $0.isLocked = true } }
        let before = bench.store.tree
        #expect(bench.box.groupElements(elements: "E9", as: "row") == "Name two or more elements to group.")
        #expect(bench.box.groupElements(elements: "E8, E9", as: "row") == "E8 is locked.")
        #expect(bench.store.tree == before)
    }

    // MARK: setLayout

    @Test func aCardBecomesAColumn() throws {
        let bench = bench()
        #expect(bench.box.setLayout(target: "E2", layout: "column", spacing: "12") == "E2 is now a column, spacing 12.")
        let card = try #require(bench.store.node(bench.login.card))
        #expect(card.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 12)))
        #expect(card.children.map(\.id) == [bench.login.about, bench.login.body])
        #expect(card.children.allSatisfy { $0.width.mode == .fixed && $0.height.mode == .fixed })
        #expect(bench.store.ownFrame(bench.login.about)?.size == CGSize(width: 200, height: 24))
        #expect(bench.store.ownFrame(bench.login.body)?.size == CGSize(width: 321, height: 40))
    }

    @Test func spacingAloneKeepsTheLayout() {
        let bench = bench()
        #expect(bench.box.setLayout(target: "E5", layout: nil, spacing: "24") == "E5's spacing is now 24.")
        #expect(bench.store.node(bench.login.row)?.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 24, alignment: .center)))
        // 80 + 24 + 51.
        #expect(bench.store.ownFrame(bench.login.row)?.width == 155)
    }

    @Test func aScreenIsFreeOrAColumn() throws {
        let refused = bench()
        let before = refused.store.tree
        #expect(refused.box.setLayout(target: "S1", layout: "row", spacing: nil) == "A screen can be free or a column, not a row.")
        #expect(refused.store.tree == before)

        let bench = bench()
        let root = try #require(bench.root)
        let grouped = TreeEdit.groupedLayout(of: root.children, as: .column, rhythm: bench.store.tree.settings.tokens.rhythm)
        guard case .stack(let stack) = grouped else {
            Issue.record("Group as Column gave no column")
            return
        }
        let words = try #require(CanvasPicture.words(for: grouped))
        #expect(words.hasPrefix("column, spacing \(Int(stack.spacing))"))
        #expect(bench.box.setLayout(target: "S1", layout: "column", spacing: nil) == "S1 is now a \(words).")
        #expect(bench.root?.layout == grouped)
        #expect(stack.axis == .vertical)
        #expect(bench.store.tree.settings.tokens.rhythm.contains(stack.spacing))
    }

    @Test func gridColumnsComeFromTheWords() {
        let bench = bench()
        func columns() -> Int? {
            if case .grid(let grid)? = bench.store.node(bench.login.card)?.layout { grid.columns } else { nil }
        }
        #expect(bench.box.setLayout(target: "E2", layout: "grid of 3", spacing: nil) == "E2 is now a grid of 3, spacing 8.")
        #expect(columns() == 3)
        _ = bench.box.setLayout(target: "E2", layout: "grid of 20", spacing: nil)
        #expect(columns() == 12)
        _ = bench.box.setLayout(target: "E2", layout: "grid 3", spacing: nil)
        #expect(columns() == 3)
        _ = bench.box.setLayout(target: "E2", layout: "grid of two", spacing: nil)
        #expect(columns() == 2)
        #expect(!bench.box.lastFailed)
    }

    @Test func alignmentWordsAreRead() {
        let bench = bench()
        _ = bench.box.setLayout(target: "E2", layout: "column centred", spacing: nil)
        if case .stack(let stack)? = bench.store.node(bench.login.card)?.layout {
            #expect(stack.alignment == .center)
        } else {
            Issue.record("The card isn't a column")
        }
        _ = bench.box.setLayout(target: "E5", layout: "row stretched", spacing: nil)
        #expect(bench.store.node(bench.login.row)?.layout == .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .fill)))
        // An alignment alone keeps the layout.
        #expect(bench.box.setLayout(target: "E5", layout: "bottom", spacing: nil) == "E5 is now a row, spacing 12, bottom.")
    }

    @Test func badWordsAreRefused() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.setLayout(target: "E5", layout: nil, spacing: "-4") == "I didn't understand the spacing.")
        #expect(bench.box.setLayout(target: "E5", layout: nil, spacing: "lots") == "I didn't understand the spacing.")
        #expect(bench.box.setLayout(target: "E5", layout: "zigzag", spacing: nil) == "I didn't understand the layout “zigzag”.")
        // An edge that a row doesn't line things up by.
        #expect(bench.box.setLayout(target: "E5", layout: "row left", spacing: nil) == "I didn't understand the layout “row left”.")
        #expect(bench.store.tree == before)
    }

    @Test func aLeafHasNoLayout() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.setLayout(target: "E1", layout: "row", spacing: nil) == "E1 is a title, which holds nothing. To put things in a row, call groupElements.")
        #expect(bench.store.tree == before)
    }

    @Test func freeKeepsWhereThingsAre() {
        let bench = bench()
        let label = bench.store.ownFrame(bench.login.label)
        let toggle = bench.store.ownFrame(bench.login.toggle)
        #expect(bench.box.setLayout(target: "E5", layout: "free", spacing: nil) == "E5 is now free: what it holds stays where it is.")
        #expect(bench.store.node(bench.login.row)?.resolvedLayout == .free)
        #expect(bench.store.ownFrame(bench.login.label) == label)
        #expect(bench.store.ownFrame(bench.login.toggle) == toggle)
    }

    // MARK: ungroup

    @Test func ungroupingARowPutsItsThingsBack() {
        let bench = bench()
        let label = bench.store.ownFrame(bench.login.label)
        let toggle = bench.store.ownFrame(bench.login.toggle)
        #expect(bench.box.ungroup(element: "E5") == "Took E6 and E7 out of E5.")
        #expect(bench.root?.children.map(\.id) == [bench.login.title, bench.login.card, bench.login.label, bench.login.toggle, bench.x, bench.y])
        #expect(bench.store.ownFrame(bench.login.label) == label)
        #expect(bench.store.ownFrame(bench.login.toggle) == toggle)
    }

    @Test func ungroupingATurnedCardKeepsPlaces() throws {
        let bench = bench { login, _, _ in login.model.store.setCanvasAngles([login.card: 90]) }
        let centres = try [bench.login.about, bench.login.body].map { try #require(bench.store.placed($0)).canvasShape.centre }
        #expect(bench.box.ungroup(element: "E2") == "Took E3 and E4 out of E2.")
        for (id, was) in zip([bench.login.about, bench.login.body], centres) {
            let now = try #require(bench.store.placed(id)).canvasShape.centre
            #expect(abs(now.x - was.x) <= 0.001 && abs(now.y - was.y) <= 0.001)
        }
    }

    @Test func aLeafCantBeUngrouped() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.ungroup(element: "E1") == "E1 isn't a row, column, grid, card or group.")
        #expect(bench.store.tree == before)
    }

    /// Taken apart by voice, a row the structure pass built declines what it held, so the pass never puts it back
    /// (plan 5, call 11).
    @Test func voicesUngroupDeclinesAStructureThePassMade() throws {
        var built: UUID?
        let bench = bench { login, x, y in
            let store = login.model.store
            guard let root = store.treeScreen(login.screen)?.root, var first = store.node(x), var second = store.node(y) else { return }
            first.frame.origin = .zero
            second.frame.origin = CGPoint(x: 116, y: 0)
            let row = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 16)),
                                          frame: CGRect(x: 20, y: 400, width: 216, height: 24), children: [first, second])
            built = store.build(StructureInference.Structure(kind: .row, parent: root.id, members: [x, y], container: row,
                                                             confidence: 1, movement: 0))
        }
        let row = try #require(built)
        #expect(bench.store.node(row)?.sketch?.decidedBy == .structure)
        let handle = bench.handles.handle(forNode: row)

        #expect(!bench.box.ungroup(element: handle).isEmpty)
        #expect(!bench.box.lastFailed)
        #expect(bench.store.node(row) == nil)
        #expect(bench.store.node(bench.x)?.sketch?.structureDeclined == true)
        #expect(bench.store.node(bench.y)?.sketch?.structureDeclined == true)
    }

    // MARK: reorder

    @Test func reorderingInARow() {
        let bench = bench()
        #expect(bench.box.reorder(element: "E7", position: "before", target: "E6") == "Moved E7 before E6.")
        #expect(bench.store.node(bench.login.row)?.children.map(\.id) == [bench.login.toggle, bench.login.label])
    }

    @Test func reorderingAcrossContainersIsRefused() {
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.reorder(element: "E6", position: "before", target: "E3") == "E6 and E3 aren't in the same row, column, grid or group.")
        #expect(bench.store.tree == before)
    }

    @Test func reorderingInAFreeParentChangesOnlyTheOrder() {
        let bench = bench()
        let ids = [bench.login.title, bench.login.card, bench.login.about, bench.login.body, bench.login.row, bench.login.label,
                   bench.login.toggle, bench.x, bench.y]
        let frames = ids.map(bench.store.ownFrame)
        #expect(bench.box.reorder(element: "E1", position: "after", target: "E5") == "Moved E1 after E5.")
        #expect(bench.root?.children.map(\.id) == [bench.login.card, bench.login.row, bench.login.title, bench.x, bench.y])
        #expect(ids.map(bench.store.ownFrame) == frames)
    }

    @Test func positionWordsAreTolerated() {
        for (words, moving, target) in [("above", "E7", "E6"), ("left of", "E7", "E6"), ("below", "E6", "E7"), ("right of", "E6", "E7")] {
            let bench = bench()
            _ = bench.box.reorder(element: moving, position: words, target: target)
            #expect(!bench.box.lastFailed, "\(words)")
            #expect(bench.store.node(bench.login.row)?.children.map(\.id) == [bench.login.toggle, bench.login.label], "\(words)")
        }
        let bench = bench()
        let before = bench.store.tree
        #expect(bench.box.reorder(element: "E7", position: "sideways", target: "E6") == "Say before or after.")
        #expect(bench.box.reorder(element: "E6", position: "before", target: "E6") == "E6 can't go before itself.")
        #expect(bench.store.tree == before)
    }

    // MARK: All four

    /// A change for one screen keeps to it (call 4): another screen's things are refused with today's line, and what is
    /// done on its own screen leaves the selection alone.
    @Test func theNewToolsKeepToTheScreenInScope() throws {
        var others: [UUID] = []
        var profile: TreeScreen.ID?
        let bench = bench { login, _, _ in
            let one = LayerNode.leaf(.text, frame: CGRect(x: 20, y: 80, width: 100, height: 24), text: "Name")
            let two = LayerNode.leaf(.text, frame: CGRect(x: 140, y: 80, width: 100, height: 24), text: "Email")
            profile = login.model.store.addFreeScreen([one, two], name: "Profile", origin: CGPoint(x: 600, y: 0))
            others = [one.id, two.id]
        }
        let screen = try #require(profile)
        let (one, two) = (bench.handles.handle(forNode: others[0]), bench.handles.handle(forNode: others[1]))
        let refusal = "\(one) isn't on S1 “Login”, the screen this change is for."
        bench.box.scope = bench.login.screen
        let selection = bench.login.model.selection
        let before = bench.store.tree

        #expect(bench.box.groupElements(elements: "\(one), \(two)", as: "row") == refusal)
        #expect(bench.box.ungroup(element: one) == refusal)
        #expect(bench.box.reorder(element: one, position: "after", target: two) == refusal)
        #expect(bench.box.setLayout(target: bench.handles.handle(forScreen: screen), layout: "column", spacing: nil)
            == "Only S1 “Login” can be changed here.")
        #expect(bench.store.tree == before)

        #expect(bench.box.groupElements(elements: "E8, E9", as: "row") == "Put E8 and E9 in a row, E13.")
        #expect(bench.login.model.selection == selection)
    }

    /// Run by a call, each new tool is one step named for a voice command, and one undo puts the design back.
    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func eachNewToolIsOneVoiceCommandStep() async throws {
        let commands: [(said: String, tool: String, arguments: String)] = [
            ("put the two texts in a row", "groupElements", #"{"elements":"E8, E9","as":"row"}"#),
            ("make the card a column", "setLayout", #"{"target":"E2","layout":"column","spacing":"12"}"#),
            ("ungroup the row", "ungroup", #"{"element":"E5"}"#),
            ("move the toggle before the label", "reorder", #"{"element":"E7","position":"before","target":"E6"}"#),
        ]
        for command in commands {
            let (login, _, _) = TreeFixture.loginWithTwoTexts()
            let store = login.model.store
            let before = store.tree
            let agent = VoiceAgent(model: login.model, testModel: ScriptedLanguageModel(script: [
                command.said: [ScriptedLanguageModel.Step(tool: command.tool, arguments: command.arguments)],
            ]))
            let outcome = await agent.run(command.said)
            #expect(outcome.problem == nil, "\(command.tool)")
            #expect(outcome.lines.count == 1, "\(command.tool)")
            #expect(store.tree != before, "\(command.tool)")
            #expect(login.undo.undoActionName == "Voice Command", "\(command.tool)")
            login.undo.undo()
            #expect(store.tree == before, "\(command.tool)")
            #expect(!login.undo.canUndo, "\(command.tool)")
        }
    }

    @Test func theToolListsGrew() {
        let bench = bench()
        #expect(VoiceTools.all(bench.box).count == 25)
        #expect(VoiceTools.all(bench.box, canEndCall: false).count == 24)
        #expect(VoiceTools.forEmptyCanvas(bench.box).map(\.name) == ["createScreen", "show", "zoom", "undo", "redo", "endCall"])
        #expect(Set(VoiceTools.all(bench.box).map(\.name)).isSuperset(of: ["groupElements", "setLayout", "ungroup", "reorder"]))
        #expect(["groupElements", "setLayout", "ungroup", "reorder"].map(VoiceTools.step(for:))
            == ["Grouping…", "Changing the layout…", "Ungrouping…", "Reordering…"])
    }

    /// With all 25 tools the on-device profile of a call with one screen was 3,578 tokens, over the 3,400 allowed it
    /// (call 10), so the on-device model is handed every tool but `setLayout` and `reorder`. A hosted model, and the
    /// test model, still have all of them.
    @Test func theOnDeviceModelIsSparedTwoTools() {
        let bench = bench()
        let all = VoiceTools.all(bench.box).map(\.name)
        let compact = VoiceTools.compact(bench.box).map(\.name)
        #expect(compact == all.filter { $0 != "setLayout" && $0 != "reorder" })
        #expect(compact.count == 23)
        #expect(VoiceTools.compact(bench.box, canEndCall: false).count == 22)
        #expect(VoiceProfile.onDeviceTools(bench.box, canEndCall: true, hasScreens: true).map(\.name) == compact)
        #expect(VoiceProfile.onDeviceTools(bench.box, canEndCall: false, hasScreens: false).map(\.name)
            == VoiceTools.forEmptyCanvas(bench.box, canEndCall: false).map(\.name))
    }
}
