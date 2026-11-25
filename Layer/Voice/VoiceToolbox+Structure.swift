import CoreGraphics
import Foundation

/// Voice's structure tools (plan 6, Task 8): what the popover's Group as, the Format panel's Layout section, Ungroup and
/// the Layers panel's reordering do by hand, by voice. Each goes through the same store verb as its control does, in
/// the command's one step (`forCommand`). A container is called by its kind word, as the Layers panel calls it: group,
/// row, column, grid, overlay or card.
extension VoiceToolbox {
    // MARK: groupElements

    /// Wraps the things named in a new container, as the popover's Group as does (`DesignStore.group(_:as:)`): a row's,
    /// column's or grid's spacing and alignment come from how they stand now, the first of them keeps its place, and the
    /// new container is selected. Two or more, sharing one parent; a card may hold one.
    func groupElements(elements: String, as shape: String) -> String {
        forCommand {
            guard let model else { return gone }
            guard let kind = Self.groupShape(named: shape) else {
                return failed("I can group them as a group, row, column, grid or card, not “\(shape.trimmingCharacters(in: .whitespacesAndNewlines))”.")
            }
            var found: [Found] = []
            for handle in Self.handleList(elements) {
                switch find(element: handle) {
                case .failure(let refusal): return failed(refusal.line)
                case .success(let one):
                    guard !one.placed.isLocked else { return failed("\(self.handle(of: one)) is locked.") }
                    if !found.contains(where: { $0.id == one.id }) { found.append(one) }
                }
            }
            guard found.count >= (kind == .card ? 1 : 2) else {
                return failed(kind == .card ? "Name what to put in the card." : "Name two or more elements to group.")
            }
            let store = model.store
            let shared = store.parent(of: found[0].id)
            if let other = found.first(where: { store.parent(of: $0.id) != shared }) {
                return failed("\(handle(of: found[0])) and \(handle(of: other)) aren't in the same place, so they can't be grouped.")
            }
            let listed = Self.listed(found.map { handle(of: $0) })
            // Refused for what Group refuses besides: all of a free group as a group, or past the tree's limits.
            guard let together = CanvasSelection(found.map { .element($0.ref) }), let made = store.group(together, as: kind) else {
                return failed("\(listed) can't be put in a new \(kind.rawValue).")
            }
            reveal(.element(made), in: model)
            return done("Put \(listed) in a \(kind.rawValue), \(handles.handle(forNode: made.node)).")
        }
    }

    /// The shape some words name: group, row, column, grid or card, a plural or an article round it tolerated.
    static func groupShape(named words: String) -> GroupShape? {
        let said = words.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for word in said {
            if let shape = GroupShape(rawValue: word) ?? GroupShape(rawValue: word.hasSuffix("s") ? String(word.dropLast()) : word) {
                return shape
            }
        }
        return nil
    }

    // MARK: setLayout

