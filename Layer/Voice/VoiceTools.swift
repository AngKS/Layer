import Foundation
@_weakLinked import FoundationModels

/// What a spoken command can do to a design. Each method does one thing and answers with
/// one short line saying what it did, or why it couldn't, which is both what the model is
/// told and what the call's pill shows.
///
/// Screens and elements are named by their handles (`VoiceHandles`). The tools below are
/// written against this protocol rather than the app, so that the same tools can be
/// measured against a model with nothing but a recorder behind them.
protocol VoiceActing: AnyObject, Sendable {
    /// `device` is the person's word for the device, such as iPad or webpage; nil for the design's usual one.
    @MainActor func createScreen(name: String?, description: String, device: String?) async throws -> String
    @MainActor func addElement(screen: String?, kind: String, text: String?, look: String?, relation: String?, target: String?) -> String
    @MainActor func stackElements(elements: String, direction: String) -> String
    @MainActor func placeElement(element: String, relation: String, target: String) -> String
    @MainActor func setText(element: String, text: String) -> String
    @MainActor func styleElement(element: String, look: String) -> String
    @MainActor func moveElement(element: String, x: String?, y: String?, width: String?, height: String?, takeOut: String?) -> String
    /// `angle` is where to turn it to; `by` is how far to turn it from where it is. Both in degrees, clockwise.
    @MainActor func rotateElement(element: String, angle: String?, by: String?) -> String
    @MainActor func alignElement(element: String, alignment: String) -> String
    @MainActor func duplicateElement(element: String) -> String
    /// `named` is the person's own word for what is to go. See `VoiceNaming`.
    @MainActor func deleteElement(element: String, named: String?) -> String
    @MainActor func renameScreen(screen: String, name: String) -> String
    @MainActor func deleteScreen(screen: String, named: String?) -> String
    /// `screen` nil, or an element's handle, is the screen pointed at.
    @MainActor func tidyScreen(screen: String?) -> String
    @MainActor func changeScreenDevice(screen: String?, device: String) -> String
    /// `elements`: handles, comma separated (two or more; one for a card). `shape`: group, row, column, grid or card.
    @MainActor func groupElements(elements: String, as shape: String) -> String
    /// `target`: a container's E handle or a screen's S handle. Nil `layout` keeps the kind; nil `spacing` keeps it.
    @MainActor func setLayout(target: String, layout: String?, spacing: String?) -> String
    @MainActor func ungroup(element: String) -> String
    /// `position`: before or after; above and left of read as before, below and right of as after.
    @MainActor func reorder(element: String, position: String, target: String) -> String
    @MainActor func show(target: String) -> String
    @MainActor func pan(direction: String) -> String
    @MainActor func zoom(to level: String) -> String
    @MainActor func undo() -> String
    @MainActor func redo() -> String
    @MainActor func endCall() -> String
}

extension VoiceActing {
    /// Makes a screen on whichever device what was said names, or the canvas's own.
    @MainActor func createScreen(name: String?, description: String) async throws -> String {
        try await createScreen(name: name, description: description, device: nil)
    }

    /// Adds an element where new elements go: below the rest.
    @MainActor func addElement(screen: String?, kind: String, text: String?, look: String?) -> String {
        addElement(screen: screen, kind: kind, text: text, look: look, relation: nil, target: nil)
    }

    /// Moves or resizes a thing, taking nothing out of the row, column or grid it is in.
    @MainActor func moveElement(element: String, x: String?, y: String?, width: String?, height: String?) -> String {
        moveElement(element: element, x: x, y: y, width: width, height: height, takeOut: nil)
    }
}

