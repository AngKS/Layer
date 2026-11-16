import CoreGraphics
import Foundation

/// The kinds of thing that can sit on a screen or on the open canvas.
enum ElementKind: String, CaseIterable, Codable, Sendable {
    case title, body, image, button, textField, divider, symbol, text, stickyNote

    var layerName: String {
        switch self {
        case .title: "Title"
        case .body: "Body"
        case .image: "Image"
        case .button: "Button"
        case .textField: "Text Field"
        case .divider: "Divider"
        case .symbol: "Symbol"
        case .text: "Text"
        case .stickyNote: "Sticky Note"
        }
    }

    var symbol: String {
        switch self {
        case .title: "textformat"
        case .body: "text.alignleft"
        case .image: "photo"
        case .button: "capsule.fill"
        case .textField: "character.cursor.ibeam"
        case .divider: "minus"
        case .symbol: "star"
        case .text: "character.textbox"
        case .stickyNote: "note.text"
        }
    }

    /// The copy a new element starts with.
    var placeholder: String {
        switch self {
        case .title: "Title"
        case .body: "A short description goes here, a line or two that says what this is."
        case .button: "Continue"
        case .textField: "Placeholder"
        case .text: "Text"
        case .stickyNote: "Note"
        case .image, .divider, .symbol: ""
        }
    }

    var hasText: Bool { !placeholder.isEmpty }

    /// Sticky notes are notes about a design, not part of one, so they never join a screen.
    var belongsOnScreens: Bool { self != .stickyNote }
}

enum FontWeightChoice: String, CaseIterable, Codable, Sendable {
    case regular, medium, semibold, bold

    var name: String { rawValue.capitalized }
}

struct DesignElement: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var kind: ElementKind
    /// In its screen's own points, the same units the generated SwiftUI uses.
    var frame: CGRect
    var text: String
    /// The element's own colour: a button's or sticky note's fill, a symbol's ink.
    var tint: RGBColor
    /// For symbols: the SF Symbol's name.
    var symbol: String?
    /// For images that show an attached picture: which one.
    var imageID: UUID?

    // Each of these overrides the kind's usual look when set. See `ElementStyle`.
    var fontSize: CGFloat?
    var fontWeight: FontWeightChoice?
    var textColor: RGBColor?
    var cornerRadius: CGFloat?
    var opacity: Double?
    /// A locked element can't be moved, resized or deleted until it is unlocked.
    var isLocked: Bool?
}

/// Where a group of elements sits on the canvas: where its own origin falls, and how
/// large its points are drawn.
struct Placement: Equatable, Sendable {
    var origin: CGPoint
    var scale: CGFloat

    func canvasPoint(for local: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + local.x * scale, y: origin.y + local.y * scale)
    }

    func canvasRect(for local: CGRect) -> CGRect {
        CGRect(origin: canvasPoint(for: local.origin), size: CGSize(width: local.width * scale, height: local.height * scale))
    }

    func localPoint(for canvas: CGPoint) -> CGPoint {
        CGPoint(x: (canvas.x - origin.x) / scale, y: (canvas.y - origin.y) / scale)
    }

    func localRect(for canvas: CGRect) -> CGRect {
        CGRect(origin: localPoint(for: canvas.origin), size: CGSize(width: canvas.width / scale, height: canvas.height / scale))
    }
}

/// An element that sits on the open canvas rather than on a screen. Its frame is in points
/// of its own, `scale` canvas points each, so it keeps the proportions it would have on
/// a screen drawn at that scale.
struct FloatingElement: Identifiable, Equatable, Codable, Sendable {
    var element: DesignElement
    var scale: CGFloat

    var id: DesignElement.ID { element.id }
    var placement: Placement { Placement(origin: .zero, scale: scale) }
    var canvasFrame: CGRect { placement.canvasRect(for: element.frame) }
}

/// A device a screen can be drawn as: its size in points and the furniture round its edges.
struct DeviceFrame: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let size: CGSize
    /// The space the status bar and the home indicator keep clear.
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let cornerRadius: CGFloat
    let hasIsland: Bool
    let hasHomeIndicator: Bool

    /// The device a sketched screen becomes.
    static let iPhone = DeviceFrame(
        id: "iphone", name: "iPhone", size: CGSize(width: 393, height: 852),
        safeTop: 59, safeBottom: 34, cornerRadius: 52, hasIsland: true, hasHomeIndicator: true
    )

    static let all = [
        iPhone,
        DeviceFrame(
            id: "iphone-pro-max", name: "iPhone Pro Max", size: CGSize(width: 440, height: 956),
            safeTop: 62, safeBottom: 34, cornerRadius: 58, hasIsland: true, hasHomeIndicator: true
        ),
        DeviceFrame(
            id: "iphone-se", name: "iPhone SE", size: CGSize(width: 375, height: 667),
            safeTop: 20, safeBottom: 0, cornerRadius: 6, hasIsland: false, hasHomeIndicator: false
        ),
        DeviceFrame(
            id: "ipad", name: "iPad", size: CGSize(width: 820, height: 1180),
            safeTop: 24, safeBottom: 20, cornerRadius: 26, hasIsland: false, hasHomeIndicator: true
        ),
    ]

    static func named(_ id: String?) -> DeviceFrame {
        all.first { $0.id == id } ?? iPhone
    }
}

/// One device screen on the canvas. Elements live in the screen's logical points; `origin`
/// and `scale` say where and how large the screen is drawn on the canvas.
struct DesignScreen: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var name: String
    var origin: CGPoint
    var scale: CGFloat
    /// Which device this is; an iPhone when unset.
    var deviceID: String?
    /// In creation order; later elements sit on top.
    var elements: [DesignElement] = []
    /// A locked screen can't be moved or deleted until it is unlocked. Its elements can
    /// still be edited.
    var isLocked: Bool?

    var device: DeviceFrame { DeviceFrame.named(deviceID) }
    var size: CGSize { device.size }
    var placement: Placement { Placement(origin: origin, scale: scale) }

    var canvasFrame: CGRect {
        placement.canvasRect(for: CGRect(origin: .zero, size: size))
    }

    /// Where the screen's name is drawn, above its top-left corner.
    var labelFrame: CGRect {
        placement.canvasRect(for: CGRect(x: 0, y: -34, width: 150, height: 30))
    }

    func canvasPoint(for local: CGPoint) -> CGPoint { placement.canvasPoint(for: local) }
    func canvasRect(for local: CGRect) -> CGRect { placement.canvasRect(for: local) }
    func localRect(for canvas: CGRect) -> CGRect { placement.localRect(for: canvas) }

    /// "Screen 1" becomes `Screen1`, the name of the generated view and its file.
    var typeName: String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber }
        guard let first = cleaned.first, first.isLetter else { return "Screen" + cleaned }
        return cleaned
    }
}

/// How the canvas itself looks and behaves, kept with each design.
struct CanvasSettings: Equatable, Codable, Sendable {
    enum GridStyle: String, CaseIterable, Codable, Sendable {
        case dots, lines
    }

    var showsGrid = true
    var gridStyle = GridStyle.dots
    /// The distance between grid marks, in canvas points.
    var gridSpacing: CGFloat = 24
    /// Whether an element dragged near a screen's centre line snaps onto it.
    var snapsToGuides = true
}
