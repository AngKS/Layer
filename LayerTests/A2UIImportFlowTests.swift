import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// A2UI brought in by a drop, a paste or Files: imported and laid out off the main actor, then made new screens in one
/// undo step, with what wasn't brought in as it was written listed by reason (plan 3, Task 10; calls 17 and 18).
@MainActor
@Suite struct A2UIImportFlowTests {
    private static let basic = "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

    @Test func anImportIsNewScreensInOneUndoStep() async throws {
        let (model, undo) = makeModel()

        let report = await model.importA2UI(try fixture("a2ui-scaffold-simple-login-form"))

        #expect(report.screens.count == 1)
        let id = try #require(report.screens.first)
        let root = try #require(model.store.root(of: id))
        #expect(leaves(of: root).map(\.kind) == [.title, .textField, .textField, .button])
        #expect(model.store.tree.screens.map(\.id) == [id])
        #expect(undo.undoActionName == "Import A2UI")
        undo.undo()
        #expect(model.store.tree.screens.isEmpty)
        #expect(!undo.canUndo)
    }

    #if DEBUG
    @Test func anImportLaysOutOffTheMainActor() async throws {
        let (model, _) = makeModel()
        let other = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 0.5))
        let before = Set(model.store.tree.screens.flatMap { TreeEdit.ids(in: $0.root) } + [other.id])

        let report = await model.importA2UI(try fixture("a2ui-scaffold-simple-login-form"))

        let id = try #require(report.screens.first)
        let rootID = try #require(model.store.root(of: id)?.id)
        #expect(!before.contains(rootID))
        let ahead = GenerationWork.layoutsAhead(of: rootID)
        #expect(ahead.total == 1)
        #expect(ahead.onMainThread == 0)
        #expect(LayoutEngine.timesLaidOut(rootID) == 1)
    }

    @Test func aSettingsChangeWhileItWorksIsLaidOutAgainOffTheMainActor() async throws {
        let (model, _) = makeModel()
        let login = try fixture("a2ui-scaffold-simple-login-form")

        // `importA2UI`'s two halves, with the new-screen device made the iPad while the first works off the main actor.
        let settings = model.store.tree.settings
        let prepared = await Task.detached { AppModel.preparedA2UI(login, settings: settings) }.value
        model.store.updateCanvas { $0.sketchDeviceID = "ipad" }
        let report = await model.commitA2UI(prepared)

        let id = try #require(report.screens.first)
        let screen = try #require(model.store.tree.screens.first { $0.id == id })
        #expect(screen.deviceID == "ipad")
        #expect(screen.root.frame.size == DeviceFrame.named("ipad").size)
        let ahead = GenerationWork.layoutsAhead(of: screen.root.id)
        #expect(ahead.total == 2)
        #expect(ahead.onMainThread == 0)
        #expect(LayoutEngine.timesLaidOut(screen.root.id) == 2, "laid out twice ahead, and not in the commit")
    }
    #endif

    @Test func anImportWithNothingUsableMakesNoScreenAndSaysWhy() async {
        let (model, undo) = makeModel()
        let rootless = Data(#"""
            {"version":"1.0","updateComponents":{"surfaceId":"s","components":[{"id":"t","component":"Text","text":"Hi","@catalogId":"\#(Self.basic)"}]}}
            """#.utf8)

        let report = await model.importA2UI(rootless)

        #expect(report.screens.isEmpty)
        #expect(model.store.tree.screens.isEmpty)
        #expect(!undo.canUndo)
        #expect(report.groups.contains { $0.reason == .missingRoot })
        #expect(report.needsShowing)
    }

    @Test func diagnosticsAreGroupedByReason() async throws {
        let modal = try fixture("a2ui-modal")
        let diagnostics = A2UIImporter.importJSON(modal, tokens: .standard, trustsLayerLook: true).diagnostics
        let present = Set(diagnostics.map(\.reason))
        #expect(present.count >= 2, "\(diagnostics)")
        let (model, _) = makeModel()

        let report = await model.importA2UI(modal)

        #expect(report.groups.map(\.reason) == A2UIDiagnostic.Reason.allCases.filter(present.contains))
        for group in report.groups {
            #expect(group.diagnostics.count == diagnostics.filter { $0.reason == group.reason }.count, "\(group.reason)")
            #expect(group.diagnostics.allSatisfy { $0.reason == group.reason })
            #expect(group.title == A2UIImportReport.title(for: group.reason))
        }
        #expect(report.screens.count == 1)
        #expect(report.needsShowing)
    }

    @Test func everyReasonHasWords() {
        for reason in A2UIDiagnostic.Reason.allCases {
            #expect(!A2UIImportReport.title(for: reason).isEmpty, "\(reason)")
        }
        #expect(A2UIImportReport.title(for: .actionNotRun) == "Actions aren't run in Layer")
        let titles = A2UIDiagnostic.Reason.allCases.map(A2UIImportReport.title(for:))
        #expect(Set(titles).count == titles.count, "each reason says something of its own")
    }

    @Test func twoSurfacesBecomeTwoScreensSideBySide() async throws {
        let (model, undo) = makeModel()
        let data = Data((surface("one", column(saying: "# One")) + "\n" + surface("two", column(saying: "# Two"))).utf8)

        let report = await model.importA2UI(data)

        #expect(report.screens.count == 2)
        let frames = report.screens.compactMap { model.store.screenFrameOnCanvas($0) }
        #expect(frames.count == 2)
        #expect(frames[1].minX > frames[0].maxX, "\(frames)")
        #expect(report.screens.map { name(of: $0, in: model) } == ["One", "Two"])
        undo.undo()
        #expect(model.store.tree.screens.isEmpty, "both are one step")
    }

    @Test func anImportedScreenIsNamedFromItsTitle() async throws {
        let (model, _) = makeModel()

        let login = await model.importA2UI(try fixture("a2ui-scaffold-simple-login-form"))
        #expect(name(of: login.screens.first, in: model) == "Login")

        let untitled = await model.importA2UI(Data(surface("plain", column(saying: "Hello")).utf8))
        #expect(name(of: untitled.screens.first, in: model) == "A2UI Screen")

        // Its words, at most 40 characters of them.
        let words = "A title that goes on well past forty characters"
        let long = await model.importA2UI(Data(surface("long", column(saying: "# " + words)).utf8))
        #expect(name(of: long.screens.first, in: model) == String(words.prefix(40)))
    }

    @Test func layersOwnExportComesBackAsItWas() async throws {
        var screen = try profileScreen()
        // Neither the title's words nor the new-screen device, so neither can come from call 18's defaults.
        screen.name = "Exported Profile"
        screen.deviceID = "ipad"
        let lines = A2UIExporter.jsonLines(for: screen, surfaceID: "profile")
        let (model, _) = makeModel()
        #expect(model.store.canvas.sketchDevice == .iPhone)

        let report = await model.importA2UI(Data(lines.utf8))

        let id = try #require(report.screens.first)
        let made = try #require(model.store.tree.screens.first { $0.id == id })
        #expect(made.name == "Exported Profile")
        #expect(made.deviceID == "ipad")
        Self.expectSame(made.root, screen.root, isRoot: true)
        #expect(!report.needsShowing, "\(report.groups)")
    }

    @Test func dropsAreToldApart() {
        #expect(CanvasDrop.payload(of: ["symbol:star"]) == .assets(["symbol:star"]))
        let a2ui = #"{"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\#(Self.basic)"}}"#
        #expect(CanvasDrop.payload(of: [a2ui]) == .a2ui(Data(a2ui.utf8)))
        #expect(CanvasDrop.payload(of: ["  \n" + a2ui]) == .a2ui(Data(("  \n" + a2ui).utf8)))
        #expect(CanvasDrop.payload(of: ["hello"]) == nil)
        #expect(CanvasDrop.payload(of: []) == nil)
    }

    /// A file larger than Layer reads A2UI is never read: its size alone says so. This one can't be read at all, so
    /// reading it would say that instead (final review B-I1).
    @Test func aFilePastTheByteCapIsRefusedUnread() async throws {
        let (model, undo) = makeModel()
        let huge = try Self.unreadableFile(bytes: A2UIImporter.maximumBytes + 1)
        defer { try? FileManager.default.removeItem(at: huge) }

        let report = await model.importA2UI(contentsOf: huge)

        #expect(report.screens.isEmpty)
        #expect(model.store.tree.screens.isEmpty)
        #expect(!undo.canUndo)
        #expect(report.groups.flatMap(\.diagnostics).map(\.message) == ["This is larger than 16 MB, so it isn't read."])
        #expect(report.needsShowing)

        // A file inside the cap is read and imported.
        let login = FileManager.default.temporaryDirectory.appendingPathComponent("Login-\(UUID().uuidString).json")
        try fixture("a2ui-scaffold-simple-login-form").write(to: login)
        defer { try? FileManager.default.removeItem(at: login) }
        #expect(await model.importA2UI(contentsOf: login).screens.count == 1)
    }

    /// A file dropped on the canvas that is larger than Layer reads A2UI isn't read either, and the drop says so.
    @Test func aDroppedFilePastTheByteCapIsRefusedUnread() throws {
        let huge = try Self.unreadableFile(bytes: A2UIImporter.maximumBytes + 1)
        defer { try? FileManager.default.removeItem(at: huge) }

        let dropped = try CanvasDrop.DroppedText(file: huge)

        #expect(dropped.isTooLarge)
        #expect(dropped.text == nil)
        #expect(CanvasDrop.payload(ofDropped: [dropped]) == .tooLarge)

        // A file inside the cap is read as its text, and is A2UI.
        let a2ui = #"{"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\#(Self.basic)"}}"#
        let small = FileManager.default.temporaryDirectory.appendingPathComponent("Small-\(UUID().uuidString).json")
        try Data(a2ui.utf8).write(to: small)
        defer { try? FileManager.default.removeItem(at: small) }
        let read = try CanvasDrop.DroppedText(file: small)
        #expect(read.text == a2ui)
        #expect(CanvasDrop.payload(ofDropped: [read, dropped]) == .a2ui(Data(a2ui.utf8)))
    }

    /// A surface's own name is made one line of at most 40 characters, as a name from its title is (final review B-m3).
    @Test func aSurfacesOwnNameIsOneLineOfAtMost40Characters() async throws {
        let (model, _) = makeModel()
        let named = #"""
            {"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\#(Self.basic)","metadata":{"extensions":{"layer":{"name":"  A name\nwritten over\t two lines, and on well past forty characters "}}}}}
            {"version":"1.0","updateComponents":{"surfaceId":"s","components":[\#(column(saying: "# Title"))]}}
            """#

        let report = await model.importA2UI(Data(named.utf8))

        let words = "A name written over two lines, and on well past forty characters"
        #expect(name(of: report.screens.first, in: model) == String(words.prefix(40)))
    }

    /// A screen the design can't take is said with the reason it can't: here, the nodes it would take the design past,
    /// written as a number is (final review B-m4).
    @Test func aScreenTheDesignCantTakeIsSaidWithItsReason() async throws {
        let (model, _) = makeModel()
        // A screen of 4,998 texts, laid out as it is given: 4,999 nodes.
        var crowd = TreeScreen(name: "Crowd", origin: .zero, scale: 1, deviceID: nil)
        crowd.root.children = (0..<4_998).map { _ in
            var text = LayerNode(kind: .text)
            text.frame = CGRect(x: 20, y: 100, width: 80, height: 20)
            return text
        }
        try #require(model.store.addLaidOutScreens([crowd]) == [crowd.id])

        let report = await model.importA2UI(try fixture("a2ui-scaffold-simple-login-form"))

        #expect(report.screens.isEmpty)
        let said = report.groups.flatMap(\.diagnostics).map(\.message).first { $0.contains("isn't imported") } ?? ""
        #expect(said.contains("past \(TreeRules.maximumNodes.formatted()) nodes"), "\(said)")
        #expect(!said.contains("can't hold") && !said.contains("what a screen can't"), "\(said)")
    }

    @Test func idsAreWrittenAsIDs() {
        #expect(A2UIImportReport.title(for: .duplicateID) == "IDs used twice")
    }

    // MARK: - Helpers

    /// A file of `bytes` bytes that can't be read: sparse, so nothing is written to the disk, and readable by no one.
    private static func unreadableFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Huge-\(UUID().uuidString).json")
        try #require(FileManager.default.createFile(atPath: url.path, contents: Data("{".utf8)))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return url
    }

    private func makeModel() -> (AppModel, UndoManager) {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        return (model, undo)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: ImportFlowBundleMarker.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// The design fixture's first screen, as plan 1's export tests read it.
    private func profileScreen() throws -> TreeScreen {
        let url = try #require(Bundle(for: ImportFlowBundleMarker.self).url(forResource: "design-profile", withExtension: "json"))
        let (content, _) = try TreeManifest.decode(try Data(contentsOf: url))
        return try #require(content.screens.first)
    }

    /// One surface on the Basic Catalog, as two lines: createSurface, then updateComponents holding `components`.
    private func surface(_ id: String, _ components: String) -> String {
        """
        {"version":"1.0","createSurface":{"surfaceId":"\(id)","catalogId":"\(Self.basic)"}}
        {"version":"1.0","updateComponents":{"surfaceId":"\(id)","components":[\(components)]}}
        """
    }

    /// A root column holding one text, which is a title when its Markdown is a heading.
    private func column(saying text: String) -> String {
        ##"{"id":"root","component":"Column","children":["t"]},{"id":"t","component":"Text","text":"\##(text)"}"##
    }

    private func name(of screen: TreeScreen.ID?, in model: AppModel) -> String? {
        model.store.tree.screens.first { $0.id == screen }?.name
    }

    /// The nodes that aren't containers, in reading order.
    private func leaves(of node: LayerNode) -> [LayerNode] {
        node.children.flatMap { $0.isContainer ? leaves(of: $0) : [$0] }
    }

    /// Plan 1's `A2UIExportTests.expectSame` (F4): both trees the same in every node's kind, layout, padding (but the
    /// root's, which `TreeRules` writes), sizing, content, style and name, and in the frames of free containers'
    /// children. Ids and `source` are ignored.
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

private final class ImportFlowBundleMarker {}
