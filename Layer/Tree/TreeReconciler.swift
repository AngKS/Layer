import CoreGraphics
import Foundation

/// Writes each update of a generated screen into the screen as it is now, matching nodes by their
/// key (`LayerNode.Source.key`), which the outline and the A2UI importer give every node they make.
///
/// A node the generator wrote keeps its id for as long as the generation runs. One the person has
/// changed since its commit is left as they left it, one they moved is left where they put it, and
/// stays theirs for the rest of the generation, one they deleted is never written again (nor anything
/// that was inside it), and one they added by hand is never touched and keeps its place (plan 3, calls
/// 2 to 5). Every other node is the generator's to write, its words and its order. It is a value, made
/// once per screen a generation writes, and pure: the merge runs off the main actor, on a copy of the
/// screen's root.
struct TreeReconciler: Sendable {
    /// A node as compared to see whether the person changed it: every field but `children`, `frame` only where it
    /// is the truth (under a free parent, and not a container sized to fit), and its parent's id (call 2). Beside
    /// them, its place among its parent's children as the commit left them, which tells whether the person has
    /// reordered it (`moves(in:written:moved:)`).
    ///
    /// A container sized to fit under a free parent keeps its origin in the record, and only its size, which the rules
    /// work out, is left out: the rules keep its corner where it is, so a drag of it is the person's change.
    struct Record: Equatable, Sendable {
        /// The node's own fields, with what it holds left out, and its frame too where the rules write it.
        private var fields: LayerNode
        fileprivate var parent: UUID?
        /// Its index among its parent's children as the last commit left them. Only its order against its written
        /// siblings', all placed by the same commit, counts.
        fileprivate var place: Int

        init(_ node: LayerNode, parent: UUID?, parentIsFree: Bool, place: Int) {
            var fields = node
            fields.children = []
            fields.unreadChildren = []
            if !parentIsFree {
                fields.frame = .zero
            } else if node.isContainer && (node.width.mode == .fit || node.height.mode == .fit) {
                fields.frame.size = .zero
            }
            self.fields = fields
            self.parent = parent
            self.place = place
        }

        /// Whether `other` has this node's fields under this parent: wherever it is among its siblings.
        fileprivate func holdsTheSameNode(as other: Record) -> Bool {
            fields == other.fields && parent == other.parent
        }
    }

    enum Written: Equatable, Sendable {
        case node(id: UUID, record: Record)     // as the store had it after the commit that wrote it
        case removedByRules(id: UUID)          // gone in that commit: written again, with this id
        case deletedByUser                     // gone since: never written again, nor anything under it
    }

    struct Merge: Sendable {
        var root: LayerNode
        var deletedByUser: Set<String>         // keys found missing since their commit
        var dropped: Set<String>               // written keys absent from the whole generated tree, removed (unchanged by the person) (F8)
        /// The keys whose generated node this merge wrote (new, or unchanged since its commit), each with the
        /// id it wrote it with. The person's nodes aren't among them: their records stay as they were.
        fileprivate var wrote: [String: UUID] = [:]
        /// The written keys whose node this merge found where the person left it, the person's changed nodes among
        /// them: each is placed again where the commit leaves it, its fields as they were.
        fileprivate var unmoved: Set<String> = []
        /// The written keys this merge found the person had moved, those found before among them (`moved`).
        fileprivate var moved: Set<String> = []
    }

    /// The screen root's key, as `Outline` writes it.
    static let rootKey = ""

    private(set) var written: [String: Written] = [:]

    /// The keys of the written nodes the person has moved: to another parent, or out of the order the generator
    /// wrote them in. Once moved, a node is the person's for the rest of the generation, wherever it then is and
    /// whatever goes round it (plan 4 Task 4, fix round 1).
    private(set) var moved: Set<String> = []

    /// A new screen this generation made: nothing written yet.
    init() {}

    /// An existing screen (Build Screen): its keyed nodes count as written, as they are now and where they are now
    /// (call 7). Of two nodes that share a key, the first in reading order counts.
    init(adopting root: LayerNode) {
        var written: [String: Written] = [:]
        Self.walk(below: root) { node, parent, place in
            guard let key = Self.key(of: node), written[key] == nil else { return }
            written[key] = .node(id: node.id, record: Record(node, parent: parent.id,
                                                             parentIsFree: parent.resolvedLayout == .free, place: place))
        }
        self.written = written
    }

