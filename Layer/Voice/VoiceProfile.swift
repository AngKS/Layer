import Foundation
@_weakLinked import FoundationModels

extension SessionPropertyValues {
    /// The canvas as it is now. Written before each command and after each tool, on the
    /// main actor only; read by the instructions, which the framework evaluates afresh
    /// before every request it makes of a model.
    @SessionPropertyEntry var canvasPicture: CanvasPicture = .empty
    /// The model the design uses, which decides the profile in force.
    @SessionPropertyEntry var voiceModel: ModelChoice = .appleIntelligence
}

/// The canvas, put to the model as part of its instructions. Because instructions are
/// evaluated before every request, the model is looking at the canvas as it is, between
/// commands and between the steps of one, and never has to ask what is there.
struct CanvasBrief: DynamicInstructions {
    @SessionProperty(\.canvasPicture) private var picture
    let detail: CanvasPicture.Detail

    var body: some DynamicInstructions {
        Instructions("The canvas now:\n\(picture.text(detail))")
    }
}

/// What the profile tells the call as a command is carried out.
struct VoiceHooks: Sendable {
    /// A tool is about to run; its name.
    var willRun: @Sendable (String) async -> Void
    /// A tool has run, and the canvas may have changed.
    var didRun: @Sendable () async -> Void
    /// Whether tools may still run. False once the command has been stopped.
    var mayRun: @Sendable () async -> Bool
}

/// How a call's session is set up, whichever model the design uses: which model answers,
/// how much it is told, which tools it is handed and how much of the conversation it is
/// sent. The profile in force follows the design's model, so changing the model in the
/// middle of a call takes effect at the next command.
struct VoiceProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.voiceModel) private var choice
    @SessionProperty(\.canvasPicture) private var picture

    private let actor: any VoiceActing
    private let hooks: VoiceHooks
    /// Keeps the tools of one answer to one at a time, in the order they were asked for.
    private let turns: VoiceToolTurns
    /// A stand-in for the design's model, for tests and the simulator.
    private let testModel: (any LanguageModel)?
    /// Whether the model is handed the tool that ends the call: not for the pencil's.
    private let canEndCall: Bool

    init(actor: any VoiceActing, hooks: VoiceHooks, turns: VoiceToolTurns, testModel: (any LanguageModel)? = nil, canEndCall: Bool = true) {
        self.actor = actor
        self.hooks = hooks
        self.turns = turns
        self.testModel = testModel
        self.canEndCall = canEndCall
    }

    var body: some LanguageModelSession.DynamicProfile {
        if let testModel {
            Profile {
                Instructions(VoiceRules.full)
                CanvasBrief(detail: .full)
                VoiceTools.taking(turns, VoiceTools.all(actor, canEndCall: canEndCall))
            }
            .model(testModel)
            .historyTransform { Self.trimmed($0, keepingCommands: 6) }
            .reporting(to: hooks, turns: turns)
        } else if let provider = choice.hostedProvider, let model = choice.model, HostedLanguageModel.isSupported {
            // A hosted model has room for everything: the whole canvas and every tool.
            Profile {
                Instructions(VoiceRules.full)
                CanvasBrief(detail: .full)
                VoiceTools.taking(turns, VoiceTools.all(actor, canEndCall: canEndCall))
            }
            .model(HostedLanguageModel(provider: provider, model: model))
            .historyTransform { Self.trimmed($0, keepingCommands: 6) }
            .reporting(to: hooks, turns: turns)
        } else {
            // The on-device model has little: one screen in full, the tools that make
            // sense for the canvas as it is, and only the last couple of commands.
            Profile {
                Instructions(VoiceRules.compact)
                CanvasBrief(detail: .compact)
                if picture.hasScreens {
                    VoiceTools.taking(turns, VoiceTools.all(actor, canEndCall: canEndCall))
                } else {
                    VoiceTools.taking(turns, VoiceTools.forEmptyCanvas(actor, canEndCall: canEndCall))
                }
            }
            .historyTransform { Self.trimmed($0, keepingCommands: 2) }
            .maximumResponseTokens(200)
            // Always its likeliest answer, so the same words on the same canvas get the
            // same result every time. Measured, it is no less accurate that way.
            // See docs/benchmarks/voice-on-device.md.
            .samplingMode(.greedy)
            .reporting(to: hooks, turns: turns)
        }
    }

    /// The conversation as it is sent to a model: the instructions, and the last `count`
    /// commands whole. The framework hands the instructions over along with the history,
    /// so they are kept here by name; taking only the last few entries would drop them.
    /// A command is kept or dropped as a whole, so a tool call is never parted from its result.
    static func trimmed(_ entries: [Transcript.Entry], keepingCommands count: Int) -> [Transcript.Entry] {
        let prompts = entries.indices.filter { if case .prompt = entries[$0] { true } else { false } }
        guard count > 0, prompts.count > count else { return entries }
        let start = prompts[prompts.count - count]
        let instructions = entries[..<start].filter { if case .instructions = $0 { true } else { false } }
        return instructions + entries[start...]
    }
}

