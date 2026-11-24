import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// What a generation or an A2UI import couldn't fix is said in the import sheet and in the generation's status
/// (spec §9; plan 6, Task 9b). Nothing is corrected, what the fix put right isn't reported, and what the person made
/// is never checked.
@Suite("What couldn't be fixed", .serialized)
@MainActor
struct UnfixedIssuesTests {
    // MARK: - Setup

    /// A column of an image 600 wide, which an iPhone, 393 wide, can't hold.
    private func wideImageRoot() -> LayerNode {
        var root = Outline.parse("title: Photos\nimage: Skyline\n", isComplete: true)
        Self.change(&root, .image) {
            $0.width = LayerNode.Sizing(.fixed)
            $0.height = LayerNode.Sizing(.fixed)
            $0.frame.size = CGSize(width: 600, height: 200)
        }
        return root
    }

    /// An A2UI column holding a title and an image 600 wide and 200 high, as Layer's look says it is.
    private func wideImageA2UI() -> Data {
        let image = ##"{"id":"photo","component":"Image","url":"","description":"Skyline","@metadata":{"extensions":{"layer":{"kind":"image","width":{"mode":"fixed"},"height":{"mode":"fixed"},"frame":[0,0,600,200]}}}}"##
        return Data("""
            {"version":"1.0","createSurface":{"surfaceId":"wide","catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}}
            {"version":"1.0","updateComponents":{"surfaceId":"wide","components":[{"id":"root","component":"Column","children":["t","photo"]},{"id":"t","component":"Text","text":"# Photos"},\(image)]}}
            """.utf8)
    }

    /// `root` as the lines of A2UI Layer exports it as.
    private func a2ui(of root: LayerNode) -> Data {
        var screen = TreeScreen(name: "Wide", origin: .zero, scale: 1, deviceID: nil)
        screen.root = root
        return A2UIExporter.document(for: screen, surfaceID: "wide")
    }

    private func makeModel() -> AppModel {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        return model
    }

    private func bench() -> (app: AppModel, feed: AsyncThrowingStream<ScreenGenerator.Update, any Error>.Continuation) {
        let app = makeModel()
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        app.screenStream = { _ in stream }
        return (app, feed)
    }

    /// Generates a screen that is written as `root`, as the generator hands it over: fixed.
    private func generate(_ root: LayerNode) async throws -> AppModel {
        let (app, feed) = bench()
        app.generateScreen(from: "a photo screen")
        var fixed = root
        _ = TreeValidator.fixGenerated(&fixed)
        feed.yield(.screen(fixed))
        feed.finish()
        await app.waitForGeneration()
        return app
    }

    private static func change(_ node: inout LayerNode, _ kind: ElementKind, _ edit: (inout LayerNode) -> Void) {
        if node.kind == kind { edit(&node) }
        for index in node.children.indices { change(&node.children[index], kind, edit) }
    }

    private func find(_ id: UUID, in node: LayerNode) -> LayerNode? {
        node.id == id ? node : node.children.lazy.compactMap { find(id, in: $0) }.first
    }

    private func ids(of node: LayerNode, where isIt: (LayerNode) -> Bool) -> [UUID] {
        (isIt(node) ? [node.id] : []) + node.children.flatMap { ids(of: $0, where: isIt) }
    }

    // MARK: - Tests

    @Test func anImportThatRunsOffTheScreenSaysSo() async throws {
        let model = makeModel()

        let report = await model.importA2UI(wideImageA2UI())

        let screen = try #require(report.screens.first)
        let root = try #require(model.store.root(of: screen))
        let image = try #require(ids(of: root) { $0.kind == .image }.first)
        #expect(report.unfixed[.runsOffTheScreen]?.contains(image) == true, "\(report.unfixed)")
        #expect(report.needsShowing)
    }

