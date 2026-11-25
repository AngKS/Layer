import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// What the store passes over since the performance sweep, held to what the full path gives (the sweep's review,
/// Minors 1, 3 and 5). The rules skip a screen or canvas node unchanged from the store's last version, and lay out
/// nothing the engine would lay out alike (`LayoutEngine.laysOutAlike`); the index re-poses only what changed
/// (`TreeIndex.refresh`). Each is a hand-kept copy of what the engine or the index reads, so each field either reads is
/// changed here through the store, and every field of a node is classed, so that a new one fails until it is.
@MainActor
@Suite struct SkippedWorkTests {
    // MARK: - A design with a field of every kind to change

    struct IDs {
        var free, column, row, label, toggle, body, group, square, tilted, card, cardTitle, cardText, chip, canvasRow,
            canvasGroup: UUID
    }

    /// Words of a kind, fitting both ways, as generation makes them.
    private static func words(_ kind: ElementKind, _ text: String) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.content.text = text
        (node.width, node.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
        return node
    }

    private static func fixed(_ kind: ElementKind, _ frame: CGRect) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        return node
    }

    private static func container(_ layout: LayerNode.Layout?, kind: ElementKind = .group, at frame: CGRect,
                                  _ children: [LayerNode]) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.layout = layout
        node.frame = frame
        (node.width, node.height) = (LayerNode.Sizing(.fit), LayerNode.Sizing(.fit))
        node.children = children
        return node
    }

    /// A free iPhone screen holding a row (a fitting text, a toggle and a body), a free group of two shapes that fits
    /// them, and a fixed-width card laying out a title and a text; an iPhone screen whose root is a column of a title and
    /// a text; and on the canvas a row of a text and a shape, and a group at half size. Laid out by the rules in full.
    static func design() -> (content: TreeContent, ids: IDs) {
        let label = words(.text, "Wi-Fi network"), body = words(.body, "Shown")
        let toggle = fixed(.toggle, CGRect(x: 0, y: 0, width: 51, height: 31))
        let row = container(.stack(LayerNode.Stack(axis: .horizontal, spacing: 8, alignment: .center)),
                            at: CGRect(x: 20, y: 100, width: 0, height: 0), [label, toggle, body])
        let square = fixed(.shape, CGRect(x: 0, y: 0, width: 60, height: 40))
        let tilted = fixed(.shape, CGRect(x: 80, y: 20, width: 40, height: 40))
        let group = container(nil, at: CGRect(x: 20, y: 300, width: 10, height: 10), [square, tilted])
        let cardTitle = words(.title, "Title"), cardText = words(.text, "Inside the card")
        var card = container(.stack(LayerNode.Stack(axis: .vertical, spacing: 8)), kind: .card,
                             at: CGRect(x: 20, y: 420, width: 300, height: 10), [cardTitle, cardText])
        card.padding = LayerNode.Padding(all: 16)
        card.width = LayerNode.Sizing(.fixed)
        var free = TreeScreen(name: "Free", origin: .zero, scale: 1, deviceID: nil)
        free.root.children = [row, group, card]
        var column = TreeScreen(name: "Column", origin: CGPoint(x: 500, y: 0), scale: 1, deviceID: nil)
        column.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .fill))
        column.root.children = [words(.title, "Heading"), words(.text, "In a column")]
        let chip = words(.text, "Chip")
        var canvasRow = container(.stack(LayerNode.Stack(axis: .horizontal, spacing: 8)), at: CGRect(x: 0, y: 1200, width: 10, height: 10),
                                  [chip, fixed(.shape, CGRect(x: 0, y: 0, width: 30, height: 30))])
        canvasRow.scale = 1
        var canvasGroup = container(nil, at: CGRect(x: 400, y: 1200, width: 100, height: 100),
                                    [fixed(.shape, CGRect(x: 0, y: 0, width: 40, height: 40)), fixed(.shape, CGRect(x: 60, y: 0, width: 40, height: 40))])
        canvasGroup.scale = 0.5
        var content = TreeContent()
        content.screens = [free, column]
        content.canvas = [canvasRow, canvasGroup]
        TreeRules.apply(to: &content, after: nil)
        return (content, IDs(free: free.id, column: column.id, row: row.id, label: label.id, toggle: toggle.id, body: body.id,
                             group: group.id, square: square.id, tilted: tilted.id, card: card.id, cardTitle: cardTitle.id,
                             cardText: cardText.id, chip: chip.id, canvasRow: canvasRow.id, canvasGroup: canvasGroup.id))
    }

    /// Every node's frame, by id.
    private static func frames(_ tree: TreeContent) -> [UUID: CGRect] {
        var found: [UUID: CGRect] = [:]
        func visit(_ node: LayerNode) {
            found[node.id] = node.frame
            node.children.forEach(visit)
        }
        tree.screens.forEach { visit($0.root) }
        tree.canvas.forEach(visit)
        return found
    }

    /// The design with the rules applied in full, as a file read lays it out.
    private static func laidOutInFull(_ tree: TreeContent) -> TreeContent {
        var tree = tree
        TreeRules.apply(to: &tree, after: nil)
        return tree
    }

    // MARK: - Each field, changed through the store

    /// A field the engine or the index reads, and a change to it through the store: whether the change moves
    /// something, so that a skip that shouldn't have been taken would leave a frame the full layout doesn't.
    enum Field: String, CaseIterable, Sendable {
        case fontWeight, fontSize, words, kind, widthSizing, heightSizing, layoutSpacing, layoutAxis, padding, fixedFrame,
             angle, hidden, nestedScale, unreadChildren, canvasFontWeight, canvasScale, lock, passStructure, titleSize,
             bodySize, textSize, look, cardRadius, device

        var moves: Bool {
            switch self {
            case .nestedScale, .unreadChildren, .canvasScale, .lock, .passStructure, .look, .cardRadius: false
            default: true
            }
        }

        @MainActor func make(in store: DesignStore, _ ids: IDs) {
            switch self {
            case .fontWeight: store.update(ids.label) { $0.style.fontWeight = .bold }
            case .fontSize: store.update(ids.label) { $0.style.fontSize = 30 }
            case .words: store.update(ids.label) { $0.content.text = "A much longer name for the network" }
            case .kind: store.update(ids.label) { $0.kind = .title }
            case .widthSizing: store.update(ids.cardText) { $0.width = LayerNode.Sizing(.fill(weight: 1)) }
            case .heightSizing: store.update(ids.cardTitle) { $0.height = LayerNode.Sizing(.fit, minimum: 80) }
            case .layoutSpacing:
                store.update(ids.row) { $0.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 30, alignment: .center)) }
            case .layoutAxis:
                store.update(ids.row) { $0.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 8, alignment: .center)) }
            case .padding: store.update(ids.card) { $0.padding = LayerNode.Padding(all: 32) }
            case .fixedFrame: store.update(ids.toggle) { $0.frame.size.width = 90 }
            case .angle: store.update(ids.tilted) { $0.rotation = 45 }
            case .hidden: store.update(ids.body) { $0.isHidden = true }
            case .nestedScale: store.update(ids.square) { $0.scale = 2 }
            case .unreadChildren:
                store.reconcile(ids.free) { root in
                    root.children[1].unreadChildren.append(LayerNode.UnreadChild(index: 2, raw: .object(["kind": .string("future")])))
                }
            case .canvasFontWeight: store.update(ids.chip) { $0.style.fontWeight = .bold }
            case .canvasScale: store.update(ids.canvasGroup) { $0.scale = 1 }
            case .lock: store.update(ids.card) { $0.isLocked = true }
            case .passStructure:
                store.update(ids.group) {
                    $0.sketch = LayerNode.SketchIntent(sketched: $0.frame, on: nil, margin: 0, confidence: 1, decidedBy: .structure)
                }
            case .titleSize: store.updateCanvas { $0.tokens.textSizes.title = 40 }
            case .bodySize: store.updateCanvas { $0.tokens.textSizes.body = 22 }
            case .textSize: store.updateCanvas { $0.tokens.textSizes.text = 24 }
            case .look:
                store.update(ids.label) {
                    $0.style.tint = RGBColor(hex: 0xFF3B30)
                    $0.style.textColor = RGBColor(hex: 0x34C759)
                    $0.style.cornerRadius = 6
                    $0.style.borderWidth = 4
                    $0.style.hasShadow = true
                    $0.name = "Named"
                }
            case .cardRadius: store.updateCanvas { $0.tokens.card.radius = 4 }
            case .device: store.setDevice(of: ids.column, to: "ipad")
            }
        }
    }

    /// Each field the engine or the index reads, changed through the store on a design that follows the rules: what the
    /// store's incremental change gives is what laying the whole design out again gives, and its kept index is a fresh
    /// build's. A change that lays something out moved a frame, so a layout the store wrongly passed over would show.
    @Test(arguments: Field.allCases)
    func aChangeToAFieldLayoutOrTheIndexReadsIsLaidOutAsInFull(_ field: Field) {
        let (content, ids) = Self.design()
        let store = DesignStore(content: content)
        _ = store.index
        let before = Self.frames(store.tree)

        field.make(in: store, ids)

        #expect(Self.laidOutInFull(store.tree) == store.tree, "\(field): the store's layout is a full layout's")
        #expect(store.index == TreeIndex(store.tree), "\(field): the kept index is a fresh build's")
        if field.moves {
            #expect(Self.frames(store.tree) != before, "\(field) moved something, so a missed layout would show")
        } else {
            #expect(Self.frames(store.tree) == before, "\(field) moves nothing")
        }
    }

    // MARK: - Every field classed

    /// What a node's own fields, its look's and its content's, are to layout: read by the engine, so compared by
    /// `LayoutEngine.laysOutAlike`; or never read by it.
    static let readByLayout: Set<String> = [
        "id", "kind", "children", "unreadChildren", "layout", "padding", "width", "height", "frame", "rotation", "scale",
        "isHidden", "content.text", "style.fontSize", "style.fontWeight",
    ]
    static let layoutFree: Set<String> = [
        "name", "isLocked", "accessibility", "sketch", "source", "interaction", "unknownKeys", "unknownPartKeys",
        "content.symbol", "content.shape", "content.imageID", "content.isOn", "content.value", "content.buttonLook",
        "content.ink", "style.tint", "style.textColor", "style.textAlignment", "style.cornerRadius", "style.opacity",
        "style.borderColor", "style.borderWidth", "style.hasShadow",
    ]

    /// The same to the index: read where an entry is worked out (`TreeIndex.isPosedAlike`, the structure count's kind
    /// and sketch, and the place in the tree), or not.
    static let readByTheIndex: Set<String> = [
        "id", "kind", "children", "frame", "rotation", "scale", "isLocked", "isHidden", "sketch",
    ]

    /// `LayerNode`'s own fields, with its look's and content's as `style.<field>` and `content.<field>`.
    private static func fieldsOfANode() -> Set<String> {
        let own = Mirror(reflecting: LayerNode(kind: .text)).children.compactMap(\.label)
        let style = Mirror(reflecting: LayerNode.Style()).children.compactMap(\.label).map { "style.\($0)" }
        let content = Mirror(reflecting: LayerNode.Content()).children.compactMap(\.label).map { "content.\($0)" }
        return Set(own.filter { $0 != "style" && $0 != "content" } + style + content)
    }

    private static func fields(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }

    /// Every stored field of a node, its look and its content is classed, for layout and for the index. A field added to
    /// any of them fails here until it is classed, and taught to `laysOutAlike`, or to the index, if either reads it.
    /// The layout's own types are compared whole by their `==`, so a field added to one is compared already; they are
    /// listed so that it is seen.
    @Test func everyFieldOfANodeIsClassedForLayoutAndTheIndex() {
        let fields = Self.fieldsOfANode()
        #expect(Self.readByLayout.isDisjoint(with: Self.layoutFree))
        let classed = Self.readByLayout.union(Self.layoutFree)
        #expect(fields.subtracting(classed).isEmpty, "not classed for layout: \(fields.subtracting(classed).sorted())")
        #expect(classed.subtracting(fields).isEmpty, "classed, but not a field: \(classed.subtracting(fields).sorted())")
        #expect(Self.readByTheIndex.isSubset(of: Set(Self.fields(of: LayerNode(kind: .text)))))

        #expect(Self.fields(of: LayerNode(kind: .text)) == [
            "id", "kind", "children", "unreadChildren", "layout", "padding", "width", "height", "frame", "rotation", "scale",
            "content", "style", "name", "isLocked", "isHidden", "accessibility", "sketch", "source", "interaction",
            "unknownKeys", "unknownPartKeys",
        ], "a node's fields changed: class the new one for the index too (readByTheIndex)")
        #expect(Self.fields(of: LayerNode.Stack(axis: .horizontal)) == ["axis", "spacing", "alignment", "justify"])
        #expect(Self.fields(of: LayerNode.Grid(columns: 2)) == ["columns", "columnSpacing", "rowSpacing", "alignment"])
        #expect(Self.fields(of: LayerNode.Alignment()) == ["horizontal", "vertical"])
        #expect(Self.fields(of: LayerNode.Padding()) == ["top", "leading", "bottom", "trailing"])
        #expect(Self.fields(of: LayerNode.Sizing(.fit)) == ["mode", "minimum", "maximum"])
        #expect(Self.fields(of: LayerNode.SketchIntent(sketched: .zero, on: nil, margin: 0, confidence: 1, decidedBy: .rules)) == [
            "originalBounds", "normalizedBounds", "confidence", "decidedBy", "placement", "structureDeclined",
        ], "the index reads only a sketch's decidedBy (LayerNode.isAStructureThePassMade)")
    }

    /// A change to each classed field, from a node every one of them changes.
    private static func changes() -> [String: (inout LayerNode) -> Void] {
        [
            "id": { $0.id = UUID() },
            "kind": { $0.kind = .title },
            "children": { $0.children.append(LayerNode(kind: .shape)) },
            "unreadChildren": { $0.unreadChildren.append(LayerNode.UnreadChild(index: 0, raw: .null)) },
            "layout": { $0.layout = .stack(LayerNode.Stack(axis: .vertical)) },
            "padding": { $0.padding = LayerNode.Padding(all: 4) },
            "width": { $0.width = LayerNode.Sizing(.fill(weight: 1)) },
            "height": { $0.height = LayerNode.Sizing(.fixed) },
            "frame": { $0.frame.origin.x += 1 },
            "rotation": { $0.rotation = 10 },
            "scale": { $0.scale = 2 },
            "isHidden": { $0.isHidden.toggle() },
            "content.text": { $0.content.text += " more" },
            "style.fontSize": { $0.style.fontSize = 30 },
            "style.fontWeight": { $0.style.fontWeight = .bold },
            "name": { $0.name = "Named" },
            "isLocked": { $0.isLocked.toggle() },
            "accessibility": { $0.accessibility = LayerNode.Accessibility(label: "Label", hint: nil) },
            "sketch": { $0.sketch = LayerNode.SketchIntent(sketched: .zero, on: nil, margin: 0, confidence: 1, decidedBy: .structure) },
            "source": { $0.source = LayerNode.Source(origin: .user, key: nil) },
            "interaction": { $0.interaction = .bool(true) },
            "unknownKeys": { $0.unknownKeys.values["future"] = .string("kept") },
            "unknownPartKeys": { $0.unknownPartKeys["style"] = UnknownKeys() },
            "content.symbol": { $0.content.symbol = "star" },
            "content.shape": { $0.content.shape = .ellipse },
            "content.imageID": { $0.content.imageID = UUID() },
            "content.isOn": { $0.content.isOn.toggle() },
            "content.value": { $0.content.value = 0.5 },
            "content.buttonLook": { $0.content.buttonLook = .bordered },
            "content.ink": { $0.content.ink = Data([1, 2, 3]) },
            "style.tint": { $0.style.tint = RGBColor(hex: 0xFF3B30) },
            "style.textColor": { $0.style.textColor = RGBColor(hex: 0x34C759) },
            "style.textAlignment": { $0.style.textAlignment = .center },
            "style.cornerRadius": { $0.style.cornerRadius = 6 },
            "style.opacity": { $0.style.opacity = 0.5 },
            "style.borderColor": { $0.style.borderColor = RGBColor(hex: 0x007AFF) },
            "style.borderWidth": { $0.style.borderWidth = 2 },
            "style.hasShadow": { $0.style.hasShadow.toggle() },
        ]
    }

    /// `laysOutAlike` does what the classing says, field by field: a node changed in a field layout reads no longer
    /// lays out alike, and one changed in a field it never reads still does, its children's included.
    @Test func laysOutAlikeComparesExactlyTheFieldsLayoutReads() {
        var base = Self.words(.text, "Words")
        base.frame = CGRect(x: 10, y: 10, width: 80, height: 24)
        let changes = Self.changes()
        var parent = Self.container(.stack(LayerNode.Stack(axis: .horizontal)), at: .zero, [base])
        parent.id = UUID()
        for field in Self.readByLayout.union(Self.layoutFree).sorted() {
            guard let change = changes[field] else {
                Issue.record("\(field) has no change to try: write one")
                continue
            }
            var changed = base
            change(&changed)
            #expect(changed != base, "\(field)'s change changes the node")
            let isRead = Self.readByLayout.contains(field)
            #expect(LayoutEngine.laysOutAlike(changed, base) == !isRead, "\(field) on the node itself")
            var changedParent = parent
            changedParent.children[0] = changed
            #expect(LayoutEngine.laysOutAlike(changedParent, parent) == !isRead, "\(field) on a child")
        }
    }

    // MARK: - A design read from a package

    #if DEBUG
    /// A design written to a package and read back, as the app opens one, follows the rules in full from the start
    /// (`DesignFile` lays it out on reading), so the store's skips apply in the app: a look changed lays nothing out.
    @Test func aDesignReadFromAPackageFollowsTheRulesSoALookLaysNothingOut() throws {
        // Written as it was made, not laid out: the reading lays it out.
        var made = TreeContent()
        var screen = TreeScreen(name: "Settings", origin: .zero, scale: 1, deviceID: nil)
        screen.root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .fill))
        screen.root.children = (0..<4).map { number in
            var row = Self.container(.stack(LayerNode.Stack(axis: .horizontal, spacing: 8, alignment: .center)), at: .zero,
                                     [Self.words(.text, "Setting \(number)"), Self.fixed(.toggle, CGRect(x: 0, y: 0, width: 51, height: 31))])
            row.width = LayerNode.Sizing(.fill(weight: 1))
            return row
        }
        made.screens = [screen]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Settings.layer")
        try DesignFile(content: made).wrapper().write(to: url, options: .atomic, originalContentsURL: nil)

        let read = try DesignFile(wrapper: FileWrapper(url: url))
        let model = AppModel(document: LayerDocument(file: read))
        let store = model.store
        #expect(store.tree != made, "the reading laid it out")
        #expect(Self.laidOutInFull(store.tree) == store.tree, "it follows the rules in full as it is opened")

        let root = try #require(store.tree.screens.first?.root)
        let containers = [root.id] + root.children.map(\.id)
        let toggle = try #require(root.children.first?.children.last?.id)
        let before = containers.map(LayoutEngine.timesLaidOut)
        store.update(toggle) { $0.style.tint = RGBColor(hex: 0xFF3B30) }
        #expect(zip(containers.map(LayoutEngine.timesLaidOut), before).map(-) == containers.map { _ in 0 },
                "a look on a design read from a package lays nothing out")
        store.update(toggle) { $0.frame.size.width = 70 }
        #expect(LayoutEngine.timesLaidOut(root.children[0].id) - before[1] == 1, "a toggle widened lays out its row")
        #expect(Self.laidOutInFull(store.tree) == store.tree)
    }
    #endif

    // MARK: - What was laid out ahead

    /// A generator's writes and an A2UI import commit roots laid out off the main actor, which the rules trust (plan 3,
    /// call 6). Through both, and through looks and words changed on what they made after, the design follows the rules
    /// in full and the kept index is a fresh build's: a root they trusted was a full layout's, so the skips after it
    /// pass over nothing that needed laying out.
    @Test func aGenerationAndAnImportLeaveTheDesignFollowingTheRules() async throws {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        let store = model.store
        func check(_ what: String) {
            #expect(Self.laidOutInFull(store.tree) == store.tree, "after \(what), the design follows the rules in full")
            #expect(store.index == TreeIndex(store.tree), "after \(what), the kept index is a fresh build's")
        }

        let screen = try #require(store.addScreen(TreeScreen(name: "Settings", origin: .zero, scale: 1, deviceID: nil,
                                                             root: Outline.parse("", isComplete: true))))
        let writer = GenerationWriter(screenID: screen)
        #expect(await writer.write(Outline.parse("title: Settings\ntext: Wi-Fi\nbutton: Save", isComplete: true), to: store, in: nil))
        check("a generated screen")
        #expect(await writer.write(Outline.parse("title: Settings\ntext: Wi-Fi\ntext: Bluetooth on this iPad\nbutton: Save",
                                                 isComplete: true), to: store, in: nil))
        check("a generator's second update, laid out over its first")
        let written = try #require(store.root(of: screen)).leaves
        let text = try #require(written.first { $0.kind == .text }?.id)
        store.update(text) { $0.style.tint = RGBColor(hex: 0xFF3B30) }
        check("a look on a generated text")
        store.update(text) { $0.style.fontWeight = .bold }
        check("a font weight on a generated text")

        let report = await model.importA2UI(try Self.fixture("a2ui-scaffold-simple-login-form"))
        let imported = try #require(report.screens.first)
        check("an imported screen")
        let fields = try #require(store.root(of: imported)).leaves
        let first = try #require(fields.first?.id)
        store.update(first) { $0.style.hasShadow = true }
        check("a look on an imported thing")
        store.update(first) { $0.content.text = "A much longer title than the import had" }
        check("words on an imported thing")
        undo.undo()
        undo.undo()
        check("two undos")
    }

    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: SkippedWorkBundleMarker.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}

private final class SkippedWorkBundleMarker {}
