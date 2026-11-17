import CoreGraphics
import Foundation
import Observation

/// The design on the canvas. Every change goes through here and is registered with the
/// document's undo manager, which is also what tells the system that the document needs
/// saving.
@MainActor @Observable
final class DesignStore {
    /// Points at one element: where it lives, and which one it is there.
    struct ElementRef: Hashable, Sendable {
        enum Host: Hashable, Sendable {
            case screen(DesignScreen.ID)
            /// The open canvas, outside every screen.
            case canvas
        }

        var host: Host
        var element: DesignElement.ID
    }

    private(set) var content: DesignContent {
        didSet {
            if content != oldValue { onChange?(content) }
        }
    }

    /// The document's undo manager, shared with PencilKit's ink. Its history is capped, so a
    /// long sitting doesn't keep every earlier version of the design alive.
    @ObservationIgnored var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = Self.undoLevels }
    }
    static let undoLevels = 50
    /// Called with the new content after every change, including undo and redo.
    @ObservationIgnored var onChange: ((DesignContent) -> Void)?
    /// The content as it was when the gradual edit in progress began.
    @ObservationIgnored private var editStart: DesignContent?

    init(content: DesignContent = DesignContent()) {
        self.content = content
    }

    var screens: [DesignScreen] { content.screens }
    var floating: [FloatingElement] { content.floating }
    var title: String? { content.title }
    var canvas: CanvasSettings { content.canvas }

    // MARK: Looking things up

    func screen(_ id: DesignScreen.ID) -> DesignScreen? {
        screens.first { $0.id == id }
    }

    /// The topmost screen covering a point on the canvas.
    func screen(at point: CGPoint) -> DesignScreen? {
        screens.last { $0.canvasFrame.contains(point) }
    }

    /// The screen a sketch was drawn on, judged by where the sketch's centre falls.
    func screen(under sketch: CGRect) -> DesignScreen? {
        screen(at: CGPoint(x: sketch.midX, y: sketch.midY))
    }

    /// An element together with the placement that turns its frame into canvas points.
    func resolve(_ ref: ElementRef) -> (element: DesignElement, placement: Placement)? {
        switch ref.host {
        case .screen(let id):
            guard let screen = screen(id), let element = screen.elements.first(where: { $0.id == ref.element }) else { return nil }
            return (element, screen.placement)
        case .canvas:
            guard let floating = floating.first(where: { $0.id == ref.element }) else { return nil }
            return (floating.element, floating.placement)
        }
    }

    /// The area everything in the design covers, or nil for an empty design.
    var contentBounds: CGRect? {
        let rects = screens.map { $0.canvasFrame.union($0.labelFrame) } + floating.map(\.canvasFrame)
        return rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }

    /// The scale loose elements are drawn at: that of the newest screen, so they match it.
    var looseScale: CGFloat { screens.last?.scale ?? 0.66 }

    // MARK: Changes made in one step

    /// Adds the screen a sketch stands for: an iPhone, as large as it was drawn.
    @discardableResult
    func addScreen(from sketch: CGRect) -> DesignScreen {
        let device = canvas.sketchDevice
        return addScreen(device, at: ElementLayout.screenPlacement(for: sketch, device: device))
    }

    @discardableResult
    func addScreen(_ device: DeviceFrame, at placement: Placement) -> DesignScreen {
        let screen = DesignScreen(
            name: "Screen \(screens.count + 1)", origin: placement.origin, scale: placement.scale,
            deviceID: device == .iPhone ? nil : device.id
        )
        change { $0.screens.append(screen) }
        return screen
    }

    /// Adds an element where it was sketched. Returns nil if the screen no longer exists.
    /// `adjust` finishes the element before it is added, in the same undoable step.
    @discardableResult
    func addElement(_ kind: ElementKind, from sketch: CGRect, to screenID: DesignScreen.ID, adjust: (inout DesignElement) -> Void = { _ in }) -> DesignElement? {
        guard let index = screens.firstIndex(where: { $0.id == screenID }) else { return nil }
        let local = screens[index].localRect(for: sketch)
        let existing = screens[index].elements.filter { !$0.isHidden }
        let laid = ElementLayout.sketched(kind, sketch: local, on: screens[index].device, among: existing.map(\.frame))
        var element = DesignElement(kind: kind, frame: laid.frame, text: kind.placeholder, tint: Theme.accent)
        element.textAlignment = laid.alignment
        // A screen's first button is its main action; any more are outlined beside or below it.
        if kind == .button, existing.contains(where: { $0.kind == .button && $0.resolvedButtonLook == .filled }) {
            element.buttonLook = .bordered
            element.text = "Cancel"
        }
        adjust(&element)
        change { $0.screens[index].elements.append(element) }
        return element
    }

    /// Adds an element sketched on the open canvas, where and about as large as it was drawn.
    @discardableResult
    func addFloating(_ kind: ElementKind, from sketch: CGRect) -> ElementRef {
        var element = Self.newElement(kind)
        let scale = looseScale
        let drawn = CGSize(width: sketch.width / scale, height: sketch.height / scale)
        switch kind {
        case .stickyNote:
            let side = min(max(max(drawn.width, drawn.height), 100), 320).rounded()
            element.frame.size = CGSize(width: side, height: side)
        case .text:
            element.frame.size.width = min(max(drawn.width, 80), 600).rounded()
        default:
            break
        }
        return place(element, centeredAt: CGPoint(x: sketch.midX, y: sketch.midY))
    }

    /// The elements a scratch-out drawn over `sketch`, in canvas points, crosses out:
    /// those, not locked or hidden, whose middle it covers.
    func elements(scratchedOutBy sketch: CGRect) -> [ElementRef] {
        let area = sketch.insetBy(dx: -6, dy: -6)
        func isCrossedOut(_ element: DesignElement, _ placement: Placement) -> Bool {
            guard !element.isLocked, !element.isHidden else { return false }
            let frame = placement.canvasRect(for: element.frame)
            return area.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        var found: [ElementRef] = []
        for screen in screens {
            for element in screen.elements where isCrossedOut(element, screen.placement) {
                found.append(ElementRef(host: .screen(screen.id), element: element.id))
            }
        }
        for floating in floating where isCrossedOut(floating.element, floating.placement) {
            found.append(ElementRef(host: .canvas, element: floating.id))
        }
        return found
    }

    /// Deletes several elements as one undo step.
    func delete(_ refs: [ElementRef]) {
        let ids = Set(refs.map(\.element))
        change { content in
            for index in content.screens.indices {
                content.screens[index].elements.removeAll { ids.contains($0.id) }
            }
            content.floating.removeAll { ids.contains($0.id) }
        }
        // Stage 0 instrumentation: a no-op unless one of these was a Magic Pen reading
        // deleted soon after it was made. See SketchReadingLog.
        for id in ids { Task { await SketchReadingLog.shared.noteDeleted(id) } }
    }
    /// Puts a ready-made element on the canvas, centred on a point: onto the screen
    /// there, if it is the kind of thing that goes on screens, and onto the open canvas
    /// otherwise. Only the size of `element.frame` is used.
    @discardableResult
    func place(_ element: DesignElement, centeredAt point: CGPoint) -> ElementRef {
        var element = element
        let size = element.frame.size

        func centered(in placement: Placement) -> CGPoint {
            let center = placement.localPoint(for: point)
            return CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
        }

        if element.kind.belongsOnScreens, let index = screens.lastIndex(where: { $0.canvasFrame.contains(point) }) {
            element.frame.origin = centered(in: screens[index].placement)
            change { $0.screens[index].elements.append(element) }
            return ElementRef(host: .screen(screens[index].id), element: element.id)
        }
        let scale = looseScale
        element.frame.origin = centered(in: Placement(origin: .zero, scale: scale))
        change { $0.floating.append(FloatingElement(element: element, scale: scale)) }
        return ElementRef(host: .canvas, element: element.id)
    }

    /// A new element of a kind, at its starting size and look, ready to be placed.
    nonisolated static func newElement(_ kind: ElementKind, symbol: String? = nil) -> DesignElement {
        let tint: RGBColor = switch kind {
        case .stickyNote: Theme.stickyNote
        case .symbol: Theme.inkTint
        default: Theme.accent
        }
        return DesignElement(
            kind: kind,
            frame: CGRect(origin: .zero, size: ElementLayout.size(for: kind, sketch: .zero)),
            text: kind.placeholder, tint: tint, symbol: symbol
        )
    }

    func delete(_ ref: ElementRef) {
        switch ref.host {
        case .screen(let id):
            guard let screen = screens.firstIndex(where: { $0.id == id }) else { return }
            change { $0.screens[screen].elements.removeAll { $0.id == ref.element } }
        case .canvas:
            change { $0.floating.removeAll { $0.id == ref.element } }
        }
        // See the matching note on delete(_ refs:).
        Task { await SketchReadingLog.shared.noteDeleted(ref.element) }
    }

    /// A copy of an element beside the original, a little down and to the right, on top.
    @discardableResult
    func duplicate(_ ref: ElementRef) -> ElementRef? {
        guard let (element, _) = resolve(ref) else { return nil }
        var copy = element
        copy.id = UUID()
        copy.isLocked = false
        copy.frame = element.frame.offsetBy(dx: 16, dy: 16)
        switch ref.host {
        case .screen(let id):
            guard let index = screens.firstIndex(where: { $0.id == id }) else { return nil }
            change { $0.screens[index].elements.append(copy) }
        case .canvas:
            guard let original = floating.first(where: { $0.id == ref.element }) else { return nil }
            change { $0.floating.append(FloatingElement(element: copy, scale: original.scale)) }
        }
        return ElementRef(host: ref.host, element: copy.id)
    }

    /// A copy of a screen and everything on it, to its right.
    @discardableResult
    func duplicateScreen(_ id: DesignScreen.ID) -> DesignScreen? {
        guard let screen = screen(id) else { return nil }
        var copy = screen
        copy.id = UUID()
        copy.name = Self.copyName(for: screen.name, among: screens.map(\.name))
        copy.isLocked = nil
        copy.origin.x = screen.canvasFrame.maxX + 60
        copy.elements = screen.elements.map { element in
            var element = element
            element.id = UUID()
            return element
        }
        change { $0.screens.append(copy) }
        return copy
    }

    /// "Screen 1" becomes "Screen 1 Copy", then "Screen 1 Copy 2" and so on.
    static func copyName(for name: String, among names: [String]) -> String {
        let base = "\(name) Copy"
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    enum Arrangement: CaseIterable, Sendable {
        case front, forward, backward, back

        var name: String {
            switch self {
            case .front: "Bring to Front"
            case .forward: "Bring Forward"
            case .backward: "Send Backward"
            case .back: "Send to Back"
            }
        }

        var symbol: String {
            switch self {
            case .front: "square.3.layers.3d.top.filled"
            case .forward: "square.2.layers.3d.top.filled"
            case .backward: "square.2.layers.3d.bottom.filled"
            case .back: "square.3.layers.3d.bottom.filled"
            }
        }
    }

    /// Moves an element up or down among those it shares its screen, or the open canvas, with.
    func arrange(_ ref: ElementRef, _ arrangement: Arrangement) {
        func reordered<T>(_ items: inout [T], id: (T) -> UUID) {
            guard let index = items.firstIndex(where: { id($0) == ref.element }) else { return }
            let target = switch arrangement {
            case .front: items.count - 1
            case .forward: min(index + 1, items.count - 1)
            case .backward: max(index - 1, 0)
            case .back: 0
            }
            guard target != index else { return }
            let item = items.remove(at: index)
            items.insert(item, at: target)
        }
        switch ref.host {
        case .screen(let id):
            guard let index = screens.firstIndex(where: { $0.id == id }) else { return }
            change { reordered(&$0.screens[index].elements, id: \.id) }
        case .canvas:
            change { reordered(&$0.floating, id: \.id) }
        }
    }

    /// Whether an element can go further up, or further down, among its neighbours.
    func canArrange(_ ref: ElementRef, _ arrangement: Arrangement) -> Bool {
        let ids: [UUID] = switch ref.host {
        case .screen(let id): screen(id)?.elements.map(\.id) ?? []
        case .canvas: floating.map(\.id)
        }
        guard let index = ids.firstIndex(of: ref.element) else { return false }
        return arrangement == .front || arrangement == .forward ? index < ids.count - 1 : index > 0
    }

    /// Lines an element on a screen up with an edge or the middle of that screen.
    func align(_ ref: ElementRef, _ alignment: ElementLayout.Alignment) {
        guard case .screen(let id) = ref.host, let screen = screen(id) else { return }
        update(ref) { $0.frame = ElementLayout.aligned($0.frame, alignment, in: screen.size) }
    }

    func deleteScreen(_ id: DesignScreen.ID) {
        change { $0.screens.removeAll { $0.id == id } }
    }

    /// Names the board. A name the app suggests itself isn't something to undo.
    func setTitle(_ title: String?, undoable: Bool = true) {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned?.isEmpty == false ? cleaned : nil
        if undoable {
            change { $0.title = value }
        } else {
            content.title = value
        }
    }

    func updateCanvas(_ body: (inout CanvasSettings) -> Void) {
        change { body(&$0.canvas) }
    }

    /// Puts the whole design back as it was, as one undo step. Siri's own undo of an action
    /// it took uses this.
    func restore(_ previous: DesignContent) {
        change { $0 = previous }
    }

    /// Adds ready-made elements to a screen as one change, replacing what is there when
    /// `replacing` is set. Returns where they now live.
    @discardableResult
    func setElements(_ elements: [DesignElement], on screenID: DesignScreen.ID, replacing: Bool) -> [ElementRef] {
        guard let index = screens.firstIndex(where: { $0.id == screenID }) else { return [] }
        change { content in
            if replacing { content.screens[index].elements = elements } else { content.screens[index].elements += elements }
        }
        return elements.map { ElementRef(host: .screen(screenID), element: $0.id) }
    }

    /// Gives an element to whatever it now lies on: the screen under its centre, or the
    /// open canvas when there is none. It keeps its size in points and its position on
    /// the canvas. Returns where the element now lives.
    @discardableResult
    func rehost(_ ref: ElementRef) -> ElementRef {
        guard let (element, placement) = resolve(ref) else { return ref }
        let frame = placement.canvasRect(for: element.frame)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let target = element.kind.belongsOnScreens ? screen(at: center) : nil
        let host: ElementRef.Host = target.map { .screen($0.id) } ?? .canvas
        guard host != ref.host else { return ref }

        // Off a screen it keeps the scale it was drawn at, so it doesn't change size.
        let newPlacement = target?.placement ?? Placement(origin: .zero, scale: placement.scale)
        let newCenter = newPlacement.localPoint(for: center)
        var moved = element
        moved.frame.origin = CGPoint(
            x: (newCenter.x - element.frame.width / 2).rounded(),
            y: (newCenter.y - element.frame.height / 2).rounded()
        )

        change { content in
            switch ref.host {
            case .screen(let id):
                if let index = content.screens.firstIndex(where: { $0.id == id }) {
                    content.screens[index].elements.removeAll { $0.id == element.id }
                }
            case .canvas:
                content.floating.removeAll { $0.id == element.id }
            }
            if let target, let index = content.screens.firstIndex(where: { $0.id == target.id }) {
                content.screens[index].elements.append(moved)
            } else {
                content.floating.append(FloatingElement(element: moved, scale: newPlacement.scale))
            }
        }
        return ElementRef(host: host, element: element.id)
    }

    // MARK: Changes made gradually

    /// Starts a change made in many small steps, such as a drag or typing. Everything
    /// until `endEdit()` undoes as one step.
    func beginEdit() {
        if editStart == nil { editStart = content }
    }

    func endEdit() {
        guard let start = editStart else { return }
        editStart = nil
        if start != content { registerUndo(restoring: start) }
    }

    func update(_ ref: ElementRef, _ body: (inout DesignElement) -> Void) {
        switch ref.host {
        case .screen(let id):
            guard let screen = screens.firstIndex(where: { $0.id == id }),
                  let element = screens[screen].elements.firstIndex(where: { $0.id == ref.element })
            else { return }
            change { body(&$0.screens[screen].elements[element]) }
        case .canvas:
            guard let index = floating.firstIndex(where: { $0.id == ref.element }) else { return }
            change { body(&$0.floating[index].element) }
        }
    }

    func updateScreen(_ id: DesignScreen.ID, _ body: (inout DesignScreen) -> Void) {
        guard let index = screens.firstIndex(where: { $0.id == id }) else { return }
        change { body(&$0.screens[index]) }
    }

    // MARK: Undo

    /// Applies a change. Inside `beginEdit()`…`endEdit()` it joins that edit's undo step;
    /// on its own it is its own undo step.
    private func change(_ body: (inout DesignContent) -> Void) {
        guard editStart == nil else {
            body(&content)
            return
        }
        let before = content
        body(&content)
        if before != content { registerUndo(restoring: before) }
    }

    private func registerUndo(restoring previous: DesignContent) {
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { store in
            let current = store.content
            store.content = previous
            // Registering while undoing makes this the redo step, and the reverse.
            store.registerUndo(restoring: current)
        }
        undoManager.endUndoGrouping()
    }
}
