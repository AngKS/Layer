@_weakLinked import AppIntents
import CoreGraphics
import Foundation

// Actions on elements. An element left out means the selected one, which is what “this
// button” refers to when Siri reads what is on screen.

struct AddElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Add Element"
    static let description = IntentDescription(
        """
        Adds an element to a screen in a Layer design and selects it: below what is already there, or at the \
        position and size given, in points from the screen's top-left corner. With On Canvas, or for a sticky \
        note, it goes on the open canvas instead, at canvas points. Look takes the same words as Build Screen, \
        such as “blue, bold, 18pt, radius 12, off, 40%, bordered, centre, shadow”.
        """,
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Kind", description: "What to add: title, body text, button, text field, image, symbol, divider, text, toggle, avatar, checkbox, radio button, progress bar or sticky note.")
    var kind: ElementKindChoice

    @Parameter(title: "Text", description: "The words it shows, such as Sign in for a button or Email for a text field. The kind's usual words if not given.")
    var text: String?

    @Parameter(title: "Symbol", description: "For symbols only: the SF Symbol's name, such as heart.fill.")
    var symbol: String?

    @Parameter(title: "Colour", description: "Its fill colour, such as blue. Layer's own colour if not given.")
    var colour: ColourOption?

    @Parameter(title: "Look", description: "Comma-separated look words: a colour name or hex, regular/medium/semibold/bold, a size such as 18pt, radius 12, text white, on/off, a percentage for a progress bar, filled/bordered/plain, left/centre/right, shadow, border red, opacity 50%.")
    var look: String?

    @Parameter(title: "X", description: "Distance of its left edge from the screen's left edge, in points; on the open canvas, from the canvas's left edge in canvas points. Centred if not given.")
    var x: Double?

    @Parameter(title: "Y", description: "Distance of its top edge from the screen's top edge, in points; on the open canvas, from the canvas's top edge in canvas points. Below what is there if not given.")
    var y: Double?

    @Parameter(title: "Width", description: "Its width in points. The kind's usual width if not given.", inclusiveRange: (1, 4000))
    var width: Double?

    @Parameter(title: "Height", description: "Its height in points. The kind's usual height if not given.", inclusiveRange: (1, 4000))
    var height: Double?

    @Parameter(title: "On Canvas", description: "Put it on the open canvas, outside every screen, as loose text or a note beside the screens.", default: false)
    var onCanvas: Bool

    @Parameter(title: "Screen", description: "The screen to add it to. The selected or newest screen if not given. Sticky notes go on the open canvas.")
    var screen: ScreenEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$kind) saying \(\.$text)") {
            \.$screen
            \.$look
            \.$x
            \.$y
            \.$width
            \.$height
            \.$onCanvas
            \.$symbol
            \.$colour
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ElementEntity> & ProvidesDialog {
        guard kind != .drawing else { throw LayerIntentError.drawingsAreDrawn }
        var element = DesignStore.newElement(kind.element, symbol: kind == .symbol ? (symbol ?? "star") : nil)
        if let text, kind.element.hasText { element.text = text }
        if let colour { element.tint = colour.colour }
        if let look {
            LookWords.look(from: look.components(separatedBy: ",")).apply(to: &element)
        }

        let model: AppModel
        let ref: DesignStore.ElementRef
        if kind == .stickyNote || onCanvas {
            model = try await DesignActions.model(for: screen?.designID)
            let scale = model.store.looseScale
            if let width { element.frame.size.width = CGFloat(width) / scale }
            if let height { element.frame.size.height = CGFloat(height) / scale }
            let middle = model.viewport.canvasPoint(for: CGPoint(x: model.canvasSize.width / 2, y: model.canvasSize.height / 2))
            let size = CGSize(width: element.frame.width * scale, height: element.frame.height * scale)
            let canvasOrigin = CGPoint(
                x: x.map { CGFloat($0) } ?? (middle.x - size.width / 2).rounded(),
                y: y.map { CGFloat($0) } ?? (middle.y - size.height / 2).rounded()
            )
            element.frame.origin = CGPoint(x: canvasOrigin.x / scale, y: canvasOrigin.y / scale)
            ref = DesignActions.edit(model, undoManager: undoManager, actionName: "Add \(kind.name)") {
                model.store.addFloating(element, scale: scale)
            }
        } else {
            let (found, host) = try await DesignActions.screenOrCurrent(screen)
            model = found
            element.frame = DesignActions.frameForNewElement(element, on: host)
            let center = element.frame.midX
            if let width {
                element.frame.size.width = CGFloat(width)
                element.frame.origin.x = (center - CGFloat(width) / 2).rounded()
            }
            if let height { element.frame.size.height = CGFloat(height) }
            if let x { element.frame.origin.x = CGFloat(x) }
            if let y { element.frame.origin.y = CGFloat(y) }
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
        """
        Changes how an element in a Layer design looks: its colour, text colour, font size and weight, text \
        alignment, corner radius, opacity, outline and shadow; whether a toggle, checkbox or radio button is on; \
        how full a progress bar is; a button's style; and a symbol's SF Symbol. Look takes the same words as \
        Build Screen, applied before the other settings. Anything left out stays as it is.
        """,
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to change. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Look", description: "Comma-separated look words, such as “blue, bold, 18pt, radius 12, text white, off, 40%, bordered, centre, shadow, border red, opacity 50%”.")
    var look: String?

    @Parameter(title: "Colour", description: "The fill colour: a button's background, a symbol's ink, a sticky note's paper.")
    var colour: ColourOption?

    @Parameter(title: "Colour Hex", description: "The fill colour as a hex code such as #0A84FF, when no named colour fits.")
    var colourHex: String?

    @Parameter(title: "Text Colour", description: "The colour of the element's words.")
    var textColour: ColourOption?

    @Parameter(title: "Text Colour Hex", description: "The words' colour as a hex code such as #FFFFFF.")
    var textColourHex: String?

    @Parameter(title: "Font Size", description: "Text size in points, from 6 to 400.", inclusiveRange: (6, 400))
    var fontSize: Double?

    @Parameter(title: "Font Weight", description: "Regular, medium, semibold or bold.")
    var weight: FontWeightOption?

    @Parameter(title: "Text Alignment", description: "Left, centre or right.")
    var alignment: TextAlignmentOption?

    @Parameter(title: "Corner Radius", description: "How round the corners are, in points from 0 to 999.", inclusiveRange: (0, 999))
    var cornerRadius: Double?

    @Parameter(title: "Opacity", description: "How solid it is, from 0 (invisible) to 1 (fully solid).", inclusiveRange: (0, 1))
    var opacity: Double?

    @Parameter(title: "Outline Width", description: "Width of an outline round the element in points, 0 for none.", inclusiveRange: (0, 40))
    var borderWidth: Double?

    @Parameter(title: "Outline Colour", description: "The outline's colour.")
    var borderColour: ColourOption?

    @Parameter(title: "Outline Colour Hex", description: "The outline's colour as a hex code such as #D1D1D6.")
    var borderColourHex: String?

    @Parameter(title: "Shadow", description: "Whether the element casts a soft shadow.")
    var shadow: Bool?

    @Parameter(title: "On", description: "For toggles, checkboxes and radio buttons: whether it is on, checked or selected.")
    var isOn: Bool?

    @Parameter(title: "Progress", description: "For progress bars: how full, from 0 to 1.", inclusiveRange: (0, 1))
    var progress: Double?

    @Parameter(title: "Button Style", description: "For buttons: filled, outlined or plain text.")
    var buttonStyle: ButtonLookOption?

    @Parameter(title: "Symbol", description: "For symbols: the SF Symbol's name, such as heart.fill.")
    var symbol: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Style \(\.$element)") {
            \.$look
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
            \.$borderColourHex
            \.$shadow
            \.$isOn
            \.$progress
            \.$buttonStyle
            \.$symbol
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let fill = try ColourOption.resolve(colour, hex: colourHex)
        let ink = try ColourOption.resolve(textColour, hex: textColourHex)
        let outline = try ColourOption.resolve(borderColour, hex: borderColourHex)
        let (model, ref, found) = try await DesignActions.elementOrSelected(element)
        let symbolName = symbol?.trimmingCharacters(in: .whitespaces)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Style \(found.kind.layerName)") {
            model.store.update(ref) { element in
                if let look {
                    LookWords.look(from: look.components(separatedBy: ",")).apply(to: &element)
                }
                if let fill { element.tint = fill }
                if let ink { element.textColor = ink }
                if let fontSize { element.fontSize = CGFloat(fontSize) }
                if let weight { element.fontWeight = weight.choice }
                if let alignment { element.textAlignment = alignment.choice }
                if let cornerRadius { element.cornerRadius = CGFloat(cornerRadius) }
                if let opacity { element.opacity = opacity >= 0.995 ? nil : opacity }
                if let borderWidth { element.borderWidth = borderWidth > 0 ? CGFloat(borderWidth) : nil }
                if let outline {
                    element.borderColor = outline
                    if (element.borderWidth ?? 0) == 0 { element.borderWidth = 1 }
                }
                if let shadow { element.hasShadow = shadow }
                if let isOn { element.isOn = isOn }
                if let progress { element.value = progress }
                if let buttonStyle { element.buttonLook = buttonStyle.look }
                if let symbolName, !symbolName.isEmpty, element.kind == .symbol { element.symbol = symbolName }
            }
        }
        return .result(dialog: "Updated the \(found.kind.layerName.lowercased()).")
    }
}