    @Test func aGenerationSaysWhatItCouldntFix() async throws {
        let app = try await generate(wideImageRoot())

        #expect(app.generation?.phase == .finished)
        #expect(app.generation?.unfixed == 1, "\(String(describing: app.generation?.unfixedIssues))")
        let generation = try #require(app.generation)
        #expect(GenerationStatus.finishedText(generation) == "Finished. 1 thing runs off the screen.")
    }

    @Test func theLeftOutWordsComeFirst() {
        var generation = AppModel.ScreenGeneration(screenID: UUID(), description: "")
        generation.leftOut = 2
        generation.unfixedIssues = [.runsOffTheScreen: [UUID(), UUID()], .controlTooSmall: [UUID()]]
        #expect(generation.unfixed == 3)
        #expect(GenerationStatus.finishedText(generation)
            == "Finished. 2 parts couldn't be brought in. 2 things run off the screen and 1 control is too small.")
    }

    @Test func whatWasFixedIsNotReported() async throws {
        var root = Outline.parse("title: Sign in\nbutton: Go\n", isComplete: true)
        Self.change(&root, .button) { $0.frame.size.height = 30; $0.height = LayerNode.Sizing(.fixed) }

        let app = try await generate(root)
        let generation = try #require(app.generation)
        #expect(generation.unfixed == 0)
        #expect(GenerationStatus.finishedText(generation) == "Wrote 2 elements")
        let written = try #require(app.store.root(of: generation.screenID))
        let button = try #require(ids(of: written) { $0.kind == .button }.first.flatMap { id in find(id, in: written) })
        #expect(button.frame.height >= 44, "raised to 44 by the fix")

        let imported = await makeModel().importA2UI(a2ui(of: root))
        #expect(imported.unfixed.isEmpty, "\(imported.unfixed)")
    }

    @Test func aHandMadeScreenIsNeverChecked() async throws {
        let model = makeModel()
        // An image dragged half off a screen the person made.
        var mine = TreeScreen(name: "Mine", origin: .zero, scale: 1, deviceID: nil)
        var image = LayerNode(kind: .image)
        image.frame = CGRect(x: 300, y: 100, width: 200, height: 100)
        mine.root.children = [image]
        let handMade = try #require(model.store.addLaidOutScreens([mine]).first)
        let before = try #require(model.store.root(of: handMade))

        // A generation and an import elsewhere say nothing of it.
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        model.screenStream = { _ in stream }
        model.generateScreen(from: "a sign-in screen")
        feed.yield(.screen(Outline.parse("title: Sign in\nbutton: Go\n", isComplete: true)))
        feed.finish()
        await model.waitForGeneration()
        let generation = try #require(model.generation)
        #expect(generation.unfixed == 0)
        #expect(GenerationStatus.finishedText(generation) == "Wrote 2 elements")
        let report = await model.importA2UI(a2ui(of: Outline.parse("title: Hi\n", isComplete: true)))
        #expect(report.unfixed.isEmpty)
        #expect(!report.needsShowing)

        // Nor does one on the same screen: what the person puts half off a generated screen while it is written.
        let (app, feedTwo) = bench()
        app.generateScreen(from: "a photo screen")
        let screen = try #require(app.generation?.screenID)
        var dragged = LayerNode(kind: .image)
        dragged.frame = CGRect(x: 300, y: 100, width: 200, height: 100)
        app.beforeGenerationCommit = { app.store.add(dragged, to: .screen(screen)); app.beforeGenerationCommit = nil }
        feedTwo.yield(.screen(Outline.parse("title: Sign in\n", isComplete: true)))
        feedTwo.yield(.screen(Outline.parse("title: Sign in\nbutton: Go\n", isComplete: true)))
        feedTwo.finish()
        await app.waitForGeneration()
        #expect(app.store.root(of: screen)?.children.contains { $0.id == dragged.id } == true)
        #expect(app.generation?.unfixed == 0, "\(String(describing: app.generation?.unfixedIssues))")

        #expect(model.store.root(of: handMade) == before, "nothing was corrected")
    }
}
