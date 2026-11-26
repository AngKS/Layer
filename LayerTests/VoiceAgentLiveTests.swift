import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

/// Spoken commands carried out by a real model in LM Studio on this Mac, through the
/// agent, the profile and the tools exactly as a call runs them. Asked for with:
///
///     TEST_RUNNER_LAYER_LMSTUDIO=google/gemma-4-26b-a4b xcodebuild test \
///       -only-testing:LayerTests/VoiceAgentLiveTests ...
///
/// It needs LM Studio's server running with that model downloaded, and a model that can
/// call tools. Each command prints a line beginning `VOICE-LIVE` with how it went and
/// how long it took, which is what `docs/benchmarks/voice-agent.md` is written from.
@Suite(
    "Voice commands with a real model in LM Studio", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] != nil && HostedLanguageModel.isSupported, "set TEST_RUNNER_LAYER_LMSTUDIO=<model id> to run")
)
@MainActor
struct VoiceAgentLiveTests {
    let model = ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] ?? ""

    private func design() -> (app: AppModel, screen: TreeScreen.ID, agent: VoiceAgent) {
        let (app, screen) = VoiceFixture.undoableLogin()
        app.setModelChoice(.hosted(.lmStudio, model: model))
        return (app, screen, VoiceAgent(model: app))
    }

    /// Runs a command and prints how it went.
    private func say(_ command: String, to agent: VoiceAgent) async -> VoiceOutcome {
        var steps: [String] = []
        agent.onStep = { steps.append($0) }
        await QuietWindow.wait()
        let start = ContinuousClock.now
        let outcome = await agent.run(command)
        let seconds = Double((ContinuousClock.now - start).components.attoseconds) / 1e18 + Double((ContinuousClock.now - start).components.seconds)
        let result = outcome.problem.map { "PROBLEM \($0)" } ?? (outcome.lines.isEmpty ? "SAID \(outcome.said)" : outcome.lines.joined(separator: " | "))
        print("VOICE-LIVE \(String(format: "%.1f", seconds))s “\(command)” -> \(result) [steps: \(steps.joined(separator: ", "))]")
        return outcome
    }

    @Test func aButtonIsRecoloured() async throws {
        let (app, screen, agent) = design()
        let outcome = await say("Make the sign in button green", to: agent)
        #expect(outcome.problem == nil)
        #expect(app.store.screenLeaves(screen).first { $0.kind == .button }?.resolvedTint == ColourWords.parse("green"))
    }

    @Test func theCanvasGoesToTheFirstScreen() async throws {
        let (app, screen, agent) = design()
        let before = app.store.content
        let outcome = await say("Show me the first screen", to: agent)
        #expect(outcome.problem == nil)
        #expect(app.selection == .screen(screen))
        #expect(app.store.content == before, "showing a screen changes nothing")
    }

    @Test func anImageIsHalvedAndCentred() async throws {
        let (app, screen, agent) = design()
        let outcome = await say("Make the image half width and align it centrally", to: agent)
        let image = try #require(app.store.screenLeaves(screen).first { $0.kind == .image })
        let frame = try #require(app.store.ownFrame(image.id))
        print("VOICE-LIVE image frame \(frame)")
        #expect(outcome.problem == nil)
        #expect(frame.width == 197)
        #expect(abs(frame.midX - 196.5) <= 1)
    }

    @Test func wordsAreRewrittenInAStyle() async throws {
        let (app, screen, agent) = design()
        let outcome = await say("Change the title's text colour to blue and make its content sound like a pirate", to: agent)
        let title = try #require(app.store.screenLeaves(screen).first { $0.kind == .title })
        print("VOICE-LIVE title now “\(title.content.text)”")
        #expect(outcome.problem == nil)
        #expect(title.style.textColor == ColourWords.parse("blue"))
        #expect(title.content.text != "Welcome back")
    }

    @Test func aCommandLeansOnTheOneBefore() async throws {
        let (app, screen, agent) = design()
        _ = await say("Make the sign in button say Continue", to: agent)
        let outcome = await say("Now make it half width", to: agent)
        let button = try #require(app.store.screenLeaves(screen).first { $0.kind == .button })
        #expect(outcome.problem == nil)
        #expect(button.content.text == "Continue")
        #expect(app.store.ownFrame(button.id)?.width == 197)
    }

    @Test func somethingThatIsNotThereIsSaidNotDone() async throws {
        let (app, _, agent) = design()
        let before = app.store.tree
        let outcome = await say("Make the slider wider", to: agent)
        #expect(app.store.tree.screens == before.screens)
        #expect(outcome.lines.isEmpty)
        // Said by the model, in words: a model that couldn't be reached leaves the
        // design alone too, and must not pass for one that declined.
        #expect(outcome.problem == nil)
        #expect(!outcome.said.isEmpty)
    }

    /// The tree fixture (a card, a row of "Wi-Fi" and a toggle) with two texts below the row, "Terms" and "Privacy", on
    /// the model of the run (plan 6, Task 8).
    private func designWithARow() -> (login: TreeFixture.Login, x: UUID, y: UUID, agent: VoiceAgent) {
        let (login, x, y) = TreeFixture.loginWithTwoTexts()
        login.model.setModelChoice(.hosted(.lmStudio, model: model))
        return (login, x, y, VoiceAgent(model: login.model))
    }

    @Test func liveGroupsTwoTextsAsARow() async throws {
        let (login, x, y, agent) = designWithARow()
        let store = login.model.store
        let outcome = await say("Put the two texts at the bottom in a row", to: agent)
        #expect(outcome.problem == nil)
        guard case .node(let id)? = store.parent(of: x), let row = store.node(id) else {
            Issue.record("The texts aren't in a container")
            return
        }
        print("VOICE-LIVE made \(row.kindName): \(String(describing: row.layout))")
        #expect(row.children.map(\.id) == [x, y])
        guard case .stack(let stack)? = row.layout else {
            Issue.record("The container isn't a row")
            return
        }
        #expect(stack.axis == .horizontal)
    }

    @Test func liveReordersInARow() async throws {
        let (login, _, _, agent) = designWithARow()
        let outcome = await say("Move the toggle before the label", to: agent)
        #expect(outcome.problem == nil)
        #expect(login.model.store.node(login.row)?.children.map(\.id) == [login.toggle, login.label])
    }

    @Test func aNewScreenIsWrittenFromADescription() async throws {
        let (app, _, agent) = design()
        let outcome = await say("I want a profile page with user settings", to: agent)
        #expect(outcome.problem == nil)
        #expect(app.store.tree.screens.count == 2)
        let made = try #require(app.store.tree.screens.last)
        print("VOICE-LIVE new screen “\(made.name)”: \(made.root.leaves.map { "\($0.kind.rawValue) \($0.content.text)" })")
        #expect(made.root.leaves.count >= 3)
        // The whole of it is one step to undo.
        app.store.undoManager?.undo()
        #expect(app.store.tree.screens.count == 1)
    }

    // MARK: Commands that call one tool more than once

    // The full rules tell a hosted model to carry a command out once and not to call a tool on the same thing twice
    // (2026-11-26, "Structure wording"). These commands need a tool more than once, or one call that does the work of
    // two, and are judged by where the design ends up.

    @Test func twoChangesAreUndone() async throws {
        let (app, screen, agent) = design()
        let leaves = app.store.screenLeaves(screen)
        let title = try #require(leaves.first { $0.kind == .title })
        let button = try #require(leaves.first { $0.kind == .button })
        // Two changes made by hand, each a step of its own.
        app.store.update(title.id) { $0.content.text = "Hello" }
        app.store.update(button.id) { $0.content.text = "Ahoy" }
        let outcome = await say("Undo the last two changes", to: agent)
        print("VOICE-LIVE end: title “\(app.store.node(title.id)?.content.text ?? "")”, button “\(app.store.node(button.id)?.content.text ?? "")”")
        #expect(outcome.problem == nil)
        #expect(app.store.node(title.id)?.content.text == "Welcome back")
        #expect(app.store.node(button.id)?.content.text == "Sign in")
    }

    @Test func threeButtonsAreAdded() async throws {
        let (app, screen, agent) = design()
        let before = app.store.screenLeaves(screen).filter { $0.kind == .button }.count
        let outcome = await say("Add three buttons", to: agent)
        let after = app.store.screenLeaves(screen).filter { $0.kind == .button }.count
        print("VOICE-LIVE end: \(after - before) buttons added")
        #expect(outcome.problem == nil)
        #expect(after - before == 3)
    }

    @Test func aTurnIsAddedToATurn() async throws {
        let (app, screen, agent) = design()
        let button = try #require(app.store.screenLeaves(screen).first { $0.kind == .button })
        app.selection = .element(NodeRef(host: .screen(screen), node: button.id))
        let outcome = await say("Rotate it 45 degrees, then 45 more", to: agent)
        let rotation = app.store.node(button.id)?.rotation ?? 0
        print("VOICE-LIVE end: the button is turned \(rotation)°")
        #expect(outcome.problem == nil)
        #expect(abs(rotation - 90) < 0.5)
        #expect(outcome.lines.count <= 2, "a call for each turn at most")
    }

    /// The same, in words the rules don't quote.
    @Test func anotherTurnIsAddedToATurn() async throws {
        let (app, screen, agent) = design()
        let button = try #require(app.store.screenLeaves(screen).first { $0.kind == .button })
        app.selection = .element(NodeRef(host: .screen(screen), node: button.id))
        let outcome = await say("Rotate it 30 degrees, then 30 more", to: agent)
        let rotation = app.store.node(button.id)?.rotation ?? 0
        print("VOICE-LIVE end: the button is turned \(rotation)°")
        #expect(outcome.problem == nil)
        #expect(abs(rotation - 60) < 0.5)
        #expect(outcome.lines.count <= 2, "a call for each turn at most")
    }

    // Two changes to one element in one command (fix round 2), judged by the end state and by the calls: at most one for
    // each change asked for. "Bigger" and "down" are each one step; made again and again, they end far past what was
    // asked, as "space the row out more" does.

    @Test func aTitleIsMadeBiggerAndBold() async throws {
        let (app, screen, agent) = design()
        let title = try #require(app.store.screenLeaves(screen).first { $0.kind == .title })
        // Regular to start with, so that "bold" has something to do: a title is bold by default.
        app.store.update(title.id) { $0.style.fontWeight = .regular }
        let tokens = app.store.tree.settings.tokens
        let size = try #require(app.store.node(title.id)).resolvedFontSize(tokens: tokens)
        let frame = try #require(app.store.ownFrame(title.id))
        let outcome = await say("Make the title bigger and bold", to: agent)
        let after = try #require(app.store.node(title.id))
        let newSize = after.resolvedFontSize(tokens: tokens)
        let newFrame = app.store.ownFrame(title.id) ?? frame
        print("VOICE-LIVE end: the title is \(after.resolvedFontWeight.rawValue), \(newSize) pt (was \(size)), \(newFrame.size) (was \(frame.size))")
        #expect(outcome.problem == nil)
        #expect(after.resolvedFontWeight == .bold)
        #expect(newSize > size || newFrame.height > frame.height)
        #expect(outcome.lines.count <= 2, "a call for each change at most")
    }

    /// "Half as wide" is half the button's own 353 points, or half the screen's 393 as "half width" is: either is taken.
    @Test func aButtonIsMovedDownAndHalved() async throws {
        let (app, screen, agent) = design()
        let button = try #require(app.store.screenLeaves(screen).first { $0.kind == .button })
        app.selection = .element(NodeRef(host: .screen(screen), node: button.id))
        let frame = try #require(app.store.ownFrame(button.id))
        let outcome = await say("Move it down and make it half as wide", to: agent)
        let after = try #require(app.store.ownFrame(button.id))
        print("VOICE-LIVE end: the button is at y \(after.minY) (was \(frame.minY)), \(after.width) wide (was \(frame.width))")
        #expect(outcome.problem == nil)
        #expect(after.minY > frame.minY)
        #expect(after.width >= frame.width * 0.45 && after.width <= 197.5)
        #expect(outcome.lines.count <= 2, "a call for each change at most")
    }
}

