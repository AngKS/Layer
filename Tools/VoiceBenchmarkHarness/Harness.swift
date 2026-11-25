// Measures how well the on-device Apple Intelligence model carries out spoken commands
// with Layer's voice tools. Apple Intelligence can't answer in the iPadOS Simulator, so
// this runs natively on the Mac, compiling the app's own rules, tools and canvas picture
// (see run.sh) with a recorder in place of the design.
//
// Each command is put to a fresh session set up as the app's on-device profile is: the
// compact rules, the compact picture of the canvas, the tools that fit the canvas, and a
// short limit on the reply. What the model asks the tools to do is recorded and graded.
//
// `latency` instead runs a call's commands in a row in one warmed session, the canvas
// changing as they go, and times each: to the first tool, from the last tool to the
// model's last word (its "Done"), and the whole.
import Foundation
// Imported as the app's own files import it, which the compiler wants to be the same throughout.
@_weakLinked import FoundationModels

/// Writes down what the model asks for, and answers as the app would.
@MainActor
final class Recorder: VoiceActing {
    struct Call: Equatable, CustomStringConvertible {
        var tool: String
        var arguments: [String: String]

        var description: String {
            "\(tool)(\(arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")))"
        }
    }

    private(set) var calls: [Call] = []
    /// How many of those calls the app would have turned down, changing nothing.
    private(set) var refusals = 0
    /// The canvas, changed as the app would change it, so that a command in a row sees
    /// what the one before it did.
    var picture: CanvasPicture
    /// When the first and the last tool of the command under way ran.
    var firstToolAt: ContinuousClock.Instant?
    var lastToolAt: ContinuousClock.Instant?

    /// What a thing of each kind is called, as the app's own table has it.
    private static let kindNames: [String: [String]] = [
        "title": ["title", "heading", "header", "headline"], "button": ["button", "primary button", "cta"],
        "image": ["image", "photo", "picture", "hero", "banner"], "avatar": ["avatar", "profile picture", "profile photo"],
        "toggle": ["toggle", "switch"],
    ]

    init(picture: CanvasPicture) {
        self.picture = picture
    }

    private func note(_ tool: String, _ arguments: [String: String?], saying line: String) -> String {
        calls.append(Call(tool: tool, arguments: arguments.compactMapValues { $0 }))
        let now = ContinuousClock.now
        if firstToolAt == nil { firstToolAt = now }
        lastToolAt = now
        return line
    }

    /// Changes an element as the app roughly would, so that the canvas text changes.
    private func change(_ handle: String, _ edit: (inout CanvasPicture.Element) -> Void) {
        for screen in picture.screens.indices {
            if let index = picture.screens[screen].elements.firstIndex(where: { $0.handle == handle }) {
                edit(&picture.screens[screen].elements[index])
                return
            }
        }
    }

    private var made = 20

    func createScreen(name: String?, description: String, device: String?) async throws -> String {
        note("createScreen", ["name": name, "description": description, "device": device], saying: "Made the screen as S9, with 6 elements.")
    }

    func tidyScreen(screen: String?) -> String {
        note("tidyScreen", ["screen": screen], saying: "Tidied the layout of \(screen ?? "the screen").")
    }

    func changeScreenDevice(screen: String?, device: String) -> String {
        note("changeScreenDevice", ["screen": screen, "device": device], saying: "Made \(screen ?? "the screen") a \(device) screen.")
    }

    func addElement(screen: String?, kind: String, text: String?, look: String?, relation: String?, target: String?) -> String {
        made += 1
        if !picture.screens.isEmpty {
            picture.screens[0].elements.append(.init(handle: "E\(made)", kind: kind, text: text ?? "", frame: CGRect(x: 20, y: 720, width: 353, height: 44)))
        }
        return note("addElement", ["screen": screen, "kind": kind, "text": text, "look": look], saying: "Added a \(kind) as E\(made).")
    }

    func setText(element: String, text: String) -> String {
        // As the app does: a colour on its own, in lower case, is the colour of the words.
        var words = text.trimmingCharacters(in: .whitespaces)
        if words == words.lowercased() {
            if words.hasPrefix("text ") { words = String(words.dropFirst(5)) }
            if Self.colours.contains(words) { return styleElement(element: element, look: "text \(words)") }
        }
        change(element) { $0.text = text }
        return note("setText", ["element": element, "text": text], saying: "Reworded \(element) to “\(text)”.")
    }

    private static let colours: Set<String> = ["black", "white", "gray", "grey", "red", "orange", "yellow", "green", "blue", "purple", "pink", "teal", "brown"]

    func styleElement(element: String, look: String) -> String {
        change(element) { $0.look.append(look) }
        return note("styleElement", ["element": element, "look": look], saying: "Restyled \(element).")
    }

    func moveElement(element: String, x: String?, y: String?, width: String?, height: String?, takeOut: String?) -> String {
        change(element) {
            guard var frame = $0.frame else { return }
            if width != nil { frame.size.width /= 2 }
            if height != nil { frame.size.height *= 2 }
            if y != nil { frame.origin.y = 60 }
            $0.frame = frame
        }
        return note("moveElement", ["element": element, "x": x, "y": y, "width": width, "height": height, "takeOut": takeOut], saying: "Resized \(element).")
    }

    func rotateElement(element: String, angle: String?, by: String?) -> String {
        // As the app does: the angle wins when both are given; both are clockwise degrees.
        change(element) { $0.rotation = Rotation.normalized(angle.flatMap(Double.init) ?? $0.rotation + (by.flatMap(Double.init) ?? 0)) }
        return note("rotateElement", ["element": element, "angle": angle, "by": by], saying: "Turned \(element).")
    }

    func alignElement(element: String, alignment: String) -> String {
        change(element) { $0.frame?.origin.x = 96 }
        return note("alignElement", ["element": element, "alignment": alignment], saying: "Aligned \(element) to the \(alignment).")
    }

    func duplicateElement(element: String) -> String {
        made += 1
        if let found = picture.screens.flatMap(\.elements).first(where: { $0.handle == element }), !picture.screens.isEmpty {
            var copy = found
            copy.handle = "E\(made)"
            copy.isSelected = false
            copy.frame?.origin.y += 60
            picture.screens[0].elements.append(copy)
        }
        return note("duplicateElement", ["element": element], saying: "Duplicated \(element) as E\(made).")
    }

    func deleteElement(element: String, named: String?) -> String {
        // The app's guard: a delete goes ahead only if the person's word fits the thing.
        if let named, let found = picture.screens.flatMap(\.elements).first(where: { $0.handle == element }),
           !VoiceNaming.fits(named, names: (Self.kindNames[found.kind] ?? [found.kind]) + (found.text.isEmpty ? [] : ["text", "words", "label"]), words: found.text) {
            refusals += 1
            return note("deleteElement", ["element": element, "named": named], saying: "There is no \(named) here. \(element) is the \(found.kind).")
        }
        for screen in picture.screens.indices { picture.screens[screen].elements.removeAll { $0.handle == element } }
        return note("deleteElement", ["element": element, "named": named], saying: "Deleted \(element).")
    }

    func renameScreen(screen: String, name: String) -> String {
        if let index = picture.screens.firstIndex(where: { $0.handle == screen }) { picture.screens[index].name = name }
        return note("renameScreen", ["screen": screen, "name": name], saying: "Renamed \(screen) to “\(name)”.")
    }

    func deleteScreen(screen: String, named: String?) -> String {
        if let named, let found = picture.screens.first(where: { $0.handle == screen }), !VoiceNaming.fits(named, names: [], words: found.name) {
            refusals += 1
            return note("deleteScreen", ["screen": screen, "named": named], saying: "There is no \(named) here. \(screen) is “\(found.name)”.")
        }
        picture.screens.removeAll { $0.handle == screen }
        return note("deleteScreen", ["screen": screen, "named": named], saying: "Deleted \(screen).")
    }

    func stackElements(elements: String, direction: String) -> String {
        note("stackElements", ["elements": elements, "direction": direction], saying: "Stacked the elements in a \(direction).")
    }

    func placeElement(element: String, relation: String, target: String) -> String {
        note("placeElement", ["element": element, "relation": relation, "target": target], saying: "Put \(element) \(relation) \(target).")
    }

    func groupElements(elements: String, as shape: String) -> String {
        made += 1
        return note("groupElements", ["elements": elements, "as": shape], saying: "Put \(elements) in a \(shape), E\(made).")
    }

    func setLayout(target: String, layout: String?, spacing: String?) -> String {
        let said = [layout, spacing.map { "spacing \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return note("setLayout", ["target": target, "layout": layout, "spacing": spacing], saying: "\(target) is now \(said).")
    }

    func ungroup(element: String) -> String {
        note("ungroup", ["element": element], saying: "Took what \(element) held out of it.")
    }

    func reorder(element: String, position: String, target: String) -> String {
        note("reorder", ["element": element, "position": position, "target": target], saying: "Moved \(element) \(position) \(target).")
    }

    func pan(direction: String) -> String {
        note("pan", ["direction": direction], saying: "Moved the view \(direction).")
    }

    func show(target: String) -> String {
        // Showing a screen puts it in view, which changes what the canvas says is in view.
        if picture.screens.contains(where: { $0.handle == target }) {
            for index in picture.screens.indices { picture.screens[index].visibleShare = picture.screens[index].handle == target ? 1 : 0 }
        }
        return note("show", ["target": target], saying: "Showing \(target).")
    }

    func zoom(to level: String) -> String {
        note("zoom", ["level": level], saying: "Zoomed \(level).")
    }

    func undo() -> String {
        note("undo", [:], saying: "Undid the last change.")
    }

    func redo() -> String {
        note("redo", [:], saying: "Redid the last change.")
    }

    func endCall() -> String {
        note("endCall", [:], saying: "Hanging up.")
    }
}

/// The canvases the commands are spoken over.
enum Canvas: String {
    case empty, one, three
    /// One screen pointed at with the pencil, as a whole: the screen selected.
    case screenPointed
    /// One screen, the sign in button pointed at with the pencil.
    case buttonPointed
    /// One screen, the title and the image selected together.
    case twoPointed
    /// One iPad-sized screen, pointed at as a whole.
    case iPadPointed
    /// One screen holding containers, as the app tells them since plan 6: a card, a row and a column (`structure`).
    case nested
    /// The same, with its two text fields selected.
    case fieldsSelected

    private static let login = CanvasPicture.Screen(
        handle: "S1", name: "Login", size: CGSize(width: 393, height: 852), visibleShare: 1,
        elements: [
            .init(handle: "E1", kind: "title", text: "Welcome back", frame: CGRect(x: 20, y: 75, width: 353, height: 41)),
            .init(handle: "E2", kind: "button", text: "Sign in", frame: CGRect(x: 20, y: 420, width: 353, height: 50), look: ["colour accent"], isSelected: true),
            .init(handle: "E3", kind: "image", text: "", frame: CGRect(x: 20, y: 500, width: 200, height: 200)),
        ]
    )

    /// E2 a free card, E5 a row and E10 a column, each holding two things, with two fields between them.
    private static let account = CanvasPicture.Screen(
        handle: "S1", name: "Account", size: CGSize(width: 393, height: 852), visibleShare: 1,
        elements: [
            .init(handle: "E1", kind: "title", text: "Account", frame: CGRect(x: 20, y: 60, width: 353, height: 41)),
            .init(handle: "E2", kind: "card", text: "", frame: CGRect(x: 20, y: 121, width: 353, height: 128), isContainer: true, children: [
                .init(handle: "E3", kind: "text", text: "About me", frame: CGRect(x: 36, y: 137, width: 200, height: 24)),
                .init(handle: "E4", kind: "body", text: "Designing better experiences.", frame: CGRect(x: 36, y: 169, width: 321, height: 64)),
            ]),
            .init(handle: "E5", kind: "group", text: "", frame: CGRect(x: 20, y: 269, width: 143, height: 31), layout: "row, spacing 12, centred", isContainer: true, children: [
                .init(handle: "E6", kind: "text", text: "Wi-Fi", frame: CGRect(x: 20, y: 272, width: 80, height: 24)),
                .init(handle: "E7", kind: "toggle", text: "", frame: CGRect(x: 112, y: 269, width: 51, height: 31), look: ["colour green", "on"]),
            ]),
            .init(handle: "E8", kind: "text field", text: "Email", frame: CGRect(x: 20, y: 320, width: 353, height: 44)),
            .init(handle: "E9", kind: "text field", text: "Password", frame: CGRect(x: 20, y: 380, width: 353, height: 44)),
            .init(handle: "E10", kind: "group", text: "", frame: CGRect(x: 20, y: 460, width: 353, height: 82), layout: "column, spacing 12", isContainer: true, children: [
                .init(handle: "E11", kind: "button", text: "Sign in", frame: CGRect(x: 20, y: 460, width: 353, height: 50), look: ["colour accent"]),
                .init(handle: "E12", kind: "text", text: "Forgot password?", frame: CGRect(x: 20, y: 522, width: 150, height: 20)),
            ]),
        ]
    )

    var picture: CanvasPicture {
        switch self {
        case .empty:
            return .empty
        case .nested:
            return CanvasPicture(screens: [Self.account])
        case .fieldsSelected:
            var account = Self.account
            account.elements[3].isSelected = true
            account.elements[4].isSelected = true
            return CanvasPicture(screens: [account])
        case .one:
            return CanvasPicture(screens: [Self.login])
        case .three:
            var login = Self.login
            login.visibleShare = 0
            login.elements[1].isSelected = false
            let profile = CanvasPicture.Screen(
                handle: "S2", name: "Profile", size: CGSize(width: 393, height: 852), visibleShare: 1,
                elements: [
                    .init(handle: "E4", kind: "avatar", text: "", frame: CGRect(x: 156, y: 80, width: 80, height: 80), look: ["colour accent"]),
                    .init(handle: "E5", kind: "title", text: "Alex Rivera", frame: CGRect(x: 20, y: 180, width: 353, height: 41)),
                    .init(handle: "E6", kind: "button", text: "Edit profile", frame: CGRect(x: 20, y: 260, width: 353, height: 50), look: ["colour accent"]),
                ]
            )
            let settings = CanvasPicture.Screen(
                handle: "S3", name: "Settings", size: CGSize(width: 393, height: 852),
                elements: [
                    .init(handle: "E7", kind: "toggle", text: "", frame: CGRect(x: 320, y: 120, width: 51, height: 31), look: ["colour green", "on"]),
                    .init(handle: "E8", kind: "button", text: "Log out", frame: CGRect(x: 20, y: 700, width: 353, height: 50), look: ["colour red"]),
                ]
            )
            return CanvasPicture(screens: [login, profile, settings])
        case .screenPointed:
            var login = Self.login
            login.elements[1].isSelected = false
            login.isSelected = true
            return CanvasPicture(screens: [login])
        case .buttonPointed:
            return CanvasPicture(screens: [Self.login])
        case .twoPointed:
            var login = Self.login
            login.elements[1].isSelected = false
            login.elements[0].isSelected = true
            login.elements[2].isSelected = true
            return CanvasPicture(screens: [login])
        case .iPadPointed:
            var login = Self.login
            login.size = CGSize(width: 1024, height: 1366)
            login.elements[1].isSelected = false
            login.isSelected = true
            login.elements = login.elements.map { var element = $0; element.frame?.size.width = 984; return element }
            return CanvasPicture(screens: [login])
        }
    }
}

/// Where the pencil pointed as the command was said, which the app tells the model ahead
/// of the words (`VoiceAgent.canvasHint` and `thingHint`, copied here as the harness
/// doesn't compile the agent). The pencil's call has no tool to end it.
enum Pointing {
    /// At empty canvas.
    case canvas
    /// At what is selected in the canvas picture.
    case thing

    func hint(_ picture: CanvasPicture) -> String {
        switch self {
        case .canvas:
            return "(The person pointed at empty canvas: a description of a screen means a new screen there.)"
        case .thing:
            return "(The person is pointing at \(picture.selectionInWords ?? "nothing"). \"This\", \"it\", \"that\" and a change that names nothing mean what is pointed at, and nothing else.)"
        }
    }
}

/// One spoken command and what should come of it.
struct Case {
    var canvas: Canvas
    var command: String
    /// The tools that would be right. Empty where the right thing is to do nothing.
    var tools: [String]
    /// Whether the right tool was asked the right thing.
    var isRight: ([String: String]) -> Bool = { _ in true }
    /// Whether the command was kept out of the tuning of the rules.
    var isHeldBack = false
    /// Whether the command was written after the rules were settled, and only ever run to
    /// be counted.
    var isFresh = false
    /// Whether the command is one a person spoke to an iPad, written as it was heard.
    var isFromTheIPad = false
    /// Where the pencil pointed; nil for a command spoken in voice mode.
    var pointing: Pointing? = nil
}

private func has(_ key: String, _ words: String...) -> ([String: String]) -> Bool {
    { arguments in
        guard let value = arguments[key]?.lowercased() else { return false }
        return words.allSatisfy { value.contains($0.lowercased()) }
    }
}

private func both(_ one: @escaping ([String: String]) -> Bool, _ other: @escaping ([String: String]) -> Bool) -> ([String: String]) -> Bool {
    { one($0) && other($0) }
}

let cases: [Case] = [
    // An empty canvas: the examples in the request, and the little there is to do besides.
    Case(canvas: .empty, command: "I want a simple login screen", tools: ["createScreen"], isRight: has("description", "login")),
    Case(canvas: .empty, command: "Profile page with user settings", tools: ["createScreen"], isRight: has("description", "profile")),
    Case(canvas: .empty, command: "Membership page", tools: ["createScreen"], isRight: has("description", "membership")),
    Case(canvas: .empty, command: "Create a settings screen with a few toggles", tools: ["createScreen"], isRight: has("description", "settings")),
    Case(canvas: .empty, command: "Zoom out", tools: ["zoom"], isRight: has("level", "out")),
    Case(canvas: .empty, command: "That's all, thanks", tools: ["endCall"]),

    // One screen, with the button selected.
    Case(canvas: .one, command: "Make the button half width", tools: ["moveElement"], isRight: both(has("element", "E2"), has("width", "50"))),
    // The app takes "centre", "centrally" and "middle" alike as centred from side to side.
    Case(canvas: .one, command: "Align the image centrally", tools: ["alignElement"], isRight: { $0["element"] == "E3" && ["centre", "center", "centrally", "middle"].contains(($0["alignment"] ?? "").lowercased()) }),
    Case(canvas: .one, command: "Change the title's text colour to blue", tools: ["styleElement"], isRight: both(has("element", "E1"), has("look", "blue"))),
    Case(canvas: .one, command: "Make the title sound like a pirate", tools: ["setText"], isRight: { $0["element"] == "E1" && ($0["text"] ?? "Welcome back") != "Welcome back" }),
    Case(canvas: .one, command: "Make the sign in button green", tools: ["styleElement"], isRight: both(has("element", "E2"), has("look", "green"))),
    Case(canvas: .one, command: "Delete the image", tools: ["deleteElement"], isRight: has("element", "E3")),
    Case(canvas: .one, command: "Duplicate the button", tools: ["duplicateElement"], isRight: has("element", "E2")),
    Case(canvas: .one, command: "Add a text field for email", tools: ["addElement"], isRight: has("kind", "field")),
    Case(canvas: .one, command: "Make the title bold", tools: ["styleElement"], isRight: both(has("element", "E1"), has("look", "bold"))),
    Case(canvas: .one, command: "Change the button text to Continue", tools: ["setText"], isRight: both(has("element", "E2"), has("text", "continue"))),
    Case(canvas: .one, command: "Undo that", tools: ["undo"]),
    Case(canvas: .one, command: "Show me the whole canvas", tools: ["show", "zoom"], isRight: { ($0["target"] ?? $0["level"] ?? "").lowercased().contains("all") || ($0["level"] ?? "").lowercased().contains("fit") }),
    Case(canvas: .one, command: "Rename this screen to Sign In", tools: ["renameScreen"], isRight: both(has("screen", "S1"), has("name", "sign in"))),
    Case(canvas: .one, command: "Make it blue", tools: ["styleElement"], isRight: both(has("element", "E2"), has("look", "blue"))),
    Case(canvas: .one, command: "Move the image to the top", tools: ["alignElement", "moveElement"], isRight: { $0["element"] == "E3" && (($0["alignment"] ?? "").lowercased() == "top" || $0["y"] != nil) }),
    Case(canvas: .one, command: "Make the slider wider", tools: []),
    Case(canvas: .one, command: "Add a profile screen", tools: ["createScreen"], isRight: has("description", "profile")),

    // Three screens, the second in view.
    Case(canvas: .three, command: "Show me the first screen", tools: ["show"], isRight: has("target", "S1")),
    Case(canvas: .three, command: "Show me the newest screen", tools: ["show"], isRight: has("target", "S3")),
    Case(canvas: .three, command: "Go to the login screen", tools: ["show"], isRight: has("target", "S1")),
    Case(canvas: .three, command: "Show me the settings screen", tools: ["show"], isRight: has("target", "S3")),
    Case(canvas: .three, command: "Make the edit profile button red", tools: ["styleElement"], isRight: both(has("element", "E6"), has("look", "red"))),
    Case(canvas: .three, command: "Delete the settings screen", tools: ["deleteScreen"], isRight: has("screen", "S3")),
    Case(canvas: .three, command: "Zoom in", tools: ["zoom"], isRight: has("level", "in")),

    // Held back: written after the rules were last changed and never used to change them,
    // so they say whether a change helped in general or only on the commands above.
    Case(canvas: .one, command: "Make the title's text red", tools: ["styleElement"], isRight: both(has("element", "E1"), has("look", "red")), isHeldBack: true),
    Case(canvas: .one, command: "Centre the button", tools: ["alignElement"], isRight: { $0["element"] == "E2" && ["centre", "center", "centrally", "middle"].contains(($0["alignment"] ?? "").lowercased()) }, isHeldBack: true),
    Case(canvas: .one, command: "Make the dropdown bigger", tools: [], isHeldBack: true),
    Case(canvas: .one, command: "Change the sign in button's text colour to white", tools: ["styleElement"], isRight: both(has("element", "E2"), has("look", "text", "white")), isHeldBack: true),
    Case(canvas: .three, command: "Make the map taller", tools: [], isHeldBack: true),
    Case(canvas: .three, command: "Change the name to Sam Lee", tools: ["setText"], isRight: both(has("element", "E5"), has("text", "sam lee")), isHeldBack: true),
    Case(canvas: .three, command: "Put the avatar on the left", tools: ["alignElement", "moveElement"], isRight: { $0["element"] == "E4" && (($0["alignment"] ?? "").lowercased() == "left" || $0["x"] != nil) }, isHeldBack: true),
    Case(canvas: .empty, command: "Give me a checkout page", tools: ["createScreen"], isRight: has("description", "checkout"), isHeldBack: true),

    // Fresh: written after the last change to the rules, the tools and the app's guards,
    // and never used to change any of them. The score on these is the one to believe.
    Case(canvas: .one, command: "Make the button green", tools: ["styleElement"], isRight: both(has("element", "E2"), has("look", "green")), isFresh: true),
    Case(canvas: .one, command: "Delete the image", tools: ["deleteElement"], isRight: has("element", "E3"), isFresh: true),
    Case(canvas: .one, command: "Make the checkbox blue", tools: [], isFresh: true),
    Case(canvas: .one, command: "Move the image to the top", tools: ["alignElement", "moveElement"], isRight: { $0["element"] == "E3" && (($0["alignment"] ?? "").lowercased() == "top" || $0["y"] != nil) }, isFresh: true),
    Case(canvas: .one, command: "Rename this screen to Welcome", tools: ["renameScreen"], isRight: both(has("screen", "S1"), has("name", "welcome")), isFresh: true),
    Case(canvas: .one, command: "Add a text field for the email", tools: ["addElement"], isRight: has("kind", "field"), isFresh: true),
    Case(canvas: .three, command: "Go to the settings screen", tools: ["show"], isRight: has("target", "S3"), isFresh: true),
    Case(canvas: .three, command: "Make the avatar twice as big", tools: ["moveElement"], isRight: { $0["element"] == "E4" && ($0["width"] != nil || $0["height"] != nil) }, isFresh: true),
    Case(canvas: .three, command: "Turn the toggle off", tools: ["styleElement"], isRight: both(has("element", "E7"), has("look", "off")), isFresh: true),
    Case(canvas: .three, command: "Delete the log out button", tools: ["deleteElement"], isRight: has("element", "E8"), isFresh: true),
    Case(canvas: .three, command: "Undo that", tools: ["undo"], isFresh: true),
    Case(canvas: .empty, command: "Build me an onboarding screen", tools: ["createScreen"], isRight: has("description", "onboarding"), isFresh: true),

    // Spoken to an iPad on 2026-11-18, as the recogniser heard them, and run here after
    // the tools were changed for what that session showed: panning, stacking, and a
    // name for a new screen. Run once and counted as they came.
    Case(canvas: .empty, command: "Make the privacy statement screen.", tools: ["createScreen"], isRight: has("name", "privacy"), isFromTheIPad: true),
    Case(canvas: .three, command: "Now give me another screen for cashier.", tools: ["createScreen"], isRight: has("name", "cashier"), isFromTheIPad: true),
    Case(canvas: .one, command: "Can you move down a bit?", tools: ["pan", "show"], isRight: { ($0["direction"] ?? $0["target"] ?? "").lowercased().contains("down") }, isFromTheIPad: true),
    Case(canvas: .one, command: "Zoom out the screen so I can see the view.", tools: ["zoom"], isRight: has("level", "out"), isFromTheIPad: true),
    Case(canvas: .one, command: "Stack the title, the button and the image into a column.", tools: ["stackElements"], isRight: { ($0["direction"] ?? "").lowercased().contains("column") && ["E1", "E2", "E3"].allSatisfy(($0["elements"] ?? "").contains) }, isFromTheIPad: true),
    Case(canvas: .one, command: "make the title bigger and red.", tools: ["styleElement"], isRight: both(has("element", "E1"), has("look", "red")), isFromTheIPad: true),
    Case(canvas: .one, command: "No, undo revert.", tools: ["undo"], isFromTheIPad: true),
    Case(canvas: .three, command: "Show me the 2nd screen.", tools: ["show"], isRight: has("target", "S2"), isFromTheIPad: true),
    Case(canvas: .three, command: "Show me the next screen.", tools: ["show"], isRight: has("target", "S3"), isFromTheIPad: true),
    // From the second session on the iPad, after placing and aligning together were added.
    Case(canvas: .one, command: "Move this image below the title.", tools: ["placeElement"], isRight: { $0["element"] == "E3" && $0["target"] == "E1" && ($0["relation"] ?? "").lowercased().contains("below") }, isFromTheIPad: true),
    Case(canvas: .one, command: "Put the image beside the button.", tools: ["placeElement"], isRight: { $0["element"] == "E3" && $0["target"] == "E2" }, isFromTheIPad: true),
    Case(canvas: .one, command: "Align the image and the title together.", tools: ["alignElement"], isRight: { ["E1", "E3"].allSatisfy(($0["element"] ?? "").contains) }, isFromTheIPad: true),
    // Heard wrongly or not clear. The right thing is to do nothing and say so.
    Case(canvas: .one, command: "Can you edit the image to be a section?", tools: [], isFromTheIPad: true),
    Case(canvas: .one, command: "make the baby photo title rate.", tools: [], isFromTheIPad: true),
]

/// The tools added on 2026-11-18 (`tidyScreen`, `changeScreenDevice`, and a device for
/// `createScreen`), with commands that must still go to the older tools. Run with
/// `newtools`, each several times. See "New tools (2026-11-18)" in the benchmark notes.
private func tidied(_ handles: String...) -> ([String: String]) -> Bool {
    { arguments in arguments["screen"].map { handles.contains($0) } ?? true }
}

private func device(_ words: String...) -> ([String: String]) -> Bool {
    { arguments in
        let said = (arguments["device"] ?? "").lowercased()
        return words.contains { said.contains($0) }
    }
}

private let centred: Set<String> = ["centre", "center", "centrally", "middle"]

let newToolCases: [Case] = {
    var list: [Case] = []
    for command in ["Align everything nicely", "Tidy this up", "Clean up the layout", "Make it look nice", "Space things out evenly"] {
        list.append(Case(canvas: .screenPointed, command: command, tools: ["tidyScreen"], isRight: tidied("S1"), pointing: .thing))
        list.append(Case(canvas: .buttonPointed, command: command, tools: ["tidyScreen"], isRight: tidied("S1", "E2"), pointing: .thing))
    }
    // As heard on the iPad before the tools were there.
    list.append(Case(canvas: .screenPointed, command: "Align everything in the layout nicely", tools: ["tidyScreen"], isRight: tidied("S1"), pointing: .thing))
    list.append(Case(canvas: .screenPointed, command: "Convert this screen into a iPad screen", tools: ["changeScreenDevice"], isRight: both(tidied("S1"), device("ipad")), pointing: .thing))
    list.append(Case(canvas: .screenPointed, command: "Convert this screen into an iPad screen", tools: ["changeScreenDevice"], isRight: both(tidied("S1"), device("ipad")), pointing: .thing))
    list.append(Case(canvas: .screenPointed, command: "Make this a Mac screen", tools: ["changeScreenDevice"], isRight: both(tidied("S1"), device("mac")), pointing: .thing))
    list.append(Case(canvas: .screenPointed, command: "Turn it into a web page", tools: ["changeScreenDevice"], isRight: both(tidied("S1"), device("web", "mac")), pointing: .thing))
    list.append(Case(canvas: .iPadPointed, command: "Make it an iPhone again", tools: ["changeScreenDevice"], isRight: both(tidied("S1"), device("iphone")), pointing: .thing))
    // A new screen: by voice on an empty canvas, and with the pencil on empty canvas beside a screen.
    for (canvas, pointing) in [(Canvas.empty, Pointing?.none), (.one, .canvas)] {
        list.append(Case(canvas: canvas, command: "Make an Apple product page on iPad", tools: ["createScreen"], isRight: both(has("description", "product"), device("ipad")), pointing: pointing))
        list.append(Case(canvas: canvas, command: "A Chinese calligraphy webpage", tools: ["createScreen"], isRight: both(has("description", "calligraphy"), device("web", "mac")), pointing: pointing))
        list.append(Case(canvas: canvas, command: "A settings screen", tools: ["createScreen"], isRight: { ($0["description"] ?? "").lowercased().contains("settings") && ($0["device"] ?? "").isEmpty }, pointing: pointing))
    }
    // Controls, which must not go to the new tools.
    list.append(Case(canvas: .buttonPointed, command: "Align it to the left", tools: ["alignElement", "placeElement"], isRight: { $0["element"] == "E2" }, pointing: .thing))
    list.append(Case(canvas: .twoPointed, command: "Centre these two", tools: ["alignElement"], isRight: { ["E1", "E3"].allSatisfy(($0["element"] ?? "").contains) && centred.contains(($0["alignment"] ?? "").lowercased()) }, pointing: .thing))
    list.append(Case(canvas: .buttonPointed, command: "Make this blue", tools: ["styleElement"], isRight: both(has("element", "E2"), has("look", "blue")), pointing: .thing))
    list.append(Case(canvas: .one, command: "Align the image to the left", tools: ["alignElement"], isRight: both(has("element", "E3"), has("alignment", "left"))))
    list.append(Case(canvas: .one, command: "Rename this screen to Sign In", tools: ["renameScreen"], isRight: both(has("screen", "S1"), has("name", "sign in"))))
    return list
}()

/// Whether a position says before: "before", "above" or "left of", as the app reads it (`VoiceToolbox.isBefore`).
private func saysBefore(_ position: String?) -> Bool {
    let said = Set((position ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
    let before = !said.isDisjoint(with: ["before", "above", "left"])
    let after = !said.isDisjoint(with: ["after", "below", "under", "beneath", "underneath", "right"])
    return before && !after
}

/// The structure tools added in plan 6 (`groupElements`, `setLayout`, `ungroup`, `reorder`), over a screen holding a
/// card, a row and a column, with two controls: taking one thing out of a row, which is `moveElement`'s, and resizing a
/// button in a column. Run with `structure`, each several times. See "Structure tools (plan 6)" in the benchmark notes.
let structureCases: [Case] = [
    Case(canvas: .fieldsSelected, command: "Put these in a column", tools: ["groupElements"],
         isRight: { ["E8", "E9"].allSatisfy(($0["elements"] ?? "").contains) && ($0["as"] ?? "").lowercased().contains("column") }),
    Case(canvas: .fieldsSelected, command: "Make these a row", tools: ["groupElements"],
         isRight: { ["E8", "E9"].allSatisfy(($0["elements"] ?? "").contains) && ($0["as"] ?? "").lowercased().contains("row") }),
    Case(canvas: .nested, command: "Make the card a grid of two", tools: ["setLayout"],
         isRight: { arguments in
             let layout = (arguments["layout"] ?? "").lowercased()
             return arguments["target"] == "E2" && layout.contains("grid") && (layout.contains("2") || layout.contains("two"))
         }),
    // More than the row's 12.
    Case(canvas: .nested, command: "Space the row out more", tools: ["setLayout"],
         isRight: { arguments in
             let spacing = Double((arguments["spacing"] ?? "").filter { $0.isNumber || $0 == "." }) ?? 0
             let keepsTheRow = arguments["layout"].map { $0.lowercased().contains("row") } ?? true
             return arguments["target"] == "E5" && spacing > 12 && keepsTheRow
         }),
    Case(canvas: .nested, command: "Ungroup the row", tools: ["ungroup"], isRight: has("element", "E5")),
    Case(canvas: .nested, command: "Move the toggle before the label", tools: ["reorder"],
         isRight: { $0["element"] == "E7" && $0["target"] == "E6" && saysBefore($0["position"]) }),
    // Controls: one thing out of a row is moveElement's take-out, and a button in a column is resized as any is.
    Case(canvas: .nested, command: "Take the toggle out of the row", tools: ["moveElement"],
         isRight: { $0["element"] == "E7" && ["yes", "true", "y"].contains(($0["takeOut"] ?? "").lowercased()) }),
    Case(canvas: .nested, command: "Make the button half width", tools: ["moveElement"], isRight: both(has("element", "E11"), has("width", "50"))),
]

/// `--all-tools` anywhere in the arguments hands the model every tool, as a hosted model has them, in place of the
/// on-device list (`VoiceTools.compact`): how the first runs of "Structure tools (plan 6)" were made.
let handsAllTools = CommandLine.arguments.contains("--all-tools")

/// The tools the model is handed with a screen on the canvas: the app's on-device list, or all of them with `--all-tools`.
func withScreen(_ actor: any VoiceActing, canEndCall: Bool = true) -> [any Tool] {
    handsAllTools ? VoiceTools.all(actor, canEndCall: canEndCall) : VoiceTools.compact(actor, canEndCall: canEndCall)
}

/// The on-device branch of the app's `VoiceProfile`, with optional changes to try.
struct BenchProfile: LanguageModelSession.DynamicProfile {
    let picture: CanvasPicture
    let actor: any VoiceActing
    let variant: Variant
    /// False for the pencil's call, which has no tool to end it.
    var canEndCall = true

    enum Variant: String {
        /// The model's own sampling, which varies from run to run.
        case sampled
        /// Always the likeliest answer, so a run can be repeated, with the canvas in the
        /// instructions. As the app has it.
        case baseline
        /// The model must call a tool.
        case required
        /// Two worked examples added to the rules.
        case examples
        /// The canvas at the head of the prompt, run straight into "The command: …".
        /// The first try, 2026-11-18 (`PromptForm.plain`).
        case canvasfirst
        /// The canvas for reference, then the person's words in quotes (`PromptForm.quoted`).
        case quoted
        /// The person's words in quotes, then the canvas (`PromptForm.commandfirst`).
        case commandfirst
        case quotedrule
        case quotedonly

        var form: PromptForm {
            switch self {
            case .canvasfirst: .plain
            case .quoted: .quoted
            case .commandfirst: .commandfirst
            case .quotedrule: .quotedrule
            case .quotedonly: .quotedonly
            default: .instructions
            }
        }
    }

    private static let examples = """

        Examples:
        "make the sign in button green", where E2 is the button "Sign in": call styleElement with element E2 and look green.
        "show me the first screen": call show with target S1.
        """

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions(VoiceRules.compact(hasScreens: picture.hasScreens) + (variant == .examples ? Self.examples : ""))
            if !variant.form.canvasInPrompt {
                Instructions("The canvas now:\n\(picture.text(.compact))")
            }
            if picture.hasScreens {
                withScreen(actor, canEndCall: canEndCall)
            } else {
                VoiceTools.forEmptyCanvas(actor, canEndCall: canEndCall)
            }
        }
        .maximumResponseTokens(200)
        .samplingMode(variant == .sampled ? nil : .greedy)
        .toolCallingMode(variant == .required ? .required : nil)
    }
}

struct Outcome {
    var command: String
    var canvas: Canvas
    var isHeldBack: Bool
    var isFresh: Bool
    var isFromTheIPad: Bool
    var calls: [Recorder.Call]
    /// How many of the calls the app would have turned down.
    var refusals: Int
    var reply: String
    var seconds: Double
    var error: String?
    /// The right tool, or rightly none.
    var rightTool: Bool
    /// The right tool asked the right thing, with nothing else done.
    var right: Bool
}

@MainActor
func run(_ testCase: Case, variant: BenchProfile.Variant) async -> Outcome {
    let recorder = Recorder(picture: testCase.canvas.picture)
    let session = LanguageModelSession(profile: BenchProfile(picture: testCase.canvas.picture, actor: recorder, variant: variant, canEndCall: testCase.pointing == nil))
    let start = ContinuousClock.now
    var reply = ""
    var failure: String?
    // As the app puts it: the pencil's hint, a space, then the words.
    let hint = testCase.pointing.map { $0.hint(testCase.canvas.picture) + " " } ?? ""
    do {
        reply = try await session.respond(to: hint + variant.form.prompt(testCase.command, picture: testCase.canvas.picture)).content
    } catch {
        failure = String(describing: error).prefix(160).description
    }
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let calls = recorder.calls
    let rightTool: Bool
    let right: Bool
    if testCase.tools.isEmpty {
        // Nothing should change: no tool called, or only ones the app turned down.
        rightTool = calls.count == recorder.refusals
        right = rightTool
    } else {
        rightTool = calls.first.map { testCase.tools.contains($0.tool) } ?? false
        right = rightTool && calls.count == 1 && testCase.isRight(calls[0].arguments)
    }
    return Outcome(
        command: testCase.command, canvas: testCase.canvas, isHeldBack: testCase.isHeldBack, isFresh: testCase.isFresh, isFromTheIPad: testCase.isFromTheIPad, calls: calls, refusals: recorder.refusals, reply: reply,
        seconds: seconds, error: failure, rightTool: rightTool, right: right
    )
}


// MARK: Commands in a row

extension SessionPropertyValues {
    /// The canvas as the app writes it before each command.
    @SessionPropertyEntry var benchCanvas: CanvasPicture = .empty
}

/// The canvas in the instructions, read afresh before every request, as `CanvasBrief` has it.
struct BenchBrief: DynamicInstructions {
    @SessionProperty(\.benchCanvas) private var picture

    var body: some DynamicInstructions {
        Instructions("The canvas now:\n\(picture.text(.compact))")
    }
}

/// The canvas in the prompt, as tried for the app on 2026-11-18 and not kept: the canvas
/// marked as for reference, any notes of the app's own, then the person's words in
/// quotes. See "Prompt order" in docs/benchmarks/voice-on-device.md.
enum VoicePrompt {
    static let canvasHeading = "The canvas now (for reference only):"
    static let wordsLead = "The person said: "

    static func make(_ words: String, notes: [String] = [], canvas: CanvasPicture) -> String {
        ([canvasHeading + "\n" + canvas.text(.compact)] + notes + [wordsLead + "\"" + words + "\""]).joined(separator: "\n\n")
    }

    /// The person's words in such a prompt; the whole text where it isn't one.
    static func words(in prompt: String) -> String {
        guard let lead = prompt.range(of: wordsLead, options: .backwards) else { return prompt }
        var words = prompt[lead.upperBound...]
        if words.count >= 2, words.hasPrefix("\""), words.hasSuffix("\"") { words = words.dropFirst().dropLast() }
        return String(words)
    }

    /// A prompt with its canvas taken out: the paragraph that opens "The canvas now".
    static func withoutCanvas(_ prompt: String) -> String {
        prompt.components(separatedBy: "\n\n").filter { !$0.hasPrefix("The canvas now") }.joined(separator: "\n\n")
    }

    /// The conversation with the canvas taken out of every prompt but the last. An older
    /// canvas is no longer the canvas, and the model shouldn't read it as one.
    static func withoutOldCanvases(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        guard let last = entries.lastIndex(where: { if case .prompt = $0 { true } else { false } }) else { return entries }
        return entries.indices.map { index in
            guard index != last, case .prompt(var prompt) = entries[index] else { return entries[index] }
            prompt.segments = prompt.segments.map { segment in
                guard case .text(var text) = segment else { return segment }
                text.content = withoutCanvas(text.content)
                return .text(text)
            }
            return .prompt(prompt)
        }
    }
}

/// How the canvas and the person's words are put to the on-device model.
enum PromptForm: String, CaseIterable {
    /// The canvas between the rules and the tools, as the app has it.
    case instructions
    /// "The canvas now:\n…\n\nThe command: …", the first try at the canvas in the prompt.
    case plain
    /// The canvas for reference, the app's notes, then the person's words in quotes, with
    /// the canvas taken out of older prompts (`VoicePrompt`).
    case quoted
    /// As `quoted`, but older prompts keep their canvas.
    case quotedkeep
    /// The person's words in quotes, then the canvas; older prompts lose their canvas.
    case commandfirst
    /// As `quoted`, with a reminder before the person's words to act only on what is listed.
    case quotedrule
    /// As `quoted`, with the canvas headed as all there is.
    case quotedonly

    var canvasInPrompt: Bool { self != .instructions }
    var stripsOldCanvases: Bool { self != .instructions && self != .plain && self != .quotedkeep }

    func prompt(_ command: String, notes: [String] = [], picture: CanvasPicture) -> String {
        switch self {
        case .instructions:
            return (notes + [command]).joined(separator: " ")
        case .plain:
            return "The canvas now:\n\(picture.text(.compact))\n\nThe command: " + (notes + [command]).joined(separator: " ")
        case .quoted, .quotedkeep:
            return VoicePrompt.make(command, notes: notes, canvas: picture)
        case .quotedrule:
            return VoicePrompt.make(command, notes: notes + ["(Act only on what the canvas lists. If they name something it doesn't list, call no tool and say it isn't there.)"], canvas: picture)
        case .quotedonly:
            return VoicePrompt.make(command, notes: notes, canvas: picture)
                .replacingOccurrences(of: VoicePrompt.canvasHeading, with: "The canvas now. Only what is listed here exists:")
        case .commandfirst:
            return (notes + [VoicePrompt.wordsLead + "\"" + command + "\"", VoicePrompt.canvasHeading + "\n" + picture.text(.compact)]).joined(separator: "\n\n")
        }
    }
}

/// The app's on-device profile for a call, with the canvas told in one of the forms above.
struct CallProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.benchCanvas) private var picture
    let actor: any VoiceActing
    let form: PromptForm

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions(VoiceRules.compact(hasScreens: picture.hasScreens))
            if !form.canvasInPrompt {
                BenchBrief()
            }
            if picture.hasScreens {
                withScreen(actor)
            } else {
                VoiceTools.forEmptyCanvas(actor)
            }
        }
        .historyTransform { [form] in
            let kept = Self.trimmed($0, keepingCommands: 2)
            return form.stripsOldCanvases ? VoicePrompt.withoutOldCanvases(kept) : kept
        }
        .maximumResponseTokens(200)
        .samplingMode(.greedy)
    }

    /// As `VoiceProfile.trimmed`.
    static func trimmed(_ entries: [Transcript.Entry], keepingCommands count: Int) -> [Transcript.Entry] {
        let prompts = entries.indices.filter { if case .prompt = entries[$0] { true } else { false } }
        guard count > 0, prompts.count > count else { return entries }
        let start = prompts[prompts.count - count]
        let instructions = entries[..<start].filter { if case .instructions = $0 { true } else { false } }
        return instructions + entries[start...]
    }
}

