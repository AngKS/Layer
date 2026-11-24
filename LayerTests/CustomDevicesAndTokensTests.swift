import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// An app showing `tree`, laid out as a file read lays it out, with an undo history of its own.
@MainActor
private func makeModel(_ tree: TreeContent) -> (model: AppModel, undo: UndoManager) {
    var tree = tree
    TreeRules.apply(to: &tree, after: nil)
    let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.store.undoManager = undo
    model.adjustmentPause = .seconds(60)
    return (model, undo)
}

/// A watch the design adds to the built-in devices, with the margin given and nothing else round its edges.
private func watch(margin: CGFloat = 8) -> DeviceFrame {
    let made = DeviceFrame.custom(name: "Watch", size: CGSize(width: 198, height: 242), family: .watch)
    return DeviceFrame(id: made.id, name: made.name, size: made.size, safeTop: 0, safeBottom: 0, cornerRadius: 0,
                       hasIsland: false, hasHomeIndicator: false, family: .watch, margin: margin)
}

private func words(_ kind: ElementKind, _ text: String) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.content.text = text
    (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
    return node
}

private func column(spacing: CGFloat = 12) -> LayerNode.Layout {
    .stack(LayerNode.Stack(axis: .vertical, spacing: spacing, alignment: .fill))
}

/// A screen on `deviceID` whose root lays `children` out in a column, or holds them freely when `free`.
private func screen(_ children: [LayerNode] = [], named name: String = "Screen 1", on deviceID: String? = nil,
                    free: Bool = false) -> TreeScreen {
    var screen = TreeScreen(name: name, origin: .zero, scale: 1, deviceID: deviceID)
    if !free { screen.root.layout = column() }
    screen.root.children = children
    return screen
}

private func design(_ screens: [TreeScreen], devices: [DeviceFrame] = [], tokens: DesignTokens = .standard) -> TreeContent {
    var content = TreeContent()
    content.settings.customDevices = devices
    content.settings.tokens = tokens
    content.screens = screens
    return content
}

private func titleSized(_ size: CGFloat) -> DesignTokens {
    var tokens = DesignTokens.standard
    tokens.textSizes.title = size
    return tokens
}

private func measured(_ node: LayerNode, at fontSize: CGFloat) -> CGSize {
    TextMeasure.shared.size(of: node.content.text, fontSize: fontSize, weight: NaturalSize.fontWeight(of: node),
                            width: node.frame.width)
}

/// Custom device frames kept with the design and the design's tokens, as the panels edit them (plan 4, Task 9).
@Suite("Custom devices and design tokens")
@MainActor
struct CustomDevicesAndTokensTests {
    // MARK: - Custom devices

    @Test func aCustomSizeIsAddedAndTheScreenTakesItInOneStep() throws {
        let s = screen(on: "ipad", free: true)
        let (model, undo) = makeModel(design([s]))
        let store = model.store
        var draft = CustomDeviceDraft(from: .custom(name: "Custom", size: CGSize(width: 820, height: 1180), family: .tablet),
                                      named: "Custom")
        draft.width = 300
        draft.height = 500
        let device = try #require(draft.device(id: nil))

        let id = store.addCustomDevice(device, forScreen: s.id)

        #expect(id == device.id)
        #expect(store.tree.settings.customDevices.map(\.id) == [id])
        #expect(store.treeScreen(s.id)?.deviceID == id)
        #expect(store.treeScreen(s.id)?.root.frame == CGRect(x: 0, y: 0, width: 300, height: 500))
        #expect(undo.undoActionName == "Add Device")

        undo.undo()
        #expect(store.tree.settings.customDevices.isEmpty)
        #expect(store.treeScreen(s.id)?.deviceID == "ipad")
        #expect(store.treeScreen(s.id)?.root.frame == CGRect(x: 0, y: 0, width: 820, height: 1180))
        #expect(!undo.canUndo)
    }

    @Test func aDeviceIsAddedUnderAnIDOfItsOwn() throws {
        let (model, _) = makeModel(design([screen(free: true)]))
        let store = model.store
        let frame = watch()

        let first = store.addCustomDevice(frame)
        let again = store.addCustomDevice(frame)
        let builtIn = store.addCustomDevice(.iPhone)

        #expect(first == frame.id)
        #expect(again != frame.id && again.hasPrefix(DeviceFrame.customPrefix))
        #expect(builtIn != DeviceFrame.iPhone.id && builtIn.hasPrefix(DeviceFrame.customPrefix))
        #expect(store.tree.settings.customDevices.map(\.id) == [first, again, builtIn])
        #expect(store.tree.settings.device(named: builtIn).size == DeviceFrame.iPhone.size)
    }

