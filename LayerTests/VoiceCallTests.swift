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
        // A line of its own: on the app's, a call started by a test running alongside
        // ended this design's.
        app.phoneLine = PhoneLine()
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
        giveUndo(to: fixture.app)
        return fixture
    }

    /// The undoable login design with a second iPhone screen to its right, named Profile,
    /// holding one title. A call knows them as S1 Login (E1 title, E2 button, E3 image)
    /// and S2 Profile (E4 title). The undo history starts empty, Profile and all.
    static func loginAndProfile() -> (app: AppModel, login: DesignScreen.ID, profile: DesignScreen.ID) {
        let (app, screen) = Self.login()
        let profile = app.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 4600, y: 4000), scale: 0.6))
        app.store.updateScreen(profile.id) { $0.name = "Profile" }
        _ = app.store.setElements([
            DesignElement(kind: .title, frame: CGRect(x: 20, y: 75, width: 353, height: 41), text: "Your profile", tint: Theme.accent),
        ], on: profile.id, replacing: true)
        giveUndo(to: app)
        return (app, screen, profile.id)
    }

    private static func giveUndo(to app: AppModel) {
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.store.undoManager = undo
    }
}

/// A route the test drives by hand: it hears what the test says it hears.
@MainActor
final class FakeRoute: VoiceRoute {
    private var continuation: AsyncStream<VoiceRouteEvent>.Continuation?
    private(set) var isStopped = false
    private(set) var finishCount = 0
    private(set) var prepareCount = 0
    private(set) var wasStarted = false
    private(set) var vocabulary: [String] = []
    var startError: (any Error)?
    /// While set, the route is still getting ready.
    var holdsStart = false

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
        wasStarted = true
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

    func prepare() async {
        prepareCount += 1
    }

    func finish() {
        finishCount += 1
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
    /// How many times it was asked to get its model ready.
    private(set) var warmUps = 0

    func warmUp() async {
        warmUps += 1
    }

    /// What each command was about, in order.
    private(set) var targets: [VoiceTarget?] = []

    func run(_ command: String, about target: VoiceTarget?) async -> VoiceOutcome {
        targets.append(target)
        return await run(command)
    }

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

/// Waits for `condition` without polling: it is looked at now, and again each time
/// something observable it reads changes, so a state that lasts only a moment, a caption
/// shown for 150 ms, isn't missed between looks. `limit` is only there so that a change
/// that never comes fails the test rather than hanging it; nothing waits for it otherwise.
@MainActor
func until(within limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while true {
        let (changes, change) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if withObservationTracking(condition, onChange: { change.yield() }) { return true }
        let timer = Task {
            try? await Task.sleep(until: deadline)
            change.finish()
        }
        var changed = false
        for await _ in changes {
            changed = true
            break
        }
        timer.cancel()
        guard changed else { return condition() }
    }
}

@Suite("A voice call", .serialized)
@MainActor
struct VoiceCallTests {
    /// A call on a line of its own, unless it is given one: on the app's line, a call
    /// started by a test running alongside ended it.
    private func makeCall(vocabulary: [String] = [], line: PhoneLine = PhoneLine()) -> (VoiceCall, FakeRoute, FakeRunner) {
        let route = FakeRoute()
        let runner = FakeRunner()
        return (VoiceCall(route: route, runner: runner, vocabulary: { vocabulary }, line: line), route, runner)
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
        route.send(.command("make it blue"))
        route.send(.command("make it bold"))
        #expect(await eventually { runner.commands == ["make it blue"] && call.queuedCount == 1 })
        #expect(call.phase == .working)
        runner.holds = false
        #expect(await eventually { runner.commands == ["make it blue", "make it bold"] && call.phase == .listening })
        #expect(call.queuedCount == 0)
        call.end()
    }

    @Test func stopCancelsTheRunningCommandAndEmptiesTheQueue() async {
        let (call, route, runner) = makeCall()
        runner.holds = true
        await call.start()
        route.send(.command("make it blue"))
        route.send(.command("make it bold"))
        #expect(await eventually { runner.commands == ["make it blue"] && call.queuedCount == 1 })
        route.send(.command("Stop."))
        #expect(await eventually { runner.cancelled == ["make it blue"] && call.queuedCount == 0 && call.phase == .listening })
        runner.holds = false
        try? await Task.sleep(for: .milliseconds(100))
        // The second command never ran, and "stop" itself was never handed to a model.
        #expect(runner.commands == ["make it blue"])
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
        route.send(.command("make it green"))
        #expect(await eventually { runner.commands == ["make it green"] })
        call.end()
    }

    @Test func wordsBeingHeardAreShown() async {
        let (call, route, _) = makeCall()
        await call.start()
        route.send(.hearing("make the button"))
        #expect(await until { call.caption == VoiceCall.Caption(kind: .hearing, text: "make the button") })
        call.end()
    }

    @Test func whatWasDoneIsShownThenCleared() async {
        let (call, route, runner) = makeCall()
        call.captionTimes = (done: .milliseconds(150), problem: .milliseconds(300))
        runner.outcomes = [VoiceOutcome(lines: ["Selected the button", "Made the button blue"])]
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await until { call.caption == VoiceCall.Caption(kind: .done, text: "Made the button blue") })
        #expect(await until { call.caption == nil })
        #expect(call.phase == .listening)
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

    /// Words with nothing done are the model's own, and never get the tick that says a
    /// change was made: a model that can't call tools will say it has done what it hasn't.
    @Test func wordsTheModelSaidAreShownWhenNothingWasDoneAndNotAsDone() async {
        let (call, route, runner) = makeCall()
        runner.outcomes = [VoiceOutcome(said: "There's no button on this screen.")]
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await eventually { call.caption?.text == "There's no button on this screen." })
        #expect(call.caption?.kind == .said)
        call.end()
    }

    /// They stay as long as a problem does, being as much to read.
    @Test func wordsTheModelSaidStayAsLongAsAProblem() async {
        let (call, route, runner) = makeCall()
        call.captionTimes = (done: .milliseconds(20), problem: .seconds(30))
        runner.outcomes = [VoiceOutcome(said: "Sure, the button is blue now.")]
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await eventually { call.caption?.text == "Sure, the button is blue now." })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(call.caption?.text == "Sure, the button is blue now.")
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
        let line = PhoneLine()
        let (first, firstRoute, _) = makeCall(line: line)
        let (second, _, _) = makeCall(line: line)
        await first.start()
        await second.start()
        #expect(first.phase == .ended)
        #expect(firstRoute.isStopped)
        #expect(second.phase == .listening)
        #expect(line.call === second)
        second.end()
        #expect(line.call == nil)
    }

