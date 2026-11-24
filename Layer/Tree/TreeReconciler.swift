import CoreGraphics
import Foundation

/// Writes each update of a generated screen into the screen as it is now, matching nodes by their
/// key (`LayerNode.Source.key`), which the outline and the A2UI importer give every node they make.
///
/// A node the generator wrote keeps its id for as long as the generation runs. One the person has
/// changed since its commit is left as they left it, one they moved is left where they put it, one
/// they deleted is never written again (nor anything that was inside it), and one they added by hand
/// is never touched and keeps its place (plan 3, calls 2 to 5). It is a value, made once per screen a
/// generation writes, and pure: the merge runs off the main actor, on a copy of the screen's root.
struct TreeReconciler: Sendable {
    /// A node as compared to see whether the person changed it: every field but `children`, `frame` only where it
    /// is the truth (under a free parent, and not a container sized to fit), its parent's id (call 2), and its place
    /// among the generator's nodes in that parent, its anchor (final review A-I1).
    ///
    /// A container sized to fit under a free parent keeps its origin in the record, and only its size, which the rules
    /// work out, is left out: the rules keep its corner where it is, so a drag of it is the person's change.
    struct Record: Equatable, Sendable {
        /// The node's own fields, with what it holds left out, and its frame too where the rules write it.
        private var fields: LayerNode
        fileprivate var parent: UUID?
        /// The key of the written node just before it in its parent, as the commit left them; nil when none was. A
        /// written node is one the generator wrote and the store still holds with the id it was written with.
        fileprivate var anchor: String?

        init(_ node: LayerNode, parent: UUID?, parentIsFree: Bool, anchor: String? = nil) {
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
            self.anchor = anchor
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
        /// The written keys whose node this merge found where its anchor says, the person's changed nodes among them:
        /// each is anchored again where the commit leaves it, its fields as they were. A node found moved keeps the
        /// anchor it had, so that it stays moved (plan 3's final re-review, A-I1).
        fileprivate var unmoved: Set<String> = []
    }

    /// The screen root's key, as `Outline` writes it.
    static let rootKey = ""

    private(set) var written: [String: Written] = [:]

    /// A new screen this generation made: nothing written yet.
    init() {}

    /// An existing screen (Build Screen): its keyed nodes count as written, as they are now and where they are now
    /// (call 7). Of two nodes that share a key, the first in reading order counts.
    init(adopting root: LayerNode) {
        var written: [String: Written] = [:]
        Self.walk(below: root) { node, parent in
            guard let key = Self.key(of: node), written[key] == nil else { return }
            written[key] = .node(id: node.id, record: Record(node, parent: parent.id,
                                                             parentIsFree: parent.resolvedLayout == .free))
        }
        self.written = written
        anchor(Set(written.keys), in: root)
    }

    /// Pure. `generated` is keyed by `source.key` (ids fresh from a parse). `current` is the screen's root now.
    ///
    /// The root keeps its id and everything about it but its layout and source, which are the generator's
    /// (call 5). Below it, each generated node is written by its key:
    /// - one not written before is new, with its parse id (or the id it had, when the rules took it away);
    /// - one written and unchanged since takes the generator's fields, with its id, wherever the generator puts it, and
    ///   keeps what a newer Layer saved on it;
    /// - one the person changed is left as it is, where it is, and what the generator puts inside it goes in it;
    /// - one the person moved (to another parent, or among the generator's nodes in its own) is the person's too;
    /// - one the person deleted isn't written, nor anything inside it.
    ///
    /// Within each parent the generator's nodes take its order. Everything else there (added by hand, moved by the
    /// person, or the person's and not listed there) stays just after the generator's node it followed, or first
    /// (call 4).
    /// A written node that is unchanged and that the generator no longer lists anywhere goes, with everything inside
    /// it that the generator no longer lists, unless it holds something that isn't the generator's. One the generator
    /// lists only where nothing is written (under a node the person deleted, say) stays where it is.
    func merged(_ generated: LayerNode, over current: LayerNode) -> Merge {
        var merging = Merging(written: written, generated: generated, current: current)
        return merging.merge()
    }