    /// Pure. `generated` is keyed by `source.key` (ids fresh from a parse). `current` is the screen's root now.
    ///
    /// The root keeps its id and everything about it but its layout and source, which are the generator's
    /// (call 5). Below it, each generated node is written by its key:
    /// - one not written before is new, with its parse id (or the id it had, when the rules took it away);
    /// - one written and unchanged since takes the generator's fields, with its id, wherever the generator puts it, and
    ///   keeps what a newer Layer saved on it;
    /// - one the person changed is left as it is, where it is, and what the generator puts inside it goes in it;
    /// - one the person moved (to another parent, or out of the order the generator wrote it in) is the person's too,
    ///   from then on: only the fewest moves that explain the order now count, so its neighbours stay the generator's,
    ///   but for one swapped with it, which order alone can't tell from it;
    /// - one the person deleted isn't written, nor anything inside it.
    ///
    /// Within each parent the generator's nodes take its order. Everything else there (added by hand, moved by the
    /// person, or the person's and not listed there) stays just after the generator's node it followed, or first
    /// (call 4).
    /// A written node that is unchanged and that the generator no longer lists anywhere goes, with everything inside
    /// it that the generator no longer lists, unless it holds something that isn't the generator's. One the generator
    /// lists only where nothing is written (under a node the person deleted, say) stays where it is.
    func merged(_ generated: LayerNode, over current: LayerNode) -> Merge {
        var merging = Merging(written: written, moved: moved, generated: generated, current: current)
        return merging.merge()
    }

    /// After a commit, from the root the store now holds.
    ///
    /// Each key the merge wrote is recorded from the committed root, or as removed by the rules when the commit
    /// took its node away. A node the store gave a new id, because the design held its id elsewhere, is found by
    /// its key, so that it keeps the new one. Keys found deleted become deleted, with every key that was inside
    /// them and went with them, and keys dropped are forgotten.
    ///
    /// The person's moves the merge found are kept for the rest of the generation. Every other written node is
    /// placed where the commit leaves it, whether the merge wrote it or kept it (one the person changed, say), so that
    /// all of a parent's written children not moved are placed by the same commit.
    mutating func record(_ merge: Merge, committed: LayerNode) {
        var placed: [UUID: Placed] = [:]
        Self.index(committed, into: &placed)
        var recorded: Set<String> = []
        let missing = Set(merge.wrote.filter { placed[$0.value] == nil }.keys)
        var renewed: [String: Placed] = [:]
        if !missing.isEmpty {
            var merged: Set<UUID> = []
            Self.walk(below: merge.root) { node, _, _ in merged.insert(node.id) }
            Self.walk(below: committed) { node, _, _ in
                guard !merged.contains(node.id), let key = Self.key(of: node), missing.contains(key),
                      renewed[key] == nil else { return }
                renewed[key] = placed[node.id]
            }
        }
        for (key, id) in merge.wrote {
            if let entry = placed[id] ?? renewed[key] {
                written[key] = .node(id: entry.node.id, record: entry.record)
                recorded.insert(key)
            } else {
                written[key] = .removedByRules(id: id)
            }
        }
        recordDeleted(merge.deletedByUser, committed: placed)
        moved.formUnion(merge.moved)
        for key in merge.dropped {
            written[key] = nil
            moved.remove(key)
        }
        for key in merge.unmoved.subtracting(recorded) {
            guard case .node(let id, var record)? = written[key], let entry = placed[id] else { continue }
            record.place = entry.place
            written[key] = .node(id: id, record: record)
        }
    }

    /// Each of `keys` as deleted, and every written key that was inside one of them and is gone from the
    /// committed root too, as their records have them.
    private mutating func recordDeleted(_ keys: Set<String>, committed: [UUID: Placed]) {
        guard !keys.isEmpty else { return }
        var inside: [UUID: [String]] = [:]
        for (key, entry) in written {
            guard case .node(let id, let record) = entry, committed[id] == nil, let parent = record.parent else { continue }
            inside[parent, default: []].append(key)
        }
        var going = Array(keys)
        while let key = going.popLast() {
            if case .node(let id, _)? = written[key] { going += inside[id] ?? [] }
            written[key] = .deletedByUser
        }
    }

    // MARK: - Walking trees

    /// A node as a tree holds it: under which parent, at which index there, and whether that parent places it freely.
    fileprivate struct Placed {
        var node: LayerNode
        var parent: UUID?
        var place: Int
        var parentIsFree: Bool

        var record: Record { Record(node, parent: parent, parentIsFree: parentIsFree, place: place) }
    }

