import Foundation

/// What a model is told to write a screen in, and read back with.
enum Format: String {
    /// The indented outline, read by `OutlineStream` and `Outline`.
    case outline
    /// A2UI 1.0, a message per line, read by `A2UIStream`.
    case a2ui
}

/// One screen's scores, from the model's whole answer.
struct ScreenScore {
    /// A tree with something in it that `TreeValidator.fixGenerated` had nothing to fix in; for
    /// A2UI also with no diagnostic but `actionNotRun`.
    var valid = false
    /// Why it isn't valid.
    var problems: [String] = []
    /// Buttons that would be filled as the model wrote them, and after `Outline.withOnePrimaryAction`.
    var filledBeforePolish = 0
    var filledAfterPolish = 0
    /// Nodes given a colour (a tint; "text grey" isn't one).
    var coloured = 0
    /// Different kinds among the leaves.
    var kinds = 0
    var leaves = 0
    var rows = 0
    var cards = 0
    var grids = 0
    /// Outline only: sections the parser made beyond the ones the model's blank lines started, such as a
    /// container 24 points from the lines written right above it.
    var splitSections = 0
    /// Lines of the prompt's examples found in the answer word for word: for the outline, an example line of
    /// more than 12 characters; for A2UI, a text of more than 12 characters that an example's component holds.
    var copiedLines = 0

    var line: String {
        "--- valid=\(valid ? 1 : 0)\(problems.isEmpty ? "" : " (\(problems.joined(separator: "; ")))") "
            + "filledBefore=\(filledBeforePolish) filledAfter=\(filledAfterPolish) coloured=\(coloured) "
            + "kinds=\(kinds) leaves=\(leaves) rows=\(rows) cards=\(cards) grids=\(grids) "
            + "split=\(splitSections) copied=\(copiedLines)"
    }
}

enum Score {
    // MARK: The outline

    static func outline(_ text: String) -> ScreenScore {
        var root = Outline.parse(text, isComplete: true, tokens: .standard)
        var score = tree(root)
        score.filledBeforePolish = filledAsWritten(text)
        score.splitSections = max(0, root.children.count - sectionsAsWritten(text))
        score.copiedLines = ScreenPrompt.library
            .flatMap { $0.lines.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 12 && text.contains($0) }
            .count
        let fixes = TreeValidator.fixGenerated(&root)
        score.valid = score.leaves > 0 && fixes.isEmpty
        if score.leaves == 0 { score.problems.append("nothing in it") }
        if !fixes.isEmpty { score.problems.append("fixed: " + fixes.map { "\($0.kind)" }.joined(separator: ", ")) }
        return score
    }