struct MoveElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Move or Resize Element"
    static let description = IntentDescription(
        """
        Moves or resizes an element. On a screen, positions and sizes are in points from the screen's top-left \
        corner; on the open canvas, in canvas points. Anything left out stays as it is.
        """,
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to move. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "X", description: "Distance of its left edge from the screen's left edge, in points.")
    var x: Double?

    @Parameter(title: "Y", description: "Distance of its top edge from the screen's top edge, in points.")
    var y: Double?

    @Parameter(title: "Width", description: "Its width in points.", inclusiveRange: (1, 4000))
    var width: Double?

    @Parameter(title: "Height", description: "Its height in points.", inclusiveRange: (1, 4000))
    var height: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$element)") {
            \.$x
            \.$y
            \.$width
            \.$height
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, ref, found) = try await DesignActions.elementOrSelected(element)
        try Self.move(ref, in: model, x: x, y: y, width: width, height: height, undoManager: undoManager)
        return .result(dialog: "Moved the \(found.kind.layerName.lowercased()).")
    }

    /// Moves or resizes an element as the action asks, unless it is locked.
    @MainActor
    static func move(_ ref: DesignStore.ElementRef, in model: AppModel, x: Double?, y: Double?, width: Double?, height: Double?, undoManager: UndoManager?) throws {
        guard let found = model.store.resolve(ref) else { throw LayerIntentError.elementNotFound }
        try DesignActions.requireUnlocked(ref, in: model)
        // Loose elements are given in canvas points and kept in points of their own.
        let scale: CGFloat = ref.host == .canvas ? found.placement.scale : 1
        DesignActions.edit(model, undoManager: undoManager, actionName: "Move \(found.element.kind.layerName)") {
            model.store.update(ref) { element in
                if let x { element.frame.origin.x = CGFloat(x) / scale }
                if let y { element.frame.origin.y = CGFloat(y) / scale }
                if let width { element.frame.size.width = CGFloat(width) / scale }
                if let height { element.frame.size.height = CGFloat(height) / scale }
            }
        }
    }
}