    /// The app's designs share its line, so a call started in one window ends another's.
    @Test func designsShareTheAppsLine() {
        #expect(AppModel(document: LayerDocument()).phoneLine === PhoneLine.shared)
        let (call, _, _) = makeCall()
        #expect(call.line !== PhoneLine.shared)
        #expect(VoiceCall(route: FakeRoute(), runner: FakeRunner()).line === PhoneLine.shared)
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
        route.send(.command("make it blue"))
        #expect(await eventually { runner.commands == ["make it blue"] })
        var ended = false
        call.onEnd = { ended = true }
        call.end()
        #expect(call.phase == .ended)
        #expect(route.isStopped)
        #expect(ended)
        #expect(await eventually { runner.cancelled == ["make it blue"] })
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

    // MARK: Warming the model

    /// A model's first answer in a conversation is its slowest by far: on an iPad the
    /// first command of a call waited fourteen seconds. The model is got ready as the
    /// call starts, while the person is still drawing breath.
    @Test func startingACallWarmsTheModel() async {
        let (call, _, runner) = makeCall()
        await call.start()
        #expect(await eventually { runner.warmUps == 1 })
        call.end()
    }

    /// A command that was stopped leaves the model to start afresh, which is the slow
    /// start over again unless it is warmed for the next command.
    @Test func afterACommandIsStoppedTheModelIsWarmedAgain() async {
        let (call, route, runner) = makeCall()
        runner.holds = true
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await eventually { call.phase == .working })
        route.send(.command("stop"))
        #expect(await eventually { runner.warmUps == 2 })
        call.end()
    }

    @Test func afterACommandGoesWrongTheModelIsWarmedAgain() async {
        let (call, route, runner) = makeCall()
        runner.outcomes = [VoiceOutcome(problem: "Can't reach the internet.")]
        await call.start()
        route.send(.command("make the button blue"))
        #expect(await eventually { runner.warmUps == 2 })
        call.end()
    }

    // MARK: Fragments

    /// A pause for thought can leave a word on its own: "So", or the "make" of a
    /// sentence not yet said. A model handed one does something all the same: on an iPad
    /// "So" sent the canvas off to another screen. They are let go.
    @Test func aWordOnItsOwnThatIsNoCommandIsNotSentToTheModel() async {
        let (call, route, runner) = makeCall()
        await call.start()
        for fragment in ["So", "make.", "Um, okay.", "you..."] {
            route.send(.command(fragment))
        }
        route.send(.command("Undo."))
        #expect(await eventually { runner.commands == ["Undo."] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.commands == ["Undo."])
        call.end()
    }

    @Test func whatIsWorthAskingAModel() {
        // A word that is a command by itself.
        for command in ["Undo.", "redo", "Delete", "Duplicate.", "bigger", "Smaller", "Bold", "centre"] {
            #expect(VoiceCall.isWorthAsking(command), "\(command)")
        }
        // Two words or more that say something.
        for command in ["Zoom out.", "make it blue", "Show me the second screen", "undo that", "So make it red"] {
            #expect(VoiceCall.isWorthAsking(command), "\(command)")
        }
        // Noises, and the start of something.
        for command in ["So", "um", "make.", "the", "Okay, so.", "Yeah", "and then", "you", "I", "",
                        "cool, cool, cool. Okay.", "Nice!", "Great, thanks"] {
            #expect(!VoiceCall.isWorthAsking(command), "\(command)")
        }
    }

    // MARK: A sentence cut short

    /// A pause in the middle of a sentence ends what was heard on "to" or "the". On an
    /// iPad "I want a screen to" made a screen. It waits for the rest instead.
    @Test func aSentenceStoppedMidWayWaitsForTheRest() async {
        let (call, route, runner) = makeCall()
        call.fragmentWait = .seconds(5)
        await call.start()
        route.send(.command("I want a screen to"))
        route.send(.command("view my baby photos"))
        #expect(await eventually { runner.commands == ["I want a screen to view my baby photos"] })
        call.end()
    }

    @Test func aSentenceStoppedMidWayIsTakenAsItIsIfNothingFollows() async {
        let (call, route, runner) = makeCall()
        call.fragmentWait = .milliseconds(100)
        await call.start()
        route.send(.command("make the image bigger and"))
        #expect(await eventually { runner.commands == ["make the image bigger and"] })
        call.end()
    }

