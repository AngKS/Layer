import CoreGraphics
import Foundation
import Testing
@testable import Layer

private final class BuildBundleMarker {}

/// Siri's Build Screen: the outline or A2UI JSON lays a new screen out off the main actor, or is merged into an
/// existing screen by a reconciler that adopts it, and either way is one undo step (plan 3, Task 11; calls 7 and 11).
@MainActor
@Suite struct BuildScreenTests {
    private func makeModel() -> (AppModel, UndoManager) {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        return (model, undo)
    }

    private func leaves(of node: LayerNode) -> [LayerNode] {
        node.children.flatMap { $0.isContainer ? leaves(of: $0) : [$0] }
    }

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle(for: BuildBundleMarker.self).url(forResource: name, withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func build(_ layout: String, on target: TreeScreen.ID? = nil, name: String? = nil, in model: AppModel) async throws
        -> TreeScreen.ID {
        try await BuildScreenIntent.build(layout, on: target, name: name, device: .iPhone, in: model, undoManager: nil)
    }

    @Test func aNewScreenIsBuiltFromAnOutline() async throws {
        let (model, undo) = makeModel()

        let id = try await build("title: Hi\ncard:\n  text: A\n  body: B\nbutton: Go", in: model)

        let root = try #require(model.store.root(of: id))
        guard case .stack(let stack) = root.resolvedLayout else { Issue.record("the root is a stack"); return }
        #expect(stack.axis == .vertical)
        #expect(leaves(of: root).map(\.kind) == [.title, .text, .body, .button])
        let card = try #require(root.children.first { $0.kind == .card })
        #expect(card.children.map(\.kind) == [.text, .body])
        #expect(model.store.tree.screens.map(\.id) == [id])
        undo.undo()
        #expect(model.store.tree.screens.isEmpty)
        #expect(!undo.canUndo)
    }

    @Test func aNewScreenIsBuiltFromA2UI() async throws {
        let (model, undo) = makeModel()

        let id = try await build(try fixture("a2ui-scaffold-simple-login-form"), in: model)

        let root = try #require(model.store.root(of: id))
        #expect(leaves(of: root).map(\.kind) == [.title, .textField, .textField, .button])
        undo.undo()
        #expect(model.store.tree.screens.isEmpty)
    }

    @Test func aNewScreenTakesAGivenNameOverTheSurfacesOwn() async throws {
        let (model, _) = makeModel()
        let named = """
            {"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json","metadata":{"extensions":{"layer":{"name":"Mine","deviceID":"ipad"}}}}}
            {"version":"1.0","updateComponents":{"surfaceId":"s","components":[{"id":"root","component":"Text","text":"Hi"}]}}
            """

        let fromSurface = try await build(named, in: model)
        let given = try await build(named, name: "Mine too", in: model)

        #expect(model.store.tree.screens.first { $0.id == fromSurface }?.name == "Mine")
        #expect(model.store.tree.screens.first { $0.id == given }?.name == "Mine too")
        #expect(model.store.tree.screens.first { $0.id == fromSurface }?.deviceID == nil, "Siri's own device parameter decides")
    }

    @Test func rebuildingKeepsWhatWasBuiltAndWhatWasAddedByHand() async throws {
        let (model, undo) = makeModel()
        let id = try await build("title: A\nbutton: Go", in: model)
        let built = try #require(model.store.root(of: id))
        let section = try #require(built.children.first)
        let title = try #require(section.children.first { $0.kind == .title })
        let button = try #require(section.children.first { $0.kind == .button })
        var hand = LayerNode(kind: .text)
        hand.content.text = "Mine"
        #expect(model.store.add(hand, to: .screen(id)))
        let steps = undo.canUndo
        #expect(steps)

        _ = try await build("title: B\nbutton: Go\ntext: More", on: id, in: model)

        let root = try #require(model.store.root(of: id))
        let rebuilt = try #require(root.children.first)
        #expect(rebuilt.id == section.id)
        let newTitle = try #require(rebuilt.children.first { $0.kind == .title })
        #expect(newTitle.id == title.id)
        #expect(newTitle.content.text == "B")
        #expect(rebuilt.children.first { $0.kind == .button }?.id == button.id)
        #expect(rebuilt.children.contains { $0.kind == .text && $0.content.text == "More" })
        #expect(root.children.map(\.id) == [section.id, hand.id], "H is still just after the section")
        var kept = try #require(root.children.last)
        var original = hand
        kept.frame = .zero
        original.frame = .zero
        #expect(kept.id == original.id)
        #expect(kept.content == original.content && kept.kind == original.kind && kept.style == original.style)

        undo.undo()
        let back = try #require(model.store.root(of: id))
        #expect(back.children.first?.children.first { $0.kind == .title }?.content.text == "A")
        #expect(!leaves(of: back).contains { $0.content.text == "More" })
        #expect(back.children.map(\.id) == [section.id, hand.id])
    }

    @Test func rebuildingIsLaidOutForTheScreensOwnDeviceNotSiris() async throws {
        let (model, _) = makeModel()
        let id = try await build("title: A", in: model)

        let rootID = try #require(model.store.root(of: id)?.id)
        _ = try await BuildScreenIntent.build("title: B\nbutton: Go", on: id, name: nil, device: DeviceFrame.named("ipad"), in: model, undoManager: nil)

        let screen = try #require(model.store.tree.screens.first { $0.id == id })
        #expect(screen.deviceID == nil)
        #expect(screen.root.frame.size == DeviceFrame.iPhone.size)
        let widest = leaves(of: screen.root).map(\.frame.maxX).max() ?? 0
        #expect(widest <= DeviceFrame.iPhone.size.width, "the layout is the iPhone's, not the iPad's")
        #if DEBUG
        let ahead = GenerationWork.layoutsAhead(of: rootID)
        #expect(LayoutEngine.timesLaidOut(rootID) == ahead.total, "the commit laid nothing out again: the layout ahead was the right one")
        #endif
    }

    @Test func rebuildingALockedScreenIsRefused() async throws {
        let (model, _) = makeModel()
        let id = try await build("title: A", in: model)
        model.store.updateScreen(id) { $0.isLocked = true }
        let before = model.store.content

        await #expect(throws: LayerIntentError.self) { _ = try await self.build("title: B", on: id, in: model) }

        #expect(model.store.content == before)
    }

    @Test func nothingToBuildIsRefused() async throws {
        let (model, undo) = makeModel()

        do {
            _ = try await build("   \n---\n", in: model)
            Issue.record("an outline with no leaves should be refused")
        } catch let error as LayerIntentError {
            #expect(String(localized: error.localizedStringResource) == String(localized: LayerIntentError.invalidBlueprint.localizedStringResource))
        }

        let rootless = """
            {"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}}
            {"version":"1.0","updateComponents":{"surfaceId":"s","components":[{"id":"t","component":"Text","text":"Hi"}]}}
            """
        do {
            _ = try await build(rootless, in: model)
            Issue.record("A2UI with no root should be refused")
        } catch let error as BuildScreenError {
            guard case .nothingInA2UI(let message) = error else { Issue.record("wrong case"); return }
            #expect(message.contains("root"))
            #expect(error.errorDescription == message)
        }
        #expect(model.store.tree.screens.isEmpty)
        #expect(!undo.canUndo)
    }

    #if DEBUG
    @Test func aBuildLaysOutOffTheMainActor() async throws {
        let (model, _) = makeModel()

        let id = try await build("title: A\nbutton: Go", in: model)
        let newRoot = try #require(model.store.root(of: id)?.id)
        let fresh = GenerationWork.layoutsAhead(of: newRoot)
        #expect(fresh.total >= 1)
        #expect(fresh.onMainThread == 0)

        let before = GenerationWork.layoutsAhead(of: newRoot)
        _ = try await build("title: B\nbutton: Go\ntext: More", on: id, in: model)
        let after = GenerationWork.layoutsAhead(of: newRoot)
        #expect(after.total == before.total + 1)
        #expect(after.onMainThread == 0)
    }
    #endif

    @Test func shortcutsWrittenForTheBlueprintStillBuild() async throws {
        let (model, _) = makeModel()

        let id = try await build("""
            heading: Settings

            row: button: Cancel | button: Done [blue, bold, radius 12]
            ---
            body: Tap a row to change it [text #333333, 15pt]
            """, in: model)

        let root = try #require(model.store.root(of: id))
        let all = leaves(of: root)
        #expect(all.map(\.kind) == [.title, .button, .button, .body])
        #expect(all[2].style.tint == ColourWords.named["blue"])
    }
}
