import Foundation
import PencilKit
import UniformTypeIdentifiers

extension UTType {
    /// A Layer design, saved with the `.layer` extension. Declared in the app's Info.plist.
    static let layerDesign = UTType(exportedAs: "kahshin.layer.design")
}

// PROJECTION: deleted in plan 6
/// The part of a design that the design tools edit: its screens, everything on them and
/// on the open canvas, its title and how its canvas is set up.
///
/// It is kept as a tree, `tree`: each screen's root holds what is on the screen, and the
/// canvas holds its own nodes. The members below are the flat list the app was written
/// against, one list of elements each saying what it is on, worked out from the tree
/// (`TreeProjection`) and written back into it until each caller reads and writes the tree
/// itself. A field or frame written to one element goes to its node alone; a write that
/// changes what is on a host, or what holds what, lowers that host, makes the change on
/// its list as the list did, and lifts the list back into the tree.
struct DesignContent: Equatable, Sendable {
    var tree = TreeContent()
    /// Pointers a flat write named that the tree can't hold yet; cut when the change ends. Not saved, not compared.
    var pendingPointers: [UUID: UUID] = [:]
    /// Version-3 elements this build couldn't read. Only until Task 8, which deletes the v3 bridge.
    var legacyUnread: [UnreadElement] = []

    init() {}

    init(tree: TreeContent) {
        self.tree = tree
    }

    /// The board's name. Nil until one has been suggested or typed.
    var title: String? {
        get { tree.title }
        set { tree.title = newValue }
    }

    var canvas: CanvasSettings {
        get { tree.settings }
        set { tree.settings = newValue }
    }

    /// The tree, and what couldn't be read. Pointers waiting for a change to end aren't compared.
    static func == (a: DesignContent, b: DesignContent) -> Bool {
        a.tree == b.tree && a.legacyUnread == b.legacyUnread
    }

    /// The pictures the design shows.
    var imageIDs: Set<UUID> {
        var ids: Set<UUID> = []
        forEachNode { node in
            if let id = node.content.imageID { ids.insert(id) }
        }
        return ids
    }

    /// Every string in what this version read but didn't understand: elements of kinds
    /// it doesn't know, and keys it doesn't know on elements, screens, the canvas and the
    /// design. Among them are the identifiers of drawings and pictures. The files they
    /// name are kept when the design is saved, so that the newer Layer that wrote them
    /// still finds them.
    var unreadNames: Set<String> {
        var names = legacyUnread.reduce(into: tree.unknownKeys.strings.union(canvas.unknownKeys.strings)) { $0.formUnion($1.json.strings) }
        for screen in tree.screens where !screen.unknownKeys.values.isEmpty { names.formUnion(screen.unknownKeys.strings) }
        forEachNode { node in
            if !node.unknownKeys.values.isEmpty { names.formUnion(node.unknownKeys.strings) }
        }
        return names
    }

    /// Forgets the keys read but not understood on the design, its canvas, screens and
    /// elements. In a design saved before version 3 they are keys earlier versions of Layer
    /// stopped using, not ones a newer Layer added, and aren't to be written back.
    mutating func forgetUnknownKeys() {
        tree.unknownKeys = UnknownKeys()
        tree.settings.unknownKeys = UnknownKeys()
        func forget(_ node: inout LayerNode) {
            node.unknownKeys = UnknownKeys()
            for index in node.children.indices { forget(&node.children[index]) }
        }
        for screen in tree.screens.indices {
            tree.screens[screen].unknownKeys = UnknownKeys()
            for index in tree.screens[screen].root.children.indices { forget(&tree.screens[screen].root.children[index]) }
        }
        for index in tree.canvas.indices { forget(&tree.canvas[index]) }
    }

    /// Every node on the screens, below their roots, and on the open canvas, each before what it holds.
    private func forEachNode(_ body: (LayerNode) -> Void) {
        func visit(_ node: LayerNode) {
            body(node)
            for child in node.children { visit(child) }
        }
        for screen in tree.screens { screen.root.children.forEach(visit) }
        tree.canvas.forEach(visit)
    }

    // MARK: Views of the list

