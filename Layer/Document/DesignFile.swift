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

    /// The tree, with what it couldn't read. Pointers waiting for a change to end aren't compared.
    static func == (a: DesignContent, b: DesignContent) -> Bool {
        a.tree == b.tree
    }

    /// The pictures the design shows.
    var imageIDs: Set<UUID> {
        var ids: Set<UUID> = []
        forEachNode { node in
            if let id = node.content.imageID { ids.insert(id) }
        }
        return ids
    }

    /// Every string in what this version read but didn't understand: nodes of kinds it
    /// doesn't know, on the canvas and inside containers; screens it can't read; custom frames
    /// it can't use; and keys it doesn't know on nodes and inside their parts, on screens, the
    /// settings, the design and its file. Among them are
    /// the identifiers of drawings and pictures. The files they name are kept when the design
    /// is saved, so that the newer Layer that wrote them still finds them.
    var unreadNames: Set<String> {
        var names = tree.unknownKeys.strings.union(tree.manifestUnknownKeys.strings)
        let settings = tree.settings
        names.formUnion(settings.unknownKeys.strings)
        names.formUnion(settings.tokens.unknownKeys.strings)
        for device in settings.customDevices where !device.unknownKeys.values.isEmpty { names.formUnion(device.unknownKeys.strings) }
        for json in settings.unreadDevices { names.formUnion(json.strings) }
        for unread in tree.unreadCanvas { names.formUnion(unread.raw.strings) }
        for unread in tree.unreadScreens { names.formUnion(unread.raw.strings) }
        func visit(_ node: LayerNode) {
            if !node.unknownKeys.values.isEmpty { names.formUnion(node.unknownKeys.strings) }
            for keys in node.unknownPartKeys.values { names.formUnion(keys.strings) }
            for unread in node.unreadChildren { names.formUnion(unread.raw.strings) }
            node.children.forEach(visit)
        }
        for screen in tree.screens {
            if !screen.unknownKeys.values.isEmpty { names.formUnion(screen.unknownKeys.strings) }
            visit(screen.root)
        }
        tree.canvas.forEach(visit)
        return names
    }

    /// Every node on the screens, below their roots, and on the open canvas, each before what it holds.
    fileprivate func forEachNode(_ body: (LayerNode) -> Void) {
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
        let device = tree.device(of: screen)
        if device != view.device { view.resolvedDevice = device }
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
    /// The root takes the screen's identifier, so that a screen made from the same view twice
    /// is the same tree.
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
        title != other.title || canvas != other.canvas || tree.unreadCanvas != other.tree.unreadCanvas
            || tree.unreadScreens != other.tree.unreadScreens
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
        DesignContent(tree: tree.reverting(after.tree, to: before.tree))
    }

    /// Takes back the change that turned `before` into `after`, as far as what it changed
    /// is still as the change left it. Whatever has been changed since, the same things
    /// included, is left as it is now. Siri's undo of an action taken a while ago works this
    /// way, so that it doesn't take back what was done by hand meanwhile. See
    /// `TreeContent.takeBack(_:to:)`.
    mutating func takeBack(_ after: DesignContent, to before: DesignContent) {
        tree.takeBack(after.tree, to: before.tree)
    }
}

// PROJECTION: deleted in plan 6
private extension DesignElement {
    func placed(on parent: DesignScreen.ID?, scale: CGFloat?) -> DesignElement {
        var element = self
        element.parent = parent
        element.scale = scale
        return element
    }
}

// PROJECTION: deleted in plan 6
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
/// A design's content is coded as its tree is: `TreeContent`'s coding, exactly. The file reads
/// and writes the tree through `TreeManifest`; this is for what codes the content on its own.
/// Reading runs no rules: opening a file does (`DesignFile`).
extension DesignContent: Codable {
    init(from decoder: any Decoder) throws {
        self.init(tree: try TreeContent(from: decoder))
    }

    func encode(to encoder: any Encoder) throws {
        try tree.encode(to: encoder)
    }
}

/// Everything saved in a `.layer` document.
///
/// On disk a design is a package, a folder that Files shows as one document:
///
///     design.json               the screens, each holding its tree, the canvas's nodes, title and settings
///     ink/<id>                  each drawing's ink, as PencilKit writes it
///     images/<id>               attached pictures, as they were imported
///     QuickLook/Thumbnail.jpg   a picture of the board, for the document browser
///
/// Keeping the parts apart is what makes saving and syncing cheap. An edit rewrites the
/// small design file; a drawing's ink is rewritten only when that drawing changes; and
/// pictures, which never change once attached, are written and uploaded to iCloud once
/// rather than on every save.
struct DesignFile: Sendable {
    typealias ReadError = TreeManifest.ReadError

    /// Version 4 saves the design as its tree: each screen's root holding what is on the
    /// screen, and the canvas's own nodes. A design saved by an earlier version is refused with
    /// a message saying so, and one saved by a newer version with a message asking for an update.
    static let currentVersion = TreeManifest.version

