import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// Voice sees the tree (plan 6, Task 6): the canvas picture tells each container with its layout in words and what it
/// holds indented under it, in reading order, every node has a handle in one E sequence (call 7), and the pencil names
/// a container it points at.
@MainActor
@Suite("The canvas picture on the tree")
struct CanvasPictureTreeTests {
    /// The picture's lines in full, with the handles of a call.
    private func told(_ login: TreeFixture.Login, handles: VoiceHandles = VoiceHandles(), _ detail: CanvasPicture.Detail = .full)
        -> [String] {
        CanvasPicture.capture(from: login.model, handles: handles).text(detail).split(separator: "\n").map(String.init)
    }

    /// One thing on the fixture's screen selected.
    private func select(_ id: UUID, in login: TreeFixture.Login) {
        login.model.selection = .element(.init(host: .screen(login.screen), element: id))
    }

    /// A column screen "Feed", 24 apart, to the right of Login, out of view: a title "Today", then a card padded 16
    /// holding a text "First post" above a body "Hello world".
    private func addFeed(to login: TreeFixture.Login) {
        let post = LayerNode.container(.card, padding: 16, children: [
            .leaf(.text, frame: CGRect(x: 0, y: 0, width: 200, height: 24), text: "First post"),
            .leaf(.body, frame: CGRect(x: 0, y: 40, width: 321, height: 40), text: "Hello world"),
        ])
        let today = LayerNode.leaf(.title, frame: CGRect(x: 0, y: 0, width: 228, height: 40), text: "Today")
        login.model.store.addColumnScreen([today, post], name: "Feed", origin: CGPoint(x: 2000, y: 0))
    }

    @Test func childrenAreIndentedUnderTheirContainer() {
        let lines = told(TreeFixture.loginWithACardAndARow())
        let expected = [
            #"  E1 title "Welcome" x20 y80 w228 h40"#,
            "  E2 card x20 y140 w353 h160:",
            #"    E3 text "About me" x36 y156 w200 h24"#,
            #"    E4 body "Designing better experiences." x36 y188 w321 h40"#,
            "  E5 row, spacing 12, centred x20 y320 w143 h31:",
            #"    E6 text "Wi-Fi" x20 y324 w80 h24"#,
        ]
        for line in expected {
            #expect(lines.contains(line), "\(line)")
        }
        let toggle = lines.firstIndex { $0.hasPrefix("    E7 toggle x112 y320 w51 h31") }
        #expect(toggle != nil)
        // One after another, each container's under it.
        let places = expected.compactMap(lines.firstIndex(of:)) + [toggle].compactMap { $0 }
        #expect(places == Array((places.first ?? 0)..<(places.first ?? 0) + 7))
    }

    @Test func aRowIsToldInItsOrderAndAFreeContainerTopToBottom() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let handles = VoiceHandles()
        _ = told(login, handles: handles)
        login.model.store.reorder([.node(login.row): [login.toggle, login.label]])
        let lines = told(login, handles: handles)
        let toggle = try #require(lines.firstIndex { $0.hasPrefix("    E7 toggle ") })
        let label = try #require(lines.firstIndex { $0.hasPrefix(#"    E6 text "Wi-Fi" "#) })
        #expect(toggle < label)
        #expect(handles.node("E6") == login.label)
        #expect(handles.node("E7") == login.toggle)

