import AVFoundation
import Foundation
import Testing
@testable import Layer

/// Sound the test hands over a buffer at a time.
@MainActor
final class FakeAudioSource: VoiceAudioSource {
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var isStopped = false
    private(set) var wasStarted = false
    /// Whether the microphone is on: started, and not stopped since.
    private(set) var isRunning = false
    var startError: (any Error)?
    /// While set, starting waits, as it does with the alert that asks for the microphone up.
    var holdsStart = false
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

    func start() async throws -> AsyncStream<AudioChunk> {
        wasStarted = true
        while holdsStart { try? await Task.sleep(for: .milliseconds(5)) }
        if let startError { throw startError }
        let (sound, continuation) = AsyncStream<AudioChunk>.makeStream()
        self.continuation = continuation
        isRunning = true
        return sound
    }

    func stop() {
        isStopped = true
        isRunning = false
        continuation?.finish()
    }

    /// A tenth of a second of a tone at `amplitude`.
    func play(amplitude: Float) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        let samples = buffer.floatChannelData![0]
        for index in 0..<1600 { samples[index] = amplitude * sin(Float(index) * 2 * .pi * 440 / 16000) }
        continuation?.yield(AudioChunk(buffer: buffer))
    }

    /// The microphone going away under the route.
    func cutOut() {
        continuation?.finish()
    }
}

/// A recogniser that hears what the test says it hears.
final class FakeRecogniser: PhraseRecogniser, @unchecked Sendable {
    private let state = NSLock()
    private var continuation: AsyncThrowingStream<HeardPhrase, any Error>.Continuation?
    private var settles = 0
    private var stopped = false
    private var told: [String] = []
    private var chunks = 0
    private var heldBack: [HeardPhrase] = []
    var startError: (any Error)?
    var prepareError: (any Error)?
    private var holding = false
    private var holdingStart = false
    private var holdingSettle = false
    private var started = false
    /// Waits for it to start listening (`untilStarted()`), by the wait's id.
    private var startWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Waits cancelled before they began waiting: they don't.
    private var abandonedWaits: Set<UUID> = []

    /// While set, getting ready waits, as it does while what speech needs is fetched.
    var holdsPrepare: Bool {
        get { state.withLock { holding } }
        set { state.withLock { holding = newValue } }
    }

    /// While set, starting to listen waits, as loading the model for it does.
    var holdsStart: Bool {
        get { state.withLock { holdingStart } }
        set { state.withLock { holdingStart = newValue } }
    }

    /// While set, settling never comes back, as a recogniser stuck finalising wouldn't.
    var holdsSettle: Bool {
        get { state.withLock { holdingSettle } }
        set { state.withLock { holdingSettle = newValue } }
    }

    /// Whether it was ever asked to listen.
    var wasStarted: Bool { state.withLock { started } }

    /// Returns once it has been asked to listen, and can be told what it hears: at once if it has been, and at once
    /// when the wait is cancelled, as at a test's time limit.
    func untilStarted() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                let resumesNow = state.withLock {
                    let now = started || abandonedWaits.contains(id)
                    if !now { startWaiters[id] = waiter }
                    return now
                }
                if resumesNow { waiter.resume() }
            }
        } onCancel: {
            let waiter = state.withLock {
                abandonedWaits.insert(id)
                return startWaiters.removeValue(forKey: id)
            }
            waiter?.resume()
        }
    }

    func prepare() async throws {
        while holdsPrepare { try? await Task.sleep(for: .milliseconds(5)) }
        if let prepareError { throw prepareError }
    }

    /// Words the recogniser has heard but won't report until it is asked to settle.
    func holdBack(_ text: String) {
        state.withLock { heldBack.append(HeardPhrase(text: text, isFinal: true)) }
    }

    var settleCount: Int { state.withLock { settles } }
    var isStopped: Bool { state.withLock { stopped } }
    var vocabulary: [String] { state.withLock { told } }
    var chunksHeard: Int { state.withLock { chunks } }

    func start(sound: AsyncStream<AudioChunk>, format: AVAudioFormat, vocabulary: [String]) async throws -> AsyncThrowingStream<HeardPhrase, any Error> {
        while holdsStart { try? await Task.sleep(for: .milliseconds(5)) }
        if let startError { throw startError }
        let (phrases, continuation) = AsyncThrowingStream<HeardPhrase, any Error>.makeStream()
        let waiters = state.withLock {
            self.continuation = continuation
            told = vocabulary
            started = true
            defer { startWaiters = [:] }
            return startWaiters
        }
        for waiter in waiters.values { waiter.resume() }
        Task {
            for await _ in sound { self.state.withLock { self.chunks += 1 } }
        }
        return phrases
    }

    func settle() async -> Bool {
        let (continuation, phrases, started) = state.withLock {
            settles += 1
            defer { heldBack = [] }
            return (self.continuation, heldBack, self.started)
        }
        // Not listening yet, as a real one isn't: nothing to settle.
        guard started else { return false }
        for phrase in phrases { continuation?.yield(phrase) }
        while holdsSettle { try? await Task.sleep(for: .milliseconds(5)) }
        return true
    }

    func stop() async {
        let continuation = state.withLock {
            stopped = true
            return self.continuation
        }
        continuation?.finish()
    }

    func hear(_ text: String, isFinal: Bool) {
        state.withLock { continuation }?.yield(HeardPhrase(text: text, isFinal: isFinal))
    }

    func fail(with error: any Error) {
        state.withLock { continuation }?.finish(throwing: error)
    }
}

