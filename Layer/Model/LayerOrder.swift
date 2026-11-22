import Foundation

/// Layer order: things brought to the front, forward, backward or sent to the back, one at
/// a time or several at once.
///
/// Order only means something among siblings: the things that share a screen, or the open
/// canvas. Drawings are in no sibling set. Unlocked ink is drawn above every element, so a
/// drawing keeps the place it has in the list whatever is arranged around it, and nothing
/// steps past it or moves it (F7).
extension DesignContent {
    /// The whole order of what is on a screen, or on the open canvas when `parent` is nil,
    /// back to front, with every drawing there in the slot it holds now and the other slots
    /// filled, in turn, by `order`: the new back-to-front order of the things there that
    /// aren't drawings. What `reorder(_:to:)` is given whenever things are put in a new
    /// order, so that it is worked out in this one place.
    ///
    /// `order` is to hold every one of those things once. Given anything else, the result
    /// doesn't hold exactly what is there, and `reorder` leaves the order as it is.
    func rawOrder(on parent: DesignScreen.ID?, withDrawingsKept order: [DesignElement.ID]) -> [DesignElement.ID] {
        var next = order.makeIterator()
        return elements.compactMap { element in
            guard element.parent == parent else { return nil }
            return element.kind == .drawing ? element.id : next.next()
        }
    }
}

extension DesignStore {
    /// Moves what is selected up or down among its siblings: the things it shares its screen,
    /// or the open canvas, with. Things on different screens each move among their own.
    /// Several things that are siblings move as one block, keeping their own order and
    /// closing the gaps between them. A screen in the selection is left as it is, and so is
    /// a drawing. One step to undo, however many screens it reorders.
    func arrange(_ selection: CanvasSelection, _ arrangement: Arrangement) {
        let orders = arranged(selection, arrangement)
        guard !orders.isEmpty else { return }
        apply { content in
            for (parent, order) in orders {
                content.reorder(parent, to: content.rawOrder(on: parent, withDrawingsKept: order))
            }
        }
    }

    /// Whether arranging what is selected would change the order of anything.
    func canArrange(_ selection: CanvasSelection, _ arrangement: Arrangement) -> Bool {
        !arranged(selection, arrangement).isEmpty
    }

    /// The new order, back to front and drawings left out, of each screen (or the open
    /// canvas, nil) whose order arranging the selection changes.
    private func arranged(_ selection: CanvasSelection, _ arrangement: Arrangement) -> [DesignScreen.ID?: [DesignElement.ID]] {
        // What moves, by the sibling set it moves in: what is on one screen, or on the
        // open canvas. A drawing is in none, and a screen is not arranged.
        var moving: [DesignScreen.ID?: (member: ElementRef, ids: Set<DesignElement.ID>)] = [:]
        for case .element(let ref) in selection.things {
            guard let (element, _) = resolve(ref), element.kind != .drawing else { continue }
            moving[element.parent, default: (ref, [])].ids.insert(element.id)
        }
        var orders: [DesignScreen.ID?: [DesignElement.ID]] = [:]
        for (parent, moved) in moving {
            let now = siblings(of: moved.member)
            let order = Self.order(moving: moved.ids, among: now, arrangement)
            if order != now { orders[parent] = order }
        }
        return orders
    }

    /// Siblings, back to front, with some of them moved as one block: in their own order,
    /// their gaps closed, to the front or the back, or just in front of the first sibling
    /// in front of the block's frontmost member (forward), or just behind the first sibling
    /// behind its backmost member (backward).
    private static func order(moving moved: Set<DesignElement.ID>, among siblings: [DesignElement.ID], _ arrangement: Arrangement) -> [DesignElement.ID] {
        let block = siblings.filter(moved.contains)
        guard let backmost = siblings.firstIndex(where: moved.contains),
              let frontmost = siblings.lastIndex(where: moved.contains) else { return siblings }
        var rest = siblings.filter { !moved.contains($0) }
        let place: Int
        switch arrangement {
        case .front:
            place = rest.count
        case .back:
            place = 0
        case .forward:
            // With nothing in front of it, the block goes to the front.
            place = siblings[(frontmost + 1)...].first.flatMap(rest.firstIndex(of:)).map { $0 + 1 } ?? rest.count
        case .backward:
            // With nothing behind it, the block goes to the back.
            place = siblings[..<backmost].last.flatMap(rest.firstIndex(of:)) ?? 0
        }
        rest.insert(contentsOf: block, at: place)
        return rest
    }
}
