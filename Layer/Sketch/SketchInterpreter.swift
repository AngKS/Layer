import CoreGraphics
import Foundation

/// Where a sketch was drawn, which is most of what gives it meaning.
enum SketchPlacement: Sendable, Equatable {
    /// Outside every screen.
    case openCanvas
    /// On a screen of `size` points. `local` is the sketch's bounds in those points.
    case onScreen(local: CGRect, existing: [ExistingElement], size: CGSize = DeviceFrame.iPhone.size)
}

struct ExistingElement: Sendable, Equatable {
    var kind: ElementKind
    var frame: CGRect
}

/// Everything an interpreter is told about one sketch. On-device text models use the
/// geometric observation, vision models and hosted APIs can also ask for `renderImage()`.
struct SketchRequest: Sendable {
    var observation: SketchObservation
    var placement: SketchPlacement
    var strokes: [[CGPoint]]
    /// Set when someone asked for this drawing to be read, with what they typed about it,
    /// which may be nothing. Nil for a Magic Pen sketch read on its own.
    var prompt: String? = nil
    /// A handwritten word or phrase `HandwritingRecognizer` (PencilKit's on-device
    /// `PKStrokeRecognizer`, Stage 2) read out of these strokes, if it found one — set by
    /// `SketchEngine` before scoring, for shapes where that's even worth trying. Evidence
    /// for `ComponentRule`'s text/title/body decision, and the label content once a kind
    /// is chosen; nil otherwise, which never changes any existing score.
    var recognizedText: String? = nil

    var isAsked: Bool { prompt != nil }

    /// The sketch drawn dark on white, fitted into a square of `side` pixels.
    func renderImage(side: Int = 384) -> CGImage? {
        let bounds = observation.bounds
        guard bounds.width > 0 || bounds.height > 0,
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        let margin = CGFloat(side) * 0.1
        let scale = (CGFloat(side) - margin * 2) / max(bounds.width, bounds.height, 1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // Core Graphics counts y upward; the canvas counts it downward.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(
            x: (CGFloat(side) - bounds.width * scale) / 2 - bounds.minX * scale,
            y: (CGFloat(side) - bounds.height * scale) / 2 - bounds.minY * scale
        )
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        context.setLineWidth(3 / scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes where stroke.count >= 2 {
            context.addLines(between: stroke)
        }
        context.strokePath()
        return context.makeImage()
    }
}

extension SketchRequest {
    /// What this sketch could mean, going by its shape and where it was drawn; empty when
    /// it can't be anything. Ranked by `scoredReadings`, highest first — a clear shape has
    /// one candidate miles ahead of anything else; a shape near one of the conventions'
    /// dividing lines has two or more sitting close together, and choosing between them is
    /// a judgement call. See `ComponentRule.swift`.
    var candidates: [SketchReading] { scoredReadings.map(\.reading) }
}

extension SketchRequest {
    /// What the sketch could mean when someone asks for it to be read: what its shape
    /// suggests first, then anything else that belongs where it was drawn, since they want
    /// it to become something.
    var askedCandidates: [SketchReading] {
        let shaped = candidates.filter { $0 != .scratchOut }
        let rest: [SketchReading] = switch placement {
        case .openCanvas: [.element(.text), .element(.stickyNote), .screen]
        case .onScreen: ElementKind.allCases.filter(\.spec.isAskedForOnScreens).map(SketchReading.element)
        }
        return shaped + rest.filter { !shaped.contains($0) }
    }

