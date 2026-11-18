import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

@Suite("Carrying out a spoken command", .serialized)
@MainActor
struct VoiceAgentTests {
    private typealias Step = ScriptedLanguageModel.Step

    private struct Bench {
        let app: AppModel
        let screen: DesignScreen.ID
        let agent: VoiceAgent
        let recorder: ScriptRecorder

        @MainActor var button: DesignElement? { app.store.screen(screen)?.elements.first { $0.kind == .button && $0.text != "Copy" } }
        @MainActor var undo: UndoManager? { app.store.undoManager }
    }

    /// The login design (S1: E1 title, E2 button, E3 image) and an agent whose model does
    /// what `script` says for each command, then says `closing`.
    private func bench(_ script: [String: [Step]], closing: String = "Done.") -> Bench {
        let (app, screen) = VoiceFixture.undoableLogin()
        let recorder = ScriptRecorder()
        let agent = VoiceAgent(model: app, testModel: ScriptedLanguageModel(script: script, closing: closing, recorder: recorder))
        return Bench(app: app, screen: screen, agent: agent, recorder: recorder)
    }

    private static let blueAndAhoy = [
        Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#),
        Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#),
    ]

    private static let supported = "Foundation Models runs models of the app's own from iPadOS 27.2"

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandRunsItsToolsInOrder() async throws {
        let bench = bench(["make the button blue and say ahoy": Self.blueAndAhoy])
        var steps: [String] = []
        bench.agent.onStep = { steps.append($0) }

        let outcome = await bench.agent.run("Make the button blue and say ahoy")

        let button = try #require(bench.button)
        #expect(button.tint == ColourWords.parse("blue"))
        #expect(button.text == "Ahoy")
        #expect(outcome.lines.count == 2)
        #expect(outcome.lines.last?.contains("Ahoy") == true)
        #expect(outcome.problem == nil)
        #expect(!outcome.wasCancelled)
        #expect(!outcome.endsCall)
        #expect(steps == ["Restyling…", "Rewording…"])
    }

