import Foundation
import OrderedJSON

/// A screen read as a model asked for A2UI 1.0 writes it, one message per line (call 9): each time a finished line
/// adds to the screen, the screen so far is handed on, as `OutlineStream` hands on an outline's.
///
/// - Each finished line is decoded only through the importer's guarded `decodeJSON` (F1). It is good when it is a
///   JSON object that is an A2UI 1.0 message (F2). Any other line (not JSON, nested too deep, a bare string, number
///   or null, or JSON that isn't an A2UI 1.0 message) is skipped and reported once, by its line number, here: the
///   importer never sees it.
/// - The good lines go to the importer as they were written, a message per line and never wrapped in an array, with
///   the design's tokens and without trusting Layer's look: a model never picks a number (§14).
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
            if let reason = Self.whyNotAMessage(line) {
                broken.append(A2UIDiagnostic(reason: .parseFailed, path: "line \(number)", message: reason))
            } else {
                good.append(line)
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

    /// Once the answer is complete: the lines that weren't A2UI 1.0 messages, then the last import's diagnostics.
    /// Empty until then, since a screen half written holds references that the lines still to come resolve.
    var diagnostics: [A2UIDiagnostic] {
        isComplete ? broken + lastImport : []
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

    /// Nil when the line is an A2UI 1.0 message: a JSON object whose `version` is "1.0", holding one message, as an
    /// object, beside it. Otherwise why it's skipped.
    private static func whyNotAMessage(_ line: String) -> String? {
        switch A2UIImporter.decodeJSON(Data(line.utf8)) {
        case .tooDeep:
            return "This line is nested more than \(A2UIImporter.maximumJSONDepth) deep, deeper than any A2UI, so it's skipped."
        case .notJSON:
            return "This line isn't JSON, so it's skipped."
        case .value(let value):
            guard let fields = value.objectValue, fields["version"]?.stringValue == "1.0" else {
                return "This line isn't an A2UI 1.0 message, so it's skipped."
            }
            let names = fields.keys.filter { $0 != "version" }
            guard names.count == 1, let name = names.first, messageNames.contains(name), fields[name]?.objectValue != nil else {
                return "This line isn't an A2UI 1.0 message, so it's skipped."
            }
            return nil
        }
    }

    /// A model wrote it, so every node says so; the importer marks what it reads as imported.
    private static func markGenerated(_ node: inout LayerNode) {
        node.source?.origin = .generated
        for index in node.children.indices {
            markGenerated(&node.children[index])
        }
    }
}
