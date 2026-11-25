import CoreGraphics
import Foundation
import Testing
@testable import Layer

// Get Design Layout shows the tree (plan 6, Task 4): every key and value Shortcuts read before stays, each leaf gains its
// sizing, its parent and its turn, and each screen and the open canvas list their containers with their children,
// layout, padding and sizing. Frames are host shapes: screen points on screens, canvas points on the canvas (call 3).
//
// `todaysKeysKeepTheirValues` holds the JSON to `Goldens/DesignLayout-sketch.json`, the Shortcuts contract: the writer's
// JSON before containers were written, recorded in plan 6's Task 3 (F9), with the canvas's `codeLayout` as "stack", the
// value main wrote and Update Canvas Settings takes. It is never recorded again.
//
// `theContainersGoldenHolds` compares the fixture's JSON, under the design id "fixture" and with each of its ids put as
// the fixture's name for it, with `Goldens/DesignLayout-containers.json`. To record it again, run this suite with the
// environment variable TEST_RUNNER_LAYER_RECORD_LAYOUT set to a folder on this Mac, then copy the file written there
// into `Goldens/`.

private final class DesignLayoutTreeBundleMarker {}

@Suite("Get Design Layout on the tree")
@MainActor
struct DesignLayoutTreeTests {
    private typealias Object = [String: Any]

    private var bundle: Bundle { Bundle(for: DesignLayoutTreeBundleMarker.self) }

    /// The fixture's design, as Get Design Layout writes it.
    private func layout(_ login: TreeFixture.Login) throws -> Object {
        let snapshot = try #require(DesignActions.snapshot(of: login.model))
        return try parse(DesignLayoutWriter.json(for: snapshot))
    }

