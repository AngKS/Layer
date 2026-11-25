import Foundation
import OrderedJSON

/// A screen read as a model asked for A2UI 1.0 writes it, one message per line (call 9): each time a finished line
/// adds to the screen, the screen so far is handed on, as `OutlineStream` hands on an outline's.
///
/// - Each finished line is decoded only through the importer's guarded `decodeJSON` (F1). It is good when it is a
///   JSON object that is an A2UI 1.0 message (F2). Any other line (not JSON, nested too deep, a bare string, number
///   or null, or JSON that isn't an A2UI 1.0 message) is skipped and reported once, by its line number, here: the
///   importer never sees it. There is one mend, which changes no text: a raw control character inside a string, such
///   as a tab, is escaped (2026-11-26). A slip in the JSON itself, a comma, colon or bracket, is never guessed at.
/// - The good lines go to the importer as they were written, a message per line and never wrapped in an array, with
///   the design's tokens and without trusting Layer's look: a model never picks a number (§14). The one change is to
///   an `Icon` a model named outside A2UI's set, which is read as the model meant it (`A2UIIcons.meant(byIconNamed:)`),
///   as an outline's `symbol:` line is read.
/// - A component a later line writes again, differently, is said (`noteRewrites`), as the importer says two
///   components with one id in one message.
/// - An answer that ends with no good line was most likely pretty-printed, so it is read whole, as one payload. Its
///   lines' failures are dropped, since they were parts of that payload.
/// - Blank lines, code fences and the half-written last line are passed over.
///
/// Each screen handed on is keyed by its component ids, with ids fresh from the import, so the reconciler maps the
/// keys to the ids the screen already has. It builds on macOS, for the screen harness.
struct A2UIStream: Sendable {
    private let tokens: DesignTokens
    /// How many of the answer's lines have been looked at.
    private var linesLooked = 0
    /// The lines that are A2UI 1.0 messages, as written.
    private var good: [String] = []
    /// How many good lines the last import read.
    private var goodImported = 0
    /// One for each line that isn't an A2UI 1.0 message.
    private var broken: [A2UIDiagnostic] = []
    /// Each component the good lines wrote, by its surface and id, as written.
    private var written: [String: OrderedJSON.JSONValue] = [:]
    /// One for each component a line wrote again, differently, after an earlier line wrote it.
    private var rewritten: [A2UIDiagnostic] = []
    /// What the last import couldn't bring in.
    private var lastImport: [A2UIDiagnostic] = []
    /// The leaves of the last screen handed on.
    private var handedOn = 0
    private var isComplete = false

    /// `tokens` are the design's: the screen's spacings and a card's padding come from them, never from the model.
    init(tokens: DesignTokens) {
        self.tokens = tokens
    }

    /// The screen so far when it has more leaves than the last one handed on; nil otherwise. `text` is the whole
    /// answer so far; when it isn't complete, its last line may be half written and waits.
    mutating func take(_ text: String, isComplete: Bool) -> LayerNode? {
        var lines = Self.lines(of: text)
        if !isComplete { lines.removeLast() }
        self.isComplete = isComplete
        while linesLooked < lines.count {
            let number = linesLooked + 1
            let line = lines[linesLooked].trimmingCharacters(in: .whitespacesAndNewlines)
            linesLooked += 1
            guard !line.isEmpty, !Self.isFence(line) else { continue }
            switch Self.read(line) {
            case .skipped(let reason):
                broken.append(A2UIDiagnostic(reason: .parseFailed, path: "line \(number)", message: reason))
            case .message(let message, let value):
                good.append(message)
                noteRewrites(in: value, line: number)
            }
        }

        let payload: String
        if isComplete, good.isEmpty {
            // Pretty-printed, most likely: its lines were parts of one payload, so they aren't reported one by one.
            broken = []
            payload = lines.filter { !Self.isFence($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.joined(separator: "\n")
            guard !payload.allSatisfy(\.isWhitespace) else { return nil }
        } else {
            guard good.count > goodImported else { return nil }
            goodImported = good.count
            payload = good.joined(separator: "\n")
        }

        let imported = A2UIImporter.importJSON(Data(payload.utf8), tokens: tokens, trustsLayerLook: false)
        lastImport = imported.diagnostics
        guard var root = imported.screens.first?.root else { return nil }
        root = Outline.withOnePrimaryAction(root)
        Self.markGenerated(&root)
        guard root.leafCount > handedOn else { return nil }
        handedOn = root.leafCount
        return root
    }

    /// Once the answer is complete: the lines that weren't A2UI 1.0 messages, the components written again
    /// differently, then the last import's diagnostics. Empty until then, since a screen half written holds references
    /// that the lines still to come resolve.
    var diagnostics: [A2UIDiagnostic] {
        isComplete ? broken + rewritten + lastImport : []
    }

    /// Says each component `message` writes that an earlier line wrote differently. A model is told to write each
    /// component once, a component a message, so the same id given to two components is a component written again: the
    /// later one is used, as A2UI says, and what was written first isn't on the screen, which is said, as the importer
    /// says two components with one id in one message (2026-11-26). Written again the same, it changes nothing.
    private mutating func noteRewrites(in message: OrderedJSON.JSONValue, line number: Int) {
        guard let update = message.objectValue?["updateComponents"]?.objectValue,
              let surface = update["surfaceId"]?.stringValue,
              let components = update["components"]?.arrayValue
        else { return }
        var now: [String: OrderedJSON.JSONValue] = [:]
        for component in components {
            guard let id = component.objectValue?["id"]?.stringValue else { continue }
            let key = surface + "\u{0}" + id
            if let earlier = written[key], earlier != component {
                rewritten.append(A2UIDiagnostic(
                    reason: .duplicateID, componentID: id, path: "line \(number)",
                    message: "An earlier line wrote a different component with this id, so this later one is used."))
            }
            now[key] = component
        }
        written.merge(now) { _, new in new }
    }

    // MARK: Lines

    /// The answer's lines, split at the newline byte as the importer splits them: JSON never holds one in a string.
    private static func lines(of text: String) -> [String] {
        text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(Substring($0)) }
    }

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("```")
    }