/// The voice harness's structure cases (`Tools/VoiceBenchmarkHarness/run.sh structure`), put to a real model in LM Studio
/// set up exactly as a hosted model is in a call: the app's own profile, so the full rules, the whole canvas and all 25
/// tools, at the app's own settings, carried out by the app's own toolbox on a design built as the harness's canvas is
/// told, the canvas taken again after each tool as a call takes it. Asked for as `VoiceAgentLiveTests` is, and run with
/// `-only-testing:LayerTests/VoiceStructureLiveTests`.
///
/// Each case runs three times, each on a fresh design in a fresh session. What the model asks for is scored as the
/// harness scores it: "right tool" is a first call to the right tool, and the harness's "right" is the right tool with
/// the right arguments and no other call. A tool asked for with arguments that can't be read, such as a number where it
/// takes text, counts as that tool picked and not right: in the app the command would change nothing. Where the design
/// ends up is scored too, as each case's `isDone` says: "right" here is the harness's right with the design where the
/// command asked for it, so a run that ends in "Done" with nothing done is never right. A line beginning
/// `VOICE-STRUCTURE` is printed for each run, and one beginning `VOICE-STRUCTURE-SUM` for each case and for the eight,
/// which "Structure wording (2026-11-26)" in docs/benchmarks/voice-on-device.md is written from.
@Suite(
    "Structure commands with a real model in LM Studio", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] != nil && HostedLanguageModel.isSupported, "set TEST_RUNNER_LAYER_LMSTUDIO=<model id> to run")
)
@MainActor
struct VoiceStructureLiveTests {
    let model = ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] ?? ""
    /// Three, or `TEST_RUNNER_LAYER_STRUCTURE_RUNS`.
    static let runs = max(1, ProcessInfo.processInfo.environment["LAYER_STRUCTURE_RUNS"].flatMap(Int.init) ?? 3)
    /// With `TEST_RUNNER_LAYER_STRUCTURE_ONLY=<words>`, only the cases whose command holds those words, such as "take the
    /// toggle", to run one case more times than the rest.
    static let only = ProcessInfo.processInfo.environment["LAYER_STRUCTURE_ONLY"]?.lowercased()

    static func isAsked(_ testCase: Case) -> Bool {
        only.map { testCase.command.lowercased().contains($0) } ?? true
    }

    /// The design a case is spoken over.
    enum Design {
        /// The harness's "Account" screen, nothing selected.
        case account
        /// The same, with its two text fields selected.
        case fieldsSelected
        /// The harness's "Login" screen, with the button selected.
        case login
    }

    /// A design made for a case, and its things by name: on "Account", `title`, `card`, `about`, `body`, `row`, `label`,
    /// `toggle`, `email`, `password`, `column`, `button` and `forgot`; on "Login", `title`, `button` and `image`.
    @MainActor
    struct Built {
        let app: AppModel
        let ids: [String: UUID]

        var store: DesignStore { app.store }

        func id(_ name: String) -> UUID { ids[name] ?? UUID() }

        func node(_ name: String) -> LayerNode? { store.node(id(name)) }

        /// The container `name` is in, if it is in one.
        func container(of name: String) -> LayerNode? {
            guard case .node(let parent)? = store.parent(of: id(name)) else { return nil }
            return store.node(parent)
        }

        /// Whether `names`, in that order, are all that one row or column holds.
        func areAll(_ names: [String], in axis: LayerNode.Axis) -> Bool {
            guard let holder = container(of: names[0]), case .stack(let stack)? = holder.layout else { return false }
            return stack.axis == axis && holder.children.map(\.id) == names.map(id)
        }
    }

    struct Case {
        var command: String
        var design = Design.account
        var tool: String
        var isRight: ([String: String]) -> Bool
        /// Whether the design is where the command asked for it, and what it shows, in a few words. The calls are there for
        /// a case whose end can't be told from the design alone: a spacing raised once, not again and again.
        var isDone: @MainActor (Built, [RecordingToolbox.Call]) -> (Bool, String)
    }

    /// The harness's `structureCases` (Tools/VoiceBenchmarkHarness/Harness.swift, `structureCases`), with the same canvas
    /// and selection and, copied clause by clause, the same test of the arguments: change one, change the other. The
    /// harness is built apart from the app, so it can't share them.
    static let cases: [Case] = [
        Case(command: "Put these in a column", design: .fieldsSelected, tool: "groupElements",
             isRight: { ["E8", "E9"].allSatisfy(($0["elements"] ?? "").contains) && ($0["as"] ?? "").lowercased().contains("column") },
             isDone: { built, _ in (built.areAll(["email", "password"], in: .vertical), "the fields' container: \(describe(built.container(of: "email")))") }),
        Case(command: "Make these a row", design: .fieldsSelected, tool: "groupElements",
             isRight: { ["E8", "E9"].allSatisfy(($0["elements"] ?? "").contains) && ($0["as"] ?? "").lowercased().contains("row") },
             isDone: { built, _ in (built.areAll(["email", "password"], in: .horizontal), "the fields' container: \(describe(built.container(of: "email")))") }),
        Case(command: "Make the card a grid of two", tool: "setLayout", isRight: { arguments in
            let layout = (arguments["layout"] ?? "").lowercased()
            return arguments["target"] == "E2" && layout.contains("grid") && (layout.contains("2") || layout.contains("two"))
        }, isDone: { built, _ in
            guard case .grid(let grid)? = built.node("card")?.layout else { return (false, "the card: \(describe(built.node("card")))") }
            return (grid.columns == 2, "the card: \(describe(built.node("card")))")
        }),
        // More than the row's 12. Done is one raise, in one call, to no more than 48: a spacing raised again and again
        // isn't what was asked, wherever it ends.
        Case(command: "Space the row out more", tool: "setLayout", isRight: { arguments in
            let spacing = Double((arguments["spacing"] ?? "").filter { $0.isNumber || $0 == "." }) ?? 0
            let keepsTheRow = arguments["layout"].map { $0.lowercased().contains("row") } ?? true
            return arguments["target"] == "E5" && spacing > 12 && keepsTheRow
        }, isDone: { built, calls in
            let raises = calls.filter { $0.tool == "setLayout" && $0.arguments["spacing"] != nil }.count
            guard case .stack(let stack)? = built.node("row")?.layout, stack.axis == .horizontal else {
                return (false, "the row: \(describe(built.node("row")))")
            }
            return (raises == 1 && stack.spacing > 12 && stack.spacing <= 48, "the row: \(describe(built.node("row"))), \(raises) raises")
        }),
        Case(command: "Ungroup the row", tool: "ungroup", isRight: { ($0["element"] ?? "").lowercased().contains("e5") }, isDone: { built, _ in
            let free = built.node("row") == nil && built.container(of: "label") == nil && built.container(of: "toggle") == nil
            return (free, built.node("row") == nil ? "the row is gone" : "the row: \(describe(built.node("row")))")
        }),
        Case(command: "Move the toggle before the label", tool: "reorder", isRight: { arguments in
            let said = Set((arguments["position"] ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
            let before = !said.isDisjoint(with: ["before", "above", "left"])
            let after = !said.isDisjoint(with: ["after", "below", "under", "beneath", "underneath", "right"])
            return arguments["element"] == "E7" && arguments["target"] == "E6" && before && !after
        }, isDone: { built, _ in (built.areAll(["toggle", "label"], in: .horizontal), "the row: \(describe(built.node("row")))") }),
        // Controls: one thing out of a row is moveElement's take-out, and a button in a column is resized as any is.
        Case(command: "Take the toggle out of the row", tool: "moveElement",
             isRight: { $0["element"] == "E7" && ["yes", "true", "y"].contains(($0["takeOut"] ?? "").lowercased()) },
             isDone: { built, _ in
                 let out = built.node("toggle") != nil && built.container(of: "toggle")?.id != built.id("row")
                 return (out, out ? "the toggle is out of the row" : "the toggle is still in the row")
             }),
        Case(command: "Make the button half width", tool: "moveElement",
             isRight: { ($0["element"] ?? "").lowercased().contains("e11") && ($0["width"] ?? "").contains("50") },
             isDone: { built, _ in
                 let width = built.store.ownFrame(built.id("button"))?.width ?? 0
                 return (abs(width - 196.5) <= 1, "the button is \(width) wide")
             }),
    ]

    /// A control beyond the eight, for wording that sends "put these in a column" to `groupElements`: "stack", as the
    /// harness's command from the iPad says it, over its "Login" screen. The harness counts `stackElements` right. Done is
    /// the three in a column, or one under another with even gaps. Scored apart from the eight.
    static let stackControl = Case(
        command: "Stack the title, the button and the image into a column.", design: .login, tool: "stackElements",
        isRight: { ($0["direction"] ?? "").lowercased().contains("column") && ["E1", "E2", "E3"].allSatisfy(($0["elements"] ?? "").contains) },
        isDone: { built, _ in
            if built.areAll(["title", "button", "image"], in: .vertical) { return (true, "the three are in a column") }
            let frames = ["title", "button", "image"].compactMap { built.store.ownFrame(built.id($0)) }.sorted { $0.minY < $1.minY }
            guard frames.count == 3 else { return (false, "not all three are there") }
            let gaps = [frames[1].minY - frames[0].maxY, frames[2].minY - frames[1].maxY]
            return (gaps.allSatisfy { $0 >= 0 } && abs(gaps[0] - gaps[1]) <= 1, "gaps \(gaps.map { Int($0.rounded()) })")
        }
    )

    /// A container or leaf in a few words: its kind, and its layout.
    static func describe(_ node: LayerNode?) -> String {
        guard let node else { return "none" }
        switch node.layout {
        case .stack(let stack)?: return "\(node.kindName), \(stack.axis == .vertical ? "column" : "row") \(Int(stack.spacing)) apart"
        case .grid(let grid)?: return "\(node.kindName), grid of \(grid.columns)"
        case let other?: return "\(node.kindName), \(other)"
        case nil: return "\(node.kindName), free"
        }
    }

    /// A fresh design for a case, as a call captures it, its screen in view: S1 "Account" holds E1 the title "Account";
    /// E2 a free card holding E3 "About me" and E4 the body; E5 a row 12 apart, centred, holding E6 "Wi-Fi" and E7 a
    /// toggle; E8 and E9 the text fields "Email" and "Password"; and E10 a column 12 apart holding E11 the "Sign in"
    /// button and E12 "Forgot password?". Or S1 "Login": E1 the title "Welcome back", E2 the "Sign in" button,
    /// selected, and E3 an image. `VoiceStructureDesignTests` checks each is told as the harness tells its canvas.
    static func make(_ design: Design) -> Built {
        let app = AppModel(document: LayerDocument())
        app.phoneLine = PhoneLine()
        // Seen at zoom 1 from the canvas's origin, where the screen is: in view, as the harness's are.
        app.canvasSize = CGSize(width: 1210, height: 834)
        app.viewport = Viewport(offset: .zero, scale: 1)
        let nodes: [String: LayerNode]
        let order: [String]
        let name: String
        if design == .login {
            nodes = [
                "title": .leaf(.title, frame: CGRect(x: 20, y: 75, width: 353, height: 41), text: "Welcome back"),
                "button": .leaf(.button, frame: CGRect(x: 20, y: 420, width: 353, height: 50), text: "Sign in", tint: Theme.accent),
                "image": .leaf(.image, frame: CGRect(x: 20, y: 500, width: 200, height: 200)),
            ]
            order = ["title", "button", "image"]
            name = "Login"
        } else {
            let about = LayerNode.leaf(.text, frame: CGRect(x: 16, y: 16, width: 200, height: 24), text: "About me")
            let body = LayerNode.leaf(.body, frame: CGRect(x: 16, y: 48, width: 321, height: 64), text: "Designing better experiences.")
            let label = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 80, height: 24), text: "Wi-Fi")
            let toggle = LayerNode.leaf(.toggle, frame: CGRect(x: 0, y: 0, width: 51, height: 31), isOn: true)
            let button = LayerNode.leaf(.button, frame: CGRect(x: 0, y: 0, width: 353, height: 50), text: "Sign in", tint: Theme.accent)
            let forgot = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 150, height: 20), text: "Forgot password?")
            nodes = [
                "title": .leaf(.title, frame: CGRect(x: 20, y: 60, width: 353, height: 41), text: "Account"),
                "about": about, "body": body, "label": label, "toggle": toggle, "button": button, "forgot": forgot,
                "card": .container(.card, frame: CGRect(x: 20, y: 121, width: 353, height: 128), width: .init(.fixed),
                                   height: .init(.fixed), padding: 16, children: [about, body]),
                "row": .container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .center)),
                                  frame: CGRect(x: 20, y: 269, width: 0, height: 0), children: [label, toggle]),
                "email": .leaf(.textField, frame: CGRect(x: 20, y: 320, width: 353, height: 44), text: "Email"),
                "password": .leaf(.textField, frame: CGRect(x: 20, y: 380, width: 353, height: 44), text: "Password"),
                "column": .container(layout: .stack(LayerNode.Stack(axis: .vertical, spacing: 12)),
                                     frame: CGRect(x: 20, y: 460, width: 0, height: 0), children: [button, forgot]),
            ]
            order = ["title", "card", "row", "email", "password", "column"]
            name = "Account"
        }
        let screen = app.store.addFreeScreen(order.compactMap { nodes[$0] }, name: name)
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.store.undoManager = undo
        let ids = nodes.mapValues(\.id)
        let selected: [String] = switch design {
        case .account: []
        case .fieldsSelected: ["email", "password"]
        case .login: ["button"]
        }
        let things = selected.compactMap { ids[$0] }.map { CanvasSelection.element(NodeRef(host: .screen(screen), node: $0)) }
        app.selection = CanvasSelection(things)
        return Built(app: app, ids: ids)
    }

    @Test func structureCommandsAreScored() async throws {
        var failures: [String] = []
        var eight = Score()
        let asked = Self.cases.filter(Self.isAsked)
        guard !asked.isEmpty || Self.isAsked(Self.stackControl) else {
            Issue.record("TEST_RUNNER_LAYER_STRUCTURE_ONLY=\(Self.only ?? "") matches no case")
            return
        }
        for testCase in asked {
            eight.add(await scored(testCase, failures: &failures))
        }
        let count = asked.count * Self.runs
        print("VOICE-STRUCTURE-SUM total \(eight.right)/\(count) right, \(eight.harnessRight)/\(count) right as the harness scores, "
            + "\(eight.rightTool)/\(count) right tool, \(eight.done)/\(count) done, \(eight.falseDone)/\(count) said done with it not done, model \(model)")
        if Self.isAsked(Self.stackControl) { _ = await scored(Self.stackControl, failures: &failures) }
        // A model that couldn't be reached mustn't pass for one that picked badly.
        #expect(failures.isEmpty, "\(failures)")
    }

    struct Score {
        /// The harness's right, with the design where the command asked for it.
        var right = 0
        var harnessRight = 0
        var rightTool = 0
        /// The design where the command asked for it, whatever was called.
        var done = 0
        /// The model answered without a problem while the design wasn't where the command asked for it.
        var falseDone = 0

        mutating func add(_ other: Score) {
            right += other.right
            harnessRight += other.harnessRight
            rightTool += other.rightTool
            done += other.done
            falseDone += other.falseDone
        }
    }

    /// Runs a case `runs` times, each on a fresh design in a fresh session, and prints each run and the case's sum.
    private func scored(_ testCase: Case, failures: inout [String]) async -> Score {
        var score = Score()
        var picks: [String: Int] = [:]
        for run in 1...Self.runs {
            let built = Self.make(testCase.design)
            let handles = VoiceHandles()
            let toolbox = VoiceToolbox(model: built.app, handles: handles)
            toolbox.reset()
            toolbox.spokenCommand = testCase.command
            let recorder = RecordingToolbox(toolbox)
            let looker = CanvasLooker(app: built.app, handles: handles)
            let turns = VoiceToolTurns()
            let session = LanguageModelSession(profile: VoiceProfile(
                actor: recorder, hooks: VoiceHooks(willRun: { _ in }, didRun: {
                    await looker.look()
                    // Before the model is asked again with this tool's result.
                    await QuietWindow.wait()
                }, mayRun: { true }), turns: turns
            ))
            turns.session = session
            looker.session = session
            session.properties.voiceModel = .hosted(.lmStudio, model: model)
            looker.look()
            var said = ""
            var calls: [RecordingToolbox.Call] = []
            var answered = false
            await QuietWindow.wait()
            do {
                said = try await session.respond(to: testCase.command).content
                calls = recorder.calls
                answered = true
            } catch let error as LanguageModelSession.ToolCallError {
                // The model asked for a tool whose arguments couldn't be read, such as a number where the tool takes
                // text: that tool was picked, wrongly asked, and in the app the command would change nothing.
                calls = recorder.calls + [.init(tool: error.tool.name, arguments: ["unreadable": "\(error.underlyingError)"], line: "")]
                said = "UNREADABLE"
            } catch {
                failures.append("\(testCase.command): \(error)")
                calls = recorder.calls
                said = "ERROR \(String(describing: error).prefix(160))"
            }
            let (isDone, end) = testCase.isDone(built, calls)
            let isRightTool = calls.first?.tool == testCase.tool
            let isHarnessRight = isRightTool && calls.count == 1 && calls[0].arguments["unreadable"] == nil && testCase.isRight(calls[0].arguments)
            let isRight = isHarnessRight && isDone
            if isRight { score.right += 1 }
            if isHarnessRight { score.harnessRight += 1 }
            if isRightTool { score.rightTool += 1 }
            if isDone { score.done += 1 }
            if answered, !isDone { score.falseDone += 1 }
            picks[calls.first?.tool ?? "none", default: 0] += 1
            let did = calls.isEmpty ? "no tool" : calls.map(\.description).joined(separator: "; ")
            let mark = isRight ? "RIGHT" : isRightTool ? "TOOL " : "WRONG"
            print("VOICE-STRUCTURE run\(run) \(mark) \(isDone ? "DONE" : "UNDONE") \(calls.count) calls “\(testCase.command)” -> \(did) | said “\(said.prefix(80))” | end: \(end)")
        }
        let picked = picks.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("VOICE-STRUCTURE-SUM \(score.right)/\(Self.runs) right, \(score.harnessRight)/\(Self.runs) right as the harness scores, "
            + "\(score.rightTool)/\(Self.runs) right tool, \(score.done)/\(Self.runs) done, \(score.falseDone)/\(Self.runs) said done with it not done "
            + "| “\(testCase.command)” | picks: \(picked)")
        return score
    }
}

