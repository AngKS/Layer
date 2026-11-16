import CoreGraphics
import Testing
@testable import Layer

private func observe(_ paths: [[CGPoint]]) -> SketchObservation? {
    SketchAnalyzer.observe(SketchSamples.strokes(paths))
}

/// A request for a sketch drawn on a screen at `local`, or on the open canvas when nil.
private func request(_ paths: [[CGPoint]], local: CGRect? = nil, existing: [ExistingElement] = []) throws -> SketchRequest {
    SketchRequest(
        observation: try #require(observe(paths)),
        placement: local.map { .onScreen(local: $0, existing: existing) } ?? .openCanvas,
        strokes: paths
    )
}

private let existingTitle = ExistingElement(kind: .title, frame: CGRect(x: 82.5, y: 112, width: 228, height: 40))

/// A wide box whose corners are rounder than a text field's and squarer than a pill's.
private func roundedWideBox(at y: CGFloat) -> (rect: CGRect, paths: [[CGPoint]]) {
    let rect = CGRect(x: 30, y: y, width: 330, height: 56)
    return (rect, [SketchSamples.box(rect, radius: rect.height * 0.22)])
}

@Suite("Describing sketches")
struct SketchAnalyzerTests {
    @Test func aBoxIsAnEnclosureWithSquarishCorners() throws {
        let observation = try #require(observe([SketchSamples.box(CGRect(x: 100, y: 80, width: 260, height: 560), radius: 10)]))
        guard case .enclosure(let roundness, let inner) = observation.form else {
            Issue.record("expected an enclosure, got \(observation.form)")
            return
        }
        #expect(roundness < 0.3)
        #expect(inner == .none)
    }

    @Test func aPillIsAFullyRoundedEnclosure() throws {
        let rect = CGRect(x: 40, y: 500, width: 220, height: 40)
        let observation = try #require(observe([SketchSamples.box(rect, radius: 20)]))
        guard case .enclosure(let roundness, _) = observation.form else {
            Issue.record("expected an enclosure, got \(observation.form)")
            return
        }
        #expect(roundness > 0.75)
    }

    @Test func aBoxWithAnXInsideHasACross() throws {
        let rect = CGRect(x: 60, y: 120, width: 210, height: 230)
        let observation = try #require(observe([SketchSamples.box(rect, radius: 28)] + SketchSamples.cross(rect)))
        #expect(observation.strokeCount == 3)
        guard case .enclosure(_, let inner) = observation.form else {
            Issue.record("expected an enclosure, got \(observation.form)")
            return
        }
        #expect(inner == .cross)
    }

    @Test(arguments: [3, 8])
    func aSquiggleIsAWaveWithItsHumpsCounted(humps: Int) throws {
        let rect = CGRect(x: 80, y: 300, width: CGFloat(humps) * 24, height: 18)
        let observation = try #require(observe([SketchSamples.wave(rect, humps: humps)]))
        #expect(observation.form == .wave(humps: humps))
    }

    @Test func aCrossOnItsOwnIsNotAnEnclosure() throws {
        let observation = try #require(observe(SketchSamples.cross(CGRect(x: 0, y: 0, width: 200, height: 200))))
        #expect(!observation.form.isEnclosure)
    }

    @Test func aStraightStrokeIsALine() throws {
        let stroke = SketchSamples.straight(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 300, y: 203))
        #expect(try #require(observe([stroke])).form == .line)
    }

    @Test func severalStraightStrokesAreStackedLines() throws {
        let strokes = [0, 14, 28].map { offset in
            SketchSamples.straight(from: CGPoint(x: 40, y: 200 + offset), to: CGPoint(x: 260, y: 201 + offset))
        }
        #expect(try #require(observe(strokes)).form == .stackedLines(count: 3))
    }

    @Test func aDotIsTooSmallToBeASketch() {
        #expect(observe([[CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 11)]]) == nil)
    }

    @Test func clusteringKeepsAnXWithItsBoxAndSeparatesDistantSketches() {
        let box = CGRect(x: 60, y: 120, width: 210, height: 230)
        let far = CGRect(x: 60, y: 520, width: 200, height: 20)
        let strokes = SketchSamples.strokes(
            [SketchSamples.box(box, radius: 20)] + SketchSamples.cross(box) + [SketchSamples.wave(far, humps: 6)]
        )
        let groups = SketchAnalyzer.cluster(strokes).sorted { $0.count > $1.count }
        #expect(groups.map(\.count) == [3, 1])
    }
}

@Suite("Reading sketches with the built-in rules")
struct RuleInterpreterTests {
    private let rules = RuleInterpreter()

    @Test func aTallBoxOnTheOpenCanvasIsAScreen() throws {
        let box = SketchSamples.box(CGRect(x: 400, y: 100, width: 270, height: 584), radius: 26)
        #expect(rules.reading(for: try request([box])) == .screen)
    }