    private func parse(_ json: String) throws -> Object {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? Object)
    }

    private func screen(_ id: TreeScreen.ID, in layout: Object) throws -> Object {
        try entry(id, in: layout["screens"])
    }

    /// The entry in `list` whose id ends with `id`.
    private func entry(_ id: UUID, in list: Any?) throws -> Object {
        let entries = try #require(list as? [Object])
        return try #require(entries.first { ($0["id"] as? String)?.hasSuffix(id.uuidString) == true })
    }

    /// The entity id of a node on the fixture's screen.
    private func id(_ node: UUID, _ login: TreeFixture.Login) -> String {
        "\(login.designID)|\(login.screen.uuidString)|\(node.uuidString)"
    }

    private func frame(of entry: Object) -> [Double?] {
        ["x", "y", "width", "height"].map { entry[$0] as? Double }
    }

    /// Records each place where `now` doesn't hold `then`: an object holds every key `then` has, with a value that holds
    /// `then`'s; a list has as many entries, each holding `then`'s at its index; anything else is equal.
    private func find(_ then: Any, heldIn now: Any, at path: String, missing: inout [String]) {
        switch (then, now) {
        case let (then as Object, now as Object):
            for (key, value) in then {
                guard let held = now[key] else {
                    missing.append("\(path).\(key) is gone")
                    continue
                }
                find(value, heldIn: held, at: "\(path).\(key)", missing: &missing)
            }
        case let (then as [Any], now as [Any]):
            guard then.count == now.count else {
                missing.append("\(path) has \(now.count) entries, not \(then.count)")
                return
            }
            for (offset, (was, held)) in zip(then, now).enumerated() {
                find(was, heldIn: held, at: "\(path)[\(offset)]", missing: &missing)
            }
        case let (then as NSObject, now as NSObject) where then == now:
            break
        default:
            missing.append("\(path) is \(now), not \(then)")
        }
    }

    @Test func todaysKeysKeepTheirValues() throws {
        let fixture = try #require(bundle.url(forResource: "design-sketch", withExtension: "json"))
        var content = try TreeManifest.decode(try Data(contentsOf: fixture)).content
        TreeRules.apply(to: &content, after: nil)
        let json = DesignLayoutWriter.json(for: DesignSnapshot(id: "local:Sketch.layer", name: "Sketch", content: content, modified: nil))
        let golden = try #require(bundle.url(forResource: "DesignLayout-sketch", withExtension: "json"))
        let then = try JSONSerialization.jsonObject(with: try Data(contentsOf: golden))
        let now = try JSONSerialization.jsonObject(with: Data(json.utf8))

        var missing: [String] = []
        find(then, heldIn: now, at: "", missing: &missing)
        #expect(missing.isEmpty, "\(missing)")
    }

    @Test func leavesKeepTodaysKeysAndGainTheirPlaceInTheTree() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let elements = try screen(login.screen, in: try layout(login))["elements"]

        let about = try entry(login.about, in: elements)
        #expect(frame(of: about) == [36, 156, 200, 24])
        #expect(about["kind"] as? String == "text")
        #expect(about["text"] as? String == "About me")
        #expect(about["parent"] as? String == id(login.card, login))
        #expect(try entry(login.title, in: elements)["parent"] == nil, "on the screen's root, in no container")
        let label = try entry(login.label, in: elements)
        #expect(label["sizing"] as? NSDictionary == ["width": ["mode": "fixed"], "height": ["mode": "fixed"]] as NSDictionary)
    }

    @Test func containersListTheirChildrenLayoutAndSizing() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let containers = try #require(try screen(login.screen, in: try layout(login))["containers"] as? [Object])

        #expect(containers.map { $0["id"] as? String } == [id(login.card, login), id(login.row, login)])
        let row = try entry(login.row, in: containers)
        #expect(row["kind"] as? String == "group")
        #expect(row["layout"] as? NSDictionary
            == ["type": "stack", "axis": "horizontal", "spacing": 12, "alignment": "center", "justify": "start"] as NSDictionary)
        #expect(row["children"] as? [String] == [id(login.label, login), id(login.toggle, login)])
        #expect(frame(of: row) == [20, 320, 143, 31])
        #expect(((row["sizing"] as? Object)?["width"] as? Object)?["mode"] as? String == "fit")

        let card = try entry(login.card, in: containers)
        #expect(card["layout"] as? NSDictionary == ["type": "free"] as NSDictionary)
        #expect(card["padding"] as? NSDictionary == ["top": 16, "leading": 16, "bottom": 16, "trailing": 16] as NSDictionary)
        #expect(card["children"] as? [String] == [id(login.about, login), id(login.body, login)])
    }

    @Test func framesAreScreenPointsOnScreensAndCanvasPointsOnTheCanvas() throws {
        let login = TreeFixture.loginWithACardAndARow()
        // Two squares, as a free group of one dissolves.
        let squares = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 100, width: 100, height: 100)]
            .map { LayerNode.leaf(.shape, frame: $0, shape: .rectangle) }
        let group = LayerNode.container(frame: CGRect(x: 100, y: 100, width: 200, height: 200), width: .init(.fixed),
                                        height: .init(.fixed), children: squares)
        login.model.store.addCanvasNode(group, scale: 0.5)
        let layout = try layout(login)

        #expect(frame(of: try entry(login.note, in: layout["canvasElements"])) == [300, 50, 75, 75])
        #expect(frame(of: try entry(group.id, in: layout["canvasContainers"])) == [50, 50, 100, 100])
    }

    @Test func rotationIsTheTurnSeen() throws {
        let login = TreeFixture.loginWithACardAndARow()
        login.model.store.update(login.card) { $0.rotation = 90 }
        let screen = try screen(login.screen, in: try layout(login))

        #expect(try entry(login.card, in: screen["containers"])["rotation"] as? Double == 90)
        let about = try entry(login.about, in: screen["elements"])
        #expect(frame(of: about) == [148.5, 147.5, 200, 24])
        #expect(about["rotation"] as? Double == 90)
        #expect(try entry(login.title, in: screen["elements"])["rotation"] == nil, "upright")
    }

    @Test func theScreenTellsItsLayoutAndDevice() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let store = login.model.store
        let settings = store.addColumnScreen([.leaf(.title, frame: CGRect(x: 0, y: 0, width: 200, height: 40), text: "Settings")],
                                             name: "Settings", origin: CGPoint(x: 500, y: 0))
        let kioskID = store.addCustomDevice(.custom(name: "Kiosk", size: CGSize(width: 1080, height: 1920), family: .other))
        let kiosk = try #require(store.tree.settings.customDevices.first { $0.id == kioskID })
        let lobby = store.addFreeScreen([], name: "Lobby", device: kiosk, origin: CGPoint(x: 1000, y: 0))
        let layout = try layout(login)

        let column = try #require(try screen(settings, in: layout)["layout"] as? Object)
        #expect(column["type"] as? String == "stack")
        #expect(column["axis"] as? String == "vertical")
        #expect(column["spacing"] as? Double == 24)

        let onKiosk = try screen(lobby, in: layout)
        #expect(kioskID.hasPrefix("custom-"))
        #expect(onKiosk["device"] as? String == kioskID)
        #expect(onKiosk["deviceName"] as? String == "Kiosk")
        #expect(onKiosk["width"] as? Double == 1080)
        #expect(onKiosk["height"] as? Double == 1920)

        let onPhone = try screen(login.screen, in: layout)
        #expect(onPhone["device"] as? String == "iphone")
        #expect(onPhone["deviceName"] as? String == "Phone")
    }

    /// A number a file can hold that is past any layout's (a custom device 1e308 wide, a screen at x 1e308, a frame's
    /// x of 1e308) is written as the farthest a picture tells, 1e12, and what isn't a number as 0: nothing infinite or
    /// NaN reaches `JSONSerialization`, which would end the app rather than throw (plan 6 final review A, I4).
    @Test func numbersPastAnyLayoutAreWrittenFinite() throws {
        let huge = DeviceFrame.custom(name: "Huge", size: CGSize(width: 1e308, height: 1e308), family: .other)
        let far = LayerNode.leaf(.text, frame: CGRect(x: 1e308, y: 20, width: 100, height: 24), text: "Far")
        let odd = LayerNode.leaf(.text, frame: CGRect(x: 20, y: CGFloat.nan, width: 100, height: CGFloat.nan), text: "Odd")
        var wall = TreeScreen(name: "Wall", origin: CGPoint(x: 1e308, y: 0), scale: 1, deviceID: huge.id)
        wall.root.children = [far, odd]
        var content = TreeContent()
        content.settings.customDevices = [huge]
        content.settings.gridSpacing = 1e308
        content.screens = [wall]

        let json = DesignLayoutWriter.json(for: DesignSnapshot(id: "design", name: "Design", content: content, modified: nil))

        let layout = try parse(json)
        #expect((layout["canvas"] as? Object)?["gridSpacing"] as? Double == 1e12)
        let screen = try screen(wall.id, in: layout)
        #expect(screen["x"] as? Double == 1e12)
        #expect(screen["width"] as? Double == 1e12)
        #expect(screen["height"] as? Double == 1e12)
        #expect(try entry(far.id, in: screen["elements"])["x"] as? Double == 1e12)
        // What a NaN height touches in the frame is 0: its y and its height, and its x, which its middle is found by.
        let notANumber = frame(of: try entry(odd.id, in: screen["elements"]))
        #expect(notANumber.allSatisfy { $0?.isFinite == true }, "\(notANumber)")
        #expect(notANumber[1] == 0 && notANumber[3] == 0, "\(notANumber)")
        #expect(notANumber[2] == 100)
    }

    /// Both axes' sizing, as a node's `width` and `height` are saved.
    private struct Sizes: Encodable {
        var width: LayerNode.Sizing
        var height: LayerNode.Sizing
    }

    /// `part` as `design.json`'s encoder writes it and JSON reads it back, written with sorted keys: an empty object when
    /// the encoder refuses it.
    private func asTheFileWrites(_ part: some Encodable) throws -> String {
        let object = (try? JSONEncoder().encode(part)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? Object()
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func sorted(_ value: Any?) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: try #require(value), options: [.sortedKeys]), as: UTF8.self)
    }

    /// A layout, padding and sizing are written as `design.json` writes them, byte for byte, at the edges too: a negative
    /// zero reads back as 0, a number far past any layout is written as it is, and a part holding a number that isn't
    /// finite, which the file's encoder refuses, is an empty object (the sweep, lane 2: written directly, not encoded
    /// and parsed per node).
    @Test func layoutPaddingAndSizingAreWrittenAsTheFileWritesThem() throws {
        var grid = LayerNode(kind: .group)
        grid.layout = .grid(LayerNode.Grid(columns: 3, columnSpacing: 1e20, rowSpacing: 0.1,
                                           alignment: LayerNode.Alignment(horizontal: .start, vertical: .end)))
        grid.padding = LayerNode.Padding(top: -0.0, leading: 1.0 / 3, bottom: 12.000000000000002, trailing: 0)
        grid.width = LayerNode.Sizing(.fill(weight: 1.0 / 3), minimum: -0.0, maximum: 1e308)
        grid.height = LayerNode.Sizing(.fit, minimum: 4.9e-324)
        grid.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        var card = LayerNode(kind: .card)
        card.layout = .overlay(LayerNode.Alignment(horizontal: .end, vertical: .start))
        card.padding = LayerNode.Padding(top: .nan, leading: 16, bottom: 16, trailing: 16)
        card.width = LayerNode.Sizing(.fixed)
        card.height = LayerNode.Sizing(.fit, maximum: .infinity)
        card.frame = CGRect(x: 0, y: 220, width: 300, height: 100)
        var leaf = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 100, height: 24), text: "Leaf")
        leaf.width = LayerNode.Sizing(.fill(weight: .nan))
        grid.children = [leaf]
        var screen = TreeScreen(name: "Edges", origin: .zero, scale: 1, deviceID: nil)
        screen.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: -0.0, alignment: .fill, justify: .spaceBetween))
        screen.root.padding = LayerNode.Padding(all: 16)
        screen.root.children = [grid, card]
        var content = TreeContent()
        content.screens = [screen]

        let layout = try parse(DesignLayoutWriter.json(for: DesignSnapshot(id: "design", name: "Edges", content: content, modified: nil)))

        let written = try self.screen(screen.id, in: layout)
        #expect(try sorted(written["layout"]) == (try asTheFileWrites(screen.root.layout)))
        #expect(try sorted(written["padding"]) == (try asTheFileWrites(screen.root.padding)))
        for node in [grid, card] {
            let entry = try entry(node.id, in: written["containers"])
            #expect(try sorted(entry["layout"]) == (try asTheFileWrites(node.layout)))
            #expect(try sorted(entry["padding"]) == (try asTheFileWrites(node.padding)))
            #expect(try sorted(entry["sizing"]) == (try asTheFileWrites(Sizes(width: node.width, height: node.height))))
        }
        let leafEntry = try entry(leaf.id, in: written["elements"])
        #expect(try sorted(leafEntry["sizing"]) == (try asTheFileWrites(Sizes(width: leaf.width, height: leaf.height))))
        // The edges are there to be written: a negative zero is 0, and what isn't finite empties its part.
        #expect(try sorted(written["layout"]).contains(#""spacing":0,"#))
        #expect(try sorted(try entry(card.id, in: written["containers"])["padding"]) == "{}")
        #expect(try sorted(leafEntry["sizing"]) == "{}")
    }

    @Test func theContainersGoldenHolds() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let snapshot = try #require(DesignActions.snapshot(of: login.model))
        // The fixture's ids are new each time it is made, and its file's is a path: each is put as its name.
        var json = DesignLayoutWriter.json(for: DesignSnapshot(id: "fixture", name: snapshot.name, content: snapshot.content, modified: nil))
        let names: [(UUID, String)] = [
            (login.screen, "screen"), (login.title, "title"), (login.card, "card"), (login.about, "about"), (login.body, "body"),
            (login.row, "row"), (login.label, "label"), (login.toggle, "toggle"), (login.note, "note"),
        ]
        for (id, name) in names { json = json.replacingOccurrences(of: id.uuidString, with: name) }

        if let folder = ProcessInfo.processInfo.environment["LAYER_RECORD_LAYOUT"] {
            try json.write(to: URL(fileURLWithPath: folder).appendingPathComponent("DesignLayout-containers.json"), atomically: true,
                           encoding: .utf8)
            return
        }
        let golden = try #require(bundle.url(forResource: "DesignLayout-containers", withExtension: "json"))
        #expect(json == (try String(contentsOf: golden, encoding: .utf8)))
    }
}
