@_weakLinked import AppIntents
import CoreGraphics
import Foundation

/// A design's contents at one moment: live from its window when it is open, read from its
/// file when it isn't.
struct DesignSnapshot: Sendable {
    let id: String
    let name: String
    let content: TreeContent
    let modified: Date?
    /// False for a design listed by its name alone, which iCloud hasn't downloaded: see
    /// `DesignSummary.isRead`.
    var isRead = true

    var entity: DesignEntity {
        DesignEntity(id: id, content: content, fallbackName: name, modified: modified)
    }

    var screens: [ScreenEntity] {
        content.screens.map { ScreenEntity(design: id, designName: name, screen: $0, settings: content.settings) }
    }

    /// Every screen's leaves, then the open canvas's, each depth first and back to front: Siri sees leaves, never the
    /// containers that hold them (My call 9). Each is locked or hidden as it is with the containers above it, though
    /// not with its screen's lock.
    var elements: [ElementEntity] {
        let index = TreeIndex(content)
        func entity(_ leaf: LayerNode, on host: TreeIndex.Host, called hostName: String) -> ElementEntity {
            let entry = index[leaf.id]
            return ElementEntity(design: id, host: host, hostName: hostName, node: leaf,
                                 isLocked: entry?.isLockedWithAncestors ?? leaf.isLocked,
                                 isHidden: entry?.isHiddenWithAncestors ?? leaf.isHidden)
        }
        return content.screens.flatMap { screen in
            screen.root.leaves.map { entity($0, on: .screen(screen.id), called: screen.name) }
        } + content.canvasLeaves.map { entity($0, on: .canvas, called: "Canvas") }
    }
}

/// Everything Siri and Shortcuts do to designs goes through here, so that an action from
/// either one behaves exactly as the same change made by hand: through the design's store,
/// undoable, on the design in its window.
@MainActor
enum DesignActions {
    // MARK: Finding designs

    static func snapshot(of model: AppModel) -> DesignSnapshot? {
        guard let id = model.designID else { return nil }
        let name = model.store.title ?? model.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return DesignSnapshot(id: id, name: name, content: model.store.tree, modified: .now)
    }

    /// A design by the identifier Siri or Shortcuts holds for it, which may be one it had
    /// before its file was renamed. The snapshot keeps that identifier, so that the design
    /// and its screens and elements answer to the identifiers they were asked for by.
    static func snapshot(design id: String) async -> DesignSnapshot? {
        if let model = OpenDesigns.shared.model(forDesign: id), let open = snapshot(of: model) {
            return DesignSnapshot(id: id, name: open.name, content: open.content, modified: open.modified)
        }
        guard let summary = await DesignLibrary.summary(for: OpenDesigns.shared.currentID(for: id)) else { return nil }
        return DesignSnapshot(id: id, name: summary.title, content: summary.content, modified: summary.modified)
    }

    /// Every design: the open ones as they are now, the rest as saved. Newest first.
    static func allSnapshots() async -> [DesignSnapshot] {
        snapshots(with: await DesignLibrary.all())
    }

    /// Every design: the open ones as they are now, the rest as `saved` has them.
    static func snapshots(with saved: [DesignSummary]) -> [DesignSnapshot] {
        let open = OpenDesigns.shared.all.compactMap(snapshot(of:))
        let openIDs = Set(open.map(\.id))
        let rest = saved
            .filter { !openIDs.contains($0.id) }
            .map { DesignSnapshot(id: $0.id, name: $0.title, content: $0.content, modified: $0.modified, isRead: $0.isRead) }
        return open.reversed() + rest
    }

    /// The design an action works on: the one named, opened if it isn't already, or else
    /// the one at the front.
    static func model(for designID: String?) async throws -> AppModel {
        if let designID { return try await OpenDesigns.shared.open(design: designID) }
        guard let model = OpenDesigns.shared.current else { throw LayerIntentError.noOpenDesign }
        return model
    }

    static func model(for design: DesignEntity?) async throws -> AppModel {
        try await model(for: design?.id)
    }

