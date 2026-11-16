import AppIntents
import CoreGraphics
import Foundation

// Actions on elements. An element left out means the selected one, which is what “this
// button” refers to when Siri reads what is on screen.

struct AddElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Add Element"
    static let description = IntentDescription(
        "Adds an element to a screen in a Layer design, below what is already there, and selects it.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Kind", description: "What to add: title, body text, button, text field, image, symbol, divider, text, toggle, avatar or sticky note.")
    var kind: ElementKindChoice

    @Parameter(title: "Text", description: "The words it shows, such as Sign in for a button or Email for a text field. The kind's usual words if not given.")
    var text: String?

    @Parameter(title: "Symbol", description: "For symbols only: the SF Symbol's name, such as heart.fill.")
    var symbol: String?

    @Parameter(title: "Colour", description: "Its fill colour, such as blue. Layer's own colour if not given.")
    var colour: ColourOption?

    @Parameter(title: "Screen", description: "The screen to add it to. The selected or newest screen if not given. Sticky notes go on the open canvas.")
    var screen: ScreenEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$kind) saying \(\.$text)") {
            \.$screen
            \.$symbol
            \.$colour
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ElementEntity> & ProvidesDialog {
        var element = DesignStore.newElement(kind.element, symbol: kind == .symbol ? (symbol ?? "star") : nil)
        if let text, kind.element.hasText { element.text = text }
        if let colour { element.tint = colour.colour }

        let model: AppModel
        let ref: DesignStore.ElementRef
        if kind == .stickyNote {
            model = try await DesignActions.model(for: screen?.designID)
            let middle = model.viewport.canvasPoint(for: CGPoint(x: model.canvasSize.width / 2, y: model.canvasSize.height / 2))
            ref = DesignActions.edit(model, undoManager: undoManager, actionName: "Add Sticky Note") {
                model.store.place(element, centeredAt: middle)
            }
        } else {
            let (found, host) = try await DesignActions.screenOrCurrent(screen)
            model = found
            element.frame = DesignActions.frameForNewElement(element, on: host)
            ref = DesignActions.edit(model, undoManager: undoManager, actionName: "Add \(kind.name)") {
                model.store.setElements([element], on: host.id, replacing: false)[0]
            }
        }
        DesignActions.reveal(.element(ref), in: model)
        guard let entity = DesignActions.entity(for: ref, in: model) else { throw LayerIntentError.elementNotFound }
        return .result(value: entity, dialog: "Added a \(kind.name.lowercased()) to \(entity.screenName).")
    }
}

struct EditElementTextIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Change Element Text"
    static let description = IntentDescription(
        "Changes the words an element shows: a title's text, a button's label, or a text field's placeholder.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to change. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Text", description: "The new words.")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Change the text of \(\.$element) to \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, ref, _) = try await DesignActions.elementOrSelected(element)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Change Text") {
            model.store.update(ref) { $0.text = text }
        }
        return .result(dialog: "Changed it to “\(text)”.")
    }
}