/// Events a test has collected, read on the main actor.
@MainActor
private final class Received {
    var events: [VoiceRouteEvent] = []
}

/// Something handed to another thread on the test's own say-so.
private struct Handed<Value>: @unchecked Sendable {
    let value: Value
}

@Suite("The microphone")
struct MicrophoneTapTests {
    /// The audio engine hands over its sound on a thread of its own. The block it calls
    /// must belong to no actor: written in place inside the main-actor class it was
    /// taken for the main actor's, and the first sound to arrive stopped the app. That
    /// happened on an iPad, the only place the microphone had ever really run.
    ///
    /// This test is not on the main actor, and takes the block without waiting: it only
    /// builds while the block belongs to no actor.
    @Test func soundIsTakenOnWhateverThreadTheEngineBringsItOn() async {
        let (sound, continuation) = AsyncStream<AudioChunk>.makeStream()
        let block = Handed(value: AudioEngineHardware.tapBlock(handingTo: { continuation.yield($0) }))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        let handed = Handed(value: buffer)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "a thread of the engine's").async {
                block.value(handed.value, AVAudioTime(hostTime: 0))
                done.resume()
            }
        }
        continuation.finish()

        var chunks = 0
        for await _ in sound { chunks += 1 }
        #expect(chunks == 1)
    }

    // MARK: One microphone for every route

    private func chunk() -> AudioChunk {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        return AudioChunk(buffer: buffer)
    }

    private func count(_ sound: AsyncStream<AudioChunk>) -> Task<Int, Never> {
        Task {
            var chunks = 0
            for await _ in sound { chunks += 1 }
            return chunks
        }
    }

    /// Two routes overlap, as a sent squeeze settling does with the next squeeze. The
    /// first to stop must not turn the microphone off under the other: that left the
    /// second route hearing nothing, and its command was lost.
    @Test func overlappingListenersShareOneMicrophone() async throws {
        let hardware = FakeHardware()
        let microphone = Microphone(hardware: hardware)
        let first = try await microphone.listen()
        let second = try await microphone.listen()
        #expect(hardware.starts == 1)
        let firstHeard = count(first.sound), secondHeard = count(second.sound)
        hardware.play(chunk())
        microphone.stopListening(first.listener)
        #expect(await firstHeard.value == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(hardware.stops == 0)
        // The second still hears.
        hardware.play(chunk())
        microphone.stopListening(second.listener)
        #expect(await secondHeard.value == 2)
        #expect(await eventuallyOff { hardware.stops == 1 })
        #expect(hardware.starts == 1)
    }

    @Test func theMicrophoneComesBackOnForTheNextListener() async throws {
        let hardware = FakeHardware()
        let microphone = Microphone(hardware: hardware)
        let first = try await microphone.listen()
        microphone.stopListening(first.listener)
        let second = try await microphone.listen()
        #expect(await eventuallyOff { hardware.starts + hardware.stops >= 1 })
        // Either it stayed on for the second, or it went off and came back on.
        #expect(hardware.starts - hardware.stops == 1)
        microphone.stopListening(second.listener)
        #expect(await eventuallyOff { hardware.starts == hardware.stops })
    }

    @Test func aMicrophoneThatCannotStartCountsNoListener() async throws {
        let hardware = FakeHardware()
        hardware.startError = DictationRoute.Failure.microphoneUnavailable
        let microphone = Microphone(hardware: hardware)
        await #expect(throws: DictationRoute.Failure.microphoneUnavailable) { _ = try await microphone.listen() }
        #expect(microphone.listenerCount == 0)
        hardware.startError = nil
        let listening = try await microphone.listen()
        #expect(hardware.starts == 1)
        microphone.stopListening(listening.listener)
    }

    @Test func losingTheMicrophoneEndsEveryonesSound() async throws {
        let hardware = FakeHardware()
        let microphone = Microphone(hardware: hardware)
        let first = try await microphone.listen(), second = try await microphone.listen()
        let firstHeard = count(first.sound), secondHeard = count(second.sound)
        hardware.loseIt()
        #expect(await firstHeard.value == 0)
        #expect(await secondHeard.value == 0)
        #expect(await eventuallyOff { hardware.stops == 1 })
        #expect(microphone.listenerCount == 0)
    }

    /// News that an earlier engine went away, arriving after the microphone was turned
    /// off and on again, must not stop the engine that is on now.
    @Test func aLateLossOfAnEarlierMicrophoneIsIgnored() async throws {
        let hardware = FakeHardware()
        let microphone = Microphone(hardware: hardware)
        let first = try await microphone.listen()
        microphone.stopListening(first.listener)
        #expect(await eventuallyOff { hardware.stops == 1 })
        let second = try await microphone.listen()
        #expect(hardware.starts == 2)
        hardware.loseIt(fromStart: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(hardware.stops == 1 && microphone.listenerCount == 1)
        microphone.stopListening(second.listener)
    }

    /// A route dropped without being stopped lets go of the microphone all the same.
    @Test @MainActor func aTapLetGoOfWithoutStoppingLetsGoOfTheMicrophone() async throws {
        let hardware = FakeHardware()
        let microphone = Microphone(hardware: hardware)
        var tap: MicrophoneTap? = MicrophoneTap(microphone: microphone, askForAccess: { true })
        _ = try await tap?.start()
        #expect(microphone.listenerCount == 1)
        tap = nil
        #expect(microphone.listenerCount == 0)
        #expect(await eventuallyOff { hardware.stops == 1 })
    }

    /// Let go of while the alert asking for the microphone was up: it never comes on.
    @Test @MainActor func aTapStoppedWhileAskingNeverTurnsTheMicrophoneOn() async throws {
        let hardware = FakeHardware()
        let microphone = Microphone(hardware: hardware)
        let answer = AsyncStream<Bool>.makeStream()
        let tap = MicrophoneTap(microphone: microphone, askForAccess: {
            for await allowed in answer.stream { return allowed }
            return false
        })
        let starting = Task { try await tap.start() }
        try await Task.sleep(for: .milliseconds(30))
        tap.stop()
        answer.continuation.yield(true)
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
        #expect(hardware.starts == 0 && microphone.listenerCount == 0)
    }

    private func eventuallyOff(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// Hardware the test turns on and off by hand, and hands sound through.
final class FakeHardware: MicrophoneHardware, @unchecked Sendable {
    private let state = NSLock()
    private var started = 0
    private var stopped = 0
    private var failure: (any Error)?
    private var hearing: (@Sendable (AudioChunk) -> Void)?
    private var lost: (@Sendable () -> Void)?
    /// What each start was told to call if the microphone went away, in order.
    private var losts: [@Sendable () -> Void] = []

    var starts: Int { state.withLock { started } }
    var stops: Int { state.withLock { stopped } }
    var startError: (any Error)? {
        get { state.withLock { failure } }
        set { state.withLock { failure = newValue } }
    }

    func start(hearing: @escaping @Sendable (AudioChunk) -> Void, lost: @escaping @Sendable () -> Void) throws -> AVAudioFormat {
        try state.withLock {
            if let failure { throw failure }
            started += 1
            self.hearing = hearing
            self.lost = lost
            losts.append(lost)
        }
        return AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    }

    func stop() {
        state.withLock {
            stopped += 1
            hearing = nil
            lost = nil
        }
    }

    func play(_ chunk: AudioChunk) {
        state.withLock { hearing }?(chunk)
    }

    func loseIt() {
        state.withLock { lost }?()
    }

    /// The microphone of an earlier start reporting it went away, late.
    func loseIt(fromStart index: Int) {
        state.withLock { losts[index] }()
    }
}

@Suite("Getting speech ready")
struct PreparedOnceTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    /// Every squeeze makes a route of its own. The language and the model are worked out
    /// for the first, and the rest are handed the same.
    @Test func itIsWorkedOutOnceForEveryone() async throws {
        let ready = PreparedOnce<String, Int>()
        let made = Counter()
        async let one = ready.value(for: "en") { try await Task.sleep(for: .milliseconds(50)); return made.next() }
        async let two = ready.value(for: "en") { made.next() }
        #expect(try await [one, two] == [1, 1])
        #expect(try await ready.value(for: "en") { made.next() } == 1)
        #expect(made.count == 1)
    }

    @Test func aFailureIsTriedAgain() async throws {
        let ready = PreparedOnce<String, Int>()
        await #expect(throws: DictationRoute.Failure.speechUnavailable) {
            _ = try await ready.value(for: "en") { throw DictationRoute.Failure.speechUnavailable }
        }
        #expect(try await ready.value(for: "en") { 7 } == 7)
    }
}

