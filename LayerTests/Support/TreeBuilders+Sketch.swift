import CoreGraphics
import Foundation
@testable import Layer

// What the sketch, generation, code and panel tests read and build beyond Task 1's builders (plan 6, Task 10), each on
// the tree: a free screen's code as the flat screen's code was written, a sketch on the open canvas as the flat store
// placed it, where a node or a screen is on the canvas, and how many things the board holds.

extension SwiftUICodeGenerator {
    /// The code of a design whose one screen, named `name` at the canvas's origin and drawn as an iPhone, has a free root
    /// holding `nodes`, each where its frame puts it: what the code tests had from a flat screen of the same elements,
    /// whose code was written from its elements lifted into a free root. Its view is named `typeName`, else as the
    /// screen's name names it.
    static func code(ofAFreeScreenHolding nodes: [LayerNode], named name: String = "Screen 1", typeName: String? = nil,
                     settings: CodeSettings = CodeSettings()) -> String {
        var root = LayerNode(kind: .group)
        root.layout = .free
        root.children = nodes
        var content = TreeContent()
        content.screens = [TreeScreen(name: name, origin: .zero, scale: 1, deviceID: nil, root: root)]
        let screen = content.screens[0]
        var context = Context(content)
        context.typeNames[screen.id] = typeName ?? Self.typeName(of: screen)
        return code(for: screen, in: context, settings: settings)
    }
}

@MainActor
extension DesignStore {
    /// What the flat store's loose sketch (`addFloating` from a sketch) made of one on the open canvas, in canvas points:
    /// a new leaf of `kind` (`LayerNode.standard`), as large as it was drawn at `looseScale` as its kind's loose size
    /// allows, drawn at that scale on the open canvas with its middle on the sketch's, its corner on whole points; one
    /// step. Its id, or nil when the store refused it. Only for a sketch with no screen under it, as the tests that call
    /// it draw.
    @discardableResult
    func addLooseSketch(_ kind: ElementKind, from sketch: CGRect) -> UUID? {
        let scale = looseScale
        var node = LayerNode.standard(kind)
        let drawn = CGSize(width: sketch.width / scale, height: sketch.height / scale)
        node.frame.size = kind.spec.looseSize.size(from: node.frame.size, drawn: drawn)
        node.frame.origin = CGPoint(x: (sketch.midX / scale - node.frame.width / 2).rounded(),
                                    y: (sketch.midY / scale - node.frame.height / 2).rounded())
        node.scale = scale
        return add(node, to: .canvas) ? node.id : nil
    }

    /// A node's upright frame on the canvas, centred on its turned shape: what a test read as the flat element's frame
    /// on the canvas. Nil for an id the design doesn't have, and a screen's root.
    func frameOnCanvas(of id: UUID) -> CGRect? {
        placed(id).map { $0.placement.canvasRect(for: $0.frame) }
    }

    /// Where a screen is drawn on the canvas, as its device, a design's own included: what a test read as the flat
    /// screen's canvas frame. Nil for a screen the design doesn't have.
    func screenFrameOnCanvas(_ id: TreeScreen.ID) -> CGRect? {
        let tree = tree
        return treeScreen(id).map { $0.canvasFrame(on: tree.device(of: $0)) }
    }

    /// How many things the board holds, containers included, on every screen and the open canvas, the screens' roots
    /// left out: what a test counted as the flat content's elements.
    var thingCount: Int {
        index.count - tree.screens.count
    }
}
