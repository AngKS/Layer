import CoreGraphics
import Foundation

// Undo on the tree. Today's three-way revert (`DesignContent.reverting`) takes back one step's
// own changes from elements in a host's list, and leaves what anything else changed since. Here
// the same is done for nodes in a parent's list: each node is compared as a record, its fields
// without its children, its parent, and its pose in its host, and the lists are put back in
// order parent by parent.

extension LayerNode {
    /// Every field but `children`, three-way: a field the step changed goes back, and the rest
    /// stay as they are now, so another edit's changes since stay. `content` and `style` are
    /// merged per sub-field. A field missing here makes undo restore the whole node.
    /// The children are `current`'s.
    static func reverting(_ current: LayerNode, after: LayerNode, to before: LayerNode) -> LayerNode {
        func reverted(_ node: LayerNode) -> LayerNode {
            var back = FieldsBack(result: node, after: after, before: before)
            visitRevertedFields(&back)
            return back.result
        }
        var result = reverted(after).withoutChildren == before.withoutChildren ? reverted(current) : before
        result.children = current.children
        return result
    }

    /// The names `reverting` covers, as `Mirror` labels: "kind", "content.text", "style.tint", …
    static let revertedFields: Set<String> = {
        var names = FieldNames()
        LayerNode.visitRevertedFields(&names)
        return names.names
    }()

    /// The node without what it holds: its record's fields.
    var withoutChildren: LayerNode {
        var node = self
        node.children = []
        return node
    }

    /// Every field `reverting` takes back, with its name. Both of them read this one list.
    fileprivate static func visitRevertedFields(_ visitor: inout some RevertedFieldVisitor) {
        visitor.visit("id", \.id)
        visitor.visit("kind", \.kind)
        visitor.visit("unreadChildren", \.unreadChildren)
        visitor.visit("layout", \.layout)
        visitor.visit("padding", \.padding)
        visitor.visit("width", \.width)
        visitor.visit("height", \.height)
        visitor.visit("frame", \.frame)
        visitor.visit("rotation", \.rotation)
        visitor.visit("scale", \.scale)
        visitor.visit("content.text", \.content.text)
        visitor.visit("content.symbol", \.content.symbol)
        visitor.visit("content.shape", \.content.shape)
        visitor.visit("content.imageID", \.content.imageID)
        visitor.visit("content.isOn", \.content.isOn)
        visitor.visit("content.value", \.content.value)
        visitor.visit("content.buttonLook", \.content.buttonLook)
        visitor.visit("content.ink", \.content.ink)
        visitor.visit("style.tint", \.style.tint)
        visitor.visit("style.fontSize", \.style.fontSize)
        visitor.visit("style.fontWeight", \.style.fontWeight)
        visitor.visit("style.textColor", \.style.textColor)
        visitor.visit("style.textAlignment", \.style.textAlignment)
        visitor.visit("style.cornerRadius", \.style.cornerRadius)
        visitor.visit("style.opacity", \.style.opacity)
        visitor.visit("style.borderColor", \.style.borderColor)
        visitor.visit("style.borderWidth", \.style.borderWidth)
        visitor.visit("style.hasShadow", \.style.hasShadow)
        visitor.visit("name", \.name)
        visitor.visit("isLocked", \.isLocked)
        visitor.visit("isHidden", \.isHidden)
        visitor.visit("accessibility", \.accessibility)
        visitor.visit("sketch", \.sketch)
        visitor.visit("source", \.source)
        visitor.visit("interaction", \.interaction)
        visitor.visit("unknownKeys", \.unknownKeys)
    }
}

fileprivate protocol RevertedFieldVisitor {
    mutating func visit<Value: Equatable>(_ name: String, _ field: WritableKeyPath<LayerNode, Value>)
}

/// Puts each field that changed from `before` to `after` back as it was before.
private struct FieldsBack: RevertedFieldVisitor {
    var result: LayerNode
    let after: LayerNode
    let before: LayerNode

    mutating func visit<Value: Equatable>(_ name: String, _ field: WritableKeyPath<LayerNode, Value>) {
        if after[keyPath: field] != before[keyPath: field] { result[keyPath: field] = before[keyPath: field] }
    }
}

