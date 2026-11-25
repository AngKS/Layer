import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// A leaf of a kind with its kind's words, in the app's accent, where its frame puts it.
private func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> LayerNode {
    .leaf(kind, frame: CGRect(x: x, y: y, width: width, height: height), text: kind.placeholder, tint: Theme.accent)
}

@MainActor
private func makeStore() -> (store: DesignStore, undo: UndoManager) {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let store = DesignStore()
    store.undoManager = undo
    return (store, undo)
}

/// A screen at the canvas origin, drawn at full size, so canvas and screen points agree, its free root holding `nodes`.
private func screenWith(_ nodes: [LayerNode]) -> TreeScreen {
    var root = LayerNode(kind: .group)
    root.layout = .free
    root.children = nodes
    return TreeScreen(name: "Screen 1", origin: .zero, scale: 1, deviceID: nil, root: root)
}

/// Screens named `names`, at the canvas's origin, each with nothing on it, alone in a design.
private func design(ofEmptyScreensNamed names: [String]) -> TreeContent {
    var content = TreeContent()
    content.screens = names.map { TreeScreen(name: $0, origin: .zero, scale: 1, deviceID: nil) }
    return content
}

/// A zigzag scrubbed back and forth across `rect`, as drawn to cross something out.
private func scratch(_ rect: CGRect, passes: Int = 6) -> [CGPoint] {
    var points: [CGPoint] = []
    for pass in 0...passes {
        let y = rect.minY + rect.height * CGFloat(pass) / CGFloat(passes)
        let fromLeft = pass.isMultiple(of: 2)
        for step in 0...20 {
            let t = CGFloat(step) / 20
            points.append(CGPoint(x: fromLeft ? rect.minX + rect.width * t : rect.maxX - rect.width * t, y: y + t * 4))
        }
    }
    return points
}

private func request(_ paths: [[CGPoint]], local: CGRect?) throws -> SketchRequest {
    SketchRequest(
        observation: try #require(SketchAnalyzer.observe(SketchSamples.strokes(paths))),
        placement: local.map { .onScreen(local: $0, existing: []) } ?? .openCanvas,
        strokes: paths
    )
}

@Suite("Element and canvas settings")
struct SettingsTests {
    @Test func designsSavedBeforeTheNewSettingsStillOpen() throws {
        let old = """
            {"screens":[{"id":"\(UUID().uuidString)","name":"Screen 1","origin":[0,0],"scale":1,"root":{"id":"\(UUID().uuidString)","kind":"group","children":[
              {"id":"\(UUID().uuidString)","kind":"title","frame":[[82,112],[228,40]],"text":"Hi","style":{"tint":{"red":0,"green":0,"blue":0}}}
            ]}}],"canvas":[],"settings":{"showsGrid":false,"gridStyle":"lines","gridSpacing":16,"snapsToGuides":true}}
            """
        let content = try JSONDecoder().decode(TreeContent.self, from: Data(old.utf8))
        let title = try #require(content.screens.first?.root.leaves.first)
        #expect(!title.isLocked && !title.isHidden && !title.style.hasShadow && title.content.isOn)
        #expect(title.displayName == "Title")
        #expect(content.settings.showsGrid == false && content.settings.gridSpacing == 16)
        #expect(content.settings.showsFrameNames && content.settings.showsMeasurements && !content.settings.snapsToGrid)
        #expect(content.settings.code == CodeSettings())
    }

    @Test func newSettingsSurviveSavingAndOpening() throws {
        var content = TreeContent()
        var avatar = element(.avatar, 20, 100, 64, 64)
        avatar.name = "Profile"
        avatar.isLocked = true
        avatar.style.borderWidth = 2
        avatar.style.hasShadow = true
        content.screens = [screenWith([avatar])]
        content.settings.background = RGBColor(hex: 0x2A2A2E)
        content.settings.snapsToGrid = true
        content.settings.code.layout = .absolute
        let reopened = try JSONDecoder().decode(TreeContent.self, from: JSONEncoder().encode(content))
        #expect(reopened == content)
        #expect(reopened.settings.isDark)
    }