    /// A node's key, when it has one that isn't the root's.
    fileprivate static func key(of node: LayerNode) -> String? {
        guard let key = node.source?.key, key != rootKey else { return nil }
        return key
    }

    /// Every node below `root`, in reading order, with its parent and its index there.
    fileprivate static func walk(below root: LayerNode, _ body: (LayerNode, LayerNode, Int) -> Void) {
        for (place, child) in root.children.enumerated() {
            body(child, root, place)
            walk(below: child, body)
        }
    }

    /// Every node of `root`, itself included, by id. The first of two nodes of one id is kept.
    fileprivate static func index(_ root: LayerNode, into placed: inout [UUID: Placed]) {
        if placed[root.id] == nil { placed[root.id] = Placed(node: root, parent: nil, place: 0, parentIsFree: false) }
        walk(below: root) { node, parent, place in
            if placed[node.id] == nil {
                placed[node.id] = Placed(node: node, parent: parent.id, place: place,
                                         parentIsFree: parent.resolvedLayout == .free)
            }
        }
    }

    /// The written keys the person has moved, as `current` shows them: each in `moved` already, each now under
    /// another parent than its commit left it, and, among each parent's other written children, each not on every
    /// longest run still in the order the commit left them (`onEveryLongestRun`). The fewest moves that explain the
    /// order now are counted, so what was only gone round, or left behind by what moved, isn't. Where order can't tell
    /// which of two moved, as when neighbours are swapped, both are counted, so that the one the person moved is
    /// always among them. A child deleted or moved out leaves the others in order, and a child added by hand has no
    /// key, so neither moves anything.
    fileprivate static func moves(in current: LayerNode, written: [String: Written], moved: Set<String>) -> Set<String> {
        var found = moved
        func visit(_ parent: LayerNode) {
            var staying: [(key: String, place: Int)] = []
            for child in parent.children {
                guard let key = TreeReconciler.key(of: child), case .node(let id, let record)? = written[key], id == child.id,
                      !found.contains(key) else { continue }
                if record.parent == parent.id { staying.append((key, record.place)) } else { found.insert(key) }
            }
            let kept = onEveryLongestRun(staying.map(\.place))
            for (index, entry) in staying.enumerated() where !kept.contains(index) { found.insert(entry.key) }
            parent.children.forEach(visit)
        }
        visit(current)
        return found
    }

    /// The indices of `places` that lie on every longest run of them, first to last, in increasing order (plan 4 Task 4,
    /// fix round 2).
    ///
    /// Each index on a longest run sits at one level on it, the length of the longest run that ends there, and every
    /// longest run has one index at each level. So an index lies on all of them exactly when it is the only one at its
    /// level among the indices on any. Two neighbours swapped are two at one level, and neither is kept; one thing
    /// moved two places or more, the rest in order, is on no longest run, and everything else is on all of them.
    fileprivate static func onEveryLongestRun(_ places: [Int]) -> Set<Int> {
        let count = places.count
        guard count > 1 else { return Set(places.indices) }
        // The longest run in increasing order that ends at each index, and the longest that starts at it.
        var ending = Array(repeating: 1, count: count), starting = Array(repeating: 1, count: count)
        for last in 1..<count {
            for earlier in 0..<last where places[earlier] < places[last] {
                ending[last] = max(ending[last], ending[earlier] + 1)
            }
        }
        for first in stride(from: count - 2, through: 0, by: -1) {
            for later in (first + 1)..<count where places[later] > places[first] {
                starting[first] = max(starting[first], starting[later] + 1)
            }
        }
        let longest = ending.max() ?? 0
        var atLevel: [Int: [Int]] = [:]
        for index in 0..<count where ending[index] + starting[index] - 1 == longest {
            atLevel[ending[index], default: []].append(index)
        }
        return Set(atLevel.values.compactMap { $0.count == 1 ? $0[0] : nil })
    }
}

// MARK: - The merge

/// One merge's work: the screen indexed once, then the merged root built once, top down.
private struct Merging {
    /// What a generated key stands for, against the screen as it is now.
    enum State {
        /// Not written yet, or taken away by the rules in the commit that wrote it: written, with the id it had then.
        case new(UUID?)
        /// Deleted by the person; `found` when that is seen for the first time.
        case gone(found: Bool)
        /// Written and unchanged since: the generator's to write.
        case ours(UUID)
        /// Written and changed since by the person: theirs to keep.
        case theirs(UUID)
    }

