import CoreGraphics
import Foundation

/// The kinds of thing that can sit on a screen or on the open canvas.
enum ElementKind: String, CaseIterable, Codable, Sendable {
    case title, body, image, button, textField, divider, symbol, text, stickyNote, toggle, avatar, checkbox, radio, progress
    /// A plain shape: a rectangle, a circle, a triangle, an arrow. See `ShapeKind`.
    case shape
    /// Ink kept as it was drawn: a sketch, a figure, an arrow, a handwritten note.
    case drawing
    /// Several things kept together as one. It is never drawn, written or described itself:
    /// its members are, and they point at it with their `group`. Its frame is the box round
    /// them, which the design keeps current; see `DesignContent.keepGroupsSound()`.
    case group

    // What each kind is called and how it behaves is in `Catalogue`; see `spec`.

    /// Every kind an element can be placed, sketched or written as: all but `.group`, which
    /// is made by grouping.
    static var placeable: [ElementKind] { allCases.filter { $0 != .group } }

    var layerName: String { spec.name }

    var symbol: String { spec.symbol }

    /// The copy a new element starts with.
    var placeholder: String { spec.placeholder }

    var hasText: Bool { !placeholder.isEmpty }

    /// Whether it can join a screen, or stays on the open canvas as sticky notes do.
    var belongsOnScreens: Bool { spec.belongsOnScreens }
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

/// How a button is drawn: filled with its colour, outlined in it, or as tinted text alone.
enum ButtonLook: String, CaseIterable, Codable, Sendable {
    case filled, bordered, plain

    var name: String { rawValue.capitalized }
}

enum FontWeightChoice: String, CaseIterable, Codable, Sendable {
    case regular, medium, semibold, bold

    var name: String { rawValue.capitalized }
}

/// One thing on the board. All of them are kept in one list, `DesignContent.elements`,
/// and each says what it is on.
struct DesignElement: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var kind: ElementKind
    /// The screen it is on, or nil on the open canvas.
    var parent: DesignScreen.ID?
    /// On the open canvas: how many canvas points each of its own points is drawn as, so
    /// that it keeps the proportions it would have on a screen drawn at that scale. Nil
    /// on a screen, which has a scale of its own.
    var scale: CGFloat?
    /// In its screen's own points, the same units the generated SwiftUI uses.
    var frame: CGRect
    /// How far it is turned about its centre, in degrees clockwise from 0 up to 360.
    /// Nil when upright. Set it with `setRotation`.
    var rotation: Double?
    var text: String
    /// The element's own colour: a button's or sticky note's fill, a symbol's ink.
    var tint: RGBColor
    /// For symbols: the SF Symbol's name.
    var symbol: String?
    /// For shapes: which one. A rectangle when unset.
    var shape: ShapeKind?
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
    /// The group it belongs to: a `.group` element on the same screen, or also on the open
    /// canvas. Nil when it is in none. Its lock and hide hold for it too; see
    /// `DesignContent.isLockedWithItsGroups(_:)`.
    var group: DesignElement.ID? = nil
    /// For toggles, checkboxes and radio buttons: whether it is drawn on. For shapes:
    /// whether it is filled with its colour, rather than outlined in it.
    var isOn = true
    /// For progress bars: how full, from 0 to 1. Half when unset.
    var value: Double?
    /// For buttons: filled when unset.
    var buttonLook: ButtonLook?
    /// For drawings: the ink, as PencilKit writes a drawing out, measured from the frame's
    /// top-left corner, so that moving the frame moves the ink and resizing it stretches
    /// the ink. Kept beside the design in its file rather than inside it: see `DesignFile`.
    var ink: Data?
    /// What a newer Layer saved with the element that this version doesn't know, to be
    /// written back with it.
    var unknownKeys = UnknownKeys()

    /// Everything about an element that is saved with the design. `ink` is saved apart.
    enum CodingKeys: String, CodingKey {
        case id, kind, parent, scale, frame, rotation, text, tint, symbol, shape, imageID
        case fontSize, fontWeight, textColor, cornerRadius, opacity, textAlignment, borderColor, borderWidth, hasShadow
        case name, isLocked, isHidden, group, isOn, value, buttonLook
    }

    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return kind.layerName }
        return name
    }
}

extension DesignElement {
    /// `current` with the properties that changed from `before` to `after` back as they
    /// were before, and the rest as they are now. With a property ever missing from the
    /// list below, the element as it was before, whole.
    static func reverting(_ current: DesignElement, after: DesignElement, to before: DesignElement) -> DesignElement {
        func reverted(_ current: DesignElement) -> DesignElement {
            var result = current
            func back<Value: Equatable>(_ property: WritableKeyPath<DesignElement, Value>) {
                if after[keyPath: property] != before[keyPath: property] { result[keyPath: property] = before[keyPath: property] }
            }
            back(\.id); back(\.kind); back(\.parent); back(\.scale); back(\.frame); back(\.rotation); back(\.text)
            back(\.tint); back(\.symbol); back(\.shape); back(\.imageID); back(\.fontSize); back(\.fontWeight)
            back(\.textColor); back(\.cornerRadius); back(\.opacity); back(\.textAlignment); back(\.borderColor)
            back(\.borderWidth); back(\.hasShadow); back(\.name); back(\.isLocked); back(\.isHidden); back(\.group)
            back(\.isOn); back(\.value); back(\.buttonLook); back(\.ink)
            return result
        }
        return reverted(after) == before ? reverted(current) : before
    }
}

