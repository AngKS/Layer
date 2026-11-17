import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Layer

@Suite("The asset library")
struct AssetLibraryTests {
    @Test func everyTabHasThingsAndEveryIDLeadsBackToItsAsset() {
        for tab in AssetTab.allCases {
            #expect(!AssetLibrary.matching("", in: tab).isEmpty, "\(tab) is empty")
        }
        #expect(Set(AssetLibrary.all.map(\.id)).count == AssetLibrary.all.count, "two assets share an id")
        for asset in AssetLibrary.all {
            #expect(AssetLibrary.asset(id: asset.id) == asset)
        }
        #expect(AssetLibrary.asset(id: "nothing:at all") == nil)
        #expect(AssetLibrary.asset(id: "Hello there") == nil, "text dropped from another app isn't an asset")
    }

    @Test func everyComponentAndTemplateCanBeMade() {
        for component in AssetLibrary.components {
            #expect(AssetLibrary.element(forComponent: component.id)?.kind == component.kind)
        }
        for template in AssetLibrary.templates {
            #expect((AssetLibrary.template(named: template.name)?.itemCount ?? 0) >= 4, "\(template.name)")
        }
    }

    @Test func searchFindsThingsByWhatTheyAreFor() {
        func names(_ search: String, _ tab: AssetTab) -> [String] { AssetLibrary.matching(search, in: tab).map(\.name) }
        #expect(names("heart fill", .icons) == ["heart.fill"])
        #expect(names("settings", .icons).first == "gearshape", "a gear is what “settings” means")
        #expect(names("delete", .icons).contains("trash"))
        #expect(names("arr", .shapes).contains("Arrow Right"), "a word is found from its start")
        #expect(names("circle", .shapes).first == "Circle")
        #expect(names("search", .components).first == "Search Field")
        #expect(names("login", .wireframes) == ["Sign In"])
        #expect(names("ipad", .wireframes).first == "iPad")
        #expect(names("zzzz", .icons).isEmpty)
        #expect(Set(names("laptop", .wireframes)) == ["MacBook Air 13″", "MacBook Pro 16″", "iMac 24″"])
        #expect(names("imac", .wireframes) == ["iMac 24″"])
    }

    @Test func aSearchGoesToTheTabWithTheStrongestMatch() {
        #expect(AssetLibrary.bestTab(for: "toggle") == .components, "the component, not the settings screen with toggles on it")
        #expect(AssetLibrary.bestTab(for: "tog") == .components, "and so as it is being typed")
        #expect(AssetLibrary.bestTab(for: "star") == .icons)
        #expect(AssetLibrary.bestTab(for: "hexagon") == .shapes)
        #expect(AssetLibrary.bestTab(for: "macbook") == .wireframes)
        #expect(AssetLibrary.bestTab(for: "cloud.sun.rain") == .icons)
        #expect(AssetLibrary.bestTab(for: "zzzz") == nil)
    }

    @Test func anySFSymbolCanBeFoundByItsExactName() {
        let name = "cloud.sun.rain"
        #expect(!SymbolCatalog.categories.flatMap(\.symbols).contains(name), "pick a symbol the catalogue doesn't have")
        #expect(AssetLibrary.matching(name, in: .icons).first?.content == .symbol(name))
        #expect(AssetLibrary.asset(id: "symbol:\(name)")?.name == name)
        #expect(AssetLibrary.customSymbol("not.a.real.symbol.at.all") == nil)
    }

    @Test func recentlyUsedThingsLeadAndArentRepeated() throws {
        let defaults = try #require(UserDefaults(suiteName: "AssetLibraryTests-\(UUID().uuidString)"))
        let star = try #require(AssetLibrary.asset(id: "symbol:star"))
        let button = try #require(AssetLibrary.asset(id: "component:button"))
        AssetLibrary.noteUsed(star, in: defaults)
        AssetLibrary.noteUsed(button, in: defaults)
        AssetLibrary.noteUsed(star, in: defaults)
        #expect(AssetLibrary.recentIDs(from: defaults.string(forKey: AssetLibrary.recentsKey) ?? "") == [star.id, button.id])
    }
}

@Suite("Putting library things on the canvas")
@MainActor
struct AddingAssetsTests {
    private func makeModel() -> AppModel {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        return model
    }

