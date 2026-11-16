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

    @ObservationIgnored var undoManager: UndoManager?
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
        addScreen(.iPhone, at: ElementLayout.screenPlacement(for: sketch))
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
    @discardableResult
    func addElement(_ kind: ElementKind, from sketch: CGRect, to screenID: DesignScreen.ID) -> DesignElement? {
        guard let index = screens.firstIndex(where: { $0.id == screenID }) else { return nil }
        let local = screens[index].localRect(for: sketch)
        let element = DesignElement(
            kind: kind,
            frame: ElementLayout.frame(for: kind, sketch: local, on: screens[index].device),
            text: kind.placeholder,
            tint: Theme.accent
        )
        change { $0.screens[index].elements.append(element) }
        return element
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
    static func newElement(_ kind: ElementKind, symbol: String? = nil) -> DesignElement {
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
    }

    func deleteScreen(_ id: DesignScreen.ID) {
        change { $0.screens.removeAll { $0.id == id } }
    }

    /// Copies an element beside the original, in the same place it lives. Returns the copy.
    @discardableResult
    func duplicate(_ ref: ElementRef) -> ElementRef? {
        guard let found = resolve(ref) else { return nil }
        var copy = found.element
        copy.id = UUID()
        copy.isLocked = nil
        copy.frame = copy.frame.offsetBy(dx: 20, dy: 20)
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

    /// Copies a screen and everything on it, to the right of the original. Returns the copy.
    @discardableResult
    func duplicateScreen(_ id: DesignScreen.ID) -> DesignScreen.ID? {
        guard let original = screen(id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.isLocked = nil
        copy.name = "\(original.name) Copy"
        copy.origin.x += original.canvasFrame.width + 60
        copy.elements = original.elements.map { element in
            var element = element
            element.id = UUID()
            return element
        }
        change { $0.screens.append(copy) }
        return copy.id
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