/// Whether the word a person used for something fits the thing a model took it to mean.
///
/// Asked about something that isn't on the canvas, a small model will sometimes act on
/// something that is: measured, "make the dropdown bigger" deleted a button. Most such
/// slips are plain to see and one "undo" away. A delete is the one that isn't let
/// through: the model passes on the person's own word, and the delete goes ahead only if
/// every word of it that names anything is one of the thing's own.
///
/// Words that only point at a thing, or say where it is, which one it is or what it is
/// like, name nothing and are passed over: "the big blue button on the left" names a
/// button, and "screen 2" names nothing at all. So the guard catches a wrong kind of
/// thing and a wrong label, and leaves the choice among things of the right kind to the model.
enum VoiceNaming {
    private static let notNaming: Set<String> = [
        // Pointing at it.
        "the", "a", "an", "my", "our", "this", "that", "these", "those", "it", "its", "one", "thing", "element", "item",
        "selected", "selection", "current", "screen", "page", "view", "other", "new", "old", "newest", "latest", "last",
        "on", "in", "of", "at", "to", "here", "there", "please", "whole", "entire", "all",
        // Where it is.
        "top", "bottom", "left", "right", "middle", "centre", "center", "upper", "lower", "above", "below", "under", "next",
        // Which one it is.
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "number",
        "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        // What it is like.
        "big", "bigger", "biggest", "large", "larger", "largest", "small", "smaller", "smallest", "little", "tiny", "huge",
        "wide", "narrow", "tall", "short", "long", "bold", "dark", "light", "bright",
        "black", "white", "gray", "grey", "red", "orange", "yellow", "green", "blue", "purple", "pink", "teal", "brown",
        "mint", "indigo", "cyan", "accent",
    ]

    /// - Parameters:
    ///   - named: What the person called it.
    ///   - names: What a thing of its kind is called, such as "button" and "cta".
    ///   - words: The words on it, or its own name.
    static func fits(_ named: String, names: [String], words: String) -> Bool {
        let said = tokens(named)
        // The thing's own words, and each pair of them run together: speech recognition
        // writes "login" or "log in" as it pleases.
        let phrases = (names + [words]).map(tokens)
        var own = Set(phrases.joined().map(singular))
        for phrase in phrases {
            for (one, next) in zip(phrase, phrase.dropFirst()) { own.insert(one + next) }
        }
        var isOwn = said.map { own.contains($0) || own.contains(singular($0)) }
        // And the other way about: two words said where the thing has one.
        for index in said.indices.dropLast() where own.contains(said[index] + said[index + 1]) {
            isOwn[index] = true
            isOwn[index + 1] = true
        }
        return said.indices.allSatisfy { isOwn[$0] || namesNothing(said[$0]) }
    }

    private static func namesNothing(_ word: String) -> Bool {
        notNaming.contains(word) || notNaming.contains(singular(word)) || word.allSatisfy(\.isNumber)
    }

    /// The words of some text, in lower case.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// A word with a plural's "s" taken off, so that "buttons" is "button".
    private static func singular(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }
}

/// The tools a model is handed during a call. There are few of them, each with a few flat
/// arguments, because the smallest model that has to use them is the on-device one.
enum VoiceTools {
    /// `canEndCall` is false for the pencil's call, which has no voice mode to end: it
    /// stays up for the next squeeze, and a model handed the tool still said it hung up.
    static func all(_ actor: any VoiceActing, canEndCall: Bool = true) -> [any Tool] {
        let tools: [any Tool] = [
            CreateScreenTool(actor: actor), AddElementTool(actor: actor), SetTextTool(actor: actor),
            StyleElementTool(actor: actor), MoveElementTool(actor: actor), RotateElementTool(actor: actor), AlignElementTool(actor: actor),
            StackElementsTool(actor: actor), PlaceElementTool(actor: actor), DuplicateElementTool(actor: actor), DeleteElementTool(actor: actor),
            GroupElementsTool(actor: actor), SetLayoutTool(actor: actor), UngroupTool(actor: actor), ReorderTool(actor: actor),
            RenameScreenTool(actor: actor), DeleteScreenTool(actor: actor), TidyScreenTool(actor: actor), ChangeScreenDeviceTool(actor: actor),
            ShowTool(actor: actor), PanTool(actor: actor), ZoomTool(actor: actor),
            UndoTool(actor: actor), RedoTool(actor: actor),
        ]
        return canEndCall ? tools + [EndCallTool(actor: actor)] : tools
    }

