import Combine
import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

@Suite("Reading a screen as it is written")
struct ScreenStreamParsingTests {
    @Test func aHalfWrittenLineWaitsForTheNext() throws {
        let partial = "title: Welcome back\ntext field: Em"
        var outline = OutlineStream(tokens: .standard)
        let soFarTaken = outline.take(partial, isComplete: false)
        let soFar = try #require(soFarTaken)
        #expect(soFar.leafCount == 1)
        let wholeTaken = outline.take(partial, isComplete: true)
        let whole = try #require(wholeTaken)
        #expect(whole.leafCount == 2)
        #expect(leaves(whole).last?.content.text == "Em")
    }

    @Test func codeFencesAndHeadingsAreIgnored() throws {
        let written = "# Login\n```\ntitle: Hi\nbutton: Go [blue]\n```\n"
        var outline = OutlineStream(tokens: .standard)
        let taken = outline.take(written, isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.kind) == [.title, .button])
    }

    @Test func nothingFinishedIsNothingToShow() {
        var outline = OutlineStream(tokens: .standard)
        let taken = outline.take("title: Wel", isComplete: false)
        #expect(taken == nil)
    }

    @Test func aScreenIsNamedFromItsDescription() {
        #expect(ScreenGenerator.name(for: "a sign-in screen with email and password") == "A sign-in screen with")
        #expect(ScreenGenerator.name(for: "   ") == "Generated Screen")
    }

    @Test func aScreenHasOnePrimaryAction() throws {
        let written = """
            title: Plans
            button: Start free trial
            button: Compare plans
            row: button: Not now | button: Upgrade
            button: Restore purchase [plain]
            """
        var outline = OutlineStream(tokens: .standard)
        let taken = outline.take(written, isComplete: true)
        let root = try #require(taken)
        let looks = leaves(root).filter { $0.kind == .button }.map(\.content.buttonLook)
        // The first stays filled; the rest step down, plainly beside others in a row;
        // a look the model chose stays.
        #expect(looks == [nil, .bordered, .plain, .plain, .plain])
    }

    @Test func theButtonWrittenAsFilledIsThePrimaryOne() throws {
        let written = "button: Cancel\nbutton: Pay now [filled]"
        var outline = OutlineStream(tokens: .standard)
        let taken = outline.take(written, isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.content.buttonLook) == [.bordered, .filled])
    }

    @Test func aScreenOfOnlyBorderedButtonsGetsAMainOne() throws {
        // As the on-device model wrote a recipe screen: every action bordered or plain.
        let written = "image\ntitle: Lemon curd\nbutton: Print [bordered]\nbutton: Save to recipe book [bordered]\nbutton: Share [plain]"
        var outline = OutlineStream(tokens: .standard)
        let taken = outline.take(written, isComplete: true)
        let root = try #require(taken)
        let looks = leaves(root).filter { $0.kind == .button }.map(\.content.buttonLook)
        #expect(looks == [.bordered, nil, .plain])
    }

    /// The leaves under `node`, in reading order.
    private func leaves(_ node: LayerNode) -> [LayerNode] {
        node.children.flatMap { $0.isContainer ? leaves($0) : [$0] }
    }
}

@Suite("What a model is told to write a screen")
struct ScreenPromptTests {
    @Test func everyKindThatGoesOnScreensIsNamedAndReadsBack() {
        let names = ScreenPrompt.kindNames
        #expect(!names.contains("sticky note"))
        #expect(names.contains("text field") && names.contains("progress"))
        for name in names {
            #expect(LookWords.kind(named: name) != nil, "\(name) should read back as a kind")
        }
    }

    @Test func examplesFitTheDescription() {
        #expect(ScreenPrompt.examples(for: "Notification settings", count: 1).map(\.name) == ["settings"])
        #expect(ScreenPrompt.examples(for: "a checkout with the delivery address", count: 1).map(\.name) == ["form"])
        #expect(ScreenPrompt.examples(for: "Log in", count: 1).map(\.name) == ["sign in"])
        // Nothing matched: not a sign-in form, which every screen would otherwise copy.
        let unmatched = ScreenPrompt.examples(for: "a weather dashboard", count: 2).map(\.name)
        #expect(unmatched.count == 2 && !unmatched.contains("sign in"))
    }

