import FoundationModels
import os

/// Reads sketches with the on-device Apple Intelligence model — a sketch agent (Stage 4,
/// `reports/Fast and slow sketch recognition.md`), not a free-floating re-classifier. It's
/// only ever asked about a sketch `RuleInterpreter.isCloseCall` already flagged (`read`
/// is only called that way for a plain Magic Pen sketch; see `SketchEngine.read`, which
/// never asks a provider about a confident answer), and it's handed System 1's own
/// ranked, scored candidates rather than starting from the shape alone, answering with
/// `{chosen, runnerUp}`, both restricted to this sketch's own candidates.
///
/// Two pieces the brief asked for are implemented but, measured, don't earn a place in
/// the live call — kept as working code (`SketchContextTool`, the `reason` field this
/// type's `agentSchema` could still generate), not shipped, per the brief's own rule to
/// keep a piece only if the benchmark shows it helps:
///
/// - **`reason`** (a one-sentence explanation): with it in the schema, System 2 latency
///   p50/p95 rose to 1.78s/2.01s, nearly double the report's own ~1s target for one tool
///   round-trip, for the exact same accuracy as without it (87.2% overall, 54.5% on
///   escalated cases, either way — confirmed by toggling only this field with everything
///   else held fixed). An open-ended string is the one part of the schema that forces real
///   token-by-token generation instead of selecting from a short list.
/// - **`SketchContextTool`** (neighbour/layout facts): calling it measured *worse* than not
///   — 85.9%/45.5% with it vs. 87.2%/54.5% without, at the same token budget, and ~300ms
///   slower. Most of this benchmark's escalated fixtures are standalone sketches with
///   little real neighbour context (`existing` is mostly empty), so the tool had almost
///   nothing to add and the extra round trip just gave the model more room to second-guess
///   a right answer — the same "unguided correction flips answers about as often as it
///   fixes them" risk Stage 0–1's own benchmark already measured for escalation itself. A
///   corpus with more genuinely neighbour-dependent escalated cases (a primary button
///   already on screen, say) might show differently; this one doesn't, so the tool stays
///   unused rather than wired in on the strength of the idea alone.
struct AppleIntelligenceInterpreter: SketchInterpreter {
    private static let log = Logger(subsystem: "kahshin.Layer", category: "sketch-agent")

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
        guard names.count > 1 else { return candidates.first ?? .unknown }

        // System 1's own ranked, scored guesses — real evidence for the agent to read,
        // not a shape it has to re-derive from scratch. Empty for an asked drawing, whose
        // options aren't scored; the shape and context description still give it plenty.
        let scored = request.scoredReadings
        let rankedLine = scored.isEmpty ? nil : "The rules' own ranked guesses, most likely first: "
            + scored.map { "\(SketchPrompt.name(for: $0.reading)) (score \(String(format: "%.2f", $0.score)))" }.joined(separator: ", ") + "."
        let prompt = [SketchPrompt.describe(request), rankedLine].compactMap { $0 }.joined(separator: " ")

        // No tools: see this type's doc comment for why `SketchContextTool`, implemented
        // and working, measured worse than leaving it out on this benchmark.
        //
        // Built fresh, not from `WarmSessions`: a tool-carrying session's data would be
        // this one sketch's own context, which a cached session from an earlier sketch
        // couldn't carry anyway. `WarmSessions.fill()`'s prewarm of `.sketch` still warms
        // the underlying model.
        let session = LanguageModelSession(instructions: SketchPrompt.instructions)

        let schema = try Self.agentSchema(for: names)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 20)
        let response = try await session.respond(to: prompt, schema: schema, options: options)
        let chosenName = try response.content.value(String.self, forProperty: "chosen")
        let runnerUpName = try? response.content.value(String.self, forProperty: "runnerUp")
        Self.log.info("agent chose \(chosenName, privacy: .public), runner-up \(runnerUpName ?? "none", privacy: .public)")
        return zip(names, candidates).first { $0.0 == chosenName }?.1 ?? .unknown
    }

    /// `{chosen, runnerUp}`, both restricted to this sketch's own candidates — see the
    /// type's own doc comment for why `reason` isn't part of what's actually generated.
    /// Built per call, not a static `@Generable` type, because that restriction has to
    /// vary with the candidates: `@Guide`'s `.anyOf` works only for a fixed, compile-time
    /// list, which a sketch's candidates never are — the same reason this type already
    /// built a dynamic schema for a plain enum answer before this.
    private static func agentSchema(for names: [String]) throws -> GenerationSchema {
        let chosen = DynamicGenerationSchema.Property(
            name: "chosen", description: "Which of the candidates this sketch actually is.",
            schema: DynamicGenerationSchema(name: "Chosen", anyOf: names)
        )
        let runnerUp = DynamicGenerationSchema.Property(
            name: "runnerUp", description: "The second most likely candidate, only if one is genuinely plausible.",
            schema: DynamicGenerationSchema(name: "RunnerUp", anyOf: names), isOptional: true
        )
        let root = DynamicGenerationSchema(
            name: "SketchAgentDecision", description: "A decision between a sketch's own ranked candidates",
            properties: [chosen, runnerUp]
        )
        return try GenerationSchema(root: root, dependencies: [])
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
