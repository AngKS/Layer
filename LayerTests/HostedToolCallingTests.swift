import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

/// What a tool was called with, gathered across the threads tools run on.
actor ToolLog {
    private(set) var calls: [String] = []

    func add(_ call: String) {
        calls.append(call)
    }
}

/// A tool that only writes down what it was asked.
struct RecordingTool: Tool {
    let log: ToolLog
    let name = "setText"
    let description = "Changes the words on an element."

    @Generable
    struct Arguments {
        var element: String
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        await log.add("\(arguments.element)=\(arguments.text)")
        return "Reworded \(arguments.element)."
    }
}

extension SSE {
    /// Anthropic asking for a tool, its arguments arriving in pieces.
    static func anthropicToolCall(id: String, name: String, json pieces: [String]) -> String {
        var lines = [
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":42,"output_tokens":1}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#,
        ]
        for piece in pieces {
            lines.append(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\#(quoted(piece))}}"#)
        }
        lines += [
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        return lines.map { "event: x\n\($0)\n" }.joined(separator: "\n")
    }

    /// OpenAI asking for a tool: its name first, then its arguments in pieces.
    static func openAIToolCall(id: String, name: String, json pieces: [String]) -> String {
        var lines = [
            #"data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":""}}]}}]}"#,
        ]
        for piece in pieces {
            lines.append(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":\#(quoted(piece))}}]}}]}"#)
        }
        lines += [
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":30,"completion_tokens":5}}"#,
            "data: [DONE]",
        ]
        return lines.joined(separator: "\n\n")
    }

    private static func quoted(_ text: String) -> String {
        String(String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast())
    }
}

/// These share the stubbed providers and their keys with the rest of the suite, so they
/// are part of it and run in turn with it.
extension HostedModelTests {
    private static let argumentPieces = [#"{"element":"E2","#, #""text":"Ahoy"}"#]

    private func body(ofRequest index: Int) throws -> [String: Any] {
        let requests = StubProvider.requests
        try #require(requests.count > index, "only \(requests.count) requests were sent")
        return try #require(try JSONSerialization.jsonObject(with: requests[index].body) as? [String: Any])
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func anthropicIsSentTheToolsAndAnswersWithACall() async throws {
        StubProvider.answer(with: [
            .init(body: SSE.anthropicToolCall(id: "toolu_1", name: "setText", json: Self.argumentPieces)),
            .init(body: SSE.anthropic(text: ["Done."])),
        ])
        let log = ToolLog()
        let session = LanguageModelSession(
            model: HostedLanguageModel(provider: .anthropic, model: "claude-test"),
            tools: [RecordingTool(log: log)], instructions: "You edit designs."
        )
        let response = try await session.respond(to: "make the button say ahoy")
        #expect(response.content == "Done.")
        #expect(await log.calls == ["E2=Ahoy"])
        #expect(StubProvider.requests.count == 2)

        // The tool went to Anthropic in its own form, one call at a time.
        let first = try body(ofRequest: 0)
        let tool = try #require((first["tools"] as? [[String: Any]])?.first)
        #expect(tool["name"] as? String == "setText")
        #expect(tool["description"] as? String == "Changes the words on an element.")
        let schema = try #require(tool["input_schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(Set((schema["properties"] as? [String: Any] ?? [:]).keys) == ["element", "text"])
        let choice = try #require(first["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "auto")
        #expect(choice["disable_parallel_tool_use"] as? Bool == true)

        // Its result went back as Anthropic expects: the call, then what came of it.
        let messages = try #require(try body(ofRequest: 1)["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let call = try #require((messages[1]["content"] as? [[String: Any]])?.last)
        #expect(call["type"] as? String == "tool_use")
        #expect(call["id"] as? String == "toolu_1")
        #expect(call["name"] as? String == "setText")
        #expect(call["input"] as? [String: String] == ["element": "E2", "text": "Ahoy"])
        let result = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        #expect(result["type"] as? String == "tool_result")
        #expect(result["tool_use_id"] as? String == "toolu_1")
        #expect(result["content"] as? String == "Reworded E2.")
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func openAIIsSentTheToolsAndAnswersWithACall() async throws {
        StubProvider.answer(with: [
            .init(body: SSE.openAIToolCall(id: "call_1", name: "setText", json: Self.argumentPieces)),
            .init(body: SSE.openAI(text: ["Done."])),
        ])
        let log = ToolLog()
        let session = LanguageModelSession(
            model: HostedLanguageModel(provider: .openAI, model: "gpt-test"),
            tools: [RecordingTool(log: log)], instructions: "You edit designs."
        )
        let response = try await session.respond(to: "make the button say ahoy")
        #expect(response.content == "Done.")
        #expect(await log.calls == ["E2=Ahoy"])

        let first = try body(ofRequest: 0)
        let tool = try #require((first["tools"] as? [[String: Any]])?.first)
        #expect(tool["type"] as? String == "function")
        let function = try #require(tool["function"] as? [String: Any])
        #expect(function["name"] as? String == "setText")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
        #expect(first["parallel_tool_calls"] as? Bool == false)
        #expect(first["tool_choice"] == nil)

        let messages = try #require(try body(ofRequest: 1)["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        let call = try #require((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_1")
        #expect(call["type"] as? String == "function")
        let called = try #require(call["function"] as? [String: Any])
        #expect(called["name"] as? String == "setText")
        let arguments = try #require((called["arguments"] as? String)?.data(using: .utf8))
        #expect(try JSONSerialization.jsonObject(with: arguments) as? [String: String] == ["element": "E2", "text": "Ahoy"])
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        #expect(messages[3]["content"] as? String == "Reworded E2.")
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"), arguments: [HostedProvider.anthropic, .openAI])
    func aModelCanBeMadeToUseATool(provider: HostedProvider) async throws {
        StubProvider.answer(with: [
            .init(body: provider == .anthropic
                ? SSE.anthropicToolCall(id: "t1", name: "setText", json: Self.argumentPieces)
                : SSE.openAIToolCall(id: "t1", name: "setText", json: Self.argumentPieces)),
            .init(body: provider == .anthropic ? SSE.anthropic(text: ["Done."]) : SSE.openAI(text: ["Done."])),
        ])
        let session = LanguageModelSession(model: HostedLanguageModel(provider: provider, model: "m"), tools: [RecordingTool(log: ToolLog())])
        _ = try await session.respond(to: "reword it", options: GenerationOptions(toolCallingMode: .required))
        let first = try body(ofRequest: 0)
        switch provider {
        case .anthropic: #expect((first["tool_choice"] as? [String: Any])?["type"] as? String == "any")
        case .openAI, .lmStudio: #expect(first["tool_choice"] as? String == "required")
        }
    }

    @Test func toolCallsAreReadFromEachProvidersStream() throws {
        func events(_ stream: String, from provider: HostedProvider) throws -> [HostedModelClient.StreamEvent] {
            var parser = HostedModelClient.StreamParser(provider: provider)
            return try stream.split(separator: "\n").flatMap { try parser.events(forLine: String($0)) }
        }
        for (provider, stream) in [
            (HostedProvider.anthropic, SSE.anthropicToolCall(id: "c1", name: "setText", json: Self.argumentPieces)),
            (.openAI, SSE.openAIToolCall(id: "c1", name: "setText", json: Self.argumentPieces)),
        ] {
            let calls = try events(stream, from: provider).compactMap { event -> String? in
                guard case .toolCall(let id, let name, let arguments) = event else { return nil }
                #expect(id == "c1")
                #expect(name == "setText")
                return arguments
            }
            #expect(calls.joined() == Self.argumentPieces.joined(), "\(provider)")
        }
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func aLocalServerThatRejectsToolsSaysSo() async throws {
        StubProvider.answer(with: .init(status: 400, body: #"{"error":{"message":"This model does not support tools."}}"#, contentType: "application/json"))
        let session = LanguageModelSession(model: HostedLanguageModel(provider: .lmStudio, model: "tiny"), tools: [RecordingTool(log: ToolLog())])
        await #expect(throws: HostedModelError.toolsUnsupported(.lmStudio)) {
            try await session.respond(to: "reword it")
        }
        #expect(HostedModelError.toolsUnsupported(.lmStudio).errorDescription == "This model can't take voice commands. Choose another in Settings.")
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func aLocalServerErrorWithoutToolsIsStillItsOwn() async throws {
        StubProvider.answer(with: .init(status: 400, body: #"{"error":{"message":"This model does not support tools."}}"#, contentType: "application/json"))
        let session = LanguageModelSession(model: HostedLanguageModel(provider: .lmStudio, model: "tiny"))
        await #expect(throws: HostedModelError.server(.lmStudio, status: 400, message: "This model does not support tools.")) {
            try await session.respond(to: "hello")
        }
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    @MainActor
    func aSpokenScreenIsWrittenByTheDesignsModel() async throws {
        StubProvider.answer(with: .init(body: SSE.openAI(text: ["title: Welcome\n", "button: Sign in [blue]\n"])))
        let (app, _) = VoiceFixture.undoableLogin()
        app.setModelChoice(.hosted(.openAI, model: "gpt-test"))
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: app, handles: handles)
        let box = VoiceToolbox(model: app, handles: handles)

        let line = try await box.createScreen(description: "a simple login screen")

        #expect(app.store.screens.count == 2)
        let made = try #require(app.store.screens.last)
        #expect(made.elements.map(\.kind) == [.title, .button])
        // The model is told what to call the new screen, and how much is on it.
        #expect(line.contains("S2"))
        #expect(line.contains("2 elements"))
        #expect(handles.screen("S2") == made.id)
        #expect(box.lines == [line])
        // The canvas's own notice isn't left up: the call's pill has said it.
        #expect(app.generation == nil)
    }
}
