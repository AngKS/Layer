import AVFoundation
import Foundation
import Testing
@testable import Layer

/// Designs for the voice tests to work on.
@MainActor
enum VoiceFixture {
    /// A design with one iPhone screen named Login. From the top: a title, a "Sign in"
    /// button and an image, which a call knows as E1, E2 and E3 on S1.
    static func login() -> (app: AppModel, screen: DesignScreen.ID) {
        let app = AppModel(document: LayerDocument())
        let screen = app.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 4000, y: 4000), scale: 0.6))
        app.store.updateScreen(screen.id) { $0.name = "Login" }
        _ = app.store.setElements([
            DesignElement(kind: .title, frame: CGRect(x: 20, y: 75, width: 353, height: 41), text: "Welcome back", tint: Theme.accent),
            DesignElement(kind: .button, frame: CGRect(x: 20, y: 420, width: 353, height: 50), text: "Sign in", tint: Theme.accent),
            DesignElement(kind: .image, frame: CGRect(x: 20, y: 500, width: 200, height: 200), text: "", tint: Theme.accent),
        ], on: screen.id, replacing: true)
        return (app, screen.id)
    }

    /// The login design with an undo history of its own, starting empty.
    static func undoableLogin() -> (app: AppModel, screen: DesignScreen.ID) {
        let fixture = login()
        let undo = UndoManager()
        undo.groupsByEvent = false
        fixture.app.store.undoManager = undo
        return fixture
    }
}

/// A route the test drives by hand: it hears what the test says it hears.
@MainActor
final class FakeRoute: VoiceRoute {
    private var continuation: AsyncStream<VoiceRouteEvent>.Continuation?
    private(set) var isStopped = false
    private(set) var vocabulary: [String] = []
    var startError: (any Error)?
    /// While set, the route is still getting ready.
    var holdsStart = false

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
        while holdsStart { try? await Task.sleep(for: .milliseconds(5)) }
        if let startError { throw startError }
        self.vocabulary = vocabulary
        let (stream, continuation) = AsyncStream<VoiceRouteEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        isStopped = true
        continuation?.finish()
    }

    func send(_ event: VoiceRouteEvent) {
        continuation?.yield(event)
    }
}

/// A runner that records what it was asked and answers as the test says. While `holds` is
/// set a command stays running, until it is let go or cancelled.
@MainActor
final class FakeRunner: VoiceCommandRunner {
    private(set) var commands: [String] = []
    private(set) var cancelled: [String] = []
    var outcomes: [VoiceOutcome] = []
    var holds = false

    func run(_ command: String) async -> VoiceOutcome {
        commands.append(command)
        while holds, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if Task.isCancelled {
            cancelled.append(command)
            return VoiceOutcome(wasCancelled: true)
        }
        return outcomes.isEmpty ? VoiceOutcome(lines: ["Done"]) : outcomes.removeFirst()
    }
}

