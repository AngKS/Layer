import CoreGraphics
import Foundation

/// The kinds of thing that can sit on a screen or on the open canvas.
enum ElementKind: String, CaseIterable, Codable, Sendable {
    case title, body, image, button, textField, divider, symbol, text, stickyNote, toggle, avatar

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
        case .toggle: "Toggle"
        case .avatar: "Avatar"
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
        case .toggle: "switch.2"
        case .avatar: "person.crop.circle"
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
        case .image, .divider, .symbol, .toggle, .avatar: ""
        }
    }

    var hasText: Bool { !placeholder.isEmpty }

    /// Sticky notes are notes about a design, not part of one, so they never join a screen.
    var belongsOnScreens: Bool { self != .stickyNote }
}

enum TextAlignmentChoice: String, CaseIterable, Codable, Sendable {
    case leading, center, trailing

    var name: String {
        switch self {
        case .leading: "Left"
        case .center: "Centre"
        case .trailing: "Right"
        }
    }

    var symbol: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
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
    var textAlignment: TextAlignmentChoice?
    /// An outline round the element, drawn when the width is above zero.
    var borderColor: RGBColor?
    var borderWidth: CGFloat?
    var hasShadow = false

    /// The name shown in the Layers panel and used in generated code; the kind's name when unset.
    var name: String?
    /// A locked element can be selected but not moved, resized or scratched out.
    var isLocked = false
    /// A hidden element isn't drawn, can't be touched on the canvas, and is left out of the code.
    var isHidden = false
    /// For toggles: whether the switch is drawn on.
    var isOn = true

    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return kind.layerName }
        return name
    }
}

extension DesignElement {
    /// Reads every property that is present, so elements saved before one existed still open.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ElementKind.self, forKey: .kind)
        frame = try container.decode(CGRect.self, forKey: .frame)
        text = try container.decode(String.self, forKey: .text)
        tint = try container.decode(RGBColor.self, forKey: .tint)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        imageID = try container.decodeIfPresent(UUID.self, forKey: .imageID)
        fontSize = try container.decodeIfPresent(CGFloat.self, forKey: .fontSize)
        fontWeight = try container.decodeIfPresent(FontWeightChoice.self, forKey: .fontWeight)
        textColor = try container.decodeIfPresent(RGBColor.self, forKey: .textColor)
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        textAlignment = try container.decodeIfPresent(TextAlignmentChoice.self, forKey: .textAlignment)
        borderColor = try container.decodeIfPresent(RGBColor.self, forKey: .borderColor)
        borderWidth = try container.decodeIfPresent(CGFloat.self, forKey: .borderWidth)
        hasShadow = try container.decodeIfPresent(Bool.self, forKey: .hasShadow) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
    }
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
    /// Whether a dragged element snaps to the edges and centres of the screen and of its
    /// neighbours, as smart guides do.
    var snapsToGuides = true
    /// Whether things dragged on the canvas snap to the grid's marks.
    var snapsToGrid = false
    /// Whether the distances to neighbours are shown while an element is adjusted.
    var showsMeasurements = true
    /// Whether each screen's name is drawn above it.
    var showsFrameNames = true
    /// The canvas colour behind everything; the usual paper colour when unset.
    var background: RGBColor?
    /// The device a tall rectangle drawn with the Magic Pen becomes; an iPhone when unset.
    var sketchDeviceID: String?
    var code = CodeSettings()

    static let paper = RGBColor(hex: 0xF4F3EC)
    /// Canvas colours offered as swatches beside the colour well.
    static let backgrounds: [RGBColor] = [paper, RGBColor(hex: 0xFFFFFF), RGBColor(hex: 0xECEFF3), RGBColor(hex: 0xEFF3EA), RGBColor(hex: 0x2A2A2E)]

    var resolvedBackground: RGBColor { background ?? Self.paper }
    var sketchDevice: DeviceFrame { DeviceFrame.named(sketchDeviceID) }

    /// Whether the background is dark enough that marks on it should be light.
    var isDark: Bool {
        let colour = resolvedBackground
        return colour.red * 0.299 + colour.green * 0.587 + colour.blue * 0.114 < 0.5
    }
}

extension CanvasSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsGrid = try container.decodeIfPresent(Bool.self, forKey: .showsGrid) ?? true
        gridStyle = try container.decodeIfPresent(GridStyle.self, forKey: .gridStyle) ?? .dots
        gridSpacing = try container.decodeIfPresent(CGFloat.self, forKey: .gridSpacing) ?? 24
        snapsToGuides = try container.decodeIfPresent(Bool.self, forKey: .snapsToGuides) ?? true
        snapsToGrid = try container.decodeIfPresent(Bool.self, forKey: .snapsToGrid) ?? false
        showsMeasurements = try container.decodeIfPresent(Bool.self, forKey: .showsMeasurements) ?? true
        showsFrameNames = try container.decodeIfPresent(Bool.self, forKey: .showsFrameNames) ?? true
        background = try container.decodeIfPresent(RGBColor.self, forKey: .background)
        sketchDeviceID = try container.decodeIfPresent(String.self, forKey: .sketchDeviceID)
        code = try container.decodeIfPresent(CodeSettings.self, forKey: .code) ?? CodeSettings()
    }
}

/// How screens are written out as SwiftUI.
struct CodeSettings: Equatable, Codable, Sendable {
    enum Layout: String, CaseIterable, Codable, Sendable {
        /// A vertical stack, top to bottom, with the gaps as padding: the way a person writes it.
        case stack
        /// Every element at its exact place on the screen: faithful to the canvas.
        case absolute

        var name: String {
            switch self {
            case .stack: "Stack"
            case .absolute: "Exact Positions"
            }
        }
    }

    var layout = Layout.stack
    /// Whether each file ends with a `#Preview`.
    var includesPreview = true
    /// Whether the screen's title becomes its navigation title inside a `NavigationStack`.
    var usesNavigationTitle = false
}

extension CodeSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? .stack
        includesPreview = try container.decodeIfPresent(Bool.self, forKey: .includesPreview) ?? true
        usesNavigationTitle = try container.decodeIfPresent(Bool.self, forKey: .usesNavigationTitle) ?? false
    }
}
