import CoreGraphics

extension ElementKind {
    /// What Layer knows about this kind.
    ///
    /// Adding a kind takes its case in `ElementKind`, its entry below, how it is drawn
    /// (`ElementView`) and how it is written as code (`SwiftUICodeGenerator`). The compiler
    /// points at each. Reading it from a sketch is separate: see `ComponentRule`.
    var spec: ComponentSpec {
        switch self {
        case .title: Catalogue.title
        case .body: Catalogue.body
        case .image: Catalogue.image
        case .button: Catalogue.button
        case .textField: Catalogue.textField
        case .divider: Catalogue.divider
        case .symbol: Catalogue.symbol
        case .text: Catalogue.text
        case .stickyNote: Catalogue.stickyNote
        case .toggle: Catalogue.toggle
        case .avatar: Catalogue.avatar
        case .checkbox: Catalogue.checkbox
        case .radio: Catalogue.radio
        case .progress: Catalogue.progress
        case .drawing: Catalogue.drawing
        case .shape: Catalogue.shape
        case .group: Catalogue.group
        case .card: Catalogue.card
        }
    }
}

/// Every kind of element, one entry each. Sizes are in points on the standard phone.
enum Catalogue {
    static let title = ComponentSpec(
        name: "Title", symbol: "textformat", placeholder: "Title", promptName: "title",
        writtenNames: ["title", "heading", "header", "headline", "large title"],
        sketchHint: "a short squiggle near the top. A screen has one title.",
        size: .fixed(CGSize(width: 228, height: 40)),
        // Bigger scribbles are bigger titles: Title 2, Title, or Large Title.
        sketchFit: .words(sizedByHeight: true),
        // A title's text grows and shrinks with its box.
        fontSize: .ofHeight(0.7), fontWeight: .bold, textColour: .colour(RGBColor(hex: 0x000000)),
        textAlignment: .center,
        traits: [.border, .textAlignment]
    )

    static let body = ComponentSpec(
        name: "Body", symbol: "text.alignleft",
        placeholder: "A short description goes here, a line or two that says what this is.",
        promptName: "bodyText",
        writtenNames: ["body", "body text", "description", "paragraph", "subtitle", "caption"],
        sketchHint: "a longer squiggle, or a squiggle below a title or an image.",
        size: .fixed(CGSize(width: 297, height: 44)),
        sketchFit: .words(sizedByHeight: false),
        fillsWrittenWidth: true,
        // The size of iOS's subheadline: large enough to read, and two lines still fit the
        // body's usual 44 points. About 7.5 to 1 against a white screen: softer than the
        // title, still easy to read.
        fontSize: .points(15), textColour: .colour(RGBColor(hex: 0x55544F)),
        textAlignment: .center,
        traits: [.border, .textAlignment]
    )

    static let image = ComponentSpec(
        name: "Image", symbol: "photo", promptName: "image",
        writtenNames: ["image", "photo", "picture", "hero", "hero image", "banner"],
        sketchHint: "a large box, about as tall as it is wide or taller.",
        size: .tallAsDrawn(width: 333, height: 120...520, step: 8),
        runsAcross: true,
        sketchFit: .box(narrowest: 44),
        fillsWrittenWidth: true,
        cornerRadius: .points(16),
        traits: [.border, .cornerRadius]
    )

    static let button = ComponentSpec(
        name: "Button", symbol: "capsule.fill", placeholder: "Continue", promptName: "button",
        writtenNames: ["button", "primary button", "cta"],
        sketchHint: "a wide pill or rounded box. Usually near the bottom of a screen, and a screen rarely has more than one or two.",
        size: .fixed(CGSize(width: 353, height: 50)),
        runsAcross: true,
        sketchFit: .box(narrowest: 88),
        fillsWrittenWidth: true,
        fontWeight: .semibold, textColour: .onFill, cornerRadius: .ofHeight(0.5),
        textAlignment: .center,
        traits: [.border, .fill, .cornerRadius, .buttonLooks]
    )

