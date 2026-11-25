import CoreGraphics
import Foundation

/// The kinds of thing that can sit on a screen or on the open canvas.
enum ElementKind: String, CaseIterable, Codable, Sendable {
    case title, body, image, button, textField, divider, symbol, text, stickyNote, toggle, avatar, checkbox, radio, progress
    /// A plain shape: a rectangle, a circle, a triangle, an arrow. See `ShapeKind`.
    case shape
    /// Ink kept as it was drawn: a sketch, a figure, an arrow, a handwritten note.
    case drawing
    /// A container: several things kept together as one, which it holds as its children. It is
    /// never drawn itself, and lays out what it holds when it has a layout (`LayerNode.Layout`).
    /// A free one's frame is the box round what it holds, which the tree's rules keep current.
    case group
    /// A container the design lays out: a rounded, filled box holding other nodes.
    case card

    // What each kind is called and how it behaves is in `Catalogue`; see `spec`.

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

/// A device a screen can be drawn as: its size in points and the furniture round its edges,
/// and the layout tokens its screens are laid out by.
struct DeviceFrame: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let name: String
    let size: CGSize
    /// The space the status bar and the home indicator keep clear.
    let safeTop: CGFloat
    let safeBottom: CGFloat
    var safeLeading: CGFloat
    var safeTrailing: CGFloat
    let cornerRadius: CGFloat
    /// Whether a status bar runs along the top: on phones, tablets and others by default.
    var hasStatusBar: Bool
    let hasIsland: Bool
    let hasHomeIndicator: Bool
    /// What kind of device it is, which decides the furniture drawn round its screen:
    /// a status bar on phones and tablets, a menu bar on a Mac.
    var family: Family
    /// A token: the space kept round a screen's column, beyond the safe areas.
    var margin: CGFloat
    /// A token: the widest a screen's column runs, centred. Nil is as wide as the screen.
    var maxContentWidth: CGFloat?
    /// What a newer Layer saved with a custom frame that this version doesn't know.
    var unknownKeys = UnknownKeys()

    enum Family: String, CaseIterable, Sendable, Codable {
        case phone, tablet, desktop, watch, other

        /// The heading devices of this family are listed under.
        var name: String {
            switch self {
            case .phone: "Phones"
            case .tablet: "Tablets"
            case .desktop: "Desktops"
            case .watch: "Watches"
            case .other: "Other"
            }
        }

        /// The margin a device of this family has unless it is given one.
        var defaultMargin: CGFloat {
            switch self {
            case .phone: 20
            case .tablet: 32
            case .desktop: 48
            case .watch: 8
            case .other: 20
            }
        }

        /// The widest column on a device of this family unless it is given a limit.
        var defaultMaxContentWidth: CGFloat? { self == .desktop ? 1080 : nil }

        /// Whether devices of this family have a status bar unless it is said they don't.
        var defaultHasStatusBar: Bool { self != .desktop && self != .watch }
    }

    /// The parameters the built-in table has always had, with the rest from the family.
    init(id: String, name: String, size: CGSize, safeTop: CGFloat, safeBottom: CGFloat, cornerRadius: CGFloat,
         hasIsland: Bool, hasHomeIndicator: Bool, family: Family = .phone,
         safeLeading: CGFloat = 0, safeTrailing: CGFloat = 0, hasStatusBar: Bool? = nil,
         margin: CGFloat? = nil, maxContentWidth: CGFloat? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.safeTop = safeTop
        self.safeBottom = safeBottom
        self.safeLeading = safeLeading
        self.safeTrailing = safeTrailing
        self.cornerRadius = cornerRadius
        self.hasStatusBar = hasStatusBar ?? family.defaultHasStatusBar
        self.hasIsland = hasIsland
        self.hasHomeIndicator = hasHomeIndicator
        self.family = family
        self.margin = margin ?? family.defaultMargin
        self.maxContentWidth = maxContentWidth ?? family.defaultMaxContentWidth
    }

    /// The prefix of every custom frame's id, which no built-in has.
    static let customPrefix = "custom-"

    var isCustom: Bool { id.hasPrefix(Self.customPrefix) }

    /// A plain frame of the family with the size given, to be adjusted.
    static func custom(name: String, size: CGSize, family: Family) -> DeviceFrame {
        DeviceFrame(id: customPrefix + UUID().uuidString, name: name, size: size, safeTop: 0, safeBottom: 0,
                    cornerRadius: 0, hasIsland: false, hasHomeIndicator: false, family: family)
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

    /// The built-in with the id, or the iPhone.
    static func named(_ id: String?) -> DeviceFrame {
        all.first { $0.id == id } ?? iPhone
    }

    /// The built-in with the id, else the custom frame, else the iPhone.
    static func named(_ id: String?, among custom: [DeviceFrame]) -> DeviceFrame {
        all.first { $0.id == id } ?? custom.first { $0.id == id } ?? iPhone
    }
}

extension DeviceFrame {
    enum CodingKeys: String, CodingKey {
        case id, name, size, safeTop, safeBottom, safeLeading, safeTrailing, cornerRadius, hasStatusBar
        case hasIsland, hasHomeIndicator, family, margin, maxContentWidth
    }

