import AVFoundation
import os

/// One route's use of the microphone, as a stream of sound, from `start()` to `stop()`.
/// The microphone itself is shared: see `Microphone`.
@MainActor
final class MicrophoneTap: VoiceAudioSource {
    private let microphone: Microphone
    private let askForAccess: @Sendable () async -> Bool
    /// Read in `deinit` as well, which belongs to no actor; a `UUID` is safe to read there.
    nonisolated(unsafe) private var listener: Microphone.Listener?
    /// Whether `stop()` came while `start()` was still under way.
    private var stoppedWhileStarting = false
    private(set) var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// `askForAccess` is for tests, which have no one to answer the alert.
    init(microphone: Microphone = .shared, askForAccess: @escaping @Sendable () async -> Bool = MicrophoneTap.requestAccess) {
        self.microphone = microphone
        self.askForAccess = askForAccess
    }

    /// A route let go of without being stopped mustn't keep the microphone on for everyone.
    deinit {
        if let listener { microphone.stopListening(listener) }
    }

    /// Asks to use the microphone, the first time, and says whether it may be used. Once
    /// allowed, there is nothing to ask, and no wait on every squeeze for the answer.
    @Sendable static func requestAccess() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Starts the microphone, asking to use it the first time.
    func start() async throws -> AsyncStream<AudioChunk> {
        stoppedWhileStarting = false
        guard await askForAccess() else { throw DictationRoute.Failure.microphoneRefused }
        // Let go of while the alert was up: the microphone mustn't come on even for a moment.
        guard !stoppedWhileStarting else { throw CancellationError() }
        let (listener, sound, format) = try await microphone.listen()
        guard !stoppedWhileStarting else {
            microphone.stopListening(listener)
            throw CancellationError()
        }
        self.listener = listener
        self.format = format
        return sound
    }

    func stop() {
        stoppedWhileStarting = true
        guard let listener else { return }
        self.listener = nil
        microphone.stopListening(listener)
    }
}

/// What the microphone needs of the hardware. The iPad's is `AudioEngineHardware`; tests
/// stand one in that hands over what they say.
///
/// Called only on the microphone's own queue, one call at a time.
protocol MicrophoneHardware: AnyObject, Sendable {
    /// Turns the microphone on: the audio session, the engine and its tap. Sound goes to
    /// `hearing`, on whatever thread brings it. `lost` is called if the microphone goes
    /// away under it. Throws having undone whatever it got as far as doing.
    func start(hearing: @escaping @Sendable (AudioChunk) -> Void, lost: @escaping @Sendable () -> Void) throws -> AVAudioFormat
    /// Turns it off and lets go of the audio session.
    func stop()
}

/// The iPad's one microphone, shared by every route that is listening.
///
/// Routes overlap. A squeeze's route is still settling its command when the next squeeze
/// opens another, and a phone call can be up at the same time. When each route turned the
/// hardware on and off for itself, the first to finish switched the audio session off
/// under the others, which then heard nothing, and two engines tapped the one input. Here
/// there is one engine and one tap, the sound is handed to every route listening, and the
/// audio session is let go of only when the last of them stops.
///
/// Turning the hardware on and off blocks for a moment, so it happens on a queue of the
/// microphone's own, never on the main actor, where the Pencil is drawing.
final class Microphone: @unchecked Sendable {
    typealias Listener = UUID

    static let shared = Microphone(hardware: AudioEngineHardware())

    private let hardware: any MicrophoneHardware
    private let queue = DispatchQueue(label: "Layer.Microphone", qos: .userInitiated)
    private let listeners = OSAllocatedUnfairLock<[Listener: AsyncStream<AudioChunk>.Continuation]>(initialState: [:])
    /// The format the hardware is giving sound in, while it is on. Touched only on `queue`,
    /// as is `generation`, which is what makes the class safe to share.
    private var format: AVAudioFormat?
    /// Which turning on this is. The microphone going away is told with the generation it
    /// went away in, so that news of one that is long off can't turn off the next.
    private var generation = 0

    init(hardware: any MicrophoneHardware) {
        self.hardware = hardware
    }