    let written: [String: TreeReconciler.Written]
    let generatedRoot: LayerNode
    let currentRoot: LayerNode
    /// The screen as it is now, by id.
    var current: [UUID: TreeReconciler.Placed] = [:]
    /// The written keys the person has moved: before, or since the last commit (`TreeReconciler.moves`).
    let moved: Set<String>
    /// The first generated node of each key, in reading order.
    var generated: [String: LayerNode] = [:]
    /// The generated keys that can be written: those not inside a node that won't be, as one the person deleted,
    /// one with no key, or the second of a key repeated. A node of the screen the generator moves is moved only
    /// when its key is among them.
    var writable: Set<String> = []
    /// Keys written, so that a key repeated is written once.
    var placedKeys: Set<String> = [TreeReconciler.rootKey]
    /// Ids in the merged root, so that no node is in it twice.
    var usedIDs: Set<UUID> = []
    var deletedByUser: Set<String> = []
    var dropped: Set<String> = []
    var wrote: [String: UUID] = [:]

    init(written: [String: TreeReconciler.Written], moved: Set<String>, generated: LayerNode, current: LayerNode) {
        self.written = written
        self.generatedRoot = generated
        self.currentRoot = current
        TreeReconciler.index(current, into: &self.current)
        self.moved = TreeReconciler.moves(in: current, written: written, moved: moved)
        var byKey: [String: LayerNode] = [:], repeated: Set<String> = []
        TreeReconciler.walk(below: generated) { node, _, _ in
            guard let key = TreeReconciler.key(of: node) else { return }
            if byKey[key] == nil { byKey[key] = node } else { repeated.insert(key) }
        }
        self.generated = byKey
        var writable: Set<String> = []
        gatherWritable(below: generated, repeated: repeated, into: &writable)
        self.writable = writable
    }

    /// The keys below `node` that `build` writes: it goes no further than a node with no key, a key already
    /// reached, or one the person deleted. Nor does it go inside a key the generator repeats, since which of its
    /// places is written depends on where the person has put it: what is listed there and is on the screen stays
    /// where it is unless it is written first, so it is never lost.
    private func gatherWritable(below node: LayerNode, repeated: Set<String>, into writable: inout Set<String>) {
        for child in node.children {
            guard let key = TreeReconciler.key(of: child), !writable.contains(key) else { continue }
            if case .gone = state(of: key) { continue }
            writable.insert(key)
            if !repeated.contains(key) { gatherWritable(below: child, repeated: repeated, into: &writable) }
        }
    }

    mutating func merge() -> TreeReconciler.Merge {
        var root = currentRoot
        root.layout = generatedRoot.layout
        root.source = generatedRoot.source
        usedIDs.insert(root.id)
        root.children = children(of: root, generated: generatedRoot.children, current: currentRoot.children)
        return TreeReconciler.Merge(root: root, deletedByUser: deletedByUser, dropped: dropped, wrote: wrote,
                                    unmoved: unmoved(), moved: moved)
    }

    /// The written keys whose node is on the screen and not moved by the person: changed by them or not.
    func unmoved() -> Set<String> {
        Set(written.keys.filter { isOnTheScreen($0) && !moved.contains($0) })
    }

    /// Whether the store holds the written node of `key` with the id it was written with.
    func isOnTheScreen(_ key: String) -> Bool {
        guard case .node(let id, _)? = written[key] else { return false }
        return current[id] != nil
    }

    // MARK: Building

    func state(of key: String) -> State {
        switch written[key] {
        case nil: return .new(nil)
        case .removedByRules(let id)?: return .new(id)
        case .deletedByUser?: return .gone(found: false)
        case .node(let id, let record)?:
            guard let placed = current[id] else { return .gone(found: true) }
            return isUnchanged(key, placed, since: record) ? .ours(id) : .theirs(id)
        }
    }

    /// Whether a written node is as the commit that wrote it left it: the same fields, under the same parent, and
    /// never moved by the person.
    func isUnchanged(_ key: String, _ placed: TreeReconciler.Placed, since record: TreeReconciler.Record) -> Bool {
        placed.record.holdsTheSameNode(as: record) && !moved.contains(key)
    }

