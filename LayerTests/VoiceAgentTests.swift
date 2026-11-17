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
        #expect(told.tools.count == 17)
        #expect(Set(told.tools).isSuperset(of: ["createScreen", "styleElement", "moveElement", "show", "undo", "endCall"]))
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
}
