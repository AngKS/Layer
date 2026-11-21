import CoreGraphics
import Foundation
import Testing
@testable import Layer

@MainActor
private func makeStore() -> (store: DesignStore, undo: UndoManager) {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore(content: DesignContent())
    store.undoManager = undo
    return (store, undo)
}

private let titleSketch = CGRect(x: 150, y: 112, width: 96, height: 40)
private let boxSketch = CGRect(x: 30, y: 300, width: 330, height: 44)
private let noteSketch = CGRect(x: 1200, y: 100, width: 150, height: 150)

@Suite("One list of elements")
@MainActor
struct FlatStoreTests {
    /// Two screens side by side with a title on the first, a note on the open canvas, and
    /// a button on the second, added in that order.
    private func board() throws -> (store: DesignStore, undo: UndoManager, first: DesignScreen, second: DesignScreen, title: DesignElement, note: DesignStore.ElementRef, button: DesignElement) {
        let (store, undo) = makeStore()
        let first = store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
        let second = store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 500, y: 0), scale: 1))
        let title = try #require(store.addElement(.title, from: titleSketch, to: first.id))
        let note = store.addFloating(.stickyNote, from: noteSketch)
        let button = try #require(store.addElement(.button, from: boxSketch.offsetBy(dx: 500, dy: 0), to: second.id))
        return (store, undo, first, second, title, note, button)
    }

    @Test func everythingOnTheBoardIsInOneListAndSaysWhatItIsOn() throws {
        let (store, _, first, second, title, note, button) = try board()

        let elements = store.content.elements
        #expect(elements.map(\.id) == [title.id, note.element, button.id])
        #expect(elements.map(\.parent) == [first.id, nil, second.id])
        // On the open canvas an element says how large it is drawn; on a screen the screen does.
        #expect(elements.map(\.scale) == [nil, store.looseScale, nil])
    }

    @Test func theScreensAndTheOpenCanvasAreViewsOfTheList() throws {
        let (store, _, _, _, title, note, button) = try board()
        #expect(store.screens.map { $0.elements.map(\.id) } == [[title.id], [button.id]])
        #expect(store.floating.map(\.id) == [note.element])
        #expect(store.floating.first?.scale == store.looseScale)
    }

    @Test func anElementIsFoundByItsIdentifierAlone() throws {
        let (store, _, _, second, _, _, button) = try board()
        #expect(store.element(button.id) == button)
        #expect(store.element(button.id)?.parent == second.id)
        #expect(store.element(UUID()) == nil)
    }

    @Test func movingToAnotherScreenChangesWhatItIsOnAndPutsItOnTopThere() throws {
        let (store, _, first, second, title, note, button) = try board()
        let ref = DesignStore.ElementRef(host: .screen(first.id), element: title.id)

        let moved = try #require(store.move(ref, toScreen: second.id, origin: CGPoint(x: 20, y: 80)))

        #expect(moved == DesignStore.ElementRef(host: .screen(second.id), element: title.id))
        #expect(store.element(title.id)?.parent == second.id)
        #expect(store.content.elements.map(\.id) == [note.element, button.id, title.id])
        #expect(store.screens.map { $0.elements.map(\.id) } == [[], [button.id, title.id]])
    }

    @Test func leavingAScreenForTheOpenCanvasKeepsTheSizeItWasDrawnAt() throws {
        let (store, _, first, _, title, _, _) = try board()
        let ref = DesignStore.ElementRef(host: .screen(first.id), element: title.id)

        let moved = try #require(store.move(ref, toScreen: nil, origin: nil))

        #expect(moved.host == .canvas)
        let loose = try #require(store.element(title.id))
        #expect(loose.parent == nil)
        #expect(loose.scale == first.scale)
        #expect(loose.frame.size == title.frame.size)
    }

    @Test func arrangingReordersOnlyAmongWhatSharesItsScreen() throws {
        let (store, _, first, _, title, note, button) = try board()
        let body = try #require(store.addElement(.body, from: boxSketch, to: first.id))
        #expect(store.content.elements.map(\.id) == [title.id, note.element, button.id, body.id])

        store.arrange(DesignStore.ElementRef(host: .screen(first.id), element: body.id), .back)

        // The body and the title swap places; the note and the button stay where they are.
        #expect(store.content.elements.map(\.id) == [body.id, note.element, button.id, title.id])
        #expect(store.screens[0].elements.map(\.id) == [body.id, title.id])
    }

    @Test func deletingAScreenTakesWhatIsOnItOutOfTheList() throws {
        let (store, undo, first, _, title, note, button) = try board()

        store.deleteScreen(first.id)
        #expect(store.content.elements.map(\.id) == [note.element, button.id])

        undo.undo()
        #expect(store.content.elements.map(\.id) == [title.id, note.element, button.id])
    }

    @Test func aCopiedScreenBringsCopiesOfWhatIsOnIt() throws {
        let (store, _, first, _, title, _, _) = try board()

        let copy = try #require(store.duplicateScreen(first.id))

        let copied = store.content.elements.filter { $0.parent == copy.id }
        #expect(copied.count == 1)
        #expect(copied.first?.kind == .title)
        #expect(copied.first?.id != title.id)
        #expect(store.element(title.id)?.parent == first.id)
    }
}

