import A2UICore
import BasicCatalog
import CoreGraphics
import Foundation
import OrderedJSON
import Testing
import UIKit
@testable import Layer

@Suite struct A2UIImportTests {
    private static let basic = "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

    private static let officialExamples = [
        "a2ui-child-list-template", "a2ui-modal", "a2ui-music-player", "a2ui-product-card",
        "a2ui-scaffold-complex-layout", "a2ui-scaffold-row-layout", "a2ui-scaffold-simple-login-form",
        "a2ui-user-profile",
    ]

    /// What an official example may be told: what Layer can't run, can't read without data, or
    /// has no exact kind for. Never a broken graph or an invalid component.
    private static let reasonsInExamples: Set<A2UIDiagnostic.Reason> = [
        .binding, .template, .actionNotRun, .functionNotRun, .nearestKind,
    ]

    // MARK: - The official examples

    @Test(arguments: officialExamples)
    func theOfficialExamplesImport(_ name: String) throws {
        let result = A2UIImporter.importJSON(try fixture(name))
        #expect(result.screens.count >= 1)
        let unexpected = result.diagnostics.filter { !Self.reasonsInExamples.contains($0.reason) }
        #expect(unexpected.isEmpty, "\(unexpected)")
        for screen in result.screens {
            #expect(screen.root.kind == .group)
            #expect(screen.root.padding == LayerNode.Padding())
            #expect(all(screen.root).allSatisfy { $0.source?.origin == .imported })
        }
    }

    @Test func theLoginFormBecomesAColumnOfFields() throws {
        let result = A2UIImporter.importJSON(try fixture("a2ui-scaffold-simple-login-form"))
        let screen = try #require(result.screens.first)
        #expect(result.screens.count == 1)
        #expect(screen.surfaceID == "gallery-simple-login-form")

        let root = screen.root
        #expect(shape(root) == "group(column)[title,textField,textField,button]")
        #expect(root.source == LayerNode.Source(origin: .imported, key: "root"))
        #expect(stack(root)?.alignment == .fill)
        #expect(stack(root)?.justify == .start)
        #expect(root.children.map(\.content.text) == ["Login", "Username", "Password", "Sign In"])
        #expect(root.children.map { $0.source?.key } == ["form_title", "username_field", "password_field", "submit_button"])
        #expect(root.child(3).content.buttonLook == .filled)
        for leaf in root.children {
            let sizing = NaturalSize.defaultSizing(for: leaf.kind)
            #expect(leaf.width == sizing.width && leaf.height == sizing.height, "\(leaf.kind)")
        }

        let actions = result.diagnostics.filter { $0.reason == .actionNotRun }
        #expect(actions.map(\.componentID) == ["submit_button"])
        #expect(actions.first?.path == "action")
    }

    // MARK: - The mapping

    /// Every Basic Catalog component, each a child of the root, with what it needs.
    private static let everyBasicComponent = """
        {"id":"root","component":"Column","children":["text","image","icon","video","audio","row","column",
          "list","card","tabs","modal","divider","button","field","check","choice","slider","date"]},
        {"id":"text","component":"Text","text":"Hello"},
        {"id":"image","component":"Image","url":"https://example.com/a.png"},
        {"id":"icon","component":"Icon","name":"star"},
        {"id":"video","component":"Video","url":"https://example.com/a.mp4"},
        {"id":"audio","component":"AudioPlayer","url":"https://example.com/a.mp3"},
        {"id":"row","component":"Row","children":["row_a","row_b"]},
        {"id":"row_a","component":"Text","text":"A"},
        {"id":"row_b","component":"Text","text":"B"},
        {"id":"column","component":"Column","children":["column_a"]},
        {"id":"column_a","component":"Text","text":"C"},
        {"id":"list","component":"List","children":["list_a"],"direction":"horizontal"},
        {"id":"list_a","component":"Text","text":"D"},
        {"id":"card","component":"Card","child":"card_text"},
        {"id":"card_text","component":"Text","text":"In a card"},
        {"id":"tabs","component":"Tabs","tabs":[{"title":"One","child":"tab_one"},{"title":"Two","child":"tab_two"}]},
        {"id":"tab_one","component":"Text","text":"First tab"},
        {"id":"tab_two","component":"Text","text":"Second tab"},
        {"id":"modal","component":"Modal","trigger":"modal_trigger","content":"modal_content"},
        {"id":"modal_trigger","component":"Button","child":"modal_label","action":{"event":{"name":"open"}}},
        {"id":"modal_label","component":"Text","text":"Open"},
        {"id":"modal_content","component":"Text","text":"Inside"},
        {"id":"divider","component":"Divider"},
        {"id":"button","component":"Button","child":"button_label","variant":"borderless","action":{"event":{"name":"go"}}},
        {"id":"button_label","component":"Text","text":"Go"},
        {"id":"field","component":"TextField","label":"Email","value":""},
        {"id":"check","component":"CheckBox","label":"Agree","value":true},
        {"id":"choice","component":"ChoicePicker","options":[{"label":"Small","value":"s"},{"label":"Large","value":"l"}],"value":["l"]},
        {"id":"slider","component":"Slider","value":5,"max":10},
        {"id":"date","component":"DateTimeInput","value":"2026-11-23","enableDate":true}
        """