extension DesignElement {
    /// Reads every property that is present, so elements saved before one existed still open.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ElementKind.self, forKey: .kind)
        parent = try container.decodeIfPresent(UUID.self, forKey: .parent)
        scale = try container.decodeIfPresent(CGFloat.self, forKey: .scale)
        frame = try container.decode(CGRect.self, forKey: .frame)
        // Kept as an angle set here is: from 0 up to 360, nothing when upright or not a number.
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation).flatMap(Rotation.kept)
        text = try container.decode(String.self, forKey: .text)
        tint = try container.decode(RGBColor.self, forKey: .tint)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        shape = try container.decodeIfPresent(ShapeKind.self, forKey: .shape)
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
        group = try container.decodeIfPresent(UUID.self, forKey: .group)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        buttonLook = try container.decodeIfPresent(ButtonLook.self, forKey: .buttonLook)
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
    }
}

extension DesignElement: KeepsUnknownKeys {}

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
///
/// A view of the design: the elements in its list that have no parent. See `DesignContent`.
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
    /// What kind of device it is, which decides the furniture drawn round its screen:
    /// a status bar on phones and tablets, a menu bar on a Mac.
    var family = Family.phone

    enum Family: String, CaseIterable, Sendable {
        case phone, tablet, desktop

        /// The heading devices of this family are listed under.
        var name: String {
            switch self {
            case .phone: "Phones"
            case .tablet: "Tablets"
            case .desktop: "Desktops"
            }
        }
    }

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
            safeTop: 24, safeBottom: 20, cornerRadius: 26, hasIsland: false, hasHomeIndicator: true, family: .tablet
        ),
        DeviceFrame(
            id: "ipad-mini", name: "iPad mini", size: CGSize(width: 744, height: 1133),
            safeTop: 24, safeBottom: 20, cornerRadius: 22, hasIsland: false, hasHomeIndicator: true, family: .tablet
        ),
        DeviceFrame(
            id: "ipad-pro-13", name: "iPad Pro 13″", size: CGSize(width: 1032, height: 1376),
            safeTop: 24, safeBottom: 20, cornerRadius: 30, hasIsland: false, hasHomeIndicator: true, family: .tablet
        ),
        // Macs: a window-sized screen under a menu bar. Their sizes are the default
        // "looks like" resolutions of each display.
        DeviceFrame(
            id: "macbook-air", name: "MacBook Air 13″", size: CGSize(width: 1470, height: 956),
            safeTop: 32, safeBottom: 0, cornerRadius: 10, hasIsland: false, hasHomeIndicator: false, family: .desktop
        ),
        DeviceFrame(
            id: "macbook-pro-16", name: "MacBook Pro 16″", size: CGSize(width: 1728, height: 1117),
            safeTop: 32, safeBottom: 0, cornerRadius: 10, hasIsland: false, hasHomeIndicator: false, family: .desktop
        ),
        DeviceFrame(
            id: "imac", name: "iMac 24″", size: CGSize(width: 2240, height: 1260),
            safeTop: 24, safeBottom: 0, cornerRadius: 6, hasIsland: false, hasHomeIndicator: false, family: .desktop
        ),
    ]

    static func named(_ id: String?) -> DeviceFrame {
        all.first { $0.id == id } ?? iPhone
    }
}