    @Test func aSquiggleOnTheOpenCanvasIsText() throws {
        let wave = SketchSamples.wave(CGRect(x: 100, y: 100, width: 120, height: 20), humps: 4)
        #expect(rules.reading(for: try request([wave])) == .element(.text))
    }

    @Test func aStrayStrokeOnTheOpenCanvasIsLeftAsInk() throws {
        let stroke = SketchSamples.straight(from: CGPoint(x: 380, y: 300), to: CGPoint(x: 460, y: 330))
        #expect(rules.reading(for: try request([stroke])) == .unknown)
    }

    @Test func aSmallSquiggleOnTheOpenCanvasIsLeftAsInk() throws {
        let wave = SketchSamples.wave(CGRect(x: 100, y: 100, width: 30, height: 20), humps: 2)
        #expect(rules.reading(for: try request([wave])) == .unknown)
    }

    @Test func theDemoSketchesAreClearAndReadAsTheDemoElements() throws {
        let button = CGRect(x: 28, y: 738, width: 337, height: 60)
        let title = CGRect(x: 150, y: 112, width: 96, height: 40)
        let image = CGRect(x: 34, y: 186, width: 326, height: 364)
        let body = CGRect(x: 52, y: 588, width: 290, height: 28)
        let sketches: [(SketchRequest, ElementKind)] = [
            (try request([SketchSamples.box(button, radius: 30)], local: button), .button),
            (try request([SketchSamples.wave(title, humps: 3)], local: title), .title),
            (try request([SketchSamples.box(image, radius: 44)] + SketchSamples.cross(image), local: image), .image),
            (try request([SketchSamples.wave(body, humps: 8)], local: body, existing: [existingTitle]), .body),
        ]
        for (sketch, kind) in sketches {
            #expect(rules.reading(for: sketch) == .element(kind))
            #expect(!rules.isCloseCall(sketch), "\(kind) should not need a second opinion")
        }
    }

    @Test func aSecondShortSquiggleIsBodyTextOnceThereIsATitle() throws {
        let rect = CGRect(x: 150, y: 300, width: 96, height: 30)
        let sketch = try request([SketchSamples.wave(rect, humps: 3)], local: rect, existing: [existingTitle])
        #expect(rules.reading(for: sketch) == .element(.body))
        #expect(!rules.isCloseCall(sketch))
    }

    @Test func aWideSquarishBoxIsATextFieldAndALineIsADivider() throws {
        let field = CGRect(x: 30, y: 400, width: 330, height: 50)
        #expect(rules.reading(for: try request([SketchSamples.box(field, radius: 2)], local: field)) == .element(.textField))

        let line = SketchSamples.straight(from: CGPoint(x: 30, y: 500), to: CGPoint(x: 360, y: 502))
        let sketch = try request([line], local: CGRect(x: 30, y: 500, width: 330, height: 2))
        #expect(rules.reading(for: sketch) == .element(.divider))
    }

    @Test func shapesNearADividingLineAreCloseCallsBetweenItsTwoSides() throws {
        let box = roundedWideBox(at: 740)
        let betweenPillAndBox = try request(box.paths, local: box.rect)
        #expect(betweenPillAndBox.candidates == [.element(.button), .element(.textField)])
        #expect(rules.isCloseCall(betweenPillAndBox))

        let wideish = CGRect(x: 40, y: 200, width: 320, height: 175)
        let betweenWideAndBoxy = try request([SketchSamples.box(wideish, radius: 6)], local: wideish)
        #expect(betweenWideAndBoxy.candidates == [.element(.image), .element(.textField)])
        #expect(rules.isCloseCall(betweenWideAndBoxy))

        let medium = CGRect(x: 110, y: 110, width: 175, height: 34)
        #expect(rules.isCloseCall(try request([SketchSamples.wave(medium, humps: 5)], local: medium)))

        let low = CGRect(x: 140, y: 600, width: 110, height: 26)
        #expect(rules.isCloseCall(try request([SketchSamples.wave(low, humps: 3)], local: low)))
    }

    @Test func theRulesAlwaysAnswerWithACandidate() throws {
        for y in stride(from: CGFloat(100), through: 700, by: 200) {
            for (width, height, radius) in [(330.0, 56.0, 12.0), (320, 175, 6), (200, 110, 50), (120, 120, 60), (330, 40, 20)] {
                let rect = CGRect(x: 30, y: y, width: width, height: height)
                let sketch = try request([SketchSamples.box(rect, radius: radius)], local: rect)
                #expect(sketch.candidates.contains(rules.reading(for: sketch)))
            }
        }
    }
}

