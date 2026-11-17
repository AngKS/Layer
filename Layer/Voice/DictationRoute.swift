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

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
        // The recogniser first: where speech can't be recognised there is nothing to
        // listen for, and the microphone stays off.
        try await recogniser.prepare()
        VoiceLog.log.info("route: speech is ready")
        // Each of these waits can be a long one: fetching what speech needs, the alert
        // that asks for the microphone. Hung up in the meantime, the route goes no
        // further, and lets go of whatever it had got as far as turning on.
        guard !isStopped else { throw CancellationError() }
        let sound = try await source.start()
        VoiceLog.log.info("route: microphone on, \(self.source.format.sampleRate, privacy: .public) Hz, \(self.source.format.channelCount, privacy: .public) channel(s)")
        guard !isStopped else {
            source.stop()
            throw CancellationError()
        }
        let (forRecogniser, recogniserInput) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(128))
        let phrases: AsyncThrowingStream<HeardPhrase, any Error>
        do {
            phrases = try await recogniser.start(sound: forRecogniser, format: source.format, vocabulary: vocabulary)
        } catch {
            source.stop()
            throw error
        }
        guard !isStopped else {
            source.stop()
            recogniserInput.finish()
            await recogniser.stop()
            throw CancellationError()
        }
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
                // How loud the room is says when the speaker has stopped.
                await self?.sounded(levels.max() ?? 0)
            }
            recogniserInput.finish()
            await self?.soundEnded()
        })
        tasks.append(Task { [weak self] in
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
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.tick()
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

    private func sounded(_ level: Float) {
        guard !isStopped else { return }
        assembler.sound(level: level, at: .now)
    }

    private func tick() async {
        guard !isStopped else { return }
        switch assembler.next(at: .now) {
        case .wait:
            break
        case .settle:
            await recogniser.settle()
            assembler.settled(at: .now)
        case .command(let command):
            lastHearing = ""
            VoiceLog.log.info("route: a command of \(command.count) characters ended")
            continuation?.yield(.command(command))
        }
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