/// A call's commands in a row, graded as the single commands are. A correction is
/// handled as the app handles it: the last change is undone first, and the model is told.
struct Sequence {
    var name: String
    var canvas: Canvas
    var steps: [Case]
    /// The steps that open with "No, …" and so undo the step before them first.
    var corrections: Set<Int> = []
}

private func one(_ command: String, _ tools: [String], _ isRight: @escaping ([String: String]) -> Bool = { _ in true }) -> Case {
    Case(canvas: .one, command: command, tools: tools, isRight: isRight)
}

let sequences: [Sequence] = [
    // Edits on one screen, each changing the canvas.
    Sequence(name: "edits", canvas: .one, steps: [
        one("Make the sign in button green", ["styleElement"], both(has("element", "E2"), has("look", "green"))),
        one("Make the title bold", ["styleElement"], both(has("element", "E1"), has("look", "bold"))),
        one("Change the button text to Continue", ["setText"], both(has("element", "E2"), has("text", "continue"))),
        one("Make the image half width", ["moveElement"], both(has("element", "E3"), has("width", "50"))),
        one("Make the title red", ["styleElement"], both(has("element", "E1"), has("look", "red"))),
        one("Align the image centrally", ["alignElement"], { $0["element"] == "E3" && ["centre", "center", "centrally", "middle"].contains(($0["alignment"] ?? "").lowercased()) }),
        one("Duplicate the button", ["duplicateElement"], has("element", "E2")),
        one("Change the title's text colour to blue", ["styleElement"], both(has("element", "E1"), has("look", "blue"))),
    ]),
    // Three screens, moving between them, with something that isn't there.
    Sequence(name: "screens", canvas: .three, steps: [
        one("Make the edit profile button red", ["styleElement"], both(has("element", "E6"), has("look", "red"))),
        one("Show me the settings screen", ["show"], has("target", "S3")),
        one("Turn the toggle off", ["styleElement"], both(has("element", "E7"), has("look", "off"))),
        one("Delete the log out button", ["deleteElement"], has("element", "E8")),
        one("Go to the login screen", ["show"], has("target", "S1")),
        one("Make the sign in button green", ["styleElement"], both(has("element", "E2"), has("look", "green"))),
        one("Make the slider wider", []),
        one("Rename this screen to Sign In", ["renameScreen"], both(has("screen", "S1"), has("name", "sign in"))),
    ]),
    // Commands that leave the canvas as it is, a rename, a correction, and something
    // that isn't there.
    Sequence(name: "views", canvas: .one, steps: [
        one("Zoom in", ["zoom"], has("level", "in")),
        one("Make the title bold", ["styleElement"], both(has("element", "E1"), has("look", "bold"))),
        one("Zoom out", ["zoom"], has("level", "out")),
        one("Make the image bigger", ["moveElement", "styleElement"], { $0["element"] == "E3" }),
        one("No, make the button bigger instead", ["moveElement", "styleElement"], { $0["element"] == "E2" }),
        one("Rename this screen to Welcome", ["renameScreen"], both(has("screen", "S1"), has("name", "welcome"))),
        one("Show me the whole canvas", ["show", "zoom"], { ($0["target"] ?? $0["level"] ?? "").lowercased().contains("all") || ($0["level"] ?? "").lowercased().contains("fit") }),
        one("Make the checkbox blue", []),
    ], corrections: [4]),
]

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// One call: the session is made and warmed as the app does when a call starts, a pause
/// stands in for the person speaking, and then a sequence's commands run one after
/// another. For each, the time to the first tool, the time from the last tool to the
/// model's last word (its "Done"), the whole, and whether it was right. Printed one line
/// a command, for adding up elsewhere.
/// Whether a build or test run is going on, which would slow the model and spoil the times.
func isBuilding() -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", "xcodebuild"]
    pgrep.standardOutput = FileHandle.nullDevice
    try? pgrep.run()
    pgrep.waitUntilExit()
    return pgrep.terminationStatus == 0
}