    @Test func anAvatarIsRoundAndAToggleHasNoText() {
        let avatar = element(.avatar, 0, 0, 64, 64)
        #expect(avatar.resolvedCornerRadius(tokens: .standard) == 32)
        // Round as its code and its view draw it.
        #expect(SwiftUICodeGenerator.Leaf(node: avatar, frame: avatar.frame, rotation: nil, tokens: .standard).isCircular)
        #expect(!ElementKind.toggle.hasText)
        #expect(element(.toggle, 0, 0, 51, 31).hasFill)
    }
}

@Suite("Freeform behaviours")
@MainActor
struct FreeformBehaviourTests {
    @Test func duplicatingAnElementPutsACopyBesideItOnTop() throws {
        let (store, undo) = makeStore()
        let screen = try #require(store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))).id
        let original = try #require(store.sketched(.button, from: CGRect(x: 20, y: 700, width: 353, height: 50), to: screen))
        store.update(original.id) { $0.isLocked = true }

        let copy = try #require(store.duplicate(.init(host: .screen(screen), node: original.id)))
        let elements = store.screenLeaves(screen)
        #expect(elements.count == 2)
        #expect(elements.last?.id == copy.node)
        #expect(elements.last.flatMap { store.ownFrame($0.id) } == original.frame.offsetBy(dx: 16, dy: 16))
        // A copy of a locked element can be moved.
        #expect(elements.last?.isLocked == false)

        undo.undo()
        #expect(store.screenLeaves(screen).count == 1)
    }

    @Test func duplicatingAScreenCopiesItsElementsToTheRight() throws {
        let (store, _) = makeStore()
        let screen = try #require(store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 0.5))).id
        _ = store.sketched(.title, from: CGRect(x: 40, y: 50, width: 100, height: 20), to: screen)
        let copy = try #require(store.duplicateTreeScreen(screen).flatMap(store.treeScreen))
        #expect(copy.name == "Screen 1 Copy")
        let original = try #require(store.canvasFrame(ofScreen: screen))
        #expect(copy.origin.x > original.maxX)
        #expect(copy.root.leaves.count == 1)
        #expect(copy.root.leaves.first?.id != store.screenLeaves(screen).first?.id)
        #expect(DesignStore.copyName(for: "Screen 1", among: ["Screen 1 Copy"]) == "Screen 1 Copy 2")
    }

    @Test func elementsCanBeArrangedUpAndDown() throws {
        let a = element(.image, 0, 0, 100, 100), b = element(.title, 0, 0, 100, 40), c = element(.button, 0, 0, 100, 50)
        let (store, _) = makeStore()
        let id = store.addFreeScreen([a, b, c])
        let ref = NodeRef(host: .screen(id), node: a.id)

        #expect(!store.canArrange(ref, .backward))
        store.arrange(ref, .forward)
        #expect(store.screenLeaves(id).map(\.id) == [b.id, a.id, c.id])
        store.arrange(ref, .front)
        #expect(store.screenLeaves(id).map(\.id) == [b.id, c.id, a.id])
        #expect(!store.canArrange(ref, .front))
        store.arrange(ref, .back)
        #expect(store.screenLeaves(id).map(\.id) == [a.id, b.id, c.id])
    }

    @Test func anElementAlignsToItsScreensEdgesAndMiddle() {
        let frame = CGRect(x: 30, y: 200, width: 100, height: 50)
        let size = DeviceFrame.iPhone.size
        #expect(ElementLayout.aligned(frame, .right, in: size).maxX == size.width)
        #expect(ElementLayout.aligned(frame, .centerX, in: size).midX.rounded() == (size.width / 2).rounded())
        #expect(ElementLayout.aligned(frame, .bottom, in: size).maxY == size.height)
        #expect(ElementLayout.aligned(frame, .top, in: size).minY == 0)
    }

