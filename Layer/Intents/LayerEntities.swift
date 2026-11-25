@_weakLinked import AppIntents
import CoreSpotlight
import Foundation

// MARK: Errors

enum LayerIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noOpenDesign
    case designNotFound
    case screenNotFound
    case elementNotFound
    case couldNotOpen
    case locked
    case nothingToExport
    case invalidColour(String)
    /// Build Screen's outline had nothing in it to build.
    case invalidScreenDescription
    /// Building, adding or copying it would take the design past what a design holds: 5,000 things, nested at most 32
    /// deep. Said after Build Screen, Add Screen, Add Element, Duplicate Element and Duplicate Screen alike.
    case designTooLarge
    case imagePlaygroundUnavailable
    case notAnImage
    case canvasNotReady
    case invalidStrokes(String)
    case cantGoOnScreens
    case drawingsAreDrawn
    case drawingsStayOnTop
    /// Arranging it would change nothing: it is already at the front, or the back, of what it
    /// is arranged among, which for a member of a group is the others in its group.
    case cantGoFurther(withinGroup: Bool)
    case invalidImage
    /// What a row, column or grid places, or for Align an overlay too, isn't moved or arranged on its own (spec §10).
    case laidOut
    /// No device of the design's own has the name given.
    case deviceNotFound(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noOpenDesign: "No design is open in Layer. Open one first, or say which design to use."
        case .designNotFound: "Layer couldn't find that design. It may have been moved, renamed or deleted."
        case .screenNotFound: "Layer couldn't find that screen."
        case .elementNotFound: "Layer couldn't find that element."
        case .couldNotOpen: "Layer couldn't open the design in time. Try again once Layer is on screen."
        case .locked: "That's locked. Unlock it in Layer first."
        case .nothingToExport: "There's nothing on that design to export yet."
        case .invalidColour(let text): "“\(text)” isn't a colour Layer knows. Use a name such as blue, or a hex code such as #0A84FF."
        case .invalidScreenDescription: "Layer couldn't read that screen description. Write one element per line, such as “title: Welcome back”."
        case .designTooLarge: "That would make the design larger than Layer keeps: more than \(TreeRules.maximumNodes.formatted()) things, or nested more than \(TreeRules.maximumDepth) deep. Nothing was changed."
        case .imagePlaygroundUnavailable: "Image Playground isn't available. It needs Apple Intelligence turned on in Settings, and its models downloaded."
        case .notAnImage: "That element isn't an image. Choose an image element, or leave it out to add a new image."
        case .canvasNotReady: "The design's canvas isn't on screen yet. Try again once Layer is showing it."
        case .invalidStrokes(let reason): "Layer couldn't read those strokes. \(reason)"
        case .cantGoOnScreens: "Sticky notes and drawings stay on the open canvas; they can't go on a screen."
        case .drawingsAreDrawn: "A drawing is made by drawing it. Draw strokes on the canvas instead of adding an element."
        case .drawingsStayOnTop: "Drawings stay on top of everything else, so they can't be brought forward or sent back."
        case .cantGoFurther(withinGroup: true): "That element can't go any further that way within its group. To move it past things outside the group, ungroup it first, or arrange the group."
        case .cantGoFurther(withinGroup: false): "That element can't go any further that way."
        case .invalidImage: "Layer couldn't read that file as a picture."
        case .laidOut: "That element's place comes from the row, column or grid it's in. Change its order in the Layers panel, or move it out of the container first."
        case .deviceNotFound(let name): "This design has no device called “\(name)”. Make one with Custom Size… in the device picker."
        }
    }
}

// MARK: Identifiers

/// Entity identifiers carry the design they belong to, so an element can be found again
/// whether or not its design is open.
enum EntityKey {
    static let separator: Character = "|"

    static func screen(design: String, screen: UUID) -> String {
        "\(design)\(separator)\(screen.uuidString)"
    }

    static func element(design: String, host: DesignStore.ElementRef.Host, element: UUID) -> String {
        let hostKey = switch host {
        case .screen(let id): id.uuidString
        case .canvas: "canvas"
        }
        return "\(design)\(separator)\(hostKey)\(separator)\(element.uuidString)"
    }

    static func parseScreen(_ id: String) -> (design: String, screen: UUID)? {
        guard let split = id.lastIndex(of: separator), let screen = UUID(uuidString: String(id[id.index(after: split)...])) else { return nil }
        return (String(id[..<split]), screen)
    }

    static func parseElement(_ id: String) -> (design: String, ref: DesignStore.ElementRef)? {
        let parts = id.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 3, let element = UUID(uuidString: String(parts[parts.count - 1])) else { return nil }
        let hostKey = String(parts[parts.count - 2])
        let host: DesignStore.ElementRef.Host
        if hostKey == "canvas" {
            host = .canvas
        } else if let screen = UUID(uuidString: hostKey) {
            host = .screen(screen)
        } else {
            return nil
        }
        let design = parts.dropLast(2).joined(separator: String(separator))
        return (design, DesignStore.ElementRef(host: host, element: element))
    }
}