/// Runs a call when nothing is building, and again if a build started part way through.
/// Only the clean call's lines are printed.
@MainActor
func cleanCall(_ sequence: Sequence, form: PromptForm, run: Int) async {
    while true {
        while isBuilding() { try? await Task.sleep(for: .seconds(10)) }
        let lines = await call(sequence, form: form, run: run)
        if let lines {
            lines.forEach { print($0) }
            return
        }
        print("# \(form.rawValue) run\(run) \(sequence.name): a build started part way, so the call is run again")
    }
}

/// The call's lines, or nil where a build was going on at some point during it.
@MainActor
func call(_ sequence: Sequence, form: PromptForm, run: Int) async -> [String]? {
    var lines: [String] = []
    let recorder = Recorder(picture: sequence.canvas.picture)
    let session = LanguageModelSession(profile: CallProfile(actor: recorder, form: form))
    session.properties.benchCanvas = recorder.picture
    session.prewarm()
    try? await Task.sleep(for: .seconds(4))
    var before = recorder.picture
    for (index, step) in sequence.steps.enumerated() {
        var notes: [String] = []
        if sequence.corrections.contains(index) {
            recorder.picture = before
            notes.append("(The last change has been undone.)")
        }
        before = recorder.picture
        // The app takes the canvas as it is before each command.
        session.properties.benchCanvas = recorder.picture
        recorder.firstToolAt = nil
        recorder.lastToolAt = nil
        let callsBefore = recorder.calls.count
        let refusalsBefore = recorder.refusals
        let start = ContinuousClock.now
        var failure = ""
        do {
            _ = try await session.respond(to: form.prompt(step.command, notes: notes, picture: recorder.picture))
        } catch {
            failure = " ERROR \(String(describing: error).prefix(100))"
        }
        let end = ContinuousClock.now
        let calls = Array(recorder.calls[callsBefore...])
        let refusals = recorder.refusals - refusalsBefore
        let right: Bool
        if step.tools.isEmpty {
            right = calls.count == refusals
        } else {
            right = calls.count == 1 && step.tools.contains(calls[0].tool) && step.isRight(calls[0].arguments)
        }
        let firstTool = recorder.firstToolAt.map { seconds($0 - start) } ?? -1
        let done = recorder.lastToolAt.map { seconds(end - $0) } ?? -1
        let did = calls.map(\.description).joined(separator: "; ") + (refusals > 0 ? " [\(refusals) turned down]" : "")
        if isBuilding() { return nil }
        lines.append(String(format: "T %@ run%d %@ cmd%d total %.3f first-tool %.3f done %.3f %@ | %@ | %@%@", form.rawValue, run, sequence.name, index, seconds(end - start), firstTool, done, right ? "RIGHT" : "WRONG", step.command, did, failure))
        // A short pause between commands, as there is in a call while the person speaks.
        try? await Task.sleep(for: .seconds(1.5))
    }
    return lines
}