struct MoveElementToScreenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Move Element to Screen"
    static let description = IntentDescription(
        """
        Moves an element onto another screen, or off its screen onto the open canvas. X and Y place its top-left \
        corner, in the new screen's points or in canvas points; without them it keeps its place on the canvas.
        """,
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Element", description: "The element to move. The selected element if not given.")
    var element: ElementEntity?

    @Parameter(title: "Screen", description: "The screen to move it onto. Leave out to put it on the open canvas.")
    var screen: ScreenEntity?

    @Parameter(title: "X", description: "Where its left edge goes: points from the screen's left edge, or canvas points on the open canvas.")
    var x: Double?

    @Parameter(title: "Y", description: "Where its top edge goes: points from the screen's top edge, or canvas points on the open canvas.")
    var y: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$element) to \(\.$screen)") {
            \.$x
            \.$y
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ElementEntity> & ProvidesDialog {
        let (model, ref, found) = try await DesignActions.elementOrSelected(element)
        try DesignActions.requireUnlocked(ref, in: model)
        var targetID: DesignScreen.ID?
        if let screen {
            guard let id = screen.screenID, model.store.screen(id) != nil else { throw LayerIntentError.screenNotFound }
            guard found.kind.belongsOnScreens else { throw LayerIntentError.cantGoOnScreens }
            targetID = id
        }
        var origin: CGPoint?
        if (x != nil || y != nil), let current = model.store.resolve(ref) {
            let canvasOrigin = current.placement.canvasRect(for: current.element.frame).origin
            if let targetID, let target = model.store.screen(targetID) {
                // Screen points, with what isn't given kept where it is on the canvas.
                let kept = target.placement.localPoint(for: canvasOrigin)
                origin = CGPoint(x: x.map { CGFloat($0) } ?? kept.x.rounded(), y: y.map { CGFloat($0) } ?? kept.y.rounded())
            } else {
                // Canvas points, turned into the element's own: off a screen it keeps the
                // scale it is drawn at.
                let scale = current.placement.scale
                origin = CGPoint(x: (x.map { CGFloat($0) } ?? canvasOrigin.x) / scale, y: (y.map { CGFloat($0) } ?? canvasOrigin.y) / scale)
            }
        }
        let moved = DesignActions.edit(model, undoManager: undoManager, actionName: "Move \(found.kind.layerName)") {
            model.store.move(ref, toScreen: targetID, origin: origin)
        }
        guard let moved, let entity = DesignActions.entity(for: moved, in: model) else { throw LayerIntentError.elementNotFound }
        DesignActions.reveal(.element(moved), in: model)
        return .result(value: entity, dialog: "Moved the \(found.kind.layerName.lowercased()) to \(entity.screenName).")
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
        let (model, ref, _) = try await DesignActions.elementOrSelected(element)
        try DesignActions.requireUnlocked(ref, in: model)
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
        "Brings an element to the front, or forward past the next element, or sends it backward past the next element, or to the back, among the elements on its screen or on the open canvas. An element in a group moves among the others in its group, and stays in it. Drawings stay on top.",
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
        try Self.arrange(ref, in: model, order.arrangement, undoManager: undoManager)
        return .result()
    }

    /// Arranges an element as one undo step, among the others in its group when it is in
    /// one. A drawing stays on top, a locked element stays where it is, and one that can go
    /// no further that way stays too, and Siri says why rather than doing nothing.
    @MainActor
    static func arrange(_ ref: DesignStore.ElementRef, in model: AppModel, _ arrangement: DesignStore.Arrangement, undoManager: UndoManager?) throws {
        guard let (element, _) = model.store.resolve(ref) else { throw LayerIntentError.elementNotFound }
        guard element.kind != .drawing else { throw LayerIntentError.drawingsStayOnTop }
        guard !model.store.isLocked(.element(ref)) else { throw LayerIntentError.locked }
        guard model.store.canArrange(ref, arrangement) else {
            throw LayerIntentError.cantGoFurther(withinGroup: element.group != nil)
        }
        DesignActions.edit(model, undoManager: undoManager, actionName: arrangement.name) {
            model.store.arrange(ref, arrangement)
        }
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
        // Asked before the confirmation: a locked element isn't offered for deleting.
        try DesignActions.requireUnlocked(ref, in: model)
        let name = DesignDescriber.describe(found)
        try await requestConfirmation(dialog: "Delete the \(name)?")
        try Self.delete(ref, in: model, undoManager: undoManager)
        return .result(dialog: "Deleted the \(name).")
    }

    /// Deletes an element, unless it is locked, as one step.
    @MainActor
    static func delete(_ ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws {
        guard model.store.resolve(ref) != nil else { throw LayerIntentError.elementNotFound }
        try DesignActions.requireUnlocked(ref, in: model)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Delete") {
            model.store.delete(ref)
        }
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
        try Self.setHidden(hidden, ref, in: model, undoManager: undoManager)
        return .result()
    }

    /// Hides an element, or shows it as one undo step.
    @MainActor
    static func setHidden(_ hidden: Bool, _ ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws {
        guard model.store.resolve(ref) != nil else { throw LayerIntentError.elementNotFound }
        DesignActions.edit(model, undoManager: undoManager, actionName: hidden ? "Hide" : "Show") {
            // Shown, it has to be showing: the hidden groups above it are shown too, as unlocking
            // unlocks the groups above (ruling D), or a member hidden only by its group stays hidden.
            let groups = hidden ? [] : model.store.content.ancestors(of: ref.element).filter { model.store.element($0)?.isHidden == true }
            model.store.apply { content in
                content.update(ref.element) { $0.isHidden = hidden }
                for id in groups { content.update(id) { $0.isHidden = false } }
            }
        }
        if hidden { model.deselect(.element(ref)) }
    }
}

struct SetElementLockedIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Lock or Unlock Element"
    static let description = IntentDescription(
        "Locks an element so it can't be moved, resized or deleted by accident, or unlocks it. Unlocking an element in a locked group unlocks the group too.",
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
        try Self.setLocked(locked, ref, in: model, undoManager: undoManager)
        return .result()
    }

    /// Locks an element, or unlocks it as one undo step. Unlocking acts on the lock that
    /// holds it: the locked groups above it are unlocked too, as the popover and the Format
    /// panel do, or a member locked only by its group would stay locked (ruling D). Locking
    /// locks only the element.
    @MainActor
    static func setLocked(_ locked: Bool, _ ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws {
        guard model.store.resolve(ref) != nil else { throw LayerIntentError.elementNotFound }
        DesignActions.edit(model, undoManager: undoManager, actionName: locked ? "Lock" : "Unlock") {
            if locked {
                model.store.setLocked(true, .element(ref))
            } else {
                model.store.unlock(.element(ref))
            }
        }
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
