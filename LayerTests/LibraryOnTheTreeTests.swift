import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("The library on the tree")
@MainActor
struct LibraryOnTheTreeTests {
    private let watch = DeviceFrame.custom(name: "Watch", size: CGSize(width: 198, height: 242), family: .watch)

    private func makeModel(_ settings: UserDefaults) -> AppModel {
        let model = AppModel(document: LayerDocument(), settings: settings)
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        model.store.updateCanvas { $0.customDevices = [watch] }
        return model
    }

    @Test func theDesignsFramesAreInTheWireframesTab() throws {
        let assets = AssetLibrary.customFrames([watch])
        let asset = try #require(assets.first)
        #expect(assets.count == 1)
        #expect(asset.tab == .wireframes)
        #expect(asset.section == "Custom")
        #expect(asset.name == "Watch")
        #expect(asset.id == "frame:\(watch.id)")
        #expect(AssetLibrary.customFrames([]).isEmpty)
        // After everything the tab already lists, so no tile people know moves.
        let tab = AssetLibrary.matching("", in: .wireframes, including: assets)
        #expect(Array(tab.dropLast()) == AssetLibrary.matching("", in: .wireframes))
        #expect(tab.last == asset)
    }

    @Test func searchFindsACustomFrameByName() {
        let extras = AssetLibrary.customFrames([watch])
        #expect(AssetLibrary.matching("watch", in: .wireframes, including: extras).first?.id == "frame:\(watch.id)")
        #expect(AssetLibrary.searchEverywhere("watch", including: extras).contains { $0.tab == .wireframes && $0.assets.contains { $0.name == "Watch" } })
        #expect(!AssetLibrary.matching("watch", in: .wireframes).contains { $0.id == "frame:\(watch.id)" })
    }

    @Test func aCustomFramePickedMakesAScreenOfIt() throws {
        try withOwnSettings { settings in
            let model = makeModel(settings)
            let asset = try #require(AssetLibrary.customFrames(model.store.tree.settings.customDevices).first)
            model.addAsset(asset)
            let screen = try #require(model.store.tree.screens.last)
            #expect(screen.deviceID == watch.id)
            #expect(screen.root.frame == CGRect(x: 0, y: 0, width: 198, height: 242))
        }
    }

    @Test func aCustomFrameDroppedOntoTheCanvasMakesAScreenOfIt() throws {
        try withOwnSettings { settings in
            let model = makeModel(settings)
            // What a drop reads back from the drag.
            let dropped = try #require(AssetLibrary.asset(id: "frame:\(watch.id)"))
            #expect(dropped.content == .frame(watch.id))
            model.addAsset(dropped, at: CGPoint(x: 300, y: 300))
            #expect(try #require(model.store.tree.screens.last).deviceID == watch.id)

            // A frame of another design adds nothing, and is not listed among this design's recents.
            let other = DeviceFrame.custom(name: "Other", size: CGSize(width: 100, height: 100), family: .phone)
            let count = model.store.tree.screens.count
            model.addAsset(try #require(AssetLibrary.asset(id: "frame:\(other.id)")))
            #expect(model.store.tree.screens.count == count)
            let stored = ["frame:\(other.id)", "frame:\(watch.id)", "frame:iphone"].joined(separator: "\n")
            let recents = AssetLibrary.recents(from: stored, among: [watch])
            #expect(recents.map(\.id) == ["frame:\(watch.id)", "frame:iphone"])
            #expect(recents.first?.name == "Watch")
        }
        #expect(AssetLibrary.asset(id: "frame:nothing") == nil)
    }

    #if DEBUG
    @Test func aTemplateThumbnailIsLaidOutOnce() throws {
        let before = AssetLibrary.templatePreviewsMade(named: "Product")
        let first = try #require(AssetLibrary.templateRoot(named: "Product"))
        let afterFirst = AssetLibrary.templatePreviewsMade(named: "Product")
        // Another test, or the library's view, may have made it already.
        #expect(afterFirst - before <= 1)
        let second = try #require(AssetLibrary.templateRoot(named: "Product"))
        #expect(AssetLibrary.templatePreviewsMade(named: "Product") == afterFirst)
        #expect(afterFirst == 1)
        #expect(first == second)
        #expect(first.children.contains { $0.kind == .card })
        #expect(AssetLibrary.templateRoot(named: "No Such Screen") == nil)
    }

    @Test func theLibraryDrawsNoElements() throws {
        try withOwnSettings { settings in
            let model = makeModel(settings)
            model.addAsset(try #require(AssetLibrary.customFrames([watch]).first))
            let screenID = try #require(model.store.tree.screens.first?.id)
            // The per-version memo is stale after a change, so a projection read lowers: the counter is live.
            model.store.updateTreeScreen(screenID) { $0.name = "One" }
            let live = TreeProjection.lowerings
            _ = model.store.screens
            #expect(TreeProjection.lowerings - live == 1)

            model.store.updateTreeScreen(screenID) { $0.name = "Two" }
            let before = TreeProjection.lowerings
            let devices = model.store.tree.settings.customDevices
            let extras = AssetLibrary.customFrames(devices)
            _ = AssetLibrary.matching("", in: .wireframes, including: extras)
            _ = AssetLibrary.searchEverywhere("screen", including: extras)
            for template in AssetLibrary.templates { #expect(AssetLibrary.templateRoot(named: template.name) != nil) }
            _ = AssetLibrary.recents(from: "frame:\(watch.id)", among: devices)
            #expect(TreeProjection.lowerings - before == 0)
        }
    }
    #endif
}
