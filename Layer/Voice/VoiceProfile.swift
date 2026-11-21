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
                await turns.failed()
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
/// any of them runs, and an answer is known by its transcript entry, as a model may use a
/// call id again in a later answer. A call's turn begins in `onToolCall` and ends when its
/// tool returns (`TakingTurns`), as `onToolOutput` comes only once every call of the
/// answer has run. A tool that throws ends the answer: the session cancels the rest, and
/// whatever is waiting here gives up.
@MainActor
final class VoiceToolTurns {
    /// The conversation whose answers are taken in turn.
    weak var session: LanguageModelSession?
    /// How long a call waits for a call ahead of it to arrive before it runs anyway. A
    /// session that left out a call without cancelling the rest would otherwise hold the
    /// command for good. A call ahead that has arrived is waited for however long it runs:
    /// a screen can take longer than this to write.
    var patience: Duration = .seconds(10)

    /// The transcript entry of the answer under way.
    private var answer: String?
    /// Its calls, in the order the model asked for them.
    private var order: [String] = []
    /// Which places in `order` a call has arrived for.
    private var arrived: Set<Int> = []
    /// How many of them have had their turn.
    private var taken = 0
    /// Whether a call of the answer threw, or was refused.
    private var hasFailed = false

    private struct Waiter {
        let id: UUID
        let position: Int
        let turn: CheckedContinuation<Bool, Never>
        var timeout: Task<Void, Never>?
    }

    private var waiting: [Waiter] = []

    /// Waits until the calls asked for ahead of `call` have run. False if the command was
    /// stopped, or its answer ended, while it waited.
    func waitForTurn(of call: String) async -> Bool {
        let position = position(of: call)
        guard !hasFailed else { return false }
        guard position > taken else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { turn in
                if Task.isCancelled {
                    turn.resume(returning: false)
                    return
                }
                waiting.append(Waiter(id: id, position: position, turn: turn, timeout: timeout(for: id)))
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(id) }
        }
    }

    /// The call whose turn it was has run: the next one goes.
    func finished() {
        taken += 1
        let due = waiting.filter { $0.position <= taken }
        waiting.removeAll { $0.position <= taken }
        for waiter in due { resume(waiter, goes: true) }
    }

    /// The call whose turn it was threw, or was refused: nothing behind it runs.
    func failed() {
        hasFailed = true
        giveUpEveryone()
    }

    /// Where `call` comes in its answer, which it starts if it is the first heard from.
    private func position(of call: String) -> Int {
        guard let asked = calls(alongside: call) else {
            // Not in the transcript: it goes after those already heard from.
            order.append(call)
            arrived.insert(order.count - 1)
            return order.count - 1
        }
        if asked.entry != answer {
            // A new answer. The session runs every call of an answer before it asks for
            // the next, so nothing of the last one should still be waiting; anything that
            // is gives up.
            giveUpEveryone()
            answer = asked.entry
            order = asked.ids
            arrived = []
            taken = 0
            hasFailed = false
        }
        // An id twice in one answer: each arrival takes the next place it has.
        let places = order.indices.filter { order[$0] == call }
        let position = places.first { !arrived.contains($0) } ?? places.first ?? order.count
        arrived.insert(position)
        return position
    }

    /// The transcript entry `call` was asked for in, and the ids of its calls in order.
    private func calls(alongside call: String) -> (entry: String, ids: [String])? {
        guard let transcript = session?.transcript else { return nil }
        for case .toolCalls(let calls) in transcript.reversed() where calls.contains(where: { $0.id == call }) {
            return (calls.id, calls.map(\.id))
        }
        return nil
    }

    private func timeout(for id: UUID) -> Task<Void, Never> {
        let patience = patience
        return Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: patience)) != nil else { return }
            self?.runAnyway(id)
        }
    }

    /// Runs a waiting call whose turn hasn't come because a call ahead of it never arrived.
    /// While every call ahead has arrived, one of them is still running: it waits on.
    private func runAnyway(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        if (0..<waiting[index].position).allSatisfy(arrived.contains) {
            waiting[index].timeout = timeout(for: id)
            return
        }
        VoiceLog.log.error("turns: a tool waited \(self.patience, privacy: .public) for one ahead of it that never came, and runs anyway")
        resume(waiting.remove(at: index), goes: true)
    }

    private func giveUp(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        resume(waiting.remove(at: index), goes: false)
    }

    private func giveUpEveryone() {
        let given = waiting
        waiting = []
        for waiter in given { resume(waiter, goes: false) }
    }

    private func resume(_ waiter: Waiter, goes: Bool) {
        waiter.timeout?.cancel()
        waiter.turn.resume(returning: goes)
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
            await turns.failed()
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