    @Test func aLockedElementCanNotBeDeleted() throws {
        let model = AppModel(document: LayerDocument())
        let screen = try #require(model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))).id
        let title = try #require(model.store.sketched(.title, from: CGRect(x: 40, y: 100, width: 100, height: 30), to: screen))
        let ref = NodeRef(host: .screen(screen), node: title.id)
        model.selection = .element(ref)
        model.toggleLockOfSelection()
        model.deleteSelection()
        #expect(model.store.placed(ref) != nil)
        model.toggleLockOfSelection()
        model.deleteSelection()
        #expect(model.store.placed(ref) == nil)
    }

    @Test func hidingTheSelectedElementLetsGoOfIt() throws {
        let model = AppModel(document: LayerDocument())
        let screen = try #require(model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))).id
        let title = try #require(model.store.sketched(.title, from: CGRect(x: 40, y: 100, width: 100, height: 30), to: screen))
        let ref = NodeRef(host: .screen(screen), node: title.id)
        model.selection = .element(ref)
        model.toggleHidden(ref)
        #expect(model.selection == nil)
        #expect(model.store.placed(ref)?.isHidden == true)
    }

    @Test func aDraggedFrameSnapsToANeighboursEdgeAndShowsTheGuide() throws {
        let neighbour = CGRect(x: 40, y: 100, width: 200, height: 40)
        let dragged = CGRect(x: 43, y: 300, width: 120, height: 40)
        let (frame, guides) = ElementLayout.snapped(dragged, to: [neighbour], in: nil, threshold: 5)
        #expect(frame.minX == 40)
        let guide = try #require(guides.first)
        #expect(guide.axis == .vertical && guide.position == 40)
        #expect(guide.start == 100 && guide.end == 340)
    }

    @Test func aDraggedFrameSnapsToTheScreensCentre() {
        let screen = CGRect(origin: .zero, size: DeviceFrame.iPhone.size)
        let dragged = CGRect(x: 138, y: 500, width: 120, height: 40)
        let (frame, guides) = ElementLayout.snapped(dragged, to: [], in: screen, threshold: 5)
        #expect(frame.midX == screen.midX)
        #expect(guides.contains { $0.axis == .vertical && $0.position == screen.midX })
    }

    @Test func farFromEverythingNothingSnaps() {
        let dragged = CGRect(x: 117, y: 413, width: 50, height: 20)
        let (frame, guides) = ElementLayout.snapped(dragged, to: [CGRect(x: 0, y: 0, width: 30, height: 30)], in: nil, threshold: 4)
        #expect(frame == dragged)
        #expect(guides.isEmpty)
    }

    @Test func snappingToTheGridLandsOnItsMarksInCanvasPoints() {
        let placement = Placement(origin: CGPoint(x: 100, y: 100), scale: 0.5)
        let frame = CGRect(x: 21, y: 45, width: 60, height: 20)
        let snapped = ElementLayout.snappedToGrid(frame, spacing: 24, placement: placement)
        let canvas = placement.canvasRect(for: snapped)
        #expect(canvas.minX.truncatingRemainder(dividingBy: 24) == 0)
        #expect(canvas.minY.truncatingRemainder(dividingBy: 24) == 0)
        #expect(snapped.size == frame.size)
    }

    @Test func resizingAnAvatarKeepsItRound() {
        let avatar = CGRect(x: 100, y: 100, width: 64, height: 64)
        let resized = ElementLayout.resizedKeepingShape(avatar, from: .bottomRight, by: CGSize(width: 30, height: 4), kind: .avatar)
        #expect(resized.width == resized.height)
        #expect(resized.origin == avatar.origin)
    }

    @Test func sketchedScreensUseTheChosenDevice() throws {
        let (store, _) = makeStore()
        store.updateCanvas { $0.sketchDeviceID = "iphone-se" }
        let screen = try #require(store.addScreen(from: CGRect(x: 0, y: 0, width: 300, height: 530))).id
        #expect(store.device(of: screen)?.id == "iphone-se")
    }
}

@Suite("More Magic Pen sketches")
@MainActor
struct MoreMagicPenTests {
    private let rules = RuleInterpreter()

