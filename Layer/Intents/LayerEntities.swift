import AppIntents
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
    case invalidBlueprint
    case imagePlaygroundUnavailable
    case notAnImage

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
        case .invalidBlueprint: "Layer couldn't read that screen description. Write one element per line, such as “title: Welcome back”."
        case .imagePlaygroundUnavailable: "Image Playground isn't available. It needs Apple Intelligence turned on in Settings, and its models downloaded."
        case .notAnImage: "That element isn't an image. Choose an image element, or leave it out to add a new image."
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

    init(id: String, content: DesignContent, fallbackName: String, modified: Date? = nil) {
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

    @Property(title: "Design")
    var designName: String

    @Property(title: "Elements")
    var elementCount: Int

    /// What is on the screen, top to bottom, for Spotlight and for describing it.
    @Property(title: "Contents", indexingKey: \.contentDescription)
    var summary: String

    var designID: String { EntityKey.parseScreen(id)?.design ?? "" }
    var screenID: UUID? { EntityKey.parseScreen(id)?.screen }

    init(design: String, designName: String, screen: DesignScreen) {
        id = EntityKey.screen(design: design, screen: screen.id)
        name = screen.name
        device = DeviceChoice(screen.device)
        self.designName = designName
        elementCount = screen.elements.count
        summary = DesignDescriber.summary(of: screen)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(device.name) · \(designName)",
            image: .init(systemName: device == .iPad ? "ipad" : "iphone")
        )
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

    init(design: String, host: DesignStore.ElementRef.Host, hostName: String, element: DesignElement) {
        id = EntityKey.element(design: design, host: host, element: element.id)
        kind = ElementKindChoice(element.kind)
        text = element.text
        name = element.name ?? element.kind.layerName
        screenName = hostName
        colourHex = element.tint.hex
        isHidden = element.isHidden
        isLocked = element.isLocked
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
    case title, body, button, textField, image, symbol, divider, text, toggle, avatar, stickyNote

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

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let caseDisplayRepresentations: [DeviceChoice: DisplayRepresentation] = [
        .iPhone: "iPhone",
        .iPhoneProMax: "iPhone Pro Max",
        .iPhoneSE: "iPhone SE",
        .iPad: "iPad",
    ]

    init(_ device: DeviceFrame) {
        self = DeviceChoice(rawValue: device.id) ?? .iPhone
    }

    var frame: DeviceFrame { DeviceFrame.named(rawValue) }
    var name: String { frame.name }
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
