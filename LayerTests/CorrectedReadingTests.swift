import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// A phone screen at the canvas's origin, at scale 1, so a sketch's canvas points are its screen points: what
/// `changeKind(of:to:fallback:)` lays a node out from when it has no sketch of its own.
@MainActor
private func makeStore() -> (store: DesignStore, screen: TreeScreen.ID, undo: UndoManager) {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore()
    store.undoManager = undo
    return (store, store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1)).id, undo)
}

private let titleSketch = CGRect(x: 150, y: 112, width: 96, height: 40)
private let boxSketch = CGRect(x: 30, y: 300, width: 330, height: 44)

@Suite("Changing what a sketch became")
@MainActor
struct ChangedKindTests {
    @Test func anElementBecomesTheOtherKindAsIfItHadBeenReadThatWay() throws {
        let (store, screen, _) = makeStore()
        let title = try #require(store.sketched(.title, from: titleSketch, to: screen))
        let field = try #require(store.sketched(.textField, from: boxSketch, to: screen))

        let changed = try #require(store.changeKind(of: field.id, to: .button, fallback: boxSketch))
        let button = try #require(store.node(changed))

        let (fresh, freshScreen, _) = makeStore()
        _ = fresh.sketched(.title, from: titleSketch, to: freshScreen)
        let expected = try #require(fresh.sketched(.button, from: boxSketch, to: freshScreen))
        #expect(button.kind == .button)
        #expect(store.ownFrame(changed) == expected.frame)
        #expect(button.content.text == "Continue")
        #expect(store.node(field.id) == button)
        // It is the same element, in the same place among the others.
        #expect(changed == field.id)
        #expect(store.screenLeaves(screen).map(\.id) == [title.id, field.id])
    }

    @Test func wordsWrittenForItCarryOver() throws {
        let (store, screen, _) = makeStore()
        let field = try #require(store.sketched(.textField, from: boxSketch, to: screen))
        store.update(field.id) { $0.content.text = "Sign in" }

        #expect(store.changeKind(of: field.id, to: .button, fallback: boxSketch).flatMap { store.node($0)?.content.text } == "Sign in")
        // A kind that shows no words drops them.
        #expect(store.changeKind(of: field.id, to: .image, fallback: boxSketch).flatMap { store.node($0)?.content.text } == "")
    }

    @Test func theChangeIsOneUndoStep() throws {
        let (store, screen, undo) = makeStore()
        let added = try #require(store.sketched(.textField, from: boxSketch, to: screen))
        let field = try #require(store.node(added.id))

        store.changeKind(of: field.id, to: .button, fallback: boxSketch)
        undo.undo()

        #expect(store.node(field.id) == field)
    }

    @Test func somethingThatIsGoneIsNotChanged() throws {
        let (store, _, _) = makeStore()
        #expect(store.changeKind(of: UUID(), to: .button, fallback: boxSketch) == nil)
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
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1)).id
        let field = try #require(model.store.sketched(.textField, from: boxSketch, to: screen))
        let ref = DesignStore.ElementRef(host: .screen(screen), element: field.id)
        let observation = try #require(SketchAnalyzer.observe(SketchSamples.strokes([SketchSamples.box(boxSketch, radius: 10)])))
        return (model, ref, KindSuggestion(ref: ref, kind: .button, sketch: boxSketch, observation: observation))
    }

    @Test func takingASuggestionChangesTheElementAndClearsIt() throws {
        let (model, ref, suggestion) = try makeModel()
        model.offer(suggestion)
        #expect(model.suggestion == suggestion)

        model.acceptSuggestion()

        #expect(model.store.node(ref.element)?.kind == .button)
        #expect(model.suggestion == nil)
    }

    @Test func dismissingASuggestionLeavesTheElementAsItWasRead() throws {
        let (model, ref, suggestion) = try makeModel()
        model.offer(suggestion)
        model.dismissSuggestion()
        #expect(model.store.node(ref.element)?.kind == .textField)
        #expect(model.suggestion == nil)
    }

    @Test func aSuggestionGoesWhenItsElementDoes() throws {
        let (model, ref, suggestion) = try makeModel()
        model.offer(suggestion)
        model.store.delete(ref)
        #expect(model.suggestion == nil)
    }

    /// Taking the suggestion lays the element out again from where it was sketched. Moved,
    /// resized or turned since, or with its screen moved, taking it threw that away and
    /// could put the element off its screen (G6). The offer goes once that happens.
    @Test(arguments: ["moved", "resized", "turned", "screen moved"])
    func aSuggestionGoesOnceItsElementOrScreenIsMoved(change: String) throws {
        let (model, ref, suggestion) = try makeModel()
        model.offer(suggestion)
        guard case .screen(let screen) = ref.host else { return }
        switch change {
        case "moved": model.store.update(ref.element) { $0.frame.origin.y += 100 }
        case "resized": model.store.update(ref.element) { $0.frame.size.width -= 40 }
        case "turned": model.store.update(ref.element) { $0.rotation = 15 }
        default: model.store.updateTreeScreen(screen) { $0.origin.x += 200 }
        }
        let changed = try #require(model.store.node(ref.element))
        #expect(model.suggestion == nil)
        model.acceptSuggestion()
        #expect(model.store.node(ref.element) == changed)
    }

    /// Words put on it, as Magic Pen does just after offering, don't take the offer away.
    @Test func aSuggestionStaysWhenOnlyItsWordsChange() throws {
        let (model, ref, suggestion) = try makeModel()
        model.offer(suggestion)
        model.store.update(ref.element) { $0.content.text = "Email" }
        #expect(model.suggestion == suggestion)
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