    static func screen(_ entity: ScreenEntity) async throws -> (model: AppModel, screen: DesignScreen) {
        guard let id = entity.screenID else { throw LayerIntentError.screenNotFound }
        let model = try await model(for: entity.designID)
        guard let screen = model.store.screen(id) else { throw LayerIntentError.screenNotFound }
        return (model, screen)
    }

    /// The screen named, or the selected one, or the one an element is selected on, or
    /// the design's only or newest screen.
    static func screenOrCurrent(_ entity: ScreenEntity?) async throws -> (model: AppModel, screen: DesignScreen) {
        if let entity { return try await screen(entity) }
        let model = try await model(for: nil as String?)
        if let screen = model.selectedScreen { return (model, screen) }
        if let selected = model.selectedElement, case .screen(let id) = selected.ref.host, let screen = model.store.screen(id) {
            return (model, screen)
        }
        guard let screen = model.store.screens.last else { throw LayerIntentError.screenNotFound }
        return (model, screen)
    }

    static func element(_ entity: ElementEntity) async throws -> (model: AppModel, ref: DesignStore.ElementRef, element: DesignElement) {
        guard let ref = entity.ref else { throw LayerIntentError.elementNotFound }
        let model = try await model(for: entity.designID)
        guard let found = model.store.resolve(ref) else { throw LayerIntentError.elementNotFound }
        return (model, ref, found.element)
    }

    /// Throws `locked` when an element is locked, by itself or by a group above it: Siri
    /// doesn't move, align or delete it, as a finger can't (F4).
    static func requireUnlocked(_ ref: DesignStore.ElementRef, in model: AppModel) throws {
        guard !model.store.isLocked(.element(ref)) else { throw LayerIntentError.locked }
    }

    /// The element named, or else the selected one: see `selected(in:)`.
    static func elementOrSelected(_ entity: ElementEntity?) async throws -> (model: AppModel, ref: DesignStore.ElementRef, element: DesignElement) {
        if let entity { return try await element(entity) }
        return try selected(in: try await model(for: nil as String?))
    }

    /// The one element selected in a design, as Siri sees it: see `selectedElement(in:)`.
    /// Throws `elementNotFound` when there is none, as when several things are selected, or
    /// a group.
    static func selected(in model: AppModel) throws -> (model: AppModel, ref: DesignStore.ElementRef, element: DesignElement) {
        guard let selected = selectedElement(in: model) else { throw LayerIntentError.elementNotFound }
        return (model, selected.ref, selected.element)
    }

    /// The one element selected, unless it is a group: Siri, which knows nothing of groups,
    /// sees what is in one, never the group item itself (F6). Taken as one element, a group
    /// would be moved or changed alone, and its members ungrouped. A member selected inside a
    /// group is an element like any other.
    static func selectedElement(in model: AppModel) -> (ref: DesignStore.ElementRef, element: DesignElement, placement: Placement)? {
        guard let selected = model.selectedElement, selected.element.kind != .group else { return nil }
        return selected
    }

    // MARK: Finding nodes

    /// The node an entity names, with where it is. Throws `elementNotFound` when it is gone, or has gone to another
    /// host since.
    static func node(_ entity: ElementEntity) async throws -> (model: AppModel, ref: DesignStore.ElementRef, node: LayerNode) {
        guard let ref = entity.ref else { throw LayerIntentError.elementNotFound }
        let model = try await model(for: entity.designID)
        guard let placed = model.store.placed(ref) else { throw LayerIntentError.elementNotFound }
        return (model, ref, placed.node)
    }

    /// The node named, or else the one leaf selected: see `selectedLeaf(in:)`. Throws `elementNotFound` when nothing
    /// is named and no one leaf is selected.
    static func nodeOrSelected(_ entity: ElementEntity?) async throws -> (model: AppModel, ref: DesignStore.ElementRef, node: LayerNode) {
        if let entity { return try await node(entity) }
        let model = try await model(for: nil as String?)
        guard let selected = selectedLeaf(in: model) else { throw LayerIntentError.elementNotFound }
        return (model, selected.ref, selected.node)
    }

