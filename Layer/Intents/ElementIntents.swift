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
        var node = LayerNode.standard(kind.element, symbol: kind == .symbol ? (symbol ?? "star") : nil)
        if let text, kind.element.hasText { node.content.text = text }
        if let colour { node.style.tint = colour.colour }
        if let look {
            LookWords.look(from: look.components(separatedBy: ",")).apply(to: &node)
        }

        let model: AppModel
        let host: TreeIndex.Host
        if kind == .stickyNote || onCanvas {
            model = try await DesignActions.model(for: screen?.designID)
            host = .canvas
        } else {
            let (found, target) = try await DesignActions.screenOrCurrent(screen)
            model = found
            host = .screen(target.id)
        }
        let ref = try Self.add(node, to: host, in: model, x: x, y: y, width: width, height: height, undoManager: undoManager)
        DesignActions.reveal(.element(ref), in: model)
        guard let entity = DesignActions.entity(for: ref, in: model) else { throw LayerIntentError.elementNotFound }
        return .result(value: entity, dialog: "Added a \(kind.name.lowercased()) to \(entity.screenName).")
    }

    /// Adds `node` (`LayerNode.standard`, with what the action asked of it) as one step, "Add <kind>" (call 5):
    /// - on a screen whose root is free, at the frame given in screen points, what isn't given coming from
    ///   `DesignStore.newElementFrame`, below what is there; a width alone keeps its middle where that puts it;
    /// - on a screen whose root lays things out, appended, last in its order, each size given fixing its axis; an x or y
    ///   given is dropped, since the root places it;
    /// - on the open canvas (`add(_:to: .canvas)`), drawn at the newest screen's scale, in the middle of the view unless
    ///   placed: its numbers are canvas points, each ÷ that scale in its own points.
    ///
    /// Throws `screenNotFound` for a screen that has gone, `cantGoOnScreens` for a kind that stays on the canvas, and
    /// `designTooLarge` when the design can hold no more. Returns where it is.
    @MainActor
    static func add(_ node: LayerNode, to host: TreeIndex.Host, in model: AppModel, x: Double?, y: Double?,
                    width: Double?, height: Double?, undoManager: UndoManager?) throws -> DesignStore.ElementRef {
        let store = model.store
        var node = node
        let parent: NodeParent
        switch host {
        case .canvas:
            // Drawn as large as the newest screen, so it matches it.
            let scale = store.tree.screens.last.map(\.scale).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0.66
            if let width { node.frame.size.width = CGFloat(width) / scale }
            if let height { node.frame.size.height = CGFloat(height) / scale }
            let middle = model.viewport.canvasPoint(for: CGPoint(x: model.canvasSize.width / 2, y: model.canvasSize.height / 2))
            let size = CGSize(width: node.frame.width * scale, height: node.frame.height * scale)
            let corner = CGPoint(
                x: x.map { CGFloat($0) } ?? (middle.x - size.width / 2).rounded(),
                y: y.map { CGFloat($0) } ?? (middle.y - size.height / 2).rounded()
            )
            node.frame.origin = CGPoint(x: corner.x / scale, y: corner.y / scale)
            node.scale = scale
            parent = .canvas
        case .screen(let screenID):
            guard let screen = store.treeScreen(screenID) else { throw LayerIntentError.screenNotFound }
            guard node.kind.belongsOnScreens else { throw LayerIntentError.cantGoOnScreens }
            if let width {
                node.frame.size.width = CGFloat(width)
                node.width.mode = .fixed
            }
            if let height {
                node.frame.size.height = CGFloat(height)
                node.height.mode = .fixed
            }
            if screen.root.resolvedLayout == .free {
                guard var frame = store.newElementFrame(node.kind, on: screenID) else { throw LayerIntentError.screenNotFound }
                let centre = frame.midX
                if let width {
                    frame.size.width = CGFloat(width)
                    frame.origin.x = (centre - CGFloat(width) / 2).rounded()
                }
                if let height { frame.size.height = CGFloat(height) }
                if let x { frame.origin.x = CGFloat(x) }
                if let y { frame.origin.y = CGFloat(y) }
                node.frame = frame
            }
            parent = .screen(screenID)
        }
        let made = node
        let added = DesignActions.edit(model, undoManager: undoManager, actionName: "Add \(made.kind.layerName)") {
            store.add(made, to: parent)
        }
        guard added else { throw LayerIntentError.designTooLarge }
        return DesignStore.ElementRef(host: DesignStore.ElementRef.Host(host), element: made.id)
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
        let (model, ref, _) = try await DesignActions.nodeOrSelected(element)
        try Self.setText(text, of: ref, in: model, undoManager: undoManager)
        return .result(dialog: "Changed it to “\(text)”.")
    }

    /// Gives the node the words, as one step, "Change Text". Throws `elementNotFound` when it has gone.
    @MainActor
    static func setText(_ text: String, of ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws {
        guard model.store.placed(ref) != nil else { throw LayerIntentError.elementNotFound }
        DesignActions.edit(model, undoManager: undoManager, actionName: "Change Text") {
            model.store.update(ref.element) { $0.content.text = text }
        }
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
        let (model, ref, found) = try await DesignActions.nodeOrSelected(element)
        try style(ref, in: model, undoManager: undoManager)
        return .result(dialog: "Updated the \(found.kind.layerName.lowercased()).")
    }

    /// Gives the node `ref` points at the look this action asks for, as one step, "Style <kind>": the look words first,
    /// then each setting given. Throws `invalidColour` for a hex code that isn't one, and `elementNotFound` when it has
    /// gone.
    @MainActor
    func style(_ ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws {
        let fill = try ColourOption.resolve(colour, hex: colourHex)
        let ink = try ColourOption.resolve(textColour, hex: textColourHex)
        let outline = try ColourOption.resolve(borderColour, hex: borderColourHex)
        guard let kind = model.store.placed(ref)?.node.kind else { throw LayerIntentError.elementNotFound }
        let words = look.map { LookWords.look(from: $0.components(separatedBy: ",")) }
        let symbolName = symbol?.trimmingCharacters(in: .whitespaces)
        let (fontSize, weight, alignment, cornerRadius, opacity) = (fontSize, weight, alignment, cornerRadius, opacity)
        let (borderWidth, shadow, isOn, progress, buttonStyle) = (borderWidth, shadow, isOn, progress, buttonStyle)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Style \(kind.layerName)") {
            model.store.update(ref.element) { node in
                words?.apply(to: &node)
                if let fill { node.style.tint = fill }
                if let ink { node.style.textColor = ink }
                if let fontSize { node.style.fontSize = CGFloat(fontSize) }
                if let weight { node.style.fontWeight = weight.choice }
                if let alignment { node.style.textAlignment = alignment.choice }
                if let cornerRadius { node.style.cornerRadius = CGFloat(cornerRadius) }
                if let opacity { node.style.opacity = opacity >= 0.995 ? nil : opacity }
                if let borderWidth { node.style.borderWidth = borderWidth > 0 ? CGFloat(borderWidth) : nil }
                if let outline {
                    node.style.borderColor = outline
                    if (node.style.borderWidth ?? 0) == 0 { node.style.borderWidth = 1 }
                }
                if let shadow { node.style.hasShadow = shadow }
                if let isOn { node.content.isOn = isOn }
                if let progress { node.content.value = progress }
                if let buttonStyle { node.content.buttonLook = buttonStyle.look }
                if let symbolName, !symbolName.isEmpty, node.kind == .symbol { node.content.symbol = symbolName }
            }
        }
    }
}