    /// The readings an interpreter chooses among.
    var options: [SketchReading] { isAsked ? askedCandidates : candidates }
}

extension DesignElement {
    /// Takes what the marks inside an outline say about the element drawn: which end a
    /// toggle's knob is at, whether a checkbox is ticked or a radio button has its dot,
    /// and how far a progress bar is shaded.
    mutating func adoptMarks(of observation: SketchObservation) {
        guard case .enclosure(_, let inner) = observation.form, let marks = kind.spec.marks else { return }
        switch marks {
        case .knob:
            if let knob = observation.innerBounds { isOn = knob.midX >= 0.5 }
        case .mark:
            isOn = inner != .none
        case .shading:
            // To the nearest 5%; unshaded bars start half full.
            if let shading = observation.innerBounds { value = (Double(min(max(shading.maxX, 0), 1)) * 20).rounded() / 20 }
        }
    }
}

/// What a sketch turned out to mean.
enum SketchReading: Sendable, Equatable {
    case screen
    case element(ElementKind)
    /// A scratch-out: whatever it was drawn over is deleted.
    case scratchOut
    /// Not recognisable as anything; the ink is left alone.
    case unknown
}

/// What an interpreter made of a sketch: its reading and, when it names one, its second choice.
struct SketchDecision: Sendable, Equatable {
    var chosen: SketchReading
    var runnerUp: SketchReading? = nil
}

extension SketchDecision {
    /// A model's answer, given as the names it was offered, turned back into readings.
    /// `names` and `candidates` run in step. A name that wasn't offered reads as unknown,
    /// or as no second choice.
    init(named chosen: String, runnerUp: String?, names: [String], candidates: [SketchReading]) {
        func reading(named name: String?) -> SketchReading? {
            zip(names, candidates).first { $0.0 == name }?.1
        }
        self.init(chosen: reading(named: chosen) ?? .unknown, runnerUp: reading(named: runnerUp))
    }
}

/// Something that can read sketches and name boards. Given a sketch, it returns one of
/// the request's `candidates`. Apple Intelligence is the built-in one; a hosted model is
/// added by writing another conforming type and listing it in `SketchProvider.all`.
protocol SketchInterpreter: Sendable {
    func read(_ request: SketchRequest) async throws -> SketchReading
    /// The reading together with a second choice. An interpreter that only gives a
    /// reading need not write this.
    func decide(_ request: SketchRequest) async throws -> SketchDecision
    /// A short name for a board, given `SketchPrompt.describe(board:)` of its design.
    func suggestTitle(for board: String) async throws -> String
}

extension SketchInterpreter {
    func decide(_ request: SketchRequest) async throws -> SketchDecision {
        SketchDecision(chosen: try await read(request))
    }
}

enum ProviderReadiness: Equatable, Sendable {
    case ready
    case unavailable(String)
}

/// How the app knows about an interpreter: what to call it, whether it can run right now,
/// and how to build it. `needsAPIKey` marks hosted providers, whose key is passed to
/// `makeInterpreter`.
struct SketchProvider: Identifiable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var needsAPIKey: Bool
    var readiness: @Sendable () -> ProviderReadiness
    var makeInterpreter: @Sendable (_ apiKey: String?) -> any SketchInterpreter

    static let appleIntelligence = SketchProvider(
        id: "apple-intelligence",
        name: "Apple Intelligence",
        symbol: "apple.intelligence",
        needsAPIKey: false,
        readiness: { AppleIntelligenceInterpreter.readiness },
        makeInterpreter: { _ in AppleIntelligenceInterpreter() }
    )

    static let all = [appleIntelligence]
}