/// One device screen on the canvas. Elements live in the screen's logical points; `origin`
/// and `scale` say where and how large the screen is drawn on the canvas.
///
/// A design keeps its elements in one list, not screen by screen. A `DesignScreen` that
/// comes from a design is a view of it: the screen together with the elements in that
/// list that are on it. See `DesignContent`.
struct DesignScreen: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var name: String
    var origin: CGPoint
    var scale: CGFloat
    /// Which device this is; an iPhone when unset.
    var deviceID: String?
    /// What is on the screen. Later elements sit on top.
    var elements: [DesignElement] = []
    /// A locked screen can't be moved or deleted until it is unlocked. Its elements can
    /// still be edited.
    var isLocked: Bool?
    /// What a newer Layer saved with the screen that this version doesn't know, to be
    /// written back with it.
    var unknownKeys = UnknownKeys()

    var device: DeviceFrame { DeviceFrame.named(deviceID) }
    var size: CGSize { device.size }

    /// `current` with the properties that changed from `before` to `after` back as they
    /// were before, and the rest as they are now; see `DesignElement.reverting`.
    static func reverting(_ current: DesignScreen, after: DesignScreen, to before: DesignScreen) -> DesignScreen {
        func reverted(_ current: DesignScreen) -> DesignScreen {
            var result = current
            func back<Value: Equatable>(_ property: WritableKeyPath<DesignScreen, Value>) {
                if after[keyPath: property] != before[keyPath: property] { result[keyPath: property] = before[keyPath: property] }
            }
            back(\.id); back(\.name); back(\.origin); back(\.scale); back(\.deviceID); back(\.elements); back(\.isLocked)
            return result
        }
        return reverted(after) == before ? reverted(current) : before
    }
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

    /// "Screen 1" becomes `Screen1`, the name of the generated view and its file. A name
    /// that is one of the types the view's own code uses, or a Swift keyword, has "Screen"
    /// added: a view called `Image` hid SwiftUI's `Image` from its own body.
    var typeName: String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber }
        guard let first = cleaned.first, first.isLetter else { return "Screen" + cleaned }
        return Self.reservedTypeNames.contains(cleaned) ? cleaned + "Screen" : cleaned
    }

    /// The types generated code uses, and the keywords a name of letters alone can be.
    private static let reservedTypeNames: Set<String> = [
        "View", "Text", "Image", "Button", "Color", "Toggle", "Divider", "Path", "Spacer", "TextField", "ProgressView",
        "VStack", "HStack", "ZStack", "NavigationStack", "Rectangle", "RoundedRectangle", "Circle", "Capsule", "Ellipse",
        "StrokeStyle", "CGPoint", "CGSize", "CGFloat", "String", "Int", "Double", "Bool", "Optional", "SwiftUI",
        "Any", "Self", "Type", "Protocol", "Never",
        // SwiftUI and Foundation types a screen is often named for, which a view of the
        // name would hide throughout the target it is added to.
        "Menu", "List", "Form", "Label", "Group", "Section", "Link", "Picker", "Slider", "Stepper", "Grid", "Table",
        "Canvas", "Shape", "Font", "Gradient", "Animation", "Scene", "Window", "App", "Date", "Data", "URL", "Error",
        "as", "associatedtype", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do",
        "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import",
        "in", "init", "inout", "internal", "is", "let", "nil", "open", "operator", "private", "protocol", "public",
        "repeat", "rethrows", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw",
        "throws", "true", "try", "typealias", "var", "where", "while",
    ]
}

extension DesignScreen {
    enum CodingKeys: String, CodingKey {
        case id, name, origin, scale, deviceID, elements, isLocked
    }

    /// Reads a screen, with the elements it held when designs were saved screen by screen.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        origin = try container.decode(CGPoint.self, forKey: .origin)
        scale = try container.decode(CGFloat.self, forKey: .scale)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked)
        elements = container.contains(.elements) ? try DesignElement.readList(in: container, forKey: .elements).elements : []
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
    }

    /// A screen is saved without its elements, which are saved in the design's one list.
    func encode(to encoder: any Encoder) throws {
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(origin, forKey: .origin)
        try container.encode(scale, forKey: .scale)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(isLocked, forKey: .isLocked)
    }
}

/// An element that was read from a design but not understood, kept as it was read with
/// its place in the list, to be written back.
struct UnreadElement: Equatable, Sendable {
    var index: Int
    var json: JSONValue
}

extension DesignElement {
    /// Reads a list of elements one at a time, so that one this version can't read, of a
    /// kind added since for instance, doesn't stop the design from opening. Those come
    /// back as `unread`.
    static func readList<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> (elements: [DesignElement], unread: [UnreadElement]) {
        var list = try container.nestedUnkeyedContainer(forKey: key)
        var elements: [DesignElement] = []
        var unread: [UnreadElement] = []
        while !list.isAtEnd {
            let index = list.currentIndex
            // A failed read leaves the list where it was, so the same entry is read again as it is.
            if let element = try? list.decode(DesignElement.self) {
                elements.append(element)
            } else {
                unread.append(UnreadElement(index: index, json: try list.decode(JSONValue.self)))
            }
        }
        return (elements, unread)
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
    /// The model that reads this design's sketches and names it. Nil in designs saved
    /// before there was a choice, which use the app's default (`ModelPreferences`).
    var model: ModelChoice?
    /// What a newer Layer saved with the settings that this version doesn't know, to be
    /// written back with them.
    var unknownKeys = UnknownKeys()

    /// Everything about the settings that is saved with the design.
    enum CodingKeys: String, CodingKey {
        case showsGrid, gridStyle, gridSpacing, snapsToGuides, snapsToGrid, showsMeasurements, showsFrameNames
        case background, sketchDeviceID, code, model
    }

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
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
        // A choice this version can't read, from a newer Layer, is treated as no choice. It
        // is kept as it was read and written back, unless a model is chosen here meanwhile.
        do {
            model = try container.decodeIfPresent(ModelChoice.self, forKey: .model)
        } catch {
            model = nil
            unknownKeys[CodingKeys.model.stringValue] = try? container.decode(JSONValue.self, forKey: .model)
        }
    }

    /// The model this design uses: its own choice, or the app's default.
    var resolvedModel: ModelChoice { resolvedModel(defaultingTo: ModelPreferences.defaultChoice) }

    /// The model this design uses: its own choice, or `default`.
    func resolvedModel(defaultingTo default: ModelChoice) -> ModelChoice { model ?? `default` }
}

extension CanvasSettings: KeepsUnknownKeys {}

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
