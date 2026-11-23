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