    /// What the on-device model is handed with a screen to edit: every tool but `setLayout` and `reorder`. Measured with
    /// all of them, its profile with one screen was 3,578 tokens of its 8,192, over the 3,400 allowed it (plan 6, Task 8:
    /// "Structure tools (plan 6)" in docs/benchmarks/voice-on-device.md).
    static func compact(_ actor: any VoiceActing, canEndCall: Bool = true) -> [any Tool] {
        all(actor, canEndCall: canEndCall).filter { !($0 is SetLayoutTool) && !($0 is ReorderTool) }
    }

    /// With no screens there is nothing to edit, so a model is spared the tools that edit.
    static func forEmptyCanvas(_ actor: any VoiceActing, canEndCall: Bool = true) -> [any Tool] {
        let tools: [any Tool] = [
            CreateScreenTool(actor: actor), ShowTool(actor: actor), ZoomTool(actor: actor),
            UndoTool(actor: actor), RedoTool(actor: actor),
        ]
        return canEndCall ? tools + [EndCallTool(actor: actor)] : tools
    }

    /// What the pill says while a tool runs.
    static func step(for tool: String) -> String {
        switch tool {
        case "createScreen": "Writing a screen…"
        case "addElement": "Adding…"
        case "setText": "Rewording…"
        case "styleElement": "Restyling…"
        case "moveElement": "Resizing…"
        case "rotateElement": "Turning…"
        case "alignElement": "Aligning…"
        case "stackElements": "Stacking…"
        case "placeElement": "Placing…"
        case "duplicateElement": "Duplicating…"
        case "deleteElement", "deleteScreen": "Deleting…"
        case "renameScreen": "Renaming…"
        case "tidyScreen": "Tidying…"
        case "changeScreenDevice": "Changing the device…"
        case "groupElements": "Grouping…"
        case "setLayout": "Changing the layout…"
        case "ungroup": "Ungrouping…"
        case "reorder": "Reordering…"
        case "show": "Showing…"
        case "pan": "Moving the view…"
        case "zoom": "Zooming…"
        case "undo": "Undoing…"
        case "redo": "Redoing…"
        case "endCall": "Hanging up…"
        default: "Working…"
        }
    }
}

struct CreateScreenTool: Tool {
    let actor: any VoiceActing
    let name = "createScreen"
    let description = "Adds a new screen and designs it from a description, such as “a simple login screen”. Use it for any request for a new screen or page, on any device."

    @Generable
    struct Arguments {
        @Guide(description: "A short name for the screen, such as Login or Checkout.")
        var name: String?
        @Guide(description: "What the screen is for and what should be on it, in the person's own words.")
        var description: String
        @Guide(description: "Only if the person names one: iPhone, iPad, Mac, or webpage for a web page or website, or one of this design's own devices by name.")
        var device: String?
    }

    func call(arguments: Arguments) async throws -> String {
        try await actor.createScreen(name: arguments.name, description: arguments.description, device: arguments.device)
    }
}

struct AddElementTool: Tool {
    let actor: any VoiceActing
    let name = "addElement"
    let description = "Adds one element to a screen, below what is already there."

    @Generable
    struct Arguments {
        @Guide(description: "The screen's handle, such as S1. Leave out for the screen being looked at.")
        var screen: String?
        @Guide(description: "One of: title, body, button, text field, image, symbol, divider, toggle, checkbox, radio, progress, avatar, text.")
        var kind: String
        @Guide(description: "The words on it, such as Sign in. For a symbol, the SF Symbol's name.")
        var text: String?
        @Guide(description: "Optional look words, comma separated, such as: blue, bold, 18pt, radius 12, text white, bordered.")
        var look: String?
        @Guide(description: "Where to put it, if the person said it goes next to another element: below, above, left of or right of.")
        var relation: String?
        @Guide(description: "The handle of that other element, such as E1.")
        var target: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.addElement(
            screen: arguments.screen, kind: arguments.kind, text: arguments.text, look: arguments.look,
            relation: arguments.relation, target: arguments.target
        )
    }
}