    @Test func stopLetsGoOfASentenceStoppedMidWay() async {
        let (call, route, runner) = makeCall()
        call.fragmentWait = .milliseconds(100)
        await call.start()
        route.send(.command("make the image bigger and"))
        route.send(.command("stop"))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runner.commands.isEmpty)
        call.end()
    }

    @Test func whatIsASentenceStoppedMidWay() {
        for said in ["I want a screen to", "Inc increase the width of it to", "With to 80% of the", "make it bigger and",
                     "put the image below", "Can you make"] {
            #expect(VoiceCall.endsMidSentence(said), "\(said)")
        }
        for said in ["Zoom out.", "zoom in", "make it blue", "Move it down to the bottom.", "turn it on", "Undo."] {
            #expect(!VoiceCall.endsMidSentence(said), "\(said)")
        }
    }

    /// The words were shown as they were heard. Let go, they are taken down again.
    @Test func aFragmentLetGoIsTakenOffThePill() async {
        let (call, route, _) = makeCall()
        await call.start()
        route.send(.hearing("So"))
        #expect(await eventually { call.caption?.text == "So" })
        route.send(.command("So"))
        // At once: a command that was run would leave its own line up for seconds.
        #expect(await eventually(within: .milliseconds(300)) { call.caption == nil })
        call.end()
    }

    /// Said to a person, "stop" comes with a "please" or an "it" as often as not. Those
    /// must stop the work at once too, not wait their turn behind it.
    @Test func stopIsHeardHoweverPolitelyItIsSaid() {
        #expect(VoiceCall.localAction(for: "Please stop.") == .stop)
        #expect(VoiceCall.localAction(for: "Stop it") == .stop)
        #expect(VoiceCall.localAction(for: "stop, please") == .stop)
        #expect(VoiceCall.localAction(for: "Cancel it.") == .stop)
        #expect(VoiceCall.localAction(for: "OK stop") == .stop)
        #expect(VoiceCall.localAction(for: "please hang up") == .hangUp)
        #expect(VoiceCall.localAction(for: "Thank you, bye-bye.") == .hangUp)
        #expect(VoiceCall.localAction(for: "Bye.") == .hangUp)
        // Still only the bare phrase: anything more is a command for the model.
        #expect(VoiceCall.localAction(for: "please stop the title being bold") == nil)
        #expect(VoiceCall.localAction(for: "please") == nil)
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
        route.send(.command("make the button green"))
        // Each caption is taken as it is shown, rather than looked for every few
        // milliseconds, which missed the first under load.
        #expect(await until {
            if let caption = call.caption, captions.last != caption { captions.append(caption) }
            return call.caption?.kind == .done
        })
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
            "make it wider": [.init(tool: "setText", arguments: #"{"element":"E2","text":"Another"}"#)],
        ])
        let before = app.store.content
        route.send(.command("two things"))
        route.send(.command("make it wider"))
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

    // MARK: Listening on request

    @Test func anOnRequestCallListensOnlyWhenAsked() async {
        var routes: [FakeRoute] = []
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
        await call.start()
        // Speech is made ready as the call starts, so the first squeeze doesn't wait on
        // it. That is never the microphone: no route has started.
        #expect(call.phase == .listening && runner.warmUps == 1)
        #expect(await eventually { routes.count == 1 && routes[0].prepareCount == 1 })
        #expect(!routes[0].wasStarted && !call.isHearing)
        // The route made ready is the one the first listen uses.
        await call.listen(for: nil)
        #expect(routes.count == 1 && routes[0].wasStarted && call.isHearing)
        call.send()
        #expect(routes[0].finishCount == 1)
        routes[0].send(.command("make it blue"))
        #expect(await eventually { runner.commands == ["make it blue"] && routes[0].isStopped && !call.isHearing })
        call.end()
    }

    @Test func queuedCommandRunsOnItsOwnTarget() async {
        // Two squeezes on different targets while the first command is still running:
        // each command starts with its own target.
        var routes: [FakeRoute] = []
        let runner = FakeRunner(); runner.holds = true
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
        var started: [VoiceTarget?] = []
        call.onCommandStarts = { started.append($0) }
        await call.start()
        let a = VoiceTarget.canvas(CGPoint(x: 1, y: 1)), b = VoiceTarget.canvas(CGPoint(x: 2, y: 2))
        await call.listen(for: a); call.send(); routes[0].send(.command("make a login screen"))
        #expect(await eventually { runner.commands.count == 1 })
        await call.listen(for: b); call.send(); routes[1].send(.command("make a settings screen"))
        #expect(await eventually { call.queuedCount == 1 })
        runner.holds = false
        #expect(await eventually { runner.commands.count == 2 })
        #expect(started == [a, b])
        #expect(runner.cancelled.isEmpty)
        call.end()
    }

    @Test func cancellingListeningQueuesNothing() async {
        var routes: [FakeRoute] = []
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
        await call.start()
        await call.listen(for: nil)
        call.cancelListening()
        routes[0].send(.command("make it blue"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(routes[0].isStopped && !call.isHearing)
        #expect(runner.commands.isEmpty && call.queuedCount == 0)
        call.end()
    }

    @Test func aSentRouteThatSaysNothingIsStoppedAfterAWhile() async {
        var routes: [FakeRoute] = []
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: FakeRunner())
        call.finishWait = .milliseconds(50)
        await call.start()
        await call.listen(for: nil)
        call.send()
        #expect(await eventually { routes[0].isStopped && !call.isHearing })
        call.end()
    }

    @Test func anOnRequestCommandEndingMidSentenceRunsAtOnce() async {
        // The person said they were done, so "to" at the end is not a pause for thought.
        var routes: [FakeRoute] = []
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
        call.fragmentWait = .seconds(60)
        await call.start()
        await call.listen(for: nil)
        call.send()
        routes[0].send(.command("I want a screen to"))
        #expect(await eventually(within: .seconds(1)) { runner.commands == ["I want a screen to"] })
        call.end()
    }

    @Test func hangUpOnAnOnRequestCallOnlyStops() async {
        var routes: [FakeRoute] = []
        let runner = FakeRunner(); runner.holds = true
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
        await call.start()
        await call.listen(for: nil); call.send(); routes[0].send(.command("make it blue"))
        #expect(await eventually { runner.commands == ["make it blue"] })
        await call.listen(for: nil); call.send(); routes[1].send(.command("Hang up"))
        #expect(await eventually { runner.cancelled == ["make it blue"] })
        #expect(call.phase != .ended)
        call.end()
    }

    @Test func aListenThatFailsLeavesThePencilCallUp() async {
        var routes: [FakeRoute] = []
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: FakeRunner())
        await call.start()
        await call.listen(for: nil)
        routes[0].send(.failed("No microphone"))
        #expect(await eventually { call.caption == VoiceCall.Caption(kind: .problem, text: "No microphone") })
        #expect(routes[0].isStopped && !call.isHearing && call.phase == .listening)
        call.end()
    }

    @Test func aSendBeforeTheRouteCanHearSaysSo() async {
        // A hold let go of before the microphone came on: nothing was heard, and the
        // person is told so rather than left waiting.
        var routes: [FakeRoute] = []
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); r.holdsStart = true; routes.append(r); return r }, runner: runner)
        await call.start()
        let listening = Task { await call.listen(for: nil) }
        #expect(await eventually { call.hasOpenListen })
        call.send()
        #expect(call.caption == VoiceCall.Caption(kind: .problem, text: "Didn't catch that. Wait for the tap, then speak."))
        #expect(routes[0].isStopped && !call.isHearing && !call.isListeningAsAsked)
        routes[0].holdsStart = false
        await listening.value
        #expect(!call.isHearing && !call.isListeningAsAsked && runner.commands.isEmpty)
        call.end()
    }

    @Test func onlyTheOpenListenFillsTheWaveform() async {
        var routes: [FakeRoute] = []
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: FakeRunner())
        await call.start()
        await call.listen(for: nil)
        #expect(call.isListeningAsAsked)
        call.send()
        #expect(!call.isListeningAsAsked && call.isHearing)
        // The sent route, still settling, is no longer what the waveform shows.
        routes[0].send(.level(0.5))
        await call.listen(for: nil)
        routes[1].send(.level(0.8))
        #expect(await eventually { call.levels == [0.8] })
        call.end()
    }

    @Test func aSentRouteThatHeardNothingIsLetGoOfAtOnce() async {
        var routes: [FakeRoute] = []
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
        // Far longer than the test waits: only the route saying so can end it in time.
        call.finishWait = .seconds(60)
        await call.start()
        await call.listen(for: nil)
        call.send()
        routes.last!.send(.nothingHeard)
        #expect(await eventually(within: .seconds(1)) { routes.last!.isStopped && !call.isHearing })
        #expect(runner.commands.isEmpty && call.caption == nil)
        call.end()
    }

    @Test func eachListenStartsWithAnEmptyWaveform() async {
        var routes: [FakeRoute] = []
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: FakeRunner())
        await call.start()
        await call.listen(for: nil)
        routes[0].send(.level(0.5))
        #expect(await eventually { call.levels == [0.5] })
        call.cancelListening()
        await call.listen(for: nil)
        // The last listen's bars aren't this one's.
        #expect(call.levels.isEmpty)
        call.end()
    }

    @Test func aSettlingListensLateWordsAreNotTheNextListens() async {
        var routes: [FakeRoute] = []
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: FakeRunner())
        await call.start()
        await call.listen(for: nil)
        call.send()
        await call.listen(for: nil)
        // The first route, still settling, revises what it heard.
        routes[0].send(.hearing("make it blue"))
        routes[1].send(.level(0.3))
        #expect(await eventually { call.levels == [0.3] })
        #expect(call.caption?.kind != .hearing)
        // Its command still arrives.
        routes[0].send(.command("make it blue"))
        #expect(await eventually { routes[0].isStopped })
        call.end()
    }

    @Test func aSentCommandThatNeverArrivesIsSaid() async {
        // Words were heard, and the route was stopped before it could settle them. Lost
        // without a word, the person would wait for a command that never comes.
        var routes: [FakeRoute] = []
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: FakeRunner())
        call.finishWait = .milliseconds(50)
        await call.start()
        await call.listen(for: nil)
        routes[0].send(.hearing("make it"))
        #expect(await eventually { call.caption?.kind == .hearing })
        call.send()
        #expect(await eventually { routes[0].isStopped && !call.isHearing })
        #expect(call.caption == VoiceCall.Caption(kind: .problem, text: VoiceCall.missedTheEnd))
        call.end()
    }

    @Test func aPencilCallAndAPhoneCallCoexist() async {
        let line = PhoneLine()
        let (phone, phoneRoute, _) = makeCall(line: line)
        let pencil = VoiceCall(listening: .onRequest { FakeRoute() }, runner: FakeRunner(), line: line)
        await phone.start()
        await pencil.start()
        #expect(phone.phase == .listening && !phoneRoute.isStopped)
        let (other, _, _) = makeCall(line: line)
        await other.start()
        #expect(phone.phase == .ended && pencil.phase == .listening)
        other.end()
        pencil.end()
    }

    // MARK: Taking turns, and a pencil call's life (Wave 2)

    private func pencilCall(_ runner: FakeRunner, routes: @escaping (FakeRoute) -> Void = { _ in }) -> VoiceCall {
        VoiceCall(listening: .onRequest { let r = FakeRoute(); routes(r); return r }, runner: runner)
    }

    /// The pencil's call and a phone call act on one design: one command at a time, in
    /// the order they came, and neither is cut short by the other (B-I2, D-I4).
    @Test func callsOnOneDesignTakeTurns() async {
        let gate = VoiceCommandGate()
        var pencilRoutes: [FakeRoute] = []
        let pencilRunner = FakeRunner(); pencilRunner.holds = true
        let pencil = pencilCall(pencilRunner) { pencilRoutes.append($0) }
        let (phone, phoneRoute, phoneRunner) = makeCall()
        pencil.gate = gate
        phone.gate = gate
        var started: [String] = []
        pencil.onCommandStarts = { _ in started.append("pencil") }
        phone.onCommandStarts = { _ in started.append("phone") }
        await pencil.start()
        await phone.start()

        await pencil.listen(for: nil); pencil.send(); pencilRoutes[0].send(.command("make a settings screen"))
        #expect(await eventually { pencilRunner.commands == ["make a settings screen"] })
        phoneRoute.send(.command("make the title bold"))
        try? await Task.sleep(for: .milliseconds(100))
        // The phone call's command waits, and says so; it hasn't selected anything yet.
        #expect(phoneRunner.commands.isEmpty && started == ["pencil"])
        #expect(phone.caption == VoiceCall.Caption(kind: .working, text: VoiceCall.waitingItsTurn))
        #expect(pencilRunner.cancelled.isEmpty)

        pencilRunner.holds = false
        #expect(await eventually { phoneRunner.commands == ["make the title bold"] })
        #expect(started == ["pencil", "phone"])
        #expect(pencilRunner.cancelled.isEmpty)
        #expect(await eventually { !gate.isBusy })
        pencil.end(); phone.end()
    }

    /// Hanging up while a command waits its turn stops it there, and the turn isn't lost.
    @Test func aCommandStoppedWhileWaitingGivesUpItsTurn() async {
        let gate = VoiceCommandGate()
        let first = FakeRunner(); first.holds = true
        var routes: [FakeRoute] = []
        let pencil = pencilCall(first) { routes.append($0) }
        pencil.gate = gate
        let (phone, phoneRoute, phoneRunner) = makeCall()
        phone.gate = gate
        await pencil.start(); await phone.start()
        await pencil.listen(for: nil); pencil.send(); routes[0].send(.command("make a settings screen"))
        #expect(await eventually { first.commands.count == 1 })
        phoneRoute.send(.command("make the title bold"))
        #expect(await eventually { phone.caption?.text == VoiceCall.waitingItsTurn })
        phone.end()
        first.holds = false
        #expect(await eventually { !gate.isBusy && pencil.phase == .listening })
        #expect(phoneRunner.commands.isEmpty)
        // The next command goes at once.
        await pencil.listen(for: nil); pencil.send(); routes[1].send(.command("make it red"))
        #expect(await eventually { first.commands == ["make a settings screen", "make it red"] })
        pencil.end()
    }

    /// The model's endCall hangs up a phone call. A pencil call stays up, with whatever
    /// else was asked of it and its warm model (D-I6).
    @Test func endCallLeavesAPencilCallUp() async {
        let runner = FakeRunner()
        runner.outcomes = [VoiceOutcome(lines: ["Hanging up."], endsCall: true)]
        var routes: [FakeRoute] = []
        let call = pencilCall(runner) { routes.append($0) }
        await call.start()
        await call.listen(for: nil); call.send(); routes[0].send(.command("that's all thanks"))
        #expect(await eventually { runner.commands.count == 1 && call.phase == .listening })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(call.phase == .listening)
        call.end()
    }

    /// A pencil call that ended while its model got ready stays ended (D-M6).
    @Test func aPencilCallEndedWhileWarmingStaysEnded() async {
        let runner = SlowRunner()
        let call = VoiceCall(listening: .onRequest { FakeRoute() }, runner: runner)
        let starting = Task { await call.start() }
        #expect(await eventually { runner.isWarming })
        call.end()
        runner.isWarming = false
        await starting.value
        #expect(call.phase == .ended && call.startedAt == nil)
    }

    /// Closing the design stops sent routes that are still settling, not only the one
    /// listening, so no microphone is left on (D-I5).
    @Test func stoppingAllListeningStopsSettlingRoutesToo() async {
        var routes: [FakeRoute] = []
        let runner = FakeRunner()
        let call = pencilCall(runner) { routes.append($0) }
        call.finishWait = .seconds(60)
        await call.start()
        await call.listen(for: nil); call.send()
        await call.listen(for: nil)
        #expect(routes.count == 2 && !routes[0].isStopped && call.isHearing)
        call.stopAllListening()
        #expect(routes[0].isStopped && routes[1].isStopped && !call.isHearing)
        // What the settling route still sends is acted on no more.
        routes[0].send(.command("make it blue"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.commands.isEmpty)
        call.end()
    }

    /// Each command's own lines say which command they are, so that a pencil bubble can
    /// tell its own from an earlier one's (D-M3).
    @Test func captionsSayWhichCommandTheyAreAbout() async {
        var routes: [FakeRoute] = []
        let runner = FakeRunner()
        let call = pencilCall(runner) { routes.append($0) }
        call.captionTimes = (.seconds(60), .seconds(60))
        await call.start()
        await call.listen(for: nil); call.send(); routes[0].send(.command("make it blue"))
        #expect(await eventually { call.caption?.kind == .done })
        #expect(call.caption?.command == 1 && call.commandsTaken == 1)
        await call.listen(for: nil)
        routes[1].send(.hearing("make it"))
        #expect(await eventually { call.caption?.kind == .hearing })
        #expect(call.caption?.command == nil)
        call.end()
    }

    // MARK: Typed words

    /// Typed words wait for the call to be up. Taken while it starts, a command would set
    /// it working at once, and the start would never finish: no listening, no timer.
    @Test func aCallStillStartingTakesNoTypedWords() async {
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { FakeRoute() }, runner: runner)
        #expect(call.phase == .starting)
        #expect(call.submit("make it blue", about: nil) == nil)
        await call.start()
        #expect(call.phase == .listening && call.startedAt != nil)
        // The words refused took no number.
        #expect(call.submit("make it blue", about: nil) == 1)
        #expect(await eventually { runner.commands == ["make it blue"] })
        call.end()
    }

    @Test func typedWordsAreACommandOfTheirOwn() async {
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { FakeRoute() }, runner: runner)
        await call.start()
        #expect(call.submit("make it blue", about: .canvas(CGPoint(x: 1, y: 2))) == 1)
        #expect(await eventually { runner.commands == ["make it blue"] })
        #expect(runner.targets == [.canvas(CGPoint(x: 1, y: 2))])
        // Nothing typed is no command.
        #expect(call.submit("  \n", about: nil) == nil)
        call.end()
        #expect(call.submit("make it red", about: nil) == nil)
        #expect(runner.commands == ["make it blue"])
    }

    /// Typed words are sent as typed: a word on its own is a command, and "stop" or "hang
    /// up" is put to the model like anything else, not acted on by the call (Review Focus 4).
    @Test func typedWordsAreTakenAsTheyAre() async {
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { FakeRoute() }, runner: runner)
        await call.start()
        #expect(call.submit("blue", about: nil) == 1)
        #expect(call.submit("stop", about: nil) == 2)
        #expect(call.submit("hang up", about: nil) == 3)
        #expect(await eventually { runner.commands == ["blue", "stop", "hang up"] })
        #expect(runner.cancelled.isEmpty)
        #expect(call.phase != .ended)
        call.end()
    }

    /// What a typed change's field shows: the command's own lines, the step it is on and
    /// then its reply, for as long as the line lasts.
    @Test func aCommandsProgressFollowsItsOwnLines() async throws {
        let runner = FakeRunner()
        let call = VoiceCall(listening: .onRequest { FakeRoute() }, runner: runner)
        call.captionTimes = (done: .milliseconds(100), problem: .milliseconds(100))
        runner.holds = true
        await call.start()
        let n = try #require(call.submit("restyle the button", about: nil))
        // Waiting its turn, with no line of its own yet.
        #expect(call.progress(of: n) == .working(nil))
        #expect(await until { call.progress(of: n) == .working("Thinking…") })
        call.showStep("Restyling…")
        #expect(call.progress(of: n) == .working("Restyling…"))
        // A command the call never took has nothing to show.
        #expect(call.progress(of: n + 1) == .over)
        runner.outcomes = [VoiceOutcome(lines: ["Restyled the button."])]
        runner.holds = false
        #expect(await until { call.progress(of: n) == .done("Restyled the button.") })
        #expect(await until { call.progress(of: n) == .over })
        call.end()
    }

    @Test func aCommandsProblemAndWhatTheModelSaidAreFollowedToo() async throws {
        let runner = FakeRunner()
        runner.outcomes = [VoiceOutcome(problem: "No connection."), VoiceOutcome(said: "I can only change the design.")]
        let call = VoiceCall(listening: .onRequest { FakeRoute() }, runner: runner)
        await call.start()
        let first = try #require(call.submit("make it blue", about: nil))
        #expect(await until { call.progress(of: first) == .problem("No connection.") })
        let second = try #require(call.submit("write me a poem", about: nil))
        #expect(await until { call.progress(of: second) == .said("I can only change the design.") })
        // The second's line has taken the place of the first's.
        #expect(call.progress(of: first) == .over)
        call.end()
    }

    /// A change typed while a spoken command runs waits its turn behind it.
    @Test func typedWordsWaitBehindASpokenCommand() async throws {
        var routes: [FakeRoute] = []
        let runner = FakeRunner(); runner.holds = true
        let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
        await call.start()
        await call.listen(for: nil); call.send(); routes[0].send(.command("make it blue"))
        #expect(await eventually { runner.commands == ["make it blue"] })
        let typed = try #require(call.submit("make it red", about: nil))
        // The spoken command was numbered as it was sent.
        #expect(typed == 2)
        #expect(call.queuedCount == 1)
        #expect(call.progress(of: typed) == .working(nil))
        runner.holds = false
        #expect(await eventually { runner.commands == ["make it blue", "make it red"] })
        call.end()
    }

    /// Ending the call ends its commands too: the one under way and the ones waiting are
    /// over, and none is left showing as working with nothing to come.
    @Test func aCommandUnderWayWhenTheCallEndsIsOver() async throws {
        let runner = FakeRunner(); runner.holds = true
        let call = VoiceCall(listening: .onRequest { FakeRoute() }, runner: runner)
        await call.start()
        let n = try #require(call.submit("make it blue", about: nil))
        #expect(await until { call.progress(of: n) == .working("Thinking…") })
        #expect(await eventually { runner.commands == ["make it blue"] })
        let m = try #require(call.submit("make it red", about: nil))
        #expect(call.progress(of: m) == .working(nil))
        call.end()
        #expect(call.progress(of: n) == .over)
        #expect(call.progress(of: m) == .over)
        #expect(!call.isUnderWay(n))
        // Still over once the stopped command has come back.
        #expect(await eventually { runner.cancelled == ["make it blue"] })
        #expect(call.progress(of: n) == .over && !call.isUnderWay(n))
    }
}

