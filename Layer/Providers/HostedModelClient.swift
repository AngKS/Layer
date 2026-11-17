import Foundation

/// A conversation as hosted providers take it: an optional system prompt, then turns.
/// Built from a Foundation Models transcript by `HostedModelExecutor`.
struct HostedConversation: Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }

    struct Message: Equatable, Sendable {
        var role: Role
        var text: String
    }

    var system: String?
    var messages: [Message] = []
}

/// What a provider answered.
struct HostedReply: Equatable, Sendable {
    /// The answer's text; for a structured request, its JSON.
    var text: String
    var inputTokens = 0
    var outputTokens = 0
}

/// The two HTTP calls each provider needs: listing its models, and answering a
/// conversation, optionally in a JSON structure. Everything provider-specific about the
/// wire format lives here.
enum HostedModelClient {
    static let anthropicVersion = "2023-06-01"

    // MARK: Listing models

    /// The models this key can use, newest first. Throws `HostedModelError`.
    static func models(for provider: HostedProvider, key: String?) async throws -> [HostedModelInfo] {
        var request = URLRequest(url: provider.baseURL.appending(path: "models").appending(queryItems: provider == .anthropic ? [URLQueryItem(name: "limit", value: "100")] : []))
        authorize(&request, for: provider, key: key)
        request.timeoutInterval = 20
        let json = try await send(request, for: provider)
        guard let data = json["data"] as? [[String: Any]] else { throw HostedModelError.unreadableResponse(provider) }
        switch provider {
        case .anthropic:
            return data.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return HostedModelInfo(id: id, name: (item["display_name"] as? String) ?? id)
            }
        case .openAI:
            return data
                .compactMap { item -> (HostedModelInfo, Double)? in
                    guard let id = item["id"] as? String, isOpenAIChatModel(id) else { return nil }
                    return (HostedModelInfo(id: id, name: id), (item["created"] as? Double) ?? 0)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        case .lmStudio:
            // Every model LM Studio has downloaded, less the ones that only make search vectors.
            return data.compactMap { item in
                guard let id = item["id"] as? String, !id.contains("embed") else { return nil }
                return HostedModelInfo(id: id, name: id)
            }
        }
    }