    /// Everything on the board that isn't a screen, back to front, host by host: the screens'
    /// in their order, then the open canvas's. Each container is a group item just in front of
    /// what it holds, which points at it with `group`. Among elements on the same screen, or
    /// together on the open canvas, later ones sit on top; the order of two elements that share
    /// neither means nothing.
    var elements: [DesignElement] {
        TreeProjection.lower(tree, pending: pendingPointers).elements
    }

    /// Each screen with what is on it. Group items are left out, and each member is locked or
    /// hidden as it is with its groups: what reads this draws, exports and describes the
    /// members as they are, unaware of groups. See `Groups.swift`.
    ///
    /// Set, each screen keeps its root as it is, and a new one gets a free root. What each holds
    /// is lifted into it, with the group items it had that weren't given, every screen against
    /// the design as it was, so that what moves between them keeps what only the tree knows.
    var screens: [DesignScreen] {
        get { TreeProjection.lower(tree, pending: pendingPointers).screens }
        set {
            let given = Set(newValue.flatMap(\.elements).map(\.id))
            let lists = newValue.map { screen in (host: Optional(screen.id), elements: screen.elements + groupItems(on: screen.id, besides: given)) }
            let wanted = Set(newValue.map(\.id))
            let gone = tree.screens.filter { !wanted.contains($0.id) }
            let kept = Dictionary(tree.screens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Those it no longer has stay until the lift, where what has moved off them is found.
            tree.screens = newValue.map { view in
                var screen = kept[view.id] ?? Self.newScreen(view)
                Self.write(view, to: &screen)
                return screen
            } + gone
            tree.projectedSetHosts(lists, pending: &pendingPointers)
            let goneIDs = Set(gone.map(\.id))
            tree.screens.removeAll { goneIDs.contains($0.id) }
        }
    }

    /// The elements on the open canvas, outside every screen. Group items are left out, and
    /// each member is locked or hidden as it is with its groups, as in `screens`.
    var floating: [FloatingElement] {
        get { TreeProjection.lower(tree, pending: pendingPointers).floating }
        set {
            let given = Set(newValue.map(\.id))
            let list = newValue.map { floating in
                var element = floating.element
                element.scale = floating.scale
                return element
            }
            tree.projectedSetHost(nil, to: list + groupItems(on: nil, besides: given), pending: &pendingPointers)
        }
    }

    /// The group items on a screen, or on the open canvas, apart from any among `given`.
    private func groupItems(on host: DesignScreen.ID?, besides given: Set<DesignElement.ID>) -> [DesignElement] {
        children(of: host).filter { $0.kind == .group && !given.contains($0.id) }
    }

    /// One screen with what is on it, as `screens` shows it: group items left out, and each
    /// member locked or hidden as it is with its groups. `children(of:)` has the list as it is.
    func screen(_ id: DesignScreen.ID) -> DesignScreen? {
        guard let screen = tree.screens.first(where: { $0.id == id }) else { return nil }
        var view = TreeProjection.view(of: screen)
        view.elements = TreeProjection.lowerHostNodes(.screen(id), in: tree, pending: pendingPointers)
            .filter { !$0.node.isContainer }.map(\.shown)
        return view
    }

    func element(_ id: DesignElement.ID) -> DesignElement? {
        tree.projectedElement(id, pending: pendingPointers)
    }

    /// What is on a screen, or on the open canvas when `parent` is nil, back to front.
    func children(of parent: DesignScreen.ID?) -> [DesignElement] {
        TreeProjection.lowerHost(parent.map { .screen($0) } ?? .canvas, in: tree, pending: pendingPointers)
    }

    // MARK: Changing the list

    /// Puts an element on a screen, or on the open canvas when `parent` is nil, where it
    /// is drawn `scale` canvas points to each of its own. It goes on top of what is
    /// already there. Returns the element as it is kept.
    @discardableResult
    mutating func add(_ element: DesignElement, to parent: DesignScreen.ID?, scale: CGFloat? = nil) -> DesignElement {
        tree.projectedAdd(element, to: parent, scale: scale, pending: &pendingPointers)
    }

    /// Changes an element in place. What it is and what it is on stay as they are: use
    /// `move` for the second.
    mutating func update(_ id: DesignElement.ID, _ body: (inout DesignElement) -> Void) {
        tree.projectedUpdate(id, pending: &pendingPointers, body)
    }

    mutating func remove(_ ids: Set<DesignElement.ID>) {
        tree.projectedRemove(ids, pending: &pendingPointers)
    }

    /// Gives an element to another screen, or to the open canvas, at `frame` there. It
    /// goes on top of what is already there.
    mutating func move(_ id: DesignElement.ID, to parent: DesignScreen.ID?, scale: CGFloat? = nil, frame: CGRect) {
        tree.projectedMove(id, to: parent, scale: scale, frame: frame, pending: &pendingPointers)
    }

    /// Puts the elements on one screen, or on the open canvas, in a new order, back to
    /// front. `order` holds the same identifiers they have now.
    mutating func reorder(_ parent: DesignScreen.ID?, to order: [DesignElement.ID]) {
        tree.projectedReorder(parent, to: order, pending: &pendingPointers)
    }

    /// Replaces what is on a screen. Its group items that `children` doesn't hold stay on it,
    /// after the rest; those it holds aren't written twice (F8). The groups are put in front
    /// of their members as the list is lifted into the tree.
    mutating func setChildren(of screen: DesignScreen.ID, to children: [DesignElement]) {
        let kept = groupItems(on: screen, besides: Set(children.map(\.id)))
        tree.projectedSetHost(screen, to: children + kept, asKept: true, pending: &pendingPointers)
    }

    /// Adds a screen, with whatever it holds. Its root is free.
    mutating func addScreen(_ screen: DesignScreen) {
        tree.screens.append(Self.newScreen(screen))
        guard !screen.elements.isEmpty else { return }
        tree.projectedSetHost(screen.id, to: screen.elements, asKept: true, pending: &pendingPointers)
    }

    /// Removes a screen and everything on it.
    mutating func removeScreen(_ id: DesignScreen.ID) {
        tree.screens.removeAll { $0.id == id }
    }

    /// Changes a screen. `body` is given the screen with what is on it, and may change that too.
    mutating func updateScreen(_ id: DesignScreen.ID, _ body: (inout DesignScreen) -> Void) {
        guard let index = tree.screens.firstIndex(where: { $0.id == id }) else { return }
        let before = children(of: id)
        var screen = TreeProjection.view(of: tree.screens[index])
        screen.elements = before
        body(&screen)
        Self.write(screen, to: &tree.screens[index])
        if screen.elements != before { setChildren(of: id, to: screen.elements) }
    }

    /// A screen new to the tree, as a view gives it: with a free root, and nothing on it yet.
    /// The root takes the screen's identifier, as the version-3 file keeps no identifier of
    /// its own for it, so that a design saved and read back is the same tree.
    private static func newScreen(_ view: DesignScreen) -> TreeScreen {
        var screen = TreeScreen(name: view.name, origin: view.origin, scale: view.scale, deviceID: view.deviceID)
        screen.id = view.id
        screen.root.id = view.id
        write(view, to: &screen)
        return screen
    }

    /// A screen's own fields, as a view gives them, written over the tree's screen. Its root,
    /// and what is on it, stay as they are, and so does its identifier.
    private static func write(_ view: DesignScreen, to screen: inout TreeScreen) {
        screen.name = view.name
        screen.origin = view.origin
        screen.scale = view.scale
        screen.deviceID = view.deviceID
        screen.isLocked = view.isLocked
        screen.unknownKeys = view.unknownKeys
    }

    // MARK: Taking a change back

    /// The screens themselves, without what is on them.
    var screenFrames: [DesignScreen] { tree.screens.map(TreeProjection.view(of:)) }

    /// Elements that say they are on a screen the design doesn't have. The tree can't hold
    /// any: what an undo leaves on a screen that has gone lands on the open canvas.
    var elementsOnMissingScreens: [DesignElement.ID] { [] }

    /// Whether the board itself differs: its name, its canvas, or what wasn't understood.
    func boardDiffers(from other: DesignContent) -> Bool {
        title != other.title || canvas != other.canvas || legacyUnread != other.legacyUnread
            || tree.unknownKeys != other.tree.unknownKeys || tree.manifestUnknownKeys != other.tree.manifestUnknownKeys
    }

    /// This content with the change that turned `before` into `after` taken back, and only
    /// that change: whatever has changed since `after` stays as it is now. With nothing
    /// else changed since, that is `before` itself. See `TreeContent.reverting(_:to:)`.
    ///
    /// An undo step is taken back this way, so that a step made while something else was
    /// changing the design too (a screen being written, a spoken command, a drag) takes
    /// back its own changes and leaves the others'.
    func reverting(_ after: DesignContent, to before: DesignContent) -> DesignContent {
        var result = DesignContent(tree: tree.reverting(after.tree, to: before.tree))
        result.legacyUnread = after.legacyUnread != before.legacyUnread ? before.legacyUnread : legacyUnread
        return result
    }

    /// Takes back the change that turned `before` into `after`, as far as what it changed
    /// is still as the change left it. Whatever has been changed since, the same things
    /// included, is left as it is now. Siri's undo of an action taken a while ago works this
    /// way, so that it doesn't take back what was done by hand meanwhile. See
    /// `TreeContent.takeBack(_:to:)`.
    mutating func takeBack(_ after: DesignContent, to before: DesignContent) {
        tree.takeBack(after.tree, to: before.tree)
        if before.legacyUnread != after.legacyUnread, legacyUnread == after.legacyUnread { legacyUnread = before.legacyUnread }
    }
}

private extension DesignElement {
    func placed(on parent: DesignScreen.ID?, scale: CGFloat?) -> DesignElement {
        var element = self
        element.parent = parent
        element.scale = scale
        return element
    }
}

/// The list operations that the projection's writes run on a host's lowered list, as the
/// design's one list ran them (F15).
extension [DesignElement] {
    /// `element` as `add` and `move` put it on a screen, or on the open canvas when `parent` is nil:
    /// said to be there, drawn `scale` canvas points to each of its own on the open canvas (1 when
    /// not given), and with no scale of its own on a screen, which has one.
    static func placed(_ element: DesignElement, on parent: DesignScreen.ID?, scale: CGFloat?) -> DesignElement {
        element.placed(on: parent, scale: parent == nil ? scale ?? 1 : nil)
    }