/// A runner whose getting ready lasts until the test lets it go.
@MainActor
private final class SlowRunner: VoiceCommandRunner {
    var isWarming = false
    func warmUp() async {
        isWarming = true
        while isWarming { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func run(_ command: String) async -> VoiceOutcome { VoiceOutcome() }

}

@Suite("Commands from recognised speech")
struct UtteranceAssemblerTests {
    private let start = ContinuousClock.now

    /// A moment so many milliseconds into the call.
    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    /// Someone speaking from one moment to another: loud sound, a tenth of a second at a time.
    private func speak(_ assembler: inout UtteranceAssembler, from begin: Int, to end: Int) {
        for moment in stride(from: begin, through: end, by: 100) {
            assembler.sound(level: 0.6, at: at(moment))
        }
    }

    /// As it ships. Someone thinking between words isn't finished: on an iPad, pauses of
    /// under a second kept cutting sentences in two.
    @Test func aPauseForThoughtDoesNotEndACommand() {
        var assembler = UtteranceAssembler()
        speak(&assembler, from: 0, to: 1000)
        assembler.heard("I want a screen", isFinal: true, at: at(900))
        // Quiet for 1.7 s: still thinking. At 1.2 s, on an iPad, "I want a screen to"
        // was taken as a whole command.
        #expect(assembler.next(at: at(2700)) == .wait)
        // Quiet for 1.8 s: finished.
        #expect(assembler.next(at: at(2800)) == .settle)
    }

    /// Where the room never goes quiet, words unchanged for 2.5 s end the command: longer
    /// than the pause, so that it is the pause that ends a command wherever it can.
    @Test func inANoisyRoomWordsUnchangedFor2Point5SecondsEndACommand() {
        var assembler = UtteranceAssembler()
        speak(&assembler, from: 0, to: 6000)
        assembler.heard("zoom out", isFinal: true, at: at(1000))
        #expect(assembler.next(at: at(3400)) == .wait)
        #expect(assembler.next(at: at(3500)) == .settle)
    }

    @Test func quietAfterSpeechEndsACommand() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        speak(&assembler, from: 0, to: 1000)
        assembler.heard("make the button blue", isFinal: true, at: at(900))
        #expect(assembler.hearing == "make the button blue")
        // Quiet for half a second: perhaps only a breath.
        #expect(assembler.next(at: at(1500)) == .wait)
        // Quiet for 0.8 s: the recogniser is asked to settle whatever it still holds.
        #expect(assembler.next(at: at(1800)) == .settle)
        #expect(assembler.next(at: at(1820)) == .wait)
        assembler.settled(at: at(1850))
        // Its last phrases are given a moment to arrive, and then the command is taken.
        #expect(assembler.next(at: at(1900)) == .wait)
        #expect(assembler.next(at: at(2100)) == .command("make the button blue"))
        // Said once, carried out once.
        #expect(assembler.hearing == "")
        #expect(assembler.next(at: at(6000)) == .wait)
    }

    /// A recogniser hands words over in bursts about a second apart. A second without
    /// new words, in the middle of a sentence, is not the end of it.
    @Test func aGapBetweenBurstsOfWordsDoesNotCutACommandShort() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        speak(&assembler, from: 0, to: 3000)
        assembler.heard("Make the button half width and", isFinal: false, at: at(1500))
        assembler.heard("Make the button half width, and align", isFinal: true, at: at(1600))
        // A full second with no new words, while the speaker is still speaking.
        #expect(assembler.next(at: at(2600)) == .wait)
        assembler.heard("the image centrally", isFinal: true, at: at(2700))
        #expect(assembler.next(at: at(3500)) == .wait)
        #expect(assembler.next(at: at(3800)) == .settle)
        assembler.settled(at: at(3850))
        #expect(assembler.next(at: at(4100)) == .command("Make the button half width, and align the image centrally"))
    }