/// Waits for something that happens a moment later, on another task.
@MainActor
func eventually(within limit: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@Suite("A voice call", .serialized)
@MainActor
struct VoiceCallTests {
    private func makeCall(vocabulary: [String] = []) -> (VoiceCall, FakeRoute, FakeRunner) {
        let route = FakeRoute()
        let runner = FakeRunner()
        return (VoiceCall(route: route, runner: runner, vocabulary: { vocabulary }), route, runner)
    }

    @Test func aCallListensOnceItsRouteHasStarted() async {
        let (call, route, _) = makeCall(vocabulary: ["Login", "Sign in"])
        #expect(call.phase == .starting)
        #expect(call.startedAt == nil)
        await call.start()
        #expect(call.phase == .listening)
        #expect(call.startedAt != nil)
        #expect(route.vocabulary == ["Login", "Sign in"])
        call.end()
    }

    @Test func whileGettingReadyTheCallSaysSo() async {
        let (call, route, _) = makeCall()
        route.holdsStart = true
        let starting = Task { await call.start() }
        #expect(await eventually { call.caption == VoiceCall.Caption(kind: .working, text: "Getting ready to listen…") })
        #expect(call.phase == .starting)
        route.holdsStart = false
        await starting.value
        #expect(call.phase == .listening)
        #expect(call.caption == nil)
        call.end()
    }

    @Test func commandsRunInOrderOneAtATime() async {
        let (call, route, runner) = makeCall()
        runner.holds = true
        await call.start()
        route.send(.command("first"))
        route.send(.command("second"))
        #expect(await eventually { runner.commands == ["first"] && call.queuedCount == 1 })
        #expect(call.phase == .working)
        runner.holds = false
        #expect(await eventually { runner.commands == ["first", "second"] && call.phase == .listening })
        #expect(call.queuedCount == 0)
        call.end()
    }

    @Test func stopCancelsTheRunningCommandAndEmptiesTheQueue() async {
        let (call, route, runner) = makeCall()
        runner.holds = true
        await call.start()
        route.send(.command("first"))
        route.send(.command("second"))
        #expect(await eventually { runner.commands == ["first"] && call.queuedCount == 1 })
        route.send(.command("Stop."))
        #expect(await eventually { runner.cancelled == ["first"] && call.queuedCount == 0 && call.phase == .listening })
        runner.holds = false
        try? await Task.sleep(for: .milliseconds(100))
        // The second command never ran, and "stop" itself was never handed to a model.
        #expect(runner.commands == ["first"])
        call.end()
    }

    @Test func hangUpEndsTheCall() async {
        let (call, route, runner) = makeCall()
        await call.start()
        route.send(.command("Hang up"))
        #expect(await eventually { call.phase == .ended })
        #expect(route.isStopped)
        #expect(runner.commands.isEmpty)
    }

    @Test func aCommandCanEndTheCall() async {
        let (call, route, runner) = makeCall()
        runner.outcomes = [VoiceOutcome(lines: ["Hanging up"], endsCall: true)]
        await call.start()
        route.send(.command("that's all for today"))
        #expect(await eventually { call.phase == .ended })
        #expect(route.isStopped)
    }

    @Test func anEmptyCommandIsIgnored() async {
        let (call, route, runner) = makeCall()
        await call.start()
        route.send(.command("  "))
        route.send(.command("real"))
        #expect(await eventually { runner.commands == ["real"] })
        call.end()
    }

    @Test func wordsBeingHeardAreShown() async {
        let (call, route, _) = makeCall()
        await call.start()
        route.send(.hearing("make the button"))
        #expect(await eventually { call.caption == VoiceCall.Caption(kind: .hearing, text: "make the button") })
        call.end()
    }

    @Test func whatWasDoneIsShownThenCleared() async {
        let (call, route, runner) = makeCall()
        call.captionTimes = (done: .milliseconds(150), problem: .milliseconds(300))
        runner.outcomes = [VoiceOutcome(lines: ["Selected the button", "Made the button blue"])]
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await eventually { call.caption == VoiceCall.Caption(kind: .done, text: "Made the button blue") })
        #expect(await eventually { call.caption == nil })
        call.end()
    }

    @Test func aProblemIsShown() async {
        let (call, route, runner) = makeCall()
        runner.outcomes = [VoiceOutcome(problem: "Can't reach the internet.")]
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await eventually { call.caption == VoiceCall.Caption(kind: .problem, text: "Can't reach the internet.") })
        call.end()
    }

    @Test func wordsTheModelSaidAreShownWhenNothingWasDone() async {
        let (call, route, runner) = makeCall()
        runner.outcomes = [VoiceOutcome(said: "There's no button on this screen.")]
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await eventually { call.caption == VoiceCall.Caption(kind: .done, text: "There's no button on this screen.") })
        call.end()
    }

    @Test func aStepIsShownWhileACommandRuns() async {
        let (call, route, runner) = makeCall()
        runner.holds = true
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await eventually { call.phase == .working })
        call.showStep("Restyling…")
        #expect(call.caption == VoiceCall.Caption(kind: .working, text: "Restyling…"))
        call.end()
    }

    @Test func aSecondCallEndsTheFirst() async {
        let (first, firstRoute, _) = makeCall()
        let (second, _, _) = makeCall()
        await first.start()
        await second.start()
        #expect(first.phase == .ended)
        #expect(firstRoute.isStopped)
        #expect(second.phase == .listening)
        #expect(VoiceCall.current === second)
        second.end()
        #expect(VoiceCall.current == nil)
    }

    @Test func levelsKeepTheLatest() async {
        let (call, route, _) = makeCall()
        await call.start()
        for step in 0..<40 { route.send(.level(Float(step) / 40)) }
        #expect(await eventually { call.levels.last == Float(39) / 40 })
        #expect(call.levels.count == VoiceCall.levelCount)
        #expect(VoiceCall.levelCount == 28)
        call.end()
    }

    @Test func endingStopsTheRouteAndCancelsWork() async {
        let (call, route, runner) = makeCall()
        runner.holds = true
        await call.start()
        route.send(.command("first"))
        #expect(await eventually { runner.commands == ["first"] })
        var ended = false
        call.onEnd = { ended = true }
        call.end()
        #expect(call.phase == .ended)
        #expect(route.isStopped)
        #expect(ended)
        #expect(await eventually { runner.cancelled == ["first"] })
    }

    @Test func aRouteThatFailsEndsTheCallWithItsReason() async {
        let (call, route, _) = makeCall()
        await call.start()
        route.send(.failed("The microphone stopped."))
        #expect(await eventually { call.phase == .ended })
        #expect(call.endReason == "The microphone stopped.")
    }

    @Test func aRouteThatCannotStartEndsTheCallWithItsReason() async {
        struct NoMicrophone: LocalizedError { var errorDescription: String? { "Layer isn't allowed to use the microphone." } }
        let (call, route, _) = makeCall()
        route.startError = NoMicrophone()
        await call.start()
        #expect(call.phase == .ended)
        #expect(call.endReason == "Layer isn't allowed to use the microphone.")
    }

    @Test func stopAndHangUpAreHeardInPlainSpeech() {
        #expect(VoiceCall.localAction(for: "Stop.") == .stop)
        #expect(VoiceCall.localAction(for: " cancel that ") == .stop)
        #expect(VoiceCall.localAction(for: "Hang up!") == .hangUp)
        #expect(VoiceCall.localAction(for: "End the call") == .hangUp)
        #expect(VoiceCall.localAction(for: "stop the button from being blue") == nil)
        #expect(VoiceCall.localAction(for: "make it blue") == nil)
    }

    // MARK: In a design

    @Test func startingACallLeavesDrawMode() async {
        let (app, _) = VoiceFixture.login()
        app.tool = .draw
        let route = FakeRoute()
        await app.startVoiceCall(route: route, runner: FakeRunner())
        #expect(app.tool == .select)
        #expect(app.isInVoiceCall)
        #expect(app.voice?.phase == .listening)
        app.endVoiceCall()
        #expect(app.voice == nil)
        #expect(!app.isInVoiceCall)
        #expect(route.isStopped)
        #expect(app.voiceNotice == nil)
    }

    @Test func theCallIsToldTheWordsOnTheCanvas() async {
        let (app, _) = VoiceFixture.login()
        let route = FakeRoute()
        await app.startVoiceCall(route: route, runner: FakeRunner())
        #expect(route.vocabulary.contains("Login"))
        #expect(route.vocabulary.contains("Sign in"))
        #expect(route.vocabulary.contains("Welcome back"))
        #expect(!route.vocabulary.contains(""))
        app.endVoiceCall()
    }

    @Test func closingTheDesignEndsTheCall() async {
        let (app, _) = VoiceFixture.login()
        let route = FakeRoute()
        await app.startVoiceCall(route: route, runner: FakeRunner())
        app.close()
        #expect(app.voice == nil)
        #expect(route.isStopped)
    }

    @Test func hangingUpByVoiceLeavesNoCallBehind() async {
        let (app, _) = VoiceFixture.login()
        let route = FakeRoute()
        await app.startVoiceCall(route: route, runner: FakeRunner())
        route.send(.command("hang up"))
        #expect(await eventually { app.voice == nil })
        #expect(app.voiceNotice == nil)
    }

    @Test func aCallThatFailsLeavesANotice() async {
        let (app, _) = VoiceFixture.login()
        let route = FakeRoute()
        await app.startVoiceCall(route: route, runner: FakeRunner())
        route.send(.failed("The microphone stopped."))
        #expect(await eventually { app.voice == nil })
        #expect(app.voiceNotice == "The microphone stopped.")
    }

    @Test func leavingLayerEndsTheCall() async {
        let (app, _) = VoiceFixture.login()
        let route = FakeRoute()
        await app.startVoiceCall(route: route, runner: FakeRunner())
        app.windowLeftTheScreen()
        #expect(app.voice == nil)
        #expect(route.isStopped)
        #expect(app.voiceNotice == nil)
    }

    // MARK: With the agent

    private static let needsOwnModels = Comment(rawValue: "Foundation Models runs models of the app's own from iPadOS 27.2")

    /// The login design in a call whose model follows `script`.
    private func call(_ script: [String: [ScriptedLanguageModel.Step]]) async -> (AppModel, DesignScreen.ID, FakeRoute) {
        let (app, screen) = VoiceFixture.undoableLogin()
        let route = FakeRoute()
        await app.startVoiceCall(route: route, runner: VoiceAgent(model: app, testModel: ScriptedLanguageModel(script: script)))
        return (app, screen, route)
    }

    private func button(in app: AppModel, _ screen: DesignScreen.ID) -> DesignElement? {
        app.store.screen(screen)?.elements.first { $0.kind == .button }
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, needsOwnModels))
    func aSpokenCommandChangesTheDesignAndSaysSo() async throws {
        let (app, screen, route) = await call(["make the button green": [.init(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#)]])
        route.send(.command("Make the button green"))
        #expect(await eventually { app.voice?.caption?.kind == .done })
        #expect(app.voice?.caption?.text == "Restyled the button “Sign in”.")
        #expect(button(in: app, screen)?.tint == ColourWords.parse("green"))
        app.endVoiceCall()
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, needsOwnModels))
    func theStepUnderWayIsShown() async throws {
        // The tool runs after the model has taken its time; the step shows as it starts.
        let (app, _, route) = await call(["make the button green": [.init(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#, delay: .milliseconds(200))]])
        var captions: [VoiceCall.Caption] = []
        let call = try #require(app.voice)
        let watching = Task {
            while !Task.isCancelled {
                if let caption = call.caption, captions.last != caption { captions.append(caption) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        route.send(.command("make the button green"))
        #expect(await eventually { call.caption?.kind == .done })
        watching.cancel()
        #expect(captions.first == VoiceCall.Caption(kind: .working, text: "Thinking…"))
        #expect(captions.last?.kind == .done)
        app.endVoiceCall()
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, needsOwnModels))
    func whatTheAgentIsDoingReachesThePill() async throws {
        let (app, _) = VoiceFixture.undoableLogin()
        let agent = VoiceAgent(model: app, testModel: ScriptedLanguageModel(script: [
            "make the button green": [.init(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#, delay: .seconds(5))],
        ]))
        let route = FakeRoute()
        await app.startVoiceCall(route: route, runner: agent)
        route.send(.command("make the button green"))
        #expect(await eventually { app.voice?.phase == .working })
        // The agent says what it is doing through the call it was started in.
        agent.onStep?("Restyling…")
        #expect(app.voice?.caption == VoiceCall.Caption(kind: .working, text: "Restyling…"))
        app.endVoiceCall()
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, needsOwnModels))
    func stopWithAQueueKeepsOneUndoStep() async throws {
        let (app, screen, route) = await call([
            "two things": [
                .init(tool: "setText", arguments: #"{"element":"E2","text":"One"}"#),
                .init(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#, delay: .seconds(5)),
            ],
            "another": [.init(tool: "setText", arguments: #"{"element":"E2","text":"Another"}"#)],
        ])
        let before = app.store.content
        route.send(.command("two things"))
        route.send(.command("another"))
        #expect(await eventually { self.button(in: app, screen)?.text == "One" })
        #expect(app.voice?.queuedCount == 1)
        route.send(.command("stop"))
        #expect(await eventually { app.voice?.phase == .listening })
        #expect(app.voice?.caption == VoiceCall.Caption(kind: .done, text: "Stopped"))
        #expect(app.voice?.queuedCount == 0)
        try await Task.sleep(for: .milliseconds(150))
        // The command waiting never ran, and the one stopped went no further.
        #expect(button(in: app, screen)?.text == "One")
        #expect(button(in: app, screen)?.tint == Theme.accent)
        // What it had done is one step.
        #expect(!app.store.isHoldingEdit)
        let undo = try #require(app.store.undoManager)
        undo.undo()
        #expect(app.store.content == before)
        #expect(!undo.canUndo)
        app.endVoiceCall()
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, needsOwnModels))
    func endingMidCommandLeavesOneUndoStep() async throws {
        let (app, screen, route) = await call(["two things": [
            .init(tool: "setText", arguments: #"{"element":"E2","text":"One"}"#),
            .init(tool: "styleElement", arguments: #"{"element":"E2","look":"green"}"#, delay: .seconds(5)),
        ]])
        let before = app.store.content
        route.send(.command("two things"))
        #expect(await eventually { self.button(in: app, screen)?.text == "One" })
        app.endVoiceCall()
        #expect(app.voice == nil)
        #expect(route.isStopped)
        // The command lets go of the design as it is cancelled, a moment later.
        #expect(await eventually { !app.store.isHoldingEdit })
        #expect(button(in: app, screen)?.tint == Theme.accent)
        let undo = try #require(app.store.undoManager)
        undo.undo()
        #expect(app.store.content == before)
        #expect(!undo.canUndo)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, needsOwnModels))
    func hangingUpByAskingTheModelEndsTheCall() async throws {
        let (app, _, route) = await call(["that is all for today": [.init(tool: "endCall", arguments: "{}")]])
        route.send(.command("That is all for today"))
        #expect(await eventually { app.voice == nil })
        #expect(route.isStopped)
        #expect(app.voiceNotice == nil)
    }

    @Test func onlyOneCallStartsInADesign() async {
        let (app, _) = VoiceFixture.login()
        let first = FakeRoute()
        let second = FakeRoute()
        await app.startVoiceCall(route: first, runner: FakeRunner())
        let call = app.voice
        await app.startVoiceCall(route: second, runner: FakeRunner())
        #expect(app.voice === call)
        #expect(!first.isStopped)
        app.endVoiceCall()
    }
}

@Suite("Commands from recognised speech")
struct UtteranceAssemblerTests {
    private let start = ContinuousClock.now

    /// A moment so many milliseconds into the call.
    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    @Test func aPauseEndsACommand() {
        var assembler = UtteranceAssembler()
        assembler.heard("make the button blue", isFinal: true, at: at(0))
        #expect(assembler.hearing == "make the button blue")
        #expect(assembler.next(at: at(500)) == .wait)
        #expect(assembler.next(at: at(900)) == .command("make the button blue"))
        // Said once, carried out once.
        #expect(assembler.hearing == "")
        #expect(assembler.next(at: at(3000)) == .wait)
    }

    @Test func speechThatContinuesIsOneCommand() {
        var assembler = UtteranceAssembler()
        assembler.heard("make the button", isFinal: true, at: at(0))
        assembler.heard("half width", isFinal: true, at: at(500))
        #expect(assembler.hearing == "make the button half width")
        // Only 400 ms since the last words.
        #expect(assembler.next(at: at(900)) == .wait)
        #expect(assembler.next(at: at(1400)) == .command("make the button half width"))
    }

    @Test func volatileTextIsShownButReplaced() {
        var assembler = UtteranceAssembler()
        assembler.heard("make the", isFinal: false, at: at(0))
        #expect(assembler.hearing == "make the")
        assembler.heard("make the button", isFinal: false, at: at(200))
        #expect(assembler.hearing == "make the button")
        assembler.heard("Make the button blue.", isFinal: true, at: at(400))
        #expect(assembler.hearing == "Make the button blue.")
        assembler.heard("and bold", isFinal: false, at: at(600))
        #expect(assembler.hearing == "Make the button blue. and bold")
    }

    @Test func aCommandWaitsForItsLastWordsToSettle() {
        var assembler = UtteranceAssembler()
        assembler.heard("make the button", isFinal: false, at: at(0))
        // After the pause the recogniser is asked to settle what it has, once.
        #expect(assembler.next(at: at(900)) == .settle)
        #expect(assembler.next(at: at(950)) == .wait)
        // Its settled words are the command, at once: the pause has already been taken.
        assembler.heard("Make the button blue", isFinal: true, at: at(1000))
        #expect(assembler.next(at: at(1000)) == .command("Make the button blue"))
    }

    @Test func speakingAgainWhileSettlingGoesOnWithTheSameCommand() {
        var assembler = UtteranceAssembler()
        assembler.heard("make the button", isFinal: false, at: at(0))
        #expect(assembler.next(at: at(900)) == .settle)
        assembler.heard("make the button half", isFinal: false, at: at(1000))
        #expect(assembler.next(at: at(1100)) == .wait)
        assembler.heard("make the button half width", isFinal: true, at: at(1300))
        #expect(assembler.next(at: at(1500)) == .wait)
        #expect(assembler.next(at: at(2200)) == .command("make the button half width"))
    }

    @Test func wordsThatNeverSettleAreTakenAsTheyAre() {
        var assembler = UtteranceAssembler()
        assembler.heard("show me the first screen", isFinal: false, at: at(0))
        #expect(assembler.next(at: at(900)) == .settle)
        #expect(assembler.next(at: at(2000)) == .wait)
        #expect(assembler.next(at: at(2400)) == .command("show me the first screen"))
        // Settled late, the same words aren't a second command.
        assembler.heard("Show me the first screen.", isFinal: true, at: at(2600))
        #expect(assembler.hearing == "")
        #expect(assembler.next(at: at(5000)) == .wait)
        // But the next thing said is.
        assembler.heard("zoom out", isFinal: true, at: at(6000))
        #expect(assembler.next(at: at(6900)) == .command("zoom out"))
    }

    @Test func silenceGivesNothing() {
        var assembler = UtteranceAssembler()
        #expect(assembler.next(at: at(5000)) == .wait)
        assembler.heard("   ", isFinal: true, at: at(6000))
        assembler.heard("", isFinal: false, at: at(6100))
        #expect(assembler.hearing == "")
        #expect(assembler.next(at: at(9000)) == .wait)
    }
}

@Suite("The scripted call for the simulator")
@MainActor
struct VoiceDemoTests {
    private func arguments(_ step: ScriptedLanguageModel.Step) throws -> [String: String] {
        try #require(try JSONSerialization.jsonObject(with: Data(step.arguments.utf8)) as? [String: String])
    }

    @Test func aScriptIsReadIntoWhatIsSaidAndWhatComesOfIt() {
        let lines = VoiceDemo.lines(from: "make it blue => Made it blue; show me the first screen => !No connection.")
        #expect(lines == [
            VoiceDemo.Line(spoken: "make it blue", result: "Made it blue"),
            VoiceDemo.Line(spoken: "show me the first screen", result: "!No connection."),
        ])
    }

    @Test func aResultThatNamesAToolIsStepsForTheModel() throws {
        let steps = try #require(VoiceDemo.steps(from: "styleElement element=E2 look=text white, bold"))
        #expect(steps.count == 1)
        #expect(steps[0].tool == "styleElement")
        #expect(try arguments(steps[0]) == ["element": "E2", "look": "text white, bold"])

        let two = try #require(VoiceDemo.steps(from: "setText element=E2 text=Ahoy there && alignElement element=E3 alignment=centre"))
        #expect(two.map(\.tool) == ["setText", "alignElement"])
        #expect(try arguments(two[0]) == ["element": "E2", "text": "Ahoy there"])
        #expect(try arguments(two[1]) == ["element": "E3", "alignment": "centre"])

        let bare = try #require(VoiceDemo.steps(from: "undo"))
        #expect(bare[0].arguments == "{}")
    }

    @Test func aResultInPlainWordsIsNotSteps() {
        #expect(VoiceDemo.steps(from: "Made the button blue") == nil)
        #expect(VoiceDemo.steps(from: "!No connection to the internet.") == nil)
    }
}

@Suite("The call pill's parts")
struct CallPillPartsTests {
    @Test func theTimerCountsMinutesAndSeconds() {
        #expect(CallTimer.text(forSeconds: 0) == "0:00")
        #expect(CallTimer.text(forSeconds: 42) == "0:42")
        #expect(CallTimer.text(forSeconds: 75) == "1:15")
        #expect(CallTimer.text(forSeconds: 3723) == "1:02:03")
        #expect(CallTimer.text(forSeconds: -3) == "0:00")
    }

    private func buffer(amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        let samples = buffer.floatChannelData![0]
        for index in 0..<1600 { samples[index] = amplitude * sin(Float(index) * 2 * .pi * 440 / 16000) }
        return buffer
    }

    @Test func silenceIsNoLevelAndAVoiceIsSome() {
        #expect(MicrophoneTap.level(of: buffer(amplitude: 0)) == 0)
        let quiet = MicrophoneTap.level(of: buffer(amplitude: 0.02))
        let speaking = MicrophoneTap.level(of: buffer(amplitude: 0.2))
        let loud = MicrophoneTap.level(of: buffer(amplitude: 1))
        #expect(quiet > 0 && quiet < speaking)
        #expect(speaking > 0.5 && speaking < 1)
        #expect(loud == 1)
    }

    @Test func aBufferGivesALevelForEachStretch() {
        // Loud for its first half, silent for its second.
        let half = buffer(amplitude: 1)
        let samples = half.floatChannelData![0]
        for index in 800..<1600 { samples[index] = 0 }
        #expect(MicrophoneTap.levels(of: half, count: 2) == [1, 0])
        #expect(MicrophoneTap.levels(of: half, count: 1).count == 1)
    }
}
