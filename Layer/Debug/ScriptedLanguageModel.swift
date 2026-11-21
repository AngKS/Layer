#if DEBUG
import Foundation
@_weakLinked import FoundationModels
import os

/// A model that does as it was told beforehand: for each command, the tools scripted for
/// it, one per turn unless they are asked for together, and then a closing word. It goes
/// wherever a real model does, so a whole voice command can be run, tools and all, with no
/// model and no network: in tests, and in the simulator, where Apple Intelligence can't answer.
struct ScriptedLanguageModel: LanguageModel {
    typealias Executor = ScriptedModelExecutor

    /// One tool for the model to ask for.
    struct Step: Hashable, Sendable {
        var tool: String
        /// Its arguments, as JSON.
        var arguments: String
        /// How long the model takes to get round to it.
        var delay: Duration?
        /// Whether the step after this one is asked for in the same answer, as the
        /// on-device model asks for all of a command's tools at once.
        var withNext = false
        /// The call's id, for a test that needs it to be one an earlier call had. Nil for
        /// one of its own.
        var id: String?

        /// Steps the model asks for together, in one answer, in this order.
        static func together(_ steps: [Step]) -> [Step] {
            steps.enumerated().map { index, step in
                var step = step
                step.withNext = index < steps.count - 1
                return step
            }
        }
    }

    /// What to do for each command. Commands are matched in lower case.
    var script: [String: [Step]]
    /// What the model says once a command's steps are done, or when it has none.
    var closing = "Done."
    /// Where to note what the model was sent.
    var recorder: ScriptRecorder?

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling])
    }

    var executorConfiguration: ScriptedModelExecutor.Configuration {
        ScriptedModelExecutor.Configuration(script: script, closing: closing, recorder: recorder)
    }
}

/// What a scripted model was sent on each request, for a test to look at afterwards.
final class ScriptRecorder: Hashable, Sendable {
    struct Request: Sendable {
        /// The instructions in force for this request.
        var instructions: String
        /// Every command in the conversation so far, the latest last.
        var prompts: [String]
        /// The names of the tools on offer.
        var tools: [String]
    }

    private let state = OSAllocatedUnfairLock(initialState: [Request]())

    var requests: [Request] { state.withLock { $0 } }

    func record(_ request: Request) {
        state.withLock { $0.append(request) }
    }

    static func == (lhs: ScriptRecorder, rhs: ScriptRecorder) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct ScriptedModelExecutor: LanguageModelExecutor {
    typealias Model = ScriptedLanguageModel

    struct Configuration: Hashable, Sendable {
        var script: [String: [ScriptedLanguageModel.Step]]
        var closing: String
        var recorder: ScriptRecorder?
    }

    let configuration: Configuration

    /// How many calls scripted models have asked for, so that each has an id of its own.
    private static let callsAskedFor = OSAllocatedUnfairLock(initialState: 0)

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest, model: ScriptedLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        var instructions: [String] = []
        var prompts: [String] = []
        // How far through the latest command's script the conversation has got.
        var stepsTaken = 0
        for entry in request.transcript {
            switch entry {
            case .instructions(let entry):
                instructions.append(HostedModelExecutor.text(of: entry.segments))
            case .prompt(let prompt):
                prompts.append(HostedModelExecutor.text(of: prompt.segments))
                stepsTaken = 0
            case .toolCalls(let calls):
                stepsTaken += calls.count
            default:
                continue
            }
        }
        configuration.recorder?.record(ScriptRecorder.Request(
            instructions: instructions.joined(separator: "\n\n"), prompts: prompts,
            tools: request.enabledToolDefinitions.map(\.name)
        ))

        let command = (prompts.last ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = configuration.script[command] ?? []
        guard stepsTaken < steps.count else {
            await channel.send(.response(action: .appendText(configuration.closing, tokenCount: 1)))
            return
        }
        // This step, and those asked for along with it.
        var answer = stepsTaken
        while steps[answer].withNext, answer + 1 < steps.count { answer += 1 }
        for index in stepsTaken...answer {
            let step = steps[index]
            if let delay = step.delay { try await Task.sleep(for: delay) }
            let number = Self.callsAskedFor.withLock { count in
                count += 1
                return count
            }
            await channel.send(.toolCalls(action: .toolCall(
                id: step.id ?? "call-\(number)", name: step.tool,
                action: .appendArguments(step.arguments, tokenCount: 1)
            )))
        }
    }
}
#endif