    @Test func aDroppedShapeLandsWhereItWasDropped() throws {
        let model = makeModel()
        let arrow = try #require(AssetLibrary.asset(id: "shape:arrowRight:line"))
        model.addAsset(arrow, at: CGPoint(x: 300, y: 200))
        let added = try #require(model.selectedElement)
        #expect(added.ref.host == .canvas)
        #expect(added.element.kind == .shape)
        #expect(added.element.shape == .arrowRight)
        #expect(added.element.isOn == false, "an outline isn't filled")
        let frame = try #require(model.store.floating.first).canvasFrame
        #expect(abs(frame.midX - 300) <= 1 && abs(frame.midY - 200) <= 1)
    }

    @Test func aComponentDroppedOnAScreenJoinsItInsideItsEdges() throws {
        let model = makeModel()
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 0), scale: 1))
        let button = try #require(AssetLibrary.asset(id: "component:button"))
        // Dropped near the screen's right edge: a full-width button can't sit centred there.
        model.addAsset(button, at: CGPoint(x: 470, y: 400))
        let added = try #require(model.selectedElement)
        #expect(added.ref.host == .screen(screen.id))
        #expect(added.element.frame.minX >= 0 && added.element.frame.maxX <= DeviceFrame.iPhone.size.width)
    }

    @Test func aTemplateIsAWholeScreenInOneUndoStep() throws {
        let model = makeModel()
        let settings = try #require(AssetLibrary.asset(id: "template:Settings"))
        model.addAsset(settings, at: CGPoint(x: 600, y: 400))
        let screen = try #require(model.store.screens.first)
        #expect(screen.name == "Settings")
        #expect(screen.elements.contains { $0.kind == .toggle })
        model.store.undoManager?.undo()
        #expect(model.store.screens.isEmpty)
    }

    @Test func aMacFrameHasAMenuBarsWorthOfRoomAtTheTop() throws {
        let model = makeModel()
        let iMac = try #require(AssetLibrary.asset(id: "frame:imac"))
        model.addAsset(iMac)
        let screen = try #require(model.store.screens.last)
        // New frames come in unselected.
        #expect(model.selection == nil)
        #expect(screen.device.family == .desktop)
        #expect(screen.canvasFrame.height <= 834 - 200, "even an iMac fits in the view")
    }

    @Test func aFrameDroppedOnTheCanvasIsCentredThere() throws {
        let model = makeModel()
        let iPad = try #require(AssetLibrary.asset(id: "frame:ipad"))
        model.addAsset(iPad, at: CGPoint(x: 500, y: 420))
        let frame = try #require(model.store.screens.last).canvasFrame
        #expect(abs(frame.midX - 500) <= 1 && abs(frame.midY - 420) <= 1)
    }
}

@Suite("Shapes")
struct ShapeTests {
    @Test func aShapeIsSavedAndOpensAgain() throws {
        var element = DesignStore.newElement(.shape)
        element.shape = .star
        element.isOn = false
        let data = try JSONEncoder().encode(element)
        let opened = try JSONDecoder().decode(DesignElement.self, from: data)
        #expect(opened.shape == .star)
        #expect(opened.isOn == false)
    }

    @Test func everyPolygonStaysInsideItsFrame() {
        for kind in ShapeKind.allCases {
            for point in kind.polygon ?? [] {
                #expect((0...1).contains(point.x) && (0...1).contains(point.y), "\(kind) has \(point)")
            }
        }
    }

    @Test func shapesAreWrittenAsSwiftUI() {
        var screen = DesignScreen(name: "Shapes", origin: .zero, scale: 1)
        var circle = DesignStore.newElement(.shape)
        circle.shape = .ellipse
        circle.frame = CGRect(x: 20, y: 100, width: 80, height: 80)
        var triangle = DesignStore.newElement(.shape)
        triangle.shape = .triangle
        triangle.isOn = false
        triangle.frame = CGRect(x: 20, y: 300, width: 100, height: 100)
        screen.elements = [circle, triangle]

        let lines = SwiftUICodeGenerator.code(for: screen).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("Ellipse()"))
        #expect(lines.contains(".frame(width: 80, height: 80)"))
        // The outline is drawn inside the frame, half the line's width in from each edge.
        #expect(lines.contains("path.addLines([CGPoint(x: 50, y: 1.5), CGPoint(x: 98.5, y: 98.5), CGPoint(x: 1.5, y: 98.5)])"))
        #expect(lines.contains { $0.hasPrefix(".stroke(") && $0.contains("lineWidth: 3") })
    }
}