    static let textField = ComponentSpec(
        name: "Text Field", symbol: "character.cursor.ibeam", placeholder: "Placeholder", promptName: "textField",
        writtenNames: ["text field", "textfield", "field", "input", "search field", "email field", "password field"],
        sketchHint: "a wide box with squarish or slightly rounded corners. Often stacked with other text fields in the upper or middle part of a screen.",
        size: .fixed(CGSize(width: 333, height: 48)),
        runsAcross: true,
        sketchFit: .box(narrowest: 120),
        fillsWrittenWidth: true,
        fontSize: .points(16), textColour: .colour(RGBColor(hex: 0x9A9892)), cornerRadius: .points(12),
        traits: [.border, .cornerRadius, .textAlignment]
    )

    static let divider = ComponentSpec(
        name: "Divider", symbol: "minus", promptName: "divider",
        writtenNames: ["divider", "separator", "line", "rule"],
        size: .fixed(CGSize(width: 333, height: 1)),
        minimumSize: CGSize(width: 32, height: 1),
        hasFixedHeight: true,
        runsAcross: true,
        fillsWrittenWidth: true,
        traits: []
    )

    static let symbol = ComponentSpec(
        name: "Symbol", symbol: "star", promptName: "symbol",
        writtenNames: ["symbol", "icon", "sf symbol"],
        isAskedForOnScreens: false,
        size: .fixed(CGSize(width: 44, height: 44)),
        minimumSize: CGSize(width: 12, height: 12),
        keepsSketchedPosition: true,
        tint: Theme.inkTint,
        traits: [.fill]
    )

    static let text = ComponentSpec(
        name: "Text", symbol: "character.textbox", placeholder: "Text", promptName: "text",
        writtenNames: ["text", "label"],
        isAskedForOnScreens: false,
        size: .fixed(CGSize(width: 200, height: 24)),
        looseSize: .wideAsDrawn(80...600),
        traits: [.border, .textAlignment]
    )

    /// Sticky notes are notes about a design, not part of one, so they never join a screen.
    static let stickyNote = ComponentSpec(
        name: "Sticky Note", symbol: "note.text", placeholder: "Note", promptName: "stickyNote",
        writtenNames: ["sticky note", "note"],
        belongsOnScreens: false,
        isAskedForOnScreens: false,
        size: .fixed(CGSize(width: 150, height: 150)),
        looseSize: .squareAsDrawn(100...320),
        tint: Theme.stickyNote,
        fontSize: .points(15), cornerRadius: .points(6),
        textAlignment: .center,
        traits: [.border, .fill, .cornerRadius, .textAlignment]
    )

    static let toggle = ComponentSpec(
        name: "Toggle", symbol: "switch.2", promptName: "toggle",
        writtenNames: ["toggle", "switch"],
        sketchHint: "a small pill with a circle (its knob) nearer one end than the middle.",
        size: .fixed(CGSize(width: 51, height: 31)),
        keepsSketchedPosition: true,
        traits: [.fill, .onState],
        onName: "On",
        marks: .knob
    )

    static let avatar = ComponentSpec(
        name: "Avatar", symbol: "person.crop.circle", promptName: "avatar",
        writtenNames: ["avatar", "profile picture", "profile photo"],
        sketchHint: "a circle about \(SketchConventions.radioPoints + 1) points across or more, usually alone rather than in a column.",
        // As large as it was drawn, within reason.
        size: .squareAsDrawn(side: 40...160, step: 4),
        staysSquare: true,
        keepsSketchedPosition: true,
        cornerRadius: .ofShorterSide(0.5),
        traits: [.border, .cornerRadius]
    )

