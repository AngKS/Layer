import CoreGraphics
import Foundation
import Observation

/// The design on the canvas. Every change goes through here and is registered with the
/// document's undo manager, which is also what tells the system that the document needs
/// saving.
///
/// The design keeps its elements in one list (`DesignContent.elements`). `screens` and
/// `floating` are views of that list, worked out once per change.
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
            guard content != oldValue else { return }
            views = nil
            changeCount += 1
            // A change made through `change(_:)` is told once it has been recorded: see there.
            if !isChanging { onChange?(content) }
        }
    }

    /// True while `change(_:)` makes a change, before it is recorded.
    @ObservationIgnored private var isChanging = false

    /// Counts the changes made to the content, by anyone, so that a step can tell whether
    /// the change before its own was its own too.
    @ObservationIgnored private var changeCount = 0

    /// The document's undo manager. Ink is in its history too, as changes to the design's
    /// drawings: PencilKit keeps none of its own here. Its history is capped, so a
    /// long sitting doesn't keep every earlier version of the design alive.
    @ObservationIgnored var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = Self.undoLevels }
    }
    static let undoLevels = 50
    /// Called with the new content after every change, including undo and redo.
    @ObservationIgnored var onChange: ((DesignContent) -> Void)?
    /// Moves on whenever the history does: a step made, undone, redone or taken out. A
    /// spoken correction checks it to be sure the step on top is still its command's.
    @ObservationIgnored private(set) var historyMark = 0

    /// The views of the list, and where each element is in it, for the content as it is now.
    private struct Views {
        var screens: [DesignScreen]
        var floating: [FloatingElement]
        var index: [DesignElement.ID: Int]
    }
    @ObservationIgnored private var views: Views?

    init(content: DesignContent = DesignContent()) {
        self.content = content
    }

    private var current: Views {
        // Read first, so that whatever draws from a view is redrawn when the content changes.
        let content = content
        if let views { return views }
        let made = Views(
            screens: content.screens, floating: content.floating,
            index: Dictionary(content.elements.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
        views = made
        return made
    }

    /// Each screen with what is on it.
    var screens: [DesignScreen] { current.screens }
    /// The elements on the open canvas.
    var floating: [FloatingElement] { current.floating }
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

    /// An element, wherever it is.
    func element(_ id: DesignElement.ID) -> DesignElement? {
        current.index[id].map { content.elements[$0] }
    }

    /// An element together with the placement that turns its frame into canvas points.
    /// Nil when the element is gone, or no longer where `ref` says it is.
    func resolve(_ ref: ElementRef) -> (element: DesignElement, placement: Placement)? {
        guard let element = element(ref.element) else { return nil }
        switch ref.host {
        case .screen(let id):
            guard element.parent == id, let screen = screen(id) else { return nil }
            return (element, screen.placement)
        case .canvas:
            guard element.parent == nil else { return nil }
            return (element, Placement(origin: .zero, scale: element.scale ?? 1))
        }
    }

    /// The area everything in the design covers, or nil for an empty design. A turned loose
    /// element covers the box round its turned shape.
    var contentBounds: CGRect? {
        let rects = screens.map { $0.canvasFrame.union($0.labelFrame) } + floating.map { $0.placement.canvasRect(for: $0.element.shapeBounds) }
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
        change { $0.addScreen(screen) }
        return screen
    }

    /// Adds an element where it was sketched. Returns nil if the screen no longer exists.
    /// `adjust` finishes the element before it is added, in the same undoable step.
    @discardableResult
    func addElement(_ kind: ElementKind, from sketch: CGRect, to screenID: DesignScreen.ID, adjust: (inout DesignElement) -> Void = { _ in }) -> DesignElement? {
        guard let screen = screen(screenID) else { return nil }
        var element = Self.sketchedElement(kind, from: sketch, on: screen, among: screen.elements)
        adjust(&element)
        return add(element, to: screenID)
    }

    /// The element a sketch drawn on a screen stands for, laid out among `others` there.
    private static func sketchedElement(_ kind: ElementKind, from sketch: CGRect, on screen: DesignScreen, among others: [DesignElement]) -> DesignElement {
        let existing = others.filter { !$0.isHidden }
        let laid = ElementLayout.sketched(kind, sketch: screen.localRect(for: sketch), on: screen.device, among: existing.map(\.frame))
        var element = DesignElement(kind: kind, frame: laid.frame, text: kind.placeholder, tint: Theme.accent)
        element.textAlignment = laid.alignment
        // A screen's first button is its main action; any more are outlined beside or below it.
        if kind == .button, existing.contains(where: { $0.kind == .button && $0.resolvedButtonLook == .filled }) {
            element.buttonLook = .bordered
            element.text = "Cancel"
        }
        return element
    }

    /// Makes an element on a screen another kind of thing, as when its sketch was read as
    /// the wrong one. It is laid out afresh from where it was sketched, as if it had been
    /// read that way to begin with, and stays the same element: its place among the
    /// others, its name, and any words written for it are kept. `adjust` finishes it in
    /// the same undoable step. Returns the element as it now is, or nil when it is gone
    /// or isn't on a screen.
    @discardableResult
    func changeKind(of ref: ElementRef, to kind: ElementKind, sketchedAt sketch: CGRect, adjust: (inout DesignElement) -> Void = { _ in }) -> DesignElement? {
        guard case .screen(let screenID) = ref.host, let old = resolve(ref)?.element, let screen = screen(screenID) else { return nil }
        var element = Self.sketchedElement(kind, from: sketch, on: screen, among: screen.elements.filter { $0.id != old.id })
        element.name = old.name
        element.isLocked = old.isLocked
        if kind.hasText, old.kind.hasText, old.text != old.kind.placeholder { element.text = old.text }
        adjust(&element)
        // Everything about it but what it is and where it lives is replaced.
        let replacement = element
        change { content in
            content.update(old.id) { $0 = replacement }
        }
        return self.element(old.id)
    }

    /// Adds an element sketched on the open canvas, where and about as large as it was drawn.
    @discardableResult
    func addFloating(_ kind: ElementKind, from sketch: CGRect) -> ElementRef {
        var element = Self.newElement(kind)
        let scale = looseScale
        let drawn = CGSize(width: sketch.width / scale, height: sketch.height / scale)
        element.frame.size = kind.spec.looseSize.size(from: element.frame.size, drawn: drawn)
        return place(element, centeredAt: CGPoint(x: sketch.midX, y: sketch.midY))
    }

    /// Deletes several elements as one undo step.
    func delete(_ refs: [ElementRef]) {
        let ids = Set(refs.map(\.element))
        change { $0.remove(ids) }
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

        if element.kind.belongsOnScreens, let screen = screens.last(where: { $0.canvasFrame.contains(point) }) {
            element.frame.origin = centered(in: screen.placement)
            add(element, to: screen.id)
            return ElementRef(host: .screen(screen.id), element: element.id)
        }
        let scale = looseScale
        element.frame.origin = centered(in: Placement(origin: .zero, scale: scale))
        add(element, to: nil, scale: scale)
        return ElementRef(host: .canvas, element: element.id)
    }

    /// A new element of a kind, at its starting size and look, ready to be placed.
    nonisolated static func newElement(_ kind: ElementKind, symbol: String? = nil) -> DesignElement {
        DesignElement(
            kind: kind,
            frame: CGRect(origin: .zero, size: ElementLayout.size(for: kind, sketch: .zero)),
            text: kind.placeholder, tint: kind.spec.tint, symbol: symbol
        )
    }

    func delete(_ ref: ElementRef) {
        guard resolve(ref) != nil else { return }
        change { $0.remove([ref.element]) }
        // See the matching note on delete(_ refs:).
        Task { await SketchReadingLog.shared.noteDeleted(ref.element) }
    }

    /// A copy of an element beside the original, a little down and to the right, on top.
    @discardableResult
    func duplicate(_ ref: ElementRef) -> ElementRef? {
        guard let (element, _) = resolve(ref) else { return nil }
        // A drawing's copy is made of strokes of its own.
        var copy = element.withStrokesOfItsOwn()
        copy.id = UUID()
        copy.isLocked = false
        copy.frame = element.frame.offsetBy(dx: 16, dy: 16)
        add(copy, to: element.parent, scale: element.scale)
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
            element.parent = copy.id
            return element
        }
        change { $0.addScreen(copy) }
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

    /// Moves an element up or down among its siblings: see `arrange(_ selection:_:)`, and
    /// `SiblingLists` for what its siblings are. Siri's Change Element Order comes this way.
    func arrange(_ ref: ElementRef, _ arrangement: Arrangement) {
        arrange(.element(ref), arrangement)
    }

    /// Whether an element can go further up, or further down, among its neighbours.
    func canArrange(_ ref: ElementRef, _ arrangement: Arrangement) -> Bool {
        canArrange(.element(ref), arrangement)
    }

    /// Lines an element on a screen up with an edge or the middle of that screen.
    func align(_ ref: ElementRef, _ alignment: ElementLayout.Alignment) {
        guard case .screen(let id) = ref.host, let screen = screen(id) else { return }
        // A turned element lines up by the box round its shape; its frame moves with it.
        update(ref) {
            let box = $0.shapeBounds
            let aligned = ElementLayout.aligned(box, alignment, in: screen.size)
            $0.frame.origin.x += aligned.minX - box.minX
            $0.frame.origin.y += aligned.minY - box.minY
        }
    }

    func deleteScreen(_ id: DesignScreen.ID) {
        change { $0.removeScreen(id) }
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

    /// Names the board `numbered`: `title` with the number its file needed, another design
    /// having that name. The number is part of the naming, so it goes in the step that
    /// named the board `title`, when a step did: undoing that takes the number away too,
    /// as the name can't go back while it isn't the one the step gave (M4). So does the
    /// step redo would take, when undo put the name back: redoing it brings back the name
    /// given after (review m1). A name with no step, one the app suggested, is numbered
    /// without one.
    func numberTitle(_ numbered: String, for title: String) {
        guard content.title == title, numbered != title else { return }
        let before = content
        isChanging = true
        content.title = numbered
        isChanging = false
        for steps in [undoable, redoable] {
            steps.last { $0.step?.lastNamed == title }?.step?.record(from: before, to: content, change: changeCount)
        }
        onChange?(content)
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
        guard screen(screenID) != nil else { return [] }
        change { content in
            if replacing {
                content.setChildren(of: screenID, to: elements)
            } else {
                for element in elements { content.add(element, to: screenID) }
            }
        }
        return elements.map { ElementRef(host: .screen(screenID), element: $0.id) }
    }

    /// Writes a screen being generated as its latest version says, over what was written
    /// from the last (`written`, by place in the version). Each element written before
    /// stays the same element and takes its new form, unless it has been changed or taken
    /// away since: it is then the person's, left as they left it and written no more
    /// (nil). Elements new to this version are added, and ones it no longer has go.
    /// Whatever else is on the screen, put there by hand meanwhile, is left alone: each
    /// line used to replace everything on the screen (G5, M1). Returns what is now written.
    func writeGenerated(_ elements: [DesignElement], on screenID: DesignScreen.ID, over written: [DesignElement?]) -> [DesignElement?] {
        guard screen(screenID) != nil else { return written }
        var now: [DesignElement?] = []
        change { content in
            for (index, var element) in elements.enumerated() {
                guard index < written.count else {
                    now.append(content.add(element, to: screenID))
                    continue
                }
                guard let last = written[index], content.element(last.id) == last else {
                    now.append(nil)
                    continue
                }
                element.id = last.id
                content.update(last.id) { $0 = element }
                now.append(content.element(last.id))
            }
            for case let last? in written.dropFirst(elements.count) where content.element(last.id) == last {
                content.remove([last.id])
            }
        }
        return now
    }

    /// Gives an element to whatever it now lies on: the screen under its centre, or the
    /// open canvas when there is none. It keeps its size in points and its position on
    /// the canvas. Returns where the element now lives.
    @discardableResult
    func rehost(_ ref: ElementRef) -> ElementRef {
        guard let (element, placement) = resolve(ref) else { return ref }
        let frame = placement.canvasRect(for: element.frame)
        let target = element.kind.belongsOnScreens ? screen(at: CGPoint(x: frame.midX, y: frame.midY)) : nil
        let host: ElementRef.Host = target.map { .screen($0.id) } ?? .canvas
        guard host != ref.host else { return ref }
        return move(ref, toScreen: target?.id, origin: nil) ?? ref
    }

    /// Puts a ready-made element on the open canvas exactly where its frame says, in points
    /// of its own drawn `scale` canvas points each.
    @discardableResult
    func addFloating(_ element: DesignElement, scale: CGFloat) -> ElementRef {
        add(element, to: nil, scale: scale)
        return ElementRef(host: .canvas, element: element.id)
    }

    /// Moves an element onto a screen, or onto the open canvas when `screenID` is nil.
    /// `origin` is where its top-left corner goes, in its new host's points; when nil it
    /// keeps its place on the canvas. It keeps its size in points. Returns where it now
    /// lives, or nil when the element or screen is gone or the element can't go on screens.
    @discardableResult
    func move(_ ref: ElementRef, toScreen screenID: DesignScreen.ID?, origin: CGPoint?) -> ElementRef? {
        guard let (element, placement) = resolve(ref) else { return nil }
        var target: DesignScreen?
        if let screenID {
            guard let found = screen(screenID), element.kind.belongsOnScreens else { return nil }
            target = found
        }
        let host: ElementRef.Host = target.map { .screen($0.id) } ?? .canvas
        // Off a screen it keeps the scale it was drawn at, so it doesn't change size.
        let newPlacement = target?.placement ?? Placement(origin: .zero, scale: placement.scale)

        var frame = element.frame
        if let origin {
            frame.origin = origin
        } else {
            let onCanvas = placement.canvasRect(for: element.frame)
            let center = newPlacement.localPoint(for: CGPoint(x: onCanvas.midX, y: onCanvas.midY))
            frame.origin = CGPoint(x: (center.x - element.frame.width / 2).rounded(), y: (center.y - element.frame.height / 2).rounded())
        }

        if host == ref.host {
            update(ref) { $0.frame = frame }
            return ref
        }
        change { $0.move(element.id, to: target?.id, scale: newPlacement.scale, frame: frame) }
        return ElementRef(host: host, element: element.id)
    }

    // MARK: Changes made gradually

    /// Who makes a change made gradually.
    enum Editor: Hashable, Sendable {
        /// A drag, a stroke, a scrub, typing, or a run of changes in the format panel.
        case hand
        /// The selection being turned, by its knob or two fingers.
        case turn
        /// The app, working by itself over time or in several parts at once: a spoken
        /// command, a screen being written, a Siri action, a template added. Only changes
        /// made for it (`act(for:)`) are its own: one made by hand meanwhile never is.
        case app
    }

    /// One change made gradually: a drag, a stroke, a turn, a scrub, a sitting of typing,
    /// a run of changes in the format panel, a screen being written, a spoken command.
    ///
    /// Each is an undo step of its own, holding its own changes and nothing else. Several
    /// can be under way at once, and one ending never ends another: they used to share one
    /// edit, so a stroke ending during a generation closed the generation's step, and every
    /// line written after it, or every frame of a drag after a conversion landed, was a
    /// step of its own, which pushed the rest of the history out (C1). Undoing one leaves
    /// what the others did meanwhile as it is.
    @MainActor final class Edit {
        /// Who is making it.
        fileprivate(set) var editor: Editor
        /// Its step, from its first change.
        fileprivate var step: HistoryStep? {
            didSet { later = [] }
        }
        /// Steps put in the history after its own while it was under way.
        fileprivate var later: [Weak] = []
        /// Edits begun and ended inside its own work, which are part of it.
        fileprivate var nested = 0
        fileprivate(set) var isOpen = true
        /// Whether only the changes made for it are its own: one that says nothing of whose it
        /// is never joins it. See `beginEdit(by:takingOnlyItsOwn:)`.
        fileprivate var takesOnlyItsOwn = false
        /// What Undo and Redo call its step: see `name(_:_:)`.
        fileprivate var name: String?

        fileprivate init(editor: Editor) {
            self.editor = editor
        }

        /// Whether it has changed the design: its step is in the history.
        var isInHistory: Bool { step != nil }
    }

    fileprivate struct Weak {
        weak var step: HistoryStep?
    }

    /// The edits under way, in the order they began.
    @ObservationIgnored private var edits: [Edit] = []
    /// The edit whose changes are being made, while one says so (`act(for:)`).
    @ObservationIgnored private var acting: Edit?

    /// Starts a change made in many small steps, such as a drag or typing. Everything made
    /// for it (`act(for:)`) until `endEdit(_:)` undoes as one step. A change that says
    /// nothing of whose it is joins the edit by hand begun last, or failing one the turn,
    /// as a tap on a button in the middle of a drag does; it never joins the app's own.
    ///
    /// Begun inside an edit's own work, it is part of that edit.
    @discardableResult
    func beginEdit(by editor: Editor = .hand) -> Edit {
        if let acting {
            acting.nested += 1
            return acting
        }
        let edit = Edit(editor: editor)
        edits.append(edit)
        return edit
    }

    /// Starts an edit by hand that takes only the changes made for it (`act(for:)`): the
    /// format panel's run of quick changes, which waits for a pause to end. A delete, a lock
    /// or a duplicate made in that pause joined it, so one Undo took back both (audit M14).
    func beginEdit(by editor: Editor = .hand, takingOnlyItsOwn: Bool) -> Edit {
        let edit = beginEdit(by: editor)
        if edit !== acting { edit.takesOnlyItsOwn = takingOnlyItsOwn }
        return edit
    }

    /// Names what `edit` does, for the Edit menu, the keyboard's shortcuts and the undo HUD:
    /// "Undo Move" rather than a plain "Undo" (C18, M22). Only before its step is made, and
    /// not an edit whose work this is part of, which has its own name.
    func name(_ edit: Edit?, _ name: String) {
        guard let edit, edit.step == nil, edit !== acting else { return }
        edit.name = name
    }

    /// Names `edit` again, and its step if it has one: a drag a twist takes over becomes a
    /// move and a turn in one step (review m3). The history keeps the name a step was put in
    /// with, and a group can only be named while it is open, so a step on top is put in again
    /// under the new name, where it was. One below others keeps its old name until undone.
    func rename(_ edit: Edit?, _ name: String) {
        guard let edit, edit !== acting else { return }
        edit.name = name
        guard let step = edit.step, step.name != name else { return }
        guard let undoManager, step === lastStep, !undoManager.isUndoing, !undoManager.isRedoing, !undoManager.canRedo else {
            step.name = name
            return
        }
        let renamed = step.renamed(name)
        // The same step, where it was: the history hasn't moved, as far as anyone checking
        // its mark (a spoken correction) is concerned.
        let mark = historyMark
        withdraw(step)
        register(renamed)
        historyMark = mark
        edit.step = renamed
    }

    /// Starts a turn that goes on from `edit`, a drag the turn cut short, so that the two
    /// are one step. Without an edit still under way, a turn of its own begins.
    func beginEdit(by editor: Editor, takingOver edit: Edit?) -> Edit {
        guard let edit, edit.isOpen, acting == nil else {
            // Given up by the drag, it is this one's to end (review M-10).
            if let edit, edit !== acting { endEdit(edit) }
            return beginEdit(by: editor)
        }
        edit.editor = editor
        return edit
    }

    /// Begins an edit of its own even inside another's work: for work that outlives what
    /// started it, as a screen being written outlives a one-off step it was asked for in.
    func beginEditOfItsOwn(by editor: Editor) -> Edit {
        let edit = Edit(editor: editor)
        edits.append(edit)
        return edit
    }

    /// Ends `edit`. Its step is closed, and taken out again if it ended where it began.
    /// Others under way go on.
    func endEdit(_ edit: Edit) {
        if edit.nested > 0 {
            edit.nested -= 1
            return
        }
        guard edit.isOpen else { return }
        edit.isOpen = false
        edits.removeAll { $0 === edit }
        guard let step = edit.step else { return }
        if step.changesNothing {
            // Its changes undid themselves: a generation that wrote nothing and took its
            // screen away, or words typed and deleted. Its step would undo nothing, so it
            // is taken out again rather than light up Undo for a press that does nothing.
            withdraw(step)
            edit.step = nil
            return
        }
        if edit.editor == .app { putOnTop(edit) }
        // The step went in at the first change, which is when the system was told there
        // was something to save. An autosave since then saved only part of the edit, and
        // nothing else would tell it about the rest.
        markNeedsSaving()
    }

    /// Ends the edit `editor` began last, for whoever holds no edit of its own.
    func endEdit(by editor: Editor = .hand) {
        if let acting, acting.nested > 0 {
            acting.nested -= 1
            return
        }
        guard let edit = edits.last(where: { $0.editor == editor }) else { return }
        endEdit(edit)
    }

    /// Ends every edit under way, as the design closes.
    func endAllEdits() {
        for edit in edits.reversed() {
            edit.nested = 0
            endEdit(edit)
        }
    }

    /// Makes the changes `body` makes `edit`'s own, whatever else is under way. With no
    /// edit, or one that has ended, they are made as if by hand.
    func act<T>(for edit: Edit?, _ body: () throws -> T) rethrows -> T {
        guard let edit, edit.isOpen else { return try body() }
        let outer = acting
        acting = edit
        defer { acting = outer }
        return try body()
    }

    /// The edit whose changes are being made now, while one says so (`act(for:)`).
    var actingEdit: Edit? { acting }

    /// Whether a gradual edit by hand, or a turn, is under way.
    var isEditing: Bool { edits.contains { $0.editor != .app } }

    /// The edit a change joins when it says nothing of whose it is: the edit by hand begun
    /// last that takes such changes, or failing one the turn. One rule for `change(_:)` and
    /// `asOneStep(_:)`: they disagreed about the format panel's edit, which takes only its
    /// own, so several changes made in its pause were a step each (review I2).
    private var implicitOwner: Edit? {
        edits.last { $0.editor == .hand && !$0.takesOnlyItsOwn } ?? edits.last { $0.editor == .turn }
    }

    /// Whether `editor` has an edit under way.
    func isEditing(by editor: Editor) -> Bool { edits.contains { $0.editor == editor } }

    /// Whether the edit by hand begun last has put its step in the history yet.
    var editIsInHistory: Bool { edits.last { $0.editor != .app }?.step != nil }

    /// Puts the step of the app's own work that has just finished, a screen written or a
    /// spoken command, on top of the history, so that undo, or "No, …", takes it back first.
    /// It went in at its first change, and steps by hand made since are above it. It moves
    /// only when none of them touched what it did: taken back first then, it would take
    /// away a screen with something added to it by hand, which would be left on nothing.
    private func putOnTop(_ edit: Edit) {
        // Not while something can be redone: registering a step clears Redo (review I-3).
        guard let step = edit.step, let undoManager, !undoManager.isUndoing, !undoManager.isRedoing, !undoManager.canRedo else { return }
        let above = edit.later.compactMap(\.step)
        guard !above.isEmpty, !above.contains(where: { $0.touched.meets(step.touched) }) else { return }
        let moved = HistoryStep(runs: step.runs)
        moved.isCommand = step.isCommand
        moved.name = step.name
        withdraw(step)
        register(moved)
        edit.step = moved
    }

    /// How many runs `edit`'s step holds: the design is kept twice for each. For tests.
    func recordedRuns(of edit: Edit) -> Int { edit.step?.runs.count ?? 0 }

    /// Whether `edit`'s step is the one undo would take back now.
    func isLastStep(_ edit: Edit) -> Bool {
        guard let step = edit.step else { return false }
        return step === lastStep
    }

    /// Tells the system the document has changes to save, without a step in the history.
    /// The system marks a document as changed when its undo manager is about to close a
    /// group, so a change made without an undo step (a name the app settles on, the file's
    /// name, the picture for the document browser, or the rest of an edit after an autosave)
    /// would otherwise never be written if nothing else changed before the design closed.
    ///
    /// It is told as the undo manager would tell it, by the notice alone. Registering a step,
    /// even one taken straight out again, clears redo and, with a full history, pushes the
    /// oldest step out.
    func markNeedsSaving() {
        guard let undoManager else { return }
        NotificationCenter.default.post(name: .NSUndoManagerWillCloseUndoGroup, object: undoManager)
    }

    /// The spoken command under way, whose changes are one step: see `beginHeldEdit()`.
    @ObservationIgnored private(set) var heldEdit: Edit?

    /// Whether a spoken command is holding a step open: see `beginHeldEdit()`.
    var isHoldingEdit: Bool { heldEdit != nil }

    /// Starts the step of a spoken command, which stays open until `endHeldEdit()`. What the
    /// command does is made for it (`actingForCommand`) and undoes as the one step the
    /// command was. A change by hand made meanwhile, ink drawn or a drag, is a step of its
    /// own, which neither undoing the command nor a spoken correction of it takes back (V1).
    @discardableResult
    func beginHeldEdit() -> Edit {
        if let heldEdit {
            heldEdit.nested += 1
            return heldEdit
        }
        let edit = beginEdit(by: .app)
        heldEdit = edit
        return edit
    }

    /// Ends the spoken command's step. A drag or turn still under way goes on in its own.
    func endHeldEdit() {
        guard let heldEdit else { return }
        if heldEdit.nested > 0 {
            heldEdit.nested -= 1
            return
        }
        self.heldEdit = nil
        endEdit(heldEdit)
    }

    /// Makes the changes `body` makes the spoken command's under way, if there is one.
    func actingForCommand<T>(_ body: () throws -> T) rethrows -> T {
        try act(for: heldEdit, body)
    }

    func update(_ ref: ElementRef, _ body: (inout DesignElement) -> Void) {
        guard resolve(ref) != nil else { return }
        change { $0.update(ref.element, body) }
    }

    func updateScreen(_ id: DesignScreen.ID, _ body: (inout DesignScreen) -> Void) {
        guard screen(id) != nil else { return }
        change { $0.updateScreen(id, body) }
    }

    // MARK: Changes worked out elsewhere

    /// Applies a change to the design as one undo step. The ink canvas's changes to
    /// drawings come this way: a stroke drawn or rubbed out there is a change to a
    /// drawing here, undone like any other.
    func apply(_ body: (inout DesignContent) -> Void) {
        change(body)
    }

    /// Makes several changes one undo step. Inside a gradual edit by hand that is already
    /// under way and takes changes that say nothing of whose they are (`implicitOwner`), or
    /// as part of an edit's own work, they join that edit instead.
    func asOneStep(_ body: () -> Void) {
        guard acting == nil, implicitOwner == nil else {
            body()
            return
        }
        asOwnStep(body)
    }

    /// Makes several changes one undo step of their own, even in the middle of a drag or a
    /// stroke, which goes on as its own step: a template added, a drawing read on request,
    /// a Siri action. They used to open and close the edit by hand that was shared, which
    /// ended the drag's step under it (M3). As part of an edit's own work, they join it.
    @discardableResult
    func asOwnStep<T>(_ body: () throws -> T) rethrows -> T {
        if acting != nil { return try body() }
        let edit = beginEdit(by: .app)
        defer { endEdit(edit) }
        return try act(for: edit, body)
    }

    // MARK: Undo

    /// Adds an element to the list as its own change. Returns it as it is kept.
    @discardableResult
    private func add(_ element: DesignElement, to parent: DesignScreen.ID?, scale: CGFloat? = nil) -> DesignElement {
        var kept = element
        change { kept = $0.add(element, to: parent, scale: scale) }
        return kept
    }

    /// Applies a change. Made for an edit (`act(for:)`), it joins that edit's step; one
    /// that doesn't say whose it is joins the edit by hand begun last; on its own it is its
    /// own undo step.
    ///
    /// An edit's step goes in the history at its first change. Put in at the end instead,
    /// an undo pressed meanwhile (the toolbar's, while a spoken command or a generation
    /// holds its step open) took back the step before, lost the edit's changes so far, and
    /// was itself undone when the edit closed.
    private func change(_ body: (inout DesignContent) -> Void) {
        let before = content
        let count = changeCount
        isChanging = true
        // The change and the groups put right after it, in one access to the content, so that
        // the whole design is compared once (C6). A design without groups costs one scan.
        Self.applying(body, to: &content)
        isChanging = false
        // Whether it changed anything, as the content's own comparison found.
        guard changeCount != count else { return }
        let owner = acting ?? implicitOwner
        let step: HistoryStep
        if let existing = owner?.step {
            step = existing
        } else {
            step = HistoryStep()
            step.isCommand = owner != nil && owner === heldEdit
            step.name = owner?.name
            owner?.step = step
            register(step)
        }
        step.record(from: before, to: content, change: changeCount)
        // Told only now that it is recorded. Whatever the notice sets off, such as the ink
        // canvas following an eraser, is a change of its own, recorded in its own step: told
        // before, it went into this step as well (review I-1).
        onChange?(content)
    }

    /// Makes a change, then puts right whatever it left unsound about the design's groups:
    /// see `DesignContent.keepGroupsSound()`. Anything that builds or moves a group whole
    /// therefore does it in one change.
    private static func applying(_ body: (inout DesignContent) -> Void, to content: inout DesignContent) {
        body(&content)
        if content.hasGroups { content.keepGroupsSound() }
    }

    /// What each step in the history is registered with, rather than the store itself, so
    /// that one step can be taken out without the rest. It holds the step's own changes, as
    /// runs of the design before and after them: changes made between its runs by anyone
    /// else aren't the step's, and undoing it leaves them as they are.
    @MainActor fileprivate final class HistoryStep {
        struct Run {
            var before: DesignContent
            var after: DesignContent
        }

        private(set) var runs: [Run] = []
        /// Whether it is what a spoken command did: the only kind of step the command's own
        /// undo tool takes back.
        var isCommand = false
        /// What Undo and Redo call it, if it has a name.
        var name: String?
        /// `changeCount` after the step's last change.
        private var lastChange = -1

        init(runs: [Run] = []) {
            self.runs = runs
        }

        /// Adds a change of the step's own. One that follows straight on from its last
        /// extends that run: an edit nothing else interrupts is one run, from its start to
        /// where it is now, as a snapshot would be. So does one after changes by others that
        /// touched nothing the run did, which the run then takes in at both ends: two edits
        /// taking turns frame by frame, a drag and a turn, kept two designs for each frame
        /// (review M-1).
        func record(from before: DesignContent, to after: DesignContent, change: Int) {
            defer { lastChange = change }
            guard let last = runs.last else {
                runs.append(Run(before: before, after: after))
                return
            }
            if lastChange == change - 1 {
                runs[runs.count - 1].after = after
            } else if !Touched(from: last.after, to: before).meets(Touched(from: last.before, to: last.after)) {
                runs[runs.count - 1] = Run(before: last.before.reverting(last.after, to: before), after: after)
            } else {
                runs.append(Run(before: before, after: after))
            }
        }

        /// The same step under another name.
        func renamed(_ name: String) -> HistoryStep {
            let copy = HistoryStep(runs: runs)
            copy.isCommand = isCommand
            copy.name = name
            copy.lastChange = lastChange
            return copy
        }

        /// The design with the step's changes taken back.
        func undone(from content: DesignContent) -> DesignContent {
            runs.reversed().reduce(content) { $0.reverting($1.after, to: $1.before) }
        }

        /// The name it last gave the board, when it named the board.
        var lastNamed: String? {
            runs.last { $0.before.title != $0.after.title }?.after.title
        }

        /// Whether its changes undo themselves, so that taking it back would change nothing.
        var changesNothing: Bool {
            guard let last = runs.last?.after else { return true }
            return undone(from: last) == last
        }

        /// What its changes touched.
        var touched: Touched {
            runs.reduce(into: Touched()) { $0.formUnion(Touched(from: $1.before, to: $1.after)) }
        }
    }

    /// What a change touched: the elements it added, took away or altered, the screens it
    /// added, took away or altered, and the screens it put an element on or took one off,
    /// and whether it changed the board's name, its canvas, or what wasn't understood.
    fileprivate struct Touched {
        var elements: Set<DesignElement.ID> = []
        var screens: Set<DesignScreen.ID> = []
        var board = false

        init() {}

        init(from before: DesignContent, to after: DesignContent) {
            board = before.boardDiffers(from: after)
            let was = Dictionary(before.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let now = Dictionary(after.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Set(was.keys).union(now.keys) where was[id] != now[id] {
                elements.insert(id)
                // Added, taken away or moved to another host: the host is touched too.
                if was[id]?.parent != now[id]?.parent || was[id] == nil || now[id] == nil {
                    if let parent = was[id]?.parent { screens.insert(parent) }
                    if let parent = now[id]?.parent { screens.insert(parent) }
                }
            }
            let screensBefore = Dictionary(before.screenFrames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let screensAfter = Dictionary(after.screenFrames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Set(screensBefore.keys).union(screensAfter.keys) where screensBefore[id] != screensAfter[id] {
                screens.insert(id)
            }
        }

        mutating func formUnion(_ other: Touched) {
            elements.formUnion(other.elements)
            screens.formUnion(other.screens)
            board = board || other.board
        }

        func meets(_ other: Touched) -> Bool {
            (board && other.board) || !elements.isDisjoint(with: other.elements) || !screens.isDisjoint(with: other.screens)
        }
    }

    /// The steps undo would take back, oldest first, as the history holds them: one is
    /// added as it is registered, and taken off as it is undone or taken out. Those the
    /// history lets go of, past its cap, go by themselves.
    @ObservationIgnored private var undoable: [Weak] = []

    /// The step on top of the history: the one undo would take back.
    private var lastStep: HistoryStep? { undoable.last { $0.step != nil }?.step }

    /// The steps redo would put back, oldest first: added as undo registers them, taken off
    /// as they are redone, and all gone once a new step is made.
    @ObservationIgnored private var redoable: [Weak] = []

    private func forget(_ step: HistoryStep) {
        undoable.removeAll { $0.step == nil || $0.step === step }
        redoable.removeAll { $0.step == nil || $0.step === step }
    }

    /// Whether the step redo would put back now is a spoken command's.
    var nextRedoIsCommand: Bool { redoable.last { $0.step != nil }?.step?.isCommand == true }

    /// Whether the step undo would take back now is a spoken command's.
    var lastStepIsCommand: Bool { lastStep?.isCommand == true }

    /// Steps to take out of the history once the group they are in has closed.
    @ObservationIgnored private var stepsToWithdraw: [HistoryStep] = []
    @ObservationIgnored nonisolated(unsafe) private var groupCloseObserver: (any NSObjectProtocol)?

    /// Takes a step that undoes nothing out of the history. The document's history groups
    /// by event: taken out while the event's group is still open, the step leaves that group
    /// empty, and an empty group still lights Undo. So it is taken out as the group closes,
    /// and an empty group closed then goes with it. Undo pressed before then closes the
    /// group first, so the step is gone by the time Undo looks.
    private func withdraw(_ step: HistoryStep) {
        guard let undoManager else { return }
        historyMark += 1
        forget(step)
        guard undoManager.groupingLevel > 0 else {
            undoManager.removeAllActions(withTarget: step)
            Self.tellHistoryChanged(undoManager)
            return
        }
        stepsToWithdraw.append(step)
        guard groupCloseObserver == nil else { return }
        groupCloseObserver = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: undoManager, queue: nil) { [weak self, weak undoManager] _ in
            MainActor.assumeIsolated {
                guard let self, let undoManager, undoManager.groupingLevel == 0 else { return }
                for step in self.stepsToWithdraw { undoManager.removeAllActions(withTarget: step) }
                self.stepsToWithdraw = []
                if let observer = self.groupCloseObserver { NotificationCenter.default.removeObserver(observer) }
                self.groupCloseObserver = nil
                Self.tellHistoryChanged(undoManager)
            }
        }
    }

    /// Posted, with the undo manager as its object, when a step is taken out of the history.
    /// The undo manager says when a step goes in, is undone or is redone, but says nothing
    /// when one is taken out, so Undo stayed lit after a generation that wrote nothing,
    /// for a press that did nothing. Whatever shows undo and redo listens for this too.
    nonisolated static let historyDidChange = Notification.Name("LayerDesignHistoryDidChange")

    private static func tellHistoryChanged(_ undoManager: UndoManager) {
        NotificationCenter.default.post(name: historyDidChange, object: undoManager)
    }

    deinit {
        if let groupCloseObserver { NotificationCenter.default.removeObserver(groupCloseObserver) }
    }

    /// What Undo and Redo call a spoken command's step.
    static let commandStepName = String(localized: "Voice Command")

    private func register(_ step: HistoryStep) {
        guard let undoManager else { return }
        historyMark += 1
        // Registering while undoing makes the step the redo step; a new step clears redo.
        if undoManager.isUndoing {
            redoable.append(Weak(step: step))
        } else {
            undoable.append(Weak(step: step))
            if !undoManager.isRedoing { redoable = [] }
        }
        if !undoManager.isUndoing {
            for edit in edits where edit.step != nil && edit.step !== step { edit.later.append(Weak(step: step)) }
        }
        // Each step is a group of its own, even in the document's history, which groups what
        // is registered in one turn of the run loop: steps begun in the same turn, a drag's
        // first frame and a turn's, or a command's change and a stroke, shared a group, and
        // one undo, or a spoken correction, took back both.
        let groupsByEvent = undoManager.groupsByEvent
        if groupsByEvent, undoManager.groupingLevel == 0 { undoManager.groupsByEvent = false }
        defer { undoManager.groupsByEvent = groupsByEvent }
        undoManager.beginUndoGrouping()
        // The history holds its target weakly: the step is kept alive by its own action.
        undoManager.registerUndo(withTarget: step) { [weak self, step] _ in
            withExtendedLifetime(step) {}
            self?.takeBack(step)
        }
        // A spoken command's step is named for the Edit menu and the undo HUD (V8). Named
        // here, inside its own group: after the command, with the document's history
        // grouping by event, no group is open and naming one throws.
        if step.isCommand {
            undoManager.setActionName(Self.commandStepName)
        } else if let name = step.name {
            undoManager.setActionName(name)
        }
        undoManager.endUndoGrouping()
    }

    /// Undoes a step, or redoes one, by taking back its own changes, and registers the
    /// reverse.
    private func takeBack(_ step: HistoryStep) {
        forget(step)
        let current = content
        var result = step.undone(from: current)
        // A screen the step took away may have had something put on it by another edit
        // since: it goes onto the open canvas where it was, rather than on no screen, drawn
        // nowhere and saved so (review C-1).
        result.rehostElementsOnMissingScreens(from: current)
        // Taken back among changes made since, a step can leave a group unsound: put right
        // here, so that the reverse step holds it too.
        if result.hasGroups { result.keepGroupsSound() }
        content = result
        let reverse = HistoryStep(runs: [.init(before: current, after: result)])
        reverse.isCommand = step.isCommand
        reverse.name = step.name
        register(reverse)
        // An edit still open whose step this was goes on from here, as a step of its own.
        for edit in edits where edit.step === step { edit.step = nil }
    }
}