@Suite("Hearing commands through the microphone", .serialized)
@MainActor
struct DictationRouteTests {
    private struct Bench {
        let route: DictationRoute
        let audio: FakeAudioSource
        let recogniser: FakeRecogniser
    }

    /// A route in a hurry: a fifth of a second of quiet ends a command, or three tenths
    /// without new words where there is no sound to go by. `patience` is how long the recogniser is given to settle.
    private func bench(patience: Duration = .milliseconds(400)) -> Bench {
        let audio = FakeAudioSource()
        let recogniser = FakeRecogniser()
        let assembler = UtteranceAssembler(
            pause: .milliseconds(200), staleness: .milliseconds(300), patience: patience, settling: .milliseconds(50)
        )
        return Bench(route: DictationRoute(source: audio, recogniser: recogniser, assembler: assembler), audio: audio, recogniser: recogniser)
    }

    /// Gathers what the route reports until `stop` says it has seen enough, or two seconds pass.
    private func events(from stream: AsyncStream<VoiceRouteEvent>, until stop: @escaping @Sendable ([VoiceRouteEvent]) -> Bool) async -> [VoiceRouteEvent] {
        let gathering = Task {
            var seen: [VoiceRouteEvent] = []
            for await event in stream {
                seen.append(event)
                if stop(seen) { break }
            }
            return seen
        }
        let giveUp = Task {
            try? await Task.sleep(for: .seconds(2))
            gathering.cancel()
        }
        let seen = await gathering.value
        giveUp.cancel()
        return seen
    }