@main
struct Main {
    @MainActor
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        if CommandLine.arguments.dropFirst().first == "check" {
            check()
            return
        }
        let variant = CommandLine.arguments.dropFirst().first.flatMap(BenchProfile.Variant.init(rawValue:)) ?? .baseline
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            print("Apple Intelligence isn't available here: \(model.availability)")
            exit(2)
        }
        // The model won't run while the Mac is short of memory, and says to try later.
        // It is tried for a few minutes before the benchmark gives up.
        var isReady = false
        for attempt in 1...18 where !isReady {
            do {
                _ = try await LanguageModelSession().respond(to: "Reply with the one word: ready")
                isReady = true
            } catch {
                print("the model wouldn't run (attempt \(attempt)): \(String(describing: error).prefix(110))")
                try? await Task.sleep(for: .seconds(20))
            }
        }
        guard isReady else {
            print("Giving up: the model would not run. Free some memory and run this again.")
            exit(3)
        }
        if CommandLine.arguments.dropFirst().first == "latency" {
            // Calls in each order, which goes first rotating from run to run, so that none
            // is favoured by the Mac warming or by a cache left by another.
            let runs = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 5
            let forms = CommandLine.arguments.dropFirst(3).first.map { $0.split(separator: ",").compactMap { PromptForm(rawValue: String($0)) } } ?? PromptForm.allCases
            for run in 1...runs {
                for sequence in sequences {
                    for step in forms.indices {
                        await cleanCall(sequence, form: forms[(step + run) % forms.count], run: run)
                    }
                }
            }
            return
        }
        if let mode = CommandLine.arguments.dropFirst().first, mode == "newtools" || mode == "structure" {
            let runs = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 5
            let variant = CommandLine.arguments.dropFirst(3).first.flatMap(BenchProfile.Variant.init(rawValue:)) ?? .baseline
            if mode == "newtools" {
                await newTools(runs: runs, variant: variant)
            } else {
                await structure(runs: runs, variant: variant)
            }
            return
        }
        print("variant: \(variant.rawValue)")
        print("context size: \(model.contextSize) tokens")
        // How much of that the app's on-device profile takes before a word is spoken.
        for canvas in [Canvas.empty, .one, .three] {
            let picture = canvas.picture
            let recorder = Recorder(picture: picture)
            let tools = picture.hasScreens ? withScreen(recorder) : VoiceTools.forEmptyCanvas(recorder)
            let rules = (try? await model.tokenCount(for: Instructions(VoiceRules.compact(hasScreens: picture.hasScreens)))) ?? -1
            let brief = (try? await model.tokenCount(for: Instructions("The canvas now:\n\(picture.text(.compact))"))) ?? -1
            let toolTokens = (try? await model.tokenCount(for: tools)) ?? -1
            print("canvas \(canvas.rawValue): rules \(rules) + canvas \(brief) + \(tools.count) tools \(toolTokens) = \(rules + brief + toolTokens) tokens")
        }
        print("")

        var outcomes: [Outcome] = []
        for testCase in cases {
            let outcome = await run(testCase, variant: variant)
            outcomes.append(outcome)
            let mark = outcome.right ? "RIGHT" : outcome.rightTool ? "TOOL " : "WRONG"
            let did = (outcome.calls.isEmpty ? "no tool" : outcome.calls.map(\.description).joined(separator: "; "))
                + (outcome.refusals > 0 ? " [\(outcome.refusals) turned down by the app]" : "")
            let said = outcome.error.map { "ERROR \($0)" } ?? "said “\(outcome.reply.prefix(80))”"
            print("\(mark) \(String(format: "%5.1f", outcome.seconds))s [\(outcome.canvas.rawValue)\(outcome.isHeldBack ? ", held back" : "")\(outcome.isFresh ? ", fresh" : "")\(outcome.isFromTheIPad ? ", iPad" : "")] “\(outcome.command)” -> \(did) | \(said)")
        }

        let times = outcomes.map(\.seconds).sorted()
        func percentile(_ share: Double) -> Double { times[min(times.count - 1, Int((Double(times.count) * share).rounded(.up)) - 1)] }
        func score(_ label: String, _ group: [Outcome]) {
            guard !group.isEmpty else { return }
            let right = group.filter(\.right).count
            let rightTool = group.filter(\.rightTool).count
            print("\(label): right tool and arguments \(right)/\(group.count) (\(Int((Double(right) / Double(group.count) * 100).rounded()))%), right tool \(rightTool)/\(group.count)")
        }
        print("")
        score("commands the rules were tuned on", outcomes.filter { !$0.isHeldBack && !$0.isFresh && !$0.isFromTheIPad })
        score("commands held back", outcomes.filter(\.isHeldBack))
        score("fresh commands", outcomes.filter(\.isFresh))
        score("commands spoken to an iPad", outcomes.filter(\.isFromTheIPad))
        print(String(format: "latency: p50 %.1f s, p95 %.1f s, longest %.1f s", percentile(0.5), percentile(0.95), times.last ?? 0))
        let severalAtOnce = outcomes.filter { $0.calls.count > 1 }.count
        print("commands where more than one tool was called: \(severalAtOnce)")
    }
}

