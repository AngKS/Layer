import CoreGraphics
import Foundation

/// A design taken apart for undo: each node's record, each parent's list of children, and the
/// screens without what is on them; put back together by `rebuild`. A host left whole (a screen,
/// or the canvas) isn't taken apart: undo leaves it as it is.
///
/// Only a damaged design has two nodes of one id. Of those, the first in reading order is a
/// record, as `TreeIndex` keeps it; each other, and a node of a screen root's id, rides along as
/// a passenger, kept as it is with all it holds, just after the sibling it followed. Their ids
/// are `shared`, and undo leaves those nodes as they are rather than lose one.
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

    /// A node's fields without its children, where it hangs, and where it was in its host.
    struct Record {
        var node: LayerNode
        var parent: Parent
        /// Where it was when taken apart. A merge or a landing on the canvas changes `node` and
        /// `parent`, never these.
        let takenFrom: Parent
        let host: TreeIndex.Host
        /// As `TreeIndex.Entry.hostShape` has it.
        let pose: TurnedRect
        /// Its parent's.
        let space: Space

        init(node: LayerNode, parent: Parent, host: TreeIndex.Host, space: Space) {
            self.node = node.withoutChildren
            self.parent = parent
            takenFrom = parent
            self.host = host
            pose = space.pose(of: node)
            self.space = space
        }

        /// The same node, in the same place in the same host.
        func isSame(as other: Record) -> Bool {
            node == other.node && parent == other.parent && host == other.host && pose == other.pose
        }
    }

    /// A node of an id already met, kept whole as it is.
    struct Passenger {
        /// With all it holds.
        var node: LayerNode
        var parent: Parent
        /// The records before it among its parent's children, nearest first: it goes just after
        /// the first of them still there, or first.
        var after: [UUID]
        /// Last on the canvas, where it went when its parent did.
        var isLast = false
        let host: TreeIndex.Host
        let pose: TurnedRect
        let space: Space

        func isSame(as other: Passenger) -> Bool {
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
    /// Each parent's records, back to front.
    var lists: [Parent: [UUID]] = [:]
    private(set) var passengers: [Passenger] = []
    /// The ids of nodes met more than once: those of the passengers, and of what they hold that
    /// is met elsewhere too.
    private(set) var shared: Set<UUID> = []
    /// The screens left whole, as they are.
    private var whole: [TreeScreen.ID: TreeScreen] = [:]
    /// The canvas, when it is left whole.
    private var wholeCanvas: [LayerNode]?
    private var rootIDs: Set<UUID> = []
    private var seen: Set<UUID> = []

    init(_ content: TreeContent, leavingWhole untouched: Set<TreeIndex.Host> = []) {
        rootIDs = Set(content.screens.map(\.root.id))
        for screen in content.screens where !seen.insert(screen.root.id).inserted { shared.insert(screen.root.id) }
        for screen in content.screens {
            screens.append(screen.withoutRootChildren)
            if untouched.contains(.screen(screen.id)) {
                whole[screen.id] = screen
                continue
            }
            add(screen.root.children, to: .node(screen.root.id), on: .screen(screen.id), in: Space.screen.inside(screen.root))
        }
        if untouched.contains(.canvas) {
            wholeCanvas = content.canvas
        } else {
            add(content.canvas, to: .canvas, on: .canvas, in: nil)
        }
    }

    /// `nodes` and what they hold, under `parent`, in `space`; the canvas's top level when nil.
    private mutating func add(_ nodes: [LayerNode], to parent: Parent, on host: TreeIndex.Host, in space: Space?) {
        var list: [UUID] = []
        for node in nodes {
            let space = space ?? .canvas(scale: node.scale)
            if !seen.insert(node.id).inserted { shared.insert(node.id) }
            guard records[node.id] == nil, !rootIDs.contains(node.id) else {
                passengers.append(Passenger(node: node, parent: parent, after: list.reversed(), host: host,
                                            pose: space.pose(of: node), space: space))
                meet(node.children)
                continue
            }
            records[node.id] = Record(node: node, parent: parent, host: host, space: space)
            order.append(node.id)
            ordered.insert(node.id)
            list.append(node.id)
            add(node.children, to: .node(node.id), on: host, in: space.inside(node))
        }
        if !list.isEmpty { lists[parent, default: []] += list }
    }

    /// Notes the ids inside a passenger, so that one met elsewhere too is shared.
    private mutating func meet(_ nodes: [LayerNode]) {
        for node in nodes {
            if !seen.insert(node.id).inserted { shared.insert(node.id) }
            meet(node.children)
        }
    }

    /// The hosts that are the same in every one of `contents`: the canvas, and each screen that
    /// is the only one of its id in each.
    static func hosts(alikeIn contents: [TreeContent]) -> Set<TreeIndex.Host> {
        guard let first = contents.first else { return [] }
        let byID = contents.map { Dictionary($0.screens.map { ($0.id, [$0]) }, uniquingKeysWith: +) }
        var hosts = Set(first.screens.filter { screen in byID.allSatisfy { $0[screen.id] == [screen] } }.map { TreeIndex.Host.screen($0.id) })
        if contents.allSatisfy({ $0.canvas == first.canvas }) { hosts.insert(.canvas) }
        return hosts
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

    /// Whether `parent` holds nothing: no record and no passenger.
    func isEmpty(_ parent: Parent) -> Bool {
        (lists[parent]?.isEmpty ?? true) && !passengers.contains { $0.parent == parent }
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
    /// as `content` or `previous` placed it, and at that screen's scale. A passenger whose parent
    /// isn't here goes the same way, after them.
    mutating func takeOutOrphans(placedFrom now: TreeRecords, else was: TreeRecords, posed: inout [UUID: Posed],
                                 in content: TreeContent, else previous: TreeContent) -> [UUID] {
        var orphans: [UUID] = [], taken: Set<UUID> = []
        func takeOut(_ id: UUID) {
            guard var record = records[id], taken.insert(id).inserted else { return }
            let isNow = now.records[id] != nil
            if let source = now.records[id] ?? was.records[id] {
                Self.land(&record.node, from: source.host, at: source.pose, in: source.space, placedBy: isNow ? content : previous)
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

        for index in passengers.indices where !holds(passengers[index].parent) {
            let passenger = passengers[index]
            Self.land(&passengers[index].node, from: passenger.host, at: passenger.pose, in: passenger.space, placedBy: content)
            passengers[index].parent = .canvas
            passengers[index].after = []
            passengers[index].isLast = true
        }
        return orphans
    }

    /// Gives `node` the frame, angle and scale that put it on the canvas's top level at `pose`:
    /// through the screen it was on, as `content` placed it, and at that screen's scale; or, from
    /// the canvas, at the scale it was drawn at there.
    private static func land(_ node: inout LayerNode, from host: TreeIndex.Host, at pose: TurnedRect, in space: Space,
                             placedBy content: TreeContent) {
        switch host {
        case .screen(let screenID):
            let screen = content.screens.first { $0.id == screenID }
            let scale = screen.flatMap { $0.scale.isFinite && $0.scale > 0 ? $0.scale : nil } ?? 1
            let origin = screen?.origin ?? .zero
            node.frame = pose.rect.offsetBy(dx: origin.x / scale, dy: origin.y / scale)
            node.scale = scale
        case .canvas:
            let scale = space.scale, rect = pose.rect
            node.frame = CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
            node.scale = scale
        }
        node.rotation = Rotation.kept(pose.degrees)
    }

    /// Each parent's list as `now` had it, of the nodes that are still there, and then, for each
    /// node in `before`'s list that the step moved, that comes back or that goes back to that
    /// parent: just after the nearest node before it there that is still there, or first. Those
    /// of `shared` ids keep their places. The orphans go last on the canvas.
    mutating func putInOrder(after left: TreeRecords, before was: TreeRecords, orphans: [UUID], leaving shared: Set<UUID>) {
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
            for (index, id) in beforeList.enumerated()
            where records[id]?.parent == parent && !away.contains(id) && !shared.contains(id) {
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
    /// order with the passengers among them. A node in `posed` is put into its parent's space at
    /// its pose now. A host left whole is written as it was.
    func rebuild(into content: inout TreeContent, posed: [UUID: Posed]) {
        enum Entry: Equatable {
            case record(UUID), passenger(after: UUID?), last

            var record: UUID? {
                guard case .record(let id) = self else { return nil }
                return id
            }
        }
        let riders = Dictionary(grouping: passengers, by: \.parent)
        var built: Set<UUID> = []

        func children(of parent: Parent, in space: Space?) -> [LayerNode] {
            var nodes: [LayerNode] = [], entries: [Entry] = []
            for id in lists[parent] ?? [] {
                guard let node = build(id, under: parent, in: space ?? .canvas(scale: records[id]?.node.scale)) else { continue }
                nodes.append(node)
                entries.append(.record(id))
            }
            let present = Set(entries.compactMap(\.record))
            for passenger in riders[parent] ?? [] {
                if passenger.isLast {
                    nodes.append(passenger.node)
                    entries.append(.last)
                    continue
                }
                let anchor = passenger.after.first(where: present.contains)
                var at = anchor.flatMap { entries.firstIndex(of: .record($0)) }.map { $0 + 1 } ?? 0
                while at < entries.count, entries[at] == .passenger(after: anchor) { at += 1 }
                nodes.insert(passenger.node, at: at)
                entries.insert(.passenger(after: anchor), at: at)
            }
            return nodes
        }

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
            // Drawn at its own scale on the canvas's top level; anywhere else it has none, as
            // today's rehost of what was left on a missing screen took it off.
            if record.takenFrom == .canvas, parent != .canvas { node.scale = nil }
            node.children = children(of: .node(id), in: space.inside(node))
            return node
        }

        content.screens = screens.map { screen in
            var screen = screen
            if let whole = whole[screen.id] {
                screen.root.children = whole.root.children
            } else {
                screen.root.children = children(of: .node(screen.root.id), in: Space.screen.inside(screen.root))
            }
            return screen
        }
        content.canvas = (wholeCanvas ?? []) + children(of: .canvas, in: nil)
    }
}