    /// The one leaf selected. Nil for a container, several things or nothing: Siri sees what is in a container, never
    /// the container itself (My call 9). Taken as one element, a container would be moved or changed without what it
    /// holds. A leaf selected inside a container is one like any other.
    static func selectedLeaf(in model: AppModel) -> PlacedNode? {
        guard let selected = model.selectedNode, !selected.node.isContainer else { return nil }
        return selected
    }

    /// The screen named, or the selected one, or the one a thing is selected on, or the design's newest screen, as the
    /// tree holds it.
    static func treeScreenOrCurrent(_ entity: ScreenEntity?) async throws -> (model: AppModel, screen: TreeScreen) {
        if let entity {
            guard let id = entity.screenID else { throw LayerIntentError.screenNotFound }
            let model = try await model(for: entity.designID)
            guard let screen = model.store.treeScreen(id) else { throw LayerIntentError.screenNotFound }
            return (model, screen)
        }
        let model = try await model(for: nil as String?)
        if let id = model.selectedScreenID, let screen = model.store.treeScreen(id) { return (model, screen) }
        if let selected = model.selectedNode, case .screen(let id) = selected.ref.host, let screen = model.store.treeScreen(id) {
            return (model, screen)
        }
        guard let screen = model.store.tree.screens.last else { throw LayerIntentError.screenNotFound }
        return (model, screen)
    }

    /// The elements of a design as Siri offers them: the one leaf selected first (see `selectedLeaf(in:)`), then the
    /// rest as `elements` has them.
    static func suggested(_ elements: [ElementEntity], in model: AppModel) -> [ElementEntity] {
        guard let selected = selectedLeaf(in: model),
              let index = elements.firstIndex(where: { $0.ref?.element == selected.node.id }) else {
            return elements
        }
        var elements = elements
        elements.insert(elements.remove(at: index), at: 0)
        return elements
    }

    /// The entity of the leaf a ref points at, locked or hidden as it is with the containers above it. Nil when it is
    /// gone, has gone to another host, or is a container, which Siri doesn't see (My call 9).
    static func entity(for ref: DesignStore.ElementRef, in model: AppModel) -> ElementEntity? {
        guard let id = model.designID, let placed = model.store.placed(ref), !placed.node.isContainer,
              let host = model.store.index[ref.element]?.host else { return nil }
        let hostName = switch host {
        case .screen(let screenID): model.store.treeScreen(screenID)?.name ?? "Screen"
        case .canvas: "Canvas"
        }
        return ElementEntity(design: id, host: host, hostName: hostName, node: placed.node,
                             isLocked: placed.isLocked, isHidden: placed.isHidden)
    }

    /// The entity of a screen in the design. Nil when the design has no such screen, or isn't saved anywhere yet.
    static func entity(for screenID: TreeScreen.ID, in model: AppModel) -> ScreenEntity? {
        guard let snapshot = snapshot(of: model), let screen = snapshot.content.screens.first(where: { $0.id == screenID }) else {
            return nil
        }
        return ScreenEntity(design: snapshot.id, designName: snapshot.name, screen: screen, settings: snapshot.content.settings)
    }

    // MARK: Changing designs

    /// Makes a change to a design as one undo step, in the design's own undo history and,
    /// when the system offers one, in the action's undo manager too.
    static func edit<T>(_ model: AppModel, undoManager: UndoManager?, actionName: String, _ body: () throws -> T) rethrows -> T {
        let before = model.store.content
        // Its own step, even in the middle of a drag, which goes on as its own (M3).
        let edit = model.store.beginEdit(by: .app)
        defer {
            model.store.endEdit(edit)
            let after = model.store.content
            if before != after, let undoManager, undoManager !== model.store.undoManager {
                let action = TakenAction(name: actionName, before: before, after: after, model: model, undoManager: undoManager)
                model.takenActions.append(action)
                undoManager.beginUndoGrouping()
                // The system's history holds its target weakly: the action is kept alive by
                // its own handler.
                undoManager.registerUndo(withTarget: action) { [action] _ in
                    MainActor.assumeIsolated { action.takeBack() }
                }
                undoManager.setActionName(actionName)
                undoManager.endUndoGrouping()
            }
        }
        return try model.store.act(for: edit, body)
    }

