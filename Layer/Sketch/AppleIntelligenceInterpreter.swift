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
    static func warmUp() -> LanguageModelSession {
        let session = LanguageModelSession(instructions: SketchPrompt.instructions)
        session.prewarm()
        return session
    }

    func read(_ request: SketchRequest) async throws -> SketchReading {
        let candidates = request.candidates
        let names = candidates.map(SketchPrompt.name(for:))
        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(name: "Meaning", description: "What the sketch stands for", anyOf: names),
            dependencies: []
        )
        // A fresh session per sketch: readings are independent, and the context stays small.
        let session = LanguageModelSession(instructions: SketchPrompt.instructions)
        let response = try await session.respond(
            to: SketchPrompt.describe(request),
            schema: schema,
            options: GenerationOptions(samplingMode: .greedy)
        )
        let answer = try response.content.value(String.self)
        return zip(names, candidates).first { $0.0 == answer }?.1 ?? .unknown
    }

    func suggestTitle(for board: String) async throws -> String {
        let session = LanguageModelSession(instructions: SketchPrompt.titleInstructions)
        let response = try await session.respond(to: board, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16))
        return response.content
    }
}
