import AVFAudio
import Foundation
import Speech

/// Apple's speech recognition, running on the device: nothing that is said leaves it.
///
/// Where the newer recogniser (`SpeechTranscriber`) is to be had it is used. Elsewhere
/// the dictation recogniser is.
actor AppleSpeechRecogniser: PhraseRecogniser {
    /// Which recogniser the device has, and for which language, once its model is here.
    /// Worked out once for the whole app: every squeeze of the Pencil makes a route of its
    /// own, and finding the language and checking the model each time put that wait
    /// ahead of the microphone.
    private enum Prepared: Sendable {
        case speech(Locale)
        case dictation(Locale)
    }

    private static let readiness = PreparedOnce<String, Prepared>()

    private let locale: Locale
    private var prepared: Prepared?
    private var analyzer: SpeechAnalyzer?
    /// Whether `analyzer` has started, and so has anything to settle. It is set before it
    /// starts, and the actor can be asked to settle in between.
    private var isAnalysing = false
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var work: [Task<Void, Never>] = []

    /// `locale` is the language to listen for; English if it isn't one the device can hear.
    init(locale: Locale = .current) {
        self.locale = locale
    }

    func prepare() async throws {
        let locale = locale
        prepared = try await Self.readiness.value(for: locale.identifier) { try await Self.prepare(for: locale) }
    }

    private static func prepare(for locale: Locale) async throws -> Prepared {
        let english = Locale(identifier: "en_US")
        if SpeechTranscriber.isAvailable {
            var heard = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            if heard == nil { heard = await SpeechTranscriber.supportedLocale(equivalentTo: english) }
            if let heard {
                VoiceLog.log.info("speech: SpeechTranscriber for \(heard.identifier, privacy: .public)")
                try await makeReady(speechTranscriber(for: heard))
                return .speech(heard)
            }
        }
        var heard = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        if heard == nil { heard = await DictationTranscriber.supportedLocale(equivalentTo: english) }
        guard let heard else {
            VoiceLog.log.error("speech: no recogniser for \(locale.identifier, privacy: .public) or English")
            throw DictationRoute.Failure.speechUnavailable
        }
        VoiceLog.log.info("speech: DictationTranscriber for \(heard.identifier, privacy: .public)")
        try await makeReady(dictationTranscriber(for: heard))
        return .dictation(heard)
    }

    private static func speechTranscriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// Told to expect short phrases from across a room, since in voice mode the iPad is
    /// lying on a desk and being given commands.
    private static func dictationTranscriber(for locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale, contentHints: [.shortForm, .farField], transcriptionOptions: [],
            reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []
        )
    }

    /// Fetches a recogniser's model if it isn't here yet, which can take a while the
    /// first time, and checks that it can then take sound at all.
    private static func makeReady(_ module: some SpeechModule) async throws {
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

    /// Each utterance has a recogniser and an analyzer of its own, made from what was
    /// prepared. Neither can be used again once its analyzer has finished.
    func start(sound: AsyncStream<AudioChunk>, format: AVAudioFormat, vocabulary: [String]) async throws -> AsyncThrowingStream<HeardPhrase, any Error> {
        if prepared == nil { try await prepare() }
        switch prepared {
        case .speech(let locale):
            return try await listen(with: Self.speechTranscriber(for: locale), to: sound, vocabulary: vocabulary) { String($0.text.characters) }
        case .dictation(let locale):
            return try await listen(with: Self.dictationTranscriber(for: locale), to: sound, vocabulary: vocabulary) { String($0.text.characters) }
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
        // Stopped while it was starting: the analyzer is no longer this one's.
        if self.analyzer === analyzer { isAnalysing = true }

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

    func settle() async -> Bool {
        guard isAnalysing, let analyzer else { return false }
        do {
            try await analyzer.finalize(through: nil)
            return true
        } catch {
            VoiceLog.log.error("speech: couldn't settle: \(String(reflecting: error), privacy: .public)")
            return false
        }
    }

    func stop() async {
        for task in work { task.cancel() }
        work = []
        input?.finish()
        input = nil
        isAnalysing = false
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }
}

/// A value worked out once and kept, for each key: the first to ask works it out, and
/// anyone asking meanwhile waits for the same answer rather than starting again. A
/// failure isn't kept, so the next ask tries again. The work isn't cancelled with whoever
/// asked first: a model being fetched goes on being fetched for the next.
actor PreparedOnce<Key: Hashable & Sendable, Value: Sendable> {
    private var made: [Key: Task<Value, any Error>] = [:]

    func value(for key: Key, making make: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = made[key] ?? Task { try await make() }
        made[key] = task
        do {
            return try await task.value
        } catch {
            if made[key] == task { made[key] = nil }
            throw error
        }
    }
}