    /// Selects something and glides the canvas to show it: a node by the box round its turned shape on the canvas, a
    /// screen with its name. `selecting` false shows it without selecting it, as for a screen just made.
    static func reveal(_ target: CanvasSelection, in model: AppModel, selecting: Bool = true) {
        model.tool = .select
        if selecting { model.selection = target }
        let area: CGRect? = switch target {
        case .element, .several:
            model.store.canvasFrame(of: target)
        case .screen(let id):
            model.store.treeScreen(id).map { screen in
                let device = model.store.tree.device(of: screen)
                return screen.canvasFrame(on: device).union(screen.labelFrame(on: device))
            }
        }
        if let area { model.ink?.glide(toShow: area) }
    }

    /// Where a new screen goes: to the right of the others, at the newest screen's scale.
    ///
    /// With a `point`, in canvas points, the screen's top-left corner goes there instead,
    /// moved right past any screen it would lie over.
    static func placementForNewScreen(_ device: DeviceFrame, in model: AppModel, near point: CGPoint? = nil) -> Placement {
        let scale = model.store.screens.last?.scale ?? 0.6
        if let point {
            // The screen with its name above it, which is what mustn't lie over another.
            let nameHeight = 34 * scale
            let top = point.y.rounded()
            var taken = CGRect(
                x: point.x.rounded(), y: top - nameHeight,
                width: device.size.width * scale, height: device.size.height * scale + nameHeight
            )
            // Each move clears one screen and only goes rightwards, so this ends.
            while let blocking = model.store.screens.map({ $0.canvasFrame.union($0.labelFrame) }).first(where: { $0.intersects(taken) }) {
                taken.origin.x = (blocking.maxX + 60).rounded()
            }
            return Placement(origin: CGPoint(x: taken.minX, y: top), scale: scale)
        }
        if let rightmost = model.store.screens.max(by: { $0.canvasFrame.maxX < $1.canvasFrame.maxX }) {
            return Placement(origin: CGPoint(x: (rightmost.canvasFrame.maxX + 60).rounded(), y: rightmost.origin.y), scale: scale)
        }
        let middle = CGPoint(x: Viewport.canvasSize.width / 2, y: Viewport.canvasSize.height / 2)
        let size = CGSize(width: device.size.width * scale, height: device.size.height * scale)
        return Placement(origin: CGPoint(x: (middle.x - size.width / 2).rounded(), y: (middle.y - size.height / 2).rounded()), scale: scale)
    }

    /// Where a new element goes on a screen: `ElementLayout.newElementFrame` below its visible elements. Plan 6's Task 5
    /// moves its callers to `DesignStore.newElementFrame(_:on:)` and deletes it.
    static func frameForNewElement(_ element: DesignElement, on screen: DesignScreen) -> CGRect {
        ElementLayout.newElementFrame(for: element.kind, on: screen.device, below: screen.elements.filter { !$0.isHidden }.map(\.frame))
    }
}

/// An action Siri or Shortcuts took on a design, kept for the system's undo of it.
///
/// The system's undo can't be told that it failed: it calls the handler and says the action
/// was undone. So an action that can no longer be taken back is taken out of the system's
/// history instead, leaving Siri nothing to undo: when its design closes, and, checked as
/// the app stops being active, once everything it changed has been changed since. See
/// `AppModel.takenActions`.
@MainActor
final class TakenAction {
    let name: String
    private let before: DesignContent
    private let after: DesignContent
    private weak var model: AppModel?
    private weak var undoManager: UndoManager?

    init(name: String, before: DesignContent, after: DesignContent, model: AppModel, undoManager: UndoManager) {
        self.name = name
        self.before = before
        self.after = after
        self.model = model
        self.undoManager = undoManager
    }

    /// Whether anything the action changed is still as the action left it in `content`.
    func canTakeBack(from content: DesignContent) -> Bool {
        if content == after { return true }
        var taken = content
        taken.takeBack(after, to: before)
        return taken != content
    }