    /// Gathers what the route reports until `stop` says it has seen enough, with no limit of its own: for what the test
    /// knows comes, however long the main actor that every suite shares takes to get to it. The test's time limit
    /// (`.timeLimit`) is what an event that never comes runs into.
    private func everyEvent(from stream: AsyncStream<VoiceRouteEvent>, until stop: ([VoiceRouteEvent]) -> Bool) async -> [VoiceRouteEvent] {
        var seen: [VoiceRouteEvent] = []
        for await event in stream {
            seen.append(event)
            if stop(seen) { break }
        }
        return seen
    }

    private nonisolated func commands(in events: [VoiceRouteEvent]) -> [String] {
        events.compactMap { if case .command(let text) = $0 { text } else { nil } }
    }

    /// It waits on the recogniser starting and on the command, never on a clock: against 3 s for the start, a stall of
    /// the main actor that every suite shares ran the limit out, and the words were said before anything listened. The
    /// recogniser's patience is out of reach, so the command comes by its settling, as this is about, not by a stall
    /// running the patience out before the settle could be asked (the sweep, lane 2).
    @Test(.timeLimit(.minutes(1)))
    func wordsBecomeACommandAfterAPause() async throws {
        let bench = bench(patience: .seconds(3600))
        let stream = try await bench.route.start(vocabulary: [])
        await bench.recogniser.untilStarted()
        #expect(bench.recogniser.wasStarted)
        bench.recogniser.hear("make the button", isFinal: false)
        bench.recogniser.hear("Make the button blue", isFinal: true)
        let seen = await everyEvent(from: stream) { [self] in !commands(in: $0).isEmpty }
        #expect(seen.contains(.hearing("make the button")))
        #expect(seen.contains(.hearing("Make the button blue")))
        #expect(commands(in: seen) == ["Make the button blue"])
        // The recogniser is asked to settle before a command is taken, in case it holds more.
        #expect(bench.recogniser.settleCount == 1)
        bench.route.stop()
    }

