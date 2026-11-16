import FoundationModels

/// Reads sketches with the on-device Apple Intelligence model. The sketch is described in
/// words, and the model's answer is constrained to the sketch's candidates, which keeps
/// each reading short, quick, and always one of the things the shape could be.
struct AppleIntelligenceInterpreter: SketchInterpreter {
    static var readiness: ProviderReadiness {
        switch SystemLanguageModel.default.availability {
        case .available:
            .ready
        case .unavailable(.deviceNotEligible):
            .unavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable("Apple Intelligence is turned off in Settings.")
        case .unavailable(.modelNotReady):
            .unavailable("The Apple Intelligence model is still downloading.")
        case .unavailable:
            .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    /// Whether the only thing missing is the switch in Settings.
    static var isTurnedOff: Bool {
        SystemLanguageModel.default.availability == .unavailable(.appleIntelligenceNotEnabled)
    }

    /// Loads the model ahead of the first sketch. Keep the returned session alive for as
    /// long as the model should stay warm.
    static func warmUp() {
        Task { await WarmSessions.shared.fill() }
    }

    func read(_ request: SketchRequest) async throws -> SketchReading {
        let candidates = request.options
        let names = candidates.map(SketchPrompt.name(for:))
        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(name: "Meaning", description: "What the sketch stands for", anyOf: names),
            dependencies: []
        )
        // A fresh session per sketch: readings are independent, and the context stays small.
        // The first is the one warmed up when the design opened.
        let session = await WarmSessions.shared.take(.sketch)
        let response = try await session.respond(
            to: SketchPrompt.describe(request),
            schema: schema,
            options: GenerationOptions(samplingMode: .greedy)
        )
        let answer = try response.content.value(String.self)
        return zip(names, candidates).first { $0.0 == answer }?.1 ?? .unknown
    }

    func suggestTitle(for board: String) async throws -> String {
        let session = await WarmSessions.shared.take(.title)
        let response = try await session.respond(to: board, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16))
        return response.content
    }
}

/// Sessions loaded ahead of the first request of each kind. Warming one is per session,
/// so the session that was warmed is the one handed out; each is used once, for one
/// independent request, and the next design that opens warms another.
actor WarmSessions {
    enum Kind { case sketch, title }

    static let shared = WarmSessions()
    private var sessions: [Kind: LanguageModelSession] = [:]

    func fill() {
        for kind in [Kind.sketch, .title] where sessions[kind] == nil {
            let session = Self.makeSession(kind)
            session.prewarm()
            sessions[kind] = session
        }
    }

    /// The warmed session of this kind if there is one, or a new one.
    func take(_ kind: Kind) -> LanguageModelSession {
        sessions.removeValue(forKey: kind) ?? Self.makeSession(kind)
    }

    private static func makeSession(_ kind: Kind) -> LanguageModelSession {
        LanguageModelSession(instructions: kind == .sketch ? SketchPrompt.instructions : SketchPrompt.titleInstructions)
    }
}
