import AVFoundation

/// The microphone, as a stream of sound, for as long as a call is up.
@MainActor
final class MicrophoneTap: VoiceAudioSource {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var watching: [any NSObjectProtocol] = []

    /// Asks to use the microphone, the first time, and says whether it may be used.
    static func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    var format: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// Starts the microphone, asking to use it the first time.
    func start() async throws -> AsyncStream<AudioChunk> {
        guard await Self.requestAccess() else { throw DictationRoute.Failure.microphoneRefused }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        // With nothing to record from there is no call to be had.
        guard session.isInputAvailable, session.availableInputs?.isEmpty == false else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw DictationRoute.Failure.microphoneUnavailable
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationRoute.Failure.microphoneUnavailable }
        // If the listener falls behind, the oldest sound is what it can best do without.
        let (sound, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        // A tenth of a second at a time, which is the shortest the engine hands over.
        // The underscored name is the one iOS 27's SDK gives the call that reports a
        // failure; the plain one is deprecated and has no Swift name of its own yet.
        // Its error parameter sits before the block, so Swift keeps an empty place for it.
        try input.__installTap(
            onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format, error: (), block: Self.tapBlock(into: continuation)
        )
        engine.prepare()
        try engine.start()
        watchForLosingTheMicrophone()
        return sound
    }

    /// The block the engine hands its sound to. The engine calls it on a thread of its
    /// own, so it must belong to no actor, which is why this is `nonisolated` and the
    /// block `@Sendable`. Written in place in `start()`, as it first was, the block is
    /// taken for the main actor's, and Swift stops the app the moment the first sound
    /// arrives on the engine's thread. Only a real microphone shows it.
    nonisolated static func tapBlock(into continuation: AsyncStream<AudioChunk>.Continuation) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in continuation.yield(AudioChunk(buffer: buffer)) }
    }

    func stop() {
        guard let continuation else { return }
        for watch in watching { NotificationCenter.default.removeObserver(watch) }
        watching = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
        self.continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A phone call, Siri, or the microphone changing under the engine (headphones going
    /// on or off) stops the sound. The stream then ends, which is how the call hears of it.
    private func watchForLosingTheMicrophone() {
        let center = NotificationCenter.default
        watching = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                if began {
                    VoiceLog.log.info("microphone: interrupted")
                    MainActor.assumeIsolated { self?.stop() }
                }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                VoiceLog.log.info("microphone: the audio route changed")
                MainActor.assumeIsolated { self?.stop() }
            },
        ]
    }
}
