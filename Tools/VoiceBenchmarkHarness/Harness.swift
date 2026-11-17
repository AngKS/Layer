// Measures how well the on-device Apple Intelligence model carries out spoken commands
// with Layer's voice tools. Apple Intelligence can't answer in the iPadOS Simulator, so
// this runs natively on the Mac, compiling the app's own rules, tools and canvas picture
// (see run.sh) with a recorder in place of the design.
//
// Each command is put to a fresh session set up as the app's on-device profile is: the
// compact rules, the compact picture of the canvas, the tools that fit the canvas, and a
// short limit on the reply. What the model asks the tools to do is recorded and graded.
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
    private let picture: CanvasPicture

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
        return line
    }

    func createScreen(description: String) async throws -> String {
        note("createScreen", ["description": description], saying: "Made the screen as S9, with 6 elements.")
    }

    func addElement(screen: String?, kind: String, text: String?, look: String?) -> String {
        note("addElement", ["screen": screen, "kind": kind, "text": text, "look": look], saying: "Added a \(kind) as E20.")
    }

    func setText(element: String, text: String) -> String {
        // As the app does: a colour on its own, in lower case, is the colour of the words.
        var words = text.trimmingCharacters(in: .whitespaces)
        if words == words.lowercased() {
            if words.hasPrefix("text ") { words = String(words.dropFirst(5)) }
            if Self.colours.contains(words) { return styleElement(element: element, look: "text \(words)") }
        }
        return note("setText", ["element": element, "text": text], saying: "Reworded \(element) to “\(text)”.")
    }

    private static let colours: Set<String> = ["black", "white", "gray", "grey", "red", "orange", "yellow", "green", "blue", "purple", "pink", "teal", "brown"]

    func styleElement(element: String, look: String) -> String {
        note("styleElement", ["element": element, "look": look], saying: "Restyled \(element).")
    }

    func moveElement(element: String, x: String?, y: String?, width: String?, height: String?) -> String {
        note("moveElement", ["element": element, "x": x, "y": y, "width": width, "height": height], saying: "Resized \(element).")
    }

    func alignElement(element: String, alignment: String) -> String {
        note("alignElement", ["element": element, "alignment": alignment], saying: "Aligned \(element) to the \(alignment).")
    }

    func duplicateElement(element: String) -> String {
        note("duplicateElement", ["element": element], saying: "Duplicated \(element) as E21.")
    }

    func deleteElement(element: String, named: String?) -> String {
        // The app's guard: a delete goes ahead only if the person's word fits the thing.
        if let named, let found = picture.screens.flatMap(\.elements).first(where: { $0.handle == element }),
           !VoiceNaming.fits(named, names: (Self.kindNames[found.kind] ?? [found.kind]) + (found.text.isEmpty ? [] : ["text", "words", "label"]), words: found.text) {
            refusals += 1
            return note("deleteElement", ["element": element, "named": named], saying: "There is no \(named) here. \(element) is the \(found.kind).")
        }
        return note("deleteElement", ["element": element, "named": named], saying: "Deleted \(element).")
    }

    func renameScreen(screen: String, name: String) -> String {
        note("renameScreen", ["screen": screen, "name": name], saying: "Renamed \(screen) to “\(name)”.")
    }

    func deleteScreen(screen: String, named: String?) -> String {
        if let named, let found = picture.screens.first(where: { $0.handle == screen }), !VoiceNaming.fits(named, names: [], words: found.name) {
            refusals += 1
            return note("deleteScreen", ["screen": screen, "named": named], saying: "There is no \(named) here. \(screen) is “\(found.name)”.")
        }
        return note("deleteScreen", ["screen": screen, "named": named], saying: "Deleted \(screen).")
    }

    func show(target: String) -> String {
        note("show", ["target": target], saying: "Showing \(target).")
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

    private static let login = CanvasPicture.Screen(
        handle: "S1", name: "Login", size: CGSize(width: 393, height: 852), visibleShare: 1,
        elements: [
            .init(handle: "E1", kind: "title", text: "Welcome back", frame: CGRect(x: 20, y: 75, width: 353, height: 41)),
            .init(handle: "E2", kind: "button", text: "Sign in", frame: CGRect(x: 20, y: 420, width: 353, height: 50), look: ["colour accent"], isSelected: true),
            .init(handle: "E3", kind: "image", text: "", frame: CGRect(x: 20, y: 500, width: 200, height: 200)),
        ]
    )

    var picture: CanvasPicture {
        switch self {
        case .empty:
            return .empty
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
]

/// The on-device branch of the app's `VoiceProfile`, with optional changes to try.
struct BenchProfile: LanguageModelSession.DynamicProfile {
    let picture: CanvasPicture
    let actor: any VoiceActing
    let variant: Variant

    enum Variant: String {
        /// The model's own sampling, which varies from run to run.
        case sampled
        /// Always the likeliest answer, so a run can be repeated. As the app has it.
        case baseline
        /// The model must call a tool.
        case required
        /// Two worked examples added to the rules.
        case examples
    }

    private static let examples = """

        Examples:
        "make the sign in button green", where E2 is the button "Sign in": call styleElement with element E2 and look green.
        "show me the first screen": call show with target S1.
        """

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions(VoiceRules.compact + (variant == .examples ? Self.examples : ""))
            Instructions("The canvas now:\n\(picture.text(.compact))")
            if picture.hasScreens {
                VoiceTools.all(actor)
            } else {
                VoiceTools.forEmptyCanvas(actor)
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
    let session = LanguageModelSession(profile: BenchProfile(picture: testCase.canvas.picture, actor: recorder, variant: variant))
    let start = ContinuousClock.now
    var reply = ""
    var failure: String?
    do {
        reply = try await session.respond(to: testCase.command).content
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
        command: testCase.command, canvas: testCase.canvas, isHeldBack: testCase.isHeldBack, isFresh: testCase.isFresh, calls: calls, refusals: recorder.refusals, reply: reply,
        seconds: seconds, error: failure, rightTool: rightTool, right: right
    )
}

@main
struct Main {
    @MainActor
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
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
        print("variant: \(variant.rawValue)")
        print("context size: \(model.contextSize) tokens")
        // How much of that the app's on-device profile takes before a word is spoken.
        for canvas in [Canvas.empty, .one, .three] {
            let picture = canvas.picture
            let recorder = Recorder(picture: picture)
            let tools = picture.hasScreens ? VoiceTools.all(recorder) : VoiceTools.forEmptyCanvas(recorder)
            let rules = (try? await model.tokenCount(for: Instructions(VoiceRules.compact))) ?? -1
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
            print("\(mark) \(String(format: "%5.1f", outcome.seconds))s [\(outcome.canvas.rawValue)\(outcome.isHeldBack ? ", held back" : "")\(outcome.isFresh ? ", fresh" : "")] “\(outcome.command)” -> \(did) | \(said)")
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
        score("commands the rules were tuned on", outcomes.filter { !$0.isHeldBack && !$0.isFresh })
        score("commands held back", outcomes.filter(\.isHeldBack))
        score("fresh commands", outcomes.filter(\.isFresh))
        print(String(format: "latency: p50 %.1f s, p95 %.1f s, longest %.1f s", percentile(0.5), percentile(0.95), times.last ?? 0))
        let severalAtOnce = outcomes.filter { $0.calls.count > 1 }.count
        print("commands where more than one tool was called: \(severalAtOnce)")
    }
}
