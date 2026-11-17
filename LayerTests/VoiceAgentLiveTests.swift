import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

/// Spoken commands carried out by a real model in LM Studio on this Mac, through the
/// agent, the profile and the tools exactly as a call runs them. Asked for with:
///
///     TEST_RUNNER_LAYER_LMSTUDIO=google/gemma-4-26b-a4b xcodebuild test \
///       -only-testing:LayerTests/VoiceAgentLiveTests ...
///
/// It needs LM Studio's server running with that model downloaded, and a model that can
/// call tools. Each command prints a line beginning `VOICE-LIVE` with how it went and
/// how long it took, which is what `docs/benchmarks/voice-agent.md` is written from.
@Suite(
    "Voice commands with a real model in LM Studio", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] != nil && HostedLanguageModel.isSupported, "set TEST_RUNNER_LAYER_LMSTUDIO=<model id> to run")
)
@MainActor
struct VoiceAgentLiveTests {
    let model = ProcessInfo.processInfo.environment["LAYER_LMSTUDIO"] ?? ""

    private func design() -> (app: AppModel, screen: DesignScreen.ID, agent: VoiceAgent) {
        let (app, screen) = VoiceFixture.undoableLogin()
        app.setModelChoice(.hosted(.lmStudio, model: model))
        return (app, screen, VoiceAgent(model: app))
    }

    /// Runs a command and prints how it went.
    private func say(_ command: String, to agent: VoiceAgent) async -> VoiceOutcome {
        var steps: [String] = []
        agent.onStep = { steps.append($0) }
        let start = ContinuousClock.now
        let outcome = await agent.run(command)
        let seconds = Double((ContinuousClock.now - start).components.attoseconds) / 1e18 + Double((ContinuousClock.now - start).components.seconds)
        let result = outcome.problem.map { "PROBLEM \($0)" } ?? (outcome.lines.isEmpty ? "SAID \(outcome.said)" : outcome.lines.joined(separator: " | "))
        print("VOICE-LIVE \(String(format: "%.1f", seconds))s “\(command)” -> \(result) [steps: \(steps.joined(separator: ", "))]")
        return outcome
    }

    @Test func aButtonIsRecoloured() async throws {
        let (app, screen, agent) = design()
        let outcome = await say("Make the sign in button green", to: agent)
        #expect(outcome.problem == nil)
        #expect(app.store.screen(screen)?.elements.first { $0.kind == .button }?.tint == ColourWords.parse("green"))
    }

    @Test func theCanvasGoesToTheFirstScreen() async throws {
        let (app, screen, agent) = design()
        let before = app.store.content
        let outcome = await say("Show me the first screen", to: agent)
        #expect(outcome.problem == nil)
        #expect(app.selection == .screen(screen))
        #expect(app.store.content == before, "showing a screen changes nothing")
    }

    @Test func anImageIsHalvedAndCentred() async throws {
        let (app, screen, agent) = design()
        let outcome = await say("Make the image half width and align it centrally", to: agent)
        let image = try #require(app.store.screen(screen)?.elements.first { $0.kind == .image })
        print("VOICE-LIVE image frame \(image.frame)")
        #expect(outcome.problem == nil)
        #expect(image.frame.width == 197)
        #expect(abs(image.frame.midX - 196.5) <= 1)
    }

    @Test func wordsAreRewrittenInAStyle() async throws {
        let (app, screen, agent) = design()
        let outcome = await say("Change the title's text colour to blue and make its content sound like a pirate", to: agent)
        let title = try #require(app.store.screen(screen)?.elements.first { $0.kind == .title })
        print("VOICE-LIVE title now “\(title.text)”")
        #expect(outcome.problem == nil)
        #expect(title.textColor == ColourWords.parse("blue"))
        #expect(title.text != "Welcome back")
    }

    @Test func aCommandLeansOnTheOneBefore() async throws {
        let (app, screen, agent) = design()
        _ = await say("Make the sign in button say Continue", to: agent)
        let outcome = await say("Now make it half width", to: agent)
        let button = try #require(app.store.screen(screen)?.elements.first { $0.kind == .button })
        #expect(outcome.problem == nil)
        #expect(button.text == "Continue")
        #expect(button.frame.width == 197)
    }

    @Test func somethingThatIsNotThereIsSaidNotDone() async throws {
        let (app, _, agent) = design()
        let before = app.store.content
        let outcome = await say("Make the slider wider", to: agent)
        #expect(app.store.content.screens == before.screens)
        #expect(outcome.lines.isEmpty)
        // Said by the model, in words: a model that couldn't be reached leaves the
        // design alone too, and must not pass for one that declined.
        #expect(outcome.problem == nil)
        #expect(!outcome.said.isEmpty)
    }

    @Test func aNewScreenIsWrittenFromADescription() async throws {
        let (app, _, agent) = design()
        let outcome = await say("I want a profile page with user settings", to: agent)
        #expect(outcome.problem == nil)
        #expect(app.store.screens.count == 2)
        let made = try #require(app.store.screens.last)
        print("VOICE-LIVE new screen “\(made.name)”: \(made.elements.map { "\($0.kind.rawValue) \($0.text)" })")
        #expect(made.elements.count >= 3)
        // The whole of it is one step to undo.
        app.store.undoManager?.undo()
        #expect(app.store.screens.count == 1)
    }
}