    /// Adds the provider's own way of passing the key. A self-hosted server without a key gets none.
    static func authorize(_ request: inout URLRequest, for provider: HostedProvider, key: String?) {
        if provider == .anthropic {
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            if let key { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        } else if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    /// OpenAI lists every model it has, including ones for pictures, speech and search
    /// vectors; only the ones that answer chat are of use here.
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let chatFamilies = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
        let otherUses = ["audio", "realtime", "tts", "transcribe", "image", "search", "embedding", "instruct", "dall-e", "whisper", "moderation", "codex"]
        return chatFamilies.contains { id.hasPrefix($0) } && !otherUses.contains { id.contains($0) }
    }

    // MARK: Answering

    /// One piece of a streamed answer.
    enum StreamEvent: Equatable, Sendable {
        /// More of the answer's text; for a structured request, more of its JSON.
        case text(String)
        /// More of what the model thought before answering, for models that say.
        case reasoning(String)
        /// Tokens used so far, as the provider counts them.
        case usage(input: Int, output: Int)
    }

    /// Answers `conversation`, streaming the answer as the provider writes it. With
    /// `schema`, a JSON Schema object, the text adds up to JSON in that structure.
    /// Failures, before or during the answer, are `HostedModelError`.
    static func stream(
        _ conversation: HostedConversation, schema: Data?, maximumTokens: Int?, temperature: Double?,
        provider: HostedProvider, model: String, key: String?
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try streamingRequest(conversation, schema: schema, maximumTokens: maximumTokens, temperature: temperature, provider: provider, model: model, key: key)
                    let lines = try await openStream(request, for: provider)
                    var parser = StreamParser(provider: provider)
                    for try await line in lines {
                        for event in try parser.events(forLine: line) { continuation.yield(event) }
                        if parser.isFinished { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole answer at once, gathered from `stream`.
    static func reply(
        to conversation: HostedConversation, schema: Data?, maximumTokens: Int?, temperature: Double?,
        provider: HostedProvider, model: String, key: String?
    ) async throws -> HostedReply {
        var reply = HostedReply(text: "")
        for try await event in stream(conversation, schema: schema, maximumTokens: maximumTokens, temperature: temperature, provider: provider, model: model, key: key) {
            switch event {
            case .text(let text): reply.text += text
            case .reasoning: break
            case .usage(let input, let output):
                reply.inputTokens = max(reply.inputTokens, input)
                reply.outputTokens = max(reply.outputTokens, output)
            }
        }
        return reply
    }

    static func streamingRequest(
        _ conversation: HostedConversation, schema: Data?, maximumTokens: Int?, temperature: Double?,
        provider: HostedProvider, model: String, key: String?
    ) throws -> URLRequest {
        let schemaObject = try schema.map { try JSONSerialization.jsonObject(with: $0) }
        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .anthropic:
            body = [
                "model": model,
                // Required by Anthropic. Generous by default: the caller's own limit,
                // when it sets one, is what counts.
                "max_tokens": maximumTokens ?? 1024,
                "messages": conversation.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
                "stream": true,
            ]
            if let system = conversation.system, !system.isEmpty { body["system"] = system }
            if let temperature { body["temperature"] = min(max(temperature, 0), 1) }
            // Anthropic has no response format setting; a single tool the model must
            // call, whose input is the structure, is its way of answering in JSON. The
            // tool's input streams as JSON fragments, like text.
            if let schemaObject {
                body["tools"] = [["name": "respond", "description": "Give the answer in this structure.", "input_schema": schemaObject]]
                body["tool_choice"] = ["type": "tool", "name": "respond"]
            }
            request = URLRequest(url: provider.baseURL.appending(path: "messages"))
        case .openAI, .lmStudio:
            var messages: [[String: Any]] = []
            if let system = conversation.system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
            messages += conversation.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
            body = ["model": model, "messages": messages, "stream": true, "stream_options": ["include_usage": true]]
            // Includes any reasoning the model does, so a small limit can leave nothing for the answer.
            if let maximumTokens { body["max_completion_tokens"] = maximumTokens }
            // Temperature isn't sent: OpenAI's reasoning models refuse any but their own.
            if let schemaObject {
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": "response", "schema": schemaObject, "strict": false]]
            }
            request = URLRequest(url: provider.baseURL.appending(path: "chat/completions"))
        }
        authorize(&request, for: provider, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        return request
    }

    /// Reads a provider's server-sent events, one `data:` line at a time.
    struct StreamParser {
        let provider: HostedProvider
        private(set) var isFinished = false
        private var inputTokens = 0

        init(provider: HostedProvider) { self.provider = provider }

        mutating func events(forLine line: String) throws -> [StreamEvent] {
            guard line.hasPrefix("data:") else { return [] }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                isFinished = true
                return []
            }
            guard let data = payload.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [] }

            switch provider {
            case .anthropic:
                switch json["type"] as? String {
                case "message_start":
                    let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any]
                    inputTokens = usage?["input_tokens"] as? Int ?? 0
                    return [.usage(input: inputTokens, output: usage?["output_tokens"] as? Int ?? 0)]
                case "content_block_delta":
                    let delta = json["delta"] as? [String: Any]
                    switch delta?["type"] as? String {
                    case "text_delta": return (delta?["text"] as? String).map { [.text($0)] } ?? []
                    case "thinking_delta": return (delta?["thinking"] as? String).map { [.reasoning($0)] } ?? []
                    case "input_json_delta": return (delta?["partial_json"] as? String).map { [.text($0)] } ?? []
                    default: return []
                    }
                case "message_delta":
                    let usage = json["usage"] as? [String: Any]
                    return [.usage(input: inputTokens, output: usage?["output_tokens"] as? Int ?? 0)]
                case "message_stop":
                    isFinished = true
                    return []
                case "error":
                    let message = (json["error"] as? [String: Any])?["message"] as? String
                    throw HostedModelError.server(provider, status: 0, message: message)
                default:
                    return []
                }
            case .openAI, .lmStudio:
                if let error = json["error"] as? [String: Any] {
                    throw HostedModelError.server(provider, status: 0, message: error["message"] as? String)
                }
                var events: [StreamEvent] = []
                if let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] {
                    if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw HostedModelError.refused(provider, refusal) }
                    // Reasoning models served this way send their thinking first, under one of these names.
                    if let thought = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !thought.isEmpty { events.append(.reasoning(thought)) }
                    if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
                }
                if let usage = json["usage"] as? [String: Any] {
                    events.append(.usage(input: usage["prompt_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0))
                }
                return events
            }
        }
    }

    // MARK: Sending

    /// Starts a streamed request and returns its lines, once the provider has said yes.
    /// A refusal (a bad key, a limit) comes back as an ordinary JSON body, read in full.
    private static func openStream(_ request: URLRequest, for provider: HostedProvider) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError {
            throw failure(error, for: provider)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw failure(status: status, body: body, for: provider)
        }
        return bytes.lines
    }

    /// Sends a request and returns its JSON object, turning failures into `HostedModelError`.
    private static func send(_ request: URLRequest, for provider: HostedProvider) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw failure(error, for: provider)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw failure(status: status, body: data, for: provider) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HostedModelError.unreadableResponse(provider)
        }
        return json
    }

    private static func failure(_ error: URLError, for provider: HostedProvider) -> HostedModelError {
        if provider.isLocal, [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost].contains(error.code) {
            return .serverUnreachable(provider)
        }
        return switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            .offline
        default:
            .server(provider, status: error.errorCode, message: error.localizedDescription)
        }
    }

    private static func failure(status: Int, body: Data, for provider: HostedProvider) -> HostedModelError {
        switch status {
        case 401, 403: return .keyRejected(provider)
        case 429: return .rateLimited(provider)
        default:
            // Both providers put a readable message at error.message.
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            return .server(provider, status: status, message: (json?["error"] as? [String: Any])?["message"] as? String)
        }
    }
}