    /// The merged node for a generated one under the parent of id `parentID`, or nil when it isn't written there.
    mutating func build(_ generated: LayerNode, under parentID: UUID) -> LayerNode? {
        guard let key = TreeReconciler.key(of: generated), !placedKeys.contains(key) else { return nil }
        var node: LayerNode
        switch state(of: key) {
        case .gone(let found):
            if found { deletedByUser.insert(key) }
            return nil
        case .theirs(let id):
            // It lives where the person put it, and is merged there: in the generator's order when they changed only
            // what it is, or just where they put it, by `keep`, when they moved it, so that the generator's nodes go
            // round it.
            guard let placed = current[id], placed.parent == parentID, !usedIDs.contains(id), !moved.contains(key)
            else { return nil }
            node = placed.node
        case .ours(let id):
            guard !usedIDs.contains(id) else { return nil }
            node = generated
            node.id = id
            // What a newer Layer saved on it, which no generator knows of, stays with it.
            if let kept = current[id]?.node {
                node.unknownKeys = kept.unknownKeys
                node.unknownPartKeys = kept.unknownPartKeys
                node.unreadChildren = kept.unreadChildren
            }
            wrote[key] = id
        case .new(let remembered):
            node = generated
            if let remembered { node.id = remembered }
            if usedIDs.contains(node.id) || current[node.id] != nil { node.id = UUID() }
            wrote[key] = node.id
        }
        placedKeys.insert(key)
        usedIDs.insert(node.id)
        node.children = children(of: node, generated: generated.children, current: current[node.id]?.node.children ?? [])
        return node
    }

    /// What `parent` holds once merged: the generator's nodes in its order, and everything else it held now just
    /// after the generator's node it followed, or first.
    mutating func children(of parent: LayerNode, generated: [LayerNode], current: [LayerNode]) -> [LayerNode] {
        let sequence = generated.compactMap { build($0, under: parent.id) }
        let built = Set(sequence.map(\.id))
        var leading: [LayerNode] = [], following: [UUID: [LayerNode]] = [:]
        var anchor: UUID?
        for child in current {
            if built.contains(child.id) {
                anchor = child.id
                continue
            }
            guard !usedIDs.contains(child.id) else { continue }
            if let key = oursKey(child) {
                // Moved: written where the generator now puts it, with its id (F8).
                if writable.contains(key) { continue }
                // No longer listed: it goes, with everything inside it, unless something in it has to stay.
                if self.generated[key] == nil, !holdsOthers(child) {
                    drop(child)
                    continue
                }
                // Listed only where nothing is written, or holding what isn't the generator's: it stays here.
            }
            let kept = keep(child)
            if let anchor {
                following[anchor, default: []].append(kept)
            } else {
                leading.append(kept)
            }
        }
        return leading + sequence.flatMap { [$0] + (following[$0.id] ?? []) }
    }

    /// A node the generator doesn't write here, as it is. What it holds is merged as anywhere else, and when it is
    /// the person's changed version of a node the generator wrote, what the generator now puts in that goes in it.
    mutating func keep(_ node: LayerNode) -> LayerNode {
        usedIDs.insert(node.id)
        var kept = node
        var inside: [LayerNode] = []
        if let key = TreeReconciler.key(of: node), case .node(let id, _)? = written[key], id == node.id,
           !placedKeys.contains(key) {
            inside = generated[key]?.children ?? []
            placedKeys.insert(key)
        }
        kept.children = children(of: kept, generated: inside, current: node.children)
        return kept
    }

    /// The key of a node of the screen that the generator wrote and the person hasn't changed or moved since.
    func oursKey(_ node: LayerNode) -> String? {
        guard let key = TreeReconciler.key(of: node), case .node(let id, let record)? = written[key], id == node.id,
              let placed = current[id], isUnchanged(key, placed, since: record) else { return nil }
        return key
    }

    /// Whether anything inside `node` has to stay where it is: something added by hand or changed by the person, or
    /// the generator's own node listed only where nothing is written. One the generator moves takes what it holds.
    func holdsOthers(_ node: LayerNode) -> Bool {
        !node.unreadChildren.isEmpty || node.children.contains { child in
            guard let key = oursKey(child) else { return true }
            if writable.contains(key) { return false }
            return generated[key] != nil || holdsOthers(child)
        }
    }

    /// An unchanged node that goes, and everything inside it, which `holdsOthers` has found is all the generator's
    /// own: their keys are forgotten, so that a later update listing one writes it anew. What the generator moves
    /// elsewhere goes there, with what it holds.
    mutating func drop(_ node: LayerNode) {
        guard let key = oursKey(node), !writable.contains(key) else { return }
        dropped.insert(key)
        for child in node.children { drop(child) }
    }
}