private struct FieldNames: RevertedFieldVisitor {
    var names: Set<String> = []

    mutating func visit<Value: Equatable>(_ name: String, _ field: WritableKeyPath<LayerNode, Value>) {
        names.insert(name)
    }
}

extension TreeScreen {
    /// Its own fields and its root's own fields (layout, padding, name, flags, …), never the
    /// root's children, which stay `current`'s. A field missing here makes undo restore the
    /// whole screen.
    static func reverting(_ current: TreeScreen, after: TreeScreen, to before: TreeScreen) -> TreeScreen {
        func reverted(_ screen: TreeScreen) -> TreeScreen {
            var result = screen
            func back<Value: Equatable>(_ field: WritableKeyPath<TreeScreen, Value>) {
                if after[keyPath: field] != before[keyPath: field] { result[keyPath: field] = before[keyPath: field] }
            }
            back(\.id); back(\.name); back(\.origin); back(\.scale); back(\.deviceID); back(\.isLocked); back(\.unknownKeys)
            result.root = LayerNode.reverting(screen.root, after: after.root, to: before.root)
            return result
        }
        var result = reverted(after).withoutRootChildren == before.withoutRootChildren ? reverted(current) : before
        result.root.children = current.root.children
        return result
    }

    /// The screen without what is on it: its record.
    var withoutRootChildren: TreeScreen {
        var screen = self
        screen.root.children = []
        return screen
    }
}

extension TreeContent {
    /// The change `before`→`after` taken back from this content, and only that change: whatever
    /// has changed since stays as it is now. With nothing else changed since, that is `before`.
    ///
    /// The title goes back only if it is still the one the step gave; the settings and unknown
    /// keys go back whole, as today. Screens go back by today's list rule, their roots' children
    /// left out. Then each node the step changed has its fields taken back (its parent among
    /// them), what it added goes and what it removed comes back, and each parent's list has what
    /// the step moved in it put back where it was among what is there now. A node moved to
    /// another parent, by the step or since, keeps the place on screen the merge gives it there.
    /// One whose parent is gone lands on the canvas where it was.
    func reverting(_ after: TreeContent, to before: TreeContent) -> TreeContent {
        if self == after { return before }
        var result = self
        if after.title != before.title, title == after.title { result.title = before.title }
        if after.settings != before.settings { result.settings = before.settings }
        if after.unknownKeys != before.unknownKeys { result.unknownKeys = before.unknownKeys }
        if after.manifestUnknownKeys != before.manifestUnknownKeys { result.manifestUnknownKeys = before.manifestUnknownKeys }
        guard after.screens != before.screens || after.canvas != before.canvas else { return result }

        let untouched = TreeRecords.screens(alikeIn: [self, after, before])
        let now = TreeRecords(self, leavingWhole: untouched)
        let left = TreeRecords(after, leavingWhole: untouched)
        let was = TreeRecords(before, leavingWhole: untouched)
        var undone = now
        undone.screens = Self.reverting(now.screens, after: left.screens, before: was.screens, id: \.id, fields: TreeScreen.reverting)

        // What the step added goes; what it removed comes back as it was; what it altered has
        // its own changes taken back. Altered by the step and since removed by another: it stays away.
        for id in left.order where was.records[id] == nil { undone.records[id] = nil }
        var posed: [UUID: TreeRecords.Posed] = [:]
        for id in was.order {
            guard let b = was.records[id] else { continue }
            guard let a = left.records[id] else {
                undone.restore(b, id: id)
                continue
            }
            guard !a.isSame(as: b), let c = undone.records[id] else { continue }
            var merged = c
            merged.node = LayerNode.reverting(c.node, after: a.node, to: b.node)
            merged.parent = a.parent != b.parent ? b.parent : c.parent
            if !(c.parent == a.parent && a.parent == b.parent) {
                posed[id] = TreeRecords.Posed(now: c, after: a, before: b)
            }
            undone.records[id] = merged
        }

        let orphans = undone.takeOutOrphans(placedFrom: now, else: was, posed: &posed, in: self, else: before)
        undone.putInOrder(after: left, before: was, orphans: orphans)
        undone.rebuild(into: &result, posed: posed)
        return result
    }

