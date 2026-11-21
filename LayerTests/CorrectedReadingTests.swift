import CoreGraphics
import Foundation
import Testing
@testable import Layer

@MainActor
private func makeStore() -> (store: DesignStore, screen: DesignScreen, undo: UndoManager) {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore(content: DesignContent())
    store.undoManager = undo
    return (store, store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1)), undo)
}

private let titleSketch = CGRect(x: 150, y: 112, width: 96, height: 40)
private let boxSketch = CGRect(x: 30, y: 300, width: 330, height: 44)

@Suite("Changing what a sketch became")
@MainActor
struct ChangedKindTests {
    @Test func anElementBecomesTheOtherKindAsIfItHadBeenReadThatWay() throws {
        let (store, screen, _) = makeStore()
        let title = try #require(store.addElement(.title, from: titleSketch, to: screen.id))
        let field = try #require(store.addElement(.textField, from: boxSketch, to: screen.id))
        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: field.id)

        let button = try #require(store.changeKind(of: ref, to: .button, sketchedAt: boxSketch))

        let (fresh, freshScreen, _) = makeStore()
        _ = fresh.addElement(.title, from: titleSketch, to: freshScreen.id)
        let expected = try #require(fresh.addElement(.button, from: boxSketch, to: freshScreen.id))
        #expect(button.kind == .button)
        #expect(button.frame == expected.frame)
        #expect(button.text == "Continue")
        #expect(store.resolve(ref)?.element == button)
        // It is the same element, in the same place among the others.
        #expect(button.id == field.id)
        #expect(store.screen(screen.id)?.elements.map(\.id) == [title.id, field.id])
    }

    @Test func wordsWrittenForItCarryOver() throws {
        let (store, screen, _) = makeStore()
        let field = try #require(store.addElement(.textField, from: boxSketch, to: screen.id))
        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: field.id)
        store.update(ref) { $0.text = "Sign in" }

        #expect(store.changeKind(of: ref, to: .button, sketchedAt: boxSketch)?.text == "Sign in")
        // A kind that shows no words drops them.
        #expect(store.changeKind(of: ref, to: .image, sketchedAt: boxSketch)?.text == "")
    }

    @Test func theChangeIsOneUndoStep() throws {
        let (store, screen, undo) = makeStore()
        let field = try #require(store.addElement(.textField, from: boxSketch, to: screen.id))
        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: field.id)

        store.changeKind(of: ref, to: .button, sketchedAt: boxSketch)
        undo.undo()

        #expect(store.resolve(ref)?.element == field)
    }

    @Test func somethingThatIsGoneIsNotChanged() throws {
        let (store, screen, _) = makeStore()
        let missing = DesignStore.ElementRef(host: .screen(screen.id), element: UUID())
        #expect(store.changeKind(of: missing, to: .button, sketchedAt: boxSketch) == nil)
    }
}

@Suite("Offering what a sketch nearly was")
@MainActor
struct KindSuggestionTests {
    private func makeModel() throws -> (model: AppModel, ref: DesignStore.ElementRef, suggestion: KindSuggestion) {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let field = try #require(model.store.addElement(.textField, from: boxSketch, to: screen.id))
        let ref = DesignStore.ElementRef(host: .screen(screen.id), element: field.id)
        let observation = try #require(SketchAnalyzer.observe(SketchSamples.strokes([SketchSamples.box(boxSketch, radius: 10)])))
        return (model, ref, KindSuggestion(ref: ref, kind: .button, sketch: boxSketch, observation: observation))
    }

    @Test func takingASuggestionChangesTheElementAndClearsIt() throws {
        let (model, ref, suggestion) = try makeModel()
        model.offer(suggestion)
        #expect(model.suggestion == suggestion)

        model.acceptSuggestion()

        #expect(model.store.resolve(ref)?.element.kind == .button)
        #expect(model.suggestion == nil)
    }

    @Test func dismissingASuggestionLeavesTheElementAsItWasRead() throws {
        let (model, ref, suggestion) = try makeModel()
        model.offer(suggestion)
        model.dismissSuggestion()
        #expect(model.store.resolve(ref)?.element.kind == .textField)
        #expect(model.suggestion == nil)
    }

    @Test func aSuggestionGoesWhenItsElementDoes() throws {
        let (model, ref, suggestion) = try makeModel()
        model.offer(suggestion)
        model.store.delete(ref)
        #expect(model.suggestion == nil)
    }
}

@Suite("Logging readings")
struct SketchReadingLogTests {
    private func logWithOneReading() async -> (log: SketchReadingLog, element: UUID) {
        let log = SketchReadingLog(fileURL: nil)
        let entry = await log.record(
            placementKind: "onScreen", existingKinds: [], existingFrames: [], screenSize: [393, 852], strokes: [],
            candidates: ["textField", "button"], scores: [0.55, 0.45], chosen: "textField", escalated: true, decidedBy: "rules"
        )
        let element = UUID()
        await log.link(element: element, toEntry: entry)
        return (log, element)
    }

    private func record(in log: SketchReadingLog, chosen: String) async -> UUID {
        await log.record(
            placementKind: "onScreen", existingKinds: [], existingFrames: [], screenSize: [393, 852], strokes: [],
            candidates: [chosen], scores: [1], chosen: chosen, escalated: false, decidedBy: "rules"
        )
    }

    /// The log on disk keeps every launch's readings, but a correction rewrote the file
    /// from this launch's readings alone, and every earlier launch's were lost (G8).
    @Test func aCorrectionKeepsEarlierLaunchesReadings() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("readings-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let earlier = SketchReadingLog(fileURL: file)
        let first = await record(in: earlier, chosen: "title")

        let now = SketchReadingLog(fileURL: file)
        let second = await record(in: now, chosen: "button")
        let element = UUID()
        await now.link(element: element, toEntry: second)
        await now.noteCorrected(element, to: "textField")

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let read = try lines.map { try JSONDecoder().decode(SketchReadingLogEntry.self, from: Data($0.utf8)) }
        #expect(read.map(\.id) == [first, second])
        try #require(read.count == 2)
        #expect(read[0].chosen == "title" && read[0].correctedAfter == nil)
        #expect(read[1].correctedTo == "textField")
    }

    @Test func changingWhatAReadingBecameIsRecordedAsItsCorrection() async {
        let (log, element) = await logWithOneReading()
        await log.noteCorrected(element, to: "button")
        #expect(await log.allEntries().first?.correctedTo == "button")
    }

    @Test func aCorrectedReadingIsExportedUnderWhatItShouldHaveBeen() async throws {
        let (log, element) = await logWithOneReading()
        await log.noteCorrected(element, to: "button")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await log.exportAsFixtures(to: directory)

        let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let fixture = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(fixture["label"] as? String == "button")
    }
}