    /// Changes how a container, or a screen's root, lays out what it holds, as the Format panel's Layout section does:
    /// the layout's kind through `LayoutChoice` (a row, column or grid made from a free one takes the layout Group as
    /// would give what it holds, and what it holds is fixed at its size in reading order; one made free keeps every
    /// frame), then a grid's columns, the alignment and the spacing the words give. A screen can be free or a column.
    func setLayout(target: String, layout: String?, spacing: String?) -> String {
        forCommand {
            guard let model else { return gone }
            let store = model.store
            let holder: LayerNode
            let handle: String
            let isScreen: Bool
            let shown: CanvasSelection
            if VoiceHandles.tidied(target)?.hasPrefix("S") == true {
                switch find(screen: target) {
                case .failure(let refusal): return failed(refusal.line)
                case .success(let screen):
                    handle = handles.handle(forScreen: screen.id)
                    guard screen.isLocked != true else { return failed("\(handle) is locked.") }
                    (holder, isScreen, shown) = (screen.root, true, .screen(screen.id))
                }
            } else {
                switch find(element: target) {
                case .failure(let refusal): return failed(refusal.line)
                case .success(let found):
                    handle = self.handle(of: found)
                    guard found.node.isContainer else {
                        let what = found.node.kind.layerName.lowercased()
                        return failed("\(handle) is \(Self.article(for: what)) \(what), which holds nothing. To put things in a row, call groupElements.")
                    }
                    guard !found.placed.isLocked else { return failed("\(handle) is locked.") }
                    (holder, isScreen, shown) = (found.node, false, .element(found.ref))
                }
            }
            let layoutWords = layout.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            let spacingWords = spacing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            guard layoutWords != nil || spacingWords != nil else { return failed("Say a layout or a spacing for \(handle).") }
            var asked = LayoutWords()
            if let layoutWords {
                guard let read = LayoutWords(layoutWords) else { return failed("I didn't understand the layout “\(layoutWords)”.") }
                asked = read
            }
            var gap = asked.spacing
            if let spacingWords {
                guard let read = LayoutWords.points(spacingWords) else { return failed("I didn't understand the spacing.") }
                gap = read
            }
            let current = holder.resolvedLayout
            // Only a number for a grid, with no other kind named: a grid of that many.
            let choice = asked.choice ?? (asked.columns != nil && LayoutChoice(current) != .grid ? .grid : nil)
            if isScreen, let choice, !LayoutChoice.choices(forScreenRoot: true).contains(choice) {
                let word = choice.title.lowercased()
                return failed("A screen can be free or a column, not \(Self.article(for: word)) \(word).")
            }
            var made = choice.map { $0.layout(from: current, children: holder.children, rhythm: store.tree.settings.tokens.rhythm) } ?? current
            guard let shaped = asked.applied(to: made) else {
                return failed("I didn't understand the layout “\(layoutWords ?? "")”.")
            }
            made = shaped
            if let gap {
                switch made {
                case .free: return failed("A free layout has no spacing. To space what \(handle) holds, give it a layout such as column.")
                case .overlay: return failed("An overlay has no spacing.")
                case .stack(var stack):
                    stack.spacing = gap
                    made = .stack(stack)
                case .grid(var grid):
                    (grid.columnSpacing, grid.rowSpacing) = (gap, gap)
                    made = .grid(grid)
                }
            }
            store.setLayout(holder.id, made)
            reveal(shown, in: model)
            guard let words = CanvasPicture.words(for: made) else {
                return done("\(handle) is now free: what it holds stays where it is.")
            }
            if layoutWords == nil { return done("\(handle)'s spacing is now \((gap ?? 0).rounded().wholePoints).") }
            return done("\(handle) is now \(Self.article(for: words)) \(words).")
        }
    }

    // MARK: ungroup

