import Foundation
import Testing
@testable import Layer

/// A route the test drives by hand: it hears what the test says it hears.
@MainActor
final class FakeRoute: VoiceRoute {
    private var continuation: AsyncStream<VoiceRouteEvent>.Continuation?
    private(set) var isStopped = false
    private(set) var vocabulary: [String] = []
    var startError: (any Error)?

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
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
}