    /// The version written: this one's, unless a test writes a design from another.
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

    /// `drawing` is ink for the board as one PencilKit drawing, which is taken in as
    /// drawings: strokes that touch become one drawing each.
    init(content: DesignContent = DesignContent(), drawing: PKDrawing = PKDrawing(), images: [String: Data] = [:]) {
        self.content = content
        self.content.adopt(drawing)
        self.images = images
    }

    // MARK: Reading

    /// Reads a design from what the system hands over when a document opens. Only a package
    /// of version 4 opens; the design's saved frames are laid out again as it does (My call 18).
    init(wrapper: FileWrapper) throws {
        guard wrapper.isDirectory else { throw Self.refusal(ofSingleFile: wrapper.regularFileContents) }
        let parts = wrapper.fileWrappers ?? [:]
        guard let data = parts[DesignPackage.design]?.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.init()
        (content, fileName) = try Self.read(data)
        // Each drawing's ink is beside the design, under the drawing's identifier. The rules
        // have put every drawing among the canvas's nodes.
        let ink = parts[DesignPackage.ink]?.fileWrappers ?? [:]
        for index in content.tree.canvas.indices where content.tree.canvas[index].kind == .drawing {
            content.tree.canvas[index].content.ink = ink[content.tree.canvas[index].id.uuidString]?.regularFileContents
        }
        // So is the ink of drawings this version can't read, which is kept for writing back.
        let named = content.unreadNames
        for (name, strokes) in ink where named.contains(name) {
            unreadInk[name] = strokes.regularFileContents
        }
        for (name, part) in parts where !Self.knownParts.contains(name) {
            unknownParts[name] = PackagePart(part)
        }
        for (name, picture) in parts[DesignPackage.images]?.fileWrappers ?? [:] {
            images[name] = picture.regularFileContents
        }
        preview = parts[DesignPackage.quickLook]?.fileWrappers?[DesignPackage.thumbnail]?.regularFileContents
    }

    /// The design in a package's design file, with the tree's rules applied: the frames it was
    /// saved with are a snapshot, and each screen is laid out again. That is no change, and
    /// makes no undo step.
    private static func read(_ data: Data) throws -> (content: DesignContent, fileName: String?) {
        var (tree, fileName) = try TreeManifest.decode(data)
        TreeRules.apply(to: &tree, after: nil)
        return (DesignContent(tree: tree), fileName)
    }

    /// Why a single file can't be opened: only version 1 saved a design as one file. Its JSON
    /// says which version it is; something that doesn't can't be read.
    private static func refusal(ofSingleFile data: Data?) -> ReadError {
        guard let data, let header = try? JSONDecoder().decode(SingleFileHeader.self, from: data) else { return .unreadable }
        return .olderVersion(header.version)
    }

    private struct SingleFileHeader: Decodable {
        var version: Int
    }

    // MARK: Writing

    /// The design as a package, ready to be written. Parts that are already on disk
    /// unchanged are handed back as they are, which leaves their files untouched.
    /// Pictures that nothing in the design shows any more are left out. What this
    /// version doesn't understand, nodes of a kind it doesn't know and parts of the
    /// package it has never heard of, is written back with the files it names.
    func wrapper(replacing existing: FileWrapper? = nil) throws -> FileWrapper {
        let old = existing?.isDirectory == true ? existing?.fileWrappers ?? [:] : [:]
        var parts: [String: FileWrapper] = [:]

        let design = try TreeManifest.encode(content.tree, fileName: fileName, version: version)
        parts[DesignPackage.design] = Self.file(design, named: DesignPackage.design, onDisk: old[DesignPackage.design])

        // A drawing whose ink is on disk unchanged keeps its file.
        let savedInk = old[DesignPackage.ink]?.fileWrappers ?? [:]
        var ink: [String: FileWrapper] = [:]
        // Wherever a drawing is, though the rules keep them all among the canvas's nodes.
        content.forEachNode { drawing in
            guard drawing.kind == .drawing, let strokes = drawing.content.ink else { return }
            let name = drawing.id.uuidString
            ink[name] = Self.file(strokes, named: name, onDisk: savedInk[name])
        }
        // What this version couldn't read keeps the ink and pictures it names.
        let named = content.unreadNames
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
        DesignPackage.design, DesignPackage.ink, DesignPackage.images, DesignPackage.quickLook,
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

    /// Reads only a design's screens, the nodes on them and on the canvas, its title and
    /// settings from its file, leaving the ink and pictures where they are: what Siri, Shortcuts
    /// and Spotlight need. The tree's rules are applied, as on opening. A design this version
    /// can't open throws as opening it does. Reads the disk, so not for the main thread.
    nonisolated static func content(at url: URL) throws -> DesignContent {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard isDirectory.boolValue else { throw refusal(ofSingleFile: try Data(contentsOf: url)) }
        return try read(Data(contentsOf: url.appendingPathComponent(DesignPackage.design))).content
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