    /// Siri's late undo: takes back what the change did as far as each thing is still as the
    /// change left it. Whatever has been changed since is left as it is now.
    /// - A node goes back to how it was before only if it is now as the change left it.
    /// - A node the change added goes only if it is unchanged since and holds nothing.
    /// - A node the change removed comes back where it was, if its parent is still there.
    /// - Screens go back the same way, and a screen the change added goes only once it is empty.
    /// - An order goes back only if it is still the one the change left.
    mutating func takeBack(_ after: TreeContent, to before: TreeContent) {
        if before.title != after.title, title == after.title { title = before.title }
        if before.settings != after.settings, settings == after.settings { settings = before.settings }
        if before.unknownKeys != after.unknownKeys, unknownKeys == after.unknownKeys { unknownKeys = before.unknownKeys }
        if before.manifestUnknownKeys != after.manifestUnknownKeys, manifestUnknownKeys == after.manifestUnknownKeys {
            manifestUnknownKeys = before.manifestUnknownKeys
        }
        guard after.screens != before.screens || after.canvas != before.canvas else { return }

        let untouched = TreeRecords.screens(alikeIn: [self, after, before])
        let was = TreeRecords(before, leavingWhole: untouched)
        let left = TreeRecords(after, leavingWhole: untouched)
        var now = TreeRecords(self, leavingWhole: untouched)

        // Screens first, so that what was on one it removed can come back to it.
        let screensLeft = Dictionary(left.screens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, screen) in was.screens.enumerated() {
            if let leftScreen = screensLeft[screen.id] {
                if leftScreen != screen, let here = now.screens.firstIndex(where: { $0.id == screen.id }), now.screens[here] == leftScreen {
                    now.screens[here] = screen
                }
            } else if !now.screens.contains(where: { $0.id == screen.id }) {
                now.screens.insert(screen, at: min(index, now.screens.count))
            }
        }

        for id in was.order {
            guard let b = was.records[id] else { continue }
            if let a = left.records[id] {
                guard !a.isSame(as: b), let c = now.records[id], c.isSame(as: a) else { continue }
                if a.parent == b.parent {
                    now.records[id]?.node = b.node
                } else if now.holds(b.parent), !now.isWithin(b.parent, of: id) {
                    // Moved to another parent: back where it was, if that is still there.
                    now.take(id)
                    now.put(b, id: id, at: was.index(of: id))
                }
            } else if now.records[id] == nil, now.holds(b.parent) {
                now.put(b, id: id, at: was.index(of: id))
            }
        }

        // Deepest first, so that a node it added with others inside goes once they have.
        for id in left.order.reversed() where was.records[id] == nil {
            guard let c = now.records[id], let a = left.records[id], c.isSame(as: a), now.lists[.node(id)]?.isEmpty ?? true else { continue }
            now.take(id)
        }
        let screensBefore = Set(was.screens.map(\.id))
        now.screens.removeAll { screen in
            !screensBefore.contains(screen.id) && screensLeft[screen.id] == screen && (now.lists[.node(screen.root.id)]?.isEmpty ?? true)
        }

        // Things it only put in a new order go back to the old one, unless put in another since.
        for (parent, order) in was.lists {
            let leftOrder = left.lists[parent] ?? []
            guard order != leftOrder, Set(order) == Set(leftOrder), now.lists[parent] == leftOrder else { continue }
            now.lists[parent] = order
        }

        now.rebuild(into: &self, posed: [:])
    }