/// The hosted structure measurement's designs, told as the voice harness tells its canvases, so that the hosted and
/// on-device numbers are for the same screen. Run in CI: they call no model.
@Suite("The hosted structure measurement's designs")
@MainActor
struct VoiceStructureDesignTests {
    /// Copied from Tools/VoiceBenchmarkHarness/Harness.swift, `Canvas.account`: change one, change the other.
    static let harnessAccount = CanvasPicture.Screen(
        handle: "S1", name: "Account", size: CGSize(width: 393, height: 852), visibleShare: 1,
        elements: [
            .init(handle: "E1", kind: "title", text: "Account", frame: CGRect(x: 20, y: 60, width: 353, height: 41)),
            .init(handle: "E2", kind: "card", text: "", frame: CGRect(x: 20, y: 121, width: 353, height: 128), isContainer: true, children: [
                .init(handle: "E3", kind: "text", text: "About me", frame: CGRect(x: 36, y: 137, width: 200, height: 24)),
                .init(handle: "E4", kind: "body", text: "Designing better experiences.", frame: CGRect(x: 36, y: 169, width: 321, height: 64)),
            ]),
            .init(handle: "E5", kind: "group", text: "", frame: CGRect(x: 20, y: 269, width: 143, height: 31), layout: "row, spacing 12, centred", isContainer: true, children: [
                .init(handle: "E6", kind: "text", text: "Wi-Fi", frame: CGRect(x: 20, y: 272, width: 80, height: 24)),
                .init(handle: "E7", kind: "toggle", text: "", frame: CGRect(x: 112, y: 269, width: 51, height: 31), look: ["colour green", "on"]),
            ]),
            .init(handle: "E8", kind: "text field", text: "Email", frame: CGRect(x: 20, y: 320, width: 353, height: 44)),
            .init(handle: "E9", kind: "text field", text: "Password", frame: CGRect(x: 20, y: 380, width: 353, height: 44)),
            .init(handle: "E10", kind: "group", text: "", frame: CGRect(x: 20, y: 460, width: 353, height: 82), layout: "column, spacing 12", isContainer: true, children: [
                .init(handle: "E11", kind: "button", text: "Sign in", frame: CGRect(x: 20, y: 460, width: 353, height: 50), look: ["colour accent"]),
                .init(handle: "E12", kind: "text", text: "Forgot password?", frame: CGRect(x: 20, y: 522, width: 150, height: 20)),
            ]),
        ]
    )