struct MoveElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Move or Resize Element"
    static let description = IntentDescription(
        """
        Moves or resizes an element. On a screen, positions and sizes are in points from the screen's top-left \
        corner; on the open canvas, in canvas points: the numbers Get Design Layout gives. Anything left out stays as \
        it is. An element in a row, column or grid moves to another place in it, or out of it onto its screen.
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
        let (model, ref, found) = try await DesignActions.nodeOrSelected(element)
        try Self.move(ref, in: model, x: x, y: y, width: width, height: height, undoManager: undoManager)
        return .result(dialog: "Moved the \(found.kind.layerName.lowercased()).")
    }

    /// Moves or resizes a node as the action asks, as one step, "Move <kind>", unless it is locked (calls 3 and 5).
    ///
    /// The numbers are its host shape's, as Get Design Layout gives them: screen points on a screen, canvas points on
    /// the open canvas. They go through the drag rule (`DesignStore.move(_:toHostFrame:size:)`): in a free parent the
    /// node is put there; in a row, column or grid a size alone fixes those axes, and a position reorders it there or
    /// takes it out onto its own screen's root, never onto another screen.
    ///
    /// A number within 0.05 of what Get Design Layout says of the node, which rounds to a tenth, is no change, and when
    /// every one given is none nothing is written, so a frame read back moves nothing (F8). Throws `laidOut` for a child
    /// of a screen's laid-out root sent where it can't be kept (F15), `locked` for a locked one, and `elementNotFound`
    /// when it has gone.
    @MainActor
    static func move(_ ref: DesignStore.ElementRef, in model: AppModel, x: Double?, y: Double?, width: Double?, height: Double?, undoManager: UndoManager?) throws {
        let store = model.store
        guard let placed = store.placed(ref), let shown = store.index[ref.element]?.hostShape.rect else {
            throw LayerIntentError.elementNotFound
        }
        try DesignActions.requireUnlocked(ref, in: model)
        /// A number given that isn't what Get Design Layout says of it now.
        func changed(_ given: Double?, from now: CGFloat) -> CGFloat? {
            guard let given else { return nil }
            let said = (Double(now) * 10).rounded() / 10
            return abs(given - said) <= 0.05 ? nil : CGFloat(given)
        }
        let newX = changed(x, from: shown.minX), newY = changed(y, from: shown.minY)
        let newWidth = changed(width, from: shown.width), newHeight = changed(height, from: shown.height)
        guard newX != nil || newY != nil || newWidth != nil || newHeight != nil else { return }
        var asked = shown
        if let newX { asked.origin.x = newX }
        if let newY { asked.origin.y = newY }
        if let newWidth { asked.size.width = newWidth }
        if let newHeight { asked.size.height = newHeight }
        // A screen's points are its nodes' host points; on the canvas those are the top-level node's own points, canvas
        // points ÷ its scale.
        let frame = ref.host == .canvas ? placed.placement.localRect(for: asked) : asked
        let outcome = DesignActions.edit(model, undoManager: undoManager, actionName: "Move \(placed.node.kind.layerName)") {
            store.move(ref.element, toHostFrame: frame, size: newX == nil && newY == nil)
        }
        if outcome == .refused { throw LayerIntentError.laidOut }
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
        let (model, ref, found) = try await DesignActions.nodeOrSelected(element)
        var targetID: TreeScreen.ID?
        if let screen {
            guard let id = screen.screenID else { throw LayerIntentError.screenNotFound }
            targetID = id
        }
        let moved = try Self.move(ref, toScreen: targetID, x: x, y: y, in: model, undoManager: undoManager)
        guard let entity = DesignActions.entity(for: moved, in: model) else { throw LayerIntentError.elementNotFound }
        DesignActions.reveal(.element(moved), in: model)
        return .result(value: entity, dialog: "Moved the \(found.kind.layerName.lowercased()) to \(entity.screenName).")
    }

    /// Moves a node onto a screen, or onto the open canvas when `screenID` is nil, as one step, "Move <kind>", unless it
    /// is locked. Returns where it now is.
    ///
    /// Onto another host it is taken out of whatever held it (`DesignStore.takeOut`): onto that host's top, in front of
    /// what is there, at its size and angle, fixed on both axes, and on the canvas drawn as large as it was. X and Y
    /// place its top-left corner, in the screen's points or in canvas points; what isn't given keeps its place on the
    /// canvas. On its own host it moves as Move Element moves it, by the drag rule, and stays where it is without X
    /// or Y.
    ///
    /// Throws `screenNotFound` for a screen that has gone, `cantGoOnScreens` for a sticky note asked onto one, `locked`
    /// and `elementNotFound`.
    @MainActor
    static func move(_ ref: DesignStore.ElementRef, toScreen screenID: TreeScreen.ID?, x: Double?, y: Double?, in model: AppModel,
                     undoManager: UndoManager?) throws -> DesignStore.ElementRef {
        let store = model.store
        guard let placed = store.placed(ref) else { throw LayerIntentError.elementNotFound }
        try DesignActions.requireUnlocked(ref, in: model)
        let target: TreeIndex.Host
        /// How the target's points lie on the canvas: a screen's placement, or the canvas's own points.
        let points: Placement
        if let screenID {
            guard let screen = store.treeScreen(screenID) else { throw LayerIntentError.screenNotFound }
            guard placed.node.kind.belongsOnScreens else { throw LayerIntentError.cantGoOnScreens }
            target = .screen(screenID)
            points = screen.placement
        } else {
            target = .canvas
            points = Placement(origin: .zero, scale: 1)
        }
        guard target != TreeIndex.Host(ref.host) else {
            if x != nil || y != nil {
                try MoveElementIntent.move(ref, in: model, x: x, y: y, width: nil, height: nil, undoManager: undoManager)
            }
            return ref
        }
        // Its middle where it is to go, in the target's points: from the corner given and its size there, which on the
        // canvas is as large as it is drawn now, or where it is on the canvas now.
        let drawn = target == .canvas ? placed.placement.scale : 1
        let size = CGSize(width: placed.frame.width * drawn, height: placed.frame.height * drawn)
        let kept = points.localPoint(for: placed.canvasShape.centre)
        let middle = CGPoint(x: x.map { CGFloat($0) + size.width / 2 } ?? kept.x, y: y.map { CGFloat($0) + size.height / 2 } ?? kept.y)
        let isMoved = DesignActions.edit(model, undoManager: undoManager, actionName: "Move \(placed.node.kind.layerName)") {
            store.takeOut(ref.element, to: target, centredAt: points.canvasPoint(for: middle))
        }
        guard isMoved, let moved = store.ref(of: ref.element) else { throw LayerIntentError.elementNotFound }
        return moved
    }
}

struct AlignElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Align Element"
    static let description = IntentDescription(
        "Lines an element up with an edge or the middle of its screen. One that a row, column or grid places keeps its place there.",
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
        let (model, ref, _) = try await DesignActions.nodeOrSelected(element)
        try Self.align(ref, in: model, alignment.alignment, undoManager: undoManager)
        return .result()
    }

    /// Lines a node up with an edge or the middle of its screen, as one step, "Align", by the popover's and the Format
    /// panel's rule (`AppModel.lineUpSelection`): only what sits in a free parent moves (spec §10). Throws `laidOut` for
    /// one a row, column, grid or overlay places, a screen's root among them, `screenNotFound` for one off a screen,
    /// `locked` and `elementNotFound`.
    @MainActor
    static func align(_ ref: DesignStore.ElementRef, in model: AppModel, _ alignment: ElementLayout.Alignment, undoManager: UndoManager?) throws {
        let store = model.store
        guard store.placed(ref) != nil else { throw LayerIntentError.elementNotFound }
        try DesignActions.requireUnlocked(ref, in: model)
        guard case .screen = ref.host else { throw LayerIntentError.screenNotFound }
        let thing = CanvasSelection.element(ref)
        guard store.laidOutParent(of: thing) == nil, store.holdsSomethingInAFreeParent(thing) else { throw LayerIntentError.laidOut }
        DesignActions.edit(model, undoManager: undoManager, actionName: "Align") {
            store.align(ref, alignment)
        }
    }
}

struct ArrangeElementIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Change Element Order"
    static let description = IntentDescription(
        "Brings an element to the front, or forward past the next element, or sends it backward past the next element, or to the back, among the elements on its screen or on the open canvas. An element in a group moves among the others in its group, and stays in it. One in a row, column or grid keeps the order it has there. Drawings stay on top.",
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
        let (model, ref, _) = try await DesignActions.nodeOrSelected(element)
        try Self.arrange(ref, in: model, order.arrangement, undoManager: undoManager)
        return .result()
    }

    /// Arranges a node as one undo step, among the others in its container when it is in
    /// one. A drawing stays on top, a locked element stays where it is, and one that can go
    /// no further that way stays too, and Siri says why rather than doing nothing. So does one
    /// a row, column or grid orders, which its order there places (`laidOut`); one in an overlay,
    /// which stacks what it holds, is arranged (My call 15, F14).
    @MainActor
    static func arrange(_ ref: DesignStore.ElementRef, in model: AppModel, _ arrangement: DesignStore.Arrangement, undoManager: UndoManager?) throws {
        let store = model.store
        guard let placed = store.placed(ref) else { throw LayerIntentError.elementNotFound }
        guard placed.node.kind != .drawing else { throw LayerIntentError.drawingsStayOnTop }
        guard !store.isLocked(.element(ref)) else { throw LayerIntentError.locked }
        switch placed.parentLayout {
        case .stack, .grid: throw LayerIntentError.laidOut
        case .free, .overlay: break
        }
        guard store.canArrange(ref, arrangement) else {
            let isInAContainer = if case .node = store.parent(of: ref.element) { true } else { false }
            throw LayerIntentError.cantGoFurther(withinGroup: isInAContainer)
        }
        DesignActions.edit(model, undoManager: undoManager, actionName: arrangement.name) {
            store.arrange(ref, arrangement)
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
        let (model, ref, _) = try await DesignActions.nodeOrSelected(element)
        let copy = try Self.duplicate(ref, in: model, undoManager: undoManager)
        guard let entity = DesignActions.entity(for: copy, in: model) else { throw LayerIntentError.elementNotFound }
        DesignActions.reveal(.element(copy), in: model)
        return .result(value: entity)
    }

    /// A copy beside the node (`DesignStore.duplicate(node:)`), as one step, "Duplicate". Throws `elementNotFound` when
    /// it has gone, and `designTooLarge` when the design can't hold the copy. Returns where the copy is.
    @MainActor
    static func duplicate(_ ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws -> DesignStore.ElementRef {
        guard model.store.placed(ref) != nil else { throw LayerIntentError.elementNotFound }
        let copy = DesignActions.edit(model, undoManager: undoManager, actionName: "Duplicate") {
            model.store.duplicate(node: ref.element)
        }
        guard let copy else { throw LayerIntentError.designTooLarge }
        return DesignStore.ElementRef(host: ref.host, element: copy)
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
        let (model, ref, found) = try await DesignActions.nodeOrSelected(element)
        // Asked before the confirmation: a locked element isn't offered for deleting.
        try DesignActions.requireUnlocked(ref, in: model)
        let name = DesignDescriber.describe(found)
        try await requestConfirmation(dialog: "Delete the \(name)?")
        try Self.delete(ref, in: model, undoManager: undoManager)
        return .result(dialog: "Deleted the \(name).")
    }

    /// Deletes a node, unless it is locked, as one step (`DesignStore.delete(nodes:)`).
    @MainActor
    static func delete(_ ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws {
        guard model.store.placed(ref) != nil else { throw LayerIntentError.elementNotFound }
        try DesignActions.requireUnlocked(ref, in: model)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Delete") {
            model.store.delete(nodes: [ref.element])
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
        let (model, ref, _) = try await DesignActions.nodeOrSelected(element)
        try Self.setHidden(hidden, ref, in: model, undoManager: undoManager)
        return .result()
    }

    /// Hides a node, or shows it, as one undo step.
    @MainActor
    static func setHidden(_ hidden: Bool, _ ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws {
        let store = model.store
        guard store.placed(ref) != nil else { throw LayerIntentError.elementNotFound }
        // Shown, it has to be showing: the hidden containers above it are shown too, as unlocking
        // unlocks the ones above (ruling D), or a node hidden only by its container stays hidden.
        let containers = hidden ? [] : store.index.ancestors(of: ref.element).filter { store.node($0)?.isHidden == true }
        DesignActions.edit(model, undoManager: undoManager, actionName: hidden ? "Hide" : "Show") {
            store.update(ref.element) { $0.isHidden = hidden }
            for id in containers { store.update(id) { $0.isHidden = false } }
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
        let (model, ref, _) = try await DesignActions.nodeOrSelected(element)
        try Self.setLocked(locked, ref, in: model, undoManager: undoManager)
        return .result()
    }

    /// Locks an element, or unlocks it as one undo step. Unlocking acts on the lock that
    /// holds it: the locked groups above it are unlocked too, as the popover and the Format
    /// panel do, or a member locked only by its group would stay locked (ruling D). Locking
    /// locks only the element.
    @MainActor
    static func setLocked(_ locked: Bool, _ ref: DesignStore.ElementRef, in model: AppModel, undoManager: UndoManager?) throws {
        guard model.store.placed(ref) != nil else { throw LayerIntentError.elementNotFound }
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
        let (model, ref, _) = try await DesignActions.nodeOrSelected(element)
        try Self.rename(ref, to: name, in: model, undoManager: undoManager)
        return .result()
    }

    /// Names the node, or takes its name away for a name of nothing but space, as one step, "Rename". Throws
    /// `elementNotFound` when it has gone.
    @MainActor
    static func rename(_ ref: DesignStore.ElementRef, to name: String, in model: AppModel, undoManager: UndoManager?) throws {
        guard model.store.placed(ref) != nil else { throw LayerIntentError.elementNotFound }
        let isBlank = name.trimmingCharacters(in: .whitespaces).isEmpty
        DesignActions.edit(model, undoManager: undoManager, actionName: "Rename") {
            model.store.update(ref.element) { $0.name = isBlank ? nil : name }
        }
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
        let (model, ref, _) = try await DesignActions.node(element)
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