/// `check`: the app's tools, rules and canvas picture built as a call's are, and a container's line read back,
/// without calling a model.
@MainActor
func check() {
    let tools = VoiceTools.all(Recorder(picture: Canvas.one.picture))
    var picture = Canvas.one.picture
    picture.screens[0].elements.append(.init(
        handle: "E4", kind: "group", text: "", frame: CGRect(x: 20, y: 720, width: 143, height: 31), layout: "row, spacing 12",
        isContainer: true, children: [.init(handle: "E5", kind: "toggle", text: "", frame: CGRect(x: 112, y: 720, width: 51, height: 31))]
    ))
    guard !VoiceRules.compact.isEmpty, picture.text(.compact).contains("\n  E4 row, spacing 12 x20 y720 w143 h31:\n    E5 toggle") else {
        print("harness FAILED: a row's line and what it holds aren't told as the app tells them")
        exit(1)
    }
    guard Canvas.fieldsSelected.picture.text(.compact).contains("\n  E10 column, spacing 12 x20 y460 w353 h82:\n    E11 button \"Sign in\""),
          Canvas.fieldsSelected.picture.selectionInWords == "E8, the text field \"Email\" on S1; E9, the text field \"Password\" on S1" else {
        print("harness FAILED: the structure cases' canvas isn't told as the app tells it")
        exit(1)
    }
    print("harness ok: \(tools.count) tools, \(structureCases.count) structure cases")
}