    /// Puts the elements at `slots` in a new order, back to front: `order` holds the identifiers
    /// they have now. The rest of the list keeps its places. Only the slots whose element changes
    /// are written, and counted as written; their number is returned. Two with one identifier, which
    /// only a damaged file has, can't be told apart: then, as when `order` doesn't hold exactly what
    /// is at `slots`, nothing changes.
    @discardableResult
    static func reorder(_ list: inout [DesignElement], slots: [Int], to order: [DesignElement.ID]) -> Int {
        let siblings = Dictionary(slots.map { (list[$0].id, list[$0]) }, uniquingKeysWith: { first, _ in first })
        guard siblings.count == slots.count, order.count == slots.count, Set(order) == Set(siblings.keys) else { return 0 }
        var written = 0
        for (slot, id) in zip(slots, order) where list[slot].id != id {
            if let element = siblings[id] {
                list[slot] = element
                written += 1
            }
        }
        #if DEBUG
        ListWork.wrote(written)
        #endif
        return written
    }
}

// PROJECTION: deleted in plan 6
/// The version-3 file, kept through the projection until the file moves to version 4 (Task 8):
/// the screens without what is on them, and one list of elements, `elements`, which is the tree
/// lowered as `elements` shows it, with the elements this build couldn't read back at their
/// places in it.
extension DesignContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case screens, elements, floating, title, canvas
    }

    /// Reads every part that is present, so designs saved before a part existed still
    /// open. Until version 3 each screen held its own elements and those on the open
    /// canvas were a list of their own, `floating`. Each host's elements are lifted into the
    /// tree, and the tree's rules run, so that a design edited elsewhere, or saved by a build
    /// that doesn't know groups, opens sound: a member of a group that has gone opens
    /// ungrouped (Review Focus 4).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let screens = try container.decodeIfPresent([DesignScreen].self, forKey: .screens) ?? []
        self.init()
        title = try container.decodeIfPresent(String.self, forKey: .title)
        canvas = try container.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? CanvasSettings()
        tree.unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
        if container.contains(.elements) {
            let (elements, unread) = try DesignElement.readList(in: container, forKey: .elements)
            legacyUnread = unread
            var hosts: [DesignScreen.ID?: [DesignElement]] = [:]
            var known: Set<DesignScreen.ID> = []
            for screen in screens where known.insert(screen.id).inserted {
                var frame = screen
                frame.elements = []
                addScreen(frame)
            }
            for element in elements {
                // One on a screen the design doesn't have, which only a damaged file has, is put
                // on the open canvas where its frame says, as an undo puts one whose screen is gone.
                guard let parent = element.parent, known.contains(parent) else {
                    var loose = element
                    if loose.parent != nil { loose.scale = 1 }
                    hosts[nil, default: []].append(loose)
                    continue
                }
                hosts[parent, default: []].append(element)
            }
            tree.projectedSetHosts(hosts.map { (host: $0.key, elements: $0.value) }, asKept: true, pending: &pendingPointers)
        } else {
            for screen in screens { addScreen(screen) }
            floating = try container.decodeIfPresent([FloatingElement].self, forKey: .floating) ?? []
        }
        keepGroupsSound()
    }

    func encode(to encoder: any Encoder) throws {
        try tree.unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(screenFrames, forKey: .screens)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(WithUnknownKeys(canvas), forKey: .canvas)

        // Elements this version couldn't read go back where they were among the others.
        var list = container.nestedUnkeyedContainer(forKey: .elements)
        var kept = legacyUnread[...]
        var written = 0
        func writeUnread(all: Bool = false) throws {
            while let next = kept.first, all || next.index <= written {
                try list.encode(next.json)
                kept = kept.dropFirst()
                written += 1
            }
        }
        for element in elements {
            try writeUnread()
            try list.encode(WithUnknownKeys(element))
            written += 1
        }
        try writeUnread(all: true)
    }
}