    /// Where the pencil pointed is told with the command it was pointed for, and only that one.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aHintFromThePencilGoesWithItsCommandOnly() async throws {
        let bench = bench([:])
        _ = await bench.agent.run("a settings screen", about: .canvas(CGPoint(x: 100, y: 200)))
        #expect(bench.recorder.requests.last?.prompts.last == VoiceAgent.canvasHint + " a settings screen")
        _ = await bench.agent.run("zoom out")
        #expect(bench.recorder.requests.last?.prompts.last == "zoom out")
    }

    /// Pointed at a thing, the model is told which in so many words, not left to find it.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aThingPointedAtIsNamedWithItsCommand() async throws {
        let bench = bench([:])
        let button = try #require(bench.button)
        let selection = CanvasSelection.element(.init(host: .screen(bench.screen), element: button.id))
        bench.app.selection = selection
        _ = await bench.agent.run("remove this", about: .thing(selection))
        let prompt = try #require(bench.recorder.requests.last?.prompts.last)
        #expect(prompt.hasPrefix(#"(The person is pointing at E2, the button "#))
        #expect(prompt.hasSuffix(" remove this"))
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandIsOneUndoStep() async throws {
        let bench = bench(["make the button blue and say ahoy": Self.blueAndAhoy])
        let before = bench.app.store.content
        _ = await bench.agent.run("make the button blue and say ahoy")
        #expect(bench.app.store.content != before)
        #expect(!bench.app.store.isHoldingEdit)
        let undo = try #require(bench.undo)
        undo.undo()
        #expect(bench.app.store.content == before)
        #expect(!undo.canUndo)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func theModelIsToldTheRulesTheCanvasAndTheTools() async throws {
        let bench = bench([:])
        _ = await bench.agent.run("hello")
        let told = try #require(bench.recorder.requests.first)
        #expect(told.instructions.contains(VoiceRules.full))
        #expect(told.instructions.contains(#"S1 "Login" 393x852"#))
        #expect(told.instructions.contains(#"E2 button "Sign in""#))
        #expect(told.tools.count == 18)
        #expect(Set(told.tools).isSuperset(of: ["createScreen", "styleElement", "moveElement", "show", "undo", "endCall"]))
    }

    /// The pencil's call stays up for the next squeeze: its model isn't handed the tool that
    /// ends a call, which said "Hanging up." and hung nothing up.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func thePencilsModelCantEndTheCall() async throws {
        let (app, _) = VoiceFixture.undoableLogin()
        let recorder = ScriptRecorder()
        let agent = VoiceAgent(model: app, testModel: ScriptedLanguageModel(script: [:], closing: "Done.", recorder: recorder), canEndCall: false)
        _ = await agent.run("hello")
        let told = try #require(recorder.requests.first)
        #expect(told.tools.count == 17)
        #expect(!told.tools.contains("endCall"))
        #expect(told.tools.contains("undo"))
        // The pencil's own agent is made that way.
        #expect((PencilVoice.standardRunner(for: app) as? VoiceAgent)?.canEndCall == false)
    }

    @Test func noToolEndsThePencilsCallWhateverTheCanvas() {
        let (app, _) = VoiceFixture.undoableLogin()
        let box = VoiceToolbox(model: app, handles: VoiceHandles())
        #expect(!VoiceTools.all(box, canEndCall: false).contains { $0.name == "endCall" })
        #expect(!VoiceTools.forEmptyCanvas(box, canEndCall: false).contains { $0.name == "endCall" })
        // A phone call's model can still hang up.
        #expect(VoiceTools.all(box).contains { $0.name == "endCall" })
        #expect(VoiceTools.forEmptyCanvas(box).contains { $0.name == "endCall" })
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func thePictureIsFreshBetweenSteps() async throws {
        // The copy only exists, as E4, once the first step has run.
        let bench = bench(["copy the button": [
            Step(tool: "duplicateElement", arguments: #"{"element":"E2"}"#),
            Step(tool: "setText", arguments: #"{"element":"E4","text":"Copy"}"#),
        ]])
        let outcome = await bench.agent.run("copy the button")
        #expect(outcome.problem == nil)
        #expect(bench.app.store.screen(bench.screen)?.elements.contains { $0.kind == .button && $0.text == "Copy" } == true)
        // Three requests: one for each step, and one to hear that they are done.
        let requests = bench.recorder.requests
        #expect(requests.count == 3)
        #expect(!requests[0].instructions.contains("E4"))
        #expect(requests[1].instructions.contains(#"E4 button "Sign in""#))
        #expect(requests[2].instructions.contains(#"E4 button "Copy""#))
    }

    /// The on-device model is told about the canvas once for a command. Told again after
    /// each step, it has to read the whole of it again before it can say "Done": three
    /// seconds on an iPad, after every command.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func onTheDeviceTheCanvasIsDescribedOnceForACommand() async throws {
        let (app, _) = VoiceFixture.undoableLogin()
        let recorder = ScriptRecorder()
        let model = ScriptedLanguageModel(
            script: ["make the button green": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#)]], recorder: recorder
        )
        let agent = VoiceAgent(model: app, testModel: model, looksAgainBetweenSteps: false)

        let outcome = await agent.run("make the button green")

        #expect(outcome.lines == ["Restyled the button “Sign in”."])
        let requests = recorder.requests
        #expect(requests.count == 2)
        #expect(requests[1].instructions == requests[0].instructions)
    }

    @Test func whichModelsAreToldAboutTheCanvasAgainBetweenSteps() {
        #expect(!VoiceAgent.looksAgainBetweenSteps(with: .appleIntelligence))
        #expect(VoiceAgent.looksAgainBetweenSteps(with: .hosted(.anthropic, model: "claude-test")))
        #expect(VoiceAgent.looksAgainBetweenSteps(with: .hosted(.lmStudio, model: "local")))
    }

    /// Getting the model ready asks it nothing, and leaves it ready to be asked.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aWarmedAgentHasAskedNothingAndStillTakesCommands() async throws {
        let bench = bench(["make the button green": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#)]])
        await bench.agent.warmUp()
        #expect(bench.recorder.requests.isEmpty)
        let outcome = await bench.agent.run("make the button green")
        #expect(outcome.problem == nil)
        #expect(bench.button?.tint == ColourWords.parse("green"))
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func whatTheModelSaysReachesThePersonWithoutHandles() async throws {
        let bench = bench([:], closing: "Which one should I change, E1 or E2?")
        let outcome = await bench.agent.run("make it bigger")
        #expect(outcome.said == "Which one should I change, the title “Welcome back” or the button “Sign in”?")
    }

    // MARK: Corrections

    /// "Make the image bigger" resized a checkbox; "Not the check marks" then resized
    /// the image and left the checkbox as it was. A correction undoes the last change
    /// first, and the model is told it has.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionUndoesTheLastChangeFirst() async throws {
        let bench = bench([
            "make the image green": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#)],
            "(the last change has been undone.) not the button, the title": [Step(tool: "styleElement", arguments: #"{"element":"E1","look":"green"}"#)],
        ])
        _ = await bench.agent.run("make the image green")
        #expect(bench.button?.tint == ColourWords.parse("green"))

        let outcome = await bench.agent.run("Not the button, the title")

        #expect(outcome.problem == nil)
        #expect(bench.button?.tint == Theme.accent)
        #expect(bench.app.store.screen(bench.screen)?.elements.first { $0.kind == .title }?.tint == ColourWords.parse("green"))
        #expect(bench.recorder.requests.last?.prompts.last == "(The last change has been undone.) Not the button, the title")
        // And the two together are one step to undo, back to before either.
        bench.undo?.undo()
        #expect(bench.app.store.screen(bench.screen)?.elements.first { $0.kind == .title }?.tint == Theme.accent)
    }

    /// "No, undo revert." undid twice. A correction that says nothing more is the undo
    /// alone, and the model isn't asked.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionAloneIsOneUndo() async throws {
        let bench = bench(["make the button say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)]])
        _ = await bench.agent.run("make the button say ahoy")
        let asked = bench.recorder.requests.count

        let outcome = await bench.agent.run("No, undo revert.")

        #expect(bench.button?.text == "Sign in")
        #expect(outcome.lines == ["Undid the last change."])
        #expect(bench.recorder.requests.count == asked)
    }

    /// After a command that changed nothing, there is nothing of its to undo.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionAfterNothingChangedUndoesNothing() async throws {
        let bench = bench([
            "make the button say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)],
            "show me the first screen": [Step(tool: "show", arguments: #"{"target":"S1"}"#)],
        ])
        _ = await bench.agent.run("make the button say ahoy")
        _ = await bench.agent.run("show me the first screen")
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.button?.text == "Ahoy")
    }

    @Test func whatIsACorrection() {
        #expect(VoiceAgent.correction(in: "Not the check marks.") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "No, make it red") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "That's wrong, the title") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "No, that's wrong.") == .undoOnly)
        #expect(VoiceAgent.correction(in: "No, undo revert.") == .undoOnly)
        #expect(VoiceAgent.correction(in: "wrong one") == .undoOnly)
        #expect(VoiceAgent.correction(in: "Now make it red") == nil)
        #expect(VoiceAgent.correction(in: "Notes screen please") == nil)
        #expect(VoiceAgent.correction(in: "undo") == nil)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func theNextCommandSeesWhatTheLastOneDid() async throws {
        let bench = bench([
            "make the button say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)],
            "now make it green": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#)],
        ])
        _ = await bench.agent.run("make the button say ahoy")
        _ = await bench.agent.run("now make it green")
        let second = try #require(bench.recorder.requests.dropFirst(2).first)
        // The canvas as it now is, with the button the last command touched still selected.
        #expect(second.instructions.contains(#"E2 button "Ahoy""#))
        #expect(second.instructions.split(separator: "\n").contains { $0.contains("E2 button") && $0.contains("[selected]") })
        // And the conversation so far, so "it" has something to refer to.
        #expect(second.prompts == ["make the button say ahoy", "now make it green"])
        #expect(try #require(bench.button).tint == ColourWords.parse("green"))
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func wordsWithoutAToolAreShown() async throws {
        let bench = bench([:], closing: "There is no slider on this screen.")
        let before = bench.app.store.content
        let outcome = await bench.agent.run("make the slider wider")
        #expect(outcome.said == "There is no slider on this screen.")
        #expect(outcome.lines.isEmpty)
        #expect(outcome.problem == nil)
        #expect(bench.app.store.content == before)
        #expect(try #require(bench.undo).canUndo == false)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aToolThatCannotBeDoneIsTheProblemShown() async throws {
        let bench = bench(["make the slider blue": [Step(tool: "styleElement", arguments: #"{"element":"E99","look":"blue"}"#)]])
        let before = bench.app.store.content
        let outcome = await bench.agent.run("make the slider blue")
        #expect(outcome.problem == "There is no E99.")
        #expect(outcome.lines.isEmpty)
        #expect(bench.app.store.content == before)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func anUnknownToolIsAProblemNotACrash() async throws {
        let bench = bench([
            "paint everything": [Step(tool: "paintEverything", arguments: "{}")],
            "say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)],
        ])
        let before = bench.app.store.content
        let outcome = await bench.agent.run("paint everything")
        #expect(outcome.problem != nil)
        #expect(bench.app.store.content == before)
        #expect(!bench.app.store.isHoldingEdit)
        // The call goes on: the next command works.
        let next = await bench.agent.run("say ahoy")
        #expect(next.problem == nil)
        #expect(try #require(bench.button).text == "Ahoy")
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func argumentsThatAreNotJSONAreAProblem() async throws {
        let bench = bench([
            "break it": [Step(tool: "setText", arguments: #"{"element":"#)],
            "say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)],
        ])
        let before = bench.app.store.content
        let outcome = await bench.agent.run("break it")
        #expect(outcome.problem != nil)
        #expect(bench.app.store.content == before)
        let next = await bench.agent.run("say ahoy")
        #expect(next.problem == nil)
        #expect(try #require(bench.button).text == "Ahoy")
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func cancellingStopsTheCommandAndKeepsOneUndoStep() async throws {
        // The model takes its time over the second step, which is when it is stopped.
        let bench = bench(["three things": [
            Step(tool: "setText", arguments: #"{"element":"E2","text":"One"}"#),
            Step(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#, delay: .seconds(5)),
            Step(tool: "setText", arguments: #"{"element":"E2","text":"Three"}"#),
        ]])
        let before = bench.app.store.content
        let running = Task { await bench.agent.run("three things") }
        #expect(await eventually { bench.button?.text == "One" })
        running.cancel()
        let outcome = await running.value

        #expect(outcome.wasCancelled)
        #expect(outcome.problem == nil)
        let button = try #require(bench.button)
        #expect(button.text == "One")
        #expect(button.tint == Theme.accent)
        // What it did before it was stopped is one step, and can be taken back.
        #expect(!bench.app.store.isHoldingEdit)
        let undo = try #require(bench.undo)
        undo.undo()
        #expect(bench.app.store.content == before)
        #expect(!undo.canUndo)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandGoesOnAfterOneThatWasStopped() async throws {
        let bench = bench([
            "slow": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Slow"}"#, delay: .seconds(5))],
            "say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)],
        ])
        let running = Task { await bench.agent.run("slow") }
        try await Task.sleep(for: .milliseconds(150))
        running.cancel()
        #expect(await running.value.wasCancelled)
        let next = await bench.agent.run("say ahoy")
        #expect(next.problem == nil)
        #expect(try #require(bench.button).text == "Ahoy")
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func hangingUpIsPassedOn() async throws {
        let bench = bench(["that is all": [Step(tool: "endCall", arguments: "{}")]])
        let outcome = await bench.agent.run("that is all")
        #expect(outcome.endsCall)
        #expect(outcome.problem == nil)
    }

    @Test func trimmingKeepsTheInstructions() throws {
        func words(_ text: String) -> [Transcript.Segment] { [.text(Transcript.TextSegment(content: text))] }
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: words("rules"), toolDefinitions: []))]
        for number in 1...4 {
            entries.append(.prompt(Transcript.Prompt(segments: words("command \(number)"))))
            entries.append(.toolCalls(Transcript.ToolCalls([Transcript.ToolCall(id: "c\(number)", toolName: "setText", arguments: GeneratedContent(properties: [:]))])))
            entries.append(.toolOutput(Transcript.ToolOutput(id: "c\(number)", toolName: "setText", segments: words("ok"))))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: words("Done."))))
        }

        let trimmed = VoiceProfile.trimmed(entries, keepingCommands: 2)
        // The instructions, then the last two commands whole: a call is never parted from its result.
        #expect(trimmed.count == 9)
        guard case .instructions = trimmed[0] else {
            Issue.record("the instructions should come first")
            return
        }
        guard case .prompt(let prompt) = trimmed[1], case .text(let text) = prompt.segments.first else {
            Issue.record("the third command's prompt should follow the instructions")
            return
        }
        #expect(text.content == "command 3")
        // Nothing to trim, nothing changed.
        #expect(VoiceProfile.trimmed(entries, keepingCommands: 6).count == entries.count)
    }

    // MARK: Wave 2

    /// "No, …" after a drag by hand undoes the command's step only if it is still on top.
    /// It used to undo the drag (B-M2).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionAfterAChangeByHandLeavesThatChange() async throws {
        let bench = bench(["make the button say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)]])
        _ = await bench.agent.run("make the button say ahoy")
        let image = DesignStore.ElementRef(host: .screen(bench.screen), element: try #require(bench.app.store.screen(bench.screen)?.elements[2].id))
        bench.app.store.update(image) { $0.frame.origin.x = 60 }

        _ = await bench.agent.run("No, that's wrong.")

        #expect(bench.app.store.resolve(image)?.element.frame.origin.x == 60)
        #expect(bench.button?.text == "Ahoy")
    }

    /// A command that reaches a design after it has closed does nothing to it (B-I4).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandAfterTheDesignClosedDoesNothing() async throws {
        let bench = bench(["make the button say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)]])
        bench.app.close()
        let outcome = await bench.agent.run("make the button say ahoy")
        #expect(outcome.problem == AppModel.closedProblem)
        #expect(bench.button?.text == "Sign in")
        #expect(bench.recorder.requests.isEmpty)
    }

    /// A command running as the design closes is refused its next tool (B-I4).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandRunningAsTheDesignClosesDoesNoMore() async throws {
        let bench = bench(["two things": [
            Step(tool: "setText", arguments: #"{"element":"E2","text":"One"}"#),
            Step(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#, delay: .milliseconds(300)),
        ]])
        let running = Task { await bench.agent.run("two things") }
        #expect(await eventually { bench.button?.text == "One" })
        bench.app.close()
        _ = await running.value
        #expect(bench.button?.tint == Theme.accent)
    }

    /// The session starts afresh after so many commands, so that the pencil's, which lives
    /// as long as the design, doesn't keep every word for good (B-M5).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func theSessionStartsAfreshAfterSoManyCommands() async throws {
        let bench = bench([:])
        bench.agent.commandsPerSession = 2
        _ = await bench.agent.run("one")
        _ = await bench.agent.run("two")
        #expect(bench.recorder.requests.last?.prompts == ["one", "two"])
        _ = await bench.agent.run("three")
        #expect(bench.recorder.requests.last?.prompts == ["three"])
    }
}
