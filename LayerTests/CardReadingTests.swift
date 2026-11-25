import CoreGraphics
import Foundation
import Testing
@testable import Layer

// A drawn outline round things already on the screen can be a card. These tests name the
// card's constants and never their values, so that tuning them (plan 5 Task 8) changes only
// `SketchConventions`. `theCorpusReadsAsBefore` pins every fixture's reading to
// `Goldens/SketchReadings.txt`, recorded before the card rule existed. To record it again, run
// this suite with the environment variable TEST_RUNNER_LAYER_RECORD_READINGS set to a folder on
// this Mac, then copy `SketchReadings.txt` from there into `Goldens/`.

private final class BundleMarker {}

private struct CardStub: SketchInterpreter {
    let answer: SketchReading
    func read(_ request: SketchRequest) async throws -> SketchReading { answer }
    func suggestTitle(for board: String) async throws -> String { "Board" }
}

private func request(_ script: String, existing: [ExistingElement] = [], size: CGSize = DeviceFrame.iPhone.size) throws -> SketchRequest {
    let paths = try StrokeScript.parse(script)
    let observation = try #require(SketchAnalyzer.observe(SketchSamples.strokes(paths)))
    return SketchRequest(
        observation: observation,
        placement: .onScreen(local: observation.bounds, existing: existing, size: size),
        strokes: paths
    )
}

private func existing(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> ExistingElement {
    ExistingElement(kind: kind, frame: CGRect(x: x, y: y, width: width, height: height))
}

private func score(of reading: SketchReading, in request: SketchRequest) -> Double? {
    request.scoredReadings.first { $0.reading == reading }?.score
}

private func line(for fixture: SketchFixture) -> String {
    guard let request = fixture.makeRequest() else { return "\(fixture.id): unobserved" }
    let scored = request.scoredReadings
    let top = scored.first.map { SketchPrompt.name(for: $0.reading) } ?? "none"
    let candidates = scored.map { "\(SketchPrompt.name(for: $0.reading)) \(String(format: "%.4f", $0.score))" }.joined(separator: ", ")
    return "\(fixture.id): \(top) | \(candidates) | \(RuleInterpreter().isCloseCall(request) ? "close" : "clear")"
}

@Suite("The card reading")
struct CardReadingTests {
    private static let title = existing(.title, 96, 120, 200, 40)
    private static let body = existing(.body, 20, 170, 353, 40)
    private static let outline = "box 10 100 373 130 16"

    @Test func theCorpusReadsAsBefore() throws {
        let directory = try #require(Bundle(for: BundleMarker.self).resourceURL)
        let fixtures = try SketchFixtureCorpus.load(from: directory)
        #expect(fixtures.count == 156)
        let written = fixtures.map(line(for:)).joined(separator: "\n") + "\n"
        if let folder = ProcessInfo.processInfo.environment["LAYER_RECORD_READINGS"] {
            try written.write(toFile: (folder as NSString).appendingPathComponent("SketchReadings.txt"), atomically: true, encoding: .utf8)
            return
        }
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "SketchReadings", withExtension: "txt"))
        let recorded = try String(contentsOf: url, encoding: .utf8)
        let (now, then) = (written.components(separatedBy: "\n"), recorded.components(separatedBy: "\n"))
        #expect(now.count == then.count)
        for (line, expected) in zip(now, then) { #expect(line == expected) }
        #expect(!written.contains("card"), "no fixture has anything enclosed, so none reads as a card")
    }

    @Test func anOutlineRoundTwoThingsIsACard() throws {
        let with = try request(Self.outline, existing: [Self.title, Self.body])
        let without = try request(Self.outline, existing: [])
        let scored = with.scoredReadings
        #expect(scored.first?.reading == .element(.card))
        #expect(scored.first?.score == SketchConventions.cardAroundSeveral)
        for other in scored.dropFirst() {
            let before = try #require(score(of: other.reading, in: without))
            #expect(other.score <= SketchConventions.cardElsewhere * before + 1e-9, "\(other.reading)")
        }
        #expect(scored.dropFirst().map { SketchPrompt.name(for: $0.reading) }.sorted() == without.scoredReadings.map { SketchPrompt.name(for: $0.reading) }.sorted())
        #expect(!RuleInterpreter().isCloseCall(with))
    }

    @Test func anOutlineRoundOneThingMightBeACard() throws {
        let pill = "pill 60 300 260 56"
        let text = existing(.text, 100, 312, 160, 32)
        let with = try request(pill, existing: [text])
        let without = try request(pill, existing: [])
        #expect(with.scoredReadings.first?.reading == .element(.button))
        #expect(score(of: .element(.card), in: with) == SketchConventions.cardAroundOne)
        for other in without.scoredReadings {
            #expect(score(of: other.reading, in: with) == other.score)
        }
    }

    @Test func nothingInsideMeansNoCard() throws {
        let far = existing(.title, 20, 400, 200, 40)
        let with = try request(Self.outline, existing: [far])
        let without = try request(Self.outline, existing: [])
        #expect(with.scoredReadings == without.scoredReadings)
        #expect(score(of: .element(.card), in: with) == nil)
    }

    @Test func aThingHalfInsideIsNotInside() throws {
        // 50% of the body's area is within the outline (y from 100 to 230).
        let straddling = existing(.body, 20, 210, 353, 40)
        let sketch = try request(Self.outline, existing: [straddling])
        #expect(score(of: .element(.card), in: sketch) == nil)
    }

    @Test func aCardIsNotInTheModelsInstructions() {
        #expect(!SketchPrompt.hintOrder.contains(.card))
        #expect(ElementKind.card.spec.sketchHint == nil)
    }
}

@Suite("What a reading carries")
@MainActor
struct OutcomeCarriesTests {
    private func engine(answering answer: SketchReading, handwriting: String? = nil) -> SketchEngine {
        let engine = SketchEngine(provider: SketchProvider(
            id: "stub", name: "Stub", symbol: "sparkle", needsAPIKey: false,
            readiness: { .ready },
            makeInterpreter: { _ in CardStub(answer: answer) }
        ))
        engine.readHandwriting = { _ in handwriting }
        return engine
    }

    @Test func anOutcomeSaysHowSureAndWhoDecided() async throws {
        // A clean pill: read by the rules.
        let pill = try request("pill 28 738 337 60")
        let byRules = await engine(answering: .element(.textField)).outcome(for: pill)
        #expect(byRules.reading == .element(.button))
        #expect(byRules.confidence == pill.scoredReadings[0].score)
        #expect(byRules.decidedBy == .rules)

        // A wave, with a word read out of it.
        let wave = try request("wave 60 112 200 40 4")
        let written = await engine(answering: .element(.body), handwriting: "Sign in").outcome(for: wave)
        #expect(written.recognizedText == "Sign in")
        #expect([.element(.title), .element(.body), .element(.text)].contains(written.reading))
        #expect(written.decidedBy == .handwriting)

        // A close call, answered by the provider.
        let close = try request("box 30 740 330 56 12")
        #expect(RuleInterpreter().isCloseCall(close))
        let answered = await engine(answering: .element(.button)).outcome(for: close)
        #expect(answered.reading == .element(.button))
        #expect(answered.decidedBy == .model)
        #expect(answered.confidence == score(of: .element(.button), in: close))

        // A drawing asked for by name.
        var asked = try request("box 30 300 100 40 8")
        asked.prompt = "a toggle"
        let named = await engine(answering: .element(.button)).outcome(for: asked)
        #expect(named.reading == .element(.toggle))
        #expect(named.decidedBy == .asked)
        #expect(named.confidence == 1)
    }
}
