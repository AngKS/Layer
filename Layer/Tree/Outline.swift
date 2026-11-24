import CoreGraphics
import Foundation

/// The compact indented format the on-device model writes whole screens in (spec §6):
///
///     column:
///       title: Profile
///       row:
///         avatar
///         text: Alex Tan [bold]
///       card:
///         text: About me
///       grid 2:
///         text: 24 Projects
///         text: 8 Teams
///     row: text: Wi-Fi | toggle [on]
///
/// It reads into a `LayerNode` tree. Parsing is tolerant and streaming: it never throws, and
/// each finished line extends the tree.
enum Outline {
    /// The deepest a container may nest. A line that would open a deeper one is read as its
    /// children's sibling instead, so a runaway outline can't build a runaway tree.
    static let maxNesting = 30

    /// The screen root: a column with spacing 24 holding the outline's sections. A run of lines
    /// at the top level is a section (a column, spacing 12), ended by a blank line. A container
    /// written straight after a section's lines, with no blank line between, joins that section,
    /// so a heading stays with the grid under it and a form's fields with the row among them. A
    /// container that starts a section, first or after a blank line, is a section of its own,
    /// and the lines after it start the next one; a one-line row aside, which begins a section
    /// the lines after it join.
    /// When `isComplete` is false the last line is ignored, since it may be half written.
    /// Each node's `source.key` is its path of `kind:ordinal` steps from the root, where a
    /// container's kind is `row`, `column`, `grid`, `card` or, for an implicit section, `group`.
    static func parse(_ text: String, isComplete: Bool) -> LayerNode {
        parse(text, isComplete: isComplete, tokens: .standard)
    }

    /// As `parse(_:isComplete:)`, with the spacings the design's tokens give: the screen root 24, sections, `column:`,
    /// rows and grids 12, and cards 8 each become `tokens.spacing(nearest:)`, and a card's padding is `tokens.card.padding`.
    /// `readsTextSizes` is false for an outline a model wrote (generation and Build Screen): no model picks a number
    /// (spec §14), so a size such as `28pt` is passed over and the kind keeps its token size. Its other looks apply.
    static func parse(_ text: String, isComplete: Bool, tokens: DesignTokens, readsTextSizes: Bool = true) -> LayerNode {
        var builder = Builder(tokens: tokens, readsTextSizes: readsTextSizes)
        var lines = text.replacingOccurrences(of: ";", with: "\n").components(separatedBy: .newlines)
        if !isComplete, !lines.isEmpty { lines.removeLast() }
        for line in lines { builder.add(line) }
        return builder.finish()
    }

    // MARK: Building

    private struct Frame {
        var node: LayerNode
        /// The indent step its line was written at; the root is -1.
        var depth: Int
        /// At the top level: it belongs to the section being collected, as a one-line `row: a | b`
        /// does, and a container written straight after the section's lines.
        var joinsSection = false
    }

    private struct Builder {
        let tokens: DesignTokens
        let readsTextSizes: Bool
        var frames: [Frame]
        /// The run of top-level leaves being collected, not yet in the root.
        var section: LayerNode?
        var breakPending = false

        init(tokens: DesignTokens, readsTextSizes: Bool) {
            self.tokens = tokens
            self.readsTextSizes = readsTextSizes
            frames = [Frame(node: Outline.root(tokens), depth: -1)]
        }

        mutating func add(_ rawLine: String) {
            var (steps, line) = Outline.indent(of: rawLine)
            if line.isEmpty || line.allSatisfy({ $0 == "-" }) {
                breakPending = true
                return
            }
            if line.hasPrefix("```") || line.hasPrefix("#") { return }
            if line.hasPrefix("- ") || line.hasPrefix("• ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { return }
            }

            while frames.count > 1, frames[frames.count - 1].depth >= steps { pop() }
            steps = min(steps, frames[frames.count - 1].depth + 1)
            defer { breakPending = false }
            if steps == 0, breakPending { closeSection() }

            if let opener = Outline.container(from: line, tokens: tokens) {
                guard frames.count <= Outline.maxNesting else { return }
                // Decided as it opens, so its key never changes as the lines after it come.
                let joinsSection = frames.count == 1 && (opener.inlineItems != nil || section != nil)
                var container = opener.node
                if let items = opener.inlineItems {
                    container.children = items.compactMap { Outline.leaf($0, readsTextSizes: readsTextSizes) }
                }
                frames.append(Frame(node: container, depth: steps, joinsSection: joinsSection))
            } else if let leaf = Outline.leaf(line, readsTextSizes: readsTextSizes) {
                if frames.count == 1 {
                    section = section ?? Outline.section(tokens)
                    section?.children.append(leaf)
                } else {
                    frames[frames.count - 1].node.children.append(leaf)
                }
            }
        }