    @Test func everyBasicComponentMapsToItsRow() throws {
        // The surface really does hold all 18.
        let written = try JSONSerialization.jsonObject(with: Data("[\(Self.everyBasicComponent)]".utf8)) as? [[String: Any]]
        let types = Set((written ?? []).compactMap { $0["component"] as? String })
        #expect(types == Set(BasicCatalog.makeCatalog(version: .v10).components.keys))

        let result = A2UIImporter.importJSON(surface(Self.everyBasicComponent))
        let root = try #require(result.screens.first?.root)
        let rows: [(String, String)] = [
            ("Text", "text"),
            ("Image", "image"),
            ("Icon", "symbol"),
            ("Video", "image"),
            ("AudioPlayer", "image"),
            ("Row", "group(row)[text,text]"),
            ("Column", "group(column)[text]"),
            ("List", "group(row)[text]"),
            ("Card", "card(column)[text]"),
            ("Tabs", "text"),
            ("Modal", "button"),
            ("Divider", "divider"),
            ("Button", "button"),
            ("TextField", "textField"),
            ("CheckBox", "group(row)[checkbox,text]"),
            ("ChoicePicker", "group(column)[group(row)[radio,text],group(row)[radio,text]]"),
            ("Slider", "progress"),
            ("DateTimeInput", "textField"),
        ]
        #expect(root.children.count == rows.count)
        for (index, row) in rows.enumerated() {
            #expect(shape(root.child(index)) == row.1, "\(row.0)")
        }

        #expect(root.child(2).content.symbol == "star.fill")
        #expect(root.child(8).padding == LayerNode.Padding(all: 16))
        #expect(root.child(9).content.text == "First tab")
        #expect(root.child(10).content.text == "Open")
        #expect(root.child(12).content.text == "Go")
        #expect(root.child(12).content.buttonLook == .plain)
        #expect(root.child(13).content.text == "Email")
        #expect(root.child(14).child(0).content.isOn == true)
        #expect(root.child(14).child(1).content.text == "Agree")
        #expect(root.child(15).children.map { $0.child(0).content.isOn } == [false, true])
        #expect(root.child(15).children.map { $0.child(1).content.text } == ["Small", "Large"])
        #expect(root.child(16).content.value == 0.5)

        let nearest = Set(result.diagnostics.filter { $0.reason == .nearestKind }.compactMap(\.componentID))
        #expect(nearest.isSuperset(of: ["video", "audio", "list", "tabs", "modal", "slider", "date"]))
        // The modal's content and the second tab aren't imported, but they are reached.
        #expect(!result.diagnostics.contains { $0.reason == .unreachable })
        #expect(Set(result.diagnostics.filter { $0.reason == .actionNotRun }.compactMap(\.componentID)) == ["modal_trigger", "button"])
    }