/// The prompt's size before a word is spoken, for each canvas, as `main` prints it.
@MainActor
func printPromptSize(canEndCall: Bool, canvases: [Canvas] = [.empty, .one, .three]) async {
    let model = SystemLanguageModel.default
    for canvas in canvases {
        let picture = canvas.picture
        let recorder = Recorder(picture: picture)
        let tools = picture.hasScreens ? withScreen(recorder, canEndCall: canEndCall) : VoiceTools.forEmptyCanvas(recorder, canEndCall: canEndCall)
        let rules = (try? await model.tokenCount(for: Instructions(VoiceRules.compact(hasScreens: picture.hasScreens)))) ?? -1
        let brief = (try? await model.tokenCount(for: Instructions("The canvas now:\n\(picture.text(.compact))"))) ?? -1
        let toolTokens = (try? await model.tokenCount(for: tools)) ?? -1
        print("canvas \(canvas.rawValue)\(canEndCall ? "" : " (pencil)"): rules \(rules) + canvas \(brief) + \(tools.count) tools \(toolTokens) = \(rules + brief + toolTokens) tokens")
    }
}

/// Each of `newToolCases` run `runs` times; one line a run, then each case's rates.
@MainActor
func newTools(runs: Int, variant: BenchProfile.Variant) async {
    print("newtools: \(runs) runs, variant \(variant.rawValue)\(handsAllTools ? ", all tools" : "")")
    print("context size: \(SystemLanguageModel.default.contextSize) tokens")
    await printPromptSize(canEndCall: true)
    await printPromptSize(canEndCall: false)
    await repeated(newToolCases, runs: runs, variant: variant)
}

