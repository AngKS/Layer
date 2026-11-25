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
        let screen: TreeScreen.ID
        let agent: VoiceAgent
        let recorder: ScriptRecorder

        @MainActor var button: LayerNode? { app.store.screenLeaves(screen).first { $0.kind == .button && $0.content.text != "Copy" } }
        /// The button's frame in its screen's points.
        @MainActor var buttonFrame: CGRect? { button.flatMap { app.store.ownFrame($0.id) } }
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
        #expect(button.resolvedTint == ColourWords.parse("blue"))
        #expect(button.content.text == "Ahoy")
        #expect(outcome.lines.count == 2)
        #expect(outcome.lines.last?.contains("Ahoy") == true)
        #expect(outcome.problem == nil)
        #expect(!outcome.wasCancelled)
        #expect(!outcome.endsCall)
        #expect(steps == ["Restyling…", "Rewording…"])
    }

    // MARK: Several tools in one answer

    /// The on-device model asks for all of a command's tools in one answer, and the session
    /// runs those at the same time: the second screen was refused with "A screen is
    /// already being written" while the first was. They run one at a time (V2).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func toolsAskedForTogetherRunOneAtATime() async throws {
        let bench = bench(["a profile and a settings screen": Step.together([
            Step(tool: "createScreen", arguments: #"{"name":"Profile","description":"a profile screen"}"#),
            Step(tool: "createScreen", arguments: #"{"name":"Settings","description":"a settings screen"}"#),
        ])])
        // Each screen is written a moment after it is asked for.
        bench.app.screenStream = { request in
            AsyncThrowingStream { feed in
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    feed.yield(.screen(Outline.parse("title: \(request.description)\n", isComplete: true)))
                    feed.finish()
                }
            }
        }

        let outcome = await bench.agent.run("a profile and a settings screen")

        #expect(outcome.problem == nil)
        #expect(bench.app.store.tree.screens.map(\.name) == ["Login", "Profile", "Settings"])
        #expect(outcome.lines.count == 2)
        #expect(outcome.lines.first?.contains("Profile") == true)
    }

    /// A screen that takes longer to write than a call waits for its turn: the second
    /// screen of the answer still waits for it, as the call ahead is running, not left
    /// out. It ran early and was refused, "A screen is already being written" (review of V2).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCallWaitsAsLongAsTheCallAheadIsRunning() async throws {
        let (app, _) = VoiceFixture.undoableLogin()
        let handles = VoiceHandles()
        let toolbox = VoiceToolbox(model: app, handles: handles)
        let turns = VoiceToolTurns()
        turns.patience = .milliseconds(100)
        let model = ScriptedLanguageModel(script: ["a profile and a settings screen": Step.together([
            Step(tool: "createScreen", arguments: #"{"name":"Profile","description":"a profile screen"}"#),
            Step(tool: "createScreen", arguments: #"{"name":"Settings","description":"a settings screen"}"#),
        ])])
        let session = LanguageModelSession(profile: VoiceProfile(
            actor: toolbox, hooks: VoiceHooks(willRun: { _ in }, didRun: {}, mayRun: { true }), turns: turns, testModel: model
        ))
        turns.session = session
        // Each screen takes four times as long to write as a call waits for its turn.
        app.screenStream = { request in
            AsyncThrowingStream { feed in
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    feed.yield(.screen(Outline.parse("title: \(request.description)\n", isComplete: true)))
                    feed.finish()
                }
            }
        }
        session.properties.canvasPicture = CanvasPicture.capture(from: app, handles: handles)

        app.store.beginHeldEdit()
        _ = try await session.respond(to: "a profile and a settings screen")
        app.store.endHeldEdit()

        #expect(toolbox.failures.isEmpty)
        #expect(app.store.tree.screens.map(\.name) == ["Login", "Profile", "Settings"])
    }

    // MARK: Taking turns

    /// A session whose transcript a test writes, and the turns taken against it.
    private static func turnsWithATranscript() -> (session: LanguageModelSession, turns: VoiceToolTurns) {
        let session = LanguageModelSession(model: ScriptedLanguageModel(script: [:]))
        let turns = VoiceToolTurns()
        turns.session = session
        return (session, turns)
    }

    /// An answer asking for calls with these ids, as its transcript entry.
    private static func answer(_ ids: String...) -> Transcript.Entry {
        .toolCalls(Transcript.ToolCalls(ids.map { Transcript.ToolCall(id: $0, toolName: "setText", arguments: GeneratedContent(properties: [:])) }))
    }

    /// Waits for `call`'s turn, giving up after a second. False if it didn't come.
    private static func turnComes(for call: String, in turns: VoiceToolTurns) async -> Bool {
        let waiting = Task { await turns.waitForTurn(of: call) }
        let timer = Task {
            try await Task.sleep(for: .seconds(1))
            waiting.cancel()
        }
        defer { timer.cancel() }
        return await waiting.value
    }

    /// A call id the model used in an earlier answer takes its place in the new one. It
    /// kept its old place: run out of turn, and when it ran first the call after it waited
    /// for good. An answer is known by its transcript entry (review of V2).
    @Test func aCallIdUsedAgainTakesItsPlaceInItsNewAnswer() async {
        let (session, turns) = Self.turnsWithATranscript()
        session.transcript.append(Self.answer("a"))
        #expect(await Self.turnComes(for: "a", in: turns))
        turns.finished()

        // "a" again, then "c": "a" goes first, and "c" once "a" has run.
        session.transcript.append(Self.answer("a", "c"))
        #expect(await Self.turnComes(for: "a", in: turns))
        turns.finished()
        #expect(await Self.turnComes(for: "c", in: turns))
        turns.finished()

        // "x", then "a" again: "a" waits for "x".
        session.transcript.append(Self.answer("x", "a"))
        #expect(!(await Self.turnComes(for: "a", in: turns)))
    }

    /// A call whose turn never comes, because the session left out the call ahead of it
    /// without cancelling the rest, runs anyway once it has waited long enough (review of V2).
    @Test func aCallWaitsOnlySoLongForItsTurn() async {
        let (session, turns) = Self.turnsWithATranscript()
        turns.patience = .milliseconds(100)
        session.transcript.append(Self.answer("left out", "next"))
        #expect(await Self.turnComes(for: "next", in: turns))
    }

    /// A tool that throws ends its answer: the calls waiting behind it give up rather
    /// than run (review of V2).
    @Test func aToolThatThrowsStopsTheRestOfItsAnswer() async throws {
        let (session, turns) = Self.turnsWithATranscript()
        session.transcript.append(Self.answer("1", "2"))
        #expect(await Self.turnComes(for: "1", in: turns))
        let second = Task { await turns.waitForTurn(of: "2") }
        try await Task.sleep(for: .milliseconds(50))

        let failing = TakingTurns(FailingTool(), turns: turns)
        await #expect(throws: FailingTool.Failure.self) {
            try await failing.call(arguments: FailingTool.Arguments(GeneratedContent(properties: ["note": "x"])))
        }

        #expect(await second.value == false)
    }

    /// End to end: a call id used again in a later answer of the same command, with a
    /// call after it. The command finishes, each step in the order asked (review of V2).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCallIdUsedAgainTakesItsPlaceInTheNewAnswer() async throws {
        for _ in 1...5 {
            let bench = bench(["two answers": [Step(tool: "setText", arguments: #"{"element":"E2","text":"One"}"#, id: "a")] + Step.together([
                Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#, id: "a"),
                Step(tool: "setText", arguments: #"{"element":"E2","text":"Two"}"#, id: "c"),
            ])])

            let outcome = try #require(await Self.run("two answers", on: bench.agent, within: .seconds(3)))

            #expect(outcome.lines.count == 3)
            #expect(bench.button?.content.text == "Two")
            #expect(bench.button?.resolvedTint == ColourWords.parse("blue"))
        }
    }

    /// Runs `command`, and stops it if it is still running after `limit`. Nil if it had to be stopped.
    private static func run(_ command: String, on agent: VoiceAgent, within limit: Duration) async -> VoiceOutcome? {
        let running = Task { await agent.run(command) }
        let timer = Task {
            try await Task.sleep(for: limit)
            running.cancel()
        }
        let outcome = await running.value
        timer.cancel()
        return outcome.wasCancelled ? nil : outcome
    }

    /// "Make the title bold and duplicate it", asked for in one answer: the copy is made
    /// after the bold, so it is bold too, every time (V2).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func toolsAskedForTogetherRunInTheOrderAsked() async throws {
        for _ in 1...20 {
            let bench = bench(["make the title bold and duplicate it": Step.together([
                Step(tool: "styleElement", arguments: #"{"element":"E1","look":"bold"}"#),
                Step(tool: "duplicateElement", arguments: #"{"element":"E1"}"#),
            ])])
            var steps: [String] = []
            bench.agent.onStep = { steps.append($0) }

            let outcome = await bench.agent.run("make the title bold and duplicate it")

            let titles = bench.app.store.screenLeaves(bench.screen).filter { $0.kind == .title }
            #expect(titles.count == 2)
            #expect(titles.allSatisfy { $0.style.fontWeight == .bold })
            #expect(steps == ["Restyling…", "Duplicating…"])
            #expect(outcome.lines.first?.hasPrefix("Restyled") == true)
        }
    }

    /// "Undo that and make it blue" in one answer undoes the last command, not the blue
    /// (V2). The undo is slow to start, so that left to the session the blue would always
    /// go first, and its undo would take back the blue instead.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func anUndoAskedForWithAChangeUndoesTheCommandBefore() async throws {
        let (app, screen) = VoiceFixture.undoableLogin()
        let handles = VoiceHandles()
        let turns = VoiceToolTurns()
        let hooks = VoiceHooks(
            willRun: { tool in if tool == "undo" { try? await Task.sleep(for: .milliseconds(200)) } },
            didRun: {}, mayRun: { true }
        )
        let model = ScriptedLanguageModel(script: ["undo that and make it blue": Step.together([
            Step(tool: "undo", arguments: "{}"),
            Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#),
        ])])
        let session = LanguageModelSession(profile: VoiceProfile(actor: VoiceToolbox(model: app, handles: handles), hooks: hooks, turns: turns, testModel: model))
        turns.session = session
        // The command before: the button says Ahoy, a step of its own.
        let button = NodeRef(host: .screen(screen), node: app.store.screenLeaves(screen)[1].id)
        app.store.update(button.node) { $0.content.text = "Ahoy" }
        session.properties.canvasPicture = CanvasPicture.capture(from: app, handles: handles)

        // Held as one step, as `VoiceAgent.run` holds a command.
        app.store.beginHeldEdit()
        _ = try await session.respond(to: "undo that and make it blue")
        app.store.endHeldEdit()

        let after = try #require(app.store.node(button.node))
        #expect(after.content.text == "Sign in")
        #expect(after.resolvedTint == ColourWords.parse("blue"))
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
        let selection = CanvasSelection.element(.init(host: .screen(bench.screen), node: button.id))
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

    /// The Edit menu, the shortcut list and the undo HUD name a spoken command's step,
    /// rather than a bare "Undo" (V8).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandsUndoStepIsNamed() async throws {
        // Both ways a history can group: the tests' own, and the document's, by event.
        for groupsByEvent in [false, true] {
            let bench = bench(["make the button blue": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#)]])
            let undo = try #require(bench.undo)
            undo.groupsByEvent = groupsByEvent
            _ = await bench.agent.run("make the button blue")
            #expect(undo.undoActionName == "Voice Command")
            undo.undo()
            #expect(undo.redoActionName == "Voice Command")
        }
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func theModelIsToldTheRulesTheCanvasAndTheTools() async throws {
        let bench = bench([:])
        _ = await bench.agent.run("hello")
        let told = try #require(bench.recorder.requests.first)
        #expect(told.instructions.contains(VoiceRules.full))
        #expect(told.instructions.contains(#"S1 "Login" 393x852"#))
        #expect(told.instructions.contains(#"E2 button "Sign in""#))
        #expect(told.tools.count == 25)
        #expect(Set(told.tools).isSuperset(of: ["createScreen", "styleElement", "moveElement", "rotateElement", "tidyScreen", "changeScreenDevice", "show", "undo", "endCall"]))
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
        #expect(told.tools.count == 24)
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
        #expect(bench.app.store.screenLeaves(bench.screen).contains { $0.kind == .button && $0.content.text == "Copy" } == true)
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
        #expect(VoiceAgent.looksAgainBetweenSteps(with: .hosted(.anthropic, model: "claude-test")) == HostedLanguageModel.isSupported)
        #expect(VoiceAgent.looksAgainBetweenSteps(with: .hosted(.lmStudio, model: "local")) == HostedLanguageModel.isSupported)
    }

    /// A design that names a provider but no model is carried out by the on-device model,
    /// so it isn't told about the canvas again between steps either: three seconds a
    /// command, measured on an iPad (V9).
    @Test func aChoiceThatFallsBackOnTheDeviceIsntToldAgain() {
        #expect(!VoiceAgent.looksAgainBetweenSteps(with: ModelChoice(provider: HostedProvider.openAI.rawValue, model: nil)))
    }

    /// Getting the model ready asks it nothing, and leaves it ready to be asked.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aWarmedAgentHasAskedNothingAndStillTakesCommands() async throws {
        let bench = bench(["make the button green": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#)]])
        await bench.agent.warmUp()
        #expect(bench.recorder.requests.isEmpty)
        let outcome = await bench.agent.run("make the button green")
        #expect(outcome.problem == nil)
        #expect(bench.button?.resolvedTint == ColourWords.parse("green"))
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
        #expect(bench.button?.resolvedTint == ColourWords.parse("green"))

        let outcome = await bench.agent.run("Not the button, the title")

        #expect(outcome.problem == nil)
        #expect(bench.button?.resolvedTint == Theme.accent)
        #expect(bench.app.store.screenLeaves(bench.screen).first { $0.kind == .title }?.resolvedTint == ColourWords.parse("green"))
        #expect(bench.recorder.requests.last?.prompts.last == "(The last change has been undone.) Not the button, the title")
        // And the two together are one step to undo, back to before either.
        bench.undo?.undo()
        #expect(bench.app.store.screenLeaves(bench.screen).first { $0.kind == .title }?.resolvedTint == Theme.accent)
    }

    /// "No, undo revert." undid twice. A correction that says nothing more is the undo
    /// alone, and the model isn't asked.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionAloneIsOneUndo() async throws {
        let bench = bench(["make the button say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)]])
        _ = await bench.agent.run("make the button say ahoy")
        let asked = bench.recorder.requests.count

        let outcome = await bench.agent.run("No, undo revert.")

        #expect(bench.button?.content.text == "Sign in")
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
        #expect(bench.button?.content.text == "Ahoy")
    }

    /// Ink drawn, or anything else done by hand, while a command runs is a step of its
    /// own. It used to join the command's step, so "No, …" undid it with the command, and
    /// the command's next change cleared the redo that could have brought it back (V1).
    /// Here the command changes nothing itself, and its correction has nothing to undo.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionNeverUndoesInkDrawnWhileTheCommandRan() async throws {
        let bench = bench(["show me the first screen": [Step(tool: "show", arguments: #"{"target":"S1"}"#, delay: .milliseconds(300))]])
        async let first = bench.agent.run("show me the first screen")
        try await Task.sleep(for: .milliseconds(50))
        bench.app.store.addCanvasNode(LayerNode.standard(.drawing), scale: 1)  // as `inkChanged` does
        _ = await first
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.app.store.tree.canvasLeaves.contains { $0.kind == .drawing })
    }

    /// The command restyles the button, then rewords it; between the two, a finger moves
    /// that same button. The command's step can't go back above the move without the move
    /// being taken back with it, so a correction leaves both alone rather than undo the move.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionNeverUndoesAMoveByHandMadeWhileTheCommandRan() async throws {
        let bench = bench(["make the button blue and say ahoy": [
            Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#),
            Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#, delay: .milliseconds(300)),
        ]])
        let button = try #require(bench.button)
        let ref = NodeRef(host: .screen(bench.screen), node: button.id)
        async let first = bench.agent.run("make the button blue and say ahoy")
        #expect(await eventually { bench.button?.resolvedTint == ColourWords.parse("blue") })
        bench.app.store.update(ref.node) { $0.frame.origin.y = 300 }
        _ = await first
        #expect(bench.button?.content.text == "Ahoy")
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.buttonFrame?.origin.y == 300)
    }

    /// When the correction can't undo the command, the model is asked, and its `undo`
    /// tool took back the top step: the person's own move (review I-2). The model's undo
    /// takes back only a command's step; told so, it goes on with what was asked.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func theModelsUndoNeverTakesBackAMoveByHand() async throws {
        let correct = [
            Step(tool: "undo", arguments: "{}"),
            Step(tool: "styleElement", arguments: #"{"element":"E2","look":"red"}"#),
        ]
        let bench = bench([
            "make the button blue and say ahoy": [
                Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#),
                Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#, delay: .milliseconds(300)),
            ],
            "no, make it red": correct,
            "(the last change was not undone: something has been changed by hand since, and that must not be undone.) no, make it red": correct,
            "no, that's wrong.": [Step(tool: "undo", arguments: "{}")],
        ])
        let button = try #require(bench.button)
        let ref = NodeRef(host: .screen(bench.screen), node: button.id)
        async let first = bench.agent.run("make the button blue and say ahoy")
        #expect(await eventually { bench.button?.resolvedTint == ColourWords.parse("blue") })
        bench.app.store.update(ref.node) { $0.frame.origin.y = 300 }
        _ = await first

        _ = await bench.agent.run("No, make it red")
        #expect(bench.buttonFrame?.origin.y == 300)
        #expect(bench.button?.resolvedTint == ColourWords.parse("red"))
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.buttonFrame?.origin.y == 300)
    }

    /// "Undo" said outright is the Undo button, whoever made the last change; a correction
    /// takes back only the command's own (I-2).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func undoSaidOutrightIsTheUndoButtonAndACorrectionIsNot() async throws {
        let bench = bench([
            "undo": [Step(tool: "undo", arguments: "{}")],
            "make the button blue": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#)],
            "no, that's wrong.": [Step(tool: "undo", arguments: "{}")],
        ])
        let ref = NodeRef(host: .screen(bench.screen), node: try #require(bench.button).id)
        // A move by hand, then "undo": the move is undone.
        bench.app.store.update(ref.node) { $0.frame.origin.y = 300 }
        _ = await bench.agent.run("undo")
        #expect(bench.buttonFrame?.origin.y == 420)
        // A move by hand, then "No, that's wrong.": the move stays.
        bench.app.store.update(ref.node) { $0.frame.origin.y = 300 }
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.buttonFrame?.origin.y == 300)
        // A command, then "undo": the command is undone.
        _ = await bench.agent.run("make the button blue")
        #expect(bench.button?.resolvedTint == ColourWords.parse("blue"))
        _ = await bench.agent.run("undo")
        #expect(bench.button?.resolvedTint == Theme.accent)
        #expect(bench.buttonFrame?.origin.y == 300)
    }

    /// Ink drawn while a command that changed nothing ran, then "No, that's wrong.": the
    /// model, asked, undid the ink (review I-2). A correction with nothing of the command's
    /// to undo says so, without asking the model.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionWithNothingToUndoDoesNotAskTheModel() async throws {
        let bench = bench([
            "show me the first screen": [Step(tool: "show", arguments: #"{"target":"S1"}"#, delay: .milliseconds(300))],
            "no, that's wrong.": [Step(tool: "undo", arguments: "{}")],
        ])
        async let first = bench.agent.run("show me the first screen")
        try await Task.sleep(for: .milliseconds(50))
        bench.app.store.addCanvasNode(LayerNode.standard(.drawing), scale: 1)
        _ = await first
        let asked = bench.recorder.requests.count
        let outcome = await bench.agent.run("No, that's wrong.")
        #expect(bench.app.store.tree.canvasLeaves.contains { $0.kind == .drawing })
        #expect(bench.recorder.requests.count == asked)
        #expect(outcome.problem != nil)
    }

    /// A drag made while a command ran and let go where it began leaves no step. The
    /// command's step was on top again, but was taken not to be, so "No, …" declined
    /// (review M-4).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionUndoesTheCommandAfterADragThatCameToNothing() async throws {
        let bench = bench(["make the button blue and say ahoy": [
            Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#),
            Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#, delay: .milliseconds(300)),
        ]])
        let image = try #require(bench.app.store.screenLeaves(bench.screen).last)
        let ref = NodeRef(host: .screen(bench.screen), node: image.id)
        async let first = bench.agent.run("make the button blue and say ahoy")
        #expect(await eventually { bench.button?.resolvedTint == ColourWords.parse("blue") })
        let drag = bench.app.store.beginEdit()
        bench.app.store.act(for: drag) { bench.app.store.update(ref.node) { $0.frame.origin.x = 60 } }
        bench.app.store.act(for: drag) { bench.app.store.update(ref.node) { $0.frame.origin.x = image.frame.origin.x } }
        bench.app.store.endEdit(drag)
        _ = await first
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.button?.resolvedTint == Theme.accent)
        #expect(bench.button?.content.text == "Sign in")
    }

    /// The corrections above with the history the document really has, which groups by
    /// event: the agent's work turns the run loop between its steps.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func correctionsWorkWithAHistoryGroupedByEvent() async throws {
        let bench = bench([
            "make the button blue": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#, delay: .milliseconds(100))],
            "make the button blue and say ahoy": [
                Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#),
                Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#, delay: .milliseconds(200)),
            ],
            "no, that's wrong.": [Step(tool: "undo", arguments: "{}")],
        ])
        let undo = try #require(bench.undo)
        undo.groupsByEvent = true
        try await Task.sleep(for: .milliseconds(5))
        undo.removeAllActions()
        // Ink drawn before the command changed anything: the correction takes back the command.
        async let first = bench.agent.run("make the button blue")
        try await Task.sleep(for: .milliseconds(20))
        bench.app.store.addCanvasNode(LayerNode.standard(.drawing), scale: 1)
        _ = await first
        try await Task.sleep(for: .milliseconds(5))
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.button?.resolvedTint == Theme.accent)
        #expect(bench.app.store.tree.canvasLeaves.contains { $0.kind == .drawing })
        // A move by hand of what the command changed: neither it nor the command is undone.
        let ref = NodeRef(host: .screen(bench.screen), node: try #require(bench.button).id)
        async let second = bench.agent.run("make the button blue and say ahoy")
        #expect(await eventually { bench.button?.resolvedTint == ColourWords.parse("blue") })
        bench.app.store.update(ref.node) { $0.frame.origin.y = 300 }
        _ = await second
        try await Task.sleep(for: .milliseconds(5))
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.buttonFrame?.origin.y == 300)
        #expect(bench.app.store.tree.canvasLeaves.contains { $0.kind == .drawing })
    }

    /// Ink drawn while the model was still thinking, before the command changed anything:
    /// the correction takes back the command, and only the command.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionTakesBackTheCommandAndLeavesInkDrawnMeanwhile() async throws {
        let bench = bench(["make the button blue": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#, delay: .milliseconds(300))]])
        async let first = bench.agent.run("make the button blue")
        try await Task.sleep(for: .milliseconds(50))
        bench.app.store.addCanvasNode(LayerNode.standard(.drawing), scale: 1)
        _ = await first
        #expect(bench.button?.resolvedTint == ColourWords.parse("blue"))
        _ = await bench.agent.run("No, that's wrong.")
        #expect(bench.button?.resolvedTint == Theme.accent)
        #expect(bench.app.store.tree.canvasLeaves.contains { $0.kind == .drawing })
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

    /// "No border", "Not bold": a look said with "no" or "not" is a command of its own.
    /// It was taken for a correction, and undid the last command (V3).
    @Test func aLookSaidWithNoOrNotIsNotACorrection() {
        #expect(VoiceAgent.correction(in: "No border on the button") == nil)
        #expect(VoiceAgent.correction(in: "not bold") == nil)
        #expect(VoiceAgent.correction(in: "Not bold.") == nil)
        #expect(VoiceAgent.correction(in: "No shadow") == nil)
        #expect(VoiceAgent.correction(in: "No rounded corners") == nil)
        #expect(VoiceAgent.correction(in: "no more shadow on the card") == nil)
        #expect(VoiceAgent.correction(in: "Not so big") == nil)
    }

    /// A correction says so: "no" or "not" with a pause after it, or words that correct.
    @Test func aCorrectionSaysItIsOne() {
        #expect(VoiceAgent.correction(in: "No, make it red") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "No. The title.") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "Not the check marks.") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "Not that, the title") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "No I meant the title") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "no the other one") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "Nope, bigger") == .undoThenAsk)
        #expect(VoiceAgent.correction(in: "No") == .undoOnly)
        #expect(VoiceAgent.correction(in: "No.") == .undoOnly)
        #expect(VoiceAgent.correction(in: "no not that one") == .undoOnly)
        #expect(VoiceAgent.correction(in: "No that's wrong") == .undoOnly)
        #expect(VoiceAgent.correction(in: "Oops") == .undoOnly)
    }

    /// The fallback recogniser writes no commas, and phrases are joined with a space, so
    /// "No, make it red" can arrive as "No make it red". Words that can't follow the "no"
    /// of a look still make it a correction, and "not X, Y" says what was meant instead.
    /// A pause that ends a sentence, as in "No. Border.", is one only when what follows is
    /// one; "no thanks" turns something down and undoes nothing (review of V3).
    @Test func correctionsWithoutACommaAndLooksWithNo() {
        let expected: [(String, VoiceAgent.Correction?)] = [
            ("no, make it red", .undoThenAsk), ("No make it red", .undoThenAsk), ("no I meant the title", .undoThenAsk),
            ("not that one, the button", .undoThenAsk), ("no — bigger", .undoThenAsk), ("no - bigger", .undoThenAsk),
            ("no—bigger", .undoThenAsk), ("No bigger", .undoThenAsk), ("No it should be blue", .undoThenAsk),
            ("no it's the title", .undoThenAsk), ("no change it to blue", .undoThenAsk), ("no put it at the top", .undoThenAsk),
            ("no just the title", .undoThenAsk), ("no actually the title", .undoThenAsk), ("not red, blue", .undoThenAsk),
            ("not bigger, smaller", .undoThenAsk), ("Not bold, italic", .undoThenAsk), ("no, no border", .undoThenAsk),
            ("no the button", .undoThenAsk), ("no I said blue", .undoThenAsk), ("No... the title", .undoThenAsk),
            ("no move it down", .undoThenAsk), ("no use the other one", .undoThenAsk), ("no instead make it green", .undoThenAsk),
            ("not it", .undoOnly),
            ("No border", nil), ("not bold", nil), ("no shadow on it", nil), ("nothing on the left", nil), ("No. Border.", nil),
            ("Not so big", nil), ("No, thanks", nil), ("no thanks", nil), ("not italic", nil), ("no more shadow on the card", nil),
        ]
        for (said, correction) in expected {
            #expect(VoiceAgent.correction(in: said) == correction, "\(said)")
        }
    }

    /// "No border on the button" after "make the title blue" is put to the model as it was
    /// said, and leaves the blue title alone (V3).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aLookSaidWithNoLeavesTheLastCommandAlone() async throws {
        let bench = bench([
            "make the title blue": [Step(tool: "styleElement", arguments: #"{"element":"E1","look":"blue"}"#)],
            "no border on the button": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"plain"}"#)],
        ])
        _ = await bench.agent.run("make the title blue")

        let outcome = await bench.agent.run("No border on the button")

        #expect(outcome.problem == nil)
        #expect(bench.app.store.screenLeaves(bench.screen).first { $0.kind == .title }?.resolvedTint == ColourWords.parse("blue"))
        #expect(bench.recorder.requests.last?.prompts.last == "No border on the button")
        // Two commands, two steps: the first undo takes back only the second.
        bench.undo?.undo()
        #expect(bench.app.store.screenLeaves(bench.screen).first { $0.kind == .title }?.resolvedTint == ColourWords.parse("blue"))
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
        #expect(try #require(bench.button).resolvedTint == ColourWords.parse("green"))
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
        #expect(try #require(bench.button).content.text == "Ahoy")
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
        #expect(try #require(bench.button).content.text == "Ahoy")
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
        #expect(await eventually { bench.button?.content.text == "One" })
        running.cancel()
        let outcome = await running.value

        #expect(outcome.wasCancelled)
        #expect(outcome.problem == nil)
        let button = try #require(bench.button)
        #expect(button.content.text == "One")
        #expect(button.resolvedTint == Theme.accent)
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
        #expect(try #require(bench.button).content.text == "Ahoy")
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
        let image = NodeRef(host: .screen(bench.screen), node: bench.app.store.screenLeaves(bench.screen)[2].id)
        bench.app.store.update(image.node) { $0.frame.origin.x = 60 }

        _ = await bench.agent.run("No, that's wrong.")

        #expect(bench.app.store.ownFrame(image.node)?.origin.x == 60)
        #expect(bench.button?.content.text == "Ahoy")
    }

    /// A command that reaches a design after it has closed does nothing to it (B-I4).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandAfterTheDesignClosedDoesNothing() async throws {
        let bench = bench(["make the button say ahoy": [Step(tool: "setText", arguments: #"{"element":"E2","text":"Ahoy"}"#)]])
        bench.app.close()
        let outcome = await bench.agent.run("make the button say ahoy")
        #expect(outcome.problem == AppModel.closedProblem)
        #expect(bench.button?.content.text == "Sign in")
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
        #expect(await eventually { bench.button?.content.text == "One" })
        bench.app.close()
        _ = await running.value
        #expect(bench.button?.resolvedTint == Theme.accent)
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

    // MARK: A change for one screen

    private struct ScreenBench {
        let app: AppModel
        let login: TreeScreen.ID
        let profile: TreeScreen.ID
        let agent: VoiceAgent
        let recorder: ScriptRecorder

        @MainActor var title: LayerNode? { app.store.screenLeaves(login).first { $0.kind == .title } }
        @MainActor var button: LayerNode? { app.store.screenLeaves(login).first { $0.kind == .button } }
        @MainActor var profileTitle: LayerNode? { app.store.screenLeaves(profile).first { $0.kind == .title } }
        /// The button's frame in its screen's points.
        @MainActor var buttonFrame: CGRect? { button.flatMap { app.store.ownFrame($0.id) } }
        @MainActor var undo: UndoManager? { app.store.undoManager }
    }

    /// Login (S1: E1 title, E2 button, E3 image) and Profile (S2: E4 title), and an agent
    /// whose model does what `script` says for each command.
    private func screenBench(_ script: [String: [Step]]) -> ScreenBench {
        let (app, login, profile) = VoiceFixture.loginAndProfile()
        let recorder = ScriptRecorder()
        let agent = VoiceAgent(model: app, testModel: ScriptedLanguageModel(script: script, closing: "Done.", recorder: recorder))
        return ScreenBench(app: app, login: login, profile: profile, agent: agent, recorder: recorder)
    }

    private static let greenAndContinue = [
        Step(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#),
        Step(tool: "setText", arguments: #"{"element":"E2","text":"Continue"}"#),
    ]

    /// A change typed about Login is told Login in full, Profile by its name alone, and in
    /// so many words which screen it is for.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aScreenChangeIsToldItsScreenInFullAndTheRestByName() async throws {
        let bench = screenBench([:])
        _ = await bench.agent.run("make the title red", about: .screenEdit(bench.login))
        let told = try #require(bench.recorder.requests.first)
        #expect(told.instructions.contains(#"E2 button "Sign in""#))
        #expect(!told.instructions.contains("Your profile"))
        let prompt = try #require(bench.recorder.requests.last?.prompts.last)
        #expect(prompt.hasPrefix(#"(The person is changing S1, the screen "Login""#))
        #expect(prompt.hasSuffix(" make the title red"))
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aScreenChangeCantReachAnotherScreen() async throws {
        let bench = screenBench(["make the profile title red": [Step(tool: "styleElement", arguments: #"{"element":"E4","look":"red"}"#)]])
        let outcome = await bench.agent.run("make the profile title red", about: .screenEdit(bench.login))
        #expect(outcome.problem?.contains("isn't on S1") == true)
        #expect(bench.profileTitle?.resolvedTint == Theme.accent)
    }

    /// However many tools it takes, a change for one screen is one step, named for what it
    /// is in the Edit menu and the undo HUD.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aScreenChangeIsOneUndoStepNamedChangeScreen() async throws {
        // Both ways a history can group: the tests' own, and the document's, by event.
        for groupsByEvent in [false, true] {
            let bench = screenBench(["make the button green and say continue": Self.greenAndContinue])
            let undo = try #require(bench.undo)
            undo.groupsByEvent = groupsByEvent
            let before = bench.app.store.content
            _ = await bench.agent.run("make the button green and say continue", about: .screenEdit(bench.login))
            #expect(bench.button?.resolvedTint == ColourWords.parse("green"))
            #expect(bench.button?.content.text == "Continue")
            #expect(undo.undoActionName == "Change Screen")
            undo.undo()
            #expect(bench.app.store.content == before)
            #expect(undo.redoActionName == "Change Screen")
        }
    }

    /// A change typed while a finger drags the button is a step of its own, and the drag
    /// goes on as its own step, still open (Review Focus 5).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aScreenChangeLeavesADragByHandItsOwnStep() async throws {
        let bench = screenBench(["make the button green and say continue": Self.greenAndContinue])
        let start = try #require(bench.button)
        let startFrame = try #require(bench.buttonFrame)
        let ref = NodeRef(host: .screen(bench.login), node: start.id)
        let drag = bench.app.store.beginEdit()
        bench.app.store.act(for: drag) { bench.app.store.update(ref.node) { $0.frame.origin.x += 10 } }

        _ = await bench.agent.run("make the button green and say continue", about: .screenEdit(bench.login))

        #expect(bench.button?.content.text == "Continue")
        #expect(drag.isOpen)
        #expect(bench.app.store.isEditing(by: .hand))
        bench.app.store.endEdit(drag)
        let undo = try #require(bench.undo)
        undo.undo()
        #expect(bench.button?.content.text == "Sign in")
        #expect(bench.button?.resolvedTint == Theme.accent)
        #expect(bench.buttonFrame?.origin.x == startFrame.origin.x + 10)
        undo.undo()
        #expect(bench.buttonFrame?.origin.x == startFrame.origin.x)
    }

    /// A hint put before a command doesn't hide the command's script from the test model.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCommandIsFoundInTheScriptBehindItsHint() async throws {
        let bench = bench(["make it blue": [Step(tool: "styleElement", arguments: #"{"element":"E2","look":"blue"}"#)]])
        let button = try #require(bench.button)
        let selection = CanvasSelection.element(.init(host: .screen(bench.screen), node: button.id))
        bench.app.selection = selection
        _ = await bench.agent.run("make it blue", about: .thing(selection))
        #expect(bench.button?.resolvedTint == ColourWords.parse("blue"))
    }

    /// "No, …" typed for Login never takes back a change to Profile, however recent: a
    /// correction for one screen corrects only a change made for that screen. Nor may the
    /// model's own undo take it back in its place (review of Task 6).
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionForOneScreenLeavesAnotherScreensChange() async throws {
        let bench = screenBench([
            "make the profile title red": [Step(tool: "styleElement", arguments: #"{"element":"E4","look":"red"}"#)],
            "make the profile title green": [Step(tool: "styleElement", arguments: #"{"element":"E4","look":"green"}"#)],
            "no, make it blue": [Step(tool: "undo", arguments: "{}"), Step(tool: "styleElement", arguments: #"{"element":"E1","look":"blue"}"#)],
            "make the title red": [Step(tool: "styleElement", arguments: #"{"element":"E1","look":"red"}"#)],
        ])
        // Saying what was meant: the model is told the change to Profile wasn't undone, and
        // its undo is refused.
        _ = await bench.agent.run("make the profile title red")
        #expect(bench.profileTitle?.resolvedTint == ColourWords.parse("red"))
        _ = await bench.agent.run("No, make it blue", about: .screenEdit(bench.login))
        #expect(bench.profileTitle?.resolvedTint == ColourWords.parse("red"))
        #expect(bench.title?.resolvedTint == ColourWords.parse("blue"))
        #expect(bench.recorder.requests.last?.prompts.last?.contains(VoiceAgent.notThisScreensHint) == true)

        // Said alone: nothing is undone, and the model isn't asked.
        _ = await bench.agent.run("make the profile title green")
        #expect(bench.profileTitle?.resolvedTint == ColourWords.parse("green"))
        let asked = bench.recorder.requests.count
        let alone = await bench.agent.run("No, that's wrong.", about: .screenEdit(bench.login))
        #expect(bench.profileTitle?.resolvedTint == ColourWords.parse("green"))
        #expect(alone.problem != nil)
        #expect(bench.recorder.requests.count == asked)

        // A change made for Login is Login's to correct.
        _ = await bench.agent.run("make the title red", about: .screenEdit(bench.login))
        #expect(bench.title?.resolvedTint == ColourWords.parse("red"))
        _ = await bench.agent.run("No, that's wrong.", about: .screenEdit(bench.login))
        #expect(bench.title?.resolvedTint == ColourWords.parse("blue"))
        #expect(bench.profileTitle?.resolvedTint == ColourWords.parse("green"))
    }

    /// A change for one screen makes no other, so its model isn't handed the tool that would,
    /// and the canvas it is told says so: the rules, the same for every command, still tell
    /// it to make screens. The next command, which can go anywhere, is handed the tool, and
    /// told the whole canvas with no such line.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aScreenChangeIsntHandedTheToolThatMakesScreens() async throws {
        let bench = screenBench([:])
        let alone = "This change is for S1 alone: no new screen can be made and nothing elsewhere can change; if one is asked for, call no tool and say it can't be done here."
        _ = await bench.agent.run("make the title red", about: .screenEdit(bench.login))
        let scoped = try #require(bench.recorder.requests.last)
        #expect(!scoped.tools.contains("createScreen"))
        #expect(scoped.tools.contains("styleElement"))
        #expect(scoped.instructions.contains(alone))

        _ = await bench.agent.run("a settings screen")
        let anywhere = try #require(bench.recorder.requests.last)
        #expect(anywhere.tools.contains("createScreen"))
        #expect(anywhere.instructions.contains("Your profile"))
        #expect(!anywhere.instructions.contains("alone: no new screen"))
        #expect(anywhere.prompts.last == "a settings screen")
    }

    /// Squeezed over Login, "make it dark" is spoken, and changes Login alone; "No, lighter"
    /// typed in Login's field then corrects it. A spoken change to Profile is still left.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionForOneScreenUndoesASpokenChangeToThatScreenAlone() async throws {
        let bench = screenBench([
            "make the title red": [Step(tool: "styleElement", arguments: #"{"element":"E1","look":"red"}"#)],
            "make the profile title red": [Step(tool: "styleElement", arguments: #"{"element":"E4","look":"red"}"#)],
        ])
        _ = await bench.agent.run("make the title red")
        #expect(bench.title?.resolvedTint == ColourWords.parse("red"))
        let undone = await bench.agent.run("No.", about: .screenEdit(bench.login))
        #expect(bench.title?.resolvedTint == Theme.accent)
        #expect(undone.problem == nil)

        _ = await bench.agent.run("make the profile title red")
        let refused = await bench.agent.run("No.", about: .screenEdit(bench.login))
        #expect(bench.profileTitle?.resolvedTint == ColourWords.parse("red"))
        #expect(refused.problem == VoiceToolbox.notThisScreens)
    }

    /// The one screen a step changed, which a correction for that screen may take back: the
    /// screen itself, or what is on it, and nothing else.
    @Test func theOneScreenAStepChanged() throws {
        let (app, login, profile) = VoiceFixture.loginAndProfile()
        let store = app.store
        let title = NodeRef(host: .screen(login), node: try #require(store.screenLeaves(login).first?.id))
        let profileTitle = NodeRef(host: .screen(profile), node: try #require(store.screenLeaves(profile).first?.id))
        func screen(changedBy body: () -> Void) -> TreeScreen.ID? {
            let edit = store.beginEdit(by: .app)
            store.act(for: edit, body)
            store.endEdit(edit)
            return store.onlyScreen(changedBy: edit)
        }
        #expect(screen { store.update(title.node) { $0.frame.origin.x += 5 } } == login)
        #expect(screen { store.updateTreeScreen(profile) { $0.name = "Me" } } == profile)
        #expect(screen {
            store.update(title.node) { $0.frame.origin.x += 5 }
            store.update(profileTitle.node) { $0.frame.origin.x += 5 }
        } == nil)
        // Login and something on the open canvas, or Login and the board's name.
        #expect(screen {
            store.update(title.node) { $0.frame.origin.x += 5 }
            store.placeLoose(.stickyNote, sketchedAs: CGRect(x: 3000, y: 3000, width: 160, height: 160))
        } == nil)
        #expect(screen {
            store.update(title.node) { $0.frame.origin.x += 5 }
            store.setTitle("Board")
        } == nil)
        #expect(screen {} == nil)
        // A screen made or taken away: undoing the step would make or take it away again.
        #expect(screen { store.addFreeScreen([], name: "Screen 3", origin: CGPoint(x: 5200, y: 4000), scale: 0.6) } == nil)
        #expect(screen { store.deleteScreen(profile) } == nil)
    }

    /// A screen spoken into being, then "No, make it darker" typed in its field: a change to
    /// that screen, not an undo of the step that made it, which would take the screen away
    /// and leave the change nothing to work on.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionInANewScreensFieldLeavesTheScreen() async throws {
        let bench = screenBench(["a settings screen": [Step(tool: "createScreen", arguments: #"{"name":"Settings","description":"a settings screen"}"#)]])
        bench.app.screenStream = { request in
            AsyncThrowingStream { feed in
                feed.yield(.screen(Outline.parse("title: \(request.description)\n", isComplete: true)))
                feed.finish()
            }
        }
        _ = await bench.agent.run("a settings screen")
        let settings = try #require(bench.app.store.tree.screens.last)
        #expect(settings.name == "Settings")

        _ = await bench.agent.run("No, make it darker", about: .screenEdit(settings.id))

        #expect(bench.app.store.treeScreen(settings.id) != nil)
        let prompt = try #require(bench.recorder.requests.last?.prompts.last)
        #expect(!prompt.contains("(The last change has been undone.)"))
        #expect(prompt.hasSuffix(" No, make it darker"))
    }

    /// The command's step undone, the model's own undo of it again is no failure: the
    /// command did what was meant, and says so, not that something couldn't be done.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aSecondUndoInACorrectionForOneScreenIsNoFailure() async throws {
        let bench = screenBench([
            "make the title red": [Step(tool: "styleElement", arguments: #"{"element":"E1","look":"red"}"#)],
            "no, make it blue": [Step(tool: "styleElement", arguments: #"{"element":"E1","look":"blue"}"#), Step(tool: "undo", arguments: "{}")],
        ])
        _ = await bench.agent.run("make the title red", about: .screenEdit(bench.login))
        let outcome = await bench.agent.run("No, make it blue", about: .screenEdit(bench.login))
        #expect(bench.title?.resolvedTint == ColourWords.parse("blue"))
        #expect(outcome.problem == nil)
    }

    /// The reason a correction for one screen gives is about another screen only when the
    /// last command's step is still on top and was for another screen. A change by hand
    /// since is the reason it always was.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aCorrectionForOneScreenGivesTheScreenAsItsReasonOnlyWhenItIs() async throws {
        let bench = screenBench([
            "make the profile title red": [Step(tool: "styleElement", arguments: #"{"element":"E4","look":"red"}"#)],
            "make the profile title green": [Step(tool: "styleElement", arguments: #"{"element":"E4","look":"green"}"#)],
        ])
        let image = NodeRef(host: .screen(bench.login), node: bench.app.store.screenLeaves(bench.login)[2].id)
        _ = await bench.agent.run("make the profile title red")
        bench.app.store.update(image.node) { $0.frame.origin.x = 60 }
        _ = await bench.agent.run("No, make it blue", about: .screenEdit(bench.login))
        let prompt = try #require(bench.recorder.requests.last?.prompts.last)
        #expect(prompt.contains(VoiceAgent.notUndoneHint))
        #expect(!prompt.contains(VoiceAgent.notThisScreensHint))

        _ = await bench.agent.run("make the profile title green")
        bench.app.store.update(image.node) { $0.frame.origin.x = 80 }
        let refused = await bench.agent.run("No.", about: .screenEdit(bench.login))
        #expect(refused.problem != nil)
        #expect(refused.problem != VoiceToolbox.notThisScreens)
        #expect(bench.profileTitle?.resolvedTint == ColourWords.parse("green"))
    }

    /// A change for one screen that runs inside another command's step, as a command can,
    /// leaves that step's name alone: only a step it begins is named Change Screen.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aScreenChangeNamesOnlyAStepItBegan() async throws {
        let bench = screenBench(["make the button green and say continue": Self.greenAndContinue])
        let undo = try #require(bench.undo)
        bench.app.store.beginHeldEdit()
        _ = await bench.agent.run("make the button green and say continue", about: .screenEdit(bench.login))
        bench.app.store.endHeldEdit()
        #expect(bench.button?.content.text == "Continue")
        #expect(undo.undoActionName == "Voice Command")
    }

    /// A change typed for a screen that has gone since is told so, and the model isn't asked.
    @Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))
    func aChangeForAScreenThatHasGoneAsksNothing() async throws {
        let bench = screenBench(["make the title red": [Step(tool: "styleElement", arguments: #"{"element":"E1","look":"red"}"#)]])
        bench.app.store.deleteScreen(bench.login)
        let before = bench.app.store.content
        let outcome = await bench.agent.run("make the title red", about: .screenEdit(bench.login))
        #expect(outcome.problem == VoiceToolbox.screenGone)
        #expect(bench.recorder.requests.isEmpty)
        #expect(bench.app.store.content == before)
    }
}

/// A tool that always throws.
private struct FailingTool: Tool {
    struct Failure: Error {}
    let name = "fail"
    let description = "Always fails."

    @Generable
    struct Arguments {
        var note: String
    }

    func call(arguments: Arguments) async throws -> String {
        throw Failure()
    }
}