    /// Reads a custom frame leniently: insets that aren't finite or are negative are 0, a
    /// margin that isn't is the family's, a widest column of 0 or less is none, and a family
    /// this version doesn't know is `.other`. A size that isn't finite and positive throws.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let size = try container.decode(CGSize.self, forKey: .size)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .size, in: container,
                                                   debugDescription: "A device's sides are finite and positive.")
        }
        func inset(_ key: CodingKeys) throws -> CGFloat {
            let value = try container.decodeIfPresent(CGFloat.self, forKey: key) ?? 0
            return value.isFinite && value >= 0 ? value : 0
        }
        let family = (try container.decodeIfPresent(String.self, forKey: .family)).map { Family(rawValue: $0) ?? .other } ?? .phone
        let margin = try container.decodeIfPresent(CGFloat.self, forKey: .margin)
        var maxContentWidth = family.defaultMaxContentWidth
        if container.contains(.maxContentWidth) {
            let value = try container.decodeIfPresent(CGFloat.self, forKey: .maxContentWidth)
            maxContentWidth = value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        self.init(id: try container.decode(String.self, forKey: .id),
                  name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Custom",
                  size: size, safeTop: try inset(.safeTop), safeBottom: try inset(.safeBottom),
                  cornerRadius: try inset(.cornerRadius),
                  hasIsland: try container.decodeIfPresent(Bool.self, forKey: .hasIsland) ?? false,
                  hasHomeIndicator: try container.decodeIfPresent(Bool.self, forKey: .hasHomeIndicator) ?? false,
                  family: family, safeLeading: try inset(.safeLeading), safeTrailing: try inset(.safeTrailing),
                  hasStatusBar: try container.decodeIfPresent(Bool.self, forKey: .hasStatusBar),
                  margin: margin.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        self.maxContentWidth = maxContentWidth
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(size, forKey: .size)
        try container.encode(safeTop, forKey: .safeTop)
        try container.encode(safeBottom, forKey: .safeBottom)
        try container.encode(safeLeading, forKey: .safeLeading)
        try container.encode(safeTrailing, forKey: .safeTrailing)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(hasStatusBar, forKey: .hasStatusBar)
        try container.encode(hasIsland, forKey: .hasIsland)
        try container.encode(hasHomeIndicator, forKey: .hasHomeIndicator)
        try container.encode(family, forKey: .family)
        try container.encode(margin, forKey: .margin)
        // Written as null when there is none, so that a desktop's missing limit isn't read as 1080.
        if let maxContentWidth {
            try container.encode(maxContentWidth, forKey: .maxContentWidth)
        } else {
            try container.encodeNil(forKey: .maxContentWidth)
        }
    }
}

