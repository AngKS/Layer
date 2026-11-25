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
        #expect(SharedA2UI(screen: screen, typeName: SwiftUICodeGenerator.typeName(of: screen)).fileName == "SignIn.a2ui.json")
    }

    /// The Share menu names a screen's A2UI file and its SwiftUI file from one set of view names, so a second "Sign In"
    /// is `SignIn2` in both (final review B-m2).
    @Test func theA2UIFileIsNamedAsTheSwiftUIViewIs() throws {
        let first = try Self.profileScreen(named: "Sign In", deviceID: nil)
        var second = try Self.profileScreen(named: "Sign-In", deviceID: nil)
        second.id = UUID()
        var tree = TreeContent()
        tree.screens = [first, second]

        let shared = SharedScreen(second, in: tree)

        #expect(shared.codeFileName == "SignIn2.swift")
        #expect(shared.a2ui.fileName == "SignIn2.a2ui.json")
        #expect(shared.code.source.contains("struct SignIn2: View"))
        #expect(SharedScreen(first, in: tree).a2ui.fileName == "SignIn.a2ui.json")
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

    // MARK: - Files made to share

    /// A folder of the test's own to stand for the system's temporary folder.
    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShareA2UITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// A screen's A2UI is written to share in a folder of its own, which goes, file and all, when the share sheet closes:
    /// each share used to leave an `A2UI-<UUID>` folder behind (the sweep, lane 2).
    @Test func theA2UIWrittenToShareGoesWithItsFolderWhenTheSheetCloses() throws {
        let temporary = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let shared = SharedA2UI(screen: try Self.profileScreen(named: "Profile", deviceID: nil), typeName: "Profile")

        let url = try shared.write(in: temporary)

        #expect(url.lastPathComponent == "Profile.a2ui.json")
        // The screen's A2UI: the same JSON, whose objects' keys come in no fixed order.
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSArray
        let screens = try JSONSerialization.jsonObject(with: shared.data) as? NSArray
        #expect(written != nil && written == screens)
        let folder = url.deletingLastPathComponent()
        #expect(folder.lastPathComponent.hasPrefix(SharedA2UI.folderPrefix))
        #expect(Self.contents(of: temporary) == [folder.lastPathComponent])
        ShareFolder.remove(holding: url, prefix: SharedA2UI.folderPrefix)
        #expect(Self.contents(of: temporary).isEmpty)
    }

    /// The SwiftUI files for every screen go the same way: their folder, once the sheet has closed.
    @Test func theSwiftUIFilesWrittenToShareGoWithTheirFolderWhenTheSheetCloses() throws {
        let temporary = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporary) }
        var second = try Self.profileScreen(named: "Settings", deviceID: nil)
        second.id = UUID()
        var tree = TreeContent()
        tree.screens = [try Self.profileScreen(named: "Profile", deviceID: nil), second]

        let urls = try #require(CodeFiles.write(tree, in: temporary))

        #expect(Set(urls.map(\.lastPathComponent)).isSuperset(of: ["Profile.swift", "Settings.swift"]))
        let folders = Set(urls.map { $0.deletingLastPathComponent().lastPathComponent })
        #expect(folders.count == 1 && folders.first?.hasPrefix(CodeFiles.folderPrefix) == true)
        for url in urls { ShareFolder.remove(holding: url, prefix: CodeFiles.folderPrefix) }
        #expect(Self.contents(of: temporary).isEmpty)
    }

    /// Only a folder made to share is taken away: never one whose name doesn't say so, such as the temporary folder
    /// itself, holding a file that was put there some other way.
    @Test func onlyAFolderMadeToShareIsTakenAway() throws {
        let temporary = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let loose = temporary.appendingPathComponent("Profile.a2ui.json")
        try Data("[]".utf8).write(to: loose)

        ShareFolder.remove(holding: loose, prefix: SharedA2UI.folderPrefix)

        #expect(FileManager.default.fileExists(atPath: loose.path))
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