/// Counts notices, which are posted on the thread that changes the history: here, the main one.
private final class Tally: @unchecked Sendable {
    var count = 0
}

/// A gradual edit's step and the saving it asks for (final fix wave, items 11 and 12).
@Suite("A gradual edit's step")
@MainActor
struct GradualEditStepTests {
    /// Typed and deleted again, or a screen written and taken away: the edit ends where it
    /// began, and leaves no step that undoes nothing. The step before is still on top.
    @Test func anEditThatEndsWhereItBeganLeavesNoStep() throws {
        let (store, undo) = makeStore()
        let screen = store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400))
        store.beginEdit()
        store.updateScreen(screen.id) { $0.name = "Settings" }
        store.updateScreen(screen.id) { $0.name = "Screen 1" }
        store.endEdit()
        #expect(undo.canUndo)
        undo.undo()
        #expect(store.screens.isEmpty, "undo takes back the screen added before the edit")
        #expect(!undo.canUndo)
    }

    @Test func anEditThatEndsWhereItBeganOnAnEmptyHistoryLeavesUndoOff() {
        let (store, undo) = makeStore()
        store.beginEdit()
        let screen = store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400))
        store.deleteScreen(screen.id)
        store.endEdit()
        #expect(!undo.canUndo && !undo.canRedo)
        // The next change is a step as ever, and undoes.
        store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400))
        undo.undo()
        #expect(store.screens.isEmpty)
    }

    /// The app's history groups by event, as a document's does: the step taken out leaves
    /// no empty group behind for Undo to light up for.
    @Test func anEditThatEndsWhereItBeganLeavesNoEmptyGroupWhenGroupedByEvent() async {
        let undo = UndoManager()
        let store = DesignStore(content: DesignContent())
        store.undoManager = undo
        store.beginEdit()
        let screen = store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400))
        store.deleteScreen(screen.id)
        store.endEdit()
        // The event's group closes when the run loop turns.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!undo.canUndo)
    }

    /// The same when the edit ends in a later event than its first change, as a failed
    /// generation's does.
    @Test func anEditEndedInALaterEventWhereItBeganLeavesNoStepWhenGroupedByEvent() async {
        let undo = UndoManager()
        let store = DesignStore(content: DesignContent())
        store.undoManager = undo
        store.beginEdit()
        let screen = store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(undo.canUndo)
        store.deleteScreen(screen.id)
        store.endEdit()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!undo.canUndo)
    }

    /// An edit that changed something still undoes as one step.
    @Test func anEditThatChangedSomethingKeepsItsStep() {
        let (store, undo) = makeStore()
        store.beginEdit()
        let screen = store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400))
        store.updateScreen(screen.id) { $0.name = "Settings" }
        store.endEdit()
        #expect(undo.canUndo)
        undo.undo()
        #expect(store.screens.isEmpty && !undo.canUndo)
    }

    /// An edit's step goes in at its first change, which is when the system hears there is
    /// something to save. When the edit ends it is told again, so that the rest of a long
    /// edit isn't lost to an autosave made part way through it.
    @Test func theEndOfAnEditInTheHistoryAsksForASave() {
        let (store, undo) = makeStore()
        let asked = Tally()
        let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerWillCloseUndoGroup, object: undo, queue: nil) { _ in
            asked.count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.beginEdit()
        let screen = store.addScreen(from: CGRect(x: 0, y: 0, width: 200, height: 400))
        let afterFirstChange = asked.count
        #expect(afterFirstChange >= 1)
        store.updateScreen(screen.id) { $0.name = "Settings" }
        #expect(asked.count == afterFirstChange, "later changes join the step without a word")
        store.endEdit()
        #expect(asked.count > afterFirstChange)
    }
}

/// A design as it was saved before elements were one list: each screen held its own
/// elements, and those on the open canvas were a list of their own.
private struct EarlierDesign: Encodable {
    struct Screen: Encodable {
        var id = UUID()
        var name: String
        var origin: CGPoint
        var scale: CGFloat
        var elements: [DesignElement]
    }

    struct Loose: Encodable {
        var element: DesignElement
        var scale: CGFloat
    }

    var screens: [Screen]
    var floating: [Loose]
    var title: String?
}

@Suite("Saving the list of elements")
struct FlatFormatTests {
    private func element(_ kind: ElementKind, at y: CGFloat = 100) -> DesignElement {
        DesignElement(kind: kind, frame: CGRect(x: 20, y: y, width: 200, height: 40), text: kind.placeholder, tint: Theme.accent)
    }