    /// Copied from Tools/VoiceBenchmarkHarness/Harness.swift, `Canvas.login`, with its button selected as `.one` has it.
    static let harnessLogin = CanvasPicture.Screen(
        handle: "S1", name: "Login", size: CGSize(width: 393, height: 852), visibleShare: 1,
        elements: [
            .init(handle: "E1", kind: "title", text: "Welcome back", frame: CGRect(x: 20, y: 75, width: 353, height: 41)),
            .init(handle: "E2", kind: "button", text: "Sign in", frame: CGRect(x: 20, y: 420, width: 353, height: 50), look: ["colour accent"], isSelected: true),
            .init(handle: "E3", kind: "image", text: "", frame: CGRect(x: 20, y: 500, width: 200, height: 200)),
        ]
    )

    /// The two ways the app's "Account" is told apart from the harness's, both of them the app's own say: its toggle is
    /// the accent colour, not green, and the label in the row is centred across the row's 31 points, at 272.5, told 273.
    static func harnessAccountAsTheAppTellsIt(fieldsSelected: Bool) -> CanvasPicture {
        var screen = harnessAccount
        screen.elements[2].children[1].look = ["colour accent", "on"]
        screen.elements[2].children[0].frame?.origin.y = 272.5
        screen.elements[3].isSelected = fieldsSelected
        screen.elements[4].isSelected = fieldsSelected
        return CanvasPicture(screens: [screen])
    }