    static let checkbox = ComponentSpec(
        name: "Checkbox", symbol: "checkmark.square", promptName: "checkbox",
        writtenNames: ["checkbox", "check box", "tick box"],
        sketchHint: "a tiny square, often with a tick or an X in it, usually beside a label.",
        size: .fixed(CGSize(width: 24, height: 24)),
        minimumSize: CGSize(width: 12, height: 12),
        keepsSketchedPosition: true,
        cornerRadius: .ofShorterSide(0.25),
        traits: [.fill, .cornerRadius, .onState],
        onName: "Checked",
        marks: .mark
    )

    static let radio = ComponentSpec(
        name: "Radio Button", symbol: "largecircle.fill.circle", promptName: "radioButton",
        writtenNames: ["radio", "radio button", "option"],
        sketchHint: "a tiny circle, under about \(SketchConventions.radioPoints) points across, often with a dot in it, usually one of a column of them.",
        size: .fixed(CGSize(width: 24, height: 24)),
        minimumSize: CGSize(width: 12, height: 12),
        staysSquare: true,
        keepsSketchedPosition: true,
        cornerRadius: .ofShorterSide(0.5),
        traits: [.fill, .onState],
        onName: "Selected",
        marks: .mark
    )

    /// Ink kept as it was drawn. It isn't part of a screen's interface, so it stays on the
    /// open canvas and no code is written for it. Its size is whatever its ink covers.
    static let drawing = ComponentSpec(
        name: "Drawing", symbol: "scribble", promptName: "drawing",
        writtenNames: [],
        belongsOnScreens: false,
        isAskedForOnScreens: false,
        size: .fixed(CGSize(width: 120, height: 120)),
        minimumSize: CGSize(width: 8, height: 8),
        tint: Theme.inkTint,
        hasEffects: false,
        traits: []
    )

    /// What it is drawn as is the element's own `shape`. Not something a sketch is read
    /// as, nor written in a generated screen: shapes are added from the library.
    static let shape = ComponentSpec(
        name: "Shape", symbol: "square.on.circle", promptName: "shape",
        writtenNames: [],
        isAskedForOnScreens: false,
        size: .fixed(CGSize(width: 100, height: 100)),
        minimumSize: CGSize(width: 8, height: 8),
        keepsSketchedPosition: true,
        cornerRadius: .points(16),
        traits: [.fill, .onState],
        onName: "Filled"
    )

    /// Several things kept together. Never sketched, written or asked for: it is made by
    /// grouping. Its size is the box round its members, worked out as they change; where it
    /// can go is decided by them. It shows no words, has no fill and no code of its own.
    static let group = ComponentSpec(
        name: "Group", symbol: "rectangle.3.group", promptName: "group",
        writtenNames: [],
        isAskedForOnScreens: false,
        size: .fixed(.zero),
        minimumSize: CGSize(width: 8, height: 8),
        hasEffects: false,
        traits: []
    )

    static let card = ComponentSpec(
        name: "Card", symbol: "rectangle.inset.filled", promptName: "card",
        writtenNames: [],
        isAskedForOnScreens: false,
        size: .fixed(.zero),
        minimumSize: CGSize(width: 8, height: 8),
        tint: DesignTokens.standard.card.fill,
        cornerRadius: .points(DesignTokens.standard.card.radius),
        hasEffects: true,
        traits: [.fill, .cornerRadius, .border]
    )

    static let progress = ComponentSpec(
        name: "Progress Bar", symbol: "progress.indicator", promptName: "progressBar",
        writtenNames: ["progress", "progress bar", "progress view", "loading bar"],
        sketchHint: "a long, very thin outline, often partly shaded in.",
        size: .fixed(CGSize(width: 333, height: 6)),
        minimumSize: CGSize(width: 32, height: 1),
        runsAcross: true,
        sketchFit: .box(narrowest: 60),
        fillsWrittenWidth: true,
        cornerRadius: .ofShorterSide(0.5),
        traits: [.border, .fill, .cornerRadius, .value],
        marks: .shading
    )
}
