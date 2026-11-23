import CoreGraphics
import Foundation

// Undo on the tree. The flat list's three-way revert took back one step's own changes from
// elements in a host's list, and left what anything else changed since. Here the same is done
// for nodes in a parent's list: each node is compared as a record, its fields
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
    /// The title goes back only if it is still the one the step gave; the settings, unknown
    /// keys and the canvas nodes this build couldn't read go back whole, as today. Screens go back by today's list rule, their roots' children
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
        if after.unreadCanvas != before.unreadCanvas { result.unreadCanvas = before.unreadCanvas }
        guard after.screens != before.screens || after.canvas != before.canvas else { return result }

        let untouched = TreeRecords.hosts(alikeIn: [self, after, before])
        let now = TreeRecords(self, leavingWhole: untouched)
        let left = TreeRecords(after, leavingWhole: untouched)
        let was = TreeRecords(before, leavingWhole: untouched)
        // Nodes that share an id, which only a damaged design has, are left as they are.
        let shared = now.shared.union(left.shared).union(was.shared)
        var undone = now
        undone.screens = Self.reverting(now.screens, after: left.screens, before: was.screens, id: \.id, fields: TreeScreen.reverting)

        // What the step added goes; what it removed comes back as it was; what it altered has
        // its own changes taken back. Altered by the step and since removed by another: it stays away.
        for id in left.order where was.records[id] == nil && !shared.contains(id) { undone.records[id] = nil }
        var posed: [UUID: TreeRecords.Posed] = [:]
        for id in was.order where !shared.contains(id) {
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
        undone.putInOrder(after: left, before: was, orphans: orphans, leaving: shared)
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
        if before.unreadCanvas != after.unreadCanvas, unreadCanvas == after.unreadCanvas { unreadCanvas = before.unreadCanvas }
        guard after.screens != before.screens || after.canvas != before.canvas else { return }

        let untouched = TreeRecords.hosts(alikeIn: [self, after, before])
        let was = TreeRecords(before, leavingWhole: untouched)
        let left = TreeRecords(after, leavingWhole: untouched)
        var now = TreeRecords(self, leavingWhole: untouched)
        // Nodes that share an id, which only a damaged design has, are left as they are.
        let shared = now.shared.union(left.shared).union(was.shared)

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

        for id in was.order where !shared.contains(id) {
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
        for id in left.order.reversed() where was.records[id] == nil && !shared.contains(id) {
            guard let c = now.records[id], let a = left.records[id], c.isSame(as: a), now.isEmpty(.node(id)) else { continue }
            now.take(id)
        }
        let screensBefore = Set(was.screens.map(\.id))
        let emptyAdded = Set(now.screens.filter { screen in
            !screensBefore.contains(screen.id) && screensLeft[screen.id] == screen && now.isEmpty(.node(screen.root.id))
        }.map(\.id))
        now.screens.removeAll { emptyAdded.contains($0.id) }

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
    /// The rule the flat list was taken back by, kept for the tree's screens.
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
