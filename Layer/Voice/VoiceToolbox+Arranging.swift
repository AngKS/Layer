import CoreGraphics
import Foundation

/// Voice's arranging tools: putting one thing by another, stacking several in a column or row, and lining things up
/// with their screen or with one another, as the popover's Align does.
extension VoiceToolbox {
    // MARK: Placing, stacking and lining up

    /// Puts one element next to another, 12 points from it: below or above it with their
    /// left edges together, or beside it with their tops together.
    func placeElement(element: String, relation: String, target: String) -> String {
        forCommand {
            guard let model else { return gone }
            guard let side = Self.side(named: relation) else {
                return failed("I can put it above, below, left of or right of another, not “\(relation)”.")
            }
            // Next to the screen it is on is an edge of that screen: asked for "the image to
            // the top", the on-device model names the screen here, or the element at the top.
            // Unless one thing was said to go by another, an edge is what was meant.
            let askedToPlace = spokenCommand.map(Self.asksToPlace) ?? true
            if VoiceHandles.tidied(target)?.hasPrefix("S") == true || !askedToPlace {
                let edge = switch side {
                case .above: "top"
                case .below: "bottom"
                case .leftOf: "left"
                case .rightOf: "right"
                }
                return alignElement(element: element, alignment: edge)
            }
            let moving: Found
            let other: Found
            switch (find(element: element), find(element: target)) {
            case (.failure(let refusal), _), (_, .failure(let refusal)): return failed(refusal.line)
            case (.success(let one), .success(let two)): (moving, other) = (one, two)
            }
            guard moving.ref != other.ref else {
                return failed("Name two different elements. To add a new one next to another, give addElement where it goes.")
            }
            guard moving.ref.host == other.ref.host else { return failed("Those aren't on the same screen.") }
            guard !moving.placed.isLocked else { return failed("\(handle(of: moving)) is locked.") }
            if let placer = placer(of: moving) { return failed(placedLine(handle(of: moving), placer)) }
            let store = model.store
            guard let frame = store.canvasFrame(of: .element(moving.ref)), let by = store.canvasFrame(of: .element(other.ref)) else {
                return failed("That couldn't be placed.")
            }
            // In the points of the screen they are on.
            let gap = 12 * moving.placed.placement.scale
            let origin = switch side {
            case .below: CGPoint(x: by.minX, y: by.maxY + gap)
            case .above: CGPoint(x: by.minX, y: by.minY - gap - frame.height)
            case .leftOf: CGPoint(x: by.minX - gap - frame.width, y: by.minY)
            case .rightOf: CGPoint(x: by.maxX + gap, y: by.minY)
            }
            reveal(.element(moving.ref), in: model)
            store.position([.element(moving.ref): origin])
            return done("Put \(Self.describe(moving.node)) \(side.rawValue) \(Self.describe(other.node)).")
        }
    }

    /// Whether what was said puts one thing by another: "below the title", "next to it".
    /// "On the left" and "to the top" are edges of the screen.
    static func asksToPlace(_ said: String) -> Bool {
        let words = said.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if !Set(words).isDisjoint(with: ["below", "under", "underneath", "beneath", "above", "beside", "besides"]) { return true }
        for (one, next) in zip(words, words.dropFirst()) {
            if (one == "next" && next == "to") || (["left", "right", "top"].contains(one) && next == "of") { return true }
        }
        return false
    }

    enum Side: String {
        case below, above
        case leftOf = "left of"
        case rightOf = "right of"
    }