    /// `current` with what turned `before` into `after` taken back: what was added goes; what
    /// was taken away comes back where it was; what was altered goes back to how it was; what
    /// was moved among the rest goes back where it was. Anything else, in `current` alone, stays.
    ///
    /// Today's list rule (`DesignContent.reverting`), copied for the tree's screens until the
    /// store moves onto the tree and today's is deleted (plan 2, F15).
    private static func reverting<Item: Equatable, ID: Hashable>(
        _ current: [Item], after: [Item], before: [Item], id: (Item) -> ID,
        fields: (_ current: Item, _ after: Item, _ before: Item) -> Item
    ) -> [Item] {
        guard after != before else { return current }
        let beforeIDs = Set(before.map(id))
        var kept: [ID: Item] = [:]
        for item in after where kept[id(item)] == nil { kept[id(item)] = item }
        var result = current

        let added = Set(kept.keys).subtracting(beforeIDs)
        if !added.isEmpty { result.removeAll { added.contains(id($0)) } }

        let moved = TreeRecords.moved(from: before.map(id), to: after.map(id))
        for (index, item) in before.enumerated() {
            let key = id(item)
            let afterwards = kept[key]
            let altered = afterwards.map { $0 != item } ?? true
            let isMoved = moved.contains(key)
            guard altered || isMoved else { continue }
            let at = result.firstIndex { id($0) == key }
            func restored(_ now: Item) -> Item { afterwards.map { fields(now, $0, item) } ?? item }
            if let at, !isMoved {
                result[at] = restored(result[at])
                continue
            }
            if at == nil, afterwards != nil { continue }
            let value = at.map { altered ? restored(result[$0]) : result[$0] } ?? item
            if let at { result.remove(at: at) }
            var place = 0
            for earlier in before[..<index].reversed() {
                let earlierID = id(earlier)
                if let found = result.firstIndex(where: { id($0) == earlierID }) {
                    place = found + 1
                    break
                }
            }
            result.insert(value, at: place)
        }
        return result
    }
}

/// A design taken apart for undo: each node's record, each parent's list of children, and the
/// screens without what is on them; put back together by `rebuild`. A screen left whole isn't
/// taken apart: undo leaves it as it is.
///
/// Read leniently: of nodes that share an id, the first in reading order is the one kept, as
/// `TreeIndex` keeps it, and a node that shares a screen root's id is left out.
struct TreeRecords {
    /// Where a node hangs: in another node, a screen's root included, or on the canvas's top level.
    enum Parent: Hashable, Sendable {
        case node(UUID)
        case canvas
    }

    /// How a parent's space maps to its host's: screen points, or canvas points. The numbers are
    /// `TreeIndex`'s, worked out the same way.
    struct Space: Equatable {
        var toHost: CGAffineTransform
        var scale: CGFloat
        var degrees: Double

        /// A screen's own space, where its root sits.
        static let screen = Space(toHost: .identity, scale: 1, degrees: 0)

        /// Where a node on the canvas's top level sits: drawn at its own scale.
        static func canvas(scale: CGFloat?) -> Space {
            let scale = scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            return Space(toHost: CGAffineTransform(scaleX: scale, y: scale), scale: scale, degrees: 0)
        }

        /// The space `node`'s children sit in.
        func inside(_ node: LayerNode) -> Space {
            Space(toHost: node.transformToParent.concatenating(toHost), scale: scale, degrees: degrees + Self.degrees(of: node))
        }

        /// `node`'s pose in the host: its box about its centre there, and its summed angle.
        func pose(of node: LayerNode) -> TurnedRect {
            let centre = CGPoint(x: node.frame.width / 2, y: node.frame.height / 2)
                .applying(node.transformToParent.concatenating(toHost))
            let size = CGSize(width: node.frame.width * scale, height: node.frame.height * scale)
            let rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
            return TurnedRect(rect: rect, degrees: degrees + Self.degrees(of: node))
        }

        /// Gives `node` the frame and angle in this space that put it at `pose` in the host.
        func place(_ node: inout LayerNode, at pose: TurnedRect) {
            let centre = pose.centre.applying(toHost.inverted())
            let size = CGSize(width: pose.rect.width / scale, height: pose.rect.height / scale)
            node.frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
            node.rotation = Rotation.kept(pose.degrees - degrees)
        }

        /// An angle that isn't a number is upright, as `transformToParent` reads it.
        private static func degrees(of node: LayerNode) -> Double {
            node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
        }
    }