/// Everything saved in a `.layer` document.
///
/// On disk a design is a package, a folder that Files shows as one document:
///
///     design.json               the screens, elements, title and canvas settings
///     ink/<id>                  each drawing's ink, as PencilKit writes it
///     images/<id>               attached pictures, as they were imported
///     QuickLook/Thumbnail.jpg   a picture of the board, for the document browser
///
/// Keeping the parts apart is what makes saving and syncing cheap. An edit rewrites the
/// small design file; a drawing's ink is rewritten only when that drawing changes; and
/// pictures, which never change once attached, are written and uploaded to iCloud once
/// rather than on every save.
struct DesignFile: Sendable {
    enum ReadError: LocalizedError {
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .newerVersion: "This design was saved by a newer version of Layer. Update Layer to open it."
            }
        }
    }

    /// Version 1 was a single JSON file with the ink and pictures inside it. Version 2
    /// made it a package, with each screen holding its own elements and all the ink as
    /// one drawing. Version 3 keeps the elements in one list, each saying what it is on,
    /// and the ink as drawings in that list. Earlier versions still open, and are saved
    /// as version 3.
    static let currentVersion = 3

    var version = currentVersion
    /// The design, its drawings' ink included. Magic Pen sketches are never saved: they
    /// either become elements or disappear.
    var content = DesignContent()
    /// All the ink that shows on the board, where it lies on the canvas.
    var drawing: PKDrawing { content.visibleInk }
    /// Attached pictures, as image file data, by the UUID that elements refer to them with.
    var images: [String: Data] = [:]
    /// A small picture of the board, as JPEG data. Nil for a board with nothing on it.
    var preview: Data?
    /// The name the file had when the app last looked. A different name on disk means
    /// the file was renamed somewhere else, in Files for instance.
    var fileName: String?
    /// The ink of drawings this version couldn't read, as it was read, by file name. It
    /// is written back for as long as those drawings are in the design.
    var unreadInk: [String: Data] = [:]
    /// Parts of the package this version doesn't know, which a newer Layer may have added,
    /// as they were read. They are written back unchanged.
    var unknownParts: [String: PackagePart] = [:]
    /// Keys at the top of the design's file that this version doesn't know, to be written back.
    var unknownKeys = UnknownKeys()

    /// The names of drawings and pictures that what this version couldn't read refers to.
    private var unreadNames: Set<String> {
        content.unreadNames.union(unknownKeys.strings)
    }

    /// `drawing` is ink for the board as one PencilKit drawing, which is taken in as
    /// drawings: strokes that touch become one drawing each.
    init(content: DesignContent = DesignContent(), drawing: PKDrawing = PKDrawing(), images: [String: Data] = [:]) {
        self.content = content
        self.content.adopt(drawing)
        self.images = images
    }

    // MARK: Reading

    /// Reads a design from what the system hands over when a document opens.
    init(wrapper: FileWrapper) throws {
        guard wrapper.isDirectory else {
            // Version 1: one file.
            guard let data = wrapper.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            try self.init(singleFile: data)
            return
        }
        let parts = wrapper.fileWrappers ?? [:]
        guard let data = parts[DesignPackage.design]?.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        // A newer design may hold things this version would silently drop on the next save.
        guard manifest.version <= Self.currentVersion else { throw ReadError.newerVersion(manifest.version) }
        self.init()
        content = manifest.content
        fileName = manifest.fileName
        unknownKeys = manifest.unknownKeys
        // What a design from before version 3 has that this version doesn't know, earlier
        // versions put there.
        if manifest.version < 3 {
            content.forgetUnknownKeys()
            unknownKeys = UnknownKeys()
        }
        // Each drawing's ink is beside the design, under the drawing's identifier.
        let ink = parts[DesignPackage.ink]?.fileWrappers ?? [:]
        for drawing in content.elements where drawing.kind == .drawing {
            let strokes = ink[drawing.id.uuidString]?.regularFileContents
            content.update(drawing.id) { $0.ink = strokes }
        }
        // So is the ink of drawings this version can't read, which is kept for writing back.
        let named = unreadNames
        for (name, strokes) in ink where named.contains(name) {
            unreadInk[name] = strokes.regularFileContents
        }
        for (name, part) in parts where !Self.knownParts.contains(name) {
            unknownParts[name] = PackagePart(part)
        }
        // Until version 3 all the ink was one drawing.
        if manifest.version < 3, let whole = parts[DesignPackage.drawing]?.regularFileContents {
            content.adopt(try PKDrawing(data: whole))
        }
        for (name, picture) in parts[DesignPackage.images]?.fileWrappers ?? [:] {
            images[name] = picture.regularFileContents
        }
        preview = parts[DesignPackage.quickLook]?.fileWrappers?[DesignPackage.thumbnail]?.regularFileContents
    }

    /// Reads a version 1 design, which was a single JSON file.
    init(singleFile data: Data) throws {
        let old = try JSONDecoder().decode(SingleFile.self, from: data)
        guard old.version <= Self.currentVersion else { throw ReadError.newerVersion(old.version) }
        self.init()
        content = old.content
        content.forgetUnknownKeys()
        content.adopt(old.drawing)
        images = old.images ?? [:]
    }

    // MARK: Writing

    /// The design as a package, ready to be written. Parts that are already on disk
    /// unchanged are handed back as they are, which leaves their files untouched.
    /// Pictures that nothing in the design shows any more are left out. What this
    /// version doesn't understand, elements of a kind it doesn't know and parts of the
    /// package it has never heard of, is written back with the files it names.
    func wrapper(replacing existing: FileWrapper? = nil) throws -> FileWrapper {
        let old = existing?.isDirectory == true ? existing?.fileWrappers ?? [:] : [:]
        var parts: [String: FileWrapper] = [:]

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let manifest = Manifest(version: version, content: content, fileName: fileName, unknownKeys: unknownKeys)
        parts[DesignPackage.design] = Self.file(try encoder.encode(WithUnknownKeys(manifest)), named: DesignPackage.design, onDisk: old[DesignPackage.design])

        // A drawing whose ink is on disk unchanged keeps its file.
        let savedInk = old[DesignPackage.ink]?.fileWrappers ?? [:]
        var ink: [String: FileWrapper] = [:]
        for drawing in content.elements where drawing.kind == .drawing {
            guard let strokes = drawing.ink else { continue }
            let name = drawing.id.uuidString
            ink[name] = Self.file(strokes, named: name, onDisk: savedInk[name])
        }
        // What this version couldn't read keeps the ink and pictures it names.
        let named = unreadNames
        for (name, strokes) in unreadInk where ink[name] == nil && named.contains(name) {
            ink[name] = Self.file(strokes, named: name, onDisk: savedInk[name])
        }
        if !ink.isEmpty {
            parts[DesignPackage.ink] = Self.folder(ink, named: DesignPackage.ink)
        }

        let shown = Set(content.imageIDs.map(\.uuidString)).union(named)
        let savedPictures = old[DesignPackage.images]?.fileWrappers ?? [:]
        var pictures: [String: FileWrapper] = [:]
        for (name, data) in images where shown.contains(name) {
            // A picture never changes once attached, so one that is on disk is right.
            pictures[name] = savedPictures[name] ?? Self.file(data, named: name, onDisk: nil)
        }
        if !pictures.isEmpty {
            parts[DesignPackage.images] = Self.folder(pictures, named: DesignPackage.images)
        }

        if let preview {
            let saved = old[DesignPackage.quickLook]?.fileWrappers?[DesignPackage.thumbnail]
            parts[DesignPackage.quickLook] = Self.folder([DesignPackage.thumbnail: Self.file(preview, named: DesignPackage.thumbnail, onDisk: saved)], named: DesignPackage.quickLook)
        }

        // Parts a newer Layer added stay as they are: as on disk when they are, or as read.
        for name in Set(unknownParts.keys).union(old.keys) where !Self.knownParts.contains(name) {
            parts[name] = old[name] ?? unknownParts[name]?.wrapper(named: name)
        }
        return FileWrapper(directoryWithFileWrappers: parts)
    }

    /// The parts of a package this version knows what to do with. Anything else in one is
    /// kept as it is.
    private static let knownParts: Set<String> = [
        DesignPackage.design, DesignPackage.ink, DesignPackage.drawing, DesignPackage.images, DesignPackage.quickLook,
    ]

    private static func file(_ data: Data, named name: String, onDisk saved: FileWrapper?) -> FileWrapper {
        if let saved, saved.isRegularFile, saved.regularFileContents == data { return saved }
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = name
        return wrapper
    }

    private static func folder(_ children: [String: FileWrapper], named name: String) -> FileWrapper {
        let wrapper = FileWrapper(directoryWithFileWrappers: children)
        wrapper.preferredFilename = name
        return wrapper
    }

    // MARK: On disk

    private struct Manifest: Codable, KeepsUnknownKeys {
        var version: Int
        var content: DesignContent
        var fileName: String?
        var unknownKeys = UnknownKeys()

        enum CodingKeys: String, CodingKey {
            case version, content, fileName
        }

        init(version: Int, content: DesignContent, fileName: String?, unknownKeys: UnknownKeys) {
            self.version = version
            self.content = content
            self.fileName = fileName
            self.unknownKeys = unknownKeys
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            content = try container.decode(DesignContent.self, forKey: .content)
            fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
        }
    }

    private struct SingleFile: Decodable {
        var version: Int
        var content: DesignContent
        var drawing: PKDrawing
        var images: [String: Data]?
    }

    /// Just the version and content of a version 1 file, without decoding its ink.
    private struct SingleFileContent: Decodable {
        var version: Int
        var content: DesignContent
    }

    /// Reads only a design's screens, elements, title and canvas settings from its file,
    /// leaving the ink and pictures where they are: what Siri, Shortcuts and Spotlight need.
    /// Reads the disk, so not for the main thread.
    nonisolated static func content(at url: URL) throws -> DesignContent {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if isDirectory.boolValue {
            let data = try Data(contentsOf: url.appendingPathComponent(DesignPackage.design))
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version <= currentVersion else { throw ReadError.newerVersion(manifest.version) }
            return manifest.content
        }
        let old = try JSONDecoder().decode(SingleFileContent.self, from: Data(contentsOf: url))
        guard old.version <= currentVersion else { throw ReadError.newerVersion(old.version) }
        return old.content
    }
}

/// A part of a design's package that this version of Layer doesn't know, kept as it was
/// read so that saving writes it back: a file's bytes, or a folder of further parts.
enum PackagePart: Equatable, Sendable {
    case file(Data)
    case folder([String: PackagePart])

    /// Nil for what is neither a file nor a folder, such as a symbolic link.
    init?(_ wrapper: FileWrapper) {
        if wrapper.isRegularFile, let data = wrapper.regularFileContents {
            self = .file(data)
        } else if wrapper.isDirectory {
            self = .folder((wrapper.fileWrappers ?? [:]).compactMapValues(PackagePart.init))
        } else {
            return nil
        }
    }

    func wrapper(named name: String) -> FileWrapper {
        let wrapper = switch self {
        case .file(let data):
            FileWrapper(regularFileWithContents: data)
        case .folder(let parts):
            FileWrapper(directoryWithFileWrappers: Dictionary(uniqueKeysWithValues: parts.map { ($0.key, $0.value.wrapper(named: $0.key)) }))
        }
        wrapper.preferredFilename = name
        return wrapper
    }
}