    @Test func quietAfterSpeechEndsACommandWithWhatTheRecogniserStillHeld() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
        // Someone speaks for a moment. The recogniser has reported nothing yet.
        bench.recogniser.holdBack("Show me the first screen.")
        for _ in 0..<3 {
            bench.audio.play(amplitude: 0.3)
            try await Task.sleep(for: .milliseconds(40))
        }
        // Then the room is quiet, and the words come out when it is asked to settle.
        let seen = await events(from: stream) { [self] in !commands(in: $0).isEmpty }
        #expect(commands(in: seen) == ["Show me the first screen."])
        #expect(bench.recogniser.settleCount == 1)
        bench.route.stop()
    }

    @Test func aNoiseWithNoWordsInItIsNotACommand() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
        bench.audio.play(amplitude: 1)
        #expect(await eventually { bench.recogniser.settleCount == 1 })
        try await Task.sleep(for: .milliseconds(300))
        bench.route.stop()
        let seen = await events(from: stream) { _ in false }
        #expect(commands(in: seen).isEmpty)
    }

    @Test func twoCommandsWithAPauseBetweenAreTwo() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
        #expect(await eventually { bench.recogniser.wasStarted })
        bench.recogniser.hear("zoom out", isFinal: true)
        try await Task.sleep(for: .milliseconds(700))
        bench.recogniser.hear("show me the first screen", isFinal: true)
        let seen = await events(from: stream) { [self] in commands(in: $0).count == 2 }
        #expect(commands(in: seen) == ["zoom out", "show me the first screen"])
        bench.route.stop()
    }

    @Test func theLevelOfTheSoundIsReported() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
        bench.audio.play(amplitude: 1)
        bench.audio.play(amplitude: 0)
        let seen = await events(from: stream) { $0.count >= 4 }
        // Two levels to a buffer, so the waveform moves more often than buffers arrive.
        #expect(Array(seen.prefix(4)) == [.level(1), .level(1), .level(0), .level(0)])
        // The same sound went to the recogniser.
        #expect(await eventually { bench.recogniser.chunksHeard == 2 })
        bench.route.stop()
    }

    @Test func theRecogniserIsToldTheWordsOnTheCanvas() async throws {
        let bench = bench()
        _ = try await bench.route.start(vocabulary: ["Login", "Sign in"])
        #expect(await eventually { bench.recogniser.vocabulary == ["Login", "Sign in"] })
        bench.route.stop()
    }

    @Test func aRefusedMicrophoneIsSaidInWords() async throws {
        let bench = bench()
        bench.audio.startError = DictationRoute.Failure.microphoneRefused
        await #expect(throws: DictationRoute.Failure.microphoneRefused) {
            _ = try await bench.route.start(vocabulary: [])
        }
        #expect(DictationRoute.Failure.microphoneRefused.errorDescription?.contains("microphone") == true)
    }

    /// Where speech can't be recognised there is nothing to listen for, so the
    /// microphone is never turned on.
    @Test func theMicrophoneStaysOffWhereSpeechCannotBeRecognised() async throws {
        let bench = bench()
        bench.recogniser.prepareError = DictationRoute.Failure.speechUnavailable
        await #expect(throws: DictationRoute.Failure.speechUnavailable) {
            _ = try await bench.route.start(vocabulary: [])
        }
        #expect(!bench.audio.wasStarted)
    }

    /// The route hears from the moment the microphone is on, so a recogniser that then
    /// can't start ends the route with its reason, and lets go of the microphone.
    @Test func aRecogniserThatCannotStartLetsGoOfTheMicrophone() async throws {
        let bench = bench()
        bench.recogniser.startError = DictationRoute.Failure.speechUnavailable
        let stream = try await bench.route.start(vocabulary: [])
        let seen = await events(from: stream) { $0.contains { if case .failed = $0 { true } else { false } } }
        #expect(seen.last == .failed(DictationRoute.Failure.speechUnavailable.errorDescription ?? ""))
        #expect(bench.audio.isStopped)
    }

    @Test func aRecogniserThatFailsEndsTheRouteWithItsReason() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
        #expect(await eventually { bench.recogniser.wasStarted })
        bench.recogniser.fail(with: DictationRoute.Failure.speechUnavailable)
        let seen = await events(from: stream) { $0.contains { if case .failed = $0 { true } else { false } } }
        #expect(seen.last == .failed(DictationRoute.Failure.speechUnavailable.errorDescription ?? ""))
    }

    @Test func aMicrophoneThatGoesAwayEndsTheRoute() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
        bench.audio.cutOut()
        let seen = await events(from: stream) { $0.contains { if case .failed = $0 { true } else { false } } }
        #expect(seen.last == .failed("The microphone stopped. Start voice mode again."))
    }

    /// The pencil has no voice mode to start again: its words say to squeeze.
    @Test func aMicrophoneThatGoesAwayDuringASqueezeSaysToSqueezeAgain() async throws {
        let audio = FakeAudioSource()
        let route = DictationRoute(endsOnPause: false, serving: .pencil, source: audio, recogniser: FakeRecogniser())
        let stream = try await route.start(vocabulary: [])
        audio.cutOut()
        let seen = await events(from: stream) { $0.contains { if case .failed = $0 { true } else { false } } }
        #expect(seen.last == .failed("The microphone stopped. Squeeze to try again."))
    }

    @Test func stoppingLetsGoOfEverything() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
        #expect(await eventually { bench.recogniser.wasStarted })
        bench.recogniser.hear("make the", isFinal: false)
        bench.route.stop()
        #expect(bench.audio.isStopped)
        #expect(await eventually { bench.recogniser.isStopped })
        // Hung up, nothing more is reported: not the words half heard, and not a failure.
        let seen = await events(from: stream) { _ in false }
        #expect(commands(in: seen).isEmpty)
        #expect(!seen.contains { if case .failed = $0 { true } else { false } })
    }

    // MARK: Hung up while still getting ready

    /// Getting ready can take a while the first time: what speech needs is fetched. A
    /// call hung up in that time must never go on to turn the microphone on.
    @Test func hangingUpWhileSpeechIsMadeReadyLeavesTheMicrophoneOff() async throws {
        let bench = bench()
        bench.recogniser.holdsPrepare = true
        let starting = Task { try await bench.route.start(vocabulary: []) }
        try await Task.sleep(for: .milliseconds(40))
        bench.route.stop()
        bench.recogniser.holdsPrepare = false
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
        #expect(!bench.audio.wasStarted)
        #expect(!bench.recogniser.wasStarted)
    }

    /// The same while the alert that asks for the microphone is up: once it is answered
    /// the microphone comes on, and has to be let go of again.
    @Test func hangingUpWhileTheMicrophoneIsAskedForTurnsItOffAgain() async throws {
        let bench = bench()
        bench.audio.holdsStart = true
        let starting = Task { try await bench.route.start(vocabulary: []) }
        #expect(await eventually { bench.audio.wasStarted })
        bench.route.stop()
        bench.audio.holdsStart = false
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
        #expect(!bench.audio.isRunning)
        #expect(!bench.recogniser.wasStarted)
    }

    /// And through the call itself, which is what the red button ends.
    @Test func aCallHungUpWhileGettingReadyNeverListens() async throws {
        let bench = bench()
        bench.recogniser.holdsPrepare = true
        let call = VoiceCall(route: bench.route, runner: FakeRunner(), line: PhoneLine())
        let starting = Task { await call.start() }
        #expect(await eventually { call.caption?.text == "Getting ready to listen…" })
        call.end()
        bench.recogniser.holdsPrepare = false
        await starting.value
        #expect(call.phase == .ended)
        #expect(!bench.audio.wasStarted)
        #expect(!bench.audio.isRunning)
    }

    // MARK: - Ending only when told to

    @Test func aPauseDoesNotEndACommandWhenOnlyFinishDoes() {
        var assembler = UtteranceAssembler(endsOnPause: false)
        let t0 = ContinuousClock.now
        assembler.sound(level: 0.5, at: t0)
        assembler.heard("make the header", isFinal: true, at: t0)
        #expect(assembler.next(at: t0 + .seconds(10)) == .wait)
        assembler.finishNow(at: t0 + .seconds(10))
        #expect(assembler.next(at: t0 + .seconds(10)) == .settle)
        assembler.settled(at: t0 + .seconds(10))
        #expect(assembler.next(at: t0 + .milliseconds(10_300)) == .command("make the header"))
    }

    /// Nothing loud and no words yet: the recogniser is still asked, since it may hold
    /// soft speech, and when it has nothing either, nothing heard is said at once.
    @Test func finishWithNothingHeardSaysSo() {
        var assembler = UtteranceAssembler(endsOnPause: false)
        let t0 = ContinuousClock.now
        assembler.finishNow(at: t0)
        #expect(assembler.next(at: t0) == .settle)
        assembler.settled(at: t0 + .milliseconds(100))
        #expect(assembler.next(at: t0 + .milliseconds(400)) == .nothingHeard)
        #expect(assembler.next(at: t0 + .seconds(3)) == .wait)
        // And it isn't held over to end the next command the moment it is heard.
        assembler.sound(level: 0.5, at: t0 + .seconds(4))
        assembler.heard("hello", isFinal: false, at: t0 + .seconds(4))
        #expect(assembler.next(at: t0 + .seconds(5)) == .wait)
    }

    @Test func finishTakesWhatWasHeardEvenIfTheRecogniserNeverSettles() {
        var assembler = UtteranceAssembler(endsOnPause: false)
        let t0 = ContinuousClock.now
        assembler.sound(level: 0.5, at: t0)
        assembler.heard("make the header", isFinal: false, at: t0)
        assembler.finishNow(at: t0 + .seconds(1))
        #expect(assembler.next(at: t0 + .seconds(1)) == .settle)
        #expect(assembler.next(at: t0 + .milliseconds(2000)) == .wait)
        #expect(assembler.next(at: t0 + .milliseconds(2500)) == .command("make the header"))
    }

    @Test func finishWhileAlreadySettlingGivesOneCommand() {
        var assembler = UtteranceAssembler()
        let t0 = ContinuousClock.now
        assembler.sound(level: 0.5, at: t0)
        assembler.heard("make the header", isFinal: true, at: t0)
        #expect(assembler.next(at: t0 + .seconds(3)) == .settle)
        assembler.finishNow(at: t0 + .seconds(3))
        #expect(assembler.next(at: t0 + .seconds(3)) == .wait)
        assembler.settled(at: t0 + .seconds(3))
        #expect(assembler.next(at: t0 + .milliseconds(3300)) == .command("make the header"))
        #expect(assembler.next(at: t0 + .seconds(5)) == .wait)
    }

    @Test func soundAfterFinishDoesNotCallItBack() {
        var assembler = UtteranceAssembler(endsOnPause: false)
        let t0 = ContinuousClock.now
        assembler.sound(level: 0.5, at: t0)
        assembler.heard("make the header", isFinal: true, at: t0)
        assembler.finishNow(at: t0 + .seconds(1))
        #expect(assembler.next(at: t0 + .seconds(1)) == .settle)
        assembler.sound(level: 0.5, at: t0 + .milliseconds(1100))
        assembler.settled(at: t0 + .milliseconds(1200))
        #expect(assembler.next(at: t0 + .milliseconds(1500)) == .command("make the header"))
    }

    @Test func aRouteThatEndsOnlyWhenToldSendsOnFinish() async throws {
        let audio = FakeAudioSource()
        let recogniser = FakeRecogniser()
        let route = DictationRoute(endsOnPause: false, source: audio, recogniser: recogniser)
        let events = try await route.start(vocabulary: [])
        #expect(await eventually { recogniser.wasStarted })
        let received = Received()
        let collecting = Task { @MainActor in
            for await event in events {
                if case .level = event { continue }
                received.events.append(event)
            }
        }
        audio.play(amplitude: 0.5)
        recogniser.hear("make the header", isFinal: true)
        try await Task.sleep(for: .milliseconds(2500))
        #expect(!received.events.contains { if case .command = $0 { true } else { false } })
        route.finish()
        #expect(await eventually { received.events.contains(.command("make the header")) })
        route.stop()
        route.finish()
        collecting.cancel()
    }
    // MARK: - Routes that always end

    /// A hold route: only `finish()` ends a command, and the recogniser is given a tenth
    /// of a second to settle, so a test needn't wait the shipping second and a half.
    private func holdBench() -> Bench {
        let audio = FakeAudioSource()
        let recogniser = FakeRecogniser()
        let assembler = UtteranceAssembler(endsOnPause: false, patience: .milliseconds(100), settling: .milliseconds(50))
        return Bench(route: DictationRoute(source: audio, recogniser: recogniser, assembler: assembler), audio: audio, recogniser: recogniser)
    }

    @Test func aFinishWithNothingHeardSaysSoAtOnce() async throws {
        let bench = holdBench()
        let stream = try await bench.route.start(vocabulary: [])
        let asked = ContinuousClock.now
        bench.route.finish()
        let seen = await events(from: stream) { $0.contains(.nothingHeard) }
        #expect(seen.contains(.nothingHeard))
        // Well before the call would give up on it.
        #expect(ContinuousClock.now - asked < .seconds(1))
        bench.route.stop()
    }

    /// A microphone that throws once its tap is in leaves the hardware half on. The
    /// route is the only one left that can let go of it.
    @Test func aMicrophoneThatFailsToStartIsLetGoOf() async throws {
        let bench = bench()
        bench.audio.startError = DictationRoute.Failure.microphoneUnavailable
        await #expect(throws: DictationRoute.Failure.microphoneUnavailable) {
            _ = try await bench.route.start(vocabulary: [])
        }
        #expect(bench.audio.isStopped)
    }

    /// A recogniser that never finishes settling mustn't hold the command hostage: once
    /// its patience runs out, what was heard is the command.
    @Test func aRecogniserThatNeverSettlesStillGivesTheCommand() async throws {
        let bench = holdBench()
        bench.recogniser.holdsSettle = true
        let stream = try await bench.route.start(vocabulary: [])
        #expect(await eventually { bench.recogniser.wasStarted })
        bench.audio.play(amplitude: 0.5)
        bench.recogniser.hear("make the header", isFinal: false)
        #expect(await eventually { bench.recogniser.chunksHeard == 1 })
        bench.route.finish()
        let seen = await events(from: stream) { [self] in !commands(in: $0).isEmpty }
        #expect(commands(in: seen) == ["make the header"])
        bench.recogniser.holdsSettle = false
        bench.route.stop()
    }

    /// Soft speech, let go of before the recogniser has said a word: the room never got
    /// loud and no words are in. The finish still asks the recogniser for what it has.
    @Test func aFinishBeforeTheFirstWordsArriveStillSendsThem() async throws {
        let bench = holdBench()
        let stream = try await bench.route.start(vocabulary: [])
        bench.recogniser.holdBack("make it red")
        bench.route.finish()
        let seen = await events(from: stream) { [self] in !commands(in: $0).isEmpty }
        #expect(commands(in: seen) == ["make it red"])
        bench.route.stop()
    }

    /// The route can hear once the microphone is on. Loading the recogniser's model
    /// takes a moment more, and the sound waits for it rather than the person.
    @Test func theRouteHearsOnceTheMicrophoneIsOn() async throws {
        let bench = bench()
        bench.recogniser.holdsStart = true
        let returned = Received()
        let starting = Task {
            let stream = try await bench.route.start(vocabulary: ["Login"])
            returned.events.append(.hearing(""))
            return stream
        }
        #expect(await eventually(within: .seconds(1)) { bench.audio.isRunning })
        // Spoken while the recogniser is still getting ready.
        bench.audio.play(amplitude: 0.5)
        let hearsAtOnce = await eventually(within: .milliseconds(500)) { !returned.events.isEmpty }
        let recogniserHadStarted = bench.recogniser.wasStarted
        bench.recogniser.holdsStart = false
        _ = try await starting.value
        #expect(hearsAtOnce)
        #expect(!recogniserHadStarted)
        // Nothing said in the meantime is lost.
        #expect(await eventually { bench.recogniser.chunksHeard == 1 })
        #expect(bench.recogniser.vocabulary == ["Login"])
        bench.route.stop()
    }
    // MARK: - Let go of before the recogniser listens

    /// A route whose recogniser takes a while to start, as its model loading does, with
    /// half a second of patience.
    private func slowRecogniserBench() -> Bench {
        let audio = FakeAudioSource()
        let recogniser = FakeRecogniser()
        recogniser.holdsStart = true
        let assembler = UtteranceAssembler(endsOnPause: false, patience: .milliseconds(500), settling: .milliseconds(50))
        return Bench(route: DictationRoute(source: audio, recogniser: recogniser, assembler: assembler), audio: audio, recogniser: recogniser)
    }

    /// Spoken and let go of while the recogniser was still starting. It starts within
    /// the patience, and the words are the command.
    @Test func aFinishBeforeTheRecogniserListensWaitsForIt() async throws {
        let bench = slowRecogniserBench()
        let stream = try await bench.route.start(vocabulary: [])
        bench.audio.play(amplitude: 0.5)
        bench.recogniser.holdBack("make it red")
        bench.route.finish()
        try await Task.sleep(for: .milliseconds(150))
        bench.recogniser.holdsStart = false
        let seen = await events(from: stream) { [self] in !commands(in: $0).isEmpty || $0.contains(.nothingHeard) }
        #expect(commands(in: seen) == ["make it red"])
        bench.route.stop()
    }

    /// The recogniser never started in time: whatever was said, nothing heard it. That is
    /// said, not passed off as silence.
    @Test func aFinishTheRecogniserNeverListenedForIsSaid() async throws {
        let bench = slowRecogniserBench()
        let stream = try await bench.route.start(vocabulary: [])
        bench.audio.play(amplitude: 0.5)
        bench.route.finish()
        let seen = await events(from: stream) { $0.contains { if case .failed = $0 { true } else { $0 == .nothingHeard } } }
        #expect(!seen.contains(.nothingHeard))
        #expect(seen.contains(.failed(VoiceCall.tooSoon)))
        #expect(bench.audio.isStopped)
        bench.recogniser.holdsStart = false
    }

    // MARK: - Settling has an end

    /// Speech after the release keeps bringing words. They don't keep the command open
    /// past the patience.
    @Test func wordsAfterSettlingDoNotKeepTheCommandOpen() {
        var assembler = UtteranceAssembler(endsOnPause: false)
        let t0 = ContinuousClock.now
        assembler.sound(level: 0.5, at: t0)
        assembler.heard("make it", isFinal: true, at: t0)
        assembler.finishNow(at: t0)
        #expect(assembler.next(at: t0) == .settle)
        assembler.settled(at: t0 + .milliseconds(100))
        var step = UtteranceAssembler.Step.wait
        var moment = 200
        while moment <= 1500, step == .wait {
            assembler.heard("and then some more \(moment)", isFinal: false, at: t0 + .milliseconds(moment))
            step = assembler.next(at: t0 + .milliseconds(moment))
            moment += 100
        }
        #expect(step == .command("make it and then some more 1500"))
    }

    /// A pause began settling, and then the route was told to finish. With nothing heard,
    /// it still says so, as every finish does.
    @Test func finishDuringAPauseSettleStillSaysNothingWasHeard() {
        var assembler = UtteranceAssembler(pause: .milliseconds(200), settling: .milliseconds(50))
        let t0 = ContinuousClock.now
        assembler.sound(level: 0.5, at: t0)
        #expect(assembler.next(at: t0 + .milliseconds(300)) == .settle)
        assembler.finishNow(at: t0 + .milliseconds(310))
        #expect(assembler.next(at: t0 + .milliseconds(320)) == .wait)
        assembler.settled(at: t0 + .milliseconds(330))
        #expect(assembler.next(at: t0 + .milliseconds(400)) == .nothingHeard)
    }
}