struct SetTextTool: Tool {
    let actor: any VoiceActing
    let name = "setText"
    let description = "Replaces the words an element shows with different words, such as changing Sign in to Continue. To rewrite words in a style, write the new words yourself. Not for text colour, bold or size: those are styleElement."

    @Generable
    struct Arguments {
        @Guide(description: "The element's handle, such as E2.")
        var element: String
        @Guide(description: "The new words, exactly as they should appear.")
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.setText(element: arguments.element, text: arguments.text)
    }
}

struct StyleElementTool: Tool {
    let actor: any VoiceActing
    let name = "styleElement"
    let description = "Changes how an element looks: its colour, its text colour, bold, text size, corners, border, shadow, or a toggle's state."

    @Generable
    struct Arguments {
        @Guide(description: "The element's handle, such as E2.")
        var element: String
        @Guide(description: "The text colour: the colour of its words, such as blue. Leave out to keep it.")
        var textColour: String?
        @Guide(description: "Other look words, comma separated. A colour name or hex sets the fill; also bold, 18pt, radius 12, border red, shadow, opacity 50%, on, off, bordered, plain, left, centre, right (text alignment).")
        var look: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.styleElement(element: arguments.element, look: Self.look(arguments.look, textColour: arguments.textColour))
    }

    /// The look words as one list. The text colour has an argument of its own because a
    /// small model takes "text colour" for the words themselves unless it is spelt out.
    static func look(_ look: String?, textColour: String?) -> String {
        let colour = textColour?.trimmingCharacters(in: .whitespaces) ?? ""
        return [look ?? "", colour.isEmpty ? "" : "text \(colour)"]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: ", ")
    }
}

struct MoveElementTool: Tool {
    let actor: any VoiceActing
    let name = "moveElement"
    let description = "Moves or resizes an element. Each value is in points, or a share of the screen such as 50%. Leave out what should stay as it is. “Half width” is width 50%."

    @Generable
    struct Arguments {
        @Guide(description: "The element's handle, such as E2.")
        var element: String
        @Guide(description: "Left edge, from the screen's left edge.")
        var x: String?
        @Guide(description: "Top edge, from the screen's top edge.")
        var y: String?
        @Guide(description: "Width, such as 180 or 50%.")
        var width: String?
        @Guide(description: "Height, such as 44 or 10%.")
        var height: String?
        @Guide(description: "Only to take it out of the row, column or grid it is in: yes. Give x and y for where it goes.")
        var takeOut: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.moveElement(element: arguments.element, x: arguments.x, y: arguments.y, width: arguments.width, height: arguments.height,
                                takeOut: arguments.takeOut)
    }
}

struct RotateElementTool: Tool {
    let actor: any VoiceActing
    let name = "rotateElement"
    let description = "Turns an element to an angle, or by an amount, in degrees clockwise. A negative amount turns it anticlockwise. “Straighten” is angle 0."

    @Generable
    struct Arguments {
        @Guide(description: "The element's handle, such as E2.")
        var element: String
        @Guide(description: "The angle to turn it to, such as 45. 0 is upright.")
        var angle: String?
        @Guide(description: "How far to turn it from where it is, such as 15 or -15.")
        var by: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.rotateElement(element: arguments.element, angle: arguments.angle, by: arguments.by)
    }
}

struct AlignElementTool: Tool {
    let actor: any VoiceActing
    let name = "alignElement"
    let description = "Lines up specific elements: one with an edge or the centre of its screen, or several with one another. “Centre” and “middle” mean side to side. Not for tidying a whole screen."