/// The thresholds that turn measurements into the words designers use for sketches.
/// Shared by the built-in rules and by the descriptions given to models, so both draw
/// the same lines. Each line has a band around it in which a sketch is too close to call
/// on shape alone.
enum SketchConventions {
    /// A "wide, flat" outline is at least this many times wider than it is tall.
    static let wideRatio: CGFloat = 1.8
    static let wideBand: ClosedRange<CGFloat> = 1.5...2.2
    /// A "tall" outline is at least this many times taller than it is wide.
    static let tallRatio: CGFloat = 1.3
    /// From this roundness up, an outline reads as a pill or an oval.
    static let pillRoundness = 0.55
    static let pillBand: ClosedRange<Double> = 0.3...0.75
    /// A squiggle narrower than this fraction of the screen's width is short enough to be a title.
    static let shortFraction: CGFloat = 0.45
    static let shortBand: ClosedRange<CGFloat> = 0.35...0.55
    /// An outline narrower than this fraction of the screen is a small control, not a block.
    static let smallFraction: CGFloat = 0.3
    /// A small outline at least this round, and about as tall as wide, is a circle.
    static let circleRoundness = 0.75
    static let roundRatio: ClosedRange<CGFloat> = 0.75...1.33
    /// A small pill this much wider than tall is a toggle.
    static let toggleRatio: ClosedRange<CGFloat> = 1.34...3
    /// The least an outline on the open canvas measures each way to be a sticky note.
    static let noteSide: CGFloat = 60
    /// A square or circle narrower than this fraction of the screen is a checkbox or radio
    /// button rather than an image or avatar (about 47 points on an iPhone).
    static let tinyFraction: CGFloat = 0.12
    /// An empty circle narrower than this is a radio button rather than an avatar: about
    /// 33 points on an iPhone, halfway between a drawn radio (28–30 pt across) and the
    /// smallest avatar (34 pt and up). The measured width includes the pen's own
    /// thickness, which the earlier 0.08 (31 pt) didn't allow for, so a 30 pt radio
    /// circle measured as wider than the cutoff.
    static let radioFraction: CGFloat = 0.085
    /// `radioFraction` in points on the standard phone, as the model is told it.
    static var radioPoints: Int { Int((radioFraction * DeviceFrame.iPhone.size.width).rounded(.down)) }
    /// An outline at least this many times wider than tall, and no taller than
    /// `progressHeight` screen points, is a progress bar.
    static let progressRatio: CGFloat = 7
    static let progressHeight: CGFloat = 28

    /// Below this score, the winning reading isn't confident even on its own — the low end
    /// of a close call. Matches the upper edge of the 35–65% "gray area" the Lenovo gesture
    /// patent (US10755027B2) uses for the same kind of decision.
    static let closeCallConfidence = 0.65
    /// When the top two scores sit within this of each other, it's a close call even if
    /// the winner looked confident on its own. `magic-pen-expansion.md` §3E.
    static let closeCallMargin = 0.15
}

/// The wording used to explain sketches and boards to a language model. Shared so that
/// every model-backed provider describes them the same way. Measurements are put into
/// words here, because small models judge "wide and flat" better than "5.2 times wider".
enum SketchPrompt {
    /// Where the catalogue's `sketchHint`s go.
    enum HintPlacement: String, Sendable {
        /// Every kind's hint, in the instructions. What the benchmarks up to Stage 4 measured.
        case all
        /// Only the hints for this sketch's own candidates, in its message, so a small
        /// model reads two or three lines that matter rather than ten.
        case candidates
    }

    /// Which placement is in force. In a debug build, `LAYER_SKETCH_HINTS=candidates`
    /// chooses the other, so the benchmark can compare them without rebuilding.
    static var hintPlacement: HintPlacement {
        #if DEBUG
        if let chosen = ProcessInfo.processInfo.environment["LAYER_SKETCH_HINTS"].flatMap(HintPlacement.init) { return chosen }
        #endif
        return .all
    }

    /// The kinds with hints, in the order the model is told them: the common wide shapes
    /// first, then words, then the small controls.
    static let hintOrder: [ElementKind] = [.button, .textField, .image, .title, .body, .checkbox, .radio, .progress, .avatar, .toggle]

    /// One line per kind, such as "- button: a wide pill or rounded box…".
    static func hints(for kinds: [ElementKind]) -> String {
        kinds.compactMap { kind in kind.spec.sketchHint.map { "- \(kind.spec.promptName): \($0)" } }.joined(separator: "\n")
    }

    static var instructions: String {
        PromptOverrides.text(.sketchInstructions, default: defaultInstructions(hintPlacement))
    }

    static func defaultInstructions(_ placement: HintPlacement) -> String {
        let intro = """
            You help a phone app design tool read hand-drawn wireframe sketches. Each message \
            describes one sketch the user drew on a phone screen, what else is on that screen, \
            and what the sketch could be. Its shape alone doesn't settle it, so use the \
            context to choose the one the user most likely meant.
            """
        let outro = """
            You're only asked about sketches the shape rules themselves found ambiguous, and \
            you're given their own ranked, scored guesses — read those scores as real evidence \
            of how the rules see it, not decoration. Answer with your choice, and a runner-up \
            only if a second reading is genuinely plausible.
            """
        switch placement {
        case .all: return "\(intro)\n\nWhat designers usually mean:\n\(hints(for: hintOrder))\n\n\(outro)"
        case .candidates: return "\(intro)\n\n\(outro)"
        }
    }

