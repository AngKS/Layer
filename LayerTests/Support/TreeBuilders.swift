import CoreGraphics
import Foundation
import Testing
@testable import Layer

// How plan 6's tests build a design and read it back: on the tree, never through the flat model (plan 6, Task 1). A
// ported setup reads as it did, with the old element's labels, and a frame is read in host points with `ownFrame`.
// Later tasks add what only they need in `TreeBuilders+<Area>.swift`.

extension LayerNode {
    /// A leaf, with the labels the flat element's initialiser had, so that a ported setup reads as it did; `rotation`
    /// and `id` come last. `.fixed` on both axes. A nil tint leaves `style.tint` nil: the kind's own.
    static func leaf(_ kind: ElementKind, frame: CGRect, text: String = "", tint: RGBColor? = nil, symbol: String? = nil,
                     shape: ShapeKind? = nil, imageID: UUID? = nil, fontSize: CGFloat? = nil, fontWeight: FontWeightChoice? = nil,
                     textColor: RGBColor? = nil, cornerRadius: CGFloat? = nil, opacity: Double? = nil,
                     textAlignment: TextAlignmentChoice? = nil, borderColor: RGBColor? = nil, borderWidth: CGFloat? = nil,
                     hasShadow: Bool = false, rotation: Double? = nil, name: String? = nil, isLocked: Bool = false,
                     isHidden: Bool = false, isOn: Bool = true, value: Double? = nil, buttonLook: ButtonLook? = nil,
                     id: UUID = UUID()) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.id = id
        node.frame = frame
        node.rotation = rotation
        node.name = name
        node.isLocked = isLocked
        node.isHidden = isHidden

        node.content.text = text
        node.content.symbol = symbol
        node.content.shape = shape
        node.content.imageID = imageID
        node.content.isOn = isOn
        node.content.value = value
        node.content.buttonLook = buttonLook

        node.style.tint = tint
        node.style.fontSize = fontSize
        node.style.fontWeight = fontWeight
        node.style.textColor = textColor
        node.style.textAlignment = textAlignment
        node.style.cornerRadius = cornerRadius
        node.style.opacity = opacity
        node.style.borderColor = borderColor
        node.style.borderWidth = borderWidth
        node.style.hasShadow = hasShadow
        return node
    }

    /// A container holding `children`, back to front: a group unless said, free unless given a layout, sized to fit on
    /// both axes unless said, with `padding` on every side.
    static func container(_ kind: ElementKind = .group, layout: LayerNode.Layout? = nil, frame: CGRect = .zero,
                          width: LayerNode.Sizing = .init(.fit), height: LayerNode.Sizing = .init(.fit), padding: CGFloat = 0,
                          rotation: Double? = nil, children: [LayerNode], id: UUID = UUID()) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.id = id
        node.layout = layout
        node.frame = frame
        node.width = width
        node.height = height
        node.padding = LayerNode.Padding(all: padding)
        node.rotation = rotation
        node.children = children
        return node
    }
}

