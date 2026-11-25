import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

/// A straight pen stroke between two canvas points, made at its own moment so that no two are taken for one.
private func stroke(from start: CGPoint, to end: CGPoint, at seconds: Double) -> PKStroke {
    let points = (0...10).map { step in
        let t = CGFloat(step) / 10
        return PKStrokePoint(
            location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
            timeOffset: Double(step) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
        )
    }
    let made = Date(timeIntervalSinceReferenceDate: 810_000_000 + seconds)
    return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: made))
}

/// The older-version message, exactly as the user sees it.
private let olderMessage = "This design was made by an earlier version of Layer and can't be opened by this one."

/// Version 4 of the design file: the tree saved as it is, a design from an earlier version
/// refused with its message and skipped by Siri and Spotlight, and what this build can't read
/// kept at its place (plan 2, Task 8).
@Suite("The file, version 4")
@MainActor
struct DesignFileV4Tests {
    // MARK: Helpers

    private func element(_ kind: ElementKind, at y: CGFloat = 100) -> LayerNode {
        .leaf(kind, frame: CGRect(x: 20, y: y, width: 200, height: 40), text: kind.placeholder, tint: Theme.accent)
    }

    /// The JSON object of a saved package's design.
    private func manifest(of package: FileWrapper) throws -> [String: Any] {
        let data = try #require(package.fileWrappers?[DesignPackage.design]?.regularFileContents)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The design's content in a saved package.
    private func content(of package: FileWrapper) throws -> [String: Any] {
        try #require(try manifest(of: package)["content"] as? [String: Any])
    }

    /// A package holding `json` as its design, with `parts` beside it.
    private func package(_ json: [String: Any], parts: [String: FileWrapper] = [:]) throws -> FileWrapper {
        var all = parts
        all[DesignPackage.design] = FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: json))
        return FileWrapper(directoryWithFileWrappers: all)
    }

    /// A package holding `tree` as version 4 writes it.
    private func package(_ tree: TreeContent) throws -> FileWrapper {
        FileWrapper(directoryWithFileWrappers: [
            DesignPackage.design: FileWrapper(regularFileWithContents: try TreeManifest.encode(tree, fileName: nil)),
        ])
    }

    /// A package as version 3 saved it: one list of elements, each saying what it is on.
    private func versionThreePackage() throws -> FileWrapper {
        let screen = UUID()
        return try package([
            "version": 3,
            "content": [
                "screens": [["id": screen.uuidString, "name": "Screen 1", "origin": [0, 0], "scale": 1]],
                "elements": [["id": UUID().uuidString, "kind": "title", "parent": screen.uuidString,
                              "frame": [[20, 100], [200, 40]], "text": "Title", "tint": ["red": 0, "green": 0, "blue": 0]]],
                "canvas": ["showsGrid": true],
            ],
        ])
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Writing

    @Test func aDesignIsSavedAsVersion4WithTreesAndCanvasNodes() throws {
        let title = element(.title), button = element(.button, at: 200)
        var holder = LayerNode(kind: .group)
        holder.children = [title, button]
        var note = element(.stickyNote)
        note.scale = 0.66
        var file = DesignFile()
        file.content.screens = [TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: nil, root: holder)]
        file.content.canvas = [note]

        let package = try file.wrapper()

        #expect(try manifest(of: package)["version"] as? Int == 4)
        let saved = try self.content(of: package)
        let screens = try #require(saved["screens"] as? [[String: Any]])
        let root = try #require(screens.first?["root"] as? [String: Any])
        let children = try #require(root["children"] as? [[String: Any]])
        #expect(children.map { $0["id"] as? String } == [title.id.uuidString, button.id.uuidString])
        #expect(children.map { $0["kind"] as? String } == ["title", "button"])
        let canvas = try #require(saved["canvas"] as? [[String: Any]])
        #expect(canvas.map { $0["id"] as? String } == [note.id.uuidString])
        #expect(canvas.first?["scale"] as? Double == 0.66)
        #expect(saved["elements"] == nil)
        #expect(saved["floating"] == nil)
        #expect(screens.allSatisfy { $0["elements"] == nil })
    }

    @Test func drawingsInkIsSavedUnderTheirNodeIDs() throws {
        let strokes = [
            stroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 160), at: 1),
            stroke(from: CGPoint(x: 900, y: 700), to: CGPoint(x: 960, y: 760), at: 2),
        ]
        let file = DesignFile(drawing: PKDrawing(strokes: strokes))
        let drawings = file.content.canvas.filter { $0.kind == .drawing }
        #expect(drawings.count == 2)

        let package = try file.wrapper()

        let ink = try #require(package.fileWrappers?[DesignPackage.ink]?.fileWrappers)
        #expect(Set(ink.keys) == Set(drawings.map(\.id.uuidString)))
        for drawing in drawings {
            #expect(drawing.content.ink != nil)
            #expect(ink[drawing.id.uuidString]?.regularFileContents == drawing.content.ink)
        }
        let reopened = try DesignFile(wrapper: package)
        let read = reopened.content.canvas.filter { $0.kind == .drawing }
        #expect(read.map(\.id) == drawings.map(\.id))
        #expect(read.map(\.content.ink) == drawings.map(\.content.ink))
        #expect(reopened.content == file.content)
    }

    // MARK: Older and newer designs

    @Test func anOlderDesignIsRefusedWithItsMessage() throws {
        let package = try versionThreePackage()
        let error = #expect(throws: DesignFile.ReadError.self) { try DesignFile(wrapper: package) }
        #expect(error == .olderVersion(3))
        #expect(error?.localizedDescription == olderMessage)

        // Version 1 was one file rather than a package.
        let single = FileWrapper(regularFileWithContents: Data("""
            {"version":1,"drawing":"\(PKDrawing().dataRepresentation().base64EncodedString())","content":{"screens":[]}}
            """.utf8))
        let first = #expect(throws: DesignFile.ReadError.self) { try DesignFile(wrapper: single) }
        #expect(first == .olderVersion(1))
        #expect(first?.localizedDescription == olderMessage)
    }

    @Test func siriAndSpotlightSkipADesignTheyCannotOpen() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("Old.layer")
        try versionThreePackage().write(to: old, options: .atomic, originalContentsURL: nil)
        var file = DesignFile()
        file.content.title = "New"
        let new = folder.appendingPathComponent("New.layer")
        try file.wrapper().write(to: new, options: .atomic, originalContentsURL: nil)

        let error = #expect(throws: DesignFile.ReadError.self) { try DesignFile.content(at: old) }
        #expect(error == .olderVersion(3))
        #expect(DesignLibrary.listed(old) == nil)
        #expect(DesignLibrary.read(old) == nil)
        #expect(DesignLibrary.listed(new)?.title == "New")

        let listing = DesignLibrary.list(in: [folder], isDownloaded: { _ in true })
        #expect(listing.designs.map(\.url.lastPathComponent) == ["New.layer"])
    }

    // MARK: Reading

    @Test func anUnknownKindOnTheCanvasIsKeptAtItsPlace() throws {
        let note = UUID(), hologram = UUID(), hologramInk = UUID(), drawing = UUID()
        let drawingInk = PKDrawing(strokes: [stroke(from: .zero, to: CGPoint(x: 40, y: 40), at: 3)]).dataRepresentation()
        let canvas: [[String: Any]] = [
            ["id": note.uuidString, "kind": "stickyNote", "frame": [[0, 0], [150, 150]], "scale": 1, "text": "Note"],
            ["id": hologram.uuidString, "kind": "hologram", "ink": hologramInk.uuidString],
            ["id": drawing.uuidString, "kind": "drawing", "frame": [[300, 300], [40, 40]], "scale": 1],
        ]
        let original = try package(["version": 4, "content": ["screens": [], "canvas": canvas]], parts: [
            DesignPackage.ink: FileWrapper(directoryWithFileWrappers: [
                hologramInk.uuidString: FileWrapper(regularFileWithContents: Data([1, 2, 3])),
                drawing.uuidString: FileWrapper(regularFileWithContents: drawingInk),
            ]),
        ])

        let file = try DesignFile(wrapper: original)

        #expect(file.content.canvas.map(\.kind) == [.stickyNote, .drawing])
        #expect(file.content.unreadCanvas.map(\.index) == [1])
        #expect(file.content.canvas.last?.content.ink == drawingInk)
        // Saved afresh, and over the file it came from.
        for saved in [try file.wrapper(), try file.wrapper(replacing: original)] {
            let written = try #require(try content(of: saved)["canvas"] as? [[String: Any]])
            #expect(written.map { $0["kind"] as? String } == ["stickyNote", "hologram", "drawing"])
            #expect(written.map { $0["id"] as? String } == [note.uuidString, hologram.uuidString, drawing.uuidString])
            #expect(written[1]["ink"] as? String == hologramInk.uuidString)
            let ink = saved.fileWrappers?[DesignPackage.ink]?.fileWrappers
            #expect(ink?[hologramInk.uuidString]?.regularFileContents == Data([1, 2, 3]))
            #expect(ink?[drawing.uuidString]?.regularFileContents == drawingInk)
        }
    }

    /// Keys a newer Layer put inside a node's style, layout, padding, sizing, accessibility, sketch
    /// or source are written back into those parts, after an edit of the part too; a picture one of
    /// them names stays in the package.
    @Test func keysInsideANodesPartsSurviveASave() throws {
        let card = UUID(), label = UUID(), picture = UUID()
        let node: [String: Any] = [
            "id": label.uuidString, "kind": "text", "frame": [[0, 0], [120, 24]], "text": "Hello",
            "style": ["fontSize": 17, "letterSpacing": 2, "backgroundImage": picture.uuidString],
            "width": ["mode": "fixed", "curve": "ease"],
            "accessibility": ["label": "Greeting", "traits": ["header"]],
            "sketch": ["originalBounds": [[0, 0], [10, 10]], "normalizedBounds": [[0, 0], [1, 1]], "confidence": 0.5,
                       "decidedBy": "rules", "placement": "leading", "pressure": 0.25],
            "source": ["origin": "generated", "key": "greeting", "model": "future"],
        ]
        let container: [String: Any] = [
            "id": card.uuidString, "kind": "card", "frame": [[20, 100], [200, 80]], "children": [node],
            "layout": ["type": "stack", "axis": "vertical", "spacing": 8, "wraps": true],
            "padding": ["top": 16, "leading": 16, "bottom": 16, "trailing": 16, "safeArea": "keyboard"],
        ]
        let screen: [String: Any] = ["id": UUID().uuidString, "name": "Screen", "origin": [0, 0], "scale": 1,
                                     "root": ["id": UUID().uuidString, "kind": "group", "children": [container]]]
        let original = try package(["version": 4, "content": ["screens": [screen], "canvas": []]], parts: [
            DesignPackage.images: FileWrapper(directoryWithFileWrappers: [
                picture.uuidString: FileWrapper(regularFileWithContents: Data([7, 7, 7])),
            ]),
        ])

        var file = try DesignFile(wrapper: original)
        let read = try #require(file.content.screens.first?.root.children.first)
        #expect(read.unknownPartKeys["layout"]?["wraps"] == .bool(true))
        #expect(read.unknownPartKeys["padding"]?["safeArea"] == .string("keyboard"))
        let text = try #require(read.children.first)
        #expect(text.style.fontSize == 17)
        #expect(text.unknownPartKeys["style"]?["letterSpacing"] == .number(2))
        #expect(Set(text.unknownPartKeys.keys) == ["style", "width", "accessibility", "sketch", "source"])
        // The style is edited: what it didn't know stays in it.
        file.content.screens[0].root.children[0].children[0].style.fontSize = 20

        let saved = try file.wrapper()
        let screens = try #require(try content(of: saved)["screens"] as? [[String: Any]])
        let root = try #require(screens.first?["root"] as? [String: Any])
        let writtenCard = try #require((root["children"] as? [[String: Any]])?.first)
        let layout = try #require(writtenCard["layout"] as? [String: Any])
        #expect(layout["wraps"] as? Bool == true && layout["type"] as? String == "stack")
        #expect((writtenCard["padding"] as? [String: Any])?["safeArea"] as? String == "keyboard")
        let writtenText = try #require((writtenCard["children"] as? [[String: Any]])?.first)
        let style = try #require(writtenText["style"] as? [String: Any])
        #expect(style["fontSize"] as? Double == 20)
        #expect(style["letterSpacing"] as? Double == 2)
        #expect((writtenText["width"] as? [String: Any])?["curve"] as? String == "ease")
        #expect((writtenText["accessibility"] as? [String: Any])?["traits"] as? [String] == ["header"])
        #expect((writtenText["sketch"] as? [String: Any])?["pressure"] as? Double == 0.25)
        #expect((writtenText["source"] as? [String: Any])?["model"] as? String == "future")
        #expect(saved.fileWrappers?[DesignPackage.images]?.fileWrappers?[picture.uuidString]?.regularFileContents == Data([7, 7, 7]))

        // Read again, it is the same design: nothing this version knows was taken for unknown.
        let again = try DesignFile(wrapper: saved)
        #expect(again.content == file.content)
    }

    /// A screen this build can't read, here one whose root lays its children out in a way a newer
    /// Layer added, doesn't stop the design from opening: the other screens open, and that one is
    /// written back as it was read, in its place among them, with the picture it names.
    @Test func aScreenThisBuildCannotReadIsKeptAndTheRestOpen() throws {
        let first = UUID(), unread = UUID(), last = UUID(), picture = UUID()
        func screen(_ id: UUID, _ name: String, x: Double, root: [String: Any]) -> [String: Any] {
            ["id": id.uuidString, "name": name, "origin": [x, 0], "scale": 1, "root": root]
        }
        let leaf: [String: Any] = ["id": UUID().uuidString, "kind": "image", "frame": [[0, 0], [100, 100]],
                                   "imageID": picture.uuidString]
        let flowing: [String: Any] = ["id": UUID().uuidString, "kind": "group", "layout": ["type": "flow", "gap": 8],
                                      "children": [leaf]]
        let screens: [[String: Any]] = [
            screen(first, "First", x: 0, root: ["id": UUID().uuidString, "kind": "group"]),
            screen(unread, "Flowing", x: 500, root: flowing),
            screen(last, "Last", x: 1000, root: ["id": UUID().uuidString, "kind": "group"]),
        ]
        let original = try package(["version": 4, "content": ["screens": screens, "canvas": []]], parts: [
            DesignPackage.images: FileWrapper(directoryWithFileWrappers: [
                picture.uuidString: FileWrapper(regularFileWithContents: Data([4, 2])),
            ]),
        ])

        let file = try DesignFile(wrapper: original)

        #expect(file.content.screens.map(\.id) == [first, last])
        #expect(file.content.unreadScreens.map(\.index) == [1])
        for saved in [try file.wrapper(), try file.wrapper(replacing: original)] {
            let written = try #require(try content(of: saved)["screens"] as? [[String: Any]])
            #expect(written.map { $0["id"] as? String } == [first, unread, last].map(\.uuidString))
            #expect(NSDictionary(dictionary: written[1]).isEqual(to: screens[1]))
            #expect(saved.fileWrappers?[DesignPackage.images]?.fileWrappers?[picture.uuidString]?.regularFileContents == Data([4, 2]))
        }

        // Siri and Spotlight read it too.
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("Flowing.layer")
        try original.write(to: url, options: [], originalContentsURL: nil)
        #expect(try DesignFile.content(at: url).screens.map(\.id) == [first, last])
    }

    @Test func savedFramesAreLaidOutAgainOnOpening() throws {
        var screen = TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: nil)
        screen.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .start))
        var button = LayerNode(kind: .button)
        button.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        screen.root.children = [button]
        var tree = TreeContent()
        tree.screens = [screen]
        let package = try package(tree)

        let opened = try #require(try DesignFile(wrapper: package).content.screens.first?.root.children.first)

        #expect(opened.id == button.id)
        #expect(opened.frame.minX == 20)
        #expect(opened.frame.minY == DeviceFrame.iPhone.safeTop + 20)
        // What Siri and Spotlight read is laid out the same way.
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Column.layer")
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
        let read = try #require(try DesignFile.content(at: url).screens.first?.root.children.first)
        #expect(read.frame == opened.frame)
    }

    @Test func aFileWithTwoNodesOfOneIDOpensAndSavesBoth() throws {
        let shared = UUID(), sharedNote = UUID()
        var screen = TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: nil)
        var one = LayerNode(kind: .text)
        one.id = shared
        one.content.text = "One"
        one.frame = CGRect(x: 20, y: 100, width: 200, height: 40)
        var two = one
        two.content.text = "Two"
        two.frame.origin.y = 200
        screen.root.children = [one, two]
        var a = LayerNode(kind: .stickyNote)
        a.id = sharedNote
        a.content.text = "A"
        a.frame = CGRect(x: 600, y: 0, width: 150, height: 150)
        a.scale = 1
        var b = a
        b.content.text = "B"
        b.frame.origin.x = 800
        var tree = TreeContent()
        tree.screens = [screen]
        tree.canvas = [a, b]

        let file = try DesignFile(wrapper: try package(tree))

        #expect(file.content.screens.first?.root.children.map(\.content.text) == ["One", "Two"])
        #expect(file.content.canvas.map(\.content.text) == ["A", "B"])
        // Opened in a store, read and changed, nothing traps and both stay.
        let store = DesignStore(content: file.content)
        #expect(store.shownLeaves(onScreenAt: 0)?.count == 2)
        store.setTitle("Twins")
        #expect(store.content.screens.first?.root.children.map(\.content.text) == ["One", "Two"])
        #expect(store.content.canvas.map(\.content.text) == ["A", "B"])

        var saving = file
        saving.content = store.content
        let saved = try saving.wrapper()
        let written = try content(of: saved)
        let children = try #require(((written["screens"] as? [[String: Any]])?.first?["root"] as? [String: Any])?["children"] as? [[String: Any]])
        #expect(children.map { $0["text"] as? String } == ["One", "Two"])
        #expect(children.allSatisfy { $0["id"] as? String == shared.uuidString })
        let canvas = try #require(written["canvas"] as? [[String: Any]])
        #expect(canvas.map { $0["text"] as? String } == ["A", "B"])
        #expect(canvas.allSatisfy { $0["id"] as? String == sharedNote.uuidString })
        #expect(try DesignFile(wrapper: saved).content == store.content)
    }

    @Test func aCustomFrameAndTokensSurviveSaving() throws {
        var frame = DeviceFrame.custom(name: "Kiosk", size: CGSize(width: 600, height: 900), family: .tablet)
        frame.margin = 24
        var tree = TreeContent()
        tree.settings.customDevices = [frame]
        tree.settings.tokens.rhythm = [4, 8, 16]
        tree.settings.tokens.card.radius = 20
        tree.screens = [TreeScreen(name: "Kiosk", origin: .zero, scale: 1, deviceID: frame.id)]

        let reopened = try DesignFile(wrapper: DesignFile(content: tree).wrapper()).content

        #expect(reopened.settings.customDevices == [frame])
        #expect(reopened.settings.tokens == tree.settings.tokens)
        let screen = try #require(reopened.screens.first)
        #expect(reopened.device(of: screen) == frame)
        // Opening laid the screen out at its own device's size.
        #expect(screen.root.frame.size == frame.size)
    }

    // MARK: Unread canvas nodes through changes (F3)

    /// A canvas of a group of two notes, a node this build can't read, and a note: the unread
    /// one at index 1, just in front of the group.
    private func canvasWithAnUnreadNode() -> (content: TreeContent, group: LayerNode, raw: JSONValue) {
        func note(_ text: String, x: CGFloat) -> LayerNode {
            var node = LayerNode(kind: .stickyNote)
            node.content.text = text
            node.frame = CGRect(x: x, y: 0, width: 150, height: 150)
            return node
        }
        var group = LayerNode(kind: .group)
        group.frame = CGRect(x: 0, y: 0, width: 350, height: 150)
        group.scale = 1
        group.children = [note("one", x: 0), note("two", x: 200)]
        var last = note("three", x: 600)
        last.scale = 1
        var tree = TreeContent()
        tree.canvas = [group, last]
        let raw = JSONValue.object(["id": .string(UUID().uuidString), "kind": .string("hologram")])
        tree.unreadCanvas = [LayerNode.UnreadChild(index: 1, raw: raw)]
        TreeRules.apply(to: &tree, after: nil)
        return (tree, tree.canvas[0], raw)
    }

    /// The kinds on the canvas as the file writes them.
    private func writtenKinds(_ content: TreeContent) throws -> [String?] {
        let data = try TreeManifest.encode(content, fileName: nil)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let canvas = try #require((json["content"] as? [String: Any])?["canvas"] as? [[String: Any]])
        return canvas.map { $0["kind"] as? String }
    }

    @Test func anUndoKeepsAnUnreadCanvasNodeInItsPlace() throws {
        let (content, group, raw) = canvasWithAnUnreadNode()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = DesignStore(content: content)
        store.undoManager = undo
        let before = store.content
        #expect(try writtenKinds(store.content) == ["group", "hologram", "stickyNote"])

        // The group's notes are deleted; the rules then take the empty group away.
        store.delete(nodes: Set(group.children.map(\.id)))
        let after = store.content

        #expect(store.content.canvas.map(\.kind) == [.stickyNote])
        #expect(store.content.unreadCanvas == [LayerNode.UnreadChild(index: 0, raw: raw)])
        #expect(try writtenKinds(store.content) == ["hologram", "stickyNote"])
        // Where the unread node sits is part of the board, for the history.
        #expect(TreeChange(from: before, to: after).board)

        // The app names the board meanwhile: a change of its own, which the undo leaves.
        store.setTitle("Named here", undoable: false)
        var late = store.content
        var expected = before
        expected.title = "Named here"

        undo.undo()

        #expect(store.content == expected)
        #expect(store.content.unreadCanvas == [LayerNode.UnreadChild(index: 1, raw: raw)])
        #expect(try writtenKinds(store.content) == ["group", "hologram", "stickyNote"])

        // Siri's late undo takes the change back the same way.
        late.takeBack(after, to: before)
        #expect(late.canvas.map(\.id) == expected.canvas.map(\.id))
        #expect(late.unreadCanvas == [LayerNode.UnreadChild(index: 1, raw: raw)])
        #expect(try writtenKinds(late) == ["group", "hologram", "stickyNote"])
    }

    @Test func deletingACanvasGroupBehindAnUnreadNodeKeepsItsPlace() throws {
        let (content, group, raw) = canvasWithAnUnreadNode()
        let store = DesignStore(content: content)

        // The group goes with what is in it, written to the canvas as a whole host.
        store.delete(nodes: Set([group.id] + group.children.map(\.id)))

        #expect(store.content.canvas.map(\.kind) == [.stickyNote])
        #expect(store.content.unreadCanvas == [LayerNode.UnreadChild(index: 0, raw: raw)])
        #expect(try writtenKinds(store.content) == ["hologram", "stickyNote"])
    }
}