    /// A word or two is over before the recogniser has reported anything.
    @Test func aShortCommandIsFlushedOutOfTheRecogniser() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        speak(&assembler, from: 0, to: 400)
        #expect(assembler.next(at: at(1000)) == .wait)
        #expect(assembler.next(at: at(1200)) == .settle)
        assembler.heard("Undo.", isFinal: true, at: at(1260))
        assembler.settled(at: at(1300))
        #expect(assembler.next(at: at(1550)) == .command("Undo."))
    }

    @Test func noiseWithoutWordsIsNothing() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        assembler.sound(level: 0.9, at: at(0))
        #expect(assembler.next(at: at(800)) == .settle)
        assembler.settled(at: at(850))
        #expect(assembler.next(at: at(1100)) == .wait)
        #expect(assembler.hearing == "")
        // And it isn't asked about again.
        #expect(assembler.next(at: at(5000)) == .wait)
    }

    @Test func speakingAgainBeforeItIsTakenGoesOnWithTheCommand() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        speak(&assembler, from: 0, to: 1000)
        assembler.heard("make the button", isFinal: true, at: at(900))
        #expect(assembler.next(at: at(1800)) == .settle)
        assembler.settled(at: at(1850))
        // The speaker goes on before the command is taken.
        speak(&assembler, from: 1900, to: 2600)
        #expect(assembler.next(at: at(2300)) == .wait)
        assembler.heard("half width", isFinal: true, at: at(2700))
        #expect(assembler.next(at: at(3000)) == .wait)
        #expect(assembler.next(at: at(3400)) == .settle)
        assembler.settled(at: at(3450))
        #expect(assembler.next(at: at(3700)) == .command("make the button half width"))
    }

    /// Where the room is never quiet, words going stale are what ends a command.
    @Test func inANoisyRoomWordsGoingStaleEndTheCommand() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        speak(&assembler, from: 0, to: 4000)
        assembler.heard("zoom out", isFinal: true, at: at(1000))
        #expect(assembler.next(at: at(2500)) == .wait)
        #expect(assembler.next(at: at(3000)) == .settle)
        assembler.settled(at: at(3050))
        #expect(assembler.next(at: at(3300)) == .command("zoom out"))
    }

    /// The same, the way a route really meets it: loud sound and a question about what
    /// to do next, turn and turn about, ten times a second. Loudness that never stops
    /// must not keep calling the command back from being taken.
    @Test func inARoomThatIsNeverQuietStaleWordsStillEndTheCommand() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        assembler.sound(level: 0.6, at: at(0))
        assembler.heard("zoom out", isFinal: false, at: at(100))
        var steps: [UtteranceAssembler.Step] = []
        for moment in stride(from: 200, through: 4000, by: 100) {
            assembler.sound(level: 0.6, at: at(moment))
            let step = assembler.next(at: at(moment + 50))
            if step == .settle { assembler.settled(at: at(moment + 60)) }
            if step != .wait { steps.append(step) }
        }
        #expect(steps == [.settle, .command("zoom out")])
    }

    /// Speech too soft to tell from the room is still heard by its words.
    @Test func softSpeechIsKnownByItsWords() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        for moment in stride(from: 0, through: 3000, by: 100) { assembler.sound(level: 0.05, at: at(moment)) }
        assembler.heard("zoom out", isFinal: true, at: at(500))
        #expect(assembler.next(at: at(2400)) == .wait)
        #expect(assembler.next(at: at(2500)) == .settle)
        assembler.settled(at: at(2550))
        #expect(assembler.next(at: at(2800)) == .command("zoom out"))
    }

    @Test func volatileTextIsShownButReplaced() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        assembler.heard("make the", isFinal: false, at: at(0))
        #expect(assembler.hearing == "make the")
        assembler.heard("make the button", isFinal: false, at: at(200))
        #expect(assembler.hearing == "make the button")
        assembler.heard("Make the button blue.", isFinal: true, at: at(400))
        #expect(assembler.hearing == "Make the button blue.")
        assembler.heard("and bold", isFinal: false, at: at(600))
        #expect(assembler.hearing == "Make the button blue. and bold")
    }

    /// Between commands a recogniser can settle a phrase that is only punctuation.
    @Test func punctuationAloneIsNotWords() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        assembler.heard(",...", isFinal: true, at: at(0))
        assembler.heard(".", isFinal: false, at: at(100))
        #expect(assembler.hearing == "")
        #expect(assembler.next(at: at(5000)) == .wait)
        speak(&assembler, from: 5000, to: 5500)
        assembler.heard(",...", isFinal: true, at: at(5600))
        assembler.heard("Show me the first screen.", isFinal: true, at: at(5700))
        #expect(assembler.hearing == "Show me the first screen.")
    }

    /// The quiet before a command can come out as punctuation at the start of it.
    @Test func punctuationBeforeTheFirstWordIsDropped() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        assembler.heard(",... Show me the 1st screen.", isFinal: true, at: at(0))
        #expect(assembler.hearing == "Show me the 1st screen.")
        assembler.heard(".. make it blue", isFinal: false, at: at(100))
        #expect(assembler.hearing == "Show me the 1st screen. make it blue")
    }

    /// A recogniser runs behind the speaker. Asked to settle, it brings out the words it
    /// was still working on; those are the end of this command, not the speaker going on.
    @Test func wordsTheRecogniserBringsOutOnSettlingDoNotRestartTheWait() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        speak(&assembler, from: 0, to: 1000)
        assembler.heard("show me the", isFinal: false, at: at(900))
        #expect(assembler.next(at: at(1800)) == .settle)
        assembler.heard("show me the first", isFinal: false, at: at(1900))
        #expect(assembler.next(at: at(1950)) == .wait)
        assembler.heard("Show me the first screen.", isFinal: true, at: at(2000))
        assembler.settled(at: at(2050))
        // Not asked to settle a second time, and taken a moment after its last words.
        #expect(assembler.next(at: at(2200)) == .wait)
        #expect(assembler.next(at: at(2300)) == .command("Show me the first screen."))
    }

    @Test func wordsThatNeverSettleAreTakenAsTheyAre() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        speak(&assembler, from: 0, to: 600)
        assembler.heard("show me the first screen", isFinal: false, at: at(500))
        #expect(assembler.next(at: at(1400)) == .settle)
        // The recogniser never says it has settled. It is given a second and a half.
        #expect(assembler.next(at: at(2000)) == .wait)
        #expect(assembler.next(at: at(2900)) == .command("show me the first screen"))
        // Settled late, the same words aren't a second command.
        assembler.heard("Show me the first screen.", isFinal: true, at: at(3100))
        #expect(assembler.hearing == "")
        #expect(assembler.next(at: at(8000)) == .wait)
        // But the next thing said is.
        speak(&assembler, from: 9000, to: 9500)
        assembler.heard("zoom out", isFinal: true, at: at(9600))
        #expect(assembler.next(at: at(10300)) == .settle)
        assembler.settled(at: at(10350))
        #expect(assembler.next(at: at(10600)) == .command("zoom out"))
    }

    @Test func silenceGivesNothing() {
        var assembler = UtteranceAssembler(pause: .milliseconds(800), staleness: .seconds(2))
        for moment in stride(from: 0, through: 5000, by: 100) { assembler.sound(level: 0, at: at(moment)) }
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

@Suite("Flicking the pencil bar away")
@MainActor
struct PencilBarFlickTests {
    @Test func aFlickAsideOrDownIsOneAndAnythingElseIsNot() {
        // Sideways, either way, and mostly sideways.
        #expect(PaletteFlick.isFlick(CGSize(width: 90, height: 6)))
        #expect(PaletteFlick.isFlick(CGSize(width: -120, height: -20)))
        // Downward, off the bottom of the window.
        #expect(PaletteFlick.isFlick(CGSize(width: 10, height: 50)))
        // A tap, a short nudge, and a drag up into the canvas are none of them a flick.
        #expect(!PaletteFlick.isFlick(CGSize(width: 2, height: 1)))
        #expect(!PaletteFlick.isFlick(CGSize(width: 30, height: 4)))
        #expect(!PaletteFlick.isFlick(CGSize(width: 12, height: -140)))
    }

    @Test func flickingTheBarAwayInANarrowWindowEndsDrawing() {
        let app = AppModel(document: LayerDocument())
        app.isCompactSizeClass = true
        app.tool = .draw
        app.pencilBarFlickedAway()
        #expect(app.tool == .select)
    }

    /// A wider window has the palette that floats, which tucks itself into a corner.
    @Test func aWiderWindowKeepsItsPalette() {
        let app = AppModel(document: LayerDocument())
        app.isCompactSizeClass = false
        app.tool = .draw
        app.pencilBarFlickedAway()
        #expect(app.tool == .draw)
    }

    /// Drawing and voice mode are one or the other: while Draw is on the pencil bar has
    /// the bottom of a narrow window, and the phone button isn't there at all.
    @Test func thePhoneButtonIsHiddenWhileDrawIsOn() {
        let app = AppModel(document: LayerDocument())
        app.isCompactSizeClass = true
        app.tool = .select
        #expect(app.offersVoiceMode)
        app.tool = .draw
        #expect(!app.offersVoiceMode)
        // Putting the bar away brings the phone button back.
        app.pencilBarFlickedAway()
        #expect(app.offersVoiceMode)
    }

    /// A narrow window, or a phone, opens a design with Draw off. The palette comes when
    /// the window widens; drawing turned on by hand is kept whatever the width does.
    @Test func aDesignOpenedNarrowStartsWithoutDrawing() {
        let narrow = AppModel(document: LayerDocument())
        narrow.isCompactSizeClass = true
        #expect(narrow.tool == .select)
        narrow.isCompactSizeClass = false
        #expect(narrow.tool == .draw)

        let wide = AppModel(document: LayerDocument())
        wide.isCompactSizeClass = false
        #expect(wide.tool == .draw)
        wide.isCompactSizeClass = true
        #expect(wide.tool == .draw)

        let chosen = AppModel(document: LayerDocument())
        chosen.isCompactSizeClass = true
        chosen.tool = .draw
        chosen.isCompactSizeClass = false
        chosen.isCompactSizeClass = true
        #expect(chosen.tool == .draw)
    }

    /// Drawing waits for a wider window only until something else is chosen, and a call is
    /// that: widening the window while one is up leaves Draw off, so the pencil bar doesn't
    /// come over the pill, and hanging up in the narrow window brings the phone button back.
    @Test func wideningTheWindowDuringACallLeavesDrawOff() async {
        let app = AppModel(document: LayerDocument())
        app.phoneLine = PhoneLine()
        app.isCompactSizeClass = true
        #expect(app.tool == .select)
        await app.startVoiceCall(route: FakeRoute(), runner: FakeRunner())
        #expect(app.isInVoiceCall)
        app.isCompactSizeClass = false
        #expect(app.tool == .select)
        app.isCompactSizeClass = true
        app.endVoiceCall()
        #expect(app.tool == .select)
        #expect(app.offersVoiceMode)
    }

    @Test func thePhoneButtonIsOnlyInANarrowWindowWithNothingOverIt() async {
        let app = AppModel(document: LayerDocument())
        app.phoneLine = PhoneLine()
        // A design opened in a narrow window starts with Draw off, so with the phone button.
        app.isCompactSizeClass = true
        #expect(app.offersVoiceMode)
        app.tool = .draw
        #expect(!app.offersVoiceMode)
        app.tool = .select
        #expect(app.offersVoiceMode)
        app.isCompactSizeClass = false
        #expect(!app.offersVoiceMode)
        app.isCompactSizeClass = true
        app.isLayersOpen = true
        #expect(!app.offersVoiceMode)
        app.isLayersOpen = false
        app.isInspectorOpen = true
        #expect(!app.offersVoiceMode)
        app.isInspectorOpen = false
        // A call that is up has the pill in its place.
        await app.startVoiceCall(route: FakeRoute(), runner: FakeRunner())
        #expect(!app.offersVoiceMode)
        app.endVoiceCall()
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
        #expect(AudioLevel.level(of: buffer(amplitude: 0)) == 0)
        let quiet = AudioLevel.level(of: buffer(amplitude: 0.02))
        let speaking = AudioLevel.level(of: buffer(amplitude: 0.2))
        let loud = AudioLevel.level(of: buffer(amplitude: 1))
        #expect(quiet > 0 && quiet < speaking)
        #expect(speaking > 0.5 && speaking < 1)
        #expect(loud == 1)
    }

    @Test func aBufferGivesALevelForEachStretch() {
        // Loud for its first half, silent for its second.
        let half = buffer(amplitude: 1)
        let samples = half.floatChannelData![0]
        for index in 800..<1600 { samples[index] = 0 }
        #expect(AudioLevel.levels(of: half, count: 2) == [1, 0])
        #expect(AudioLevel.levels(of: half, count: 1).count == 1)
    }
}
