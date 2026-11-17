import AVFAudio
import Foundation
import Speech

/// Apple's speech recognition, running on the device: nothing that is said leaves it.
///
/// Where the newer recogniser (`SpeechTranscriber`) is to be had it is used. Elsewhere
/// the dictation recogniser is, told to expect short phrases from across a room, since in
/// voice mode the iPad is lying on a desk and being given commands.
actor AppleSpeechRecogniser: PhraseRecogniser {
    /// The recogniser in use, of whichever kind the device has.
    private enum Module {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)
    }

    private let locale: Locale
    private var module: Module?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var work: [Task<Void, Never>] = []

    /// `locale` is the language to listen for; English if it isn't one the device can hear.
    init(locale: Locale = .current) {
        self.locale = locale
    }

    func prepare() async throws {
        let english = Locale(identifier: "en_US")
        if SpeechTranscriber.isAvailable {
            var heard = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            if heard == nil { heard = await SpeechTranscriber.supportedLocale(equivalentTo: english) }
            if let heard {
                let transcriber = SpeechTranscriber(locale: heard, preset: .progressiveTranscription)
                VoiceLog.log.info("speech: SpeechTranscriber for \(heard.identifier, privacy: .public)")
                try await makeReady(transcriber)
                module = .speech(transcriber)
                return
            }
        }
        var heard = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        if heard == nil { heard = await DictationTranscriber.supportedLocale(equivalentTo: english) }
        guard let heard else {
            VoiceLog.log.error("speech: no recogniser for \(self.locale.identifier, privacy: .public) or English")
            throw DictationRoute.Failure.speechUnavailable
        }
        VoiceLog.log.info("speech: DictationTranscriber for \(heard.identifier, privacy: .public)")
        let transcriber = DictationTranscriber(
            locale: heard, contentHints: [.shortForm, .farField], transcriptionOptions: [],
            reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []
        )
        try await makeReady(transcriber)
        module = .dictation(transcriber)
    }

    /// Fetches a recogniser's model if it isn't here yet, which can take a while the
    /// first time, and checks that it can then take sound at all.
    private func makeReady(_ module: some SpeechModule) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            VoiceLog.log.info("speech: fetching what the recogniser needs")
            try await request.downloadAndInstall()
            VoiceLog.log.info("speech: fetched")
        }
        // With no model for it here, a recogniser has no kind of sound it can take.
        guard await !module.availableCompatibleAudioFormats.isEmpty else {
            VoiceLog.log.error("speech: the recogniser takes no kind of sound here")
            throw DictationRoute.Failure.speechUnavailable
        }
    }

    func start(sound: AsyncStream<AudioChunk>, format: AVAudioFormat, vocabulary: [String]) async throws -> AsyncThrowingStream<HeardPhrase, any Error> {
        if module == nil { try await prepare() }
        switch module {
        case .speech(let transcriber):
            return try await listen(with: transcriber, to: sound, vocabulary: vocabulary) { String($0.text.characters) }
        case .dictation(let transcriber):
            return try await listen(with: transcriber, to: sound, vocabulary: vocabulary) { String($0.text.characters) }
        case nil:
            throw DictationRoute.Failure.speechUnavailable
        }
    }

    private func listen<Module: SpeechModule>(
        with module: Module, to sound: AsyncStream<AudioChunk>, vocabulary: [String],
        text: @escaping @Sendable (Module.Result) -> String
    ) async throws -> AsyncThrowingStream<HeardPhrase, any Error> {
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        if !vocabulary.isEmpty {
            // The words on the canvas, which are the ones a command is likely to name.
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        try await analyzer.start(inputSequence: inputs)

        let (phrases, heard) = AsyncThrowingStream<HeardPhrase, any Error>.makeStream()
        work.append(Task {
            do {
                // Whatever the microphone gives is turned into what the recogniser takes.
                let converter = try await AnalyzerInputConverter.converter(compatibleWith: [module])
                for await chunk in sound {
                    for converted in try converter.convert(chunk.buffer, at: nil) {
                        input.yield(converted)
                    }
                }
                input.finish()
            } catch {
                VoiceLog.log.error("speech: sound couldn't be passed on: \(String(reflecting: error), privacy: .public)")
                heard.finish(throwing: error)
            }
        })
        work.append(Task {
            do {
                for try await result in module.results {
                    heard.yield(HeardPhrase(text: text(result), isFinal: result.isFinal))
                }
                heard.finish()
            } catch {
                VoiceLog.log.error("speech: results stopped: \(String(reflecting: error), privacy: .public)")
                heard.finish(throwing: error)
            }
        })
        return phrases
    }

    func settle() async {
        try? await analyzer?.finalize(through: nil)
    }

    func stop() async {
        for task in work { task.cancel() }
        work = []
        input?.finish()
        input = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }
}