    /// Takes a container apart, as Ungroup does (`DesignStore.ungroup(_:)`): what it held goes into its slot, each where
    /// it is on the screen, and is selected. Taking apart a row, column or grid the structure pass made declines what it
    /// held, so the pass never puts it back (plan 5, call 11).
    func ungroup(element: String) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                let handle = handle(of: found)
                guard found.node.isContainer else { return failed("\(handle) isn't a row, column, grid, card or group.") }
                guard !found.placed.isLocked else { return failed("\(handle) is locked.") }
                guard found.node.unreadChildren.isEmpty else {
                    return failed("\(handle) holds something this version of Layer can't read, so it can't be taken apart.")
                }
                let held = found.node.children.map(\.id)
                let members = model.store.ungroup(found.ref)
                // An empty one is taken away, and there is nothing to select.
                guard let first = held.first else { return done("Took \(handle) apart. It held nothing.") }
                guard let members else { return failed("\(handle) couldn't be taken apart.") }
                reveal(.element(NodeRef(host: found.ref.host, node: first)), in: model)
                select(members, in: model)
                return done("Took \(Self.listed(held.map { handles.handle(forNode: $0) })) out of \(handle).")
            }
        }
    }

    // MARK: reorder

    /// Puts a thing before or after another among those they share a parent with, as the Layers panel does: in a row,
    /// column or grid that is its place in the layout; in a free parent or an overlay, its place front to back, and
    /// nothing moves. So there a side, such as "above", is refused with a pointer to `placeElement`: the person asked
    /// for a place, which a new order wouldn't give. This is how a laid-out child is moved (call 8).
    func reorder(element: String, position: String, target: String) -> String {
        forCommand {
            guard let model else { return gone }
            guard let isBefore = Self.isBefore(position) else { return failed("Say before or after.") }
            let moving: Found
            let other: Found
            switch (find(element: element), find(element: target)) {
            case (.failure(let refusal), _), (_, .failure(let refusal)): return failed(refusal.line)
            case (.success(let one), .success(let two)): (moving, other) = (one, two)
            }
            let handle = handle(of: moving)
            let side = isBefore ? "before" : "after"
            guard moving.id != other.id else { return failed("\(handle) can't go \(side) itself.") }
            let store = model.store
            guard let parent = store.parent(of: moving.id), parent == store.parent(of: other.id) else {
                return failed("\(handle) and \(self.handle(of: other)) aren't in the same row, column, grid or group.")
            }
            guard !moving.placed.isLocked else { return failed("\(handle) is locked.") }
            if !Self.laysOutInOrder(parent, in: store), let spoken = Self.side(in: position) {
                let by = self.handle(of: other)
                return failed("\(handle) and \(by) aren't in a row, column or grid, so their order is only which is in front. To put \(handle) \(spoken) \(by), call placeElement.")
            }
            let order = Self.children(of: parent, in: store).map(\.id)
            let rest = order.filter { $0 != moving.id }
            guard let at = rest.firstIndex(of: other.id) else { return failed("\(handle) couldn't be moved.") }
            let index = isBefore ? at : at + 1
            var wanted = rest
            wanted.insert(moving.id, at: index)
            guard wanted != order else { return noted("\(handle) is \(side) \(self.handle(of: other)) already.") }
            guard store.move(moving.id, to: parent, at: index) else { return failed("\(handle) couldn't be moved.") }
            reveal(.element(moving.ref), in: model)
            return done("Moved \(handle) \(side) \(self.handle(of: other)).")
        }
    }

    /// Whether some words say before (true) or after (false): "above" and "left of" are before, "below" and "right of"
    /// after. Nil for anything else, or for words that say both.
    static func isBefore(_ words: String) -> Bool? {
        let said = Set(words.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        let before = !said.isDisjoint(with: ["before", "above", "left"])
        let after = !said.isDisjoint(with: ["after", "below", "under", "beneath", "underneath", "right"])
        return before == after ? nil : before
    }

    /// The side some position words name, as `placeElement` says it: above, below, left of or right of. Nil for "before"
    /// and "after", which name an order.
    static func side(in words: String) -> String? {
        let said = Set(words.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        if said.contains("above") { return "above" }
        if !said.isDisjoint(with: ["below", "under", "beneath", "underneath"]) { return "below" }
        if said.contains("left") { return "left of" }
        if said.contains("right") { return "right of" }
        return nil
    }

    /// Whether a parent places what it holds in its order: a row, column or grid. A free parent's order, and an
    /// overlay's, is only which is in front.
    private static func laysOutInOrder(_ parent: NodeParent, in store: DesignStore) -> Bool {
        let layout: LayerNode.Layout? = switch parent {
        case .node(let id): store.node(id)?.resolvedLayout
        case .screen(let id): store.treeScreen(id)?.root.resolvedLayout
        case .canvas: nil
        }
        switch layout {
        case .stack?, .grid?: return true
        case .free?, .overlay?, nil: return false
        }
    }

    /// What a parent holds, back to front: a container's children, a screen's root's, or the open canvas's.
    private static func children(of parent: NodeParent, in store: DesignStore) -> [LayerNode] {
        switch parent {
        case .node(let id): store.node(id)?.children ?? []
        case .screen(let id): store.treeScreen(id)?.root.children ?? []
        case .canvas: store.tree.canvas
        }
    }

    // MARK: In words

    /// Handles as a list is said: `E1`, `E1 and E2`, `E1, E2 and E3`.
    static func listed(_ handles: [String]) -> String {
        guard let last = handles.last else { return "" }
        guard handles.count > 1 else { return last }
        return handles.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// What a person's layout words ask for (`setLayout`): a kind, a grid's columns, the edges to line things up by, and a
/// spacing written among them, as the canvas picture writes one (`row, spacing 12`).
struct LayoutWords {
    enum Edge { case left, right, top, bottom, centre, stretched }

    var choice: LayoutChoice?
    var columns: Int?
    var edges: Set<Edge> = []
    var spacing: CGFloat?

    init() {}

    /// Nil for a word that isn't one of these, or for two kinds named at once.
    ///
    /// A number is a spacing when "spacing" or "gap" is said beside it ("spacing 16", "16 spacing"), and a grid's count
    /// when "column" or "columns" follows it ("2 column grid", "3 columns") or a grid is named ("grid of 3"). A number
    /// that is neither is refused, rather than taken for a grid's count: "row 16" is no grid of 12.
    init?(_ written: String) {
        let words = written.lowercased().matches(of: /-?[0-9]+(?:\.[0-9]+)?|[a-z]+/).map { String($0.output) }
        let filler: Set<String> = ["a", "an", "the", "of", "with", "and", "in", "to", "it", "columns", "layout", "aligned",
                                   "align", "alignment", "pt", "points"]
        // A number not yet known to be a spacing or a grid's count.
        var pending: String?
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if ["spacing", "gap", "spaced"].contains(word) {
                // The number after it, or else the one before it: a spacing with no number is no spacing.
                let number: String
                if index < words.count, Self.isNumber(words[index]) {
                    number = words[index]
                    index += 1
                } else if let before = pending {
                    number = before
                    pending = nil
                } else {
                    return nil
                }
                guard spacing == nil, let value = Self.points(number) else { return nil }
                spacing = value
                continue
            }
            if Self.isNumber(word) {
                if index < words.count, words[index] == "column" || words[index] == "columns" {
                    guard columns == nil, let count = Self.count(word) else { return nil }
                    columns = count
                    index += 1
                    continue
                }
                if let earlier = pending {
                    // Two numbers: the first counts a grid named before it, and the second waits for its "spacing".
                    guard choice == .grid, columns == nil, let count = Self.count(earlier) else { return nil }
                    columns = count
                }
                pending = word
                continue
            }
            let kind: LayoutChoice?
            switch word {
            case "free", "freeform": kind = .free
            case "row", "horizontal": kind = .row
            case "column", "vertical", "stack": kind = .column
            case "grid": kind = .grid
            case "overlay", "overlaid", "layered": kind = .overlay
            case "left", "leading": kind = nil; edges.insert(.left)
            case "right", "trailing": kind = nil; edges.insert(.right)
            case "top": kind = nil; edges.insert(.top)
            case "bottom": kind = nil; edges.insert(.bottom)
            case "centre", "center", "centred", "centered", "middle": kind = nil; edges.insert(.centre)
            case "stretched", "stretch", "fill", "filled": kind = nil; edges.insert(.stretched)
            default:
                guard filler.contains(word) else { return nil }
                kind = nil
            }
            if let kind {
                guard choice == nil || choice == kind else { return nil }
                choice = kind
            }
        }
        if let number = pending {
            guard choice == .grid, columns == nil, let count = Self.count(number) else { return nil }
            columns = count
        }
        guard choice != nil || columns != nil || !edges.isEmpty || spacing != nil else { return nil }
    }

    private static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                                      "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]

    private static func isNumber(_ word: String) -> Bool {
        Double(word) != nil || numberWords[word] != nil
    }

    /// A grid's count of columns as written: a whole number of one or more, in figures or words.
    private static func count(_ word: String) -> Int? {
        guard let count = Int(word) ?? numberWords[word], count >= 1 else { return nil }
        return count
    }

    /// A spacing as written: points, such as `16` or `16pt`, from 0 up to a screen's largest side, 4,000; nil for anything
    /// else, such as `-4` or `lots`.
    static func points(_ written: String) -> CGFloat? {
        var text = written.lowercased().trimmingCharacters(in: .whitespaces)
        for unit in ["points", "point", "pts", "pt"] where text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let value = Double(text), value.isFinite, value >= 0, value <= 4_000 else { return nil }
        return CGFloat(value)
    }

    /// `layout` with the columns and edges asked for: nil where they don't fit it, such as columns for a row, or the left
    /// edge for a row, which lines things up by its top, middle or bottom.
    func applied(to layout: LayerNode.Layout) -> LayerNode.Layout? {
        switch layout {
        case .free:
            return columns == nil && edges.isEmpty ? layout : nil
        case .stack(var stack):
            guard columns == nil else { return nil }
            let isRow = stack.axis == .horizontal
            let across: [Edge: LayerNode.CrossAlignment] = isRow
                ? [.top: .start, .centre: .center, .bottom: .end, .stretched: .fill]
                : [.left: .start, .centre: .center, .right: .end, .stretched: .fill]
            guard edges.count <= 1 else { return nil }
            if let edge = edges.first {
                guard let alignment = across[edge] else { return nil }
                stack.alignment = alignment
            }
            return .stack(stack)
        case .grid(var grid):
            if let columns { grid.columns = min(max(columns, 1), 12) }
            guard let alignment = aligned(grid.alignment) else { return nil }
            grid.alignment = alignment
            return .grid(grid)
        case .overlay(let alignment):
            guard columns == nil, let aligned = aligned(alignment) else { return nil }
            return .overlay(aligned)
        }
    }

    /// A grid's or overlay's alignment with the edges asked for: left, right and top, bottom on their own axes, and
    /// centred on whichever axis no other edge was named for. Nil for stretched, or two edges on one axis.
    private func aligned(_ alignment: LayerNode.Alignment) -> LayerNode.Alignment? {
        guard !edges.contains(.stretched) else { return nil }
        let across = edges.intersection([.left, .right])
        let down = edges.intersection([.top, .bottom])
        guard across.count <= 1, down.count <= 1 else { return nil }
        var made = alignment
        if let edge = across.first { made.horizontal = edge == .left ? .start : .end }
        if let edge = down.first { made.vertical = edge == .top ? .start : .end }
        if edges.contains(.centre) {
            guard across.isEmpty || down.isEmpty else { return nil }
            if across.isEmpty { made.horizontal = .center }
            if down.isEmpty { made.vertical = .center }
        }
        return made
    }
}