    /// Takes the action out of the system's history, so that nothing offers to undo it.
    func withdraw() {
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Puts back what the action changed, as one step in the design's own history. Undone
    /// straight away, the design goes back as it was. Undone after more has been done, only
    /// what the action changed and nothing has changed since goes back. When nothing is
    /// left to take back, nothing changes, and the design says so.
    func takeBack() {
        guard let model else { return }
        model.takenActions.removeAll { $0 === self }
        guard !model.isClosed else { return }
        let store = model.store
        // A one-off step of its own, as the action was: a drag under way meanwhile stays
        // one step of its own, rather than taking this in.
        if store.content == after {
            store.asOwnStep { store.restore(before) }
        } else if canTakeBack(from: store.content) {
            store.asOwnStep { store.apply { $0.takeBack(after, to: before) } }
        } else {
            model.undoNotice = "Siri couldn't undo “\(name)”: everything it changed has been changed since. Use Undo in Layer to go back step by step."
        }
    }
}

// MARK: Queries

struct DesignQuery: EntityStringQuery, EnumerableEntityQuery {
    static let findIntentDescription: IntentDescription? = IntentDescription(
        "Finds Layer designs by name or by the names of their screens.",
        categoryName: "Designs"
    )

    func entities(for identifiers: [DesignEntity.ID]) async throws -> [DesignEntity] {
        var found: [DesignEntity] = []
        for id in identifiers {
            if let snapshot = await DesignActions.snapshot(design: id) { found.append(snapshot.entity) }
        }
        return found
    }

    func suggestedEntities() async throws -> [DesignEntity] {
        Array(await DesignActions.allSnapshots().prefix(20).map(\.entity))
    }

    func allEntities() async throws -> [DesignEntity] {
        await DesignActions.allSnapshots().map(\.entity)
    }

    func entities(matching string: String) async throws -> [DesignEntity] {
        let words = string.lowercased()
        return await DesignActions.allSnapshots().map(\.entity).filter { design in
            design.name.lowercased().contains(words) || design.screenNames.contains { $0.lowercased().contains(words) }
        }
    }
}

struct ScreenQuery: EntityStringQuery {
    func entities(for identifiers: [ScreenEntity.ID]) async throws -> [ScreenEntity] {
        var found: [ScreenEntity] = []
        var snapshots: [String: DesignSnapshot] = [:]
        for id in identifiers {
            guard let key = EntityKey.parseScreen(id) else { continue }
            if snapshots[key.design] == nil { snapshots[key.design] = await DesignActions.snapshot(design: key.design) }
            if let screen = snapshots[key.design]?.screens.first(where: { $0.id == id }) { found.append(screen) }
        }
        return found
    }

    /// The screens of the design at the front, then those of other recent designs.
    func suggestedEntities() async throws -> [ScreenEntity] {
        Array(await DesignActions.allSnapshots().prefix(5).flatMap(\.screens).prefix(40))
    }

    func entities(matching string: String) async throws -> [ScreenEntity] {
        let words = string.lowercased()
        return await DesignActions.allSnapshots().flatMap(\.screens).filter {
            $0.name.lowercased().contains(words) || $0.summary.lowercased().contains(words)
        }
    }
}

struct ElementQuery: EntityStringQuery {
    func entities(for identifiers: [ElementEntity.ID]) async throws -> [ElementEntity] {
        var found: [ElementEntity] = []
        var snapshots: [String: DesignSnapshot] = [:]
        for id in identifiers {
            guard let key = EntityKey.parseElement(id) else { continue }
            if snapshots[key.design] == nil { snapshots[key.design] = await DesignActions.snapshot(design: key.design) }
            if let element = snapshots[key.design]?.elements.first(where: { $0.id == id }) { found.append(element) }
        }
        return found
    }

    /// The selected element first, then the rest of the design at the front. A selected group
    /// isn't one element, and puts nothing first (F6).
    func suggestedEntities() async throws -> [ElementEntity] {
        await MainActor.run {
            guard let model = OpenDesigns.shared.current, let snapshot = DesignActions.snapshot(of: model) else { return [] }
            return DesignActions.suggested(snapshot.elements, in: model)
        }
    }