    /// Starts hearing the microphone, turning it on if no one else has. The stream ends when
    /// `stopListening` is called, or when the microphone goes away.
    func listen() async throws -> (listener: Listener, sound: AsyncStream<AudioChunk>, format: AVAudioFormat) {
        let listener = Listener()
        // If the listener falls behind, the oldest sound is what it can best do without.
        let (sound, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        // Counted before the hardware is asked for, so that a route stopping meanwhile
        // can't turn it off under this one.
        listeners.withLock { $0[listener] = continuation }
        do {
            let format: AVAudioFormat = try await withCheckedThrowingContinuation { done in
                queue.async { done.resume(with: Result { try self.turnOn() }) }
            }
            return (listener, sound, format)
        } catch {
            stopListening(listener)
            throw error
        }
    }

    /// Stops hearing the microphone, and turns it off if no one else is listening.
    func stopListening(_ listener: Listener) {
        let continuation = listeners.withLock { $0.removeValue(forKey: listener) }
        continuation?.finish()
        queue.async { self.turnOffIfUnheard() }
    }

    /// Whether anyone is listening. For tests.
    var listenerCount: Int { listeners.withLock { $0.count } }

    // MARK: On the queue

    private func turnOn() throws -> AVAudioFormat {
        if let format { return format }
        // Everyone who asked has gone already.
        guard listenerCount > 0 else { throw CancellationError() }
        generation += 1
        let generation = generation
        let format = try hardware.start(hearing: Self.handOut(to: listeners), lost: { [weak self] in
            guard let self else { return }
            self.queue.async { self.lost(in: generation) }
        })
        VoiceLog.log.info("microphone: on")
        self.format = format
        return format
    }

    private func turnOffIfUnheard() {
        guard format != nil, listenerCount == 0 else { return }
        hardware.stop()
        format = nil
        VoiceLog.log.info("microphone: off")
    }

    /// The microphone went away: everyone listening hears the sound end, which is how a
    /// route learns of it.
    private func lost(in generation: Int) {
        guard format != nil, generation == self.generation else { return }
        hardware.stop()
        format = nil
        let all = listeners.withLock { listeners in
            defer { listeners = [:] }
            return listeners
        }
        for continuation in all.values { continuation.finish() }
    }

    /// Hands each chunk to everyone listening. The engine calls this on a thread of its
    /// own, so it must belong to no actor: `nonisolated`, and `@Sendable`.
    nonisolated private static func handOut(
        to listeners: OSAllocatedUnfairLock<[Listener: AsyncStream<AudioChunk>.Continuation]>
    ) -> @Sendable (AudioChunk) -> Void {
        { @Sendable chunk in
            for continuation in listeners.withLock({ Array($0.values) }) {
                continuation.yield(chunk)
            }
        }
    }
}

/// The iPad's microphone: the audio session, an `AVAudioEngine` and a tap on its input.
/// Used only on `Microphone`'s queue, one call at a time, which is what makes it safe to share.
final class AudioEngineHardware: MicrophoneHardware, @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var watching: [any NSObjectProtocol] = []

    func start(hearing: @escaping @Sendable (AudioChunk) -> Void, lost: @escaping @Sendable () -> Void) throws -> AVAudioFormat {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        do {
            // With nothing to record from there is nothing to hear.
            guard session.isInputAvailable, session.availableInputs?.isEmpty == false else {
                throw DictationRoute.Failure.microphoneUnavailable
            }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationRoute.Failure.microphoneUnavailable }
            // A tenth of a second at a time, which is the shortest the engine hands over.
            // The underscored name is the one iOS 27's SDK gives the call that reports a
            // failure; the plain one is deprecated and has no Swift name of its own yet.
            // Its error parameter sits before the block, so Swift keeps an empty place for it.
            try input.__installTap(
                onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format, error: (), block: Self.tapBlock(handingTo: hearing)
            )
            do {
                engine.prepare()
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
            self.engine = engine
            watch(engine, lost: lost)
            return format
        } catch {
            // Left on, the session would keep other apps' sound stopped.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        for watch in watching { NotificationCenter.default.removeObserver(watch) }
        watching = []
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The block the engine hands its sound to. The engine calls it on a thread of its
    /// own, so it must belong to no actor, which is why this is `nonisolated` and the
    /// block `@Sendable`. Written in place inside a main-actor class, as it first was,
    /// the block is taken for the main actor's, and Swift stops the app the moment the
    /// first sound arrives on the engine's thread. Only a real microphone shows it.
    nonisolated static func tapBlock(handingTo hearing: @escaping @Sendable (AudioChunk) -> Void) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in hearing(AudioChunk(buffer: buffer, time: .now)) }
    }

    /// What an interruption notification says when the interruption began: `AVAudioSession.InterruptionType.began`.
    /// iOS 27 deprecates that type with the notification, for `didBecomeInactiveNotification`; the notification is
    /// kept, as it is what has been tried on a device, and the type isn't named.
    private static let interruptionBegan: UInt = 1

    /// A phone call, Siri, or the microphone changing under the engine (headphones going
    /// on or off) stops the sound.
    private func watch(_ engine: AVAudioEngine, lost: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        watching = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == Self.interruptionBegan
                guard began else { return }
                VoiceLog.log.info("microphone: interrupted")
                lost()
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                VoiceLog.log.info("microphone: the audio route changed")
                lost()
            },
        ]
    }
}