    @Generable
    struct Arguments {
        @Guide(description: "The element's handle, such as E3. Two or more, comma separated, are lined up with one another.")
        var element: String
        @Guide(description: "One of: left, centre, right, top, bottom, or vertical centre for centred from top to bottom.")
        var alignment: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.alignElement(element: arguments.element, alignment: arguments.alignment)
    }
}

struct StackElementsTool: Tool {
    let actor: any VoiceActing
    let name = "stackElements"
    let description = "Puts several elements one after another so that none overlap: in a column, one under another, or in a row, side by side."

    @Generable
    struct Arguments {
        @Guide(description: "The handles of the elements, comma separated, such as E3, E4, E5.")
        var elements: String
        @Guide(description: "column or row.")
        var direction: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.stackElements(elements: arguments.elements, direction: arguments.direction)
    }
}

struct PlaceElementTool: Tool {
    let actor: any VoiceActing
    let name = "placeElement"
    let description = "Puts an element next to another element: below, above, left of or right of it. Use it for “below the title”, “beside the image” and “under the button”. For an edge of the screen, use alignElement."

    @Generable
    struct Arguments {
        @Guide(description: "The handle of the element to move, such as E3.")
        var element: String
        @Guide(description: "below, above, left of or right of.")
        var relation: String
        @Guide(description: "The handle of the element it goes next to, such as E1.")
        var target: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.placeElement(element: arguments.element, relation: arguments.relation, target: arguments.target)
    }
}

struct DuplicateElementTool: Tool {
    let actor: any VoiceActing
    let name = "duplicateElement"
    let description = "Makes a copy of an element on the same screen."

    @Generable
    struct Arguments {
        @Guide(description: "The element's handle, such as E2.")
        var element: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.duplicateElement(element: arguments.element)
    }
}

struct DeleteElementTool: Tool {
    let actor: any VoiceActing
    let name = "deleteElement"
    let description = "Removes an element from its screen."

    @Generable
    struct Arguments {
        @Guide(description: "The element's handle, such as E2.")
        var element: String
        @Guide(description: "The person's own word for what to delete, such as image or sign in button.")
        var named: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.deleteElement(element: arguments.element, named: arguments.named)
    }
}

struct RenameScreenTool: Tool {
    let actor: any VoiceActing
    let name = "renameScreen"
    let description = "Gives a screen a new name."

    @Generable
    struct Arguments {
        @Guide(description: "The screen's handle, such as S1.")
        var screen: String
        @Guide(description: "The new name.")
        var name: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.renameScreen(screen: arguments.screen, name: arguments.name)
    }
}

struct DeleteScreenTool: Tool {
    let actor: any VoiceActing
    let name = "deleteScreen"
    let description = "Removes a whole screen and everything on it."

    @Generable
    struct Arguments {
        @Guide(description: "The screen's handle, such as S2.")
        var screen: String
        @Guide(description: "The person's own words for the screen to delete, such as settings screen or this screen.")
        var named: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.deleteScreen(screen: arguments.screen, named: arguments.named)
    }
}

struct TidyScreenTool: Tool {
    let actor: any VoiceActing
    let name = "tidyScreen"
    let description = "Tidies a whole screen's layout: consistent margins, spacing and alignment, keeping the order. Use for “align everything”, “tidy up”, “space things out”, “make it look nice” and “clean up the layout”, even with one element pointed at."

    @Generable
    struct Arguments {
        @Guide(description: "The screen's handle, such as S1. Leave out for this screen.")
        var screen: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.tidyScreen(screen: arguments.screen)
    }
}

struct ChangeScreenDeviceTool: Tool {
    let actor: any VoiceActing
    let name = "changeScreenDevice"
    let description = "Makes a screen another device's, such as an iPad screen, and lays it out for that size."

