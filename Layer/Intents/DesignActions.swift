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

    /// A screen by its entity, as the tree holds it, with the design it is in.
    static func screen(_ entity: ScreenEntity) async throws -> (model: AppModel, screen: TreeScreen) {
        guard let id = entity.screenID else { throw LayerIntentError.screenNotFound }
        let model = try await model(for: entity.designID)
        guard let screen = model.store.treeScreen(id) else { throw LayerIntentError.screenNotFound }
        return (model, screen)
    }

    /// Throws `locked` when an element is locked, by itself or by a group above it: Siri
    /// doesn't move, align or delete it, as a finger can't (F4).
    static func requireUnlocked(_ ref: DesignStore.ElementRef, in model: AppModel) throws {
        guard !model.store.isLocked(.element(ref)) else { throw LayerIntentError.locked }
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
        let selected = try selected(in: model)
        return (model, selected.ref, selected.node)
    }

    /// Siri's "this element" in a design: the one leaf selected (`selectedLeaf(in:)`). Throws `elementNotFound` when no
    /// one leaf is selected: nothing, several things, or a container.
    static func selected(in model: AppModel) throws -> PlacedNode {
        guard let selected = selectedLeaf(in: model) else { throw LayerIntentError.elementNotFound }
        return selected
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
    static func screenOrCurrent(_ entity: ScreenEntity?) async throws -> (model: AppModel, screen: TreeScreen) {
        if let entity { return try await screen(entity) }
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

    /// Makes a change to a design as one undo step, named `actionName`, in the design's own undo history and, when the
    /// system offers one, in the action's undo manager too.
    static func edit<T>(_ model: AppModel, undoManager: UndoManager?, actionName: String, _ body: () throws -> T) rethrows -> T {
        let before = model.store.content
        // Its own step, even in the middle of a drag, which goes on as its own (M3).
        let edit = model.store.beginEdit(by: .app)
        // "Undo Move Text" in the Edit menu, as the system's history calls it.
        model.store.name(edit, actionName)
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
    ///
    /// Each screen takes up its frame on the canvas drawn as its own device, the design's own included.
    static func placementForNewScreen(_ device: DeviceFrame, in model: AppModel, near point: CGPoint? = nil) -> Placement {
        let tree = model.store.tree
        let screens = tree.screens
        let scale = screens.last?.scale ?? 0.6
        func frame(of screen: TreeScreen) -> CGRect { screen.canvasFrame(on: tree.device(of: screen)) }
        if let point {
            // The screen with its name above it, which is what mustn't lie over another.
            let nameHeight = 34 * scale
            let top = point.y.rounded()
            var taken = CGRect(
                x: point.x.rounded(), y: top - nameHeight,
                width: device.size.width * scale, height: device.size.height * scale + nameHeight
            )
            let covered = screens.map { frame(of: $0).union($0.labelFrame(on: tree.device(of: $0))) }
            // Each move clears one screen and only goes rightwards, so this ends.
            while let blocking = covered.first(where: { $0.intersects(taken) }) {
                taken.origin.x = (blocking.maxX + 60).rounded()
            }
            return Placement(origin: CGPoint(x: taken.minX, y: top), scale: scale)
        }
        if let rightmost = screens.max(by: { frame(of: $0).maxX < frame(of: $1).maxX }) {
            return Placement(origin: CGPoint(x: (frame(of: rightmost).maxX + 60).rounded(), y: rightmost.origin.y), scale: scale)
        }
        let middle = CGPoint(x: Viewport.canvasSize.width / 2, y: Viewport.canvasSize.height / 2)
        let size = CGSize(width: device.size.width * scale, height: device.size.height * scale)
        return Placement(origin: CGPoint(x: (middle.x - size.width / 2).rounded(), y: (middle.y - size.height / 2).rounded()), scale: scale)
    }

    /// Where a new element goes on a screen: `ElementLayout.newElementFrame` below its visible elements. Siri no longer
    /// calls it: it is kept only for voice's `VoiceToolbox` (lane C), whose plan 6 Task 7 moves it to
    /// `DesignStore.newElementFrame(_:on:)`; the last lane to move deletes it (F11, F16).
    static func frameForNewElement(_ element: DesignElement, on screen: DesignScreen) -> CGRect {
        ElementLayout.newElementFrame(for: element.kind, on: screen.device, below: screen.elements.filter { !$0.isHidden }.map(\.frame))
    }

    // MARK: Devices

    /// The device an action asks for (call 6): `custom`, one of the design's own by its name ignoring case and the space
    /// round it (`CanvasSettings.customDevice(named:)`), when it is given and isn't blank; else `choice`'s frame; nil when
    /// neither is given. Throws `deviceNotFound` for a name the design has no device of its own called, and for one of
    /// its own that can't be used (`problems`), which a file can hold and the store refuses everywhere: so Change Screen
    /// Device, Add Screen, Build Screen and Update Canvas Settings refuse it before anything is written.
    static func device(_ choice: DeviceChoice?, custom: String?, in model: AppModel) throws -> DeviceFrame? {
        let name = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return choice?.frame }
        guard let device = model.store.tree.settings.customDevice(named: name), device.problems.isEmpty else {
            throw LayerIntentError.deviceNotFound(name)
        }
        return device
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

    /// The same for a flat element, which voice still hands over until plan 6's Task 7; Siri's actions no longer do. The
    /// last lane to move deletes it.
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