    @Test func aZigzagScrubbedBackAndForthIsAScratchOut() throws {
        let observation = try #require(SketchAnalyzer.observe(SketchSamples.strokes([scratch(CGRect(x: 40, y: 200, width: 200, height: 40))])))
        guard case .scratch = observation.form else {
            Issue.record("expected a scratch, got \(observation.form)")
            return
        }
        #expect(rules.reading(for: try request([scratch(CGRect(x: 40, y: 200, width: 200, height: 40))], local: CGRect(x: 40, y: 200, width: 200, height: 40))) == .scratchOut)
    }

    @Test func aTitleSquiggleIsNotAScratchOut() throws {
        let observation = try #require(SketchAnalyzer.observe(SketchSamples.strokes([SketchSamples.wave(CGRect(x: 150, y: 112, width: 96, height: 40), humps: 3)])))
        #expect(observation.form == .wave(humps: 3))
    }

    @Test func aSmallPillOnAScreenIsAToggle() throws {
        let rect = CGRect(x: 300, y: 300, width: 56, height: 30)
        let reading = rules.reading(for: try request([SketchSamples.box(rect, radius: 15)], local: rect))
        #expect(reading == .element(.toggle))
    }

    @Test func aSmallCircleOnAScreenIsAnAvatar() throws {
        let rect = CGRect(x: 30, y: 120, width: 70, height: 70)
        let reading = rules.reading(for: try request([SketchSamples.box(rect, radius: 35)], local: rect))
        #expect(reading == .element(.avatar))
    }

    @Test func aWidePillIsStillAButton() throws {
        let rect = CGRect(x: 28, y: 738, width: 337, height: 60)
        #expect(rules.reading(for: try request([SketchSamples.box(rect, radius: 30)], local: rect)) == .element(.button))
    }

    @Test func aBoxOnTheOpenCanvasIsAStickyNote() throws {
        let box = SketchSamples.box(CGRect(x: 900, y: 100, width: 140, height: 120), radius: 6)
        #expect(rules.reading(for: try request([box], local: nil)) == .element(.stickyNote))
    }

    @Test func aSketchedToggleKeepsItsPlaceAcrossTheScreen() {
        let frame = ElementLayout.frame(for: .toggle, sketch: CGRect(x: 310, y: 300, width: 56, height: 30))
        #expect(frame.size == CGSize(width: 51, height: 31))
        #expect(frame.midX > 300)
        let avatar = ElementLayout.frame(for: .avatar, sketch: CGRect(x: 20, y: 120, width: 70, height: 70))
        #expect(avatar.width == avatar.height)
        #expect(avatar.minX < 60)
    }

    @Test func aStickyNoteSketchedBesideTheScreensLandsWhereItWasDrawn() throws {
        let (store, _) = makeStore()
        let note = try #require(store.placeLoose(.stickyNote, sketchedAs: CGRect(x: 900, y: 100, width: 140, height: 120)))
        let onCanvas = try #require(store.canvasRect(of: note.node))
        #expect(store.ref(of: note.node)?.host == .canvas)
        #expect(abs(onCanvas.midX - 970) <= 1)
        #expect(abs(onCanvas.midY - 160) <= 1)
    }
}