    @Test func theOnDeviceModelIsToldLess() {
        let compact = ScreenPrompt.instructions(.compact, for: "a profile")
        let full = ScreenPrompt.instructions(.full, for: "a profile")
        #expect(compact.count < full.count)
        // About a quarter of the on-device model's 4,096-token context, at about four characters a token.
        #expect(compact.count < 4_000, "\(compact.count) characters")
    }

    @Test func theBoardIsSentToAHostedModelWhenThereIsOne() {
        #expect(ScreenPrompt.request("a profile", board: nil, room: .full) == "a profile")
        let board = String(repeating: "a title saying “Hi”, ", count: 200)
        let full = ScreenPrompt.request("a profile", board: board, room: .full)
        #expect(full.hasPrefix("a profile\n\n") && full.hasSuffix("…"))
        #expect(full.count < 2_120)
    }

    /// Given the board, the on-device model copied it out in place of the screen asked for.
    @Test func theOnDeviceModelIsToldOnlyTheDescription() {
        #expect(ScreenPrompt.request("a calligraphy webpage", board: "S1 \"Trip planner\": title \"Plan your trip\"", room: .compact) == "a calligraphy webpage")
    }
}

@Suite("Where the sketch hints come from")
struct SketchHintTests {
    /// The instructions every benchmark up to Stage 4 measured, word for word. The hints
    /// now come from the catalogue; until a benchmark shows a better wording, they must
    /// still add up to this.
    @Test func theMeasuredInstructionsAreUnchanged() {
        let measured = """
            You help a phone app design tool read hand-drawn wireframe sketches. Each message \
            describes one sketch the user drew on a phone screen, what else is on that screen, \
            and what the sketch could be. Its shape alone doesn't settle it, so use the \
            context to choose the one the user most likely meant.

            What designers usually mean:
            - button: a wide pill or rounded box. Usually near the bottom of a screen, and a \
            screen rarely has more than one or two.
            - textField: a wide box with squarish or slightly rounded corners. Often stacked \
            with other text fields in the upper or middle part of a screen.
            - image: a large box, about as tall as it is wide or taller.
            - title: a short squiggle near the top. A screen has one title.
            - bodyText: a longer squiggle, or a squiggle below a title or an image.
            - checkbox: a tiny square, often with a tick or an X in it, usually beside a label.
            - radioButton: a tiny circle, under about 33 points across, often with a dot in it, usually one of a column of them.
            - progressBar: a long, very thin outline, often partly shaded in.
            - avatar: a circle about 34 points across or more, usually alone rather than in a column.
            - toggle: a small pill with a circle (its knob) nearer one end than the middle.

            You're only asked about sketches the shape rules themselves found ambiguous, and \
            you're given their own ranked, scored guesses — read those scores as real evidence \
            of how the rules see it, not decoration. Answer with your choice, and a runner-up \
            only if a second reading is genuinely plausible.
            """
        #expect(SketchPrompt.defaultInstructions(.all) == measured)
    }

    @Test func candidateHintsNameOnlyTheCandidates() {
        let lines = SketchPrompt.hints(for: [.button, .textField])
        #expect(lines.hasPrefix("- button: ") && lines.contains("\n- textField: "))
        #expect(!lines.contains("avatar"))
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
            case .usage, .toolCall: break
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
            let count = app.store.screenLeaves(screenID).count
            if counts.last != count { counts.append(count) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let screen = try #require(app.store.treeScreen(screenID)).root.leaves
        print("LMSTUDIO generated \(screen.map { "\($0.kind.rawValue): \($0.content.text)" }) — counts seen while streaming: \(counts)")
        #expect(app.generation?.phase == .finished)
        #expect(screen.count >= 3)
        #expect(screen.contains { $0.kind == .button })
        #expect(counts.filter { $0 > 0 }.count >= 2, "elements should appear while the model is still writing: \(counts)")
    }
}

/// A screen being written, as its design changes and closes around it (Wave 2).
@Suite("A generation's life", .serialized)
@MainActor
struct ScreenGenerationLifecycleTests {
    /// A design whose generations are written by the test, a line at a time.
    private func bench() -> (app: AppModel, undo: UndoManager, feed: AsyncThrowingStream<ScreenGenerator.Update, any Error>.Continuation) {
        let app = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.store.undoManager = undo
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        app.screenStream = { _ in stream }
        return (app, undo, feed)
    }