    @Test func layersOwnComponentsMapToTheirNodes() throws {
        let components = """
            {"id":"root","component":"Column","children":["grid","overlay","free","toggle","radio","progress","symbol","shape"]},
            {"id":"grid","component":"LayerGrid","children":["a","b"],"columns":3,"columnSpacing":8,"rowSpacing":4},
            {"id":"a","component":"Text","text":"A"},
            {"id":"b","component":"Text","text":"B"},
            {"id":"overlay","component":"LayerOverlay","children":["c"],"horizontal":"start","vertical":"end"},
            {"id":"c","component":"Text","text":"C"},
            {"id":"free","component":"LayerFree","children":["d"]},
            {"id":"d","component":"Text","text":"D"},
            {"id":"toggle","component":"LayerToggle","label":"Wi-Fi","value":false},
            {"id":"radio","component":"LayerRadio","label":"Small","value":true},
            {"id":"progress","component":"LayerProgress","value":0.25},
            {"id":"symbol","component":"LayerSymbol","name":"heart.fill"},
            {"id":"shape","component":"LayerShape","shape":"ellipse","filled":false}
            """
        let result = A2UIImporter.importJSON(surface(components, catalog: LayerCatalog.id))
        let root = try #require(result.screens.first?.root)
        #expect(shape(root) == "group(column)[group(grid3)[text,text],group(overlay)[text],group(free)[text],toggle,radio,progress,symbol,shape]")
        #expect(root.child(0).layout == .grid(LayerNode.Grid(
            columns: 3, columnSpacing: 8, rowSpacing: 4, alignment: LayerNode.Alignment(horizontal: .start, vertical: .start))))
        #expect(root.child(1).layout == .overlay(LayerNode.Alignment(horizontal: .start, vertical: .end)))
        #expect(root.child(3).content.isOn == false)
        #expect(root.child(3).name == "Wi-Fi")
        #expect(root.child(4).content.isOn == true)
        #expect(root.child(5).content.value == 0.25)
        #expect(root.child(6).content.symbol == "heart.fill")
        #expect(root.child(7).content.shape == .ellipse)
        #expect(root.child(7).content.isOn == false)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    @Test func aCardTakesItsColumnsLayoutAndChildren() throws {
        let components = """
            {"id":"root","component":"Card","child":"inside"},
            {"id":"inside","component":"Column","children":["a","b"],"align":"center","justify":"end"},
            {"id":"a","component":"Text","text":"A"},
            {"id":"b","component":"Text","text":"B","weight":2}
            """
        let result = A2UIImporter.importJSON(surface(components))
        let root = try #require(result.screens.first?.root)
        // A card isn't a column, so the screen root is a column holding it.
        #expect(shape(root) == "group(column)[card(column)[text,text]]")
        #expect(root.source?.key == nil)
        let card = root.child(0)
        #expect(card.source?.key == "root")
        #expect(card.padding == LayerNode.Padding(all: 16))
        #expect(stack(card)?.alignment == .center)
        #expect(stack(card)?.justify == .end)
        #expect(stack(card)?.spacing == 8)
        #expect(card.child(1).height == LayerNode.Sizing(.fill(weight: 2)))
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    @Test func aRootLayerFreeBecomesAFreeScreenRoot() throws {
        let components = """
            {"id":"root","component":"LayerFree","children":["title","go"]},
            {"id":"title","component":"Text","text":"Sketch",
             "@metadata":{"extensions":{"layer":{"frame":[24,60,200,40],"width":{"mode":"fixed"},"height":{"mode":"fixed"}}}}},
            {"id":"go","component":"Button","child":"go_label","action":{"event":{"name":"\(A2UIImporter.layerActionName)"}},
             "@metadata":{"extensions":{"layer":{"frame":[24,600,320,50],"rotation":5,"width":{"mode":"fixed"},"height":{"mode":"fixed"}}}}},
            {"id":"go_label","component":"Text","text":"Go"}
            """
        let result = A2UIImporter.importJSON(surface(components, catalog: LayerCatalog.id))
        let root = try #require(result.screens.first?.root)
        // The free group is the screen root itself: no column is added round it.
        #expect(shape(root) == "group(free)[text,button]")
        #expect(root.source?.key == "root")
        #expect(root.padding == LayerNode.Padding())
        #expect(root.child(0).frame == CGRect(x: 24, y: 60, width: 200, height: 40))
        #expect(root.child(1).frame == CGRect(x: 24, y: 600, width: 320, height: 50))
        #expect(root.child(1).rotation == 5)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    @Test func textsReadTheirMarkdown() throws {
        let components = """
            {"id":"root","component":"Column","children":["one","two","three","body","note"]},
            {"id":"one","component":"Text","text":"# **Big** news"},
            {"id":"two","component":"Text","text":"## Login"},
            {"id":"three","component":"Text","text":"### Small heading"},
            {"id":"body","component":"Text","text":"First line\\nSecond *line*"},
            {"id":"note","component":"Text","text":"`snake_case` stays","variant":"caption"}
            """
        let root = try #require(A2UIImporter.importJSON(surface(components)).screens.first?.root)
        #expect(root.children.map(\.kind) == [.title, .title, .text, .body, .text])
        #expect(root.children.map(\.content.text) == ["Big news", "Login", "Small heading", "First line\nSecond line", "snake_case stays"])
        #expect(root.child(4).style.textColor != nil)
        #expect(root.child(0).style.textColor == nil)
    }

    @Test func layersMetadataWinsOverTheMapping() throws {
        let components = """
            {"id":"root","component":"Column","children":["text","check"],
             "@metadata":{"extensions":{"layer":{"layout":{"type":"stack","axis":"vertical","spacing":24,"alignment":"center","justify":"start"}}}}},
            {"id":"text","component":"Text","text":"Hello","@accessibility":{"label":"Greeting"},
             "@metadata":{"extensions":{"layer":{"kind":"body","name":"Intro","frame":[10,20,200,40],"rotation":15,
               "width":{"mode":"fixed"},"height":{"mode":"fill","weight":2},
               "style":{"fontSize":20,"tint":{"red":1,"green":0,"blue":0}},
               "content":{"text":"Hi there"},"padding":{"top":4,"leading":4,"bottom":4,"trailing":4}}}}},
            {"id":"check","component":"CheckBox","label":"","value":false,
             "@metadata":{"extensions":{"layer":{"kind":"checkbox","content":{"isOn":false}}}}}
            """
        let result = A2UIImporter.importJSON(surface(components))
        let root = try #require(result.screens.first?.root)
        #expect(root.layout == .stack(LayerNode.Stack(axis: .vertical, spacing: 24, alignment: .center, justify: .start)))
        let text = root.child(0)
        #expect(text.kind == .body)
        #expect(text.name == "Intro")
        #expect(text.frame == CGRect(x: 10, y: 20, width: 200, height: 40))
        #expect(text.rotation == 15)
        #expect(text.width == LayerNode.Sizing(.fixed))
        #expect(text.height == LayerNode.Sizing(.fill(weight: 2)))
        #expect(text.style.fontSize == 20)
        #expect(text.style.tint == RGBColor(red: 1, green: 0, blue: 0))
        #expect(text.content.text == "Hi there")
        #expect(text.accessibility?.label == "Greeting")
        // Layer's own checkbox comes back as one checkbox, not a row with a label.
        #expect(shape(root.child(1)) == "checkbox")
        #expect(root.child(1).content.isOn == false)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")

        let bad = """
            {"id":"root","component":"Column","children":["text"]},
            {"id":"text","component":"Text","text":"Hello",
             "@metadata":{"extensions":{"layer":{"width":{"mode":"stretchy"},"name":"Kept"}}}}
            """
        let badResult = A2UIImporter.importJSON(surface(bad))
        let kept = try #require(badResult.screens.first?.root).child(0)
        #expect(kept.name == "Kept")
        #expect(kept.width == NaturalSize.defaultSizing(for: .text).width)
        #expect(badResult.diagnostics.map(\.reason) == [.invalidComponent])
        #expect(badResult.diagnostics.first?.path == "@metadata.extensions.layer.width")
    }

    // MARK: - Malformed input

    @Test func aMissingVersionIsRejected() {
        for message in [
            #"{"createSurface":{"surfaceId":"s","catalogId":"\#(Self.basic)"}}"#,
            #"{"version":"0.9","createSurface":{"surfaceId":"s","catalogId":"\#(Self.basic)"}}"#,
        ] {
            let result = A2UIImporter.importJSON(Data(message.utf8))
            #expect(result.screens.isEmpty)
            #expect(result.diagnostics.map(\.reason) == [.notVersion1], "\(message)")
        }
    }

    @Test func aMalformedEnvelopeIsRejected() {
        for payload in [
            #"{"version":"1.0","updateComponents":{"surfaceId":"s","components":"not-an-array"}}"#,
            "this isn't JSON at all",
            "42",
        ] {
            let result = A2UIImporter.importJSON(Data(payload.utf8))
            #expect(result.screens.isEmpty)
            #expect(!result.diagnostics.isEmpty)
            #expect(result.diagnostics.allSatisfy { $0.reason == .parseFailed }, "\(payload): \(result.diagnostics)")
        }
    }

    @Test func duplicateIdsAndAMissingRootAreReported() throws {
        let data = Data("""
            [{"version":"1.0","createSurface":{"surfaceId":"one","catalogId":"\(Self.basic)"}},
             {"version":"1.0","updateComponents":{"surfaceId":"one","components":[
               {"id":"root","component":"Column","children":["t"]},
               {"id":"t","component":"Text","text":"First"},
               {"id":"t","component":"Text","text":"Second"}]}},
             {"version":"1.0","createSurface":{"surfaceId":"two","catalogId":"\(Self.basic)"}},
             {"version":"1.0","updateComponents":{"surfaceId":"two","components":[
               {"id":"lonely","component":"Text","text":"No root"}]}}]
            """.utf8)
        let result = A2UIImporter.importJSON(data)
        #expect(result.screens.map(\.surfaceID) == ["one"])
        let root = try #require(result.screens.first?.root)
        #expect(root.children.map(\.content.text) == ["Second"])
        #expect(result.diagnostics.contains { $0.reason == .duplicateID && $0.componentID == "t" })
        #expect(result.diagnostics.contains { $0.reason == .missingRoot })
    }

    @Test func aCycleIsCutAndTheRestImported() throws {
        let components = """
            {"id":"root","component":"Column","children":["a"]},
            {"id":"a","component":"Column","children":["b"]},
            {"id":"b","component":"Column","children":["a"]}
            """
        let result = A2UIImporter.importJSON(surface(components))
        let root = try #require(result.screens.first?.root)
        #expect(shape(root) == "group(column)[group(column)[group(column)[]]]")
        #expect(all(root).compactMap { $0.source?.key } == ["root", "a", "b"])
        let cycles = result.diagnostics.filter { $0.reason == .cycle }
        #expect(cycles.count == 1)
        #expect(cycles.first?.componentID == "b")
        #expect(cycles.first?.path == "children[0]")
    }

    @Test func unresolvedAndUnreachableAreReported() throws {
        let components = """
            {"id":"root","component":"Column","children":["here","ghost"]},
            {"id":"here","component":"Text","text":"Here"},
            {"id":"orphan","component":"Text","text":"Nobody holds me"}
            """
        let result = A2UIImporter.importJSON(surface(components))
        let root = try #require(result.screens.first?.root)
        #expect(root.children.map(\.content.text) == ["Here"])
        let unresolved = result.diagnostics.filter { $0.reason == .unresolved }
        #expect(unresolved.map(\.componentID) == ["root"])
        #expect(unresolved.map(\.path) == ["children[1]"])
        #expect(result.diagnostics.filter { $0.reason == .unreachable }.map(\.componentID) == ["orphan"])
    }

    @Test func aGraphDeeperThan50StopsThere() throws {
        // root holds c1, which holds c2, and so on to c59.
        let components = (0..<60).map { index in
            let id = index == 0 ? "root" : "c\(index)"
            let children = index < 59 ? #"["c\#(index + 1)"]"# : "[]"
            return #"{"id":"\#(id)","component":"Column","children":\#(children)}"#
        }.joined(separator: ",")
        let result = A2UIImporter.importJSON(surface(components))
        let root = try #require(result.screens.first?.root)
        // root and c1 to c50 come in: 51 nodes, no deeper than 50 from the root, then lifted to 32 or less.
        #expect(all(root).count == 51)
        #expect(depth(root) <= TreeRules.maximumDepth)
        let tooDeep = result.diagnostics.filter { $0.reason == .tooDeep }
        #expect(tooDeep.contains { $0.componentID == "c51" })
        #expect(!all(root).contains { $0.source?.key == "c51" })
    }

    @Test func aGraphThatMultipliesStopsAt5000Nodes() throws {
        // Each level holds the next twice, so the tree it describes has more than a billion nodes.
        let components = (0..<30).map { index in
            let id = index == 0 ? "root" : "level\(index)"
            return #"{"id":"\#(id)","component":"Column","children":["level\#(index + 1)","level\#(index + 1)"]}"#
        }.joined(separator: ",") + #",{"id":"level30","component":"Text","text":"Leaf"}"#
        let result = A2UIImporter.importJSON(surface(components))
        let root = try #require(result.screens.first?.root)
        #expect(all(root).count == TreeRules.maximumNodes)
        #expect(result.diagnostics.map(\.reason) == [.invalidComponent])
    }

    @Test func aDeeplyNestedPayloadIsRefusedNotCrashed() async throws {
        // Each is read off the main actor, where a thread's stack is small. Foundation reads JSON
        // up to 512 deep, and decoding 450 deep runs such a thread out of stack, so anything past
        // Layer's limit is refused before anything decodes it.
        func arrays(_ depth: Int) -> Data {
            Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        }
        func objects(_ depth: Int) -> Data {
            Data((String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)).utf8)
        }
        let unclosed = Data(String(repeating: "[", count: 1_000).utf8)
        for payload in [arrays(450), objects(450), arrays(1_000), objects(1_000), unclosed] {
            let result = await Task.detached { A2UIImporter.importJSON(payload) }.value
            #expect(result.screens.isEmpty)
            #expect(result.diagnostics.map(\.reason) == [.parseFailed])
            #expect(result.diagnostics.first?.path == nil)
        }

        // The limit is 64: 64 deep is decoded (and isn't a message), 65 deep is refused unread.
        let inside = await Task.detached { A2UIImporter.importJSON(arrays(A2UIImporter.maximumJSONDepth)) }.value
        #expect(inside.diagnostics.map(\.reason) == [.parseFailed])
        #expect(inside.diagnostics.first?.path == "messages[0]")
        let past = await Task.detached { A2UIImporter.importJSON(arrays(A2UIImporter.maximumJSONDepth + 1)) }.value
        #expect(past.diagnostics.map(\.reason) == [.parseFailed])
        #expect(past.diagnostics.first?.path == nil)

        // Brackets inside a string aren't nesting, nor is an escaped quote the string's end.
        let brackets = String(repeating: "[{", count: 500)
        let text = surface(#"{"id":"root","component":"Column","children":["t"]},{"id":"t","component":"Text","text":"say \"\#(brackets)\\"}"#)
        let read = await Task.detached { A2UIImporter.importJSON(text) }.value
        #expect(read.screens.first?.root.child(0).content.text == #"say "\#(brackets)\"#)
        #expect(read.diagnostics.isEmpty, "\(read.diagnostics)")
    }

    @Test func aStrayQuoteCantHideADeepLine() async throws {
        // Line 1 opens a string it never closes; line 2 is valid JSON 450 deep, which decoding on
        // its own would run a thread out of stack. A string can't run past a newline, so line 2's
        // nesting still counts, and each line is checked again before it is decoded on its own.
        let deep = String(repeating: "[", count: 450) + String(repeating: "]", count: 450)
        let payload = Data(("{\"a\":\"\n" + deep + "\n").utf8)
        let result = await Task.detached { A2UIImporter.importJSON(payload) }.value
        #expect(result.screens.isEmpty)
        #expect(result.diagnostics.map(\.reason) == [.parseFailed])

        // Lines that are each fine still read as messages, a stray quote and all.
        let lines = Data("""
            {"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\(Self.basic)"}}
            {"a":"
            {"version":"1.0","updateComponents":{"surfaceId":"s","components":[{"id":"root","component":"Column","children":["t"]},{"id":"t","component":"Text","text":"Still here"}]}}
            """.utf8)
        let read = await Task.detached { A2UIImporter.importJSON(lines) }.value
        #expect(read.screens.first?.root.child(0).content.text == "Still here")
        #expect(read.diagnostics.map(\.reason) == [.parseFailed])
        #expect(read.diagnostics.first?.path == "line 2")
    }

    @Test func aVeryLongPathIsCapped() async throws {
        func messages(path: String) -> Data {
            var written = String(decoding: surface("""
                {"id":"root","component":"Column","children":["name"]},
                {"id":"name","component":"Text","text":{"@path":"\(path)"}}
                """), as: UTF8.self)
            written.removeLast()
            written += #",{"version":"1.0","updateDataModel":{"surfaceId":"s","path":"\#(path)","value":"Deep"}}]"#
            return Data(written.utf8)
        }

        // 5,000 steps: neither written nor read, each said so.
        let long = messages(path: String(repeating: "/a", count: 5_000))
        let capped = await Task.detached { A2UIImporter.importJSON(long) }.value
        let text = try #require(capped.screens.first?.root.child(0))
        #expect(text.content.text == ElementKind.text.placeholder)
        #expect(capped.diagnostics.allSatisfy { $0.reason == .binding }, "\(capped.diagnostics)")
        #expect(capped.diagnostics.contains { $0.componentID == nil && $0.path == "updateDataModel.path" })
        #expect(capped.diagnostics.contains { $0.componentID == "name" && $0.path == "text" })

        // 64 steps, the most a path may take, are written and read.
        let longest = messages(path: String(repeating: "/a", count: A2UIImporter.maximumPathSteps))
        let kept = await Task.detached { A2UIImporter.importJSON(longest) }.value
        #expect(kept.screens.first?.root.child(0).content.text == "Deep")
        #expect(kept.diagnostics.isEmpty, "\(kept.diagnostics)")
    }

    @Test func oneTooDeepLineIsSkippedNotTheWholeStream() async throws {
        let good = """
            {"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\(Self.basic)"}}
            {"version":"1.0","updateComponents":{"surfaceId":"s","components":[{"id":"root","component":"Column","children":["t"]},{"id":"t","component":"Text","text":"Still here"}]}}
            """
        let lines = good.split(separator: "\n").map(String.init)
        let deep = String(repeating: "[", count: 450) + String(repeating: "]", count: 450)
        let stream = Data([lines[0], deep, lines[1]].joined(separator: "\n").utf8)
        let read = await Task.detached { A2UIImporter.importJSON(stream) }.value
        #expect(read.screens.first?.root.child(0).content.text == "Still here")
        #expect(read.diagnostics.map(\.reason) == [.parseFailed])
        #expect(read.diagnostics.first?.path == "line 2")

        // Stray opening braces, each on its own line, don't add up against the lines after them.
        let strays = Array(repeating: "{", count: A2UIImporter.maximumJSONDepth + 6).joined(separator: "\n")
        let afterStrays = Data((strays + "\n" + good).utf8)
        let streamed = await Task.detached { A2UIImporter.importJSON(afterStrays) }.value
        #expect(streamed.screens.first?.root.child(0).content.text == "Still here")
        #expect(streamed.diagnostics.count == A2UIImporter.maximumJSONDepth + 6)
        #expect(streamed.diagnostics.allSatisfy { $0.reason == .parseFailed })
    }

    @Test func everyA2UIReadGoesThroughTheGuard() async throws {
        // The guarded reader other code uses to read A2UI text, a line at a time or whole.
        let deep = Data((String(repeating: "[", count: 450) + String(repeating: "]", count: 450)).utf8)
        let deepRead = await Task.detached { A2UIImporter.decodeJSON(deep) }.value
        guard case .tooDeep = deepRead else {
            Issue.record("A payload 450 deep should be refused unread, not \(deepRead)")
            return
        }
        guard case .notJSON = A2UIImporter.decodeJSON(Data("{\"a\":".utf8)) else {
            Issue.record("Half an object isn't JSON")
            return
        }
        guard case .value(let value) = A2UIImporter.decodeJSON(Data(#"{"version":"1.0"}"#.utf8)) else {
            Issue.record("A small object should be read")
            return
        }
        #expect(value.objectValue?["version"]?.stringValue == "1.0")

        let stream = Data("""
            {"version":"1.0","createSurface":{"surfaceId":"s"}}
            \(String(decoding: deep, as: UTF8.self))
            not JSON
            {"version":"1.0","deleteSurface":{"surfaceId":"s"}}
            """.utf8)
        let (messages, diagnostics) = await Task.detached { A2UIImporter.guardedMessages(from: stream) }.value
        #expect(messages.count == 2)
        #expect(diagnostics.map(\.path) == ["line 2", "line 3"])
        #expect(diagnostics.allSatisfy { $0.reason == .parseFailed })
    }

    @Test func importedRootsKeepTheOutlinesRhythm() throws {
        // Ruling M3: a screen's root column is spaced 24, as the outline's is; a column in it 12.
        let components = """
            {"id":"root","component":"Column","children":["section"]},
            {"id":"section","component":"Column","children":["a","b"]},
            {"id":"a","component":"Text","text":"A"},
            {"id":"b","component":"Text","text":"B"}
            """
        let root = try #require(A2UIImporter.importJSON(surface(components)).screens.first?.root)
        #expect(stack(root)?.spacing == 24)
        #expect(stack(root.child(0))?.spacing == 12)

        // A root that isn't a column is held in one spaced the same.
        let row = #"{"id":"root","component":"Row","children":["a"]},{"id":"a","component":"Text","text":"A"}"#
        let wrapped = try #require(A2UIImporter.importJSON(surface(row)).screens.first?.root)
        #expect(stack(wrapped)?.spacing == 24)
        #expect(stack(wrapped.child(0))?.spacing == 12)
    }

    @Test func everyNodesKeyIsItsOwn() throws {
        // A Divider two parents share, a Text whose id is a CheckBox's part, and an id with an @.
        let components = """
            {"id":"root","component":"Column","children":["line","a","a/box","line","b@x","row"]},
            {"id":"line","component":"Divider"},
            {"id":"a","component":"CheckBox","label":"Agree","value":true},
            {"id":"a/box","component":"Text","text":"Slash"},
            {"id":"b@x","component":"Text","text":"At"},
            {"id":"row","component":"Row","children":["line"]}
            """
        let root = try #require(A2UIImporter.importJSON(surface(components)).screens.first?.root)
        let keys = all(root).compactMap { $0.source?.key }
        #expect(Set(keys).count == keys.count, "\(keys)")
        // A shared component keeps its id the first time it's met in reading order; later ones are numbered.
        #expect(root.child(0).source?.key == "line")
        #expect(root.child(3).source?.key == "line#2")
        #expect(root.child(5).child(0).source?.key == "line#3")
        #expect(root.child(1).children.map { $0.source?.key } == ["a/box", "a/label"])
        #expect(root.child(2).source?.key == "a~1box")
        #expect(root.child(4).source?.key == "b~2x")
        // The same file gives the same keys.
        let again = try #require(A2UIImporter.importJSON(surface(components)).screens.first?.root)
        #expect(all(again).compactMap { $0.source?.key } == keys)
    }

    @Test func aHostileDataModelCantGrowPastItsLimits() async throws {
        func update(_ path: String, _ value: String) -> String {
            #"{"version":"1.0","updateDataModel":{"surfaceId":"s","path":"\#(path)","value":\#(value)}}"#
        }
        func stream(bound path: String, _ updates: [String]) -> Data {
            let start = """
                {"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\(Self.basic)"}}
                {"version":"1.0","updateComponents":{"surfaceId":"s","components":[{"id":"root","component":"Column","children":["t"]},{"id":"t","component":"Text","text":{"@path":"\(path)"}}]}}
                """
            return Data(([start] + updates).joined(separator: "\n").utf8)
        }

        // An index past 1,000 would grow an array to it, so the update is skipped and said so.
        let indexed = stream(bound: "/x/1000", [update("/x/1000", #""Kept""#), update("/y/1001", "1"),
                                                update("/z/10000/10000/10000/10000", "1")])
        let read = await Task.detached { A2UIImporter.importJSON(indexed) }.value
        #expect(read.screens.first?.root.child(0).content.text == "Kept")
        #expect(read.diagnostics.filter { $0.reason == .binding && $0.path == "updateDataModel.path" }.count == 2,
                "\(read.diagnostics)")

        // Past 50,000 values in all, the updates left are skipped, said once.
        let thousand = "[" + (0..<1_000).map(String.init).joined(separator: ",") + "]"
        let many = stream(bound: "/last", (0..<60).map { update("/list\($0)", thousand) } + [update("/last", #""Late""#)])
        let bounded = await Task.detached { A2UIImporter.importJSON(many) }.value
        #expect(bounded.screens.first?.root.child(0).content.text == ElementKind.text.placeholder)
        #expect(bounded.diagnostics.filter { $0.reason == .binding && $0.path == "updateDataModel.value" }.count == 1,
                "\(bounded.diagnostics)")
    }

    @Test func hugeNumbersInAFileAreBroughtIntoRange() throws {
        // Schema-valid, and every number finite: but laid out as written, the grid's third cell
        // and the frame's far edge are infinite, and the design couldn't be saved.
        let components = """
            {"id":"root","component":"Column","children":["grid","free"]},
            {"id":"grid","component":"LayerGrid","children":["a","b","c"],"columns":3,"columnSpacing":1e308,"rowSpacing":1e308},
            {"id":"a","component":"Text","text":"A","@metadata":{"extensions":{"layer":{"style":{"fontSize":1e308}}}}},
            {"id":"b","component":"Text","text":"B"},
            {"id":"c","component":"Text","text":"C"},
            {"id":"free","component":"LayerFree","children":["far"],
             "@metadata":{"extensions":{"layer":{"padding":{"top":1e308,"leading":1e308,"bottom":1e308,"trailing":1e308},
               "width":{"mode":"fit"},"height":{"mode":"fit"}}}}},
            {"id":"far","component":"Text","text":"Far",
             "@metadata":{"extensions":{"layer":{"frame":[1e308,0,1e308,10],"width":{"mode":"fixed"},"height":{"mode":"fixed"}}}}}
            """
        let result = A2UIImporter.importJSON(surface(components, catalog: LayerCatalog.id))
        let root = try #require(result.screens.first?.root)
        #expect(shape(root) == "group(column)[group(grid3)[text,text,text],group(free)[text]]")
        #expect(root.child(0).layout == .grid(LayerNode.Grid(
            columns: 3, columnSpacing: LayoutEngine.maximumGap, rowSpacing: LayoutEngine.maximumGap,
            alignment: LayerNode.Alignment(horizontal: .start, vertical: .start))))
        #expect(root.child(0).child(0).style.fontSize == 1_000)
        #expect(root.child(1).padding == LayerNode.Padding(all: LayoutEngine.maximumGap))
        #expect(root.child(1).child(0).frame
            == CGRect(x: LayoutEngine.maximumLength, y: 0, width: LayoutEngine.maximumLength, height: 10))
        #expect(result.diagnostics.contains { $0.reason == .invalidComponent && $0.componentID == "grid" })

        // On a screen, laid out by the rules, every frame is finite and the design can be saved.
        var content = TreeContent()
        content.screens = [TreeScreen(name: "Imported", origin: .zero, scale: 1, deviceID: nil, root: root)]
        TreeRules.apply(to: &content, after: nil)
        let frames = all(content.screens[0].root).map(\.frame)
        #expect(frames.allSatisfy { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }, "\(frames)")
        #expect(throws: Never.self) { _ = try JSONEncoder().encode(content.screens[0].root) }
    }

    @Test func surfacesShareOneNodeLimit() throws {
        // Three surfaces, each a tree of 4,095 nodes: one import keeps 5,000 nodes in all.
        func lines(_ surfaceID: String) -> String {
            let components = (0..<11).map { index in
                let id = index == 0 ? "root" : "level\(index)"
                return #"{"id":"\#(id)","component":"Column","children":["level\#(index + 1)","level\#(index + 1)"]}"#
            }.joined(separator: ",") + #",{"id":"level11","component":"Text","text":"Leaf"}"#
            return """
                {"version":"1.0","createSurface":{"surfaceId":"\(surfaceID)","catalogId":"\(Self.basic)"}}
                {"version":"1.0","updateComponents":{"surfaceId":"\(surfaceID)","components":[\(components)]}}
                """
        }
        let result = A2UIImporter.importJSON(Data(["one", "two", "three"].map(lines).joined(separator: "\n").utf8))
        #expect(result.screens.map(\.surfaceID) == ["one", "two"])
        #expect(result.screens.map { all($0.root).count } == [4_095, TreeRules.maximumNodes - 4_095])
        #expect(result.diagnostics.count == 2, "\(result.diagnostics)")
    }

    @Test func aFanOutPayloadIsReadQuickly() async throws {
        // A column reached 4,096 times over, each time holding 1,000 references: half to nothing,
        // half back up to an ancestor. Each is turned away, but each costs time, so an import
        // considers no more than `maximumChildRequests` children in all. (Validating one component
        // with 10,000 children takes the SDK's validator about 0.4 s in a debug build on its own,
        // so the payload is kept to 1,000 in the one component, to time only the fan-out.)
        let levels = 12
        var components = (0..<levels).map { index in
            let id = index == 0 ? "root" : "level\(index)"
            return #"{"id":"\#(id)","component":"Column","children":["level\#(index + 1)","level\#(index + 1)"]}"#
        }
        let references = Array(repeating: #""nowhere""#, count: 500) + Array(repeating: #""level1""#, count: 500)
        components.append(#"{"id":"level\#(levels)","component":"Column","children":[\#(references.joined(separator: ","))]}"#)
        let payload = surface(components.joined(separator: ","))

        let clock = ContinuousClock()
        let started = clock.now
        let result = await Task.detached { A2UIImporter.importJSON(payload) }.value
        let took = clock.now - started
        #expect(took < .seconds(1), "\(took)")
        #expect(result.screens.count == 1)
    }

    /// The work an import does, counted by the import itself: each component's references are read once, each
    /// reference is followed once by the walk, and each child or search step is charged to `maximumChildRequests`.
    private static func workBound(components: Int, references: Int) -> Int {
        components + references + A2UIImporter.maximumChildRequests
    }

    @Test func aButtonsWordsAreLookedForOnceForEachChild() throws {
        // 500 buttons share one child: a row of 60 icons and then the words. Looked for afresh for each button,
        // each component's references read again each time, that was 500 searches of 62 components.
        let buttons = (0..<500).map { "b\($0)" }
        let icons = (0..<60).map { "i\($0)" }
        func list(_ ids: [String]) -> String { ids.map { "\"\($0)\"" }.joined(separator: ",") }
        let components = [#"{"id":"root","component":"Column","children":[\#(list(buttons))]}"#,
                          #"{"id":"label","component":"Row","children":[\#(list(icons + ["words"]))]}"#,
                          #"{"id":"words","component":"Text","text":"Go"}"#]
            + icons.map { #"{"id":"\#($0)","component":"Icon","name":"star"}"# }
            + buttons.map { #"{"id":"\#($0)","component":"Button","child":"label"}"# }

        let result = A2UIImporter.importJSON(surface(components.joined(separator: ",")))

        let root = try #require(result.screens.first?.root)
        #expect(root.children.count == buttons.count)
        #expect(root.children.allSatisfy { $0.kind == .button && $0.content.text == "Go" })
        // Every component read once, every reference followed once, every child considered once, and one search.
        let read = 3 + icons.count + buttons.count
        let followed = buttons.count + (icons.count + 1) + buttons.count
        #expect(result.work <= read + followed + buttons.count + 2 * 100, "\(result.work)")
    }

    @Test func aFanOutsWorkIsBounded() throws {
        // aFanOutPayloadIsReadQuickly's payload, bounded by the work counted rather than by the clock.
        let levels = 12
        var components = (0..<levels).map { index in
            let id = index == 0 ? "root" : "level\(index)"
            return #"{"id":"\#(id)","component":"Column","children":["level\#(index + 1)","level\#(index + 1)"]}"#
        }
        let references = Array(repeating: #""nowhere""#, count: 500) + Array(repeating: #""level1""#, count: 500)
        components.append(#"{"id":"level\#(levels)","component":"Column","children":[\#(references.joined(separator: ","))]}"#)

        let result = A2UIImporter.importJSON(surface(components.joined(separator: ",")))

        #expect(result.screens.count == 1)
        #expect(result.work > 0)
        #expect(result.work <= Self.workBound(components: levels + 1, references: 2 * levels + references.count), "\(result.work)")
    }

    @Test func buttonsWordsSearchesAreChargedToTheImportsChildren() throws {
        // 400 buttons, each with a child of its own that holds one column of 200 empty columns and then the words.
        // Each search looks at 100 components and finds no words, so in all they would look at more than
        // `maximumChildRequests` allows.
        let count = 400
        let empties = (0..<200).map { "e\($0)" }
        func list(_ ids: [String]) -> String { ids.map { "\"\($0)\"" }.joined(separator: ",") }
        var components = [#"{"id":"root","component":"Column","children":[\#(list((0..<count).map { "b\($0)" }))]}"#,
                          #"{"id":"deep","component":"Column","children":[\#(list(empties + ["words"]))]}"#,
                          #"{"id":"words","component":"Text","text":"Go"}"#]
        components += empties.map { #"{"id":"\#($0)","component":"Column","children":[]}"# }
        for index in 0..<count {
            components.append(#"{"id":"b\#(index)","component":"Button","child":"c\#(index)"}"#)
            components.append(#"{"id":"c\#(index)","component":"Row","children":["deep"]}"#)
        }

        let result = A2UIImporter.importJSON(surface(components.joined(separator: ",")))

        let reached = 3 + empties.count + 2 * count
        let followed = 3 * count + empties.count + 1
        #expect(result.work <= Self.workBound(components: reached, references: followed), "\(result.work)")
        let root = try #require(result.screens.first?.root)
        #expect(root.children.count == count)
        #expect(root.children.allSatisfy { $0.content.text == ElementKind.button.placeholder })
    }

    @Test func componentsWithoutCreateSurfaceStillImport() throws {
        let data = Data("""
            {"version":"1.0","updateComponents":{"surfaceId":"loose","components":[
              {"id":"root","component":"Column","children":["t"],"@catalogId":"\(Self.basic)"},
              {"id":"t","component":"Text","text":"Hi","@catalogId":"\(Self.basic)"}]}}
            """.utf8)
        let result = A2UIImporter.importJSON(data)
        let screen = try #require(result.screens.first)
        #expect(screen.surfaceID == "loose")
        #expect(screen.root.children.map(\.content.text) == ["Hi"])
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.reason == .unresolved)
        #expect(result.diagnostics.first?.path == "updateComponents.surfaceId")

        // With no catalogue named anywhere, each component says so, and still comes in.
        let bare = Data("""
            {"version":"1.0","updateComponents":{"surfaceId":"bare","components":[
              {"id":"root","component":"Column","children":["t"]},
              {"id":"t","component":"Text","text":"Hi"}]}}
            """.utf8)
        let bareResult = A2UIImporter.importJSON(bare)
        #expect(bareResult.screens.first?.root.children.map(\.content.text) == ["Hi"])
        #expect(Set(bareResult.diagnostics.filter { $0.reason == .noCatalog }.compactMap(\.componentID)) == ["root", "t"])
    }

    @Test func oneMessagePerLineIsRead() throws {
        let lines = """
            {"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\(Self.basic)"}}
            {"version":"1.0","updateComponents":{"surfaceId":"s","components":[{"id":"root","component":"Column","children":["t"]},{"id":"t","component":"Text","text":"Lines"}]}}
            """
        let result = A2UIImporter.importJSON(Data(lines.utf8))
        #expect(result.screens.first?.root.children.map(\.content.text) == ["Lines"])
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    // MARK: - Data

    @Test func bindingsReadTheDataModelElsePlaceholders() throws {
        let components = """
            {"id":"root","component":"Column","children":["name"]},
            {"id":"name","component":"Text","text":{"@path":"/user/name"}}
            """
        let bound = A2UIImporter.importJSON(surface(components, dataModel: #"{"user":{"name":"Ada"}}"#))
        #expect(bound.screens.first?.root.child(0).content.text == "Ada")
        #expect(bound.diagnostics.isEmpty, "\(bound.diagnostics)")

        // updateDataModel works as well as createSurface's data model.
        var messages = String(decoding: surface(components), as: UTF8.self)
        messages.removeLast()
        messages += #",{"version":"1.0","updateDataModel":{"surfaceId":"s","path":"/user","value":{"name":"Grace"}}}]"#
        let updated = A2UIImporter.importJSON(Data(messages.utf8))
        #expect(updated.screens.first?.root.child(0).content.text == "Grace")

        let unbound = A2UIImporter.importJSON(surface(components))
        let text = try #require(unbound.screens.first?.root.child(0))
        #expect(text.kind == .text)
        #expect(text.content.text == ElementKind.text.placeholder)
        #expect(unbound.diagnostics.map(\.reason) == [.binding])
        #expect(unbound.diagnostics.first?.componentID == "name")
        #expect(unbound.diagnostics.first?.path == "text")
    }

    @Test func templatesExpandOverTheDataModel() throws {
        let result = A2UIImporter.importJSON(try fixture("a2ui-child-list-template"))
        let root = try #require(result.screens.first?.root)
        #expect(shape(root) == "group(column)[card(column)[text,group(column)[group(row)[text,text,text],group(row)[text,text,text],group(row)[text,text,text]]]]")
        let rows = root.child(0).child(1).children
        #expect(rows.map { $0.children.map(\.content.text) } == [
            ["Apple", "- Qty:", "10"], ["Banana", "- Qty:", "5"], ["Cherry", "- Qty:", "20"],
        ])
        // Each item's nodes have keys of their own.
        let keys = rows.flatMap { all($0) }.compactMap { $0.source?.key }
        #expect(Set(keys).count == keys.count)
        #expect(!result.diagnostics.contains { $0.reason == .template || $0.reason == .binding })

        // Without the data model: one item, said so.
        let file = try JSONSerialization.jsonObject(with: try fixture("a2ui-child-list-template")) as? [String: Any]
        var messages = try #require(file?["messages"] as? [[String: Any]])
        #expect(messages.removeLast()["updateDataModel"] != nil)
        let alone = A2UIImporter.importJSON(try JSONSerialization.data(withJSONObject: messages))
        let list = try #require(alone.screens.first?.root).child(0).child(1)
        #expect(list.children.count == 1)
        #expect(alone.diagnostics.contains { $0.reason == .template && $0.componentID == "item_list" })
    }

    // MARK: - Nothing is run

    @Test func actionsAndFunctionsAreNeverRun() {
        // Nothing here can run anything: the importer has no action handler and no processor.
        //   grep -n "MessageProcessor\|ActionHandling\|outboundListener" Layer/A2UI/A2UIImporter.swift
        // finds nothing. This test only asserts what is reported.
        let data = Data("""
            [{"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\(Self.basic)"}},
             {"version":"1.0","updateComponents":{"surfaceId":"s","components":[
               {"id":"root","component":"Column","children":["send","own","price"]},
               {"id":"send","component":"Button","child":"send_label","action":{"event":{"name":"send"}}},
               {"id":"send_label","component":"Text","text":"Send"},
               {"id":"own","component":"Button","child":"own_label","action":{"event":{"name":"\(A2UIImporter.layerActionName)"}}},
               {"id":"own_label","component":"Text","text":"Layer's"},
               {"id":"price","component":"Text","text":{"@call":"formatCurrency","args":{"value":3,"currency":"USD"}}}]}},
             {"version":"1.0","callRendererFunction":{"functionCallId":"call_1","surfaceId":"s",
               "callFunction":{"@call":"openUrl","args":{"url":"https://example.com"},"catalogId":"\(Self.basic)"}}}]
            """.utf8)
        let result = A2UIImporter.importJSON(data)
        #expect(result.diagnostics.filter { $0.reason == .actionNotRun }.map(\.componentID) == ["send"])
        let functions = result.diagnostics.filter { $0.reason == .functionNotRun }
        #expect(functions.contains { $0.componentID == "price" && $0.path == "text" })
        #expect(functions.contains { $0.componentID == nil && $0.path == "callRendererFunction" })
        #expect(functions.count == 2)
    }

    // MARK: - Icons and isolation

    @Test func iconNamesBecomeSymbolsThatExist() throws {
        let schema = try #require(BasicCatalog.makeCatalog(version: .v10).components["Icon"]?.schema.jsonValue)
        let names = try #require(schema["/properties/name/oneOf/0/enum"]?.arrayValue).compactMap(\.stringValue)
        #expect(names.count == 59)
        #expect(Set(A2UIIcons.symbols.keys) == Set(names))
        for name in names {
            let symbol = A2UIIcons.symbol(for: name)
            #expect(symbol != SystemSymbol.placeholder, "\(name)")
            #expect(UIImage(systemName: symbol) != nil, "\(name) → \(symbol)")
        }
        // A name not in the table falls back to Layer's own reading of symbol names.
        #expect(A2UIIcons.symbol(for: "star.fill") == "star.fill")
        #expect(A2UIIcons.symbol(for: "xyzzy plugh") == SystemSymbol.placeholder)
    }

    @Test func importingRunsOffTheMainActor() async throws {
        let data = try fixture("a2ui-user-profile")
        let result = await Task.detached { A2UIImporter.importJSON(data) }.value
        #expect(result.screens.count == 1)
        #expect(result.screens.first?.root.child(0).kind == .card)
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: ImportBundleMarker.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// createSurface naming a catalogue (the Basic Catalog unless given), with a data model when
    /// given, then one updateComponents holding `components`: as one array of messages.
    private func surface(_ components: String, catalog: String = basic, dataModel: String? = nil) -> Data {
        let model = dataModel.map { #","dataModel":\#($0)"# } ?? ""
        return Data("""
            [{"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\(catalog)"\(model)}},
             {"version":"1.0","updateComponents":{"surfaceId":"s","components":[\(components)]}}]
            """.utf8)
    }

    /// A tree as kinds and layouts: `group(column)[title,group(row)[avatar,text]]`.
    private func shape(_ node: LayerNode) -> String {
        guard node.isContainer else { return node.kind.rawValue }
        let layout: String
        switch node.resolvedLayout {
        case .free: layout = "free"
        case .overlay: layout = "overlay"
        case .grid(let grid): layout = "grid\(grid.columns)"
        case .stack(let stack): layout = stack.axis == .horizontal ? "row" : "column"
        }
        return "\(node.kind.rawValue)(\(layout))[\(node.children.map(shape).joined(separator: ","))]"
    }

    private func stack(_ node: LayerNode) -> LayerNode.Stack? {
        if case .stack(let stack) = node.resolvedLayout { return stack }
        return nil
    }

    private func all(_ node: LayerNode) -> [LayerNode] {
        [node] + node.children.flatMap(all)
    }

    private func depth(_ node: LayerNode) -> Int {
        node.children.map { depth($0) + 1 }.max() ?? 0
    }
}

private final class ImportBundleMarker {}

private extension LayerNode {
    /// The child at an index, or an empty placeholder, so a wrong tree fails its expectations and doesn't trap.
    func child(_ index: Int) -> LayerNode {
        children.indices.contains(index) ? children[index] : LayerNode(kind: .shape)
    }
}