@Suite("More SwiftUI")
struct MoreCodeTests {
    /// The code of a free screen of `nodes`, a line at a time, without its indent.
    private func lines(_ nodes: [LayerNode], _ settings: CodeSettings = CodeSettings()) -> [String] {
        SwiftUICodeGenerator.code(forFreeScreenHolding: nodes, settings: settings).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test func eachFileEndsWithAPreviewUnlessAskedNotTo() {
        let screen = [element(.title, 82.5, 112, 228, 40)]
        let code = SwiftUICodeGenerator.code(forFreeScreenHolding: screen)
        #expect(code.hasSuffix("#Preview {\n    Screen1()\n}"))
        #expect(!SwiftUICodeGenerator.code(forFreeScreenHolding: screen, settings: CodeSettings(includesPreview: false)).contains("#Preview"))
    }

    @Test func hiddenElementsAreLeftOut() {
        var hidden = element(.button, 20, 744, 353, 50)
        hidden.isHidden = true
        #expect(!lines([element(.title, 82.5, 112, 228, 40), hidden]).contains("Button {"))
    }

    @Test func exactPositionsPlaceEveryElementWhereItIs() {
        let screen = [element(.title, 82, 112, 228, 40), element(.toggle, 320, 300, 51, 31)]
        let code = lines(screen, CodeSettings(layout: .absolute, includesPreview: false))
        #expect(code.contains("ZStack(alignment: .topLeading) {"))
        #expect(code.contains(".offset(x: 82, y: 112)"))
        #expect(code.contains(".offset(x: 320, y: 300)"))
        #expect(code.contains("Toggle(\"\", isOn: .constant(true))"))
        #expect(code.contains(".ignoresSafeArea()"))
    }

    @Test func theTitleCanBecomeTheNavigationTitle() {
        var title = element(.title, 82.5, 112, 228, 40)
        title.content.text = "Inbox"
        let screen = [title, element(.button, 20, 744, 353, 50)]
        let code = lines(screen, CodeSettings(usesNavigationTitle: true))
        #expect(code.contains("NavigationStack {"))
        #expect(code.contains(".navigationTitle(\"Inbox\")"))
        #expect(!code.contains("Text(\"Inbox\")"))
    }

    @Test func bordersShadowsAvatarsAndNamesAreWritten() {
        var avatar = element(.avatar, 30, 120, 64, 64)
        avatar.name = "Profile Photo"
        avatar.style.borderWidth = 2
        avatar.style.borderColor = RGBColor(hex: 0xFFFFFF)
        avatar.style.hasShadow = true
        let code = lines([avatar])
        #expect(code.contains("// Profile Photo"))
        #expect(code.contains("Image(\"profile-photo\")"))
        #expect(code.contains(".clipShape(.circle)"))
        #expect(code.contains("Circle()"))
        #expect(code.contains(".strokeBorder(Color(red: 1.00, green: 1.00, blue: 1.00), lineWidth: 2)"))
        #expect(code.contains(".shadow(color: .black.opacity(0.18), radius: 10, y: 5)"))
    }

    @Test func textAlignmentIsWritten() {
        var body = element(.body, 48, 580, 297, 44)
        body.style.textAlignment = .leading
        #expect(lines([body]).contains(".multilineTextAlignment(.leading)"))
    }

    @Test func everyScreenGetsItsOwnFileName() {
        let files = SwiftUICodeGenerator.files(for: design(ofEmptyScreensNamed: ["Home", "Home"]), settings: CodeSettings())
        #expect(files.map(\.name) == ["Home.swift", "Home2.swift"])
    }

    /// The view a file declares, from its `struct X: View` line.
    private func structName(in source: String) -> String? {
        source.split(separator: "\n").first { $0.hasPrefix("struct ") }
            .map { String($0.dropFirst("struct ".count).prefix { $0 != ":" }) }
    }

    /// Two screens whose names clean to the same type used to be written as two files that
    /// both declared it, which won't compile in one target (G2): "Screen 2" again after a
    /// screen was deleted, or "Sign In" beside "Sign-In". Names that differ only in case
    /// are told apart too, as a Mac's disk doesn't tell their files apart.
    @Test func screensWhoseNamesCleanToTheSameTypeDeclareDifferentViews() throws {
        let content = design(ofEmptyScreensNamed: ["Sign In", "Sign-In", "Sign in"])
        let screens = content.screens
        let files = SwiftUICodeGenerator.files(for: content, settings: CodeSettings())
        let names = files.map { structName(in: $0.source) }
        #expect(names == ["SignIn", "SignIn2", "Signin3"])
        #expect(files.map(\.name) == ["SignIn.swift", "SignIn2.swift", "Signin3.swift"])
        // Each file's preview shows its own view.
        #expect(files[1].source.hasSuffix("#Preview {\n    SignIn2()\n}"))
        // The code panel names each one as its file is named.
        let typeNames = SwiftUICodeGenerator.typeNames(for: screens)
        #expect(screens.map { typeNames[$0.id] } == ["SignIn", "SignIn2", "Signin3"])
        #expect(structName(in: SwiftUICodeGenerator.code(for: screens[1], in: .init(content), settings: CodeSettings())) == "SignIn2")
    }

    /// A carriage return or other control character in an element's words, pasted from
    /// Windows or set by a Siri intent, broke the string literal it was written into, and
    /// in a layer's name ended the comment, leaving the rest as code (G16).
    @Test func controlCharactersAreEscapedInStringsAndDroppedFromComments() {
        var body = element(.body, 48, 580, 297, 44)
        body.content.text = "a\r\nb\tc\u{7}d"
        body.name = "Hero\r\nText"
        let code = SwiftUICodeGenerator.code(forFreeScreenHolding: [body])
        #expect(!code.contains("\r") && !code.contains("\t") && !code.contains("\u{7}"))
        #expect(code.contains(#"Text("a\r\nb\tc\u{07}d")"#))
        #expect(code.contains("// Hero  Text"))
    }

    /// A size past Int's range trapped writing it out, and the code panel works its code
    /// out as it draws (G18).
    @Test func aHugeNumberIsWrittenRatherThanATrap() {
        var wide = element(.button, 20, 744, 353, 50)
        wide.frame.size.width = 1e19
        let code = SwiftUICodeGenerator.code(forFreeScreenHolding: [wide], settings: CodeSettings(layout: .absolute))
        #expect(code.contains("Button"))
    }

    /// Siri's code for a screen names its view as the shared files and the code panel do:
    /// a second "Home" is `Home2` there too (review M-8).
    @MainActor @Test func siriNamesAScreensViewAsItsFileDoes() throws {
        var content = TreeContent()
        let first = TreeScreen(name: "Home", origin: .zero, scale: 1, deviceID: nil)
        let second = TreeScreen(name: "Home", origin: CGPoint(x: 500, y: 0), scale: 1, deviceID: nil)
        content.screens = [first, second]
        #expect(structName(in: GenerateSwiftUICodeIntent.code(for: second.id, in: content) ?? "") == "Home2")
        #expect(structName(in: GenerateSwiftUICodeIntent.code(for: first.id, in: content) ?? "") == "Home")
    }

    /// A non-finite size is written as Swift reads it, not as `nan` or `inf`.
    @Test func aSizeThatIsNotANumberStillCompiles() {
        var wide = element(.button, 20, 744, 353, 50)
        wide.frame.size.width = .infinity
        wide.frame.size.height = .nan
        let code = SwiftUICodeGenerator.code(forFreeScreenHolding: [wide], settings: CodeSettings(layout: .absolute))
        #expect(!code.contains("inf,") && !code.contains("nan"))
    }

    /// A screen named after a type its own code uses ("Image", "Text") shadowed it, and
    /// one named for a keyword wasn't a type name at all (G17).
    @Test func aScreenNamedAfterATypeItsCodeUsesGetsAnotherName() {
        for name in ["Image", "Text", "Button", "Color", "View", "Any", "Self", "default", "Menu", "List", "Form", "Label", "Group", "Section", "App"] {
            let typeName = SwiftUICodeGenerator.typeName(of: TreeScreen(name: name, origin: .zero, scale: 1, deviceID: nil))
            #expect(typeName == name + "Screen")
        }
        #expect(SwiftUICodeGenerator.typeName(of: TreeScreen(name: "Images", origin: .zero, scale: 1, deviceID: nil)) == "Images")
    }
}

@Suite("Scrubbing number fields")
@MainActor
struct ScrubbingTests {
    private final class Box {
        var value: CGFloat
        var steps = 0
        init(_ value: CGFloat) { self.value = value }
    }