        /// Closes the innermost container into its parent.
        private mutating func pop() {
            let frame = frames.removeLast()
            guard !frame.node.children.isEmpty else { return }
            if frames.count == 1 {
                if frame.joinsSection {
                    section = section ?? Outline.section(tokens)
                    section?.children.append(frame.node)
                } else {
                    closeSection()
                    frames[0].node.children.append(frame.node)
                }
            } else {
                frames[frames.count - 1].node.children.append(frame.node)
            }
        }

        private mutating func closeSection() {
            if let section, !section.children.isEmpty { frames[0].node.children.append(section) }
            section = nil
        }

        mutating func finish() -> LayerNode {
            while frames.count > 1 { pop() }
            closeSection()
            var root = frames[0].node
            Outline.keyAndPolish(&root)
            return root
        }
    }

    // MARK: Lines

    /// A line's indent in steps of two spaces (a tab is one step), and the line without it.
    private static func indent(of raw: String) -> (steps: Int, line: String) {
        var width = 0
        for character in raw {
            if character == "\t" { width += 2 } else if character == " " { width += 1 } else { break }
        }
        return (width / 2, raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A container opener, with the items an inline row carries.
    private static func container(from line: String, tokens: DesignTokens) -> (node: LayerNode, inlineItems: [String]?)? {
        let lower = line.lowercased()
        if lower == "column:" { return (makeColumn(spacing: tokens.spacing(nearest: 12)), nil) }
        if lower == "card:" { return (makeCard(tokens), nil) }
        if lower.hasPrefix("grid"), lower.hasSuffix(":") {
            let count = lower.dropFirst(4).dropLast().trimmingCharacters(in: .whitespaces)
            if count.isEmpty { return (makeGrid(columns: 2, tokens), nil) }
            if let columns = Int(count) { return (makeGrid(columns: columns, tokens), nil) }
            return nil
        }
        // The blueprint's other spellings of a row: `row - …` and `side by side: …`.
        let rowPrefix = ["row:", "row -", "side by side:"].first { lower.hasPrefix($0) }
        if let rowPrefix {
            let rest = String(line.dropFirst(rowPrefix.count)).trimmingCharacters(in: .whitespaces)
            let items = rest.isEmpty ? nil : rest.split(separator: "|").map(String.init)
            return (makeRow(tokens), items)
        }
        return nil
    }

    /// A leaf from `kind: words [look, …]`; a line with no known kind is text. Without `readsTextSizes` a look's text
    /// size is passed over.
    private static func leaf(_ written: String, readsTextSizes: Bool) -> LayerNode? {
        var text = written.trimmingCharacters(in: .whitespaces)
        var look: [String] = []
        if let open = text.lastIndex(of: "["), text.hasSuffix("]") {
            look = text[text.index(after: open)..<text.index(before: text.endIndex)]
                .split(separator: ",").map { String($0) }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty || !look.isEmpty else { return nil }

        var kind = ElementKind.text
        if let colon = text.firstIndex(of: ":"), let named = LookWords.kind(named: String(text[..<colon])) {
            kind = named
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else if let named = LookWords.kind(named: text) {
            kind = named
            text = ""
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))

        var node = LayerNode(kind: kind)
        node.source = LayerNode.Source(origin: .generated, key: nil)
        (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
        if kind == .symbol {
            node.content.symbol = text.isEmpty ? "star" : text
        } else {
            node.content.text = text.isEmpty ? kind.placeholder : text
        }
        var asked = LookWords.look(from: look)
        if !readsTextSizes { asked.fontSize = nil }
        asked.apply(to: &node)
        return node
    }

    // MARK: Containers

    private static func container(kind: ElementKind, layout: LayerNode.Layout) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.layout = layout
        node.source = LayerNode.Source(origin: .generated, key: nil)
        node.width = LayerNode.Sizing(.fill(weight: 1))
        node.height = LayerNode.Sizing(.fit)
        return node
    }

    private static func column(spacing: CGFloat, alignment: LayerNode.CrossAlignment = .start) -> LayerNode.Layout {
        .stack(LayerNode.Stack(axis: .vertical, spacing: spacing, alignment: alignment))
    }

    private static func root(_ tokens: DesignTokens) -> LayerNode {
        container(kind: .group, layout: column(spacing: tokens.spacing(nearest: 24)))
    }
    private static func section(_ tokens: DesignTokens) -> LayerNode { makeColumn(spacing: tokens.spacing(nearest: 12)) }
    private static func makeColumn(spacing: CGFloat) -> LayerNode { container(kind: .group, layout: column(spacing: spacing)) }

    private static func makeRow(_ tokens: DesignTokens) -> LayerNode {
        container(kind: .group, layout: .stack(LayerNode.Stack(axis: .horizontal, spacing: tokens.spacing(nearest: 12), alignment: .center)))
    }

    private static func makeGrid(columns: Int, _ tokens: DesignTokens) -> LayerNode {
        let gap = tokens.spacing(nearest: 12)
        return container(kind: .group, layout: .grid(LayerNode.Grid(
            columns: min(max(columns, 1), 12), columnSpacing: gap, rowSpacing: gap,
            alignment: LayerNode.Alignment(horizontal: .start, vertical: .start))))
    }

    private static func makeCard(_ tokens: DesignTokens) -> LayerNode {
        var node = container(kind: .card, layout: column(spacing: tokens.spacing(nearest: 8)))
        node.padding = LayerNode.Padding(all: tokens.card.padding)
        return node
    }

    // MARK: Keys and the primary action

    /// What a node is called in a key.
    private static func keyName(_ node: LayerNode) -> String {
        guard node.isContainer else { return node.kind.rawValue }
        if node.kind == .card { return "card" }
        switch node.resolvedLayout {
        case .grid: return "grid"
        case .stack(let stack): return stack.axis == .horizontal ? "row" : "group"
        case .free, .overlay: return "group"
        }
    }

    private static func keyAndPolish(_ root: inout LayerNode) {
        root.source?.key = ""
        key(&root)
        root = withOnePrimaryAction(root)
    }

    /// Plan 1's one-primary-action rule, on any tree.
    static func withOnePrimaryAction(_ root: LayerNode) -> LayerNode {
        var root = root
        onePrimaryAction(in: &root)
        return root
    }

    private static func key(_ node: inout LayerNode) {
        var counts: [String: Int] = [:]
        for index in node.children.indices {
            let name = keyName(node.children[index])
            let ordinal = counts[name, default: 0]
            counts[name] = ordinal + 1
            let prefix = (node.source?.key).flatMap { $0.isEmpty ? nil : $0 + "/" } ?? ""
            node.children[index].source?.key = "\(prefix)\(name):\(ordinal)"
            key(&node.children[index])
        }
    }

    /// Keeps one filled button: the only explicitly filled one, else the first. The others become
    /// bordered, or plain inside a row. When every button was bordered the last one outside a row
    /// becomes filled. Plain buttons stay plain.
    private static func onePrimaryAction(in root: inout LayerNode) {
        var filled: [[Int]] = [], explicit: [[Int]] = [], bordered: [[Int]] = []
        func scan(_ node: LayerNode, path: [Int]) {
            let inRow: Bool = {
                if case .stack(let stack) = node.resolvedLayout { return stack.axis == .horizontal }
                return false
            }()
            for (index, child) in node.children.enumerated() {
                let childPath = path + [index]
                if child.kind == .button {
                    switch child.content.buttonLook {
                    case nil: filled.append(childPath)
                    case .filled?: filled.append(childPath); explicit.append(childPath)
                    case .bordered?: if !inRow { bordered.append(childPath) }
                    case .plain?: break
                    }
                } else {
                    scan(child, path: childPath)
                }
            }
        }
        func edit(_ path: [Int], in node: inout LayerNode, _ change: (inout LayerNode, _ parentIsRow: Bool) -> Void) {
            guard let first = path.first else { return }
            if path.count == 1 {
                var isRow = false
                if case .stack(let stack) = node.resolvedLayout { isRow = stack.axis == .horizontal }
                change(&node.children[first], isRow)
            } else {
                edit(Array(path.dropFirst()), in: &node.children[first], change)
            }
        }
        scan(root, path: [])
        if filled.isEmpty, let last = bordered.last {
            edit(last, in: &root) { button, _ in button.content.buttonLook = nil }
            return
        }
        guard filled.count > 1 else { return }
        let keeper = explicit.count == 1 ? explicit[0] : filled[0]
        for path in filled where path != keeper {
            edit(path, in: &root) { button, inRow in button.content.buttonLook = inRow ? .plain : .bordered }
        }
    }
}
