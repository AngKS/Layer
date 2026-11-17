// Stand-ins for the two layout helpers ScreenBlueprint.swift refers to. The harness only
// parses and scores screens; it never lays them out, so neither is called.
import CoreGraphics
enum ElementLayout {
    static func size(for kind: ElementKind, sketch: CGRect) -> CGSize { .zero }
    static func keepsSketchedPosition(_ kind: ElementKind) -> Bool { false }
}
enum DesignStore {
    static func newElement(_ kind: ElementKind, symbol: String?) -> DesignElement { fatalError("not used") }
}