    private static func written(_ text: String) -> ScreenGenerator.Update {
        .screen(Outline.parse(text, isComplete: true))
    }

    /// Undo pressed while a screen is written takes it away. The generation still
    /// finishes: it used to stay "writing" for good, with every later one refused and its
    /// own undo step never closed (B-I1).
    @Test func aGenerationWhoseScreenIsTakenAwayStillFinishes() async throws {
        let (app, undo, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { app.store.screenLeaves(screen).count == 1 })
        undo.undo()
        #expect(app.store.treeScreen(screen) == nil)
        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        #expect(await eventually { !app.isGenerating })
        #expect(app.generation == nil)
        #expect(app.store.treeScreen(screen) == nil)
        // Its edit is closed: a change now is a step of its own.
        let mark = app.store.historyMark
        app.store.setTitle("Next")
        #expect(app.store.historyMark != mark)
        // And the next generation goes.
        let (stream, next) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        app.screenStream = { _ in stream }
        app.generateScreen(from: "a profile screen")
        #expect(app.isGenerating)
        next.finish()
        feed.finish()
        await app.waitForGeneration()
    }

    /// A generation that fails, or writes nothing, takes its screen away and leaves no undo
    /// step: Undo used to light up after it and do nothing.
    @Test func aGenerationThatWritesNothingLeavesNoUndoStep() async throws {
        let (app, undo, feed) = bench()
        app.generateScreen(from: "a settings screen")
        #expect(app.store.tree.screens.count == 1)
        feed.finish(throwing: URLError(.notConnectedToInternet))
        await app.waitForGeneration()
        #expect(app.store.tree.screens.isEmpty)
        #expect(!undo.canUndo)

        let (stream, empty) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        app.screenStream = { _ in stream }
        app.generateScreen(from: "a profile screen")
        empty.finish()
        await app.waitForGeneration()
        #expect(app.store.tree.screens.isEmpty)
        #expect(!undo.canUndo)
    }

    /// Undo and Redo look again whenever the history says it changed. Taking the empty step
    /// out said nothing, so after a failed generation Undo stayed lit and did nothing.
    @Test func undoGoesOutAfterAGenerationThatWritesNothing() async throws {
        let (app, undo, feed) = bench()
        var shown: [Bool] = []
        let listening = UndoControl.changes(of: undo).sink { _ in shown.append(undo.canUndo) }
        defer { listening.cancel() }

        app.generateScreen(from: "a settings screen")
        #expect(shown.last == true, "the screen being written is a step")
        feed.finish(throwing: URLError(.notConnectedToInternet))
        await app.waitForGeneration()
        #expect(!undo.canUndo)
        #expect(shown.last == false, "the controls were told the step went")

        let (stream, empty) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        app.screenStream = { _ in stream }
        app.generateScreen(from: "a profile screen")
        #expect(shown.last == true)
        empty.finish()
        await app.waitForGeneration()
        #expect(shown.last == false)
    }

    /// Deleting the screen by hand while it is written: the same.
    @Test func aGenerationWhoseScreenIsDeletedStillFinishes() async throws {
        let (app, _, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { app.store.screenLeaves(screen).count == 1 })
        app.store.deleteScreen(screen)
        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        #expect(await eventually { !app.isGenerating })
        feed.finish()
    }

    /// Something put on the screen while it is written, and typed into, used to be wiped by
    /// the next line, which replaced everything on the screen (G5, M1). Each line now
    /// rewrites only what the generation wrote, keeping each element it wrote the same
    /// element, so a selection of it stays.
    @Test func whatIsPutOnTheScreenByHandSurvivesTheNextLine() async throws {
        let (app, _, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { app.store.screenLeaves(screen).count == 1 })
        let title = try #require(app.store.screenLeaves(screen).first)
        var note = LayerNode.standard(.text)
        note.frame.origin = CGPoint(x: 40, y: 600)
        try #require(app.store.add(note, to: .screen(screen)))
        app.store.update(note.id) { $0.content.text = "typed" }
        app.selection = .element(.init(host: .screen(screen), node: title.id))

        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        #expect(await eventually { app.store.screenLeaves(screen).count == 3 })
        #expect(app.store.node(note.id)?.content.text == "typed")
        #expect(app.store.node(title.id)?.kind == .title, "the title is the same element")
        #expect(app.selection == .element(.init(host: .screen(screen), node: title.id)))
        feed.finish()
        await app.waitForGeneration()
        #expect(app.store.node(note.id)?.content.text == "typed")
    }

