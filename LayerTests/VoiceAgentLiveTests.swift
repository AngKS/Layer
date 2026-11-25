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

    private func design() -> (app: AppModel, screen: TreeScreen.ID, agent: VoiceAgent) {
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
        #expect(app.store.screenLeaves(screen).first { $0.kind == .button }?.resolvedTint == ColourWords.parse("green"))
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
        let image = try #require(app.store.screenLeaves(screen).first { $0.kind == .image })
        let frame = try #require(app.store.ownFrame(image.id))
        print("VOICE-LIVE image frame \(frame)")
        #expect(outcome.problem == nil)
        #expect(frame.width == 197)
        #expect(abs(frame.midX - 196.5) <= 1)
    }

    @Test func wordsAreRewrittenInAStyle() async throws {
        let (app, screen, agent) = design()
        let outcome = await say("Change the title's text colour to blue and make its content sound like a pirate", to: agent)
        let title = try #require(app.store.screenLeaves(screen).first { $0.kind == .title })
        print("VOICE-LIVE title now “\(title.content.text)”")
        #expect(outcome.problem == nil)
        #expect(title.style.textColor == ColourWords.parse("blue"))
        #expect(title.content.text != "Welcome back")
    }

    @Test func aCommandLeansOnTheOneBefore() async throws {
        let (app, screen, agent) = design()
        _ = await say("Make the sign in button say Continue", to: agent)
        let outcome = await say("Now make it half width", to: agent)
        let button = try #require(app.store.screenLeaves(screen).first { $0.kind == .button })
        #expect(outcome.problem == nil)
        #expect(button.content.text == "Continue")
        #expect(app.store.ownFrame(button.id)?.width == 197)
    }

    @Test func somethingThatIsNotThereIsSaidNotDone() async throws {
        let (app, _, agent) = design()
        let before = app.store.tree
        let outcome = await say("Make the slider wider", to: agent)
        #expect(app.store.tree.screens == before.screens)
        #expect(outcome.lines.isEmpty)
        // Said by the model, in words: a model that couldn't be reached leaves the
        // design alone too, and must not pass for one that declined.
        #expect(outcome.problem == nil)
        #expect(!outcome.said.isEmpty)
    }

    /// The tree fixture (a card, a row of "Wi-Fi" and a toggle) with two texts below the row, "Terms" and "Privacy", on
    /// the model of the run (plan 6, Task 8).
    private func designWithARow() -> (login: TreeFixture.Login, x: UUID, y: UUID, agent: VoiceAgent) {
        let (login, x, y) = TreeFixture.loginWithTwoTexts()
        login.model.setModelChoice(.hosted(.lmStudio, model: model))
        return (login, x, y, VoiceAgent(model: login.model))
    }

    @Test func liveGroupsTwoTextsAsARow() async throws {
        let (login, x, y, agent) = designWithARow()
        let store = login.model.store
        let outcome = await say("Put the two texts at the bottom in a row", to: agent)
        #expect(outcome.problem == nil)
        guard case .node(let id)? = store.parent(of: x), let row = store.node(id) else {
            Issue.record("The texts aren't in a container")
            return
        }
        print("VOICE-LIVE made \(row.kindName): \(String(describing: row.layout))")
        #expect(row.children.map(\.id) == [x, y])
        guard case .stack(let stack)? = row.layout else {
            Issue.record("The container isn't a row")
            return
        }
        #expect(stack.axis == .horizontal)
    }

    @Test func liveReordersInARow() async throws {
        let (login, _, _, agent) = designWithARow()
        let outcome = await say("Move the toggle before the label", to: agent)
        #expect(outcome.problem == nil)
        #expect(login.model.store.node(login.row)?.children.map(\.id) == [login.toggle, login.label])
    }

    @Test func aNewScreenIsWrittenFromADescription() async throws {
        let (app, _, agent) = design()
        let outcome = await say("I want a profile page with user settings", to: agent)
        #expect(outcome.problem == nil)
        #expect(app.store.tree.screens.count == 2)
        let made = try #require(app.store.tree.screens.last)
        print("VOICE-LIVE new screen “\(made.name)”: \(made.root.leaves.map { "\($0.kind.rawValue) \($0.content.text)" })")
        #expect(made.root.leaves.count >= 3)
        // The whole of it is one step to undo.
        app.store.undoManager?.undo()
        #expect(app.store.tree.screens.count == 1)
    }
}