    @Test func aDraftWithABadSizeIsRefused() {
        let good = CustomDeviceDraft(from: .iPhone, named: "Phone")
        #expect(good.problems.isEmpty)
        #expect(good.device(id: nil) != nil)
        for bad: CGFloat in [0, -5, .nan, .infinity, 5000] {
            var wide = good
            wide.width = bad
            #expect(!wide.problems.isEmpty, "width \(bad)")
            #expect(wide.device(id: nil) == nil, "width \(bad)")
            var tall = good
            tall.height = bad
            #expect(!tall.problems.isEmpty, "height \(bad)")
            #expect(tall.device(id: nil) == nil, "height \(bad)")
        }
        for name in ["", "   "] {
            var unnamed = good
            unnamed.name = name
            #expect(!unnamed.problems.isEmpty)
            #expect(unnamed.device(id: nil) == nil)
        }
        var edges = good
        edges.width = 1
        edges.height = 4000
        edges.margin = 0
        #expect(edges.problems.isEmpty)
        // Safe areas and a margin that leave the column no room are a problem too, on either axis.
        var crowded = good
        crowded.safeTop = 500
        crowded.safeBottom = 352
        #expect(!crowded.problems.isEmpty && crowded.device(id: nil) == nil)
        var wideMargin = good
        wideMargin.margin = 197
        #expect(!wideMargin.problems.isEmpty && wideMargin.device(id: nil) == nil)
    }

    // MARK: - What the device verbs take (fix round 1)