private actor CallCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct StubInterpreter: SketchInterpreter {
    let answer: SketchReading
    let calls: CallCounter

    func read(_ request: SketchRequest) async throws -> SketchReading {
        await calls.record()
        return answer
    }

    func suggestTitle(for board: String) async throws -> String {
        "  “Onboarding Flow.”\nA second line"
    }
}

@Suite("Deciding who reads a sketch")
@MainActor
struct SketchEngineTests {
    private let calls = CallCounter()

    private func engine(answering answer: SketchReading, readiness: ProviderReadiness = .ready) -> SketchEngine {
        let calls = calls
        return SketchEngine(provider: SketchProvider(
            id: "stub", name: "Stub", symbol: "sparkle", needsAPIKey: false,
            readiness: { readiness },
            makeInterpreter: { _ in StubInterpreter(answer: answer, calls: calls) }
        ))
    }

    @Test func clearSketchesAreSettledByTheRulesWithoutAskingTheProvider() async throws {
        let pill = CGRect(x: 28, y: 738, width: 337, height: 60)
        let reading = await engine(answering: .element(.textField)).read(try request([SketchSamples.box(pill, radius: 30)], local: pill))
        #expect(reading == .element(.button))
        #expect(await calls.count == 0)
    }

    @Test func closeCallsAreDecidedByTheProvider() async throws {
        let box = roundedWideBox(at: 740)
        let sketch = try request(box.paths, local: box.rect)
        #expect(RuleInterpreter().reading(for: sketch) == .element(.textField))

        let engine = engine(answering: .element(.button))
        #expect(await engine.read(sketch) == .element(.button))
        #expect(await calls.count == 1)
        #expect(engine.statusLine == "Stub decides the close calls")
    }

    @Test func anAnswerThatIsNotACandidateFallsBackToTheRules() async throws {
        let box = roundedWideBox(at: 740)
        let engine = engine(answering: .element(.title))
        #expect(await engine.read(try request(box.paths, local: box.rect)) == .element(.textField))
        #expect(engine.statusLine == "Stub didn't answer. Using built-in shape rules.")
    }

    @Test func aProviderThatKeepsFailingIsLeftAloneForAWhile() async throws {
        let box = roundedWideBox(at: 740)
        let sketch = try request(box.paths, local: box.rect)
        // A title is not one of this sketch's candidates, so each answer counts as a failure.
        let engine = engine(answering: .element(.title))

        for _ in 0..<SketchEngine.failuresBeforeResting {
            #expect(await engine.read(sketch) == .element(.textField))
        }
        #expect(await calls.count == SketchEngine.failuresBeforeResting)
        #expect(engine.isResting)
        #expect(engine.statusLine == "Stub isn't answering. Using built-in shape rules for now.")

        // Further close calls are settled by the rules at once, without asking.
        #expect(await engine.read(sketch) == .element(.textField))
        #expect(await calls.count == SketchEngine.failuresBeforeResting)
    }

    @Test func oneFailureAmongAnswersIsNotARest() async throws {
        let box = roundedWideBox(at: 740)
        let sketch = try request(box.paths, local: box.rect)
        let failing = engine(answering: .element(.title))
        _ = await failing.read(sketch)
        #expect(!failing.isResting)
        #expect(failing.lastAttemptFailed)

        let answering = engine(answering: .element(.button))
        #expect(await answering.read(sketch) == .element(.button))
        #expect(!answering.lastAttemptFailed)
        #expect(!answering.isResting)
    }

    @Test func anUnavailableProviderLeavesTheRulesInCharge() async throws {
        let box = roundedWideBox(at: 740)
        let engine = engine(answering: .element(.button), readiness: .unavailable("Apple Intelligence is turned off in Settings."))
        #expect(await engine.read(try request(box.paths, local: box.rect)) == .element(.textField))
        #expect(await calls.count == 0)
        #expect(engine.statusLine == "Apple Intelligence is turned off in Settings. Using built-in shape rules.")
    }
}

@Suite("Naming boards")
@MainActor
struct BoardTitleTests {
    private func board(titled text: String?) -> DesignContent {
        var screen = DesignScreen(name: "Screen 1", origin: .zero, scale: 1)
        if let text {
            screen.elements = [DesignElement(kind: .title, frame: CGRect(x: 82.5, y: 112, width: 228, height: 40), text: text, tint: Theme.accent)]
        }
        var content = DesignContent()
        content.screens = [screen]
        return content
    }

    @Test func withoutAModelABoardIsNamedForWhatItSaysOrWhatItIsFor() {
        let rules = RuleInterpreter()
        #expect(rules.title(for: board(titled: "Weekend in Salzburg")) == "Weekend in Salzburg")
        #expect(rules.title(for: board(titled: "Title")) == "iPhone Wireframe")
        #expect(rules.title(for: board(titled: nil)) == "iPhone Wireframe")
        #expect(rules.title(for: DesignContent()) == "Untitled Board")
    }