private extension LanguageModelSession.DynamicProfile {
    /// Tells the call what each tool is doing, and refuses tools once it has been stopped.
    /// Each tool waits for its turn first (`VoiceToolTurns`).
    func reporting(to hooks: VoiceHooks, turns: VoiceToolTurns) -> some LanguageModelSession.DynamicProfile {
        onToolCall { call in
            guard await turns.waitForTurn(of: call.id) else { throw CancellationError() }
            guard await hooks.mayRun() else {
                await turns.finished()
                throw CancellationError()
            }
            await hooks.willRun(call.toolName)
        }
        .onToolOutput { _, _ in
            await hooks.didRun()
        }
    }
}

/// Keeps the tools of one answer to one at a time, in the order the model asked for them.
///
/// The on-device model asks for all of a command's tools in one answer, and the session
/// starts those together and in no fixed order (measured with three: their `onToolCall`s
/// ran b, c, a). So "make the title bold and duplicate it" sometimes copied the title
/// before it was bold, "undo that and make it blue" undid its own blue, and a second
/// screen was refused while the first was being written. A hosted model is handed one
/// tool an answer (`HostedModelExecutor`); the on-device model's answers can't be cut
/// short that way, so each tool waits here instead, before it runs, for those asked for
/// ahead of it to have run.
///
/// The order is the answer's own: the session's transcript holds the answer's calls before
/// any of them runs. A call's turn begins in `onToolCall` and ends when its tool returns
/// (`TakingTurns`), as `onToolOutput` comes only once every call of the answer has run.
/// If one call fails, the session cancels the rest, and a call waiting here gives up.
@MainActor
final class VoiceToolTurns {
    /// The conversation whose answers are taken in turn.
    weak var session: LanguageModelSession?
    /// The calls of the answer under way, in the order the model asked for them.
    private var order: [String] = []
    /// How many of them have had their turn.
    private var taken = 0
    private var waiting: [(id: UUID, position: Int, turn: CheckedContinuation<Bool, Never>)] = []

    /// Waits until the calls asked for ahead of `call` have run. False if the command was
    /// stopped while it waited.
    func waitForTurn(of call: String) async -> Bool {
        let position = position(of: call)
        guard position > taken else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { turn in
                if Task.isCancelled {
                    turn.resume(returning: false)
                } else {
                    waiting.append((id, position, turn))
                }
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(id) }
        }
    }

    /// The call whose turn it was has run, or won't: the next one goes.
    func finished() {
        taken += 1
        let due = waiting.filter { $0.position <= taken }
        waiting.removeAll { $0.position <= taken }
        for waiter in due { waiter.turn.resume(returning: true) }
    }

    /// Where `call` comes in its answer.
    private func position(of call: String) -> Int {
        if let position = order.firstIndex(of: call) { return position }
        if let asked = calls(alongside: call) {
            // The first heard from of a new answer. The session runs every call of an
            // answer before it asks for the next, so nothing of the last one should still
            // be waiting; anything that is gives up.
            for waiter in waiting { waiter.turn.resume(returning: false) }
            waiting = []
            order = asked
            taken = 0
        } else {
            // Not in the transcript: it goes after those already heard from.
            order.append(call)
        }
        return order.firstIndex(of: call) ?? order.count - 1
    }

    /// The ids of the calls `call` was asked for with, in the order they were asked for.
    private func calls(alongside call: String) -> [String]? {
        guard let transcript = session?.transcript else { return nil }
        for case .toolCalls(let calls) in transcript.reversed() where calls.contains(where: { $0.id == call }) {
            return calls.map(\.id)
        }
        return nil
    }

    private func giveUp(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(returning: false)
    }
}

/// A tool that ends its turn when it returns, so that the next tool of the answer can go.
///
/// It keeps the tool it stands for as a closure, not as a stored tool: holding the tool
/// itself, the session called `onToolCall` twice for every call (measured).
struct TakingTurns<Arguments: ConvertibleFromGeneratedContent, Output: PromptRepresentable>: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let includesSchemaInInstructions: Bool
    let turns: VoiceToolTurns
    let run: @Sendable (Arguments) async throws -> Output

    init<Inner: Tool>(_ tool: Inner, turns: VoiceToolTurns) where Inner.Arguments == Arguments, Inner.Output == Output {
        name = tool.name
        description = tool.description
        parameters = tool.parameters
        includesSchemaInInstructions = tool.includesSchemaInInstructions
        self.turns = turns
        run = { try await tool.call(arguments: $0) }
    }

    func call(arguments: Arguments) async throws -> Output {
        do {
            let output = try await run(arguments)
            await turns.finished()
            return output
        } catch {
            await turns.finished()
            throw error
        }
    }
}

extension VoiceTools {
    /// `tools`, each taking its turn among the tools of an answer.
    static func taking(_ turns: VoiceToolTurns, _ tools: [any Tool]) -> [any Tool] {
        tools.map { taking(turns, $0) }
    }

    private static func taking(_ turns: VoiceToolTurns, _ tool: some Tool) -> any Tool {
        TakingTurns(tool, turns: turns)
    }
}