// MARK: Design

/// A Layer design: one `.layer` file holding device screens, loose elements and ink.
struct DesignEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Layer Design",
        numericFormat: "\(placeholder: .int) designs"
    )
    static let defaultQuery = DesignQuery()

    let id: String

    @Property(title: "Name", indexingKey: \.title)
    var name: String

    @Property(title: "Screens")
    var screenCount: Int

    @Property(title: "Screen Names", indexingKey: \.keywords)
    var screenNames: [String]

    @Property(title: "Last Modified")
    var modified: Date?

    init(summary: DesignSummary) {
        id = summary.id
        name = summary.title
        screenCount = summary.content.screens.count
        screenNames = summary.content.screens.map(\.name)
        modified = summary.modified
    }

    init(id: String, content: TreeContent, fallbackName: String, modified: Date? = nil) {
        self.id = id
        name = content.title ?? fallbackName
        screenCount = content.screens.count
        screenNames = content.screens.map(\.name)
        self.modified = modified
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: screenCount == 1 ? "1 screen" : "\(screenCount) screens",
            image: .init(systemName: "square.on.square.dashed")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = screenNames.isEmpty ? "A Layer design" : "Screens: \(screenNames.joined(separator: ", "))"
        attributes.contentModificationDate = modified
        return attributes
    }
}

// MARK: Screen

/// One device screen in a design, such as an iPhone screen called Login.
struct ScreenEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Layer Screen",
        numericFormat: "\(placeholder: .int) screens"
    )
    static let defaultQuery = ScreenQuery()

    let id: String

    @Property(title: "Name", indexingKey: \.title)
    var name: String

    @Property(title: "Device")
    var device: DeviceChoice

    /// The name of the design's own device for a screen on one, else the built-in's name as Siri and Shortcuts show it
    /// ("Phone", "Tablet"…), never the built-in's own name, which is a trademark (F23).
    @Property(title: "Device Name")
    var deviceName: String

    @Property(title: "Design")
    var designName: String

    @Property(title: "Elements")
    var elementCount: Int

    /// What is on the screen, top to bottom, for Spotlight and for describing it.
    @Property(title: "Contents", indexingKey: \.contentDescription)
    var summary: String

    var designID: String { EntityKey.parseScreen(id)?.design ?? "" }
    var screenID: UUID? { EntityKey.parseScreen(id)?.screen }

    /// A screen of a design whose canvas is set up as `settings` says, which hold the design's own devices. Its elements
    /// are its leaves (My call 9).
    init(design: String, designName: String, screen: TreeScreen, settings: CanvasSettings) {
        let frame = settings.device(named: screen.deviceID)
        id = EntityKey.screen(design: design, screen: screen.id)
        name = screen.name
        device = DeviceChoice(frame)
        deviceName = DeviceChoice.displayName(of: frame)
        self.designName = designName
        elementCount = screen.root.leaves.count
        summary = DesignDescriber.summary(of: screen, on: frame)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(deviceName) · \(designName)",
            image: .init(systemName: device == .iPad ? "ipad" : "iphone")
        )
    }
}

/// The design's own devices, by name, for a Custom Device parameter (call 6): Shortcuts offers them, and any name can
/// still be typed, which `DesignActions.device(_:custom:in:)` looks up.
struct CustomDeviceOptions: DynamicOptionsProvider {
    /// `names(in:)` of the design at the front, or none when no design is open.
    func results() async throws -> [String] {
        await MainActor.run { OpenDesigns.shared.current.map(Self.names(in:)) ?? [] }
    }

    /// The design's own devices' names, in the order they were made. What tests call, with the model (F17).
    @MainActor static func names(in model: AppModel) -> [String] {
        model.store.tree.settings.customDevices.map(\.name)
    }
}

// MARK: Element

