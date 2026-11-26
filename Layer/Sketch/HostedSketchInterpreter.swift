@_weakLinked import FoundationModels
import os

/// Reads sketches and names boards with a hosted model, through the same Foundation
/// Models session API, prompt and answer structure as `AppleIntelligenceInterpreter`:
/// only the model passed to the session differs. See that type for what the model is
/// asked and why.
struct HostedSketchInterpreter: SketchInterpreter {
    private static let log = Logger(subsystem: "kahshin.Layer", category: "sketch-agent")

    let model: HostedLanguageModel

    /// What each request asks for: temperature 0, but nothing from LM Studio, which samples at its model's own. LM
    /// Studio was sent no temperature until 2026-11-26, and at 0 its gemma-4 chose the same wrong reading of one close
    /// call five times out of five, where it was right four times in five at its own (docs/benchmarks/screen-prompt.md).
    private var options: GenerationOptions {
        GenerationOptions(temperature: model.provider == .lmStudio ? nil : 0)
    }

    /// `{chosen, runnerUp}`, restricted to the sketch's own candidates.
    static func decisionSchema(for names: [String]) throws -> GenerationSchema {
        try AppleIntelligenceInterpreter.agentSchema(for: names)
    }

    func read(_ request: SketchRequest) async throws -> SketchReading {
        try await decide(request).chosen
    }

    func decide(_ request: SketchRequest) async throws -> SketchDecision {
        let candidates = request.options
        let names = candidates.map(SketchPrompt.name(for:))
        guard names.count > 1 else { return SketchDecision(chosen: candidates.first ?? .unknown) }

        let scored = request.scoredReadings
        let rankedLine = scored.isEmpty ? nil : "The rules' own ranked guesses, most likely first: "
            + scored.map { "\(SketchPrompt.name(for: $0.reading)) (score \(String(format: "%.2f", $0.score)))" }.joined(separator: ", ") + "."
        let prompt = [SketchPrompt.describe(request), rankedLine].compactMap { $0 }.joined(separator: " ")

        let session = LanguageModelSession(model: model, instructions: SketchPrompt.instructions)
        // No token limit: unlike the on-device model's, a hosted model's limit can include
        // its own reasoning, and a tight one can leave nothing for the answer.
        let response = try await session.respond(to: prompt, schema: try Self.decisionSchema(for: names), options: options)
        let chosenName = try response.content.value(String.self, forProperty: "chosen")
        let runnerUpName = try? response.content.value(String.self, forProperty: "runnerUp")
        Self.log.info("\(model.provider.rawValue, privacy: .public) \(model.model, privacy: .public) chose \(chosenName, privacy: .public)")
        return SketchDecision(named: chosenName, runnerUp: runnerUpName, names: names, candidates: candidates)
    }

    func suggestTitle(for board: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: SketchPrompt.titleInstructions)
        // Streamed, so a name starts arriving as soon as the provider starts writing it.
        var title = ""
        for try await partial in session.streamResponse(to: board, options: options) {
            title = partial.content
        }
        return title
    }
}
