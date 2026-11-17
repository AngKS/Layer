@_weakLinked import AppIntents
import CoreGraphics
import Foundation

/// A design's contents at one moment: live from its window when it is open, read from its
/// file when it isn't.
struct DesignSnapshot: Sendable {
    let id: String
    let name: String
    let content: DesignContent
    let modified: Date?

    var entity: DesignEntity {
        DesignEntity(id: id, content: content, fallbackName: name, modified: modified)
    }

    var screens: [ScreenEntity] {
        content.screens.map { ScreenEntity(design: id, designName: name, screen: $0) }
    }

    var elements: [ElementEntity] {
        content.screens.flatMap { screen in
            screen.elements.map { ElementEntity(design: id, host: .screen(screen.id), hostName: screen.name, element: $0) }
        } + content.floating.map { ElementEntity(design: id, host: .canvas, hostName: "Canvas", element: $0.element) }
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
        return DesignSnapshot(id: id, name: name, content: model.store.content, modified: .now)
    }

    static func snapshot(design id: String) async -> DesignSnapshot? {
        if let model = OpenDesigns.shared.model(forDesign: id) { return snapshot(of: model) }
        guard let summary = await DesignLibrary.summary(for: id) else { return nil }
        return DesignSnapshot(id: summary.id, name: summary.title, content: summary.content, modified: summary.modified)
    }

