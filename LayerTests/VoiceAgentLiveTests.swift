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
}

/// The voice harness's structure cases (`Tools/VoiceBenchmarkHarness/run.sh structure`), put to a real model in LM Studio
/// set up exactly as a hosted model is in a call: the app's own profile, so the full rules, the whole canvas and all 25
/// tools, at the app's own settings, carried out by the app's own toolbox on a design built as the harness's canvas is
/// told, the canvas taken again after each tool as a call takes it. Asked for as `VoiceAgentLiveTests` is, and run with
/// `-only-testing:LayerTests/VoiceStructureLiveTests`.
///
/// Each case runs three times, each on a fresh design in a fresh session, and is scored as the harness scores it, by
/// what the model asks for: "right" is the right tool with the right arguments and no other call; "right tool" is a
/// first call to the right tool. A tool asked for with arguments that can't be read, such as a number where it takes
/// text, counts as that tool picked and not right: in the app the command would change nothing. A line beginning
/// `VOICE-STRUCTURE` is printed for each run, and one beginning `VOICE-STRUCTURE-SUM` for each case and for the eight,
/// which "Structure wording (2026-11-26)" in docs/benchmarks/voice-on-device.md is written from.
@Suite(
    "Structure commands with a real model in LM Studio", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] != nil && HostedLanguageModel.isSupported, "set TEST_RUNNER_LAYER_LMSTUDIO=<model id> to run")
)
@MainActor
struct VoiceStructureLiveTests {
    let model = ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] ?? ""
    static let runs = 3

    /// The design a case is spoken over.
    enum Design {
        /// The harness's "Account" screen, nothing selected.
        case account
        /// The same, with its two text fields selected.
        case fieldsSelected
        /// The harness's "Login" screen, with the button selected.
        case login
    }

    struct Case {
        var command: String
        var design = Design.account
        var tool: String
        var isRight: ([String: String]) -> Bool
    }

    /// The harness's `structureCases`, with the same canvas and selection and the same test of the arguments.
    static let cases: [Case] = [
        Case(command: "Put these in a column", design: .fieldsSelected, tool: "groupElements",
             isRight: { ["E8", "E9"].allSatisfy(($0["elements"] ?? "").contains) && ($0["as"] ?? "").lowercased().contains("column") }),
        Case(command: "Make these a row", design: .fieldsSelected, tool: "groupElements",
             isRight: { ["E8", "E9"].allSatisfy(($0["elements"] ?? "").contains) && ($0["as"] ?? "").lowercased().contains("row") }),
        Case(command: "Make the card a grid of two", tool: "setLayout", isRight: { arguments in
            let layout = (arguments["layout"] ?? "").lowercased()
            return arguments["target"] == "E2" && layout.contains("grid") && (layout.contains("2") || layout.contains("two"))
        }),
        // More than the row's 12.
        Case(command: "Space the row out more", tool: "setLayout", isRight: { arguments in
            let spacing = Double((arguments["spacing"] ?? "").filter { $0.isNumber || $0 == "." }) ?? 0
            let keepsTheRow = arguments["layout"].map { $0.lowercased().contains("row") } ?? true
            return arguments["target"] == "E5" && spacing > 12 && keepsTheRow
        }),
        Case(command: "Ungroup the row", tool: "ungroup", isRight: { ($0["element"] ?? "").lowercased().contains("e5") }),
        Case(command: "Move the toggle before the label", tool: "reorder", isRight: { arguments in
            let said = Set((arguments["position"] ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
            let before = !said.isDisjoint(with: ["before", "above", "left"])
            let after = !said.isDisjoint(with: ["after", "below", "under", "beneath", "underneath", "right"])
            return arguments["element"] == "E7" && arguments["target"] == "E6" && before && !after
        }),
        // Controls: one thing out of a row is moveElement's take-out, and a button in a column is resized as any is.
        Case(command: "Take the toggle out of the row", tool: "moveElement",
             isRight: { $0["element"] == "E7" && ["yes", "true", "y"].contains(($0["takeOut"] ?? "").lowercased()) }),
        Case(command: "Make the button half width", tool: "moveElement",
             isRight: { ($0["element"] ?? "").lowercased().contains("e11") && ($0["width"] ?? "").contains("50") }),
    ]

    /// A control beyond the eight, for wording that sends "put these in a column" to `groupElements`: "stack", as the
    /// harness's command from the iPad says it, over its "Login" screen. The harness counts `stackElements` right.
    /// Scored apart from the eight.
    static let stackControl = Case(
        command: "Stack the title, the button and the image into a column.", design: .login, tool: "stackElements",
        isRight: { ($0["direction"] ?? "").lowercased().contains("column") && ["E1", "E2", "E3"].allSatisfy(($0["elements"] ?? "").contains) }
    )

    /// A fresh design for a case, as a call captures it: S1 "Account" holds E1 the title "Account"; E2 a free card holding
    /// E3 "About me" and E4 the body; E5 a row 12 apart, centred, holding E6 "Wi-Fi" and E7 a toggle; E8 and E9 the text
    /// fields "Email" and "Password"; and E10 a column 12 apart holding E11 the "Sign in" button and E12 "Forgot
    /// password?". Or the voice tests' "Login": E1 the title, E2 the "Sign in" button, E3 the image.
    static func make(_ design: Design) -> AppModel {
        if design == .login {
            let (app, screen) = VoiceFixture.undoableLogin()
            if let button = app.store.screenLeaves(screen).first(where: { $0.kind == .button }) {
                app.selection = .element(NodeRef(host: .screen(screen), node: button.id))
            }
            return app
        }
        let app = AppModel(document: LayerDocument())
        app.phoneLine = PhoneLine()
        let title = LayerNode.leaf(.title, frame: CGRect(x: 20, y: 60, width: 353, height: 41), text: "Account")
        let about = LayerNode.leaf(.text, frame: CGRect(x: 16, y: 16, width: 200, height: 24), text: "About me")
        let body = LayerNode.leaf(.body, frame: CGRect(x: 16, y: 48, width: 321, height: 64), text: "Designing better experiences.")
        let card = LayerNode.container(.card, frame: CGRect(x: 20, y: 121, width: 353, height: 128), width: .init(.fixed),
                                       height: .init(.fixed), padding: 16, children: [about, body])
        let label = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 80, height: 24), text: "Wi-Fi")
        let toggle = LayerNode.leaf(.toggle, frame: CGRect(x: 0, y: 0, width: 51, height: 31), isOn: true)
        let row = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .center)),
                                      frame: CGRect(x: 20, y: 269, width: 0, height: 0), children: [label, toggle])
        let email = LayerNode.leaf(.textField, frame: CGRect(x: 20, y: 320, width: 353, height: 44), text: "Email")
        let password = LayerNode.leaf(.textField, frame: CGRect(x: 20, y: 380, width: 353, height: 44), text: "Password")
        let button = LayerNode.leaf(.button, frame: CGRect(x: 0, y: 0, width: 353, height: 50), text: "Sign in", tint: Theme.accent)
        let forgot = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 150, height: 20), text: "Forgot password?")
        let column = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .vertical, spacing: 12)),
                                         frame: CGRect(x: 20, y: 460, width: 0, height: 0), children: [button, forgot])
        let screen = app.store.addFreeScreen([title, card, row, email, password, column], name: "Account")
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.store.undoManager = undo
        if design == .fieldsSelected {
            app.selection = .several([
                .element(NodeRef(host: .screen(screen), node: email.id)), .element(NodeRef(host: .screen(screen), node: password.id)),
            ])
        }
        return app
    }

    /// The designs are captured with the harness's handles and selection.
    @Test func theDesignsAreToldAsTheHarnessTellsThem() {
        let account = CanvasPicture.capture(from: Self.make(.fieldsSelected), handles: VoiceHandles()).text(.full)
        print("VOICE-STRUCTURE canvas:\n\(account)")
        for line in ["E1 title \"Account\"", "E2 card", "E3 text \"About me\"", "E5 row, spacing 12", "E6 text \"Wi-Fi\"", "E7 toggle",
                     "E8 text field \"Email\"", "E9 text field \"Password\"", "E10 column, spacing 12", "E11 button \"Sign in\"",
                     "E12 text \"Forgot password?\""] {
            #expect(account.contains(line), "\(line)")
        }
        #expect(account.components(separatedBy: "[selected]").count == 3)
        let login = CanvasPicture.capture(from: Self.make(.login), handles: VoiceHandles()).text(.full)
        #expect(login.contains("E2 button \"Sign in\"") && login.contains("E3 image"))
    }

    @Test func structureCommandsAreScored() async throws {
        var failures: [String] = []
        var eight = (right: 0, rightTool: 0)
        for testCase in Self.cases {
            let score = await scored(testCase, failures: &failures)
            eight.right += score.right
            eight.rightTool += score.rightTool
        }
        let count = Self.cases.count * Self.runs
        print("VOICE-STRUCTURE-SUM total \(eight.right)/\(count) right, \(eight.rightTool)/\(count) right tool, model \(model)")
        _ = await scored(Self.stackControl, failures: &failures)
        // A model that couldn't be reached mustn't pass for one that picked badly.
        #expect(failures.isEmpty, "\(failures)")
    }

    /// Runs a case `runs` times, each on a fresh design in a fresh session, and prints each run and the case's sum.
    private func scored(_ testCase: Case, failures: inout [String]) async -> (right: Int, rightTool: Int) {
        var right = 0
        var rightTool = 0
        var picks: [String: Int] = [:]
        for run in 1...Self.runs {
            let app = Self.make(testCase.design)
            let handles = VoiceHandles()
            let toolbox = VoiceToolbox(model: app, handles: handles)
            toolbox.reset()
            toolbox.spokenCommand = testCase.command
            let recorder = RecordingToolbox(toolbox)
            let looker = CanvasLooker(app: app, handles: handles)
            let turns = VoiceToolTurns()
            let session = LanguageModelSession(profile: VoiceProfile(
                actor: recorder, hooks: VoiceHooks(willRun: { _ in }, didRun: { await looker.look() }, mayRun: { true }), turns: turns
            ))
            turns.session = session
            looker.session = session
            session.properties.voiceModel = .hosted(.lmStudio, model: model)
            looker.look()
            var said = ""
            var calls: [RecordingToolbox.Call] = []
            do {
                said = try await session.respond(to: testCase.command).content
                calls = recorder.calls
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
            let isRightTool = calls.first?.tool == testCase.tool
            let isRight = isRightTool && calls.count == 1 && calls[0].arguments["unreadable"] == nil && testCase.isRight(calls[0].arguments)
            if isRight { right += 1 }
            if isRightTool { rightTool += 1 }
            picks[calls.first?.tool ?? "none", default: 0] += 1
            let did = calls.isEmpty ? "no tool" : calls.map(\.description).joined(separator: "; ")
            print("VOICE-STRUCTURE run\(run) \(isRight ? "RIGHT" : isRightTool ? "TOOL " : "WRONG") “\(testCase.command)” -> \(did) | said “\(said.prefix(80))”")
        }
        let picked = picks.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("VOICE-STRUCTURE-SUM \(right)/\(Self.runs) right, \(rightTool)/\(Self.runs) right tool | “\(testCase.command)” | picks: \(picked)")
        return (right, rightTool)
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
        let line = try await inner.createScreen(name: name, description: description, device: device)
        return note("createScreen", ["name": name, "description": description, "device": device], line)
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