    @Generable
    struct Arguments {
        @Guide(description: "The screen's handle, such as S1. Leave out for this screen.")
        var screen: String?
        @Guide(description: "iPhone, iPad, Mac or webpage, or one of this design's own devices by name.")
        var device: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.changeScreenDevice(screen: arguments.screen, device: arguments.device)
    }
}

struct GroupElementsTool: Tool {
    let actor: any VoiceActing
    let name = "groupElements"
    let description = "Puts elements in a new group, row, column, grid or card."

    @Generable
    struct Arguments {
        @Guide(description: "The handles, comma separated, such as E3, E4. They must be in the same place.")
        var elements: String
        @Guide(description: "group, row, column, grid or card.")
        var `as`: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.groupElements(elements: arguments.elements, as: arguments.as)
    }
}

struct SetLayoutTool: Tool {
    let actor: any VoiceActing
    let name = "setLayout"
    let description = "Changes how a row, column, grid, card, group or screen lays out what it holds."

    @Generable
    struct Arguments {
        @Guide(description: "A row, column, grid, card or group, such as E5, or a screen, such as S1.")
        var target: String
        @Guide(description: "free, row, column, grid of 2 (any number), or overlay; may add left, centred, right, top, bottom or stretched. Leave out to keep it.")
        var layout: String?
        @Guide(description: "The gap between the things in it, in points, such as 16. Leave out to keep it.")
        var spacing: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.setLayout(target: arguments.target, layout: arguments.layout, spacing: arguments.spacing)
    }
}

struct UngroupTool: Tool {
    let actor: any VoiceActing
    let name = "ungroup"
    let description = "Takes a row, column, grid, card or group apart, leaving what it held in place."

    @Generable
    struct Arguments {
        @Guide(description: "The row, column, grid, card or group to take apart, such as E5.")
        var element: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.ungroup(element: arguments.element)
    }
}

struct ReorderTool: Tool {
    let actor: any VoiceActing
    let name = "reorder"
    let description = "Moves an element before or after another in the row, column, grid or group they share."

    @Generable
    struct Arguments {
        @Guide(description: "The element to move, such as E7.")
        var element: String
        @Guide(description: "before or after.")
        var position: String
        @Guide(description: "The element it goes before or after, such as E6.")
        var target: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.reorder(element: arguments.element, position: arguments.position, target: arguments.target)
    }
}

struct ShowTool: Tool {
    let actor: any VoiceActing
    let name = "show"
    let description = "Moves the canvas to show a screen or an element, or everything. Use it for “show me”, “go to” and “pan to”."

    @Generable
    struct Arguments {
        @Guide(description: "A handle, such as S2 or E7, or the word all.")
        var target: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.show(target: arguments.target)
    }
}

struct PanTool: Tool {
    let actor: any VoiceActing
    let name = "pan"
    let description = "Moves the view of the canvas up, down, left or right, when no screen or element is named. Use it for “move down a bit”, “scroll up” and “go left”."

    @Generable
    struct Arguments {
        @Guide(description: "up, down, left or right. Add “a bit” for a small move.")
        var direction: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.pan(direction: arguments.direction)
    }
}

struct ZoomTool: Tool {
    let actor: any VoiceActing
    let name = "zoom"
    let description = "Zooms the canvas."

    @Generable
    struct Arguments {
        @Guide(description: "One of: in, out, fit, or a percentage such as 150.")
        var level: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actor.zoom(to: arguments.level)
    }
}

struct UndoTool: Tool {
    let actor: any VoiceActing
    let name = "undo"
    let description = "Undoes the last change to the design. Use it for “undo that” and “put it back”."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await actor.undo()
    }
}

struct RedoTool: Tool {
    let actor: any VoiceActing
    let name = "redo"
    let description = "Redoes the change that was last undone."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await actor.redo()
    }
}

struct EndCallTool: Tool {
    let actor: any VoiceActing
    let name = "endCall"
    let description = "Ends voice mode. Use it only when the person says they are finished, such as “that's all” or “we're done”."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await actor.endCall()
    }
}