    static func side(named words: String) -> Side? {
        let said = Set(words.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        if !said.isDisjoint(with: ["below", "under", "underneath", "beneath"]) { return .below }
        if !said.isDisjoint(with: ["above", "over", "top"]) { return .above }
        if said.contains("left") { return .leftOf }
        if !said.isDisjoint(with: ["right", "beside", "next"]) { return .rightOf }
        return nil
    }

    /// The handles in a list such as "E3, E4" or "E2 E1". A handle written loosely, "E 2",
    /// is one.
    static func handleList(_ written: String) -> [String] {
        written.components(separatedBy: CharacterSet(charactersIn: ",;&")).flatMap { part -> [String] in
            let part = part.replacingOccurrences(of: " and ", with: " ")
            let words = part.split(separator: " ").map(String.init)
            return words.count > 1 && words.allSatisfy({ VoiceHandles.tidied($0) != nil }) ? words : [part]
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Puts several elements one after another, none overlapping: down a column with
    /// their left edges together, or along a row with their tops together, 12 points
    /// apart. They keep the order they stand in; those on top of one another, which have
    /// none, take the order they were named in. It starts where the first of them is.
    func stackElements(elements: String, direction: String) -> String {
        forCommand {
            guard let model else { return gone }
            let isColumn: Bool
            switch direction.lowercased().trimmingCharacters(in: .whitespaces) {
            case "column", "vertical", "vertically", "down": isColumn = true
            case "row", "horizontal", "horizontally", "across": isColumn = false
            default: return failed("I can stack in a column or a row, not “\(direction)”.")
            }
            let named = Self.handleList(elements)
            var found: [Found] = []
            for handle in named {
                switch find(element: handle) {
                case .failure(let refusal): return failed(refusal.line)
                case .success(let one):
                    guard !one.placed.isLocked else { return failed("\(self.handle(of: one)) is locked.") }
                    if let placer = placer(of: one) { return failed(placedLine(self.handle(of: one), placer)) }
                    if !found.contains(where: { $0.ref == one.ref }) { found.append(one) }
                }
            }
            guard found.count > 1 else { return failed("Name two or more elements to stack.") }
            guard Set(found.map(\.ref.host)).count == 1 else { return failed("Those aren't all on one screen.") }

            // Worked out on the canvas, where the store puts things, in the points of the
            // screen they are on: a gap of 12 of those is less on a screen drawn small.
            let store = model.store
            let gap = 12 * found[0].placed.placement.scale
            var placed: [(ref: NodeRef, frame: CGRect)] = found.compactMap { one in
                store.canvasFrame(of: .element(one.ref)).map { (one.ref, $0) }
            }
            guard placed.count == found.count else { return failed("Those couldn't be stacked.") }
            // A stable sort: things at the same place keep the order they were named in.
            placed = placed.enumerated().sorted { a, b in
                let (one, other) = isColumn ? (a.element.frame.minY, b.element.frame.minY) : (a.element.frame.minX, b.element.frame.minX)
                return abs(one - other) > 0.5 ? one < other : a.offset < b.offset
            }.map(\.element)
            let left = placed.map(\.frame.minX).min() ?? 0
            let top = placed.map(\.frame.minY).min() ?? 0
            var next = isColumn ? top : left
            var origins: [CanvasSelection: CGPoint] = [:]
            for (ref, frame) in placed {
                origins[.element(ref)] = isColumn ? CGPoint(x: left, y: next) : CGPoint(x: next, y: top)
                next += (isColumn ? frame.height : frame.width) + gap
            }
            reveal(.element(placed[0].ref), in: model)
            store.position(origins)
            // All of them stay selected, so that "them" goes on meaning them.
            select(.several(Set(placed.map { .element($0.ref) })), in: model)
            return done("Stacked \(placed.count) elements in a \(isColumn ? "column" : "row").")
        }
    }

    /// One thing lined up with its screen, as the popover's Align does: only in a free parent (spec §10). What a row,
    /// column, grid or overlay places is lined up by that one's alignment, which the model is told to set.
    func alignElement(element: String, alignment: String) -> String {
        forCommand {
            guard let model else { return gone }
            let named = Self.handleList(element)
            if named.count > 1 { return alignTogether(named, alignment: alignment) }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                guard let (edge, name) = Self.alignment(named: alignment) else {
                    return failed("I can align to the left, centre, right, top, middle or bottom, not “\(alignment)”.")
                }
                let handle = handle(of: found)
                guard found.screen != nil else { return failed("\(handle) isn't on a screen to line up with.") }
                guard !found.placed.isLocked else { return failed("\(handle) is locked.") }
                if let placer = placer(of: found) { return failed(alignedLine(handle, placer)) }
                reveal(.element(found.ref), in: model)
                model.store.align(found.ref, edge)
                return done("Aligned \(Self.describe(found.node)) to the \(name).")
            }
        }
    }

    /// Lines several elements up with one another: by an edge, or through the middle, of
    /// the area they cover together, through the popover's Align (`DesignStore.lineUp`): in one row, column, grid or
    /// overlay, by that one's alignment; otherwise only what is in a free parent moves (spec §10), and what is placed
    /// stays where it is, the rest lining up with it all the same.
    private func alignTogether(_ named: [String], alignment: String) -> String {
        guard let model else { return gone }
        guard let (edge, name) = Self.alignment(named: alignment) else {
            return failed("I can align to the left, centre, right, top, middle or bottom, not “\(alignment)”.")
        }
        var found: [Found] = []
        for handle in named {
            switch find(element: handle) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let one):
                guard !one.placed.isLocked else { return failed("\(self.handle(of: one)) is locked.") }
                if !found.contains(where: { $0.ref == one.ref }) { found.append(one) }
            }
        }
        guard found.count > 1 else { return alignElement(element: named[0], alignment: alignment) }
        guard Set(found.map(\.ref.host)).count == 1 else { return failed("Those aren't all on one screen.") }
        let together = CanvasSelection.several(Set(found.map { .element($0.ref) }))
        let store = model.store
        let by = name.hasSuffix("centre") ? "\(name)s" : "\(name) edges"
        // All in one that places them along this edge, or each placed by one: nothing of theirs can move.
        if store.layoutAligned(together, edge) == nil,
           store.laidOutParent(of: together) != nil || !store.holdsSomethingInAFreeParent(together),
           let placed = found.first(where: { $0.placed.isLaidOut }), let placer = placer(of: placed) {
            return failed(alignedLine(handle(of: placed), placer))
        }
        reveal(.element(found[0].ref), in: model)
        store.lineUp(together, edge)
        select(together, in: model)
        return done("Lined up \(found.count) elements by their \(by).")
    }

    private static func alignment(named word: String) -> (ElementLayout.Alignment, String)? {
        switch word.lowercased().trimmingCharacters(in: .whitespaces) {
        case "left", "leading": (.left, "left")
        // "Middle" is how people say centred, so it is side to side like "centre".
        case "centre", "center", "centred", "centered", "centrally", "middle", "horizontal centre", "horizontal center": (.centerX, "centre")
        case "right", "trailing": (.right, "right")
        case "top": (.top, "top")
        case "vertical centre", "vertical center", "vertical middle", "vertically", "centre vertically", "center vertically": (.centerY, "vertical centre")
        case "bottom": (.bottom, "bottom")
        default: nil
        }
    }
}
