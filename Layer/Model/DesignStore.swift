import CoreGraphics
import Foundation
import Observation

/// The design on the canvas. Every change goes through here and is registered with the
/// document's undo manager, which is also what tells the system that the document needs
/// saving.
///
/// The design is kept as a tree (`DesignContent.tree`), and the tree's rules (`TreeRules`) run
/// inside every change, undo and redo. `screens` and `floating`, and the one list of elements
/// they are views of, are the tree lowered (`TreeProjection`), worked out once per change.
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
            kept = nil
            targets = nil
            changeCount += 1
            // A change made through `change(_:)` is told once it has been recorded: see there.
            if !isChanging { onChange?(content) }
        }
    }

    /// True while `change(_:)` makes a change, before it is recorded.
    @ObservationIgnored private var isChanging = false
    /// True while the app moves things by their placement intents: see `keepingPlacementIntents(_:)`.
    @ObservationIgnored private var keepsPlacementIntents = false

    /// Counts the changes made to the content, by anyone, so that a step can tell whether
    /// the change before its own was its own too.
    @ObservationIgnored private var changeCount = 0

    /// Screens' roots laid out off the main actor, for the next change alone: see `withLaidOutAhead`.
    @ObservationIgnored private var laidOutAhead: [TreeScreen.ID: LayerNode] = [:]

    /// Moves on with every change to the content, and is read so that whatever draws from
    /// something kept for one version is drawn again when the content changes. For keeping
    /// what is worked out from the content, for as long as it is as it was.
    var contentVersion: Int {
        _ = content
        return changeCount
    }

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

    /// What is worked out from the tree for the content as it is now, each part when it is
    /// first asked for: where every node is, and the tree lowered to the list and its views.
    private struct Kept {
        /// Made by `index` when it is first read.
        var index: TreeIndex?
        /// Made by `projection` when it is first read.
        var lowered: TreeProjection.Lowered?
    }
    @ObservationIgnored private var kept: Kept?

    #if DEBUG
    /// How many times this store has lowered its tree: at most once for each version of the content
    /// that was read. For the tests that hold what is lowered on a change to the store's memo.
    @ObservationIgnored private(set) var timesLowered = 0
    /// How many times this store has built its index: at most once for each version of the content
    /// that was read. For the tests that hold a gesture's frames to building it only when they need it.
    @ObservationIgnored private(set) var timesIndexed = 0
    #endif

    init(content: DesignContent = DesignContent()) {
        self.content = content
    }

    // PROJECTION: deleted in plan 6
    /// The tree lowered to the list and its views, once per version of the content.
    var projection: TreeProjection.Lowered {
        // Read first, so that whatever draws from a view is redrawn when the content changes.
        let content = content
        if let lowered = kept?.lowered { return lowered }
        let lowered = TreeProjection.lower(content.tree)
        #if DEBUG
        timesLowered += 1
        #endif
        if kept == nil { kept = Kept() }
        kept?.lowered = lowered
        return lowered
    }

    /// The design's tree. Read through `content`, so that whatever reads it is redrawn when it changes.
    var tree: TreeContent { content.tree }

    /// Where every node of the tree is, worked out once per version of the content, when it is
    /// first asked for: see `TreeIndex`.
    var index: TreeIndex {
        // Read first, so that whatever reads it is redrawn when the content changes.
        let content = content
        if let index = kept?.index { return index }
        let index = TreeIndex(content.tree)
        #if DEBUG
        timesIndexed += 1
        #endif
        if kept == nil { kept = Kept() }
        kept?.index = index
        return index
    }

    /// What can be touched on each host, for the containers that had been gone into when it was
    /// worked out (see `treeTargets(entered:)`), for the content as it is now. Hover asks for it
    /// on every move of the pen.
    @ObservationIgnored private var targets: (entered: Set<UUID>, found: TreeTargets)?

    /// What can be touched on each screen and the open canvas while the containers in `entered` have been
    /// gone into: see `TreeTargets`. Kept until the content changes, or other containers are gone into:
    /// hover asks on every move of the pen. `CanvasWork.targetPasses` counts each build.
    func treeTargets(entered: Set<UUID>) -> TreeTargets {
        // Read first, so that whatever draws from it is redrawn when the content changes.
        _ = content
        if let targets, targets.entered == entered { return targets.found }
        #if DEBUG
        CanvasWork.targetPasses += 1
        #endif
        let found = TreeTargets(tree, index: index, entered: entered)
        targets = (entered, found)
        return found
    }

    // PROJECTION: deleted in plan 6
    // Called by nothing: the projection's list has no place in the tree.
    /// Where an element is in the design's own list.
    func indexInList(of id: DesignElement.ID) -> Int? {
        projection.position[id]
    }

    // PROJECTION: deleted in plan 6
    /// Each screen with what is on it.
    var screens: [DesignScreen] { projection.screens }
    // PROJECTION: deleted in plan 6
    /// The elements on the open canvas.
    var floating: [FloatingElement] { projection.floating }
    var title: String? { content.title }
    var canvas: CanvasSettings { content.canvas }

    // MARK: Looking things up

    // PROJECTION: deleted in plan 6
    func screen(_ id: DesignScreen.ID) -> DesignScreen? {
        screens.first { $0.id == id }
    }

    // PROJECTION: deleted in plan 6
    // The tree's is `treeScreen(at:)`.
    /// The topmost screen covering a point on the canvas.
    func screen(at point: CGPoint) -> DesignScreen? {
        screens.last { $0.canvasFrame.contains(point) }
    }

    // PROJECTION: deleted in plan 6
    // For the sketch path (`AppModel`, plan 5); the tree's is `treeScreen(at:)` at the sketch's centre.
    /// The screen a sketch was drawn on, judged by where the sketch's centre falls.
    func screen(under sketch: CGRect) -> DesignScreen? {
        screen(at: CGPoint(x: sketch.midX, y: sketch.midY))
    }

    // PROJECTION: deleted in plan 6
    /// An element, wherever it is.
    func element(_ id: DesignElement.ID) -> DesignElement? {
        let lowered = projection
        return lowered.position[id].map { lowered.elements[$0] }
    }

    // PROJECTION: deleted in plan 6
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

    /// The area everything in the design covers, or nil for an empty design: each screen with its name, and the
    /// shape of every node on the open canvas as the index has it. A turned one covers the box round its turned shape.
    var contentBounds: CGRect? {
        let tree = tree, index = index
        var rects = tree.screens.map { screen in
            let device = tree.device(of: screen)
            return screen.canvasFrame(on: device).union(screen.labelFrame(on: device))
        }
        func cover(_ node: LayerNode) {
            if let shape = index.canvasShape(of: node.id, in: tree) { rects.append(shape.bounds) }
            node.children.forEach(cover)
        }
        tree.canvas.forEach(cover)
        return rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }

    /// The scale loose things are drawn at: that of the newest screen, so they match it.
    var looseScale: CGFloat { tree.screens.last?.scale ?? 0.66 }

    // MARK: Changes made in one step

    /// Adds the screen a sketch stands for: an iPhone, as large as it was drawn.
    @discardableResult
    func addScreen(from sketch: CGRect) -> DesignScreen {
        let device = canvas.sketchDevice
        return addScreen(device, at: ElementLayout.screenPlacement(for: sketch, device: device))
    }

    /// Named by how many screens the tree holds, so that a frame added from the library lowers nothing.
    @discardableResult
    func addScreen(_ device: DeviceFrame, at placement: Placement) -> DesignScreen {
        let screen = DesignScreen(
            name: "Screen \(tree.screens.count + 1)", origin: placement.origin, scale: placement.scale,
            deviceID: device == .iPhone ? nil : device.id
        )
        change { $0.addScreen(screen) }
        return screen
    }

    // PROJECTION: deleted in plan 6
    /// Adds an element where it was sketched on a screen: `addSketched`, as the rules read it with confidence 1 (F27).
    /// It lands where its centre is on the screen, laid out there, and remembers its sketch. `adjust` finishes the
    /// element before it is added, in the same undoable step. Returns it as it is kept, or nil when the screen no longer
    /// exists, the sketch's centre isn't on it (it is the topmost screen there), or the design can't hold another thing.
    @discardableResult
    func addElement(_ kind: ElementKind, from sketch: CGRect, to screenID: DesignScreen.ID, adjust: (inout DesignElement) -> Void = { _ in }) -> DesignElement? {
        guard self.screenID(under: sketch) == screenID else { return nil }
        let added = addSketched(kind, from: sketch, confidence: 1, decidedBy: .rules) { node in
            let shown = DesignElement(node: node, frame: node.frame, rotation: node.rotation, parent: screenID, scale: nil, group: nil)
            var element = shown
            adjust(&element)
            node.take(element, shown: shown)
        }
        return added.flatMap { element($0) }
    }

    // PROJECTION: deleted in plan 6
    /// `changeKind(of:to:fallback:adjust:)` for an element ref, and as the projection's element: the sketch (canvas points)
    /// is only what a node with no sketch of its own is laid out from. Nil when it is gone or isn't on a screen.
    @discardableResult
    func changeKind(of ref: ElementRef, to kind: ElementKind, sketchedAt sketch: CGRect, adjust: (inout DesignElement) -> Void = { _ in }) -> DesignElement? {
        guard case .screen(let screenID) = ref.host, let screen = treeScreen(screenID),
              index[ref.element]?.host == .screen(screenID) else { return nil }
        let changed = changeKind(of: ref.element, to: kind, fallback: screen.placement.localRect(for: sketch)) { node in
            let shown = DesignElement(node: node, frame: node.frame, rotation: node.rotation, parent: screenID, scale: nil, group: nil)
            var element = shown
            adjust(&element)
            node.take(element, shown: shown)
        }
        return changed.flatMap { element($0) }
    }

    // PROJECTION: deleted in plan 6
    /// Adds an element sketched on the open canvas, where and about as large as it was drawn: the sketch path's reading
    /// off every screen (plan 5 leaves it here, F15).
    @discardableResult
    func addFloating(_ kind: ElementKind, from sketch: CGRect) -> ElementRef {
        var element = Self.newElement(kind)
        let scale = looseScale
        let drawn = CGSize(width: sketch.width / scale, height: sketch.height / scale)
        element.frame.size = kind.spec.looseSize.size(from: element.frame.size, drawn: drawn)
        return place(element, centeredAt: CGPoint(x: sketch.midX, y: sketch.midY))
    }

    /// Deletes several elements as one undo step. A container goes with everything in it, at
    /// any depth, whatever their own locks: a group is one thing. What held it keeps the rest
    /// of what it holds, laid out again if it lays them out. The sketch reading log is told
    /// once, of everything that went (`delete(nodes:)`).
    func delete(_ refs: [ElementRef]) {
        delete(nodes: Set(refs.map(\.element)))
    }

    // PROJECTION: deleted in plan 6
    /// Puts a ready-made element on the canvas, centred on a point: onto the screen
    /// there, if it is the kind of thing that goes on screens, and onto the open canvas
    /// otherwise. Only the size of `element.frame` is used. The library's drops land here (plan 5 leaves it, F15).
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

    /// Deletes an element, or a container with everything in it, as one undo step: see
    /// `delete(_ refs:)`.
    func delete(_ ref: ElementRef) {
        guard resolve(ref) != nil else { return }
        delete(nodes: [ref.element])
    }

    /// Tells the sketch reading log which elements were deleted: see `SketchReadingLog`.
    func tellTheReadingLogOfDeleted(_ ids: Set<DesignElement.ID>) {
        // One task for them all: a group of 200 is not 200 hops to the log's actor.
        guard !ids.isEmpty else { return }
        #if DEBUG
        CanvasWork.readingLogTasks += 1
        #endif
        Task { await SketchReadingLog.shared.noteDeleted(ids) }
    }

    /// A copy of an element beside the original, 16 of its points down and to the right,
    /// whatever the turn of what holds it, as one change (`duplicate(node:)`). It goes on top
    /// of what is on its host; or, inside a container, just in front of the original there:
    /// next to it in a row or a column, and in a group without pulling the group to the front.
    ///
    /// A container is copied whole, with everything in it, as what it is: a row stays a row
    /// and a card a card. Each copy is new. The copy itself is unlocked, as a copy is; what is
    /// in it keeps its own lock and hide, and a drawing's copy has strokes of its own. Nil
    /// when it is gone, or the copy would take the design past 5,000 things.
    @discardableResult
    func duplicate(_ ref: ElementRef) -> ElementRef? {
        guard resolve(ref) != nil, let copy = duplicate(node: ref.element) else { return nil }
        return ElementRef(host: ref.host, element: copy)
    }

    /// A copy of a screen and everything on it, to its right, as one change. What is on it is
    /// copied as it is, its root's layout, rows and cards included, each thing new and keeping
    /// its own lock and hide. The copy is unlocked and named for the original. Nil when the
    /// screen is gone, or the copy would take the design past 5,000 things.
    @discardableResult
    func duplicateScreen(_ id: DesignScreen.ID) -> DesignScreen? {
        duplicateTreeScreen(id).flatMap { screen($0) }
    }

    /// `duplicateScreen(_:)` read from the tree, giving the copy's identifier: what the popover's Duplicate does, so
    /// that a tap lowers nothing.
    @discardableResult
    func duplicateTreeScreen(_ id: TreeScreen.ID) -> TreeScreen.ID? {
        let tree = tree
        guard let original = tree.screens.first(where: { $0.id == id }) else { return nil }
        let frame = original.canvasFrame(on: tree.device(of: original))
        var copy = original
        copy.id = UUID()
        copy.root = TreeEdit.copyWithNewIDs(original.root)
        // A screen's root takes the screen's identifier, as one made from a view does (`DesignContent.addScreen`).
        copy.root.id = copy.id
        copy.name = Self.copyName(for: original.name, among: tree.screens.map(\.name))
        copy.isLocked = nil
        copy.origin.x = frame.maxX + 60
        return addScreen(copy)
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

    /// Moves an element up or down among its siblings, the children of its parent: see
    /// `arrange(_ selection:_:)`. Siri's Change Element Order comes this way.
    func arrange(_ ref: ElementRef, _ arrangement: Arrangement) {
        arrange(.element(ref), arrangement)
    }

    /// Whether an element can go further up, or further down, among its neighbours.
    func canArrange(_ ref: ElementRef, _ arrangement: Arrangement) -> Bool {
        canArrange(.element(ref), arrangement)
    }

    /// Lines an element on a screen up with an edge or the middle of that screen. A container
    /// lines up as one block: its box is lined up, and everything in it moves as far. Read from the
    /// tree and written to it, so that an Align tap lowers nothing: a container by `position`, and
    /// anything else through its parent (`place`), which in a row, column, grid or overlay takes it
    /// out as a new place does (My call 20).
    func align(_ ref: ElementRef, _ alignment: ElementLayout.Alignment) {
        guard case .screen(let id) = ref.host, let screen = treeScreen(id), let placed = placed(ref) else { return }
        // A turned thing lines up by the box round its shape; its frame moves with it.
        let shape = TurnedRect(rect: placed.frame, degrees: placed.degrees).bounds
        let aligned = ElementLayout.aligned(shape, alignment, in: tree.device(of: screen).size)
        let distance = CGSize(width: aligned.minX - shape.minX, height: aligned.minY - shape.minY)
        guard placed.node.isContainer else {
            return place(ref.element, at: placed.frame.offsetBy(dx: distance.width, dy: distance.height))
        }
        // `position` takes canvas points.
        let box = placed.canvasShape.bounds, scale = screen.placement.scale
        position([.element(ref): CGPoint(x: box.minX + distance.width * scale, y: box.minY + distance.height * scale)])
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

    /// Adds ready-made elements to a screen as one step, in front of what is there. The screen's
    /// root keeps its layout, and lays them out if it lays things out. Returns where they now live.
    /// What a screen holds is replaced whole with `replaceChildren(of:with:)`.
    ///
    /// The tree keeps sticky notes and drawings on the open canvas, never on a screen: one
    /// given here goes on the canvas where the screen would have shown it, at the screen's
    /// scale, in front of what is there.
    @discardableResult
    func setElements(_ elements: [DesignElement], on screenID: DesignScreen.ID) -> [ElementRef] {
        guard let screen = tree.screens.first(where: { $0.id == screenID }) else { return [] }
        let scale = screen.scale.isFinite && screen.scale > 0 ? screen.scale : 1
        var onScreen: [LayerNode] = [], onCanvas: [LayerNode] = []
        for element in elements {
            var node = LayerNode(element: element)
            guard !element.kind.belongsOnScreens else {
                onScreen.append(node)
                continue
            }
            // From the screen's points to the canvas's, drawn as large.
            node.frame.origin.x += screen.origin.x / scale
            node.frame.origin.y += screen.origin.y / scale
            node.scale = scale
            onCanvas.append(node)
        }
        asOneStep {
            for node in onScreen { add(node, to: .screen(screenID)) }
            for node in onCanvas { add(node, to: .canvas) }
        }
        return elements.map { ElementRef(host: $0.kind.belongsOnScreens ? .screen(screenID) : .canvas, element: $0.id) }
    }

    /// Gives a thing to whatever it now lies on: the screen under its middle, or the open canvas
    /// when there is none. It goes to that host's top level, on top, in one change (`move(_:to:at:)`):
    /// its middle stays where it is on the canvas and its size in its own points, its corner on
    /// whole points. A container goes whole, and what is in it keeps its own frames, so that on a
    /// screen drawn at another scale it arrives scaled about its middle. Sticky notes and drawings
    /// stay on the canvas, and so does a container holding one, which the move refuses. Read from
    /// the tree. Returns where the thing now lives.
    @discardableResult
    func rehost(_ ref: ElementRef) -> ElementRef {
        guard let placed = placed(ref) else { return ref }
        let middle = placed.canvasShape.centre
        let goesOnScreens = placed.node.isContainer || placed.node.kind.belongsOnScreens
        let target = goesOnScreens ? treeScreen(at: middle) : nil
        let host: ElementRef.Host = target.map { .screen($0.id) } ?? .canvas
        guard host != ref.host, move(ref.element, to: target.map { .screen($0.id) } ?? .canvas) else { return ref }
        return self.ref(of: ref.element) ?? ref
    }

    // PROJECTION: deleted in plan 6
    /// Puts a ready-made element on the open canvas exactly where its frame says, in points
    /// of its own drawn `scale` canvas points each.
    @discardableResult
    func addFloating(_ element: DesignElement, scale: CGFloat) -> ElementRef {
        add(element, to: nil, scale: scale)
        return ElementRef(host: .canvas, element: element.id)
    }

    /// Moves an element onto a screen, or onto the open canvas when `screenID` is nil.
    /// `origin` is where its top-left corner goes, in its new host's points; when nil it
    /// keeps its place on the canvas, its corner on whole points. It keeps its size in its own
    /// points, and a container goes whole, everything in it with it (`move(_:to:at:)`). Returns
    /// where it now lives, or nil when the element or screen is gone or the element can't go on
    /// screens. One step to undo.
    @discardableResult
    func move(_ ref: ElementRef, toScreen screenID: DesignScreen.ID?, origin: CGPoint?) -> ElementRef? {
        guard let (element, placement) = resolve(ref) else { return nil }
        var target: DesignScreen?
        if let screenID {
            guard let found = screen(screenID), element.kind.belongsOnScreens else { return nil }
            target = found
        }
        let host: ElementRef.Host = target.map { .screen($0.id) } ?? .canvas

        guard host != ref.host else {
            var frame = element.frame
            if let origin {
                frame.origin = origin
            } else {
                let onCanvas = placement.canvasRect(for: element.frame)
                let center = placement.localPoint(for: CGPoint(x: onCanvas.midX, y: onCanvas.midY))
                frame.origin = CGPoint(x: (center.x - element.frame.width / 2).rounded(), y: (center.y - element.frame.height / 2).rounded())
            }
            let distance = CGSize(width: frame.minX - element.frame.minX, height: frame.minY - element.frame.minY)
            if element.kind == .group, let moved = self.origin(of: element.id, movedBy: distance) {
                // A container moves by its own frame, and what is in it rides along.
                update(element.id) { $0.frame.origin = moved }
            } else {
                update(ref) { $0.frame = frame }
            }
            return ref
        }
        // It lands at the top level of its new host, on top, where its own frame is in the host's points.
        var moved = false
        asOneStep {
            moved = move(element.id, to: target.map { .screen($0.id) } ?? .canvas)
            if moved, let origin { update(element.id) { $0.frame.origin = origin } }
        }
        return moved ? ElementRef(host: host, element: element.id) : nil
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

    /// The one screen that all `edit`'s step changed is, or is on: the screen itself, and
    /// elements on it before and after. Nil when it changed nothing, or anything else: the
    /// board, another screen, or an element on the open canvas, or moved on or off it; or
    /// when it made that screen or took it away.
    func onlyScreen(changedBy edit: Edit) -> DesignScreen.ID? {
        edit.step?.onlyScreen
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
    ///
    /// `name` names the step, for the Edit menu and the undo HUD, when it is begun here. A
    /// command begun inside another's step is part of that one, and leaves its name alone.
    @discardableResult
    func beginHeldEdit(named name: String? = nil) -> Edit {
        if let heldEdit {
            heldEdit.nested += 1
            return heldEdit
        }
        let edit = beginEdit(by: .app)
        if let name { self.name(edit, name) }
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

    // PROJECTION: deleted in plan 6
    func update(_ ref: ElementRef, _ body: (inout DesignElement) -> Void) {
        guard resolve(ref) != nil else { return }
        change { $0.update(ref.element, body) }
    }

    // PROJECTION: deleted in plan 6
    // The twin of `update(_ ref:)`, for Siri, voice and Debug; the tree's is `updateTreeScreen(_:_:)`.
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

    /// Runs `body`, whose next change commits roots laid out off the main actor: `roots`, by screen. For that change
    /// alone, the rules lay out nothing on a screen whose root is then the one given for it (plan 3, call 6).
    func withLaidOutAhead<T>(_ roots: [TreeScreen.ID: LayerNode], _ body: () throws -> T) rethrows -> T {
        laidOutAhead = roots
        defer { laidOutAhead = [:] }
        return try body()
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
        // A hint for this change alone.
        let ahead = laidOutAhead
        laidOutAhead = [:]
        isChanging = true
        // The change and the tree's rules after it, in one access to the content, so that the
        // whole design is compared once (C6).
        let isUndoingOrRedoing = undoManager.map { $0.isUndoing || $0.isRedoing } ?? false
        Self.applying(body, to: &content, previous: before, laidOutAhead: ahead, followingPlacements: !keepsPlacementIntents,
                      decliningWhatLeftAStructure: !isUndoingOrRedoing)
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

    /// Writes the structure pass's declines (`declining(_:in:)`) outside every step, as a suggested title is written
    /// (`setTitle(undoable: false)`): undo never takes one back, and no Undo lights for one. False when none changed.
    /// Only "Keep them as drawn" declines so (call 11): a decline a change makes is part of its step (`applying`).
    @discardableResult
    func markDeclinedOutsideTheHistory(_ ids: [UUID]) -> Bool {
        let marked = Self.declining(Set(ids), in: content.tree)
        guard marked != content.tree else { return false }
        content.tree = marked
        return true
    }

    /// Makes a change, then cuts the pointers it left that the tree can't hold and runs the
    /// tree's rules, laying out what changed since `previous`. Anything that builds or moves a
    /// group whole therefore does it in one change: see `DesignContent.keepGroupsSound()`.
    ///
    /// A screen whose root was laid out ahead, and is that root now, is laid out already: the rules are told it was
    /// that root before, so they find nothing changed there and lay nothing out (plan 3, call 6).
    ///
    /// With `followingPlacements`, each sketched thing the change put somewhere new in a free container on a screen has
    /// its placement intent read again from where it is (`TreeContent.followPlacements(since:)`), in the same change and
    /// so the same step: undoing the move puts the intent back with it.
    ///
    /// With `decliningWhatLeftAStructure` (plan 5's call 11, F4), a node the change took out of a container the
    /// structure pass made, into another parent, is declined, whichever verb moved it: the canvas's drops and lifts, the
    /// Layers panel, several things dragged, Siri and voice. Not for a container that is gone, so that a structure grown
    /// into another or ungrouped declines nothing this way (`ungroup` declines on its own). The marks are part of the
    /// change, and so of its step (plan 5's final review, A9): undoing the move takes them away, and redo puts them
    /// back. Not after an undo or a redo, which never come through here anyway.
    private static func applying(_ body: (inout DesignContent) -> Void, to content: inout DesignContent, previous: DesignContent,
                                 laidOutAhead: [TreeScreen.ID: LayerNode] = [:], followingPlacements: Bool,
                                 decliningWhatLeftAStructure: Bool) {
        body(&content)
        content.pendingPointers = [:]
        TreeRules.apply(to: &content.tree, after: holding(laidOutAhead, in: previous.tree, as: content.tree))
        if followingPlacements { content.tree.followPlacements(since: previous.tree) }
        if decliningWhatLeftAStructure {
            let leaving = takenOutOfStructures(from: previous.tree, to: content.tree)
            if !leaving.isEmpty { content.tree = declining(Set(leaving), in: content.tree) }
        }
    }

    /// Makes `body`'s changes keeping every placement intent as it is (plan 5's final review, A4): a device change moves
    /// things by them, and voice's tidy carries what rides on what it lays out. Only a move or a resize the person makes
    /// rewrites one.
    func keepingPlacementIntents<T>(_ body: () throws -> T) rethrows -> T {
        let outer = keepsPlacementIntents
        keepsPlacementIntents = true
        defer { keepsPlacementIntents = outer }
        return try body()
    }

    /// `previous` with each screen of `laidOut` holding its root there, when `content` has that screen with that root:
    /// in its place, or added for a new screen.
    private static func holding(_ laidOut: [TreeScreen.ID: LayerNode], in previous: TreeContent,
                                as content: TreeContent) -> TreeContent {
        guard !laidOut.isEmpty else { return previous }
        var previous = previous
        for screen in content.screens {
            guard let root = laidOut[screen.id], screen.root == root else { continue }
            if let index = previous.screens.firstIndex(where: { $0.id == screen.id }) {
                previous.screens[index].root = root
            } else {
                previous.screens.append(screen)
            }
        }
        return previous
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
            } else if !TreeChange(from: last.after, to: before).meets(TreeChange(from: last.before, to: last.after)) {
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
        var touched: TreeChange {
            runs.reduce(into: TreeChange()) { $0.formUnion(TreeChange(from: $1.before, to: $1.after)) }
        }

        /// The one screen all its changes were to or on: see `DesignStore.onlyScreen(changedBy:)`.
        var onlyScreen: DesignScreen.ID? {
            var screens: Set<DesignScreen.ID> = []
            for run in runs {
                let touched = TreeChange(from: run.before, to: run.after)
                guard !touched.board else { return nil }
                screens.formUnion(touched.screens)
                // Where each node it changed was, and is: a screen, or the open canvas.
                let was = TreeChange.hosts(in: run.before.tree), now = TreeChange.hosts(in: run.after.tree)
                for id in touched.nodes {
                    for host in [was[id], now[id]] {
                        // Not there on that side: added, or taken away.
                        guard let host else { continue }
                        guard case .screen(let screen) = host else { return nil }
                        screens.insert(screen)
                    }
                }
            }
            // A screen the step made or took away isn't one a correction for it may undo:
            // that would take the screen away, or bring it back, again.
            guard screens.count == 1, let screen = screens.first,
                  runs.first?.before.tree.screens.contains(where: { $0.id == screen }) == true,
                  runs.last?.after.tree.screens.contains(where: { $0.id == screen }) == true
            else { return nil }
            return screen
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

    /// What Undo and Redo call the step of a change asked of one screen, typed or held to
    /// speak: a command's step named for what it is.
    static let screenEditStepName = String(localized: "Change Screen")

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
        // A spoken command's step is named for the Edit menu and the undo HUD (V8), unless
        // it has a name of its own, as a change for one screen has. Named here, inside its
        // own group: after the command, with the document's history grouping by event, no
        // group is open and naming one throws.
        if let name = step.name {
            undoManager.setActionName(name)
        } else if step.isCommand {
            undoManager.setActionName(Self.commandStepName)
        }
        undoManager.endUndoGrouping()
    }

    /// Undoes a step, or redoes one, by taking back its own changes, and registers the
    /// reverse.
    private func takeBack(_ step: HistoryStep) {
        forget(step)
        let current = content
        // A node whose parent the step took away, a screen or a group, may have been put
        // there by another edit since: it lands on the open canvas where it was, rather than
        // on nothing, drawn nowhere and saved so (review C-1).
        var result = step.undone(from: current)
        // Taken back among changes made since, a step can leave the tree as its rules wouldn't:
        // put right here, so that the reverse step holds it too.
        result.pendingPointers = [:]
        TreeRules.apply(to: &result.tree, after: current.tree)
        content = result
        let reverse = HistoryStep(runs: [.init(before: current, after: result)])
        reverse.isCommand = step.isCommand
        reverse.name = step.name
        register(reverse)
        // An edit still open whose step this was goes on from here, as a step of its own.
        for edit in edits where edit.step === step { edit.step = nil }
    }
}

private extension TreeChange {
    /// What a change to the content touched: what it touched in the tree.
    init(from before: DesignContent, to after: DesignContent) {
        self.init(from: before.tree, to: after.tree)
    }
}