    @Test(arguments: [false, true])
    func theAccountIsToldAsTheHarnessTellsIt(fieldsSelected: Bool) {
        let built = VoiceStructureLiveTests.make(fieldsSelected ? .fieldsSelected : .account)
        let told = CanvasPicture.capture(from: built.app, handles: VoiceHandles()).text(.full)
        #expect(told == Self.harnessAccountAsTheAppTellsIt(fieldsSelected: fieldsSelected).text(.full))
    }

    @Test func theLoginIsToldAsTheHarnessTellsIt() {
        let built = VoiceStructureLiveTests.make(.login)
        let told = CanvasPicture.capture(from: built.app, handles: VoiceHandles()).text(.full)
        #expect(told == CanvasPicture(screens: [Self.harnessLogin]).text(.full))
    }
}

/// LM Studio is shared with other work on this Mac, some of it timed. With `TEST_RUNNER_LAYER_QUIET_FILE=<path>`, the
/// live suites send it nothing while that file exists: they wait before each command, and the structure suite also
/// before each request after a tool. Without it, they never wait.
enum QuietWindow {
    static let path = ProcessInfo.processInfo.environment["LAYER_QUIET_FILE"]

    static func wait() async {
        guard let path, !path.isEmpty else { return }
        var announced = false
        while FileManager.default.fileExists(atPath: path) {
            if !announced {
                print("VOICE-QUIET waiting while \(path) exists")
                announced = true
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

/// Takes the canvas again for the model's next look, as a call does after each tool a hosted model runs.
@MainActor
final class CanvasLooker {
    let app: AppModel
    let handles: VoiceHandles
    weak var session: LanguageModelSession?

    init(app: AppModel, handles: VoiceHandles) {
        self.app = app
        self.handles = handles
    }

    func look() {
        session?.properties.canvasPicture = CanvasPicture.capture(from: app, handles: handles)
    }
}

/// The app's own toolbox, with each call the model asks for written down as it goes through, and the line it answered.
@MainActor
final class RecordingToolbox: VoiceActing {
    struct Call: CustomStringConvertible {
        var tool: String
        var arguments: [String: String]
        var line: String

        var description: String {
            "\(tool)(\(arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")))"
                + (line.isEmpty ? "" : " = “\(line)”")
        }
    }

    let inner: VoiceToolbox
    private(set) var calls: [Call] = []

    init(_ inner: VoiceToolbox) {
        self.inner = inner
    }

    private func note(_ tool: String, _ arguments: [String: String?], _ line: String) -> String {
        calls.append(Call(tool: tool, arguments: arguments.compactMapValues { $0 }, line: line))
        return line
    }

    func createScreen(name: String?, description: String, device: String?) async throws -> String {
        let arguments = ["name": name, "description": description, "device": device]
        do {
            return note("createScreen", arguments, try await inner.createScreen(name: name, description: description, device: device))
        } catch {
            // Written down before it is passed on, so a call that threw is still counted.
            _ = note("createScreen", arguments, "threw: \(error)")
            throw error
        }
    }

    func addElement(screen: String?, kind: String, text: String?, look: String?, relation: String?, target: String?) -> String {
        note("addElement", ["screen": screen, "kind": kind, "text": text, "look": look, "relation": relation, "target": target],
             inner.addElement(screen: screen, kind: kind, text: text, look: look, relation: relation, target: target))
    }

    func stackElements(elements: String, direction: String) -> String {
        note("stackElements", ["elements": elements, "direction": direction], inner.stackElements(elements: elements, direction: direction))
    }

    func placeElement(element: String, relation: String, target: String) -> String {
        note("placeElement", ["element": element, "relation": relation, "target": target],
             inner.placeElement(element: element, relation: relation, target: target))
    }

    func setText(element: String, text: String) -> String {
        note("setText", ["element": element, "text": text], inner.setText(element: element, text: text))
    }

    func styleElement(element: String, look: String) -> String {
        note("styleElement", ["element": element, "look": look], inner.styleElement(element: element, look: look))
    }

    func moveElement(element: String, x: String?, y: String?, width: String?, height: String?, takeOut: String?) -> String {
        note("moveElement", ["element": element, "x": x, "y": y, "width": width, "height": height, "takeOut": takeOut],
             inner.moveElement(element: element, x: x, y: y, width: width, height: height, takeOut: takeOut))
    }

    func rotateElement(element: String, angle: String?, by: String?) -> String {
        note("rotateElement", ["element": element, "angle": angle, "by": by], inner.rotateElement(element: element, angle: angle, by: by))
    }

    func alignElement(element: String, alignment: String) -> String {
        note("alignElement", ["element": element, "alignment": alignment], inner.alignElement(element: element, alignment: alignment))
    }

    func duplicateElement(element: String) -> String {
        note("duplicateElement", ["element": element], inner.duplicateElement(element: element))
    }

    func deleteElement(element: String, named: String?) -> String {
        note("deleteElement", ["element": element, "named": named], inner.deleteElement(element: element, named: named))
    }

    func renameScreen(screen: String, name: String) -> String {
        note("renameScreen", ["screen": screen, "name": name], inner.renameScreen(screen: screen, name: name))
    }

    func deleteScreen(screen: String, named: String?) -> String {
        note("deleteScreen", ["screen": screen, "named": named], inner.deleteScreen(screen: screen, named: named))
    }

    func tidyScreen(screen: String?) -> String {
        note("tidyScreen", ["screen": screen], inner.tidyScreen(screen: screen))
    }

    func changeScreenDevice(screen: String?, device: String) -> String {
        note("changeScreenDevice", ["screen": screen, "device": device], inner.changeScreenDevice(screen: screen, device: device))
    }

    func groupElements(elements: String, as shape: String) -> String {
        note("groupElements", ["elements": elements, "as": shape], inner.groupElements(elements: elements, as: shape))
    }

    func setLayout(target: String, layout: String?, spacing: String?) -> String {
        note("setLayout", ["target": target, "layout": layout, "spacing": spacing], inner.setLayout(target: target, layout: layout, spacing: spacing))
    }

    func ungroup(element: String) -> String {
        note("ungroup", ["element": element], inner.ungroup(element: element))
    }

    func reorder(element: String, position: String, target: String) -> String {
        note("reorder", ["element": element, "position": position, "target": target],
             inner.reorder(element: element, position: position, target: target))
    }

    func show(target: String) -> String { note("show", ["target": target], inner.show(target: target)) }
    func pan(direction: String) -> String { note("pan", ["direction": direction], inner.pan(direction: direction)) }
    func zoom(to level: String) -> String { note("zoom", ["level": level], inner.zoom(to: level)) }
    func undo() -> String { note("undo", [:], inner.undo()) }
    func redo() -> String { note("redo", [:], inner.redo()) }
    func endCall() -> String { note("endCall", [:], inner.endCall()) }
}
