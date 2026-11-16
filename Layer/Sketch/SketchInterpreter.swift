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
    /// it can't be anything. A clear shape has one candidate. A shape near one of the
    /// conventions' dividing lines has the candidates from both sides of that line, and
    /// choosing between them is a judgement call.
    var candidates: [SketchReading] {
        if case .scratch = observation.form { return [.scratchOut] }
        switch placement {
        case .openCanvas:
            let bounds = observation.bounds
            switch observation.form {
            case .enclosure(_, .none) where bounds.height >= bounds.width * SketchConventions.tallRatio && bounds.height >= 160:
                return [.screen]
            case .enclosure where min(bounds.width, bounds.height) >= SketchConventions.noteSide:
                // A box beside the screens is a note about them.
                return [.element(.stickyNote)]
            case .wave, .stackedLines:
                // Only writing-like marks: a stray stroke beside the screens stays ink.
                return bounds.width >= max(bounds.height, 40) ? [.element(.text)] : []
            default:
                return []
            }

        case .onScreen(let local, _, let size):
            switch observation.form {
            case .enclosure(_, _) where local.width / max(local.height, 1) >= SketchConventions.progressRatio
                && local.height <= SketchConventions.progressHeight:
                // A long, thin outline is a progress bar, however it is filled in.
                return [.element(.progress)]
            case .enclosure(let roundness, let inner) where local.width / size.width < SketchConventions.smallFraction:
                return Self.smallControl(local: local, size: size, roundness: roundness, inner: inner)
            case .enclosure(_, .cross):
                return [.element(.image)]
            case .enclosure(let roundness, _):
                let ratio = local.width / max(local.height, 1)
                var options: [SketchReading] = []
                if ratio <= SketchConventions.wideBand.upperBound { options.append(.element(.image)) }
                if ratio >= SketchConventions.wideBand.lowerBound {
                    if roundness >= SketchConventions.pillBand.lowerBound { options.append(.element(.button)) }
                    if roundness <= SketchConventions.pillBand.upperBound { options.append(.element(.textField)) }
                }
                return options
            case .stackedLines:
                return [.element(.body)]
            case .line:
                return [.element(.divider)]
            case .wave, .scribble:
                guard local.width >= local.height else { return [] }
                let isLong = local.width / size.width > SketchConventions.shortBand.upperBound
                return isLong ? [.element(.body)] : [.element(.title), .element(.body)]
            case .scratch:
                return [.scratchOut]
            }
        }
    }
}

extension SketchRequest {
    /// What a small outline on a screen could be. Tiny squares are checkboxes and tiny
    /// circles radio buttons; a little larger, circles are avatars and pills toggles.
    static func smallControl(local: CGRect, size: CGSize, roundness: Double, inner: SketchObservation.InnerMark) -> [SketchReading] {
        let ratio = local.width / max(local.height, 1)
        let fraction = local.width / size.width
        let isRound = roundness >= SketchConventions.circleRoundness
        if SketchConventions.roundRatio.contains(ratio), fraction < SketchConventions.tinyFraction {
            if !isRound { return [.element(.checkbox)] }
            // A dot in the middle selects a radio button; a very small empty circle is one too.
            if inner == .dot || (inner == .none && fraction < SketchConventions.radioFraction) { return [.element(.radio)] }
        }
        if inner == .cross { return [.element(.image)] }
        if isRound, SketchConventions.roundRatio.contains(ratio) {
            return [.element(.avatar)]
        }
        if roundness >= SketchConventions.pillBand.lowerBound, SketchConventions.toggleRatio.contains(ratio) {
            return [.element(.toggle)]
        }
        return ratio <= SketchConventions.wideBand.upperBound ? [.element(.image)] : [.element(.textField)]
    }
}