    @Test func aModelsSuggestionIsTidiedBeforeItIsUsed() async {
        let stub = SketchProvider(
            id: "stub", name: "Stub", symbol: "sparkle", needsAPIKey: false,
            readiness: { .ready },
            makeInterpreter: { _ in StubInterpreter(answer: .unknown, calls: CallCounter()) }
        )
        #expect(await SketchEngine(provider: stub).suggestTitle(for: board(titled: "Title")) == "Onboarding Flow")
    }

    @Test func aBoardIsDescribedByWhatIsOnItsScreens() {
        let text = SketchPrompt.describe(board: board(titled: "Weekend in Salzburg"))
        #expect(text == "The board has one screen. Screen 1, an iPhone screen, has from top to bottom: a title saying “Weekend in Salzburg”.")
    }
}

@Suite("Describing sketches to a model")
struct SketchPromptTests {
    @Test func aCloseCallIsDescribedInWordsWithItsContextAndItsCandidates() throws {
        let box = roundedWideBox(at: 740)
        let text = SketchPrompt.describe(try request(box.paths, local: box.rect, existing: [existingTitle]))
        #expect(text == "The sketch is a wide, flat closed outline with rounded corners, empty inside. "
            + "It is drawn on a phone screen, near the bottom. On the screen so far, top to bottom: title. "
            + "It could be: button or textField.")
    }

    @Test func aSquiggleIsDescribedByItsLength() throws {
        let medium = CGRect(x: 110, y: 110, width: 175, height: 34)
        let text = SketchPrompt.describe(try request([SketchSamples.wave(medium, humps: 5)], local: medium))
        #expect(text == "The sketch is a medium-length squiggle with 5 humps, running left to right. "
            + "It is drawn on a phone screen, near the top. The screen is empty so far. It could be: title or bodyText.")
    }

    @Test func aSketchRendersToASquareImage() throws {
        let sketch = try request([SketchSamples.box(CGRect(x: 100, y: 50, width: 300, height: 80), radius: 40)])
        let image = try #require(sketch.renderImage(side: 128))
        #expect(image.width == 128)
        #expect(image.height == 128)
    }
}

@Suite("Reading a drawing on request")
@MainActor
struct AskedReadingTests {
    private let calls = CallCounter()

    private func engine(answering answer: SketchReading, readiness: ProviderReadiness = .ready) -> SketchEngine {
        let calls = calls
        return SketchEngine(provider: SketchProvider(
            id: "stub", name: "Stub", symbol: "sparkle", needsAPIKey: false,
            readiness: { readiness },
            makeInterpreter: { _ in StubInterpreter(answer: answer, calls: calls) }
        ))
    }

    private func asked(_ prompt: String) throws -> SketchRequest {
        let pill = CGRect(x: 28, y: 738, width: 337, height: 60)
        var sketch = try request([SketchSamples.box(pill, radius: 30)], local: pill)
        sketch.prompt = prompt
        return sketch
    }

    @Test func whatThePromptNamesIsWhatItBecomesWithoutAskingTheModel() async throws {
        let reading = await engine(answering: .element(.button)).read(try asked("an avatar of the user"))
        #expect(reading == .element(.avatar))
        #expect(await calls.count == 0)
    }

    @Test func aPromptThatNamesNothingIsLeftToTheModel() async throws {
        let reading = await engine(answering: .element(.image)).read(try asked("the hero for the sign up page"))
        #expect(reading == .element(.image))
        #expect(await calls.count == 1)
    }

    @Test func withoutTheModelTheShapeDecides() async throws {
        let reading = await engine(answering: .element(.image), readiness: .unavailable("Off")).read(try asked(""))
        #expect(reading == .element(.button))
    }

    @Test func aRequestedReadingCanBeAnythingThatBelongsWhereItWasDrawn() throws {
        let sketch = try asked("")
        #expect(sketch.options.first == .element(.button), "what the shape suggests comes first")
        #expect(sketch.options.contains(.element(.avatar)))
        #expect(!sketch.options.contains(.screen))
    }

    @Test func thePromptsNamesAndWordsAreFound() {
        let options = [ElementKind.button, .textField, .body, .title].map(SketchReading.element)
        #expect(SketchPrompt.reading(namedIn: "email text field", among: options) == .element(.textField))
        #expect(SketchPrompt.reading(namedIn: "Sign up button", among: options) == .element(.button))
        #expect(SketchPrompt.reading(namedIn: "something nice", among: options) == nil)
        #expect(SketchPrompt.label(in: "a button saying Sign up") == "Sign up")
        #expect(SketchPrompt.label(in: "title “Welcome back”") == "Welcome back")
        #expect(SketchPrompt.label(in: "a big picture") == nil)
    }
}