    static var titleInstructions: String {
        PromptOverrides.text(.titleInstructions, default: """
            You name design boards in an app design tool. Each message describes what is on \
            one board. Answer with a name for the board of two to four words, in title case, \
            and nothing else: no quotation marks, no full stop.
            """)
    }

    /// The name a reading goes by in prompts and in models' answers.
    static func name(for reading: SketchReading) -> String {
        switch reading {
        case .screen: "phoneScreen"
        case .element(let kind): kind.spec.promptName
        case .scratchOut: "scratchOut"
        case .unknown: "unknown"
        }
    }

    static func describe(_ request: SketchRequest) -> String {
        let observation = request.observation
        var sentences: [String]
        switch request.placement {
        case .openCanvas:
            sentences = [
                "The sketch is \(shape(observation.form, bounds: observation.bounds, widthFraction: nil)).",
                "It is drawn on the open canvas, outside any phone screen.",
            ]

        case .onScreen(let local, let existing, let size):
            let position = local.midY < size.height / 3 ? "near the top" : local.midY > size.height * 2 / 3 ? "near the bottom" : "around the middle"
            let shape = shape(observation.form, bounds: local, widthFraction: local.width / size.width)
            sentences = ["The sketch is \(shape).", "It is drawn on a phone screen, \(position)."]
            if existing.isEmpty {
                sentences.append("The screen is empty so far.")
            } else {
                let names = existing.sorted { $0.frame.minY < $1.frame.minY }.map { $0.kind.layerName.lowercased() }
                sentences.append("On the screen so far, top to bottom: \(names.joined(separator: ", ")).")
            }
        }
        let options = request.options.map(name(for:))
        if options.count > 1 {
            sentences.append("It could be: \(options.dropLast().joined(separator: ", ")) or \(options[options.count - 1]).")
            if hintPlacement == .candidates {
                let kinds = request.options.compactMap { if case .element(let kind) = $0 { kind } else { nil } }
                let lines = hints(for: hintOrder.filter(kinds.contains))
                if !lines.isEmpty { sentences.append("\nWhat designers usually mean by these:\n\(lines)") }
            }
        }
        if let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            sentences.append("The designer says of it: “\(prompt)”. Go by what they say.")
        }
        return sentences.joined(separator: " ")
    }

    /// The reading a prompt names outright, such as “a sign up button”, if it is one of
    /// `options`. Longer names are looked for first, so “text field” isn't read as text.
    static func reading(namedIn prompt: String, among options: [SketchReading]) -> SketchReading? {
        let words: [(String, [SketchReading])] = [
            // Before "button" and "bar", which these contain.
            ("checkbox", [.element(.checkbox)]), ("check box", [.element(.checkbox)]), ("tick box", [.element(.checkbox)]),
            ("radio button", [.element(.radio)]), ("radio", [.element(.radio)]),
            ("progress bar", [.element(.progress)]), ("progress", [.element(.progress)]), ("loading bar", [.element(.progress)]),
            ("text field", [.element(.textField)]), ("textfield", [.element(.textField)]),
            ("input", [.element(.textField)]), ("search", [.element(.textField)]), ("field", [.element(.textField)]),
            ("sticky", [.element(.stickyNote)]), ("note", [.element(.stickyNote)]),
            ("button", [.element(.button)]), ("cta", [.element(.button)]),
            ("image", [.element(.image)]), ("photo", [.element(.image)]), ("picture", [.element(.image)]),
            ("heading", [.element(.title)]), ("header", [.element(.title)]), ("title", [.element(.title)]),
            ("divider", [.element(.divider)]), ("separator", [.element(.divider)]),
            ("toggle", [.element(.toggle)]), ("switch", [.element(.toggle)]),
            ("avatar", [.element(.avatar)]), ("profile", [.element(.avatar)]),
            ("screen", [.screen]), ("phone", [.screen]),
            ("paragraph", [.element(.body)]), ("description", [.element(.body)]), ("body", [.element(.body)]),
            ("label", [.element(.text), .element(.body)]), ("text", [.element(.text), .element(.body)]),
        ]
        let lowered = prompt.lowercased()
        for (word, readings) in words where lowered.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
            if let reading = readings.first(where: options.contains) { return reading }
        }
        return nil
    }

    /// The words a prompt gives for the element to show: what is in quotation marks, or
    /// what follows “saying”, “says”, “that reads” or “labelled”.
    static func label(in prompt: String) -> String? {
        let patterns = [
            #"[\"“”']([^\"“”']+)[\"“”']"#,
            #"(?i)\b(?:saying|says|reads|labell?ed|called|named)\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
                  let range = Range(match.range(at: 1), in: prompt)
            else { continue }
            let label = prompt[range].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !label.isEmpty { return label }
        }
        return nil
    }

    /// What is on a board, in a sentence or two, for naming it.
    static func describe(board content: DesignContent) -> String {
        var sentences = [content.screens.count == 1 ? "The board has one screen." : "The board has \(content.screens.count) screens."]
        for screen in content.screens {
            let parts = screen.elements.sorted { $0.frame.minY < $1.frame.minY }.map(describe(element:))
            sentences.append(parts.isEmpty
                ? "\(screen.name) is an empty \(screen.device.name) screen."
                : "\(screen.name), an \(screen.device.name) screen, has from top to bottom: \(parts.joined(separator: ", ")).")
        }
        let loose = content.floating.map { describe(element: $0.element) }
        if !loose.isEmpty { sentences.append("Beside the screens: \(loose.joined(separator: ", ")).") }
        return sentences.joined(separator: " ")
    }

    private static func describe(element: DesignElement) -> String {
        let kind = element.kind.layerName.lowercased()
        if element.kind == .symbol, let symbol = element.symbol { return "a \(symbol.replacingOccurrences(of: ".", with: " ")) icon" }
        guard element.kind.hasText, !element.text.isEmpty else { return "a \(kind)" }
        return "a \(kind) saying “\(element.text.prefix(60))”"
    }

    private static func shape(_ form: SketchObservation.Form, bounds: CGRect, widthFraction: CGFloat?) -> String {
        let length = widthFraction.map { fraction in
            SketchConventions.shortBand.contains(fraction)
                ? "medium-length "
                : fraction < SketchConventions.shortFraction ? "short " : "long "
        } ?? ""
        switch form {
        case .enclosure(let roundness, let inner):
            let ratio = bounds.width / max(bounds.height, 1)
            let proportion = ratio > SketchConventions.wideBand.upperBound
                ? "wide, flat"
                : ratio >= SketchConventions.wideBand.lowerBound
                    ? "somewhat wider than tall"
                    : bounds.height >= bounds.width * SketchConventions.tallRatio ? "tall" : "boxy"
            let corners = roundness > SketchConventions.pillBand.upperBound
                ? "fully rounded ends, like a pill or an oval"
                : roundness >= SketchConventions.pillBand.lowerBound ? "rounded corners" : "squarish corners"
            let inside = switch inner {
            case .none: "empty inside"
            case .cross: "with an X drawn across the inside"
            case .tick: "with a tick drawn inside"
            case .dot: "with a dot in the middle"
            case .other: "with some marks inside"
            }
            // On a screen, say how big it is: a radio button and an avatar (or a checkbox and
            // an image) differ by size alone, which the model can't judge without it.
            // Only for small shapes: for wide boxes the number measurably pulled a button
            // towards a text field, and their size isn't what tells those apart.
            let across = widthFraction.map { $0 < SketchConventions.tinyFraction } == true
                ? " about \(Int(bounds.width.rounded())) points across" : ""
            return "a \(proportion) closed outline\(across) with \(corners), \(inside)"
        case .wave(let humps):
            return "a \(length)squiggle with \(humps) humps, running left to right"
        case .stackedLines(let count):
            return "\(count) straight lines stacked on top of each other"
        case .line:
            return "a single straight horizontal line"
        case .scribble:
            return bounds.width >= bounds.height ? "a \(length)squiggle" : "a loose scribble, taller than it is wide"
        case .scratch(let passes):
            return "a zigzag scrubbed back and forth \(passes) times"
        }
    }
}
