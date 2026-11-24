import AppIntents
import CoreGraphics
import Foundation
import Testing
@testable import Layer

// Siri reads the tree (plan 6, Task 3): a design's snapshot holds its tree, Siri's elements are its leaves under the ids
// they always had, a container is invisible to Siri, and Get Design Layout writes today's JSON from the tree.
//
// `todaysJSONIsUnchangedWithoutContainers` compares the JSON with `Goldens/DesignLayout-sketch.json`, recorded from the
// writer as it was before this task (F9), except in one value: the canvas's `codeLayout` is "stack" where that writer
// wrote "structure", the value main wrote and Update Canvas Settings takes (`theCodeLayoutIsWrittenAsItsOption`). To
// record it again, run this suite with the environment variable TEST_RUNNER_LAYER_RECORD_LAYOUT set to a folder on this
// Mac, then copy the file written there into `Goldens/`.

private final class SiriOnTheTreeBundleMarker {}

@Suite("Siri on the tree")
@MainActor
struct SiriOnTheTreeTests {
    private func snapshot(_ login: TreeFixture.Login) throws -> DesignSnapshot {
        try #require(DesignActions.snapshot(of: login.model))
    }

    /// The entity whose id ends with a node's uuid.
    private func entity(_ node: UUID, in elements: [ElementEntity]) throws -> ElementEntity {
        try #require(elements.first { $0.id.hasSuffix(node.uuidString) })
    }

    private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    @Test func elementEntitiesAreLeavesOnly() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let elements = try snapshot(login).elements