    /// A node's fields without its children, where it hangs, and where it is in its host.
    struct Record {
        var node: LayerNode
        var parent: Parent
        var host: TreeIndex.Host
        /// As `TreeIndex.Entry.hostShape` has it.
        var pose: TurnedRect
        /// Its parent's, as it was taken apart.
        var space: Space

        /// The same node, in the same place in the same host.
        func isSame(as other: Record) -> Bool {
            node == other.node && parent == other.parent && host == other.host && pose == other.pose
        }
    }

    /// A node moved between parents, by the step or since: its frame and angle merged as poses
    /// in the host, to be put into its parent's space once that is known.
    struct Posed {
        var pose: TurnedRect
        /// Where it already sat at that pose, in a parent: its frame and angle there are kept
        /// as they are when it lands in the same parent, in the same space.
        var sources: [Record]

        /// Each of the frame and the angle, back to before's if the step changed it, else as now.
        init(now c: Record, after a: Record, before b: Record) {
            let rect = Self.isNear(a.pose.rect, b.pose.rect) ? c.pose.rect : b.pose.rect
            let degrees = Self.isNear(a.pose.degrees, b.pose.degrees) ? c.pose.degrees : b.pose.degrees
            pose = TurnedRect(rect: rect, degrees: degrees)
            sources = [c, b].filter { Self.isNear($0.pose.rect, rect) && Self.isNear($0.pose.degrees, degrees) }
        }

        /// Within a millionth of a point: moving a node from one parent's space to another's
        /// and back doesn't always come to the same number.
        private static let tolerance = 1e-6

        private static func isNear(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
                && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
        }

        /// Angles, a whole turn apart or not.
        private static func isNear(_ a: Double, _ b: Double) -> Bool {
            let apart = abs((a - b).truncatingRemainder(dividingBy: 360))
            return min(apart, 360 - apart) <= tolerance
        }
    }

    /// The screens, their roots without children.
    var screens: [TreeScreen] = []
    var records: [UUID: Record] = [:]
    /// Every record's id, in reading order: screen by screen, then the canvas, each node before
    /// what it holds. Records brought back from another version follow, in its order.
    private(set) var order: [UUID] = []
    private var ordered: Set<UUID> = []
    /// Each parent's children, back to front.
    var lists: [Parent: [UUID]] = [:]
    /// The screens left whole, as they are.
    private(set) var whole: [TreeScreen.ID: TreeScreen] = [:]
    private var rootIDs: Set<UUID> = []

    init(_ content: TreeContent, leavingWhole untouched: Set<TreeScreen.ID> = []) {
        rootIDs = Set(content.screens.map(\.root.id))
        for screen in content.screens {
            screens.append(screen.withoutRootChildren)
            if untouched.contains(screen.id) {
                whole[screen.id] = screen
                continue
            }
            add(screen.root.children, to: .node(screen.root.id), on: .screen(screen.id), in: Space.screen.inside(screen.root))
        }
        add(content.canvas, to: .canvas, on: .canvas, in: nil)
    }

    /// `nodes` and what they hold, under `parent`, in `space`; the canvas's top level when nil.
    private mutating func add(_ nodes: [LayerNode], to parent: Parent, on host: TreeIndex.Host, in space: Space?) {
        var list: [UUID] = []
        for node in nodes where records[node.id] == nil && !rootIDs.contains(node.id) {
            let space = space ?? .canvas(scale: node.scale)
            records[node.id] = Record(node: node.withoutChildren, parent: parent, host: host, pose: space.pose(of: node), space: space)
            order.append(node.id)
            ordered.insert(node.id)
            list.append(node.id)
            add(node.children, to: .node(node.id), on: host, in: space.inside(node))
        }
        if !list.isEmpty { lists[parent, default: []] += list }
    }

    /// The screens that are the same in every one of `contents`, and the only one of their id in each.
    static func screens(alikeIn contents: [TreeContent]) -> Set<TreeScreen.ID> {
        guard let first = contents.first else { return [] }
        let byID = contents.map { Dictionary($0.screens.map { ($0.id, [$0]) }, uniquingKeysWith: +) }
        return Set(first.screens.filter { screen in byID.allSatisfy { $0[screen.id] == [screen] } }.map(\.id))
    }