    /// Every design: the open ones as they are now, the rest as saved. Newest first.
    static func allSnapshots() async -> [DesignSnapshot] {
        let open = OpenDesigns.shared.all.compactMap(snapshot(of:))
        let openIDs = Set(open.map(\.id))
        let saved = await DesignLibrary.all()
            .filter { !openIDs.contains($0.id) }
            .map { DesignSnapshot(id: $0.id, name: $0.title, content: $0.content, modified: $0.modified) }
        return open.reversed() + saved
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

    /// The element named, or else the selected one.
    static func elementOrSelected(_ entity: ElementEntity?) async throws -> (model: AppModel, ref: DesignStore.ElementRef, element: DesignElement) {
        if let entity { return try await element(entity) }
        let model = try await model(for: nil as String?)
        guard let selected = model.selectedElement else { throw LayerIntentError.elementNotFound }
        return (model, selected.ref, selected.element)
    }

    static func entity(for ref: DesignStore.ElementRef, in model: AppModel) -> ElementEntity? {
        guard let id = model.designID, let found = model.store.resolve(ref) else { return nil }
        let hostName = switch ref.host {
        case .screen(let screenID): model.store.screen(screenID)?.name ?? "Screen"
        case .canvas: "Canvas"
        }
        return ElementEntity(design: id, host: ref.host, hostName: hostName, element: found.element)
    }

    static func entity(for screen: DesignScreen, in model: AppModel) -> ScreenEntity? {
        guard let snapshot = snapshot(of: model) else { return nil }
        return ScreenEntity(design: snapshot.id, designName: snapshot.name, screen: screen)
    }

    // MARK: Changing designs

    /// Makes a change to a design as one undo step, in the design's own undo history and,
    /// when the system offers one, in the action's undo manager too.
    static func edit<T>(_ model: AppModel, undoManager: UndoManager?, actionName: String, _ body: () throws -> T) rethrows -> T {
        let before = model.store.content
        model.store.beginEdit()
        defer {
            model.store.endEdit()
            let after = model.store.content
            if before != after, let undoManager, undoManager !== model.store.undoManager {
                undoManager.beginUndoGrouping()
                undoManager.registerUndo(withTarget: model.store) { store in
                    MainActor.assumeIsolated { store.restore(before) }
                }
                undoManager.setActionName(actionName)
                undoManager.endUndoGrouping()
            }
        }
        return try body()
    }

    /// Selects something and glides the canvas to show it.
    static func reveal(_ target: CanvasSelection, in model: AppModel) {
        model.tool = .select
        model.selection = target
        let area: CGRect? = switch target {
        case .element(let ref): model.store.resolve(ref).map { $0.placement.canvasRect(for: $0.element.frame) }
        case .screen(let id): model.store.screen(id).map { $0.canvasFrame.union($0.labelFrame) }
        }
        if let area { model.ink?.glide(toShow: area) }
    }

    /// Where a new screen goes: to the right of the others, at the newest screen's scale.
    static func placementForNewScreen(_ device: DeviceFrame, in model: AppModel) -> Placement {
        let scale = model.store.screens.last?.scale ?? 0.6
        if let rightmost = model.store.screens.max(by: { $0.canvasFrame.maxX < $1.canvasFrame.maxX }) {
            return Placement(origin: CGPoint(x: (rightmost.canvasFrame.maxX + 60).rounded(), y: rightmost.origin.y), scale: scale)
        }
        let middle = CGPoint(x: Viewport.canvasSize.width / 2, y: Viewport.canvasSize.height / 2)
        let size = CGSize(width: device.size.width * scale, height: device.size.height * scale)
        return Placement(origin: CGPoint(x: (middle.x - size.width / 2).rounded(), y: (middle.y - size.height / 2).rounded()), scale: scale)
    }

    /// Where a new element goes on a screen: centred, below everything already there,
    /// or at the top of the safe area on an empty screen.
    static func frameForNewElement(_ element: DesignElement, on screen: DesignScreen) -> CGRect {
        let device = screen.device
        let lowest = screen.elements.filter { !$0.isHidden }.map(\.frame.maxY).max()
        let top = (lowest.map { $0 + 16 } ?? device.safeTop + 16)
        var frame = ElementLayout.frame(for: element.kind, sketch: CGRect(x: device.size.width / 2, y: top, width: 0, height: 0), on: device)
        frame.origin.y = min(top, max(device.safeTop, device.size.height - device.safeBottom - frame.height - 8))
        if ElementLayout.keepsSketchedPosition(element.kind) {
            frame.origin.x = ((device.size.width - frame.width) / 2).rounded()
        }
        return frame
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

    /// The selected element first, then the rest of the design at the front.
    func suggestedEntities() async throws -> [ElementEntity] {
        await MainActor.run {
            guard let model = OpenDesigns.shared.current, let snapshot = DesignActions.snapshot(of: model) else { return [] }
            var elements = snapshot.elements
            if let selected = model.selectedElement, let entity = DesignActions.entity(for: selected.ref, in: model) {
                elements.removeAll { $0.id == entity.id }
                elements.insert(entity, at: 0)
            }
            return elements
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
    static func summary(of screen: DesignScreen) -> String {
        let visible = screen.elements.filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }
        guard !visible.isEmpty else { return "An empty \(screen.device.name) screen." }
        return visible.map(describe).joined(separator: ", ")
    }

    static func describe(_ element: DesignElement) -> String {
        let words = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = element.kind.layerName.lowercased()
        if element.kind == .symbol, let symbol = element.symbol { return "\(symbol) symbol" }
        return words.isEmpty ? kind : "\(kind) “\(words)”"
    }

    static func describe(_ snapshot: DesignSnapshot) -> String {
        let screens = snapshot.content.screens
        var lines = ["\(snapshot.name) has \(screens.count == 1 ? "1 screen" : "\(screens.count) screens")."]
        for screen in screens {
            lines.append("\(screen.name) (\(screen.device.name)): \(summary(of: screen))")
        }
        let loose = snapshot.content.floating.count
        if loose > 0 { lines.append("Plus \(loose == 1 ? "1 element" : "\(loose) elements") on the open canvas.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: Layout as data

/// A design as JSON, with every position and size, for a model or a shortcut that edits a
/// design and needs to see exactly where things are. Screens give their canvas position and
/// scale; their elements give frames in the screen's own points. Loose elements give frames
/// in canvas points. Each element's `id` is the identifier its entity goes by.
enum DesignLayoutWriter {
    static func json(for snapshot: DesignSnapshot, ink: (count: Int, bounds: CGRect?)? = nil, hasUnreadSketch: Bool = false) -> String {
        let content = snapshot.content
        var root: [String: Any] = [
            "design": snapshot.name,
            "id": snapshot.id,
            "canvas": canvas(content.canvas),
            "screens": content.screens.map { screen in
                [
                    "id": EntityKey.screen(design: snapshot.id, screen: screen.id),
                    "name": screen.name,
                    "device": DeviceChoice(screen.device).rawValue,
                    "width": number(screen.size.width),
                    "height": number(screen.size.height),
                    "x": number(screen.origin.x),
                    "y": number(screen.origin.y),
                    "scale": number(screen.scale * 100),
                    "locked": screen.isLocked == true,
                    "safeAreaTop": number(screen.device.safeTop),
                    "safeAreaBottom": number(screen.device.safeBottom),
                    "elements": screen.elements.map { element(design: snapshot.id, host: .screen(screen.id), $0, frame: $0.frame) },
                ] as [String: Any]
            },
            "canvasElements": content.floating.map { floating in
                element(design: snapshot.id, host: .canvas, floating.element, frame: floating.canvasFrame)
            },
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

    private static func element(design: String, host: DesignStore.ElementRef.Host, _ element: DesignElement, frame: CGRect) -> [String: Any] {
        var info: [String: Any] = [
            "id": EntityKey.element(design: design, host: host, element: element.id),
            "kind": element.kind.rawValue,
            "name": element.displayName,
            "x": number(frame.minX),
            "y": number(frame.minY),
            "width": number(frame.width),
            "height": number(frame.height),
            "colour": element.tint.hex,
        ]
        if element.kind.hasText { info["text"] = element.text }
        if let symbol = element.symbol { info["symbol"] = symbol }
        if element.imageID != nil { info["hasPicture"] = true }
        if let fontSize = element.fontSize { info["fontSize"] = number(fontSize) }
        if let weight = element.fontWeight { info["fontWeight"] = weight.rawValue }
        if let textColor = element.textColor { info["textColour"] = textColor.hex }
        if let alignment = element.textAlignment { info["textAlignment"] = alignment.rawValue }
        if let radius = element.cornerRadius { info["cornerRadius"] = number(radius) }
        if let opacity = element.opacity { info["opacity"] = opacity }
        if let width = element.borderWidth, width > 0 {
            info["borderWidth"] = number(width)
            if let colour = element.borderColor { info["borderColour"] = colour.hex }
        }
        if element.hasShadow { info["shadow"] = true }
        if element.isLocked { info["locked"] = true }
        if element.isHidden { info["hidden"] = true }
        if element.hasOnState { info["on"] = element.isOn }
        if element.hasValue { info["progress"] = element.value ?? 0.5 }
        if element.hasButtonLooks { info["buttonStyle"] = (element.buttonLook ?? .filled).rawValue }
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
            "codeLayout": settings.code.layout.rawValue,
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
