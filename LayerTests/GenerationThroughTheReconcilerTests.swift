import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// A generated screen written through the reconciler: each streamed outline merged by key over the screen as it is,
/// laid out off the main actor and committed once, its ids kept and the person's edits left as they made them
/// (plan 3, Task 4).
@Suite("Generation through the reconciler", .serialized)
@MainActor
struct GenerationThroughTheReconcilerTests {
    /// A design whose generations are written by the test, a line at a time (the lifecycle suite's feed).
    private func bench() -> (app: AppModel, feed: AsyncThrowingStream<ScreenGenerator.Update, any Error>.Continuation) {
        let app = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.store.undoManager = undo
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        app.screenStream = { _ in stream }
        return (app, feed)
    }

    private static func written(_ text: String) -> ScreenGenerator.Update {
        .screen(Outline.parse(text, isComplete: true))
    }

    private func all(_ node: LayerNode) -> [LayerNode] { [node] + node.children.flatMap(all) }

    /// The leaves under `node`, in reading order.
    private func leaves(_ node: LayerNode) -> [LayerNode] {
        node.children.flatMap { $0.isContainer ? leaves($0) : [$0] }
    }

    /// Feeds `text` and waits until the screen holds `count` leaves.
    private func feed(_ text: String, until count: Int, on screen: TreeScreen.ID, of app: AppModel,
                      _ feed: AsyncThrowingStream<ScreenGenerator.Update, any Error>.Continuation) async -> Bool {
        feed.yield(Self.written(text))
        return await eventually(within: .seconds(10)) { app.store.root(of: screen)?.leafCount == count }
    }

    #if DEBUG
    @Test func eachUpdateIsOneCommitLaidOutOffTheMainActor() async throws {
        let (app, feed) = bench()
        app.generateScreen(from: "a sign-in screen")
        let screen = try #require(app.generation?.screenID)
        let rootID = try #require(app.store.root(of: screen)?.id)
        let laidOut = LayoutEngine.timesLaidOut(rootID)

        let updates = ["title: Sign in\n", "title: Sign in\ntext field: Email\n", "title: Sign in\ntext field: Email\nbutton: Go\n"]
        for (index, text) in updates.enumerated() {
            #expect(await self.feed(text, until: index + 1, on: screen, of: app, feed))
        }

        #expect(GenerationWork.commits(on: screen) == 3)
        let ahead = GenerationWork.layoutsAhead(of: rootID)
        #expect(ahead.total == 3)
        #expect(ahead.onMainThread == 0)
        // The layouts ahead, and none in the commits.
        #expect(LayoutEngine.timesLaidOut(rootID) == laidOut + 3)
        feed.finish()
        await app.waitForGeneration()
    }
    #endif

    @Test func everyIDOutlivesTheUpdatesAfterIt() async throws {
        let (app, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)

        let lines = ["title: Settings\n", "text field: Name\n", "card:\n  text: Notifications\n  toggle [on]\n",
                     "row: text: Wi-Fi | toggle\n", "button: Save\n"]
        var text = ""
        var ids: [Set<UUID>] = []
        for line in lines {
            text += line
            let count = Outline.parse(text, isComplete: true).leafCount
            #expect(await self.feed(text, until: count, on: screen, of: app, feed))
            let root = try #require(app.store.root(of: screen))
            ids.append(Set(all(root).map(\.id)))
        }

        #expect(ids.count == 5)
        for k in ids.indices.dropLast() {
            #expect(ids[k].isSubset(of: ids[k + 1]), "update \(k + 1)'s ids should all be there after update \(k + 2)")
        }
        feed.finish()
        await app.waitForGeneration()
    }