    /// The buttons an outline asks to be filled as it is written, before `withOnePrimaryAction` keeps one. Its lines
    /// are read as `Outline` reads them: semicolons are line breaks, indents and list marks are passed over, an opener
    /// holds no element itself, and a one-line row holds its `|`-separated elements.
    static func filledAsWritten(_ text: String) -> Int {
        var count = 0
        for raw in lines(of: text) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("- ") || line.hasPrefix("• ") { line = String(line.dropFirst(2)) }
            let lower = line.lowercased()
            var items = [line]
            if let prefix = ["row:", "row -", "side by side:"].first(where: { lower.hasPrefix($0) }) {
                items = line.dropFirst(prefix.count).split(separator: "|").map(String.init)
            } else if lower == "column:" || lower == "card:" || (lower.hasPrefix("grid") && lower.hasSuffix(":")) {
                items = []
            }
            count += items.filter(isFilledButton).count
        }
        return count
    }

    /// Whether `item`, written `kind: words [look]`, is a button with no look or a filled one.
    private static func isFilledButton(_ item: String) -> Bool {
        var text = item.trimmingCharacters(in: .whitespaces)
        var look: [String] = []
        if let open = text.lastIndex(of: "["), text.hasSuffix("]") {
            look = text[text.index(after: open)..<text.index(before: text.endIndex)].split(separator: ",").map(String.init)
            text = String(text[..<open])
        }
        let name = text.firstIndex(of: ":").map { String(text[..<$0]) } ?? text
        guard LookWords.kind(named: name) == .button else { return false }
        let buttonLook = LookWords.look(from: look).buttonLook
        return buttonLook == nil || buttonLook == .filled
    }

    /// How many sections the model's blank lines make: runs of lines, each begun by the first line or by a top-level
    /// line after a blank one. A blank line before an indented line doesn't end its container, as in `Outline`.
    static func sectionsAsWritten(_ text: String) -> Int {
        var sections = 0
        var inSection = false
        var blank = false
        for raw in lines(of: text) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.allSatisfy({ $0 == "-" }) {
                blank = true
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("#") { continue }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            if !inSection || (blank && indent < 2) { sections += 1 }
            inSection = true
            blank = false
        }
        return sections
    }

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: ";", with: "\n").components(separatedBy: .newlines)
    }

    // MARK: A2UI

    static func a2ui(_ text: String) -> ScreenScore {
        var stream = A2UIStream(tokens: .standard)
        let root = stream.take(text, isComplete: true) ?? LayerNode(kind: .group)
        var score = tree(root)
        let asWritten = A2UIImporter.importJSON(Data(text.utf8), tokens: .standard, trustsLayerLook: false).screens.first?.root
        score.filledBeforePolish = asWritten.map(filled) ?? 0
        let texts = Set(leaves(of: root).compactMap(\.content.text))
        score.copiedLines = exampleTexts.filter(texts.contains).count
        var fixed = root
        let fixes = TreeValidator.fixGenerated(&fixed)
        let diagnostics = stream.diagnostics.filter { $0.reason != .actionNotRun }
        score.valid = score.leaves > 0 && fixes.isEmpty && diagnostics.isEmpty
        if score.leaves == 0 { score.problems.append("nothing in it") }
        if !fixes.isEmpty { score.problems.append("fixed: " + fixes.map { "\($0.kind)" }.joined(separator: ", ")) }
        for diagnostic in diagnostics {
            score.problems.append("\(diagnostic.reason)\(diagnostic.componentID.map { " " + $0 } ?? "")\(diagnostic.path.map { " " + $0 } ?? ""): \(diagnostic.message)")
        }
        return score
    }

    /// The texts of more than 12 characters that the A2UI examples' components hold.
    private static let exampleTexts: Set<String> = Set(A2UIPrompt.library.flatMap { example in
        A2UIImporter.importJSON(Data(example.lines.utf8), tokens: .standard, trustsLayerLook: false).screens
            .flatMap { leaves(of: $0.root) }
            .compactMap(\.content.text)
            .filter { $0.count > 12 }
    })

    // MARK: Trees

    /// The scores a tree gives whatever it was written in.
    private static func tree(_ root: LayerNode) -> ScreenScore {
        var score = ScreenScore()
        let leaves = leaves(of: root)
        score.leaves = leaves.count
        score.kinds = Set(leaves.map(\.kind)).count
        score.filledAfterPolish = filled(root)
        score.coloured = all(root).filter { $0.style.tint != nil }.count
        for node in all(root).dropFirst() where node.isContainer {
            if node.kind == .card {
                score.cards += 1
                continue
            }
            switch node.resolvedLayout {
            case .grid: score.grids += 1
            case .stack(let stack) where stack.axis == .horizontal: score.rows += 1
            default: break
            }
        }
        return score
    }

    /// The buttons that are filled: with no look, or a filled one.
    private static func filled(_ root: LayerNode) -> Int {
        all(root).filter { $0.kind == .button && ($0.content.buttonLook == nil || $0.content.buttonLook == .filled) }.count
    }

    private static func all(_ node: LayerNode) -> [LayerNode] {
        [node] + node.children.flatMap(all)
    }

    private static func leaves(of node: LayerNode) -> [LayerNode] {
        all(node).filter { !$0.isContainer }
    }
}

/// What a run of screens adds up to.
struct Summary {
    var label: String
    var scores: [ScreenScore] = []
    /// Screens the model gave no answer for, with why.
    var errors: [String] = []
    var firstContent: [Duration] = []
    var completion: [Duration] = []
    var outputTokens: [Int] = []

    var line: String {
        let count = scores.count + errors.count
        func perScreen(_ value: (ScreenScore) -> Int) -> String {
            count == 0 ? "-" : String(format: "%.1f", Double(scores.map(value).reduce(0, +)) / Double(count))
        }
        var parts = [
            "screens=\(count)",
            "valid=\(scores.filter(\.valid).count)",
            "errors=\(errors.count)",
            "screens>1filledBeforePolish=\(scores.filter { $0.filledBeforePolish > 1 }.count)",
            "screens>1filledAfterPolish=\(scores.filter { $0.filledAfterPolish > 1 }.count)",
            "colouredNodes=\(scores.map(\.coloured).reduce(0, +))",
            "kinds/screen=\(perScreen(\.kinds))",
            "leaves/screen=\(perScreen(\.leaves))",
            "rows/screen=\(perScreen(\.rows))",
            "cards/screen=\(perScreen(\.cards))",
            "grids/screen=\(perScreen(\.grids))",
            "splitSections=\(scores.map(\.splitSections).reduce(0, +))",
            "copiedExampleLines=\(scores.map(\.copiedLines).reduce(0, +))",
            "firstContent p50=\(Self.milliseconds(firstContent, 0.5)) p95=\(Self.milliseconds(firstContent, 0.95)) ms",
            "completion p50=\(Self.milliseconds(completion, 0.5)) p95=\(Self.milliseconds(completion, 0.95)) ms",
        ]
        if !outputTokens.isEmpty {
            parts.append("outputTokens total=\(outputTokens.reduce(0, +)) p50=\(Self.percentile(outputTokens, 0.5)) max=\(outputTokens.max() ?? 0)")
        }
        return "SUMMARY \(label): " + parts.joined(separator: " ")
    }

    /// The nearest-rank percentile, in whole milliseconds.
    private static func milliseconds(_ durations: [Duration], _ fraction: Double) -> String {
        guard !durations.isEmpty else { return "-" }
        let values = durations.map { Int(($0 / .milliseconds(1)).rounded()) }
        return "\(percentile(values, fraction))"
    }

    private static func percentile(_ values: [Int], _ fraction: Double) -> Int {
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
