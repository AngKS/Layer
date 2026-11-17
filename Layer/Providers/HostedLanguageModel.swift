import Foundation
// Weakly linked: the channel calls an executor makes aren't in every iPadOS 27 release
// (they're missing from the 27.0 simulator), so the app must still launch where they're
// absent. Hosted models are only offered where they are, see `isSupported`.
@_weakLinked import FoundationModels

/// A model hosted by Anthropic or OpenAI, as a Foundation Models `LanguageModel`. It goes
/// wherever the on-device `SystemLanguageModel` does: into a `LanguageModelSession`, with
/// the same instructions, prompts, `respond` and `streamResponse` calls, and the same
/// guided generation from a `GenerationSchema` or a `@Generable` type.
///
///     let session = LanguageModelSession(model: HostedLanguageModel(provider: .anthropic, model: "claude-sonnet-4-5"))
///     for try await partial in session.streamResponse(to: "Name this board") { … }
///
/// The framework does the session's bookkeeping (its transcript, parsing structured
/// answers, partial results while streaming); `HostedModelExecutor` turns each request
/// into the provider's own HTTP call and streams the answer back as it arrives.
struct HostedLanguageModel: LanguageModel {
    typealias Executor = HostedModelExecutor

    /// Whether this system's Foundation Models can run a model of the app's own. Before
    /// iPadOS 27.2 only Apple Intelligence is offered.
    static var isSupported: Bool {
        if #available(iOS 27.2, *) { true } else { false }
    }

    var provider: HostedProvider
    var model: String

    var capabilities: LanguageModelCapabilities {
        // Both providers can answer in a JSON structure. Tools and pictures aren't wired up.
        LanguageModelCapabilities([.guidedGeneration])
    }

    var executorConfiguration: HostedModelExecutor.Configuration {
        HostedModelExecutor.Configuration(provider: provider, model: model)
    }
}

/// Runs requests for a `HostedLanguageModel`: the transcript becomes the provider's
/// messages, a schema becomes its JSON-structured answer, and the answer streams into the
/// framework's channel one fragment at a time.
struct HostedModelExecutor: LanguageModelExecutor {
    typealias Model = HostedLanguageModel

    struct Configuration: Hashable, Sendable {
        var provider: HostedProvider
        var model: String
    }

    let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest, model: HostedLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let key = APIKeyStore.key(for: model.provider)
        if model.provider.requiresKey, key == nil { throw HostedModelError.missingKey(model.provider) }
        let conversation = Self.conversation(from: request.transcript)
        let schema = try request.schema.map(Self.jsonSchema(of:))
        let options = request.generationOptions
        let events = HostedModelClient.stream(
            conversation, schema: schema, maximumTokens: options.maximumResponseTokens, temperature: options.temperature,
            provider: model.provider, model: model.model, key: key
        )
        var usage: (input: Int, output: Int)?
        for try await event in events {
            switch event {
            case .text(let fragment):
                // Providers don't count tokens per fragment; one per fragment is what
                // the framework is told until the real totals arrive with the usage.
                await channel.send(.response(action: .appendText(fragment, tokenCount: 1)))
            case .reasoning(let thought):
                // What a reasoning model thought before answering goes into the
                // transcript as reasoning, apart from the answer.
                await channel.send(.reasoning(action: .appendText(thought, tokenCount: 1)))
            case .usage(let input, let output):
                usage = (input, output)
            }
        }
        if let usage {
            await channel.send(.response(action: .updateUsage(
                input: .init(totalTokenCount: usage.input, cachedTokenCount: 0),
                output: .init(totalTokenCount: usage.output, reasoningTokenCount: 0)
            )))
        }
    }

    /// The transcript as a provider's conversation: instructions become the system
    /// prompt, prompts and responses become turns. Structured segments are sent as their
    /// JSON. Tool calls, reasoning and attachments aren't sent; this model doesn't offer them.
    static func conversation(from transcript: Transcript) -> HostedConversation {
        var conversation = HostedConversation()
        var system: [String] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                system.append(text(of: instructions.segments))
            case .prompt(let prompt):
                conversation.messages.append(.init(role: .user, text: text(of: prompt.segments)))
            case .response(let response):
                conversation.messages.append(.init(role: .assistant, text: text(of: response.segments)))
            case .toolOutput(let output):
                conversation.messages.append(.init(role: .user, text: "\(output.toolName) returned: \(text(of: output.segments))"))
            default:
                continue
            }
        }
        let joined = system.filter { !$0.isEmpty }.joined(separator: "\n\n")
        conversation.system = joined.isEmpty ? nil : joined
        return conversation
    }

    static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: nil
            }
        }
        .joined(separator: "\n")
    }

    /// A `GenerationSchema` as a JSON Schema object, which is how it encodes.
    static func jsonSchema(of schema: GenerationSchema) throws -> Data {
        try JSONEncoder().encode(schema)
    }
}