        #expect(elements.map { $0.kind } == [.title, .text, .body, .text, .toggle, .stickyNote])
        let leaves = [login.title, login.about, login.body, login.label, login.toggle, login.note]
        #expect(elements.count == leaves.count)
        for (element, leaf) in zip(elements, leaves) {
            #expect(element.id.hasSuffix(leaf.uuidString))
        }
        #expect(!elements.contains { $0.id.hasSuffix(login.card.uuidString) || $0.id.hasSuffix(login.row.uuidString) })
    }

    @Test func anEntityIDKeepsItsForm() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let elements = try snapshot(login).elements
        let about = try entity(login.about, in: elements), note = try entity(login.note, in: elements)

        #expect(about.id == "\(login.designID)|\(login.screen.uuidString)|\(login.about.uuidString)")
        #expect(note.id == "\(login.designID)|canvas|\(login.note.uuidString)")
        let parsedAbout = try #require(EntityKey.parseElement(about.id))
        #expect(parsedAbout.design == login.designID)
        #expect(parsedAbout.ref == DesignStore.ElementRef(host: .screen(login.screen), element: login.about))
        let parsedNote = try #require(EntityKey.parseElement(note.id))
        #expect(parsedNote.design == login.designID)
        #expect(parsedNote.ref == DesignStore.ElementRef(host: .canvas, element: login.note))
    }

    @Test func aSelectedContainerIsInvisibleToSiri() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model
        let elements = try snapshot(login).elements

        model.selection = .element(try #require(model.store.ref(of: login.card)))
        #expect(DesignActions.selectedLeaf(in: model) == nil)
        #expect(DesignActions.suggested(elements, in: model).first?.ref?.element == login.title, "the title, as listed")

        model.selection = .element(try #require(model.store.ref(of: login.about)))
        #expect(DesignActions.selectedLeaf(in: model)?.node.id == login.about)
        #expect(DesignActions.suggested(elements, in: model).first?.ref?.element == login.about)
    }

    @Test func lockedByAnAncestorIsLocked() throws {
        let login = TreeFixture.loginWithACardAndARow()
        login.model.store.update(login.card) { $0.isLocked = true }
        let elements = try snapshot(login).elements

        #expect(try entity(login.about, in: elements).isLocked == true)
        let ref = try #require(login.model.store.ref(of: login.about))
        let error = #expect(throws: LayerIntentError.self) { try DesignActions.requireUnlocked(ref, in: login.model) }
        #expect(error.map { if case .locked = $0 { true } else { false } } == true)
        #expect(try entity(login.title, in: elements).isLocked == false)
    }

    @Test func aScreensElementsAreItsLeaves() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let screen = try #require(try snapshot(login).screens.first { $0.screenID == login.screen })

        #expect(screen.elementCount == 5)
        // Top to bottom, as today: the toggle's 320 comes before the label's 324 (F7).
        #expect(screen.summary == "title “Welcome”, text “About me”, body “Designing better experiences.”, toggle, text “Wi-Fi”")
    }

    @Test func aCustomDevicesScreenSaysItsName() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let kioskID = store.addCustomDevice(.custom(name: "Kiosk", size: CGSize(width: 1080, height: 1920), family: .other))
        let kiosk = try #require(store.tree.settings.customDevices.first { $0.id == kioskID })
        let lobby = store.addFreeScreen([], name: "Lobby", device: kiosk, origin: CGPoint(x: 500, y: 0))
        let screens = try snapshot(login).screens

        #expect(screens.first { $0.screenID == lobby }?.deviceName == "Kiosk")
        #expect(screens.first { $0.screenID == login.screen }?.deviceName == "Phone")
    }

    @Test func onscreenEntitiesAreLeavesAtTheirViewFrames() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model
        let view = CGRect(origin: .zero, size: model.canvasSize)
        func shown() -> [AppEntityUIElement] {
            let top = model.onscreenEntities(wantsSelected: false, visible: [view])
            return top + top.flatMap(\.subelements)
        }
        func bounds(of node: UUID) -> CGRect? {
            shown().first { $0.identifier.identifier.hasSuffix(node.uuidString) }?.bounds
        }

        #expect(!shown().contains {
            $0.identifier.identifier.hasSuffix(login.card.uuidString) || $0.identifier.identifier.hasSuffix(login.row.uuidString)
        })
        #expect(bounds(of: login.about) == CGRect(x: 36, y: 156, width: 200, height: 24))

        // The box round its turned shape.
        model.store.update(login.card) { $0.rotation = 90 }
        let turned = try #require(bounds(of: login.about))
        #expect(close(turned, CGRect(x: 236.5, y: 59.5, width: 24, height: 200)), "\(turned)")
    }

    @Test func aClosedDesignIsReadFromItsFile() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let open = try snapshot(login).elements.map(\.id)
        let url = try #require(login.model.fileURL)
        login.model.close()

        let summary = try #require(DesignLibrary.read(url))
        #expect(summary.id == login.designID)
        let read = try #require(DesignActions.snapshots(with: [summary]).first { $0.id == login.designID })
        #expect(read.isRead)
        #expect(read.elements.map(\.id) == open)
    }

    /// The Shortcuts contract before containers are written: every key and value as the writer gave them (F9). Task 4
    /// replaces it with `todaysKeysKeepTheirValues`, as its new keys break exact equality.
    @Test func todaysJSONIsUnchangedWithoutContainers() throws {
        let bundle = Bundle(for: SiriOnTheTreeBundleMarker.self)
        let fixture = try #require(bundle.url(forResource: "design-sketch", withExtension: "json"))
        var content = try TreeManifest.decode(try Data(contentsOf: fixture)).content
        TreeRules.apply(to: &content, after: nil)
        let json = DesignLayoutWriter.json(for: DesignSnapshot(id: "local:Sketch.layer", name: "Sketch", content: content, modified: nil))

        if let folder = ProcessInfo.processInfo.environment["LAYER_RECORD_LAYOUT"] {
            try json.write(to: URL(fileURLWithPath: folder).appendingPathComponent("DesignLayout-sketch.json"), atomically: true,
                           encoding: .utf8)
            return
        }
        let golden = try #require(bundle.url(forResource: "DesignLayout-sketch", withExtension: "json"))
        #expect(json == (try String(contentsOf: golden, encoding: .utf8)))
    }

    /// The code layout is written as the option Update Canvas Settings takes, so that a shortcut can hand it back:
    /// "stack" for the structure, as before the layout was renamed (plan 3's carry, the coordinator's ruling).
    @Test func theCodeLayoutIsWrittenAsItsOption() throws {
        let login = TreeFixture.loginWithACardAndARow()
        func written() throws -> String? {
            let json = DesignLayoutWriter.json(for: try snapshot(login))
            let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return (root["canvas"] as? [String: Any])?["codeLayout"] as? String
        }

        #expect(try written() == "stack")
        #expect(CodeLayoutOption(rawValue: try #require(try written()))?.layout == .structure)
        login.model.store.updateCanvas { $0.code.layout = .absolute }
        #expect(try written() == "absolute")
        #expect(CodeLayoutOption(rawValue: try #require(try written()))?.layout == .absolute)
    }

    /// Reading the design for Siri lowers nothing (F18). Counted for the fixture's own screen, so that other suites'
    /// designs lowered meanwhile don't add to it. Its lowering lines are retired in Task 11 under (s).
    @Test func readingDoesNotLower() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store

        // After a change through a tree verb, a read of the projection lowers the design: the counter is live.
        store.update(login.title) { $0.content.text = "Hello" }
        let live = TreeProjection.lowerings(of: login.screen)
        _ = store.screens
        #expect(TreeProjection.lowerings(of: login.screen) - live == 1)

        store.update(login.title) { $0.content.text = "Hello again" }
        let before = TreeProjection.lowerings(of: login.screen)
        let read = try snapshot(login)
        _ = read.elements
        _ = read.screens
        _ = DesignLayoutWriter.json(for: read)
        #expect(TreeProjection.lowerings(of: login.screen) - before == 0)
    }
}