    /// Elements in the open designs whose words or names match.
    func entities(matching string: String) async throws -> [ElementEntity] {
        let words = string.lowercased()
        return await MainActor.run {
            OpenDesigns.shared.all.reversed().compactMap(DesignActions.snapshot(of:)).flatMap(\.elements).filter {
                $0.text.lowercased().contains(words) || $0.name.lowercased().contains(words) || $0.kind.name.lowercased() == words
            }
        }
    }
}

// MARK: Describing

/// Designs and screens in words, for Siri to read out and for Spotlight to index.
enum DesignDescriber {
    /// What a screen shows, top to bottom: its visible leaves by the tops of their frames in screen points, each as
    /// `describe(_:)` says it, or that it is empty. A leaf in a hidden container isn't visible.
    static func summary(of screen: TreeScreen, in content: TreeContent) -> String {
        summary(of: screen, on: content.device(of: screen))
    }

    /// `summary(of:in:)` for a screen drawn as `device`: what a screen's entity says, which has the design's settings
    /// but not the rest of it.
    static func summary(of screen: TreeScreen, on device: DeviceFrame) -> String {
        // The screen alone is indexed: its leaves' frames don't depend on anything else in the design.
        var alone = TreeContent()
        alone.screens = [screen]
        let index = TreeIndex(alone)
        let visible = screen.root.leaves
            .compactMap { leaf -> (leaf: LayerNode, top: CGFloat)? in
                guard let entry = index[leaf.id], !entry.isHiddenWithAncestors else { return nil }
                return (leaf, entry.hostShape.rect.minY)
            }
            .sorted { $0.top < $1.top }
        guard !visible.isEmpty else { return "An empty \(device.name) screen." }
        return visible.map { describe($0.leaf) }.joined(separator: ", ")
    }

    /// A leaf in a few words: its kind and its words, or a symbol's name.
    static func describe(_ node: LayerNode) -> String {
        describe(kind: node.kind, text: node.content.text, symbol: node.content.symbol)
    }

    /// The same for a flat element, which voice and Siri's actions still hand over until plan 6's Tasks 5 and 7.
    static func describe(_ element: DesignElement) -> String {
        describe(kind: element.kind, text: element.text, symbol: element.symbol)
    }

    private static func describe(kind: ElementKind, text: String, symbol: String?) -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = kind.layerName.lowercased()
        if kind == .symbol, let symbol { return "\(symbol) symbol" }
        return words.isEmpty ? name : "\(name) “\(words)”"
    }