    private func target(_ box: Box, range: ClosedRange<CGFloat> = 0...100) -> Scrubber.Target {
        Scrubber.Target(label: "W", unit: "W", frame: .zero, range: range, get: { box.value }, set: { box.value = $0 })
    }

    @Test func dragAndRollTurnIntoWholeSteps() {
        #expect(Scrubber.steps(forDrag: 7) == 0)
        #expect(Scrubber.steps(forDrag: 25) == 3)
        #expect(Scrubber.steps(forDrag: -17) == -2)
        #expect(Scrubber.steps(forRoll: .degrees(35)) == 3)
        #expect(Scrubber.steps(forRoll: .degrees(-12)) == -1)
    }

    @Test func rollingPastTheWrapIsASmallTurnNotAFullOne() {
        #expect(abs(Scrubber.turn(from: .degrees(175), to: .degrees(-175)).degrees - 10) < 0.001)
        #expect(abs(Scrubber.turn(from: .degrees(-170), to: .degrees(170)).degrees + 20) < 0.001)
    }

    @Test func scrubbingStepsFromWhereItBeganAndStaysInRange() {
        let scrubber = Scrubber()
        let box = Box(40.4)
        var began = 0, ended = 0
        scrubber.onBegin = { began += 1 }
        scrubber.onEnd = { ended += 1 }
        scrubber.onStep = { _ in box.steps += 1 }

        scrubber.begin(target(box))
        scrubber.scrub(to: 5)
        #expect(box.value == 45)
        scrubber.scrub(to: -100)
        #expect(box.value == 0)
        scrubber.end()
        scrubber.end()
        #expect(began == 1 && ended == 1)
        #expect(box.steps == 2)
        #expect(scrubber.target == nil)
    }