/// Each of `structureCases` run `runs` times, as `newtools` runs its own, with the profile's size for the nested canvas.
@MainActor
func structure(runs: Int, variant: BenchProfile.Variant) async {
    print("structure: \(runs) runs, variant \(variant.rawValue)\(handsAllTools ? ", all tools" : "")")
    print("context size: \(SystemLanguageModel.default.contextSize) tokens")
    await printPromptSize(canEndCall: true, canvases: [.one, .nested])
    await printPromptSize(canEndCall: false, canvases: [.one, .nested])
    await repeated(structureCases, runs: runs, variant: variant)
}

/// `cases`, each run `runs` times; one line a run, then each case's rates.
@MainActor
func repeated(_ cases: [Case], runs: Int, variant: BenchProfile.Variant) async {
    var tallies: [(Case, right: Int, rightTool: Int, picks: [String: Int])] = cases.map { ($0, 0, 0, [:]) }
    for pass in 1...runs {
        for index in cases.indices {
            let testCase = cases[index]
            let outcome = await run(testCase, variant: variant)
            if outcome.right { tallies[index].right += 1 }
            if outcome.rightTool { tallies[index].rightTool += 1 }
            let pick = outcome.calls.first?.tool ?? "none"
            tallies[index].picks[pick, default: 0] += 1
            let did = outcome.calls.isEmpty ? "no tool" : outcome.calls.map(\.description).joined(separator: "; ")
            print("R run\(pass) \(outcome.right ? "RIGHT" : outcome.rightTool ? "TOOL " : "WRONG") [\(testCase.canvas.rawValue)\(testCase.pointing == nil ? "" : ", pencil")] “\(testCase.command)” -> \(did)\(outcome.error.map { " ERROR \($0)" } ?? "")")
        }
    }
    print("")
    for tally in tallies {
        let picks = tally.picks.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("S \(tally.right)/\(runs) right, \(tally.rightTool)/\(runs) right tool | [\(tally.0.canvas.rawValue)\(tally.0.pointing == nil ? "" : ", pencil")] “\(tally.0.command)” | picks: \(picks)")
    }
}