    #if DEBUG
    @Test func anEditMadeWhileAnUpdateIsLaidOutIsKept() async throws {
        let (app, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        #expect(await self.feed("title: Settings\n", until: 1, on: screen, of: app, feed))
        let root = try #require(app.store.root(of: screen))
        let title = try #require(leaves(root).first)

        // The person retypes the title while the next update is laid out.
        app.beforeGenerationCommit = { app.store.update(title.id) { $0.content.text = "Mine" } }
        let laidOut = LayoutEngine.timesLaidOut(root.id)
        #expect(await self.feed("title: Settings\nbutton: Save\n", until: 2, on: screen, of: app, feed))
        app.beforeGenerationCommit = nil

        let after = try #require(app.store.root(of: screen))
        #expect(leaves(after).map(\.kind) == [.title, .button])
        #expect(leaves(after).first?.id == title.id)
        #expect(leaves(after).first?.content.text == "Mine")
        #expect(leaves(after).last?.content.text == "Save")
        // Once ahead, once for the edit's own change, and once in the commit, which merged again over the edited
        // screen.
        #expect(LayoutEngine.timesLaidOut(root.id) == laidOut + 3)
        feed.finish()
        await app.waitForGeneration()
    }
    #endif

    @Test func aGeneratedScreenIsAColumnOnItsDevice() async throws {
        let (app, feed) = bench()
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        #expect(await self.feed("title: Settings\n", until: 1, on: screen, of: app, feed))

        let root = try #require(app.store.root(of: screen))
        guard case .stack(let stack) = root.resolvedLayout else {
            Issue.record("the root should be a stack, not \(root.resolvedLayout)")
            return
        }
        #expect(stack.axis == .vertical)
        #expect(stack.spacing == 24)
        let title = try #require(app.store.screen(screen)?.elements.first)
        #expect(title.kind == .title)
        #expect(title.frame.minY == DeviceFrame.iPhone.safeTop + 20)
        feed.finish()
        await app.waitForGeneration()
    }

    @Test func aDesignsTokensReachTheGeneratedScreen() async throws {
        let app = AppModel(document: LayerDocument())
        app.store.updateCanvas { $0.tokens.rhythm = [4, 10, 20, 40] }
        // The model's answer is read with the tokens it was asked with.
        app.screenStream = { request in
            AsyncThrowingStream { feed in
                var outline = OutlineStream(tokens: request.tokens)
                if let root = outline.take("title: Settings\nbutton: Save\n", isComplete: true) { feed.yield(.screen(root)) }
                feed.finish()
            }
        }
        app.generateScreen(from: "a settings screen")
        let screen = try #require(app.generation?.screenID)
        await app.waitForGeneration()

        let root = try #require(app.store.root(of: screen))
        #expect(root.leafCount == 2)
        guard case .stack(let stack) = root.resolvedLayout else {
            Issue.record("the root should be a stack, not \(root.resolvedLayout)")
            return
        }
        #expect(stack.spacing == 20)
    }

    /// Outside a generation's edit, a write is one change of its own, so one undo step; and a screen that is gone
    /// takes none.
    @Test func aWriteWithoutAnEditIsAStepOfItsOwn() async throws {
        let app = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.store.undoManager = undo
        let screen = app.store.addScreen(TreeScreen(name: "Settings", origin: .zero, scale: 1, deviceID: nil,
                                                    root: Outline.parse("", isComplete: true)))
        undo.removeAllActions()
        let writer = GenerationWriter(screenID: screen)

        #expect(await writer.write(Outline.parse("title: Settings\nbutton: Save", isComplete: true), to: app.store, in: nil))
        #expect(app.store.root(of: screen)?.leafCount == 2)
        undo.undo()
        #expect(app.store.root(of: screen)?.leafCount == 0)
        #expect(!undo.canUndo)

        app.store.deleteScreen(screen)
        #expect(await writer.write(Outline.parse("title: Settings", isComplete: true), to: app.store, in: nil) == false)
    }

    @Test func anOpenerAloneWaitsForItsFirstLine() throws {
        var outline = OutlineStream(tokens: .standard)
        let firstTaken = outline.take("title: A\n", isComplete: false)
        let first = try #require(firstTaken)
        #expect(first.leafCount == 1)
        let opener = outline.take("title: A\ncard:\n", isComplete: false)
        #expect(opener == nil)
    }
}
