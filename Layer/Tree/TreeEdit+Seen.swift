import CoreGraphics

// What a sketched card (`SketchedNode`) and a container the structure pass builds (`StructureInference`) both ask
// when they choose their slot among the children that stay: which children were seen, and the ruled slot moved as
// little as needed into the slots where nothing seen is wholly hidden by one thing. What would hide what differs
// between them, a card drawing itself and a built container nothing, so each asks that itself.

extension TreeEdit {
    /// Which of some children, back to front, are seen: drawn, and not wholly under one drawn thing in front of them,
    /// each counted as the box round its turned shape. Asked only of what one thing wholly covers, which is seldom, so
    /// each is worked out when first asked, and once.
    struct Seen {
        private let shapes: [CGRect]
        private let drawn: [Bool]
        private var known: [Bool?]

        /// `shapes` and `drawn` are the children's, back to front: the box round each turned shape, and whether it is
        /// drawn (a hidden one isn't, and counts for nothing).
        init(shapes: [CGRect], drawn: [Bool]) {
            self.shapes = shapes
            self.drawn = drawn
            known = Array(repeating: nil, count: shapes.count)
        }

        /// Whether the child at `at` is seen.
        mutating func callAsFunction(_ at: Int) -> Bool {
            if let seen = known[at] { return seen }
            let seen = drawn[at] && !shapes.indices.contains { over in
                over > at && drawn[over] && shapes[over].contains(shapes[at])
            }
            known[at] = seen
            return seen
        }
    }

    /// `ruled` moved as little as needed into the slots from `lowest` to `highest`, those that hide nothing seen; where
    /// there are none (`lowest` past `highest`), `ruled` stands.
    static func slot(_ ruled: Int, movedInto lowest: Int, _ highest: Int) -> Int {
        lowest <= highest ? min(max(ruled, lowest), highest) : ruled
    }
}