    /// After a commit, from the root the store now holds.
    ///
    /// Each key the merge wrote is recorded from the committed root, or as removed by the rules when the commit
    /// took its node away. A node the store gave a new id, because the design held its id elsewhere, is found by
    /// its key, so that it keeps the new one. Keys found deleted become deleted, with every key that was inside
    /// them and went with them, and keys dropped are forgotten.
    ///
    /// Every written node the merge didn't find moved is anchored where the commit leaves it, whether it wrote it or
    /// kept it (one the person changed, say), so that no anchor but a moved node's goes stale.
    mutating func record(_ merge: Merge, committed: LayerNode) {
        var placed: [UUID: Placed] = [:]
        Self.index(committed, into: &placed)
        var recorded: Set<String> = []
        let missing = Set(merge.wrote.filter { placed[$0.value] == nil }.keys)
        var renewed: [String: Placed] = [:]
        if !missing.isEmpty {
            var merged: Set<UUID> = []
            Self.walk(below: merge.root) { node, _ in merged.insert(node.id) }
            Self.walk(below: committed) { node, _ in
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
        for key in merge.dropped { written[key] = nil }
        // Which nodes are written is known only now, so each is placed among them last.
        anchor(recorded.union(merge.unmoved), in: committed)
    }

    /// Each of `keys` that is written as a node of `root` gets the anchor it has there: the key of the written node
    /// just before it among its siblings, or nil. Its fields stay as recorded.
    private mutating func anchor(_ keys: Set<String>, in root: LayerNode) {
        guard !keys.isEmpty else { return }
        let anchors = Self.anchors(in: root, written: written)
        for key in keys {
            guard case .node(let id, var record)? = written[key] else { continue }
            record.anchor = anchors[id]
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

    /// A node as a tree holds it: under which parent, and whether that parent places it freely.
    fileprivate struct Placed {
        var node: LayerNode
        var parent: UUID?
        var parentIsFree: Bool

        var record: Record { Record(node, parent: parent, parentIsFree: parentIsFree) }
    }

    /// A node's key, when it has one that isn't the root's.
    fileprivate static func key(of node: LayerNode) -> String? {
        guard let key = node.source?.key, key != rootKey else { return nil }
        return key
    }

    /// Every node below `root`, in reading order, with its parent.
    fileprivate static func walk(below root: LayerNode, _ body: (LayerNode, LayerNode) -> Void) {
        for child in root.children {
            body(child, root)
            walk(below: child, body)
        }
    }

    /// For each node of `root` that has a written node before it among its siblings, the key of the nearest one: its
    /// anchor. A written node is one `written` holds by its key with its id. A node added by hand, which has no key,
    /// is never an anchor, so it can come and go without moving anything.
    fileprivate static func anchors(in root: LayerNode, written: [String: Written]) -> [UUID: String] {
        var anchors: [UUID: String] = [:]
        func visit(_ node: LayerNode) {
            var last: String?
            for child in node.children {
                if let last { anchors[child.id] = last }
                if let key = Self.key(of: child), case .node(let id, _)? = written[key], id == child.id { last = key }
                visit(child)
            }
        }
        visit(root)
        return anchors
    }

    /// Every node of `root`, itself included, by id. The first of two nodes of one id is kept.
    fileprivate static func index(_ root: LayerNode, into placed: inout [UUID: Placed]) {
        if placed[root.id] == nil { placed[root.id] = Placed(node: root, parent: nil, parentIsFree: false) }
        walk(below: root) { node, parent in
            if placed[node.id] == nil {
                placed[node.id] = Placed(node: node, parent: parent.id, parentIsFree: parent.resolvedLayout == .free)
            }
        }
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
    /// The screen's anchors now: for each node with a written node before it among its siblings, that node's key.
    let anchors: [UUID: String]
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

    init(written: [String: TreeReconciler.Written], generated: LayerNode, current: LayerNode) {
        self.written = written
        self.generatedRoot = generated
        self.currentRoot = current
        TreeReconciler.index(current, into: &self.current)
        anchors = TreeReconciler.anchors(in: current, written: written)
        var byKey: [String: LayerNode] = [:], repeated: Set<String> = []
        TreeReconciler.walk(below: generated) { node, _ in
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
                                    unmoved: unmoved())
    }

    /// The written keys whose node is on the screen where its anchor says: changed by the person or not.
    func unmoved() -> Set<String> {
        var keys: Set<String> = []
        for (key, entry) in written {
            guard case .node(let id, let record) = entry, let placed = current[id], !wasMoved(placed, since: record)
            else { continue }
            keys.insert(key)
        }
        return keys
    }

    // MARK: Building

    func state(of key: String) -> State {
        switch written[key] {
        case nil: return .new(nil)
        case .removedByRules(let id)?: return .new(id)
        case .deletedByUser?: return .gone(found: false)
        case .node(let id, let record)?:
            guard let placed = current[id] else { return .gone(found: true) }
            return isUnchanged(placed, since: record) ? .ours(id) : .theirs(id)
        }
    }

    /// Whether a written node is as the commit that wrote it left it: the same fields, under the same parent, and in
    /// the same place among the generator's nodes there.
    func isUnchanged(_ placed: TreeReconciler.Placed, since record: TreeReconciler.Record) -> Bool {
        placed.record.holdsTheSameNode(as: record) && !wasMoved(placed, since: record)
    }

    /// Whether the person moved a written node since its commit: to another parent, or among the generator's nodes in
    /// its parent, so that the written node just before it now isn't its anchor. Where the anchor has gone from that
    /// parent since (deleted, moved out or dropped), the node that anchor followed stands in for it, so that what goes
    /// round a node doesn't move it.
    ///
    /// An anchor that can't be followed further, one forgotten, deleted or taken away by the rules before, is a move:
    /// every node found unmoved is anchored again at each commit, so only a node once found moved has an anchor that
    /// old, and it stays the person's (plan 3's final re-review, A-I1).
    func wasMoved(_ placed: TreeReconciler.Placed, since record: TreeReconciler.Record) -> Bool {
        guard placed.parent == record.parent else { return true }
        let now = anchors[placed.node.id]
        var anchor = record.anchor
        var followed: Set<String> = []
        while let key = anchor, key != now {
            guard followed.insert(key).inserted, case .node(let id, let recorded)? = written[key] else { return true }
            // Still there, and something else has come before the node.
            if current[id]?.parent == placed.parent { return true }
            anchor = recorded.anchor
        }
        return anchor != now
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
            guard let placed = current[id], placed.parent == parentID, !usedIDs.contains(id),
                  case .node(_, let record)? = written[key], !wasMoved(placed, since: record) else { return nil }
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
              let placed = current[id], isUnchanged(placed, since: record) else { return nil }
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