    static func describe(_ snapshot: DesignSnapshot) -> String {
        let content = snapshot.content
        let screens = content.screens
        var lines = ["\(snapshot.name) has \(screens.count == 1 ? "1 screen" : "\(screens.count) screens")."]
        for screen in screens {
            let device = content.device(of: screen)
            lines.append("\(screen.name) (\(device.name)): \(summary(of: screen, on: device))")
        }
        let loose = content.canvasLeaves.count
        if loose > 0 { lines.append("Plus \(loose == 1 ? "1 element" : "\(loose) elements") on the open canvas.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: Layout as data

/// A design as JSON, with every position and size, for a model or a shortcut that edits a
/// design and needs to see exactly where things are. Screens give their canvas position and
/// scale; the leaves on them give frames in the screen's own points. Leaves on the open canvas
/// give frames in canvas points. Each leaf's `id` is the identifier its entity goes by. Read
/// from the tree: a leaf's frame is its host shape, the upright frame centred on what is seen,
/// and it is locked or hidden as it is with the containers above it.
enum DesignLayoutWriter {
    static func json(for snapshot: DesignSnapshot, ink: (count: Int, bounds: CGRect?)? = nil, hasUnreadSketch: Bool = false) -> String {
        let content = snapshot.content
        let index = TreeIndex(content)
        var root: [String: Any] = [
            "design": snapshot.name,
            "id": snapshot.id,
            "canvas": canvas(content.settings),
            "screens": content.screens.map { screen in
                let device = content.device(of: screen)
                return [
                    "id": EntityKey.screen(design: snapshot.id, screen: screen.id),
                    "name": screen.name,
                    "device": DeviceChoice(device).rawValue,
                    "width": number(device.size.width),
                    "height": number(device.size.height),
                    "x": number(screen.origin.x),
                    "y": number(screen.origin.y),
                    "scale": number(screen.scale * 100),
                    "locked": screen.isLocked == true,
                    "safeAreaTop": number(device.safeTop),
                    "safeAreaBottom": number(device.safeBottom),
                    "elements": screen.root.leaves.map { leaf(design: snapshot.id, host: .screen(screen.id), $0, in: index) },
                ] as [String: Any]
            },
            "canvasElements": content.canvasLeaves.map { leaf(design: snapshot.id, host: .canvas, $0, in: index) },
        ]
        if let ink {
            var drawing: [String: Any] = ["strokes": ink.count]
            if let bounds = ink.bounds { drawing["bounds"] = rect(bounds) }
            root["ink"] = drawing
        }
        if hasUnreadSketch { root["unreadMagicPenSketch"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A leaf's entry: its host shape's frame (screen points on a screen, canvas points on the canvas), and its lock and
    /// hide with the containers above it.
    private static func leaf(design: String, host: DesignStore.ElementRef.Host, _ node: LayerNode, in index: TreeIndex) -> [String: Any] {
        let entry = index[node.id]
        let frame = entry?.hostShape.rect ?? node.frame
        let traits = node.kind.spec.traits
        var info: [String: Any] = [
            "id": EntityKey.element(design: design, host: host, element: node.id),
            "kind": node.kind.rawValue,
            "name": node.displayName,
            "x": number(frame.minX),
            "y": number(frame.minY),
            "width": number(frame.width),
            "height": number(frame.height),
            "colour": node.resolvedTint.hex,
        ]
        let style = node.style, content = node.content
        if node.kind.hasText { info["text"] = content.text }
        if let symbol = content.symbol { info["symbol"] = symbol }
        if node.kind == .shape { info["shape"] = (content.shape ?? .rectangle).rawValue }
        if content.imageID != nil { info["hasPicture"] = true }
        if let fontSize = style.fontSize { info["fontSize"] = number(fontSize) }
        if let weight = style.fontWeight { info["fontWeight"] = weight.rawValue }
        if let textColor = style.textColor { info["textColour"] = textColor.hex }
        if let alignment = style.textAlignment { info["textAlignment"] = alignment.rawValue }
        if let radius = style.cornerRadius { info["cornerRadius"] = number(radius) }
        if let opacity = style.opacity { info["opacity"] = opacity }
        if let width = style.borderWidth, width > 0 {
            info["borderWidth"] = number(width)
            if let colour = style.borderColor { info["borderColour"] = colour.hex }
        }
        if style.hasShadow { info["shadow"] = true }
        if entry?.isLockedWithAncestors ?? node.isLocked { info["locked"] = true }
        if entry?.isHiddenWithAncestors ?? node.isHidden { info["hidden"] = true }
        if traits.contains(.onState) { info["on"] = content.isOn }
        if traits.contains(.value) { info["progress"] = content.value ?? 0.5 }
        if traits.contains(.buttonLooks) { info["buttonStyle"] = (content.buttonLook ?? .filled).rawValue }
        return info
    }

    private static func canvas(_ settings: CanvasSettings) -> [String: Any] {
        [
            "background": settings.resolvedBackground.hex,
            "showsGrid": settings.showsGrid,
            "gridStyle": settings.gridStyle.rawValue,
            "gridSpacing": number(settings.gridSpacing),
            "snapsToGuides": settings.snapsToGuides,
            "snapsToGrid": settings.snapsToGrid,
            "showsMeasurements": settings.showsMeasurements,
            "showsFrameNames": settings.showsFrameNames,
            "newScreenDevice": DeviceChoice(settings.sketchDevice).rawValue,
            // The option's value, which Update Canvas Settings takes, not the layout's own name.
            "codeLayout": CodeLayoutOption(settings.code.layout).rawValue,
            "codeIncludesPreview": settings.code.includesPreview,
            "codeUsesNavigationTitle": settings.code.usesNavigationTitle,
        ]
    }

    private static func rect(_ rect: CGRect) -> [String: Double] {
        ["x": number(rect.minX), "y": number(rect.minY), "width": number(rect.width), "height": number(rect.height)]
    }

    /// Rounded to a tenth of a point, which is all a layout needs.
    private static func number(_ value: CGFloat) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}