extension SketchRequest {
    /// What the sketch could mean when someone asks for it to be read: what its shape
    /// suggests first, then anything else that belongs where it was drawn, since they want
    /// it to become something.
    var askedCandidates: [SketchReading] {
        let shaped = candidates.filter { $0 != .scratchOut }
        let rest: [SketchReading] = switch placement {
        case .openCanvas: [.element(.text), .element(.stickyNote), .screen]
        case .onScreen: [ElementKind.title, .body, .image, .button, .textField, .divider, .toggle, .avatar, .checkbox, .radio, .progress].map(SketchReading.element)
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
        guard case .enclosure(_, let inner) = observation.form else { return }
        switch kind {
        case .toggle:
            if let knob = observation.innerBounds { isOn = knob.midX >= 0.5 }
        case .checkbox, .radio:
            isOn = inner != .none
        case .progress:
            // To the nearest 5%; unshaded bars start half full.
            if let shading = observation.innerBounds { value = (Double(min(max(shading.maxX, 0), 1)) * 20).rounded() / 20 }
        default:
            break
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

/// Something that can read sketches and name boards. Given a sketch, it returns one of
/// the request's `candidates`. Apple Intelligence is the built-in one; a hosted model is
/// added by writing another conforming type and listing it in `SketchProvider.all`.
protocol SketchInterpreter: Sendable {
    func read(_ request: SketchRequest) async throws -> SketchReading
    /// A short name for a board, given `SketchPrompt.describe(board:)` of its design.
    func suggestTitle(for board: String) async throws -> String
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
    /// An empty circle narrower than this is a radio button rather than an avatar.
    static let radioFraction: CGFloat = 0.08
    /// An outline at least this many times wider than tall, and no taller than
    /// `progressHeight` screen points, is a progress bar.
    static let progressRatio: CGFloat = 7
    static let progressHeight: CGFloat = 28
}

/// The wording used to explain sketches and boards to a language model. Shared so that
/// every model-backed provider describes them the same way. Measurements are put into
/// words here, because small models judge "wide and flat" better than "5.2 times wider".
enum SketchPrompt {
    static let instructions = """
        You help a phone app design tool read hand-drawn wireframe sketches. Each message \
        describes one sketch the user drew on a phone screen, what else is on that screen, \
        and what the sketch could be. Its shape alone doesn't settle it, so use the \
        context to choose the one the user most likely meant.

        What designers usually mean:
        - button: a wide pill or rounded box. Usually near the bottom of a screen, and a \
        screen rarely has more than one or two.
        - textField: a wide box with squarish or slightly rounded corners. Often stacked \
        with other text fields in the upper or middle part of a screen.
        - image: a large box, about as tall as it is wide or taller.
        - title: a short squiggle near the top. A screen has one title.
        - bodyText: a longer squiggle, or a squiggle below a title or an image.
        - checkbox: a tiny square, often with a tick or an X in it, usually beside a label.
        - radioButton: a tiny circle, often with a dot in it, usually one of a column of them.
        - progressBar: a long, very thin outline, often partly shaded in.
        """

    static let titleInstructions = """
        You name design boards in an app design tool. Each message describes what is on \
        one board. Answer with a name for the board of two to four words, in title case, \
        and nothing else: no quotation marks, no full stop.
        """

    /// The name a reading goes by in prompts and in models' answers.
    static func name(for reading: SketchReading) -> String {
        switch reading {
        case .screen: "phoneScreen"
        case .element(.title): "title"
        case .element(.body): "bodyText"
        case .element(.image): "image"
        case .element(.button): "button"
        case .element(.textField): "textField"
        case .element(.divider): "divider"
        case .element(.symbol): "symbol"
        case .element(.text): "text"
        case .element(.stickyNote): "stickyNote"
        case .element(.toggle): "toggle"
        case .element(.avatar): "avatar"
        case .element(.checkbox): "checkbox"
        case .element(.radio): "radioButton"
        case .element(.progress): "progressBar"
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
            return "a \(proportion) closed outline with \(corners), \(inside)"
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