    @Test func everyBuiltInDeviceIsOneTheVerbsTake() {
        for device in DeviceFrame.all { #expect(device.problems.isEmpty, "\(device.name)") }
    }

    @Test func theDeviceVerbsRefuseAFrameWithNoUsableSize() throws {
        let frame = watch()
        let s = screen(on: frame.id, free: true)
        let (model, undo) = makeModel(design([s], devices: [frame]))
        let store = model.store
        func sized(_ width: CGFloat, _ height: CGFloat, id: String? = nil) -> DeviceFrame {
            DeviceFrame(id: id ?? DeviceFrame.customPrefix + UUID().uuidString, name: "Odd", size: CGSize(width: width, height: height),
                        safeTop: 0, safeBottom: 0, cornerRadius: 0, hasIsland: false, hasHomeIndicator: false, family: .other,
                        margin: 0)
        }
        for bad: CGFloat in [0, -5, .nan, .infinity, 0.5, 4001, 1e300] {
            let wide = sized(bad, 500), tall = sized(300, bad)
            #expect(!wide.problems.isEmpty && !tall.problems.isEmpty, "\(bad)")
            #expect(store.addCustomDevice(wide, forScreen: s.id) == "", "\(bad)")
            #expect(store.addCustomDevice(tall) == "", "\(bad)")
            #expect(store.addCustomDeviceForNewScreens(wide) == "", "\(bad)")
            store.updateCustomDevice(sized(bad, bad, id: frame.id))
        }
        #expect(store.tree.settings.customDevices == [frame])
        #expect(store.treeScreen(s.id)?.deviceID == frame.id)
        #expect(store.tree.settings.sketchDeviceID == nil)
        #expect(!undo.canUndo, "nothing refused is a step")
        // The sides' ends are taken.
        #expect(store.addCustomDevice(sized(1, 4000)) != "")
        #expect(store.addCustomDevice(sized(4000, 1)) != "")
    }

    @Test func theDeviceVerbsRefuseSafeAreasOrAMarginWithNoRoom() throws {
        let frame = watch()
        let s = screen(on: frame.id, free: true)
        let (model, undo) = makeModel(design([s], devices: [frame]))
        let store = model.store
        func crowded(top: CGFloat = 0, bottom: CGFloat = 0, leading: CGFloat = 0, trailing: CGFloat = 0, margin: CGFloat = 0,
                     radius: CGFloat = 0, id: String? = nil) -> DeviceFrame {
            DeviceFrame(id: id ?? DeviceFrame.customPrefix + UUID().uuidString, name: "Crowded",
                        size: CGSize(width: 300, height: 500), safeTop: top, safeBottom: bottom, cornerRadius: radius,
                        hasIsland: false, hasHomeIndicator: false, family: .phone, safeLeading: leading,
                        safeTrailing: trailing, margin: margin)
        }
        let refused = [
            crowded(top: 500), crowded(top: 300, bottom: 200), crowded(top: 200, bottom: 200, margin: 50),
            crowded(leading: 300), crowded(leading: 100, trailing: 100, margin: 50), crowded(margin: 150),
            crowded(top: -1), crowded(leading: .nan), crowded(margin: .infinity), crowded(radius: -4),
        ]
        for device in refused {
            #expect(!device.problems.isEmpty)
            #expect(store.addCustomDevice(device, forScreen: s.id) == "")
            store.updateCustomDevice(crowded(top: device.safeTop, bottom: device.safeBottom, leading: device.safeLeading,
                                             trailing: device.safeTrailing, margin: device.margin,
                                             radius: device.cornerRadius, id: frame.id))
        }
        #expect(store.tree.settings.customDevices == [frame])
        #expect(store.treeScreen(s.id)?.deviceID == frame.id)
        #expect(!undo.canUndo)
        // One point of room on each axis is enough.
        let roomy = crowded(top: 200, bottom: 199, leading: 100, trailing: 99, margin: 50)
        #expect(roomy.problems.isEmpty)
        let id = store.addCustomDevice(crowded(top: 249, bottom: 250, leading: 149, trailing: 150), forScreen: s.id)
        #expect(id != "")
        #expect(store.treeScreen(s.id)?.deviceID == id)
    }

    /// A design's own device whose size a file held as too large for a whole number is said in the device picker and
    /// in the selection's summary as the largest length a design has, and it can't be chosen for another screen.
    @Test func aDeviceSizeFromAFileTooLargeForAWholeNumberIsSaidWithoutTrapping() throws {
        var content = TreeContent()
        content.screens = [TreeScreen(name: "Huge", origin: .zero, scale: 1, deviceID: "custom-huge"),
                           TreeScreen(name: "Phone", origin: CGPoint(x: 0, y: 2000), scale: 1, deviceID: nil)]
        var json = try #require(try JSONSerialization.jsonObject(with: TreeManifest.encode(content, fileName: nil)) as? [String: Any])
        var inner = try #require(json["content"] as? [String: Any])
        var settings = inner["settings"] as? [String: Any] ?? [:]
        settings["customDevices"] = [["id": "custom-huge", "name": "Huge", "size": [1e300, 1e19]]]
        inner["settings"] = settings
        json["content"] = inner
        let read = try TreeManifest.decode(JSONSerialization.data(withJSONObject: json)).content
        let huge = try #require(read.settings.customDevices.first)
        #expect(huge.size.width == 1e300 && huge.size.height == 1e19)
        #expect(!huge.problems.isEmpty)

        #expect(DevicePicker.label(huge, showsSize: true) == "Huge  1000000 × 1000000")
        #expect(DevicePicker.label(huge, showsSize: false) == "Huge")

        let (model, _) = makeModel(read)
        let screens = model.store.tree.screens
        model.selection = .screen(screens[0].id)
        #expect(SelectionSummary.value(for: model) == "Huge · 1000000 × 1000000")
        model.store.setDevice(of: screens[1].id, to: "custom-huge")
        #expect(model.store.treeScreen(screens[1].id)?.deviceID == nil)
        #expect(CGFloat.nan.wholePoints == 0 && (-CGFloat.infinity).wholePoints == 0 && CGFloat(-1e300).wholePoints == -1_000_000)
        #expect(CGFloat(393.9).wholePoints == 393)
    }

    @Test func aRhythmKeepsNoStepLargerThanAnyScreen() throws {
        #expect(DesignTokens.largestStep == DeviceFrame.sides.upperBound)
        #expect(DesignTokensSection.rhythm(typed: "16, 8, 5000, 4000, 1e300") == [8, 16, 4000])
        #expect(DesignTokensSection.rhythm(typed: "9000, 100000") == DesignTokens.standard.rhythm)
        var typed = DesignTokens.standard
        typed.rhythm = [16, 4001, 4000]
        let decoded = try JSONDecoder().decode(DesignTokens.self, from: JSONEncoder().encode(typed))
        #expect(decoded.rhythm == [16, 4000])
        let (model, _) = makeModel(design([screen(free: true)]))
        DesignTokensSection.edit(model) { $0.rhythm = [8, 12, 50_000] }
        #expect(model.store.tree.settings.tokens.rhythm == [8, 12])
    }

    /// A form's number field, the board menu's tokens or a device's form, scrubs as a Format panel field does: a scrub is
    /// an edit, begun and ended with it, and its ticks are felt at the field, where the form is in the window.
    @Test func aFormsFieldScrubsAsAnEditAndTicksWhereTheFormIs() {
        let scrubber = Scrubber()
        var begins = 0, ends = 0
        var ticks: [CGPoint] = []
        scrubber.onBegin = { begins += 1 }
        scrubber.onEnd = { ends += 1 }
        scrubber.onStep = { ticks.append($0) }
        scrubber.panelOrigin = CGPoint(x: 900, y: 0)
        scrubber.formOrigin = CGPoint(x: 10, y: 100)
        let title = ScrubbedField(28)
        var target = title.target("Title size", at: CGRect(x: 0, y: 0, width: 80, height: 32), range: 1...400)
        target.owner = .form
        scrubber.begin(target)
        scrubber.scrub(to: 2)
        #expect(title.value == 30)
        #expect(ticks.last == CGPoint(x: 50, y: 116))
        scrubber.end(.panel)
        #expect(scrubber.target != nil, "the Format panel's going doesn't put a form's ruler away")
        scrubber.end(.form)
        #expect(begins == 1 && ends == 1)
    }

    @Test func thePickerListsTheDesignsOwnFrames() {
        var settings = CanvasSettings()
        let plain = DevicePicker.sections(settings)
        #expect(plain.map(\.title) == ["Phones", "Tablets", "Desktops"])
        #expect(plain.flatMap(\.devices) == DeviceFrame.all)

        let frame = watch()
        settings.customDevices = [frame]
        let sections = DevicePicker.sections(settings)
        #expect(sections.map(\.title) == ["Phones", "Tablets", "Desktops", "Custom"])
        #expect(sections.last?.title == "Custom")
        #expect(sections.last?.devices == [frame])
        #expect(sections.dropLast().flatMap(\.devices) == DeviceFrame.all)
        for section in sections.dropLast() {
            #expect(Set(section.devices.map(\.family)).count == 1, "\(section.title)")
        }
    }

    @Test func aDeviceInUseIsNotDeleted() throws {
        let frame = watch()
        let s = screen(on: frame.id, free: true)
        let (model, _) = makeModel(design([s], devices: [frame]))
        let store = model.store

        #expect(!store.deleteCustomDevice(frame.id))
        #expect(store.tree.settings.customDevices == [frame])

        store.setDevice(of: s.id, to: nil)
        #expect(store.treeScreen(s.id)?.deviceID == nil)
        #expect(store.deleteCustomDevice(frame.id))
        #expect(store.tree.settings.customDevices.isEmpty)

        // The canvas's New Screens device is a use too (F16).
        let other = watch()
        store.addCustomDevice(other)
        store.updateCanvas { $0.sketchDeviceID = other.id }
        #expect(!store.deleteCustomDevice(other.id))
        store.updateCanvas { $0.sketchDeviceID = nil }
        #expect(store.deleteCustomDevice(other.id))
        #expect(!store.deleteCustomDevice("custom-nothing"))
    }

    @Test func editingADeviceReLaysItsScreens() throws {
        var frame = watch(margin: 12)
        let s = screen([words(.body, "Hi")], on: frame.id)
        let (model, undo) = makeModel(design([s], devices: [frame]))
        let store = model.store
        #expect(store.treeScreen(s.id)?.root.children.first?.frame.minX == 12)

        frame.margin = 24
        store.updateCustomDevice(frame)

        #expect(store.tree.settings.customDevices == [frame])
        #expect(store.treeScreen(s.id)?.root.children.first?.frame.minX == 24)
        undo.undo()
        #expect(store.treeScreen(s.id)?.root.children.first?.frame.minX == 12)
    }

    @Test func saveAsDeviceStartsFromTheScreensDevice() throws {
        let draft = CustomDeviceDraft(from: .iPhone, named: "iPhone (Custom)")
        #expect(draft.name == "iPhone (Custom)")
        #expect(draft.width == 393 && draft.height == 852)
        #expect(draft.family == .phone)
        #expect(draft.safeTop == 59 && draft.safeBottom == 34 && draft.safeLeading == 0 && draft.safeTrailing == 0)
        #expect(draft.cornerRadius == 52)
        #expect(draft.hasStatusBar && draft.hasIsland && draft.hasHomeIndicator)
        #expect(draft.margin == 20 && draft.maxContentWidth == nil)

        let made = try #require(draft.device(id: nil))
        #expect(made.isCustom)
        #expect(made.id != DeviceFrame.iPhone.id)
        #expect(made.name == "iPhone (Custom)")
        #expect(made.size == DeviceFrame.iPhone.size)
        #expect(made.safeTop == 59 && made.safeBottom == 34 && made.cornerRadius == 52)
        #expect(made.hasIsland && made.hasHomeIndicator && made.hasStatusBar)
        #expect(made.family == .phone && made.margin == 20 && made.maxContentWidth == nil)
        // Kept under its own id when edited.
        #expect(draft.device(id: made.id)?.id == made.id)
        #expect(CustomDeviceDraft(from: made, named: made.name).device(id: made.id) == made)
    }

    /// The `updateScreen` view and `screenFrames` show a screen on one of the design's own devices as that device,
    /// not the iPhone `deviceID` alone names (plan 2, carried).
    @Test func aScreensViewsResolveTheDesignsOwnDevices() throws {
        let frame = watch()
        let s = screen(on: frame.id, free: true)
        var content = DesignContent(tree: design([s], devices: [frame]))
        #expect(content.screenFrames.first?.device == frame)
        #expect(content.screenFrames.first?.size == frame.size)

        var seen: DeviceFrame?
        content.updateScreen(s.id) { seen = $0.device; $0.name = "Watch face" }
        #expect(seen == frame)
        #expect(content.tree.screens.first?.deviceID == frame.id)
        #expect(content.tree.screens.first?.name == "Watch face")

        let (model, _) = makeModel(design([s], devices: [frame]))
        var shown: CGSize?
        model.store.updateScreen(s.id) { shown = $0.size; $0.origin.x = 40 }
        #expect(shown == frame.size)
        #expect(model.store.treeScreen(s.id)?.deviceID == frame.id)
    }

    @Test func aDeviceAddedForNewScreensIsOneStep() throws {
        let (model, undo) = makeModel(design([screen(free: true)]))
        let store = model.store
        let device = try #require(CustomDeviceDraft(from: .iPhone, named: "Tall").device(id: nil))

        let id = store.addCustomDeviceForNewScreens(device)

        #expect(store.tree.settings.sketchDeviceID == id)
        #expect(store.tree.settings.sketchDevice == device)
        #expect(undo.undoActionName == "Add Device")
        undo.undo()
        #expect(store.tree.settings.customDevices.isEmpty)
        #expect(store.tree.settings.sketchDeviceID == nil)
        #expect(!undo.canUndo)
    }

    // MARK: - Tokens

    @Test func tokensTypedAreReadAsPlan2Reads() throws {
        #expect(DesignTokensSection.rhythm(typed: "16, 8, 8, -2") == [8, 16])
        #expect(DesignTokensSection.rhythm(typed: "") == DesignTokens.standard.rhythm)
        #expect(DesignTokensSection.rhythm(typed: "a, b") == DesignTokens.standard.rhythm)
        #expect(DesignTokensSection.text(of: DesignTokens.standard.rhythm) == "8, 12, 16, 24, 32")
        #expect(DesignTokens.reading(size: -1, standard: 16) == 16)
        #expect(DesignTokens.reading(size: .nan, standard: 16) == 16)
        #expect(DesignTokens.reading(size: 20, standard: 16) == 20)

        let (model, undo) = makeModel(design([screen(free: true)]))
        let store = model.store
        DesignTokensSection.edit(model) { $0.card.padding = -1 }
        #expect(store.tree.settings.tokens.card.padding == 16)
        DesignTokensSection.edit(model) { $0.rhythm = DesignTokensSection.rhythm(typed: "16, 8, 8, -2") }
        #expect(store.tree.settings.tokens.rhythm == [8, 16])
        DesignTokensSection.edit(model) { $0.textSizes.title = 34 }
        #expect(store.tree.settings.tokens.textSizes.title == 34)
        #expect(undo.undoActionName == "Format")
        undo.undo()
        #expect(store.tree.settings.tokens == .standard, "the run of edits is one Format step")
        #expect(!undo.canUndo)

        DesignTokensSection.edit(model) { $0.cornerRadii.large = 20 }
        DesignTokensSection.reset(model)
        #expect(store.tree.settings.tokens == .standard)

        // What the section keeps is what a file holding the same numbers reads as (F25).
        var typed = DesignTokens.standard
        typed.rhythm = [16, 8, 8, -2]
        typed.card.padding = -1
        typed.card.radius = 0
        typed.cornerRadii.small = -3
        typed.textSizes.body = 0
        let decoded = try JSONDecoder().decode(DesignTokens.self, from: JSONEncoder().encode(typed))
        DesignTokensSection.edit(model) { $0 = typed }
        #expect(store.tree.settings.tokens == decoded)
        #expect(decoded.rhythm == [8, 16] && decoded.card.padding == 16 && decoded.card.radius == 16)
        #expect(decoded.cornerRadii.small == 8 && decoded.textSizes.body == 15)
    }

    @Test func theDesignsTitleSizeIsMeasuredAndDrawnAlike() throws {
        let tokens = titleSized(34)
        let heading = words(.title, "A heading long enough to run onto a second line here")
        var content = design([screen([heading])], tokens: tokens)
        TreeRules.apply(to: &content, after: nil)
        let title = try #require(content.screens.first?.root.children.first)
        #expect(title.frame.width > 0)
        #expect(title.frame.height == measured(title, at: 34).height)
        #expect(title.frame.height != measured(title, at: 28).height)

        for kind in ElementKind.allCases where kind != .group && kind != .card {
            let node = LayerNode(kind: kind)
            #expect(NaturalSize.fontSize(of: node, tokens: tokens) == node.resolvedFontSize(tokens: tokens), "\(kind)")
        }

        // A root laid out ahead, off the main actor, measures it alike (F25).
        let ahead = TreeRules.laidOut(screen([heading]).root, deviceID: nil, settings: content.settings, previous: nil)
        let laid = try #require(ahead.children.first)
        #expect(laid.frame == title.frame)
        #expect(laid.frame.height == measured(laid, at: 34).height)
    }

    /// The Format panel's font size field shows the size a text is drawn at: the design's title size for a title
    /// without one of its own.
    @Test func theFormatPanelShowsTheDesignsTitleSize() {
        var title = LayerNode(kind: .title)
        #expect(StylePanel.fontSizeShown(for: title, tokens: titleSized(34)) == 34)
        #expect(StylePanel.fontSizeShown(for: title, tokens: .standard) == 28)
        title.style.fontSize = 20.4
        #expect(StylePanel.fontSizeShown(for: title, tokens: titleSized(34)) == 20)
    }

    @Test func aTokenChangeLaysOutEveryScreenOnce() throws {
        func screenWithARow(_ name: String) -> TreeScreen {
            var row = LayerNode(kind: .group)
            row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8, alignment: .center))
            row.children = [words(.text, "Left"), words(.text, "Right")]
            (row.width, row.height) = NaturalSize.defaultSizing(for: .group)
            return screen([words(.title, "Welcome"), row], named: name)
        }
        var card = LayerNode(kind: .card)
        card.layout = column(spacing: 8)
        card.padding = LayerNode.Padding(all: 16)
        card.frame = CGRect(x: 900, y: 0, width: 300, height: 100)
        card.width = LayerNode.Sizing(.fixed)
        card.height = LayerNode.Sizing(.fit)
        card.scale = 1
        card.children = [words(.title, "On the canvas")]
        var content = design([screenWithARow("Screen 1"), screenWithARow("Screen 2")])
        content.canvas = [card]
        let (model, _) = makeModel(content)
        let store = model.store

        var containers: [UUID] = [card.id]
        for screen in store.tree.screens {
            containers.append(screen.root.id)
            containers += screen.root.children.filter(\.isContainer).map(\.id)
        }
        #expect(containers.count == 5)
        let before = containers.map(LayoutEngine.timesLaidOut)

        store.updateCanvas { $0.tokens.textSizes.title = 34 }

        let after = containers.map(LayoutEngine.timesLaidOut)
        #expect(zip(before, after).map { $1 - $0 } == [1, 1, 1, 1, 1])
        let shown = try #require(store.tree.canvas.first?.children.first)
        #expect(shown.frame.height == measured(shown, at: 34).height)
        for screen in store.tree.screens {
            let title = try #require(screen.root.children.first)
            #expect(title.frame.height == measured(title, at: 34).height)
        }
    }
}
