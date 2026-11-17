import Foundation
@_weakLinked import FoundationModels
import os
import Testing
@testable import Layer

/// Answers the app's HTTPS requests from canned provider responses, and remembers what
/// was asked, so hosted models can be tested without a network or a real key.
final class StubProvider: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var body: String
        var contentType = "text/event-stream"
    }

    private static let state = OSAllocatedUnfairLock<(replies: [Reply], requests: [(url: URL, headers: [String: String], body: Data)])>(initialState: ([], []))

    static func answer(with reply: Reply) {
        state.withLock { $0 = ([reply], []) }
    }

    /// Answers requests in turn, one reply each; the last goes on answering any after it.
    static func answer(with replies: [Reply]) {
        state.withLock { $0 = (replies, []) }
    }

    /// Requests fail as they do with no network.
    static func failNextRequests() {
        state.withLock { $0 = ([], []) }
    }

    static var requests: [(url: URL, headers: [String: String], body: Data)] { state.withLock { $0.requests } }

    static var lastBody: [String: Any] {
        guard let body = requests.last?.body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        // LM Studio's own machine too, where its server is looked for when no address is set.
        return host == "api.anthropic.com" || host == "api.openai.com" || host == "localhost"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let record = (url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let reply = Self.state.withLock { state -> Reply? in
            state.requests.append(record)
            return state.replies.count > 1 ? state.replies.removeFirst() : state.replies.first
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, the way a stream arrives.
        for line in reply.body.split(separator: "\n", omittingEmptySubsequences: false) {
            client?.urlProtocol(self, didLoad: Data((line + "\n").utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Server-sent events, as each provider writes them.
enum SSE {
    static func anthropic(text pieces: [String], toolJSON: Bool = false) -> String {
        var lines = [
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":42,"output_tokens":1}}}"#,
            #"data: {"type":"content_block_start","index":0}"#,
        ]
        for piece in pieces {
            let escaped = String(data: try! JSONSerialization.data(withJSONObject: [piece], options: .fragmentsAllowed), encoding: .utf8)!.dropFirst().dropLast()
            lines.append(toolJSON
                ? #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\#(escaped)}}"#
                : #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(escaped)}}"#)
        }
        lines += [
            #"data: {"type":"message_delta","usage":{"output_tokens":7}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        return lines.map { "event: x\n\($0)\n" }.joined(separator: "\n")
    }

    static func openAI(text pieces: [String], thinking: [String] = []) -> String {
        var lines: [String] = []
        for thought in thinking {
            let escaped = String(data: try! JSONSerialization.data(withJSONObject: [thought], options: .fragmentsAllowed), encoding: .utf8)!.dropFirst().dropLast()
            lines.append(#"data: {"choices":[{"delta":{"reasoning_content":\#(escaped)}}]}"#)
        }
        for piece in pieces {
            let escaped = String(data: try! JSONSerialization.data(withJSONObject: [piece], options: .fragmentsAllowed), encoding: .utf8)!.dropFirst().dropLast()
            lines.append(#"data: {"choices":[{"delta":{"content":\#(escaped)}}]}"#)
        }
        lines.append(#"data: {"choices":[],"usage":{"prompt_tokens":30,"completion_tokens":5}}"#)
        lines.append("data: [DONE]")
        return lines.joined(separator: "\n\n")
    }
}

@Suite("Hosted models through Foundation Models", .serialized)
final class HostedModelTests {
    init() throws {
        URLProtocol.registerClass(StubProvider.self)
        try APIKeyStore.setKey("test-key-anthropic", for: .anthropic)
        try APIKeyStore.setKey("test-key-openai", for: .openAI)
    }

    // The tests run inside the app, so their keys would otherwise stay in its Keychain.
    deinit {
        try? APIKeyStore.removeKey(for: .anthropic)
        try? APIKeyStore.removeKey(for: .openAI)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func anAnthropicModelAnswersAPlainPromptThroughASession() async throws {
        StubProvider.answer(with: .init(body: SSE.anthropic(text: ["Travel ", "Planner"])))
        let session = LanguageModelSession(model: HostedLanguageModel(provider: .anthropic, model: "claude-test"), instructions: "Name boards.")
        let response = try await session.respond(to: "A board with a map")
        #expect(response.content == "Travel Planner")

        let sent = try #require(StubProvider.requests.last)
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.headers["x-api-key"] == "test-key-anthropic")
        #expect(sent.headers["anthropic-version"] == HostedModelClient.anthropicVersion)
        let body = StubProvider.lastBody
        #expect(body["model"] as? String == "claude-test")
        #expect(body["stream"] as? Bool == true)
        #expect(body["system"] as? String == "Name boards.")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        #expect((messages.first?["content"] as? String)?.contains("A board with a map") == true)
        // The session's transcript records the exchange, as it does for the on-device model.
        #expect(session.transcript.count == 3)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func streamingDeliversTheAnswerPieceByPiece() async throws {
        StubProvider.answer(with: .init(body: SSE.openAI(text: ["One", " two", " three"])))
        let session = LanguageModelSession(model: HostedLanguageModel(provider: .openAI, model: "gpt-test"))
        var snapshots: [String] = []
        for try await snapshot in session.streamResponse(to: "Count") {
            snapshots.append(snapshot.content)
        }
        #expect(snapshots.last == "One two three")
        #expect(snapshots.count >= 2, "partial answers should arrive before the whole one: \(snapshots)")
        let body = StubProvider.lastBody
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(StubProvider.requests.last?.headers["Authorization"] == "Bearer test-key-openai")
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"), arguments: [HostedProvider.anthropic, .openAI])
    func aSchemaGivesAStructuredAnswer(provider: HostedProvider) async throws {
        let json = #"{"chosen": "button", "runnerUp": "textField"}"#
        let pieces = [String(json.prefix(12)), String(json.dropFirst(12))]
        StubProvider.answer(with: .init(body: provider == .anthropic ? SSE.anthropic(text: pieces, toolJSON: true) : SSE.openAI(text: pieces)))
        let schema = try HostedSketchInterpreter.decisionSchema(for: ["button", "textField", "image"])
        let session = LanguageModelSession(model: HostedLanguageModel(provider: provider, model: "m"))
        let response = try await session.respond(to: "Which is it?", schema: schema)
        #expect(try response.content.value(String.self, forProperty: "chosen") == "button")

        // The schema went to the provider in its own form.
        let body = StubProvider.lastBody
        switch provider {
        case .anthropic:
            let tool = try #require((body["tools"] as? [[String: Any]])?.first)
            #expect((tool["input_schema"] as? [String: Any])?["type"] as? String == "object")
            #expect((body["tool_choice"] as? [String: Any])?["name"] as? String == "respond")
        case .openAI, .lmStudio:
            let format = try #require(body["response_format"] as? [String: Any])
            #expect(format["type"] as? String == "json_schema")
        }
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func aRejectedKeyIsReportedInWords() async throws {
        StubProvider.answer(with: .init(status: 401, body: #"{"error":{"message":"invalid x-api-key"}}"#, contentType: "application/json"))
        let session = LanguageModelSession(model: HostedLanguageModel(provider: .anthropic, model: "m"))
        await #expect(throws: HostedModelError.keyRejected(.anthropic)) {
            try await session.respond(to: "Hello")
        }
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func aMissingKeyIsReportedBeforeAnythingIsSent() async throws {
        try APIKeyStore.removeKey(for: .openAI)
        StubProvider.answer(with: .init(body: SSE.openAI(text: ["x"])))
        let session = LanguageModelSession(model: HostedLanguageModel(provider: .openAI, model: "m"))
        await #expect(throws: HostedModelError.missingKey(.openAI)) {
            try await session.respond(to: "Hello")
        }
        #expect(StubProvider.requests.isEmpty)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    @MainActor
    func aGeneratedScreenFillsInOnTheCanvasAndUndoesInOneStep() async throws {
        let lines = ["title: Welcome back\n", "text field: Email\n", "text field: Pass", "word\n", "button: Sign in [blue]"]
        StubProvider.answer(with: .init(body: SSE.openAI(text: lines)))
        let app = AppModel(document: LayerDocument())
        let undo = UndoManager()
        app.store.undoManager = undo
        app.setModelChoice(.hosted(.openAI, model: "gpt-test"))
        let screensBefore = app.store.screens.count

        app.generateScreen(from: "a sign-in screen")
        #expect(app.isGenerating)
        #expect(app.generation?.isThinking == true, "nothing is written yet, so it is thinking")
        let screenID = try #require(app.generation?.screenID)
        #expect(app.store.screen(screenID)?.name == "A sign-in screen")
        let deadline = ContinuousClock.now + .seconds(10)
        while app.isGenerating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        #expect(app.generation?.phase == .finished)
        #expect(app.generation?.isThinking == false)
        #expect(app.generation?.elementCount == 4)
        let screen = try #require(app.store.screen(screenID))
        #expect(screen.elements.map(\.kind) == [.title, .textField, .textField, .button])
        #expect(screen.elements.map(\.text) == ["Welcome back", "Email", "Password", "Sign in"])
        // The description went to the design's model, with the generator's instructions.
        // (Switching models also sends the engine's own short check, so it's one of several.)
        let systems = StubProvider.requests.compactMap { request -> String? in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            return (body?["messages"] as? [[String: Any]])?.first?["content"] as? String
        }
        #expect(systems.contains(ScreenGenerator.instructions))

        // One undo takes the whole generated screen away.
        undo.undo()
        #expect(app.store.screens.count == screensBefore)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func aModelIsThinkingUntilItsAnswerStarts() async throws {
        StubProvider.answer(with: .init(body: SSE.openAI(text: ["title: Hi\n", "button: Go\n"], thinking: ["The user wants", " a short screen."])))
        var updates: [ScreenGenerator.Update] = []
        for try await update in ScreenGenerator.stream("a tiny screen", using: .hosted(.openAI, model: "m")) {
            updates.append(update)
        }
        // Its reasoning isn't the answer: writing starts with the first line, once.
        #expect(updates.first == .startedWriting)
        #expect(updates.filter { $0 == .startedWriting }.count == 1)
        let counts = updates.compactMap { if case .screen(let blueprint) = $0 { blueprint.itemCount } else { nil } }
        #expect(counts.last == 2)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    @MainActor
    func aFailedGenerationLeavesNoEmptyScreen() async throws {
        StubProvider.answer(with: .init(status: 401, body: #"{"error":{"message":"bad key"}}"#, contentType: "application/json"))
        let app = AppModel(document: LayerDocument())
        app.setModelChoice(.hosted(.anthropic, model: "m"))
        app.generateScreen(from: "a profile screen")
        let deadline = ContinuousClock.now + .seconds(10)
        while app.isGenerating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.generation?.phase == .failed(HostedModelError.keyRejected(.anthropic).localizedDescription))
        #expect(app.store.screens.isEmpty)
    }

    @Test func modelsAreListedFromEachProvider() async throws {
        StubProvider.answer(with: .init(body: #"{"data":[{"id":"claude-a","display_name":"Claude A"},{"id":"claude-b"}],"has_more":false}"#, contentType: "application/json"))
        let anthropic = try await HostedModelClient.models(for: .anthropic, key: "k")
        #expect(anthropic == [HostedModelInfo(id: "claude-a", name: "Claude A"), HostedModelInfo(id: "claude-b", name: "claude-b")])

        StubProvider.answer(with: .init(body: #"{"data":[{"id":"gpt-old","created":1},{"id":"text-embedding-3-small","created":3},{"id":"gpt-new","created":2},{"id":"gpt-4o-realtime-preview","created":4},{"id":"o4-mini","created":5}]}"#, contentType: "application/json"))
        let openAI = try await HostedModelClient.models(for: .openAI, key: "k")
        #expect(openAI.map(\.id) == ["o4-mini", "gpt-new", "gpt-old"])
    }

    @Test func noNetworkIsReportedInWords() async throws {
        StubProvider.answer(with: .init(body: "")) // replaced below by a failure
        StubProvider.failNextRequests()
        await #expect(throws: HostedModelError.offline) {
            _ = try await HostedModelClient.models(for: .openAI, key: "k")
        }
    }

    @Test(arguments: [HostedProvider.anthropic, .openAI])
    func theClientStreamsTheAnswerAsItArrives(provider: HostedProvider) async throws {
        StubProvider.answer(with: .init(body: provider == .anthropic ? SSE.anthropic(text: ["Sign", " in"]) : SSE.openAI(text: ["Sign", " in"])))
        var events: [HostedModelClient.StreamEvent] = []
        let conversation = HostedConversation(system: "S", messages: [.init(role: .user, text: "Hi")])
        for try await event in HostedModelClient.stream(conversation, schema: nil, maximumTokens: 50, temperature: nil, provider: provider, model: "m", key: "k") {
            events.append(event)
        }
        #expect(events.compactMap { if case .text(let text) = $0 { text } else { nil } } == ["Sign", " in"])
        #expect(events.contains { if case .usage(_, let output) = $0 { output > 0 } else { false } })
        let body = StubProvider.lastBody
        #expect(body["stream"] as? Bool == true)
        switch provider {
        case .anthropic: #expect(body["max_tokens"] as? Int == 50)
        case .openAI, .lmStudio: #expect(body["max_completion_tokens"] as? Int == 50)
        }
    }

    @Test func aStreamThatFailsPartWayIsReported() async throws {
        let failing = #"data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}"# + "\n\n" + #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        StubProvider.answer(with: .init(body: failing))
        await #expect(throws: HostedModelError.server(.anthropic, status: 0, message: "Overloaded")) {
            for try await _ in HostedModelClient.stream(HostedConversation(), schema: nil, maximumTokens: nil, temperature: nil, provider: .anthropic, model: "m", key: "k") {}
        }
    }

    @Test func aRejectedKeyIsReportedByTheClient() async throws {
        StubProvider.answer(with: .init(status: 401, body: #"{"error":{"message":"Incorrect API key"}}"#, contentType: "application/json"))
        await #expect(throws: HostedModelError.keyRejected(.openAI)) {
            _ = try await HostedModelClient.models(for: .openAI, key: "bad")
        }
        await #expect(throws: HostedModelError.keyRejected(.openAI)) {
            for try await _ in HostedModelClient.stream(HostedConversation(), schema: nil, maximumTokens: nil, temperature: nil, provider: .openAI, model: "m", key: "bad") {}
        }
    }

    @Test func aTranscriptBecomesTheProvidersConversation() {
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "Be brief."))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Hi"))])),
            .response(.init(assetIDs: [], segments: [.text(.init(content: "Hello"))])),
            .prompt(.init(segments: [.text(.init(content: "Again"))])),
        ])
        let conversation = HostedModelExecutor.conversation(from: transcript)
        #expect(conversation.system == "Be brief.")
        #expect(conversation.messages == [.init(role: .user, text: "Hi"), .init(role: .assistant, text: "Hello"), .init(role: .user, text: "Again")])
    }
}

@Suite("API keys in the Keychain", .serialized)
struct APIKeyStoreTests {
    @Test func aKeyIsSavedReplacedAndRemoved() throws {
        let provider = HostedProvider.openAI
        try APIKeyStore.setKey("  first  ", for: provider)
        #expect(APIKeyStore.key(for: provider) == "first")
        #expect(APIKeyStore.hasKey(for: provider))
        try APIKeyStore.setKey("second", for: provider)
        #expect(APIKeyStore.key(for: provider) == "second")
        try APIKeyStore.setKey("", for: provider)
        #expect(APIKeyStore.key(for: provider) == nil)
        #expect(!APIKeyStore.hasKey(for: provider))
        // Not kept anywhere else.
        #expect(UserDefaults.standard.dictionaryRepresentation().values.contains { ($0 as? String) == "second" } == false)
    }
}

@Suite("Each design remembers its model", .serialized)
struct ModelChoiceTests {
    @Test func theChoiceIsSavedInTheDesignFileAndReadBack() throws {
        var content = DesignContent()
        content.canvas.model = .hosted(.anthropic, model: "claude-sonnet-test")
        let saved = DesignFile(content: content)
        let reopened = try DesignFile(wrapper: saved.wrapper())
        #expect(reopened.content.canvas.model == .hosted(.anthropic, model: "claude-sonnet-test"))
        #expect(reopened.content.canvas.resolvedModel.hostedProvider == .anthropic)
    }

    @Test func aDesignSavedBeforeThereWasAChoiceUsesTheDefault() throws {
        let previous = ModelPreferences.defaultChoice
        defer { ModelPreferences.defaultChoice = previous }
        ModelPreferences.defaultChoice = .hosted(.openAI, model: "gpt-test")

        let old = #"{"screens":[],"floating":[],"canvas":{"showsGrid":true}}"#
        let content = try JSONDecoder().decode(DesignContent.self, from: Data(old.utf8))
        #expect(content.canvas.model == nil)
        #expect(content.canvas.resolvedModel == .hosted(.openAI, model: "gpt-test"))
    }

    @Test func aChoiceFromANewerLayerStillOpens() throws {
        let newer = #"{"canvas":{"model":{"provider":42}}}"#
        let content = try JSONDecoder().decode(DesignContent.self, from: Data(newer.utf8))
        #expect(content.canvas.model == nil)
    }

    @Test func aNewDesignStartsWithTheDefaultModel() {
        let previous = ModelPreferences.defaultChoice
        defer { ModelPreferences.defaultChoice = previous }
        ModelPreferences.defaultChoice = .hosted(.anthropic, model: "claude-new")
        #expect(LayerDocument().current.content.canvas.model == .hosted(.anthropic, model: "claude-new"))
    }

    @Test func aHostedChoiceRunsItsModelWhereItCan() {
        let choice = ModelChoice.hosted(.openAI, model: "gpt-x")
        if HostedLanguageModel.isSupported {
            #expect(choice.sketchProvider.id == "openai:gpt-x")
            #expect(choice.sketchProvider.needsAPIKey)
        } else {
            #expect(choice.sketchProvider.id == SketchProvider.appleIntelligence.id)
        }
        #expect(ModelChoice.appleIntelligence.sketchProvider.id == SketchProvider.appleIntelligence.id)
        #expect(ModelChoice(provider: "someday-provider", model: "m").sketchProvider.id == SketchProvider.appleIntelligence.id)
    }
}