extension TreeScreen {
    /// "Screen 1" becomes `Screen1`, the name of the generated view and its file. A name that is one of the types the
    /// view's own code uses, or a Swift keyword, has "Screen" added: a view called `Image` hid SwiftUI's `Image` from its
    /// own body.
    static func typeName(forScreenNamed name: String) -> String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber }
        guard let first = cleaned.first, first.isLetter else { return "Screen" + cleaned }
        return reservedTypeNames.contains(cleaned) ? cleaned + "Screen" : cleaned
    }

    /// The types generated code uses, and the keywords a name of letters alone can be.
    private static let reservedTypeNames: Set<String> = [
        "View", "Text", "Image", "Button", "Color", "Toggle", "Divider", "Path", "Spacer", "TextField", "ProgressView",
        "VStack", "HStack", "ZStack", "NavigationStack", "Rectangle", "RoundedRectangle", "Circle", "Capsule", "Ellipse",
        "StrokeStyle", "CGPoint", "CGSize", "CGFloat", "String", "Int", "Double", "Bool", "Optional", "SwiftUI",
        "Any", "Self", "Type", "Protocol", "Never",
        // A laid-out screen's code uses a grid's rows and the design's tokens (F21).
        "GridRow", "DesignTokens",
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
    /// The device frames this design adds to the built-in ones.
    var customDevices: [DeviceFrame] = []
    /// Custom frames this build can't read, as they were read, written back after the others.
    var unreadDevices: [JSONValue] = []
    /// The numbers this design is laid out and styled by. The standard ones when unset.
    var tokens = DesignTokens.standard
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
        case background, sketchDeviceID, code, model, customDevices, tokens
    }

    static let paper = RGBColor(hex: 0xF4F3EC)
    /// Canvas colours offered as swatches beside the colour well.
    static let backgrounds: [RGBColor] = [paper, RGBColor(hex: 0xFFFFFF), RGBColor(hex: 0xECEFF3), RGBColor(hex: 0xEFF3EA), RGBColor(hex: 0x2A2A2E)]

    var resolvedBackground: RGBColor { background ?? Self.paper }
    var sketchDevice: DeviceFrame { device(named: sketchDeviceID) }

    /// The device with the id: a built-in, or one of this design's own, or the iPhone.
    func device(named id: String?) -> DeviceFrame { DeviceFrame.named(id, among: customDevices) }

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
        tokens = ((try? container.decodeIfPresent(DesignTokens.self, forKey: .tokens)) ?? nil) ?? .standard
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
        (customDevices, unreadDevices) = Self.readDevices(in: container)
        // A choice this version can't read, from a newer Layer, is treated as no choice. It
        // is kept as it was read and written back, unless a model is chosen here meanwhile.
        do {
            model = try container.decodeIfPresent(ModelChoice.self, forKey: .model)
        } catch {
            model = nil
            unknownKeys[CodingKeys.model.stringValue] = try? container.decode(JSONValue.self, forKey: .model)
        }
    }

    /// Writes the settings with the keys this version doesn't know, as `TreeContent` writes them
    /// unwrapped. The tokens and a list of custom frames are left out when there are none to keep.
    func encode(to encoder: any Encoder) throws {
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showsGrid, forKey: .showsGrid)
        try container.encode(gridStyle, forKey: .gridStyle)
        try container.encode(gridSpacing, forKey: .gridSpacing)
        try container.encode(snapsToGuides, forKey: .snapsToGuides)
        try container.encode(snapsToGrid, forKey: .snapsToGrid)
        try container.encode(showsMeasurements, forKey: .showsMeasurements)
        try container.encode(showsFrameNames, forKey: .showsFrameNames)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(sketchDeviceID, forKey: .sketchDeviceID)
        try container.encode(code, forKey: .code)
        try container.encodeIfPresent(model, forKey: .model)
        if tokens != .standard { try container.encode(tokens, forKey: .tokens) }
        if !customDevices.isEmpty || !unreadDevices.isEmpty {
            var list = container.nestedUnkeyedContainer(forKey: .customDevices)
            for device in customDevices { try list.encode(device) }
            for json in unreadDevices { try list.encode(json) }
        }
    }

    /// The custom frames in the list, one at a time. Those that can't be used come back as
    /// they were read: an id that isn't `custom-` or is a built-in's or an earlier one's, or
    /// a size that isn't finite and positive.
    private static func readDevices(in container: KeyedDecodingContainer<CodingKeys>) -> ([DeviceFrame], [JSONValue]) {
        guard let list = try? container.decodeIfPresent([JSONValue].self, forKey: .customDevices) else { return ([], []) }
        var frames: [DeviceFrame] = [], unread: [JSONValue] = []
        let builtIn = Set(DeviceFrame.all.map(\.id))
        for json in list {
            guard let data = try? JSONEncoder().encode(json), let frame = try? JSONDecoder().decode(DeviceFrame.self, from: data),
                  frame.isCustom, !builtIn.contains(frame.id), !frames.contains(where: { $0.id == frame.id })
            else {
                unread.append(json)
                continue
            }
            frames.append(frame)
        }
        return (frames, unread)
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
        /// The screen as its tree is built: rows, columns, grids, overlays and cards as stacks, and
        /// what is placed freely read in reading order, the gaps as padding, as a person writes it.
        case structure
        /// Every element at its exact place on the screen: faithful to the canvas.
        case absolute

        var name: String {
            switch self {
            case .structure: "Structure"
            case .absolute: "Exact Positions"
            }
        }

        /// "stack", which this was called before it followed the tree, reads as `.structure`.
        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            if value == "stack" {
                self = .structure
            } else if let layout = Layout(rawValue: value) {
                self = layout
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Cannot initialize Layout from invalid String value \(value)"))
            }
        }
    }

    var layout = Layout.structure
    /// Whether each file ends with a `#Preview`.
    var includesPreview = true
    /// Whether the screen's title becomes its navigation title inside a `NavigationStack`.
    var usesNavigationTitle = false
}

extension CodeSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? .structure
        includesPreview = try container.decodeIfPresent(Bool.self, forKey: .includesPreview) ?? true
        usesNavigationTitle = try container.decodeIfPresent(Bool.self, forKey: .usesNavigationTitle) ?? false
    }
}