/// One element: a title, body text, button, text field, image, symbol, divider, toggle,
/// avatar, piece of text or sticky note, on a screen or on the open canvas.
struct ElementEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Layer Element",
        numericFormat: "\(placeholder: .int) elements"
    )
    static let defaultQuery = ElementQuery()

    let id: String

    @Property(title: "Kind")
    var kind: ElementKindChoice

    @Property(title: "Text")
    var text: String

    @Property(title: "Name")
    var name: String

    /// The screen it sits on, or “Canvas” for elements outside every screen.
    @Property(title: "Screen")
    var screenName: String

    @Property(title: "Colour")
    var colourHex: String

    @Property(title: "Hidden")
    var isHidden: Bool

    @Property(title: "Locked")
    var isLocked: Bool

    var designID: String { EntityKey.parseElement(id)?.design ?? "" }
    var ref: DesignStore.ElementRef? { EntityKey.parseElement(id)?.ref }

    /// A leaf on `host`, called `hostName`, locked or hidden as `isLocked` and `isHidden` say: with the containers
    /// above it, as the design's index has it.
    init(design: String, host: TreeIndex.Host, hostName: String, node: LayerNode, isLocked: Bool, isHidden: Bool) {
        // Until plan 6's Task 11 renames the ref, the index's host and a ref's are two enums of one shape, converted
        // here alone (F29).
        id = EntityKey.element(design: design, host: DesignStore.ElementRef.Host(host), element: node.id)
        kind = ElementKindChoice(node.kind)
        text = node.content.text
        name = node.name ?? node.kind.layerName
        screenName = hostName
        colourHex = node.resolvedTint.hex
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    var displayRepresentation: DisplayRepresentation {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return DisplayRepresentation(
            title: words.isEmpty ? "\(name)" : "\(kind.name): \(words)",
            subtitle: "\(screenName)",
            image: .init(systemName: kind.element.symbol)
        )
    }
}

// MARK: Enums

enum ElementKindChoice: String, AppEnum {
    case title, body, button, textField, image, symbol, divider, text, toggle, avatar, stickyNote, checkbox, radio, progress, shape, drawing

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Element Kind"
    static let caseDisplayRepresentations: [ElementKindChoice: DisplayRepresentation] = [
        .title: "Title",
        .body: "Body Text",
        .button: "Button",
        .textField: "Text Field",
        .image: "Image",
        .symbol: "Symbol",
        .divider: "Divider",
        .text: "Text",
        .toggle: "Toggle",
        .avatar: "Avatar",
        .stickyNote: "Sticky Note",
        .checkbox: "Checkbox",
        .radio: "Radio Button",
        .progress: "Progress Bar",
        .shape: "Shape",
        .drawing: "Drawing",
    ]

    init(_ kind: ElementKind) {
        self = ElementKindChoice(rawValue: kind.rawValue) ?? .text
    }

    var element: ElementKind { ElementKind(rawValue: rawValue) ?? .text }
    var name: String { element.layerName }
}

enum DeviceChoice: String, AppEnum {
    case iPhone = "iphone"
    case iPhoneProMax = "iphone-pro-max"
    case iPhoneSE = "iphone-se"
    case iPad = "ipad"
    case iPadMini = "ipad-mini"
    case iPadPro13 = "ipad-pro-13"
    case macBookAir = "macbook-air"
    case macBookPro16 = "macbook-pro-16"
    case iMac = "imac"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let caseDisplayRepresentations: [DeviceChoice: DisplayRepresentation] = [
        // App Store Connect rejects Apple trademarks (iPhone, iPad, Siri…) in App Intent
        // metadata (ITMS-90626), so Siri and Shortcuts see generic device names.
        .iPhone: "Phone",
        .iPhoneProMax: "Large phone",
        .iPhoneSE: "Small phone",
        .iPad: "Tablet",
        .iPadMini: "Small tablet",
        .iPadPro13: "Large tablet",
        .macBookAir: "Laptop",
        .macBookPro16: "Large laptop",
        .iMac: "Desktop",
    ]

    init(_ device: DeviceFrame) {
        self = DeviceChoice(rawValue: device.id) ?? .iPhone
    }

    var frame: DeviceFrame { DeviceFrame.named(rawValue) }
    var name: String { frame.name }

    /// What Siri and Shortcuts call it ("Phone", "Tablet"…): its display representation's title, which names no
    /// trademark, where `name` does.
    var displayName: String {
        Self.caseDisplayRepresentations[self].map { String(localized: $0.title) } ?? rawValue
    }

    /// What Siri and Shortcuts call a device: one of the design's own by its name, a built-in by its `displayName`
    /// (F23). A screen's entity and Get Design Layout both say it.
    static func displayName(of device: DeviceFrame) -> String {
        DeviceChoice(rawValue: device.id)?.displayName ?? device.name
    }
}

enum FontWeightOption: String, AppEnum {
    case regular, medium, semibold, bold

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Font Weight"
    static let caseDisplayRepresentations: [FontWeightOption: DisplayRepresentation] = [
        .regular: "Regular", .medium: "Medium", .semibold: "Semibold", .bold: "Bold",
    ]

    var choice: FontWeightChoice { FontWeightChoice(rawValue: rawValue) ?? .regular }
}

enum TextAlignmentOption: String, AppEnum {
    case leading, center, trailing

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Text Alignment"
    static let caseDisplayRepresentations: [TextAlignmentOption: DisplayRepresentation] = [
        .leading: "Left", .center: "Centre", .trailing: "Right",
    ]