    private func json(_ content: DesignContent) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
    }

    @Test func aDesignIsSavedAsItsScreensAndOneListOfElements() throws {
        var content = DesignContent()
        let screen = DesignScreen(name: "Screen 1", origin: .zero, scale: 1, elements: [element(.title), element(.button, at: 200)])
        content.screens = [screen]
        content.floating = [FloatingElement(element: element(.stickyNote), scale: 0.66)]

        let saved = try json(content)

        let screens = try #require(saved["screens"] as? [[String: Any]])
        #expect(screens.count == 1)
        #expect(screens[0]["elements"] == nil, "a screen no longer holds its elements")
        let elements = try #require(saved["elements"] as? [[String: Any]])
        #expect(elements.map { $0["kind"] as? String } == ["title", "button", "stickyNote"])
        #expect(elements.map { $0["parent"] as? String } == [screen.id.uuidString, screen.id.uuidString, nil])
        #expect(elements.map { $0["scale"] as? Double } == [nil, nil, 0.66])
        #expect(saved["floating"] == nil)
    }

    @Test func aSavedDesignReadsBackAsItWas() throws {
        var content = DesignContent()
        content.screens = [DesignScreen(name: "Screen 1", origin: CGPoint(x: 40, y: 60), scale: 0.5, elements: [element(.title), element(.image, at: 200)])]
        content.floating = [FloatingElement(element: element(.text), scale: 0.5)]
        content.title = "Sign In"

        let read = try JSONDecoder().decode(DesignContent.self, from: JSONEncoder().encode(content))

        #expect(read == content)
    }

    @Test func aDesignSavedBeforeElementsWereOneListStillOpens() throws {
        let title = element(.title)
        let button = element(.button, at: 200)
        let note = element(.stickyNote)
        let earlier = EarlierDesign(
            screens: [.init(name: "Screen 1", origin: CGPoint(x: 40, y: 60), scale: 0.5, elements: [title, button])],
            floating: [.init(element: note, scale: 0.66)],
            title: "Sign In"
        )

        let content = try JSONDecoder().decode(DesignContent.self, from: JSONEncoder().encode(earlier))

        let screen = try #require(content.screens.first)
        #expect(screen.id == earlier.screens[0].id)
        #expect(screen.origin == CGPoint(x: 40, y: 60))
        #expect(screen.elements.map(\.id) == [title.id, button.id])
        #expect(content.floating.map(\.id) == [note.id])
        #expect(content.floating.first?.scale == 0.66)
        #expect(content.elements.map(\.parent) == [screen.id, screen.id, nil])
        #expect(content.title == "Sign In")
    }

    @Test func anElementOfAKindThisVersionDoesNotKnowIsKeptAndWrittenBackWhereItWas() throws {
        var content = DesignContent()
        let screen = DesignScreen(name: "Screen 1", origin: .zero, scale: 1, elements: [element(.title), element(.button, at: 200)])
        content.screens = [screen]
        var saved = try json(content)
        var elements = try #require(saved["elements"] as? [[String: Any]])
        // A later version of Layer put a carousel between the two.
        let carousel: [String: Any] = ["id": UUID().uuidString, "kind": "carousel", "parent": screen.id.uuidString, "pages": 3, "frame": [[20, 150], [353, 180]]]
        elements.insert(carousel, at: 1)
        saved["elements"] = elements

        let read = try JSONDecoder().decode(DesignContent.self, from: JSONSerialization.data(withJSONObject: saved))

        // The design opens with what this version understands.
        #expect(read.screens.first?.elements.map(\.kind) == [.title, .button])
        // And saving it loses nothing.
        let written = try #require(try json(read)["elements"] as? [[String: Any]])
        #expect(written.map { $0["kind"] as? String } == ["title", "carousel", "button"])
        #expect(written[1]["pages"] as? Int == 3)
        #expect(written[1]["parent"] as? String == screen.id.uuidString)
    }

    @Test func elementsThatShareAnIdentifierAreLeftInTheirOrderRatherThanTrapping() {
        // Only a damaged file has two elements with one identifier; arranging them, or
        // Siri's undo putting an order back, leaves them as they are.
        let note = DesignStore.newElement(.stickyNote)
        var content = DesignContent()
        content.add(note, to: nil)
        content.add(note, to: nil)
        let before = content
        content.reorder(nil, to: [note.id, note.id])
        #expect(content == before)
    }

    @Test func aPackageSavedByTheVersionBeforeOpens() throws {
        let earlier = EarlierDesign(
            screens: [.init(name: "Screen 1", origin: .zero, scale: 1, elements: [element(.title)])],
            floating: [], title: nil
        )
        let manifest = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "content": try JSONSerialization.jsonObject(with: JSONEncoder().encode(earlier)),
        ])
        let package = FileWrapper(directoryWithFileWrappers: [DesignPackage.design: FileWrapper(regularFileWithContents: manifest)])

        let file = try DesignFile(wrapper: package)

        #expect(file.content.screens.first?.elements.map(\.kind) == [.title])
        #expect(DesignFile.currentVersion == 3)
    }
}