struct StyleElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Style Element"
    static let description = IntentDescription(
        "Changes how an element in a Layer design looks: its colour, text colour, font size and weight, text alignment, corner radius, opacity, outline and shadow. Anything left out stays as it is.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to change. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Colour", description: "The fill colour: a button's background, a symbol's ink, a sticky note's paper.")
    var colour: ColourOption?

    @Parameter(title: "Colour Hex", description: "The fill colour as a hex code such as #0A84FF, when no named colour fits.")
    var colourHex: String?

    @Parameter(title: "Text Colour", description: "The colour of the element's words.")
    var textColour: ColourOption?

    @Parameter(title: "Text Colour Hex", description: "The words' colour as a hex code such as #FFFFFF.")
    var textColourHex: String?

    @Parameter(title: "Font Size", description: "Text size in points, from 8 to 96.", inclusiveRange: (8, 96))
    var fontSize: Double?

    @Parameter(title: "Font Weight", description: "Regular, medium, semibold or bold.")
    var weight: FontWeightOption?

    @Parameter(title: "Text Alignment", description: "Left, centre or right.")
    var alignment: TextAlignmentOption?

    @Parameter(title: "Corner Radius", description: "How round the corners are, in points from 0 to 60.", inclusiveRange: (0, 60))
    var cornerRadius: Double?

    @Parameter(title: "Opacity", description: "How solid it is, from 0 (invisible) to 1 (fully solid).", inclusiveRange: (0, 1))
    var opacity: Double?

    @Parameter(title: "Outline Width", description: "Width of an outline round the element in points, 0 for none.", inclusiveRange: (0, 12))
    var borderWidth: Double?

    @Parameter(title: "Outline Colour", description: "The outline's colour.")
    var borderColour: ColourOption?

    @Parameter(title: "Shadow", description: "Whether the element casts a soft shadow.")
    var shadow: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("Style \(\.$element)") {
            \.$colour
            \.$colourHex
            \.$textColour
            \.$textColourHex
            \.$fontSize
            \.$weight
            \.$alignment
            \.$cornerRadius
            \.$opacity
            \.$borderWidth
            \.$borderColour
            \.$shadow
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let fill = try ColourOption.resolve(colour, hex: colourHex)
        let ink = try ColourOption.resolve(textColour, hex: textColourHex)
        let (model, ref, found) = try await DesignActions.elementOrSelected(element)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Style \(found.kind.layerName)") {
            model.store.update(ref) { element in
                if let fill { element.tint = fill }
                if let ink { element.textColor = ink }
                if let fontSize { element.fontSize = CGFloat(fontSize) }
                if let weight { element.fontWeight = weight.choice }
                if let alignment { element.textAlignment = alignment.choice }
                if let cornerRadius { element.cornerRadius = CGFloat(cornerRadius) }
                if let opacity { element.opacity = opacity }
                if let borderWidth { element.borderWidth = CGFloat(borderWidth) }
                if let borderColour {
                    element.borderColor = borderColour.colour
                    if (element.borderWidth ?? 0) == 0 { element.borderWidth = 1 }
                }
                if let shadow { element.hasShadow = shadow }
            }
        }
        return .result(dialog: "Updated the \(found.kind.layerName.lowercased()).")
    }
}

struct MoveElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Move or Resize Element"
    static let description = IntentDescription(
        "Moves or resizes an element. Positions are in points from the top-left corner of its screen; anything left out stays as it is.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to move. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "X", description: "Distance of its left edge from the screen's left edge, in points.")
    var x: Double?

    @Parameter(title: "Y", description: "Distance of its top edge from the screen's top edge, in points.")
    var y: Double?

    @Parameter(title: "Width", description: "Its width in points.", inclusiveRange: (1, 2000))
    var width: Double?

    @Parameter(title: "Height", description: "Its height in points.", inclusiveRange: (1, 2000))
    var height: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$element) to \(\.$x), \(\.$y)") {
            \.$width
            \.$height
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, ref, found) = try await DesignActions.elementOrSelected(element)
        guard !found.isLocked else { throw LayerIntentError.locked }
        DesignActions.edit(model, undoManager: undoManager, actionName: "Move \(found.kind.layerName)") {
            model.store.update(ref) { element in
                if let x { element.frame.origin.x = CGFloat(x) }
                if let y { element.frame.origin.y = CGFloat(y) }
                if let width { element.frame.size.width = CGFloat(width) }
                if let height { element.frame.size.height = CGFloat(height) }
            }
        }
        return .result(dialog: "Moved the \(found.kind.layerName.lowercased()).")
    }
}

struct AlignElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Align Element"
    static let description = IntentDescription(
        "Lines an element up with an edge or the middle of its screen.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to align. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Alignment", description: "Which edge or middle of the screen to line it up with.")
    var alignment: AlignmentOption

    static var parameterSummary: some ParameterSummary {
        Summary("Align \(\.$element) to the \(\.$alignment)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let (model, ref, found) = try await DesignActions.elementOrSelected(element)
        guard !found.isLocked else { throw LayerIntentError.locked }
        guard case .screen = ref.host else { throw LayerIntentError.screenNotFound }
        DesignActions.edit(model, undoManager: undoManager, actionName: "Align") {
            model.store.align(ref, alignment.alignment)
        }
        return .result()
    }
}