    /// Of what is in both lists, what has something else just before it in `after`: today's rule
    /// for what a change moved.
    static func moved<ID: Hashable>(from before: [ID], to after: [ID]) -> Set<ID> {
        let inBefore = Set(before), inAfter = Set(after)
        let stayedBefore = before.filter(inAfter.contains)
        let stayedAfter = after.filter(inBefore.contains)
        guard stayedBefore != stayedAfter else { return [] }
        func predecessors(_ order: [ID]) -> [ID: ID] {
            Dictionary(zip(order.dropFirst(), order), uniquingKeysWith: { first, _ in first })
        }
        let was = predecessors(stayedBefore), now = predecessors(stayedAfter)
        return Set(stayedBefore.filter { was[$0] != now[$0] })
    }

    // MARK: Changing

    /// Whether `parent` is here: the canvas, a screen's root, or a node.
    func holds(_ parent: Parent) -> Bool {
        switch parent {
        case .canvas: true
        case .node(let id): records[id] != nil || screens.contains { $0.root.id == id }
        }
    }

    /// Whether `parent` is the node `id` or inside it.
    func isWithin(_ parent: Parent, of id: UUID) -> Bool {
        var next = parent, seen: Set<UUID> = []
        while case .node(let current) = next, seen.insert(current).inserted {
            if current == id { return true }
            guard let record = records[current] else { return false }
            next = record.parent
        }
        return false
    }

    /// Where `id` is in its parent's list.
    func index(of id: UUID) -> Int {
        guard let parent = records[id]?.parent else { return 0 }
        return lists[parent]?.firstIndex(of: id) ?? 0
    }

    /// Brings `record` back as the node `id`, keeping its place if it is here already.
    mutating func restore(_ record: Record, id: UUID) {
        if ordered.insert(id).inserted { order.append(id) }
        records[id] = record
    }

    /// Takes the node `id` out of its parent's list and the records, what it holds staying with it.
    mutating func take(_ id: UUID) {
        guard let parent = records[id]?.parent else { return }
        lists[parent]?.removeAll { $0 == id }
        records[id] = nil
    }

    /// Puts `record` in as the node `id`, at `index` in its parent's list or last.
    mutating func put(_ record: Record, id: UUID, at index: Int) {
        restore(record, id: id)
        var list = lists[record.parent] ?? []
        list.insert(id, at: min(index, list.count))
        lists[record.parent] = list
    }

