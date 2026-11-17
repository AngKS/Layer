import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

@Suite("Reading a screen as it is written")
struct ScreenStreamParsingTests {
    @Test func aHalfWrittenLineWaitsForTheNext() throws {
        let partial = "title: Welcome back\ntext field: Em"
        let soFar = try #require(ScreenGenerator.blueprint(ofFinishedLinesIn: partial, isComplete: false))
        #expect(soFar.itemCount == 1)
        let whole = try #require(ScreenGenerator.blueprint(ofFinishedLinesIn: partial, isComplete: true))
        #expect(whole.itemCount == 2)
        #expect(whole.sections.flatMap(\.items).last?.text == "Em")
    }

    @Test func codeFencesAndHeadingsAreIgnored() throws {
        let written = "# Login\n```\ntitle: Hi\nbutton: Go [blue]\n```\n"
        let blueprint = try #require(ScreenGenerator.blueprint(ofFinishedLinesIn: written, isComplete: true))
        #expect(blueprint.sections.flatMap(\.items).map(\.kind) == [.title, .button])
    }

    @Test func nothingFinishedIsNothingToShow() {
        #expect(ScreenGenerator.blueprint(ofFinishedLinesIn: "title: Wel", isComplete: false) == nil)
    }

    @Test func aScreenIsNamedFromItsDescription() {
        #expect(ScreenGenerator.name(for: "a sign-in screen with email and password") == "A sign-in screen with")
        #expect(ScreenGenerator.name(for: "   ") == "Generated Screen")
    }
}

/// Runs against LM Studio on this Mac, when asked for:
///
///     TEST_RUNNER_LAYER_LMSTUDIO=google/gemma-4-26b-a4b xcodebuild test \
///       -only-testing:LayerTests/LMStudioLiveTests ...
///
/// It needs LM Studio's server running with that model downloaded.
@Suite(
    "A real model in LM Studio", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] != nil, "set TEST_RUNNER_LAYER_LMSTUDIO=<model id> to run")
)
struct LMStudioLiveTests {
    let model = ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] ?? ""

    @Test func itsModelsAreListed() async throws {
        let models = try await HostedModelClient.models(for: .lmStudio, key: nil)
        #expect(models.contains { $0.id == model }, "LM Studio lists \(models.map(\.id))")
        #expect(!models.contains { $0.id.contains("embed") })
    }

    @Test func itStreamsAnAnswer() async throws {
        var pieces: [String] = []
        var thought = ""
        let conversation = HostedConversation(system: nil, messages: [.init(role: .user, text: "Reply with exactly the two words: Sign in")])
        for try await event in HostedModelClient.stream(conversation, schema: nil, maximumTokens: nil, temperature: nil, provider: .lmStudio, model: model, key: nil) {
            switch event {
            case .text(let piece): pieces.append(piece)
            case .reasoning(let piece): thought += piece
            case .usage: break
            }
        }
        print("LMSTUDIO answer in \(pieces.count) pieces: \(pieces.joined()) (thought \(thought.count) characters)")
        #expect(pieces.count >= 2, "the answer should arrive in pieces")
        #expect(pieces.joined().localizedCaseInsensitiveContains("sign in"))
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func aSessionStreamsThroughFoundationModels() async throws {
        let session = LanguageModelSession(model: HostedLanguageModel(provider: .lmStudio, model: model), instructions: "Answer in as few words as you can.")
        var snapshots = 0
        var answer = ""
        for try await snapshot in session.streamResponse(to: "What colour is a clear daytime sky?") {
            snapshots += 1
            answer = snapshot.content
        }
        print("LMSTUDIO session answer after \(snapshots) snapshots: \(answer)")
        #expect(snapshots >= 2)
        #expect(answer.localizedCaseInsensitiveContains("blue"))
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func aStructuredAnswerComesBackInItsSchema() async throws {
        let session = LanguageModelSession(model: HostedLanguageModel(provider: .lmStudio, model: model), instructions: SketchPrompt.instructions)
        let schema = try HostedSketchInterpreter.decisionSchema(for: ["button", "textField"])
        let response = try await session.respond(to: "A wide pill near the bottom of the screen, with 'Continue' written in it.", schema: schema)
        let chosen = try response.content.value(String.self, forProperty: "chosen")
        print("LMSTUDIO chose \(chosen)")
        #expect(["button", "textField"].contains(chosen))
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    @MainActor
    func aScreenIsGeneratedOnTheCanvasAsItIsWritten() async throws {
        let document = LayerDocument()
        let app = AppModel(document: document)
        app.setModelChoice(.hosted(.lmStudio, model: model))
        app.generateScreen(from: "a sign-in screen with a title, email and password fields, and a sign in button")
        let screenID = try #require(app.generation?.screenID)
        var counts: [Int] = []
        let deadline = ContinuousClock.now + .seconds(240)
        while app.isGenerating, ContinuousClock.now < deadline {
            let count = app.store.screen(screenID)?.elements.count ?? 0
            if counts.last != count { counts.append(count) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let screen = try #require(app.store.screen(screenID))
        print("LMSTUDIO generated \(screen.elements.map { "\($0.kind.rawValue): \($0.text)" }) — counts seen while streaming: \(counts)")
        #expect(app.generation?.phase == .finished)
        #expect(screen.elements.count >= 3)
        #expect(screen.elements.contains { $0.kind == .button })
        #expect(counts.filter { $0 > 0 }.count >= 2, "elements should appear while the model is still writing: \(counts)")
    }
}