    var choice: TextAlignmentChoice { TextAlignmentChoice(rawValue: rawValue) ?? .leading }
}

enum AlignmentOption: String, AppEnum {
    case left, center, right, top, middle, bottom

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Alignment on Screen"
    static let caseDisplayRepresentations: [AlignmentOption: DisplayRepresentation] = [
        .left: "Left Edge", .center: "Horizontal Centre", .right: "Right Edge",
        .top: "Top Edge", .middle: "Vertical Middle", .bottom: "Bottom Edge",
    ]

    var alignment: ElementLayout.Alignment {
        switch self {
        case .left: .left
        case .center: .centerX
        case .right: .right
        case .top: .top
        case .middle: .centerY
        case .bottom: .bottom
        }
    }
}

enum ArrangementOption: String, AppEnum {
    case front, forward, backward, back

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Layer Order"
    static let caseDisplayRepresentations: [ArrangementOption: DisplayRepresentation] = [
        .front: "Bring to Front", .forward: "Bring Forward", .backward: "Send Backward", .back: "Send to Back",
    ]

    var arrangement: DesignStore.Arrangement {
        switch self {
        case .front: .front
        case .forward: .forward
        case .backward: .backward
        case .back: .back
        }
    }
}

enum GridStyleOption: String, AppEnum {
    case dots, lines

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Grid Style"
    static let caseDisplayRepresentations: [GridStyleOption: DisplayRepresentation] = [.dots: "Dots", .lines: "Lines"]

    var style: CanvasSettings.GridStyle { CanvasSettings.GridStyle(rawValue: rawValue) ?? .dots }
}

/// Colours people name out loud. A hex code can be given instead wherever a colour is asked for.
enum ColourOption: String, AppEnum {
    case accent, black, white, gray, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour"
    static let caseDisplayRepresentations: [ColourOption: DisplayRepresentation] = [
        .accent: "Layer Orange", .black: "Black", .white: "White", .gray: "Grey", .red: "Red",
        .orange: "Orange", .yellow: "Yellow", .green: "Green", .mint: "Mint", .teal: "Teal",
        .blue: "Blue", .indigo: "Indigo", .purple: "Purple", .pink: "Pink", .brown: "Brown",
    ]

    var colour: RGBColor { ColourWords.named[rawValue] ?? Theme.accent }

    /// The colour a named option or a hex code gives, the named option winning. Throws when
    /// the hex code isn't one.
    static func resolve(_ option: ColourOption?, hex: String?) throws -> RGBColor? {
        if let option { return option.colour }
        guard let hex, !hex.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let colour = ColourWords.parse(hex) else { throw LayerIntentError.invalidColour(hex) }
        return colour
    }
}

enum ButtonLookOption: String, AppEnum {
    case filled, bordered, plain

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Button Style"
    static let caseDisplayRepresentations: [ButtonLookOption: DisplayRepresentation] = [
        .filled: "Filled", .bordered: "Outlined", .plain: "Plain Text",
    ]

    var look: ButtonLook { ButtonLook(rawValue: rawValue) ?? .filled }
}

enum CodeLayoutOption: String, AppEnum {
    /// Keeps the raw value it had when the layout was called Stack, so that saved Shortcuts still work.
    case stack, absolute

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Code Layout"
    static let caseDisplayRepresentations: [CodeLayoutOption: DisplayRepresentation] = [
        .stack: "Structure", .absolute: "Exact Positions",
    ]

    var layout: CodeSettings.Layout {
        switch self {
        case .stack: .structure
        case .absolute: .absolute
        }
    }

    /// The option a code layout is chosen by, which Get Design Layout writes, so that a shortcut can hand it back as it
    /// was given: "stack" for the structure, as before the layout was renamed.
    init(_ layout: CodeSettings.Layout) {
        self = switch layout {
        case .structure: .stack
        case .absolute: .absolute
        }
    }
}

/// What strokes are drawn with: the Magic Pen, whose sketches become elements, or one of
/// PencilKit's pens, whose ink stays as drawn.
enum InkPenOption: String, AppEnum {
    case magicPen, pen, monoline, marker, pencil

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pen"
    static let caseDisplayRepresentations: [InkPenOption: DisplayRepresentation] = [
        .magicPen: "Magic Pen", .pen: "Pen", .monoline: "Monoline", .marker: "Marker", .pencil: "Pencil",
    ]
}

/// Which points stroke coordinates are given in.
enum StrokeSpaceOption: String, AppEnum {
    case screen, canvas

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Coordinates"
    static let caseDisplayRepresentations: [StrokeSpaceOption: DisplayRepresentation] = [
        .screen: "Screen Points", .canvas: "Canvas Points",
    ]
}