    @Test func rollingTheBarrelWhileScrubbingStepsTheValue() {
        let scrubber = Scrubber()
        let box = Box(10)
        scrubber.begin(target(box))
        scrubber.rolled(to: .degrees(170))
        scrubber.rolled(to: .degrees(-170))   // 20° on, across the wrap
        scrubber.rolled(to: .degrees(-160))   // 30° in all
        #expect(box.value == 13)
        scrubber.end()
        // With no field being scrubbed, rolling does nothing.
        scrubber.rolled(to: .degrees(0))
        #expect(box.value == 13)
    }

    @Test func aScrubUndoesAsOneStep() throws {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        let screen = try #require(model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))).id
        let title = try #require(model.store.sketched(.title, from: CGRect(x: 40, y: 100, width: 100, height: 30), to: screen))
        let start = title.frame.width

        model.beginScrubbing()
        for step in 1...12 {
            model.adjusting { model.store.update(title.id) { $0.frame.size.width = start + CGFloat(step) } }
        }
        model.endScrubbing()
        #expect(model.store.ownFrame(title.id)?.width == start + 12)
        undo.undo()
        #expect(model.store.ownFrame(title.id)?.width == start)
    }

    /// The window's one scrubber: the zoom's ruler is no edit, and a Format field's undoes
    /// as one step, as the model wires it.
    @Test func scrubbingTheZoomLeavesNoUndoStep() throws {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.scrubber.begin(ZoomStops.target(frame: .zero, current: { 1 }, zoom: { _ in }))
        model.scrubber.scrub(to: 2)
        model.scrubber.end()
        #expect(undo.canUndo == false)
        #expect(model.store.isEditing == false)

        let screen = try #require(model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))).id
        let title = try #require(model.store.sketched(.title, from: CGRect(x: 40, y: 100, width: 100, height: 30), to: screen))
        let start = title.frame.width
        model.scrubber.begin(Scrubber.Target(
            label: "W", unit: "W", frame: .zero, range: 0...4000,
            get: { model.store.ownFrame(title.id)?.width ?? 0 },
            set: { width in model.adjusting { model.store.update(title.id) { $0.frame.size.width = width } } }
        ))
        // The model wired its scrubber: a field's scrub is the model's, from begin to end.
        #expect(model.isScrubbing)
        model.scrubber.scrub(to: 3)
        model.scrubber.end()
        #expect(!model.isScrubbing)
        #expect(!model.store.isEditing)
        #expect(model.store.ownFrame(title.id)?.width == start + 3)
        undo.undo()
        #expect(model.store.ownFrame(title.id)?.width == start)
    }
}