struct ArrangeElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Change Element Order"
    static let description = IntentDescription(
        "Moves an element in front of or behind the elements it overlaps.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to move. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Order", description: "Bring to front, bring forward, send backward or send to back.")
    var order: ArrangementOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$order) \(\.$element)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let (model, ref, _) = try await DesignActions.elementOrSelected(element)
        DesignActions.edit(model, undoManager: undoManager, actionName: order.arrangement.name) {
            model.store.arrange(ref, order.arrangement)
        }
        return .result()
    }
}

struct DuplicateElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Duplicate Element"
    static let description = IntentDescription("Copies an element, placing the copy a little below and to the right of it.", categoryName: "Elements")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to copy. The selected element if not given.")
    var element: ElementEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Duplicate \(\.$element)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ElementEntity> {
        let (model, ref, _) = try await DesignActions.elementOrSelected(element)
        let copy = DesignActions.edit(model, undoManager: undoManager, actionName: "Duplicate") {
            model.store.duplicate(ref)
        }
        guard let copy, let entity = DesignActions.entity(for: copy, in: model) else { throw LayerIntentError.elementNotFound }
        DesignActions.reveal(.element(copy), in: model)
        return .result(value: entity)
    }
}

struct DeleteElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Delete Element"
    static let description = IntentDescription("Deletes an element from a Layer design. It can be undone.", categoryName: "Elements")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to delete. The selected element if not given.")
    var element: ElementEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$element)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, ref, found) = try await DesignActions.elementOrSelected(element)
        guard !found.isLocked else { throw LayerIntentError.locked }
        let name = DesignDescriber.describe(found)
        try await requestConfirmation(dialog: "Delete the \(name)?")
        DesignActions.edit(model, undoManager: undoManager, actionName: "Delete") {
            model.store.delete(ref)
        }
        return .result(dialog: "Deleted the \(name).")
    }
}

struct SetElementHiddenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Hide or Show Element"
    static let description = IntentDescription(
        "Hides an element or shows it again. Hidden elements aren't drawn and are left out of the generated code.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to hide or show. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Hidden", description: "On to hide it, off to show it.", default: true)
    var hidden: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$element) hidden to \(\.$hidden)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let (model, ref, _) = try await DesignActions.elementOrSelected(element)
        DesignActions.edit(model, undoManager: undoManager, actionName: hidden ? "Hide" : "Show") {
            model.store.update(ref) { $0.isHidden = hidden }
        }
        if hidden, model.selection == .element(ref) { model.selection = nil }
        return .result()
    }
}

struct SetElementLockedIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Lock or Unlock Element"
    static let description = IntentDescription(
        "Locks an element so it can't be moved, resized or deleted by accident, or unlocks it.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to lock or unlock. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Locked", description: "On to lock it, off to unlock it.", default: true)
    var locked: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$element) locked to \(\.$locked)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let (model, ref, _) = try await DesignActions.elementOrSelected(element)
        DesignActions.edit(model, undoManager: undoManager, actionName: locked ? "Lock" : "Unlock") {
            model.store.update(ref) { $0.isLocked = locked }
        }
        return .result()
    }
}

struct RenameElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Rename Element"
    static let description = IntentDescription(
        "Names an element in the Layers list, such as Sign In Button. The name is also used in the generated code.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to name. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Name", description: "The new name.")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Rename \(\.$element) to \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let (model, ref, _) = try await DesignActions.elementOrSelected(element)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Rename") {
            model.store.update(ref) { $0.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name }
        }
        return .result()
    }
}

struct SelectElementIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Element"
    static let description = IntentDescription(
        "Selects an element on the canvas and brings it into view, ready to be changed.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to select.")
    var element: ElementEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Select \(\.$element)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let (model, ref, _) = try await DesignActions.element(element)
        DesignActions.reveal(.element(ref), in: model)
        return .result()
    }
}

struct FindElementsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Elements"
    static let description = IntentDescription(
        "Finds elements in the open Layer designs whose words, name or kind match, such as sign in or button.",
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Words", description: "Words on the element, its name, or its kind.")
    var words: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find elements matching \(\.$words)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ElementEntity]> {
        .result(value: try await ElementQuery().entities(matching: words))
    }
}
