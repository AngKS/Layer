// NOT BUILT. Staged for the Siri AI Developer Preview SDK, which Xcode 27.2 doesn't
// include: it has no `.tool` trait, `ToolIntent`, `GenerableEntity` or `@AppEntity(.generable)`.
// Written against Apple's preview documentation and never compiled. Move it into
// Layer/Intents/ once a preview SDK is installed, and fix what the compiler says.

import AppIntents
import CoreGraphics

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

    @Property(title: "Font Size", description: "Text size in points, 11 to 64. The kind's usual size if unsaid.")
    var fontSize: Double?

    @Property(title: "Weight", description: "Regular, medium, semibold or bold.")
    var weight: FontWeightOption?

    @Property(title: "Corner Radius", description: "Corner radius in points, 0 to 40.")
    var cornerRadius: Double?

    var displayRepresentation: DisplayRepresentation { "\(text)" }
    init() {}

    var item: ScreenBlueprint.Item {
        ScreenBlueprint.Item(
            kind: kind.element,
            text: text.isEmpty ? kind.element.placeholder : text,
            symbol: kind == .symbol ? (symbol ?? "star") : nil,
            width: fillsWidth.map { $0 ? .fill : .fit },
            colour: colour.flatMap(ColourWords.parse),
            fontSize: fontSize.map { CGFloat($0) },
            weight: weight?.choice,
            cornerRadius: cornerRadius.map { CGFloat($0) }
        )
    }
}

/// A part of a screen: a column or a row of elements.
@available(iOS 27, *)
@AppEntity(.generable)
struct SectionSpec: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen Section"

    @Property(title: "Side by Side", description: "True to put the elements in one row, false to stack them top to bottom.")
    var isRow: Bool

    @Property(title: "Spacing", description: "Gap between elements in points, 0 to 48. 12 if unsaid.")
    var spacing: Double?

    @Property(title: "Elements", description: "The section's elements in reading order.")
    var elements: [ElementSpec]

    var displayRepresentation: DisplayRepresentation { "\(elements.count) elements" }
    init() {}
}

/// A whole screen, written by Siri from a description such as “a login screen with
/// email, password and a Sign in button”. Laid out by the same code as `BuildScreenIntent`.
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

    var blueprint: ScreenBlueprint {
        ScreenBlueprint(sections: sections.map { section in
            ScreenBlueprint.Section(
                axis: section.isRow ? .horizontal : .vertical,
                spacing: section.spacing.map { CGFloat($0) } ?? 12,
                items: section.elements.map(\.item)
            )
        })
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
        let built = DesignActions.edit(model, undoManager: undoManager, actionName: "Build Screen") { () -> DesignScreen in
            let screen = model.store.addScreen(device, at: DesignActions.placementForNewScreen(device, in: model))
            model.store.updateScreen(screen.id) { $0.name = spec.name }
            model.store.setElements(spec.blueprint.layout(on: device), on: screen.id, replacing: true)
            return model.store.screen(screen.id) ?? screen
        }
        DesignActions.reveal(.screen(built.id), in: model)
        guard let entity = DesignActions.entity(for: built, in: model) else { throw LayerIntentError.screenNotFound }
        return .result(value: entity)
    }
}