    /// Moves to the canvas's top level each record whose parent isn't here, and, of records whose
    /// parents would make a loop, the one latest in `was`'s order. Each lands where it was on the
    /// canvas: as `now` has it if it is there, else as `was` does, through the screen it was on
    /// as `content` or `previous` placed it, and at that screen's scale.
    mutating func takeOutOrphans(placedFrom now: TreeRecords, else was: TreeRecords, posed: inout [UUID: Posed],
                                 in content: TreeContent, else previous: TreeContent) -> [UUID] {
        var orphans: [UUID] = [], taken: Set<UUID> = []
        func takeOut(_ id: UUID) {
            guard var record = records[id], taken.insert(id).inserted else { return }
            let isNow = now.records[id] != nil
            if let source = now.records[id] ?? was.records[id] {
                switch source.host {
                case .screen(let screenID):
                    let screen = (isNow ? content : previous).screens.first { $0.id == screenID }
                    let scale = screen.flatMap { $0.scale.isFinite && $0.scale > 0 ? $0.scale : nil } ?? 1
                    let origin = screen?.origin ?? .zero
                    record.node.frame = source.pose.rect.offsetBy(dx: origin.x / scale, dy: origin.y / scale)
                    record.node.scale = scale
                case .canvas:
                    let scale = source.space.scale, rect = source.pose.rect
                    record.node.frame = CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
                    record.node.scale = scale
                }
                record.node.rotation = Rotation.kept(source.pose.degrees)
            }
            record.parent = .canvas
            records[id] = record
            posed[id] = nil
            orphans.append(id)
        }

        for id in order {
            guard let record = records[id], !holds(record.parent) else { continue }
            takeOut(id)
        }
        // Each chain of parents is followed up once: to the canvas, a screen's root, or a loop.
        var settled: Set<UUID> = []
        var beforeOrder: [UUID: Int]?
        for id in order where records[id] != nil && !settled.contains(id) {
            var path: [UUID] = [], onPath: Set<UUID> = []
            var next: UUID? = id
            while let current = next, !settled.contains(current) {
                if onPath.contains(current) {
                    if beforeOrder == nil {
                        beforeOrder = Dictionary(was.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                    }
                    let loop = path.drop { $0 != current }
                    if let latest = loop.max(by: { (beforeOrder?[$0] ?? -1) < (beforeOrder?[$1] ?? -1) }) { takeOut(latest) }
                    break
                }
                onPath.insert(current)
                path.append(current)
                guard case .node(let parent)? = records[current]?.parent, records[parent] != nil else { break }
                next = parent
            }
            settled.formUnion(path)
        }
        return orphans
    }

    /// Each parent's list as `now` had it, of the nodes that are still there, and then, for each
    /// node in `before`'s list that the step moved, that comes back or that goes back to that
    /// parent: just after the nearest node before it there that is still there, or first.
    /// The orphans go last on the canvas.
    mutating func putInOrder(after left: TreeRecords, before was: TreeRecords, orphans: [UUID]) {
        let away = Set(orphans)
        var result: [Parent: [UUID]] = [:]
        for (parent, ids) in lists {
            let kept = ids.filter { records[$0]?.parent == parent && !away.contains($0) }
            if !kept.isEmpty { result[parent] = kept }
        }
        for (parent, beforeList) in was.lists {
            let moved = Self.moved(from: beforeList, to: left.lists[parent] ?? [])
            var list = result[parent] ?? []
            var inList = Set(list)
            for (index, id) in beforeList.enumerated() where records[id]?.parent == parent && !away.contains(id) {
                let isThere = inList.contains(id)
                guard !isThere || moved.contains(id) else { continue }
                if isThere, let at = list.firstIndex(of: id) { list.remove(at: at) }
                var place = 0
                for earlier in beforeList[..<index].reversed() where inList.contains(earlier) {
                    if let found = list.firstIndex(of: earlier) {
                        place = found + 1
                        break
                    }
                }
                list.insert(id, at: place)
                inList.insert(id)
            }
            if !list.isEmpty { result[parent] = list }
        }
        if !orphans.isEmpty { result[.canvas, default: []] += orphans }
        lists = result
    }

    /// Writes the screens and the canvas into `content`, each node's children in their list's
    /// order. A node in `posed` is put into its parent's space at its pose now.
    func rebuild(into content: inout TreeContent, posed: [UUID: Posed]) {
        var built: Set<UUID> = []
        func build(_ id: UUID, under parent: Parent, in space: Space) -> LayerNode? {
            guard let record = records[id], built.insert(id).inserted else { return nil }
            var node = record.node
            if let posed = posed[id] {
                if let source = posed.sources.first(where: { $0.parent == parent && $0.space == space }) {
                    node.frame = source.node.frame
                    node.rotation = source.node.rotation
                } else {
                    space.place(&node, at: posed.pose)
                }
            }
            let inside = space.inside(node)
            node.children = (lists[.node(id)] ?? []).compactMap { build($0, under: .node(id), in: inside) }
            return node
        }
        content.screens = screens.map { screen in
            if let whole = whole[screen.id] {
                var kept = screen
                kept.root.children = whole.root.children
                return kept
            }
            var screen = screen
            let inRoot = Space.screen.inside(screen.root)
            screen.root.children = (lists[.node(screen.root.id)] ?? []).compactMap { build($0, under: .node(screen.root.id), in: inRoot) }
            return screen
        }
        content.canvas = (lists[.canvas] ?? []).compactMap { id in
            build(id, under: .canvas, in: .canvas(scale: records[id]?.node.scale))
        }
    }
}
