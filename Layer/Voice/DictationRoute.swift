import AVFAudio
import Foundation

/// Listens with the iPad's microphone and turns what is said into text on the iPad, so
/// that only words are ever sent to a model. This is the route every provider can use.
///
/// The sound goes two ways: its loudness to the call, for the waveform, and the sound
/// itself to the recogniser. The recogniser's phrases are gathered into commands, a
/// command ending when the speaker pauses.
@MainActor
final class DictationRoute: VoiceRoute {
    enum Failure: LocalizedError, Equatable {
        case microphoneRefused
        case microphoneUnavailable
        case speechUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneRefused:
                "Layer isn't allowed to use the microphone. Allow it in Settings, under Privacy & Security."
            case .microphoneUnavailable:
                "The microphone isn't available right now."
            case .speechUnavailable:
                "Speech recognition isn't available on this device in this language."
            }
        }
    }

    private let source: any VoiceAudioSource
    private let recogniser: any PhraseRecogniser
    private var assembler: UtteranceAssembler
    private var continuation: AsyncStream<VoiceRouteEvent>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var lastHearing = ""
    private var isStopped = false
    /// The recogniser settling, which the ticking doesn't wait on.
    private var settling: Task<Void, Never>?
    /// Which settle this is, so that a late one isn't taken for the next.
    private var settleRound = 0

    /// `assembler` decides where one command ends and the next begins; its own
    /// defaults are the ones for a person speaking to an iPad. With `endsOnPause` false
    /// a command ends only on `finish()`; it applies to the assembler made here, not to
    /// one handed in.
    init(
        endsOnPause: Bool = true,
        source: any VoiceAudioSource = MicrophoneTap(), recogniser: any PhraseRecogniser = AppleSpeechRecogniser(),
        assembler: UtteranceAssembler? = nil
    ) {
        self.source = source
        self.recogniser = recogniser
        self.assembler = assembler ?? UtteranceAssembler(endsOnPause: endsOnPause)
    }

    func prepare() async {
        try? await recogniser.prepare()
    }

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
        let asked = ContinuousClock.now
        // The recogniser first: where speech can't be recognised there is nothing to
        // listen for, and the microphone stays off. It is made ready once for the whole
        // app, so after the first time this is quick.
        try await recogniser.prepare()
        VoiceLog.log.info("route: speech is ready")
        // Each of these waits can be a long one: fetching what speech needs, the alert
        // that asks for the microphone. Hung up in the meantime, the route goes no
        // further, and lets go of whatever it had got as far as turning on.
        guard !isStopped else { throw CancellationError() }
        let sound: AsyncStream<AudioChunk>
        do {
            sound = try await source.start()
        } catch {
            // It may have got part of the way: the session on, the tap in.
            source.stop()
            throw error
        }
        guard !isStopped else {
            source.stop()
            throw CancellationError()
        }
        VoiceLog.log.info("""
            route: microphone on after \(Self.milliseconds(since: asked), privacy: .public) ms, \
            \(self.source.format.sampleRate, privacy: .public) Hz, \(self.source.format.channelCount, privacy: .public) channel(s)
            """)
        let (forRecogniser, recogniserInput) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(128))
        let (events, continuation) = AsyncStream<VoiceRouteEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.continuation = continuation

        // Off the main actor: sound arrives many times a second.
        tasks.append(Task.detached { [weak self] in
            for await chunk in sound {
                let levels = AudioLevel.levels(of: chunk.buffer, count: 2)
                for level in levels {
                    continuation.yield(.level(level))
                }
                recogniserInput.yield(chunk)
                // How loud the room is says when the speaker has stopped. Not waited for:
                // a busy main actor would hold the sound up until the microphone's queue
                // overflowed, and the recogniser lost the oldest of it. The chunk says
                // when it was heard, so arriving late changes nothing.
                let loudest = levels.max() ?? 0, time = chunk.time
                Task { @MainActor [weak self] in self?.sounded(loudest, at: time) }
            }
            recogniserInput.finish()
            await self?.soundEnded()
        })
        // The route hears from the moment the microphone is on. The recogniser's model
        // takes a moment more to load, and the sound waits for it in `forRecogniser`.
        let recogniser = recogniser, format = source.format
        tasks.append(Task { [weak self] in
            let phrases: AsyncThrowingStream<HeardPhrase, any Error>
            do {
                phrases = try await recogniser.start(sound: forRecogniser, format: format, vocabulary: vocabulary)
            } catch {
                recogniserInput.finish()
                // It may have got part of the way, and a stop that came meanwhile could
                // have found nothing yet to stop.
                await recogniser.stop()
                VoiceLog.log.error("route: the recogniser couldn't start: \(String(reflecting: error), privacy: .public)")
                self?.fail(saying: (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
            // Stopped while it was starting: the stop may have reached it before it had
            // anything to stop, so it is told again.
            guard let route = self, !route.isStopped else {
                recogniserInput.finish()
                await recogniser.stop()
                return
            }
            VoiceLog.log.info("route: recogniser listening after \(Self.milliseconds(since: asked), privacy: .public) ms")
            do {
                for try await phrase in phrases {
                    self?.heard(phrase)
                }
            } catch {
                VoiceLog.log.error("route: the recogniser stopped: \(String(reflecting: error), privacy: .public)")
                self?.fail(saying: (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        })
        // The pause that ends a command is measured here, a tenth of a second at a time.
        // A route let go of without being stopped stops ticking too.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.tick()
            }
        })
        return events
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        source.stop()
        for task in tasks { task.cancel() }
        tasks = []
        settling?.cancel()
        settling = nil
        let recogniser = recogniser
        Task { await recogniser.stop() }
        continuation?.finish()
        continuation = nil
    }

    func finish() {
        // Once stopped there is nothing left to end.
        guard !isStopped else { return }
        assembler.finishNow(at: .now)
    }

    private func heard(_ phrase: HeardPhrase) {
        guard !isStopped else { return }
        assembler.heard(phrase.text, isFinal: phrase.isFinal, at: .now)
        let hearing = assembler.hearing
        guard hearing != lastHearing else { return }
        lastHearing = hearing
        continuation?.yield(.hearing(hearing))
    }

    private func sounded(_ level: Float, at time: ContinuousClock.Instant) {
        guard !isStopped else { return }
        assembler.sound(level: level, at: time)
    }

    private func tick() {
        guard !isStopped else { return }
        switch assembler.next(at: .now) {
        case .wait:
            break
        case .settle:
            // Not waited for here. A recogniser slow to settle, or one that never does,
            // would stop the ticking, and with it the assembler's patience, which is what
            // takes the words as they are when settling runs late.
            settleRound += 1
            let round = settleRound, recogniser = recogniser
            settling?.cancel()
            settling = Task { [weak self] in
                await recogniser.settle()
                self?.recogniserSettled(round)
            }
        case .command(let command):
            lastHearing = ""
            VoiceLog.log.info("route: a command of \(command.count) characters ended")
            continuation?.yield(.command(command))
        case .nothingHeard:
            lastHearing = ""
            VoiceLog.log.info("route: finished with nothing heard")
            continuation?.yield(.nothingHeard)
        }
    }

    /// The recogniser has settled. A settle asked for an earlier command, coming back
    /// late, says nothing about this one.
    private func recogniserSettled(_ round: Int) {
        guard !isStopped, round == settleRound else { return }
        assembler.settled(at: .now)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    /// The sound stopped without the route being stopped: an interruption, or the
    /// microphone changing under it.
    private func soundEnded() {
        fail(saying: "The microphone stopped. Start voice mode again.")
    }

    private func fail(saying reason: String) {
        guard !isStopped else { return }
        VoiceLog.log.error("route: failed, \(reason, privacy: .public)")
        continuation?.yield(.failed(reason))
        stop()
    }
}