@MainActor
extension DesignStore {
    /// A screen whose free root holds `nodes`, each where its frame puts it, added after the others as one step.
    /// A device of the design's own must be added to it first (`addCustomDevice`).
    @discardableResult
    func addFreeScreen(_ nodes: [LayerNode], name: String = "Screen 1", device: DeviceFrame = .iPhone,
                       origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeScreen.ID {
        addBuiltScreen(nodes, layout: nil, name: name, device: device, origin: origin, scale: scale)
    }

    /// A screen whose root lays `nodes` out in a column, `spacing` apart, inside the device's safe areas and margin,
    /// added after the others as one step.
    @discardableResult
    func addColumnScreen(_ nodes: [LayerNode], name: String = "Screen 1", spacing: CGFloat = 24, device: DeviceFrame = .iPhone,
                         origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeScreen.ID {
        addBuiltScreen(nodes, layout: .stack(LayerNode.Stack(axis: .vertical, spacing: spacing)), name: name, device: device,
                       origin: origin, scale: scale)
    }

    /// `node` on the open canvas, in front of what is there, drawn `scale` canvas points to each of its own: one step.
    /// Its id.
    @discardableResult
    func addCanvasNode(_ node: LayerNode, scale: CGFloat = 1) -> UUID {
        var drawn = node
        drawn.scale = scale
        if !add(drawn, to: .canvas) { Issue.record("The store refused a node for the canvas: \(node.kind)") }
        return drawn.id
    }

    /// A node's own frame in its host's points (screen points; on the canvas, its top-level node's own points), centred
    /// on its turned shape: what a test read as an element's frame. Nil for an id the design doesn't have.
    func ownFrame(_ id: UUID) -> CGRect? {
        index.ownPose(of: id, in: tree)?.frame
    }

    /// A screen's leaves, depth first, back to front: what a test read as the screen's elements.
    func screenLeaves(_ screenID: TreeScreen.ID) -> [LayerNode] {
        tree.leaves(on: screenID)
    }

    /// What plan 5's sketch wrapper gave a test (F12): the node `addSketched(kind, from: sketch, confidence: 1,
    /// decidedBy: .rules)` made, the sketch in canvas points, with its own frame in screen points. Nil when the sketch's
    /// centre isn't on `screenID` (the topmost screen there), or the store made nothing.
    func sketched(_ kind: ElementKind, from sketch: CGRect, to screenID: TreeScreen.ID) -> (id: UUID, frame: CGRect)? {
        guard self.screenID(under: sketch) == screenID,
              let id = addSketched(kind, from: sketch, confidence: 1, decidedBy: .rules),
              let frame = ownFrame(id) else { return nil }
        return (id, frame)
    }

    private func addBuiltScreen(_ nodes: [LayerNode], layout: LayerNode.Layout?, name: String, device: DeviceFrame,
                                origin: CGPoint, scale: CGFloat) -> TreeScreen.ID {
        var root = LayerNode(kind: .group)
        root.layout = layout
        root.children = nodes
        let screen = TreeScreen(name: name, origin: origin, scale: scale, deviceID: device == .iPhone ? nil : device.id, root: root)
        if addScreen(screen) == nil { Issue.record("The store refused the screen \"\(name)\"") }
        return screen.id
    }
}

/// The design plan 6's Siri and voice tasks share (Tasks 3–8).
enum TreeFixture {
    struct Login {
        var model: AppModel
        /// The store's, starting empty: building the design isn't a step.
        var undo: UndoManager
        /// The id of the file the design is saved in, which Siri knows it by: write `"\(designID)|…"` for an entity's.
        var designID: String
        var screen: TreeScreen.ID
        var title, card, about, body, row, label, toggle, note: UUID
    }

    /// One iPhone screen, "Login", at the canvas's origin, at scale 1, seen at zoom 1, on a free root holding:
    /// - `title`, a title "Welcome" at (20, 80, 228, 40);
    /// - `card`, a free card at (20, 140, 353, 160), fixed on both axes, padded 16, holding `about`, a text "About me"
    ///   at (16, 16, 200, 24), and `body`, a body "Designing better experiences." at (16, 48, 321, 40);
    /// - `row`, a group at (20, 320) that fits what it holds, laid out in a row 12 apart and centred across it, holding
    ///   `label`, a text "Wi-Fi" 80 × 24, and `toggle`, a toggle 51 × 31, on, both fixed.
    ///
    /// The canvas holds `note`, a sticky note "Idea" at (600, 100, 150, 150), drawn at scale 0.5.
    ///
    /// It is saved to a temporary file of its own, which the model is told it is in, so it registers with
    /// `OpenDesigns` under that file's id (F17). A test never reads `OpenDesigns.shared.current` across an await.
    @MainActor
    static func loginWithACardAndARow() -> Login {
        // A design that was opened, not made just now, in a file still called "Untitled": told its file, it takes no
        // title from the file's name, and doesn't make that name the app's name for new designs, which other tests read.
        let model = AppModel(document: LayerDocument(file: DesignFile()))
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)

        let title = LayerNode.leaf(.title, frame: CGRect(x: 20, y: 80, width: 228, height: 40), text: "Welcome")
        let about = LayerNode.leaf(.text, frame: CGRect(x: 16, y: 16, width: 200, height: 24), text: "About me")
        let body = LayerNode.leaf(.body, frame: CGRect(x: 16, y: 48, width: 321, height: 40), text: "Designing better experiences.")
        let card = LayerNode.container(.card, frame: CGRect(x: 20, y: 140, width: 353, height: 160), width: .init(.fixed),
                                       height: .init(.fixed), padding: 16, children: [about, body])
        let label = LayerNode.leaf(.text, frame: CGRect(x: 0, y: 0, width: 80, height: 24), text: "Wi-Fi")
        let toggle = LayerNode.leaf(.toggle, frame: CGRect(x: 0, y: 0, width: 51, height: 31), isOn: true)
        let row = LayerNode.container(layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: 12, alignment: .center)),
                                      frame: CGRect(x: 20, y: 320, width: 0, height: 0), children: [label, toggle])
        let note = LayerNode.leaf(.stickyNote, frame: CGRect(x: 600, y: 100, width: 150, height: 150), text: "Idea")

        let store = model.store
        let screen = store.addFreeScreen([title, card, row], name: "Login")
        store.addCanvasNode(note, scale: 0.5)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("Untitled.layer")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try model.document.current.wrapper().write(to: file, options: .atomic, originalContentsURL: nil)
        } catch {
            Issue.record("The fixture's design couldn't be saved: \(error)")
        }
        model.fileURL = file
        if model.designID == nil { Issue.record("The fixture's design has no id") }

        return Login(model: model, undo: undo, designID: model.designID ?? "", screen: screen, title: title.id, card: card.id,
                     about: about.id, body: body.id, row: row.id, label: label.id, toggle: toggle.id, note: note.id)
    }
}
