import Foundation
import Testing
@testable import Layer

@Suite struct ShareA2UITests {
    @Test func theSharedFileIsTheScreensA2UI() throws {
        let screen = try Self.profileScreen(named: "Profile", deviceID: "ipad-mini")
        let shared = SharedA2UI(screen: screen, typeName: "Profile")

        let result = A2UIImporter.importJSON(shared.data)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
        #expect(result.screens.count == 1)
        let imported = try #require(result.screens.first)
        Self.expectSame(imported.root, screen.root, isRoot: true)
        // The screen's name and device travel in the file (F3).
        #expect(imported.name == "Profile")
        #expect(imported.deviceID == "ipad-mini")

        // One JSON array, a file other A2UI tools read whole.
        let array = try JSONSerialization.jsonObject(with: shared.data)
        #expect((array as? [Any])?.count == 2)
    }

    @Test func theFileIsNamedForTheScreensView() throws {
        let screen = try Self.profileScreen(named: "Sign In", deviceID: nil)
        #expect(SharedA2UI(screen: screen, typeName: DesignScreen.typeName(forScreenNamed: screen.name)).fileName == "SignIn.a2ui.json")
    }

    @Test func nothingIsWrittenUntilShared() throws {
        let screen = try Self.profileScreen(named: "Profile", deviceID: nil)
        // This test's own surface id: other suites write documents too (F13).
        let surface = "NothingIsWrittenUntilShared"
        let before = A2UIExporter.documentsWritten(for: surface)
        let shared = SharedA2UI(screen: screen, typeName: surface)
        #expect(A2UIExporter.documentsWritten(for: surface) == before)
        _ = shared.data
        #expect(A2UIExporter.documentsWritten(for: surface) == before + 1)
    }

    // MARK: - Helpers

    private static func profileScreen(named name: String, deviceID: String?) throws -> TreeScreen {
        let url = try #require(Bundle(for: ShareBundleMarker.self).url(forResource: "design-profile", withExtension: "json"))
        let (content, _) = try TreeManifest.decode(try Data(contentsOf: url))
        var screen = try #require(content.screens.first)
        screen.name = name
        screen.deviceID = deviceID ?? screen.deviceID
        return screen
    }

    /// As `A2UIExportTests.expectSame`: ids and `source` are ignored, and so is the root's padding,
    /// which `TreeRules` writes (F4).
    private static func expectSame(_ got: LayerNode, _ want: LayerNode, isRoot: Bool = false, path: String = "root") {
        #expect(got.kind == want.kind, "\(path) kind")
        #expect(got.resolvedLayout == want.resolvedLayout, "\(path) layout")
        if !isRoot { #expect(got.padding == want.padding, "\(path) padding") }
        #expect(got.width == want.width, "\(path) width")
        #expect(got.height == want.height, "\(path) height")
        #expect(got.content == want.content, "\(path) content")
        #expect(got.style == want.style, "\(path) style")
        #expect(got.name == want.name, "\(path) name")
        let visible = want.children.filter { !$0.isHidden && $0.kind != .drawing }
        #expect(got.children.count == visible.count, "\(path) children")
        for (index, (a, b)) in zip(got.children, visible).enumerated() {
            if want.resolvedLayout == .free {
                #expect(a.frame == b.frame, "\(path)/\(index) frame")
                #expect(a.rotation == b.rotation, "\(path)/\(index) rotation")
            }
            expectSame(a, b, path: "\(path)/\(index)")
        }
    }
}

private final class ShareBundleMarker {}
