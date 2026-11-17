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
    private var started = false

    /// While set, getting ready waits, as it does while what speech needs is fetched.
    var holdsPrepare: Bool {
        get { state.withLock { holding } }
        set { state.withLock { holding = newValue } }
    }

    /// Whether it was ever asked to listen.
    var wasStarted: Bool { state.withLock { started } }

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
        if let startError { throw startError }
        let (phrases, continuation) = AsyncThrowingStream<HeardPhrase, any Error>.makeStream()
        state.withLock {
            self.continuation = continuation
            told = vocabulary
            started = true
        }
        Task {
            for await _ in sound { self.state.withLock { self.chunks += 1 } }
        }
        return phrases
    }

    func settle() async {
        let (continuation, phrases) = state.withLock {
            settles += 1
            defer { heldBack = [] }
            return (self.continuation, heldBack)
        }
        for phrase in phrases { continuation?.yield(phrase) }
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

@Suite("Hearing commands through the microphone", .serialized)
@MainActor
struct DictationRouteTests {
    private struct Bench {
        let route: DictationRoute
        let audio: FakeAudioSource
        let recogniser: FakeRecogniser
    }

    /// A route in a hurry: a fifth of a second of quiet ends a command, or three tenths
    /// without new words where there is no sound to go by.
    private func bench() -> Bench {
        let audio = FakeAudioSource()
        let recogniser = FakeRecogniser()
        let assembler = UtteranceAssembler(
            pause: .milliseconds(200), staleness: .milliseconds(300), patience: .milliseconds(400), settling: .milliseconds(50)
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

    private nonisolated func commands(in events: [VoiceRouteEvent]) -> [String] {
        events.compactMap { if case .command(let text) = $0 { text } else { nil } }
    }

    @Test func wordsBecomeACommandAfterAPause() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
        bench.recogniser.hear("make the button", isFinal: false)
        bench.recogniser.hear("Make the button blue", isFinal: true)
        let seen = await events(from: stream) { [self] in !commands(in: $0).isEmpty }
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
        #expect(bench.recogniser.vocabulary == ["Login", "Sign in"])
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

    @Test func aRecogniserThatCannotStartLetsGoOfTheMicrophone() async throws {
        let bench = bench()
        bench.recogniser.startError = DictationRoute.Failure.speechUnavailable
        await #expect(throws: DictationRoute.Failure.speechUnavailable) {
            _ = try await bench.route.start(vocabulary: [])
        }
        #expect(bench.audio.isStopped)
    }

    @Test func aRecogniserThatFailsEndsTheRouteWithItsReason() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
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

    @Test func stoppingLetsGoOfEverything() async throws {
        let bench = bench()
        let stream = try await bench.route.start(vocabulary: [])
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
        let call = VoiceCall(route: bench.route, runner: FakeRunner())
        let starting = Task { await call.start() }
        #expect(await eventually { call.caption?.text == "Getting ready to listen…" })
        call.end()
        bench.recogniser.holdsPrepare = false
        await starting.value
        #expect(call.phase == .ended)
        #expect(!bench.audio.wasStarted)
        #expect(!bench.audio.isRunning)
    }
}
