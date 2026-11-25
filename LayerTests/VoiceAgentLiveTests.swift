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
/// tools, at the app's own settings. Asked for as `VoiceAgentLiveTests` is, and run with
/// `-only-testing:LayerTests/VoiceStructureLiveTests`.
///
/// A recorder stands in for the design and answers every call as the harness's does, so that a case is scored as the
/// harness scores it, by the model's first pick: "right" is the right tool with the right arguments and no other call;
/// "right tool" is a first call to the right tool. Each case runs three times, each in a fresh session. A line beginning
/// `VOICE-STRUCTURE` is printed for each run, and one beginning `VOICE-STRUCTURE-SUM` for each case and for the whole,
/// which "Structure wording (2026-11-26)" in docs/benchmarks/voice-on-device.md is written from.
@Suite(
    "Structure commands with a real model in LM Studio", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] != nil && HostedLanguageModel.isSupported, "set TEST_RUNNER_LAYER_LMSTUDIO=<model id> to run")
)
@MainActor
struct VoiceStructureLiveTests {
    let model = ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] ?? ""
    static let runs = 3

    struct Case {
        var command: String
        var picture = VoiceStructureLiveTests.account(fieldsSelected: false)
        var tool: String
        var isRight: ([String: String]) -> Bool
    }

    /// The harness's `structureCases`, with the same canvas and selection and the same test of the arguments.
    static let cases: [Case] = [
        Case(command: "Put these in a column", picture: account(fieldsSelected: true), tool: "groupElements",
             isRight: { ["E8", "E9"].allSatisfy(($0["elements"] ?? "").contains) && ($0["as"] ?? "").lowercased().contains("column") }),
        Case(command: "Make these a row", picture: account(fieldsSelected: true), tool: "groupElements",
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

    /// A control beyond the eight, for the wording that sends "put these in a column" to `groupElements`: "stack" still
    /// goes to `stackElements`, as the harness's command from the iPad has it, over its "Login" screen with the button
    /// selected. Scored apart from the eight.
    static let stackControl = Case(
        command: "Stack the title, the button and the image into a column.", picture: login, tool: "stackElements",
        isRight: { ($0["direction"] ?? "").lowercased().contains("column") && ["E1", "E2", "E3"].allSatisfy(($0["elements"] ?? "").contains) }
    )

    /// The harness's "Login" screen: a title, the "Sign in" button, selected, and an image.
    static let login = CanvasPicture(screens: [CanvasPicture.Screen(
        handle: "S1", name: "Login", size: CGSize(width: 393, height: 852), visibleShare: 1,
        elements: [
            .init(handle: "E1", kind: "title", text: "Welcome back", frame: CGRect(x: 20, y: 75, width: 353, height: 41)),
            .init(handle: "E2", kind: "button", text: "Sign in", frame: CGRect(x: 20, y: 420, width: 353, height: 50), look: ["colour accent"], isSelected: true),
            .init(handle: "E3", kind: "image", text: "", frame: CGRect(x: 20, y: 500, width: 200, height: 200)),
        ]
    )])

    /// The harness's "Account" screen: a title, a free card (E2: a text and a body), a row (E5: the text "Wi-Fi" and a
    /// toggle), two text fields (E8, E9) and a column (E10: a "Sign in" button and a text).
    nonisolated static func account(fieldsSelected: Bool) -> CanvasPicture {
        CanvasPicture(screens: [CanvasPicture.Screen(
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
                .init(handle: "E8", kind: "text field", text: "Email", frame: CGRect(x: 20, y: 320, width: 353, height: 44), isSelected: fieldsSelected),
                .init(handle: "E9", kind: "text field", text: "Password", frame: CGRect(x: 20, y: 380, width: 353, height: 44), isSelected: fieldsSelected),
                .init(handle: "E10", kind: "group", text: "", frame: CGRect(x: 20, y: 460, width: 353, height: 82), layout: "column, spacing 12", isContainer: true, children: [
                    .init(handle: "E11", kind: "button", text: "Sign in", frame: CGRect(x: 20, y: 460, width: 353, height: 50), look: ["colour accent"]),
                    .init(handle: "E12", kind: "text", text: "Forgot password?", frame: CGRect(x: 20, y: 522, width: 150, height: 20)),
                ]),
            ]
        )])
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

    /// Runs a case `runs` times, each in a fresh session, and prints each run and the case's sum.
    private func scored(_ testCase: Case, failures: inout [String]) async -> (right: Int, rightTool: Int) {
        var right = 0
        var rightTool = 0
        var picks: [String: Int] = [:]
        for run in 1...Self.runs {
            let recorder = StructureRecorder()
            let turns = VoiceToolTurns()
            let session = LanguageModelSession(profile: VoiceProfile(
                actor: recorder, hooks: VoiceHooks(willRun: { _ in }, didRun: {}, mayRun: { true }), turns: turns
            ))
            turns.session = session
            session.properties.voiceModel = .hosted(.lmStudio, model: model)
            session.properties.canvasPicture = testCase.picture
            var said = ""
            var calls: [StructureRecorder.Call] = []
            do {
                said = try await session.respond(to: testCase.command).content
                calls = recorder.calls
            } catch let error as LanguageModelSession.ToolCallError {
                // The model asked for a tool whose arguments couldn't be read, such as a number where the tool takes
                // text: that tool was picked, wrongly asked, and in the app the command would change nothing.
                calls = recorder.calls + [.init(tool: error.tool.name, arguments: ["unreadable": "\(error.underlyingError)"])]
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

/// Writes down what the model asks for and answers as the voice harness's recorder does: every call goes through.
@MainActor
final class StructureRecorder: VoiceActing {
    struct Call: CustomStringConvertible {
        var tool: String
        var arguments: [String: String]

        var description: String {
            "\(tool)(\(arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")))"
        }
    }

    private(set) var calls: [Call] = []
    private var made = 20

    private func note(_ tool: String, _ arguments: [String: String?], saying line: String) -> String {
        calls.append(Call(tool: tool, arguments: arguments.compactMapValues { $0 }))
        return line
    }

    func createScreen(name: String?, description: String, device: String?) async throws -> String {
        note("createScreen", ["name": name, "description": description, "device": device], saying: "Made the screen as S9, with 6 elements.")
    }

    func addElement(screen: String?, kind: String, text: String?, look: String?, relation: String?, target: String?) -> String {
        made += 1
        return note("addElement", ["screen": screen, "kind": kind, "text": text, "look": look, "relation": relation, "target": target], saying: "Added a \(kind) as E\(made).")
    }

    func stackElements(elements: String, direction: String) -> String {
        note("stackElements", ["elements": elements, "direction": direction], saying: "Stacked the elements in a \(direction).")
    }

    func placeElement(element: String, relation: String, target: String) -> String {
        note("placeElement", ["element": element, "relation": relation, "target": target], saying: "Put \(element) \(relation) \(target).")
    }

    func setText(element: String, text: String) -> String {
        note("setText", ["element": element, "text": text], saying: "Reworded \(element) to “\(text)”.")
    }

    func styleElement(element: String, look: String) -> String {
        note("styleElement", ["element": element, "look": look], saying: "Restyled \(element).")
    }

    func moveElement(element: String, x: String?, y: String?, width: String?, height: String?, takeOut: String?) -> String {
        note("moveElement", ["element": element, "x": x, "y": y, "width": width, "height": height, "takeOut": takeOut], saying: "Resized \(element).")
    }

    func rotateElement(element: String, angle: String?, by: String?) -> String {
        note("rotateElement", ["element": element, "angle": angle, "by": by], saying: "Turned \(element).")
    }

    func alignElement(element: String, alignment: String) -> String {
        note("alignElement", ["element": element, "alignment": alignment], saying: "Aligned \(element) to the \(alignment).")
    }

    func duplicateElement(element: String) -> String {
        made += 1
        return note("duplicateElement", ["element": element], saying: "Duplicated \(element) as E\(made).")
    }

    func deleteElement(element: String, named: String?) -> String {
        note("deleteElement", ["element": element, "named": named], saying: "Deleted \(element).")
    }

    func renameScreen(screen: String, name: String) -> String {
        note("renameScreen", ["screen": screen, "name": name], saying: "Renamed \(screen) to “\(name)”.")
    }

    func deleteScreen(screen: String, named: String?) -> String {
        note("deleteScreen", ["screen": screen, "named": named], saying: "Deleted \(screen).")
    }

    func tidyScreen(screen: String?) -> String {
        note("tidyScreen", ["screen": screen], saying: "Tidied the layout of \(screen ?? "the screen").")
    }

    func changeScreenDevice(screen: String?, device: String) -> String {
        note("changeScreenDevice", ["screen": screen, "device": device], saying: "Made \(screen ?? "the screen") a \(device) screen.")
    }

    func groupElements(elements: String, as shape: String) -> String {
        made += 1
        return note("groupElements", ["elements": elements, "as": shape], saying: "Put \(elements) in a \(shape), E\(made).")
    }

    func setLayout(target: String, layout: String?, spacing: String?) -> String {
        let said = [layout, spacing.map { "spacing \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return note("setLayout", ["target": target, "layout": layout, "spacing": spacing], saying: "\(target) is now \(said).")
    }

    func ungroup(element: String) -> String {
        note("ungroup", ["element": element], saying: "Took what \(element) held out of it.")
    }

    func reorder(element: String, position: String, target: String) -> String {
        note("reorder", ["element": element, "position": position, "target": target], saying: "Moved \(element) \(position) \(target).")
    }

    func show(target: String) -> String { note("show", ["target": target], saying: "Showing \(target).") }
    func pan(direction: String) -> String { note("pan", ["direction": direction], saying: "Moved the view \(direction).") }
    func zoom(to level: String) -> String { note("zoom", ["level": level], saying: "Zoomed \(level).") }
    func undo() -> String { note("undo", [:], saying: "Undid the last change.") }
    func redo() -> String { note("redo", [:], saying: "Redid the last change.") }
    func endCall() -> String { note("endCall", [:], saying: "Hanging up.") }
}
