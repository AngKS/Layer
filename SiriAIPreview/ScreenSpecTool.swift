// NOT BUILT. Staged for the Siri AI Developer Preview SDK, which Xcode 27.2 doesn't
// include: it has no `.tool` trait, `ToolIntent`, `GenerableEntity` or `@AppEntity(.generable)`.
// Written against Apple's preview documentation and never compiled. Move it into
// Layer/Intents/ once a preview SDK is installed, and fix what the compiler says.

import AppIntents

/// One element of a screen Siri describes, filled straight from what the person said.
@available(iOS 27, *)
@AppEntity(.generable)
struct ElementSpec: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Element Spec"

    @Property(title: "Kind", description: "Title, body text, button, text field, image, symbol, divider, toggle, avatar or text.")
    var kind: ElementKindChoice

    @Property(title: "Text", description: "The words shown, or a text field's placeholder. Empty for images and dividers.")
    var text: String

    @Property(title: "Symbol", description: "For symbols only: an SF Symbol name such as star.fill.")
    var symbol: String?

    @Property(title: "Fills Width", description: "True to stretch across the section, false to hug the content. Buttons and fields fill by default.")
    var fillsWidth: Bool?

    @Property(title: "Colour", description: "Fill colour as a name (blue) or a hex code (#0A84FF). The kind's usual colour if unsaid.")
    var colour: String?

    @Property(title: "Weight", description: "Regular, medium, semibold or bold.")
    var weight: FontWeightOption?

    // No size, radius or spacing: a model fills this spec, and no model picks a number (spec §14). The design's
    // tokens give them.

    var displayRepresentation: DisplayRepresentation { "\(text)" }
    init() {}

    /// This element as one line of the outline `BuildScreenIntent` reads: `kind: words [look]`.
    var line: String {
        let name = kind.element.spec.writtenNames.first ?? "text"
        let words = kind == .symbol ? (symbol ?? "star") : text
        var look: [String] = []
        if let fillsWidth { look.append(fillsWidth ? "fill" : "fit") }
        if let colour, ColourWords.parse(colour) != nil { look.append(colour) }
        if let weight { look.append(weight.choice.rawValue) }
        let written = "\(name): \(Self.written(words))"
        return look.isEmpty ? written : "\(written) [\(look.joined(separator: ", "))]"
    }

    /// Words as the outline reads them: on one line, with no `;` or `|`, which it reads as a new line and a row's
    /// split, and no square brackets, which hold a look.
    private static func written(_ words: String) -> String {
        words.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }
}

/// A part of a screen: a column or a row of elements.
@available(iOS 27, *)
@AppEntity(.generable)
struct SectionSpec: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen Section"

    @Property(title: "Side by Side", description: "True to put the elements in one row, false to stack them top to bottom.")
    var isRow: Bool

    @Property(title: "Elements", description: "The section's elements in reading order.")
    var elements: [ElementSpec]

    var displayRepresentation: DisplayRepresentation { "\(elements.count) elements" }
    init() {}
}

/// A whole screen, written by Siri from a description such as “a login screen with
/// email, password and a Sign in button”. Built by the same code as `BuildScreenIntent`, from its outline.
@available(iOS 27, *)
@AppEntity(.generable)
struct ScreenSpec: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen Spec"

    @Property(title: "Name", description: "The screen's name, such as Login or Settings.")
    var name: String

    @Property(title: "Device", description: "iPhone, iPhone Pro Max, iPhone SE or iPad. iPhone if unsaid.")
    var device: DeviceChoice?

    @Property(title: "Sections", description: "The screen's parts from top to bottom, such as a header, a form, a row of buttons.")
    var sections: [SectionSpec]

    var displayRepresentation: DisplayRepresentation { "\(name)" }
    init() {}

    /// The screen as the outline `BuildScreenIntent` reads: each section its lines, or one row, a blank line apart.
    var outline: String {
        sections.map { section in
            let lines = section.elements.map(\.line)
            return section.isRow ? "row: " + lines.joined(separator: " | ") : lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// Builds a screen from a spec Siri fills in itself. Hidden from Shortcuts, which has
/// `BuildScreenIntent` with its written layout instead.
@available(iOS 27, *)
@AppIntent(.tool)
struct BuildScreenFromSpecIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Build Screen from Spec"
    static let description = IntentDescription(
        "Builds a whole app screen in a Layer design from a structured description of its sections and elements."
    )
    static let supportedModes: IntentModes = .foreground
    static let isDiscoverable = false

    @Parameter(title: "Screen", description: "The screen to build: its name, device, and sections from top to bottom.")
    var spec: ScreenSpec

    @Parameter(title: "Design", description: "The design to add it to. The design at the front if not given.")
    var design: DesignEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScreenEntity> {
        let model = try await DesignActions.model(for: design)
        let device = (spec.device ?? .iPhone).frame
        // Read as Build Screen reads a generated outline, laid out off the main actor, as one step.
        let id = try await BuildScreenIntent.build(spec.outline, on: nil, name: spec.name, device: device, in: model,
                                                   undoManager: undoManager)
        DesignActions.reveal(.screen(id), in: model)
        guard let built = model.store.screen(id), let entity = DesignActions.entity(for: built, in: model) else {
            throw LayerIntentError.screenNotFound
        }
        return .result(value: entity)
    }
}