    /// The A2UI 1.0 messages: each is one of these, beside its `version`.
    private static let messageNames: Set<String> = [
        "createSurface", "updateComponents", "updateDataModel", "deleteSurface", "callRendererFunction", "agentFunctionResponse",
    ]

    /// A line as it is read: the message the importer is given, as text and decoded, or why it's skipped.
    private enum Reading {
        case message(String, OrderedJSON.JSONValue)
        case skipped(String)
    }

    /// A line read as a model's message (`message(in:)`). A line that isn't JSON only because a string in it holds a
    /// raw control character, such as a tab, is read with each of those escaped, which is the same text: that is the
    /// only mend, and it is said nowhere. Any other slip is never guessed at, so the line is skipped. Each `Icon` in a
    /// message is then what the model meant by it (`A2UIIcons.meant(byIconNamed:)`).
    private static func read(_ line: String) -> Reading {
        var text = line
        var decoded = message(in: line)
        if case .skipped = decoded, let escaped = escapingControlCharacters(in: line), case .message(let value) = message(in: escaped) {
            text = escaped
            decoded = .message(value)
        }
        switch decoded {
        case .skipped(let reason):
            return .skipped(reason)
        case .message(let value):
            guard let meant = iconsAsMeant(in: value), let written = try? meant.serialized() else { return .message(text, value) }
            return .message(written, meant)
        }
    }

    /// A line decoded as an A2UI 1.0 message: a JSON object whose `version` is "1.0", holding one message, as an
    /// object, beside it. Otherwise why it's skipped.
    private static func message(in line: String) -> Decoded {
        switch A2UIImporter.decodeJSON(Data(line.utf8)) {
        case .tooDeep:
            return .skipped("This line is nested more than \(A2UIImporter.maximumJSONDepth) deep, deeper than any A2UI, so it's skipped.")
        case .notJSON:
            return .skipped("This line isn't JSON, so it's skipped.")
        case .value(let value):
            guard let fields = value.objectValue, fields["version"]?.stringValue == "1.0" else {
                return .skipped("This line isn't an A2UI 1.0 message, so it's skipped.")
            }
            let names = fields.keys.filter { $0 != "version" }
            guard names.count == 1, let name = names.first, messageNames.contains(name), fields[name]?.objectValue != nil else {
                return .skipped("This line isn't an A2UI 1.0 message, so it's skipped.")
            }
            return .message(value)
        }
    }

    /// A line decoded: the message, or why it's skipped.
    private enum Decoded {
        case message(OrderedJSON.JSONValue)
        case skipped(String)
    }

    /// The line with each raw control character inside a string written as JSON writes it (`\t`, `\u0001`); nil when
    /// there is none. One outside a string is left as it is, so the line still isn't JSON.
    private static func escapingControlCharacters(in line: String) -> String? {
        var escaped = ""
        var changed = false
        var inString = false
        var afterBackslash = false
        for scalar in line.unicodeScalars {
            if inString, scalar.value < 0x20 {
                changed = true
                afterBackslash = false
                switch scalar {
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                case "\n": escaped += "\\n"
                case "\u{8}": escaped += "\\b"
                case "\u{C}": escaped += "\\f"
                default: escaped += String(format: "\\u%04x", scalar.value)
                }
                continue
            }
            escaped.unicodeScalars.append(scalar)
            if afterBackslash {
                afterBackslash = false
            } else if inString, scalar == "\\" {
                afterBackslash = true
            } else if scalar == "\"" {
                inString.toggle()
            }
        }
        return changed ? escaped : nil
    }

    /// `message` with each `Icon` named outside A2UI's set as the model meant it (`A2UIIcons.meant(byIconNamed:)`):
    /// A2UI's icon of the same letters, or Layer's own symbol by the name as written. Layer's symbol is in Layer's
    /// catalogue, so an Icon that names another catalogue of its own is left as written. Nil when there is none.
    private static func iconsAsMeant(in message: OrderedJSON.JSONValue) -> OrderedJSON.JSONValue? {
        guard case .object(var fields) = message, case .object(var update)? = fields["updateComponents"],
              case .array(var components)? = update["components"]
        else { return nil }
        var changed = false
        for index in components.indices {
            guard case .object(var component) = components[index], component["component"]?.stringValue == "Icon",
                  let name = component["name"]?.stringValue
            else { continue }
            switch A2UIIcons.meant(byIconNamed: name) {
            case .icon(let a2uiName) where a2uiName == name:
                continue
            case .icon(let a2uiName):
                component["name"] = .string(a2uiName)
            case .symbol(let symbol):
                guard component["@catalogId"].map({ $0.stringValue == LayerCatalog.id }) ?? true else { continue }
                component["component"] = .string("LayerSymbol")
                component["name"] = .string(symbol)
            }
            components[index] = .object(component)
            changed = true
        }
        guard changed else { return nil }
        update["components"] = .array(components)
        fields["updateComponents"] = .object(update)
        return .object(fields)
    }

    /// A model wrote it, so every node says so; the importer marks what it reads as imported.
    private static func markGenerated(_ node: inout LayerNode) {
        node.source?.origin = .generated
        for index in node.children.indices {
            markGenerated(&node.children[index])
        }
    }
}