    /// An element the generation wrote and the person then moved, retyped or deleted is
    /// theirs: later lines leave it as they left it (G5).
    @Test func aWrittenElementChangedByHandIsLeftAsItWasChanged() async throws {
        let (app, _, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        feed.yield(Self.written("title: Settings\nbutton: Save\n"))
        #expect(await eventually { app.store.screenLeaves(screen).count == 2 })
        let written = app.store.screenLeaves(screen)
        let title = NodeRef(host: .screen(screen), node: written[0].id)
        let button = NodeRef(host: .screen(screen), node: written[1].id)
        app.store.update(title.node) { $0.content.text = "Mine"; $0.frame.origin.y += 40 }
        app.store.delete(button)
        let moved = try #require(app.store.node(title.node))

        feed.yield(Self.written("title: Settings\nbutton: Save\ntext: Notifications\n"))
        #expect(await eventually { app.store.screenLeaves(screen).count == 2 })
        #expect(app.store.node(title.node) == moved)
        #expect(app.store.node(button.node) == nil, "a deleted element isn't brought back")
        feed.finish()
        await app.waitForGeneration()
    }

    /// A generation that writes nothing took its screen away with everything on it, so
    /// what was put there by hand was lost with it (M1). A screen with something put on it
    /// by hand stays, with that on it.
    @Test(arguments: [true, false])
    func aGenerationThatWritesNothingKeepsWhatWasPutOnItsScreen(fails: Bool) async throws {
        let (app, _, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        feed.yield(.startedWriting)
        #expect(await eventually { app.generation?.isThinking == false })
        let added = LayerNode.standard(.text)
        try #require(app.store.add(added, to: .screen(screen)))
        app.store.update(added.id) { $0.content.text = "typed" }
        if fails { feed.finish(throwing: URLError(.notConnectedToInternet)) } else { feed.finish() }
        await app.waitForGeneration()
        #expect(app.store.treeScreen(screen) != nil)
        #expect(app.store.node(added.id)?.content.text == "typed")
    }

    /// Stop pressed before the first line: the screen goes, as there is nothing on it, and
    /// that isn't reported as the model failing to describe anything (G10).
    @Test func stoppingBeforeTheFirstLineIsNotAFailure() async throws {
        let (app, _, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        app.stopGenerating()
        await app.waitForGeneration()
        #expect(app.store.treeScreen(screen) == nil)
        #expect(app.generation == nil)
        feed.finish()
    }

    /// The screen undone before the model has written a line: the model is stopped then,
    /// not left thinking, and paid for, for a screen that is gone (G11).
    @Test func aScreenTakenAwayBeforeItsFirstLineStopsTheModel() async throws {
        let (app, undo, feed) = bench()
        app.generateScreen(from: "a settings screen")
        undo.undo()
        #expect(await eventually { !app.isGenerating })
        #expect(app.generation == nil)
        feed.finish()
    }

    /// Nothing is written to a design once it has closed, and nothing new is started (B-I4).
    @Test func aClosedDesignIsNotWrittenTo() async throws {
        let (app, _, feed) = bench()
        app.generateScreen(from: "a settings screen")
        feed.yield(Self.written("title: Settings\n"))
        #expect(await eventually { app.store.tree.screens.first?.root.leaves.count == 1 })
        let saved = app.document.current.content
        app.close()
        await app.waitForGeneration()
        #expect(app.generation == nil && !app.isGenerating)
        // Nothing more is written to the closed file.
        #expect(app.document.current.content == saved)
        app.generateScreen(from: "a profile screen")
        #expect(app.generation == nil)
        feed.finish()
    }
}