        let stored = TreeFixture.loginWithACardAndARow()
        stored.model.store.reorder([.node(stored.card): [stored.body, stored.about]])
        #expect(stored.model.store.node(stored.card)?.children.map(\.id) == [stored.body, stored.about])
        let read = told(stored)
        let about = try #require(read.firstIndex { $0.hasPrefix(#"    E3 text "About me" "#) })
        let body = try #require(read.firstIndex { $0.hasPrefix("    E4 body ") })
        #expect(about < body)
    }

    @Test func aScreensRootLayoutIsOnItsLine() {
        let login = TreeFixture.loginWithACardAndARow()
        addFeed(to: login)
        #expect(told(login).contains(#"S2 "Feed" 393x852 column, spacing 24"#))
        // A free root has no layout to tell.
        #expect(told(login).contains(#"S1 "Login" 393x852 [in view]"#))
    }

    @Test func theCompactPictureTellsOneScreenWithItsNesting() throws {
        let login = TreeFixture.loginWithACardAndARow()
        addFeed(to: login)
        login.model.viewport = Viewport(offset: CGPoint(x: 1900, y: 0), scale: 1)

        let lines = told(login, .compact)
        let loginLine = try #require(lines.first { $0.hasPrefix(#"S1 "Login""#) })
        #expect(loginLine.hasSuffix(", 5 elements"))
        #expect(!lines.contains { $0.contains("Welcome") })
        #expect(lines.contains(#"S2 "Feed" 393x852 column, spacing 24 [in view]"#))
        #expect(lines.contains { $0.hasPrefix(#"  E8 title "Today" "#) })
        #expect(lines.contains { $0.hasPrefix("  E9 card ") && $0.hasSuffix(":") })
        #expect(lines.contains { $0.hasPrefix(#"    E10 text "First post" "#) })
        #expect(lines.contains { $0.hasPrefix(#"    E11 body "Hello world" "#) })
    }

    @Test func aSelectedContainerIsSelectedItself() throws {
        let login = TreeFixture.loginWithACardAndARow()
        select(login.card, in: login)
        let picture = CanvasPicture.capture(from: login.model, handles: VoiceHandles())
        let lines = picture.text(.full).split(separator: "\n").map(String.init)
        #expect(lines.contains("  E2 card x20 y140 w353 h160 [selected]:"))
        #expect(!lines.contains { ($0.hasPrefix("    E3 ") || $0.hasPrefix("    E4 ")) && $0.contains("[selected]") })
        #expect(lines.filter { $0.contains("[selected]") }.count == 1)
        #expect(picture.selectionInWords == "E2, the card on S1")
    }

    @Test func framesAreScreenPointsThroughTurnedContainers() {
        let login = TreeFixture.loginWithACardAndARow()
        login.model.store.update(login.card) { $0.rotation = 90 }
        let lines = told(login)
        #expect(lines.contains("  E2 card x20 y140 w353 h160 turned 90°:"))
        #expect(lines.contains(#"    E3 text "About me" x149 y148 w200 h24 turned 90°"#))
    }

    @Test func drawingsStayUntold() {
        let login = TreeFixture.loginWithACardAndARow()
        login.model.store.addCanvasNode(.leaf(.drawing, frame: CGRect(x: 800, y: 400, width: 100, height: 100)))
        #expect(login.model.store.tree.canvas.map(\.kind) == [.stickyNote, .drawing])

        let handles = VoiceHandles()
        let picture = CanvasPicture.capture(from: login.model, handles: handles)
        #expect(picture.loose.map(\.kind) == ["sticky note"])
        #expect(!picture.text(.full).contains("drawing"))
        // The seven on the screen and the note: nothing was given the next handle on the quiet.
        #expect(handles.node("E8") == login.note)
        #expect(handles.node("E9") == nil)
    }

    @Test func theDesignsOwnDevicesAreTold() throws {
        let login = TreeFixture.loginWithACardAndARow()
        #expect(!told(login).contains { $0.hasPrefix("This design's own devices") })

        let kiosk = login.model.store.addCustomDevice(.custom(name: "Kiosk", size: CGSize(width: 1080, height: 1920), family: .other))
        #expect(!kiosk.isEmpty)
        var picture = CanvasPicture.capture(from: login.model, handles: VoiceHandles())
        let devices = #"This design's own devices: "Kiosk" 1080x1920."#
        #expect(picture.text(.full).split(separator: "\n").last.map(String.init) == devices)
        #expect(picture.text(.compact).hasSuffix("\n" + devices))
        // Last, but for a change for one screen's last line.
        picture.scope = "S1"
        #expect(picture.text(.full).hasSuffix("\n" + devices + "\n" + CanvasPicture.alone("S1")))
    }

    /// A design's own device read from a file as 1e300 by 1e19 points, which no whole number holds, is told as the
    /// largest length a design has, as the device picker says it (`wholePoints`), and so is a thing that far along.
    @Test func aDeviceTooLargeForAWholeNumberIsToldWithoutTrapping() {
        let login = TreeFixture.loginWithACardAndARow()
        let huge = DeviceFrame.custom(name: "Huge", size: CGSize(width: 1e300, height: 1e19), family: .other)
        // As a file holds it: one the design is given by hand is refused (`DeviceFrame.problems`).
        login.model.store.changeTree(writing: 0) { $0.settings.customDevices.append(huge) }
        let far = LayerNode.leaf(.title, frame: CGRect(x: 1e300, y: 20, width: 100, height: 40), text: "Far")
        login.model.store.addFreeScreen([far], name: "Huge", device: huge, origin: CGPoint(x: 2000, y: 0))

        let lines = told(login)
        #expect(lines.contains(#"S2 "Huge" 1000000x1000000"#))
        #expect(lines.contains { $0.hasPrefix(#"  E8 title "Far" x"#) })
        #expect(lines.last == #"This design's own devices: "Huge" 1000000x1000000."#)
    }

    @Test func handlesSurviveARegroup() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let handles = VoiceHandles()
        _ = told(login, handles: handles)
        // Ungrouped by hand, as the Format panel's Ungroup does.
        _ = try #require(login.model.store.ungroup(.init(host: .screen(login.screen), element: login.row)))
        #expect(login.model.store.node(login.row) == nil)

        let lines = told(login, handles: handles)
        #expect(lines.contains(#"  E6 text "Wi-Fi" x20 y324 w80 h24"#))
        #expect(lines.contains { $0.hasPrefix("  E7 toggle x112 y320 w51 h31") })
        #expect(!lines.contains { $0.contains("E5") })
        #expect(handles.node("E6") == login.label)
        #expect(handles.node("E7") == login.toggle)
    }

    @Test func thePencilNamesTheContainerItPointsAt() throws {
        let login = TreeFixture.loginWithACardAndARow()
        let model = login.model
        model.tool = .select
        // A line of its own: on the app's, a call started by a test running alongside would end this design's.
        model.phoneLine = PhoneLine()
        let pencil = PencilVoice(model: model, makeRoute: { FakeRoute() }, makeRunner: { _ in FakeRunner() })
        pencil.squeezeIsOff = { false }
        pencil.phoneCallIsUp = { false }
        pencil.otherWindows = { [] }
        pencil.readiness = { .ready }
        model.pencilVoice = pencil

        // The card's empty area, below what it holds: the view shows the canvas unscrolled and unzoomed.
        pencil.squeezeBegan(at: CGPoint(x: 300, y: 280), azimuth: nil)
        #expect(model.selection == .element(.init(host: .screen(login.screen), element: login.card)))
        let pointed = try #require(CanvasPicture.capture(from: model, handles: VoiceHandles()).selectionInWords)
        #expect(VoiceAgent.thingHint(pointed).contains("E2, the card"))

        pencil.call?.end()
        model.endVoiceCall()
    }

    @Test func theVocabularyIsTheLeavesWords() {
        let vocabulary = TreeFixture.loginWithACardAndARow().model.voiceVocabulary
        for words in ["Login", "Welcome", "About me", "Designing better experiences.", "Wi-Fi", "Idea"] {
            #expect(vocabulary.contains(words), "\(words)")
        }
    }

    @Test func layoutsAreToldInWords() {
        typealias Stack = LayerNode.Stack
        #expect(CanvasPicture.words(for: nil) == nil)
        #expect(CanvasPicture.words(for: .free) == nil)
        #expect(CanvasPicture.words(for: .stack(Stack(axis: .horizontal, spacing: 12, alignment: .center))) == "row, spacing 12, centred")
        #expect(CanvasPicture.words(for: .stack(Stack(axis: .vertical, spacing: 16))) == "column, spacing 16")
        #expect(CanvasPicture.words(for: .stack(Stack(axis: .horizontal, spacing: 8, alignment: .end))) == "row, spacing 8, bottom")
        #expect(CanvasPicture.words(for: .stack(Stack(axis: .vertical, spacing: 8, alignment: .end))) == "column, spacing 8, right")
        #expect(CanvasPicture.words(for: .stack(Stack(axis: .vertical, spacing: 8, alignment: .fill))) == "column, spacing 8, stretched")
        #expect(CanvasPicture.words(for: .grid(LayerNode.Grid(columns: 2, columnSpacing: 12, rowSpacing: 12))) == "grid of 2, spacing 12")
        #expect(CanvasPicture.words(for: .grid(LayerNode.Grid(columns: 3, columnSpacing: 12, rowSpacing: 16)))
            == "grid of 3, spacing 12 across, 16 down")
        #expect(CanvasPicture.words(for: .overlay(LayerNode.Alignment())) == "overlay")
        // A spacing a file held as no whole number is told without trapping.
        #expect(CanvasPicture.words(for: .stack(Stack(axis: .vertical, spacing: .nan))) == "column, spacing 0")
    }
}
