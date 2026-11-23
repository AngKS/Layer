import CoreGraphics
import Foundation

/// One node of a design's semantic tree: a thing on the canvas, or a container holding
/// more of them. It sits beside `DesignElement`, which the app still uses; nothing reads
/// a `LayerNode` yet but the tree's own code. Everything here builds on macOS too, so no
/// UIKit and no SwiftUI: every type that could clash with SwiftUI's is nested below.
struct LayerNode: Identifiable, Equatable, Sendable, Codable {
    var id = UUID()
    var kind: ElementKind
    /// Back to front; the layout order in rows, columns and grids.
    var children: [LayerNode] = []
    /// Children this build couldn't read, each kept at its index among the children.
    var unreadChildren: [UnreadChild] = []
    /// Containers only; nil reads as `.free`.
    var layout: Layout?
    /// Containers only.
    var padding = Padding()
    var width = Sizing(.fixed)
    var height = Sizing(.fixed)
    /// In the parent's space, upright.
    var frame = CGRect.zero
    /// Degrees clockwise about the frame's centre.
    var rotation: Double?
    /// Top-level canvas nodes only.
    var scale: CGFloat?
    var content = Content()
    var style = Style()
    var name: String?
    var isLocked = false
    var isHidden = false
    var accessibility: Accessibility?
    var sketch: SketchIntent?
    var source: Source?
    /// Reserved: kept as it was read, never looked at.
    var interaction: JSONValue?
    /// What a newer Layer saved with the node that this version doesn't know.
    var unknownKeys = UnknownKeys()

    init(kind: ElementKind) {
        self.kind = kind
    }

    var isContainer: Bool { kind == .group || kind == .card }

    var resolvedLayout: Layout { layout ?? .free }
}

extension LayerNode {
    enum Layout: Equatable, Sendable, Codable {
        case free
        case stack(Stack)
        case grid(Grid)
        case overlay(Alignment)
    }

    struct Stack: Equatable, Sendable, Codable {
        var axis: Axis
        var spacing: CGFloat = 0
        var alignment: CrossAlignment = .start
        var justify: Justify = .start
    }

    enum Axis: String, Sendable, Codable { case horizontal, vertical }
    enum CrossAlignment: String, Sendable, Codable { case start, center, end, fill }
    enum Justify: String, Sendable, Codable { case start, center, end, spaceBetween, spaceAround, spaceEvenly }

    struct Grid: Equatable, Sendable, Codable {
        var columns: Int
        var columnSpacing: CGFloat = 0
        var rowSpacing: CGFloat = 0
        var alignment = Alignment()
    }

    enum Edge3: String, Sendable, Codable { case start, center, end }

    struct Alignment: Equatable, Sendable, Codable {
        var horizontal = Edge3.center
        var vertical = Edge3.center
    }

    struct Padding: Equatable, Sendable, Codable {
        var top: CGFloat = 0
        var leading: CGFloat = 0
        var bottom: CGFloat = 0
        var trailing: CGFloat = 0

        init() {}

        init(all: CGFloat) {
            self.init(top: all, leading: all, bottom: all, trailing: all)
        }

        init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
            (self.top, self.leading, self.bottom, self.trailing) = (top, leading, bottom, trailing)
        }
    }

    struct Sizing: Equatable, Sendable, Codable {
        enum Mode: Equatable, Sendable {
            case fit
            case fill(weight: CGFloat)
            case fixed
        }

        var mode: Mode
        var minimum: CGFloat?
        var maximum: CGFloat?

        init(_ mode: Mode, minimum: CGFloat? = nil, maximum: CGFloat? = nil) {
            self.mode = mode
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    struct Content: Equatable, Sendable {
        var text = ""
        var symbol: String?
        var shape: ShapeKind?
        var imageID: UUID?
        var isOn = true
        var value: Double?
        var buttonLook: ButtonLook?
        /// Never coded: ink is saved apart from the design, as `DesignElement`'s is.
        var ink: Data?
    }

    struct Style: Equatable, Sendable, Codable {
        var tint: RGBColor?
        var fontSize: CGFloat?
        var fontWeight: FontWeightChoice?
        var textColor: RGBColor?
        var textAlignment: TextAlignmentChoice?
        var cornerRadius: CGFloat?
        var opacity: Double?
        var borderColor: RGBColor?
        var borderWidth: CGFloat?
        var hasShadow = false
    }

    struct Accessibility: Equatable, Sendable, Codable {
        var label: String?
        var hint: String?
    }

    /// What settled a sketch's meaning.
    enum DecidedBy: String, Sendable, Codable { case rules, handwriting, model, asked, structure }
    enum PlacementIntent: String, Sendable, Codable { case fixed, leading, trailing, centered, proportional }

    /// Where a node was drawn and what the reading of it was, kept for the structure pass.
    struct SketchIntent: Equatable, Sendable, Codable {
        var originalBounds: CGRect
        var normalizedBounds: CGRect
        var confidence: Double
        var decidedBy: DecidedBy
        var placement: PlacementIntent
        var structureDeclined = false
    }

    enum Origin: String, Sendable, Codable { case user, sketch, generated, imported, template }

    struct Source: Equatable, Sendable, Codable {
        var origin: Origin
        var key: String?
    }

    struct UnreadChild: Equatable, Sendable {
        var index: Int
        var raw: JSONValue
    }
}

extension LayerNode {
    /// This node's own space to its parent's: translate to frame.origin, then turn about the frame's centre.
    /// Clockwise on screen, as `TurnedRect` turns. An angle that isn't a number is upright.
    var transformToParent: CGAffineTransform {
        let halfWidth = frame.size.width / 2, halfHeight = frame.size.height / 2
        let degrees = rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGAffineTransform(translationX: -halfWidth, y: -halfHeight)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: frame.origin.x + halfWidth, y: frame.origin.y + halfHeight))
    }
}
