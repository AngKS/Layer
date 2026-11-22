import Foundation
import PencilKit
import UniformTypeIdentifiers

extension UTType {
    /// A Layer design, saved with the `.layer` extension. Declared in the app's Info.plist.
    static let layerDesign = UTType(exportedAs: "kahshin.layer.design")
}

/// The part of a design that the design tools edit: its screens, everything on them and
/// on the open canvas, its title and how its canvas is set up.
///
/// Everything that isn't a screen is kept in one list, `elements`, and each element says
/// what it is on. `screens` and `floating` are views of that list: each screen with the
/// elements on it, and the elements on the open canvas. Reading them is how most of the
/// app sees a design; changing the list is done with the methods below, or by setting
/// either view whole.
struct DesignContent: Equatable, Sendable {
    /// The screens themselves, without what is on them.
    private var frames: [DesignScreen] = []
    /// Everything on the board that isn't a screen, back to front. Among elements on the
    /// same screen, or together on the open canvas, later ones sit on top; the order of
    /// two elements that share neither means nothing.
    private(set) var elements: [DesignElement] = []
    /// Elements that were read but not understood, to be written back where they were.
    private var unread: [UnreadElement] = []
    /// The board's name. Nil until one has been suggested or typed.
    var title: String?
    var canvas = CanvasSettings()
    /// What a newer Layer saved with the design that this version doesn't know, to be
    /// written back with it.
    private var unknownKeys = UnknownKeys()

    init() {}

    /// The pictures the design shows.
    var imageIDs: Set<UUID> {
        Set(elements.compactMap(\.imageID))
    }

    /// Every string in what this version read but didn't understand: elements of kinds
    /// it doesn't know, and keys it doesn't know on elements, screens, the canvas and the
    /// design. Among them are the identifiers of drawings and pictures. The files they
    /// name are kept when the design is saved, so that the newer Layer that wrote them
    /// still finds them.
    var unreadNames: Set<String> {
        var names = unread.reduce(into: unknownKeys.strings.union(canvas.unknownKeys.strings)) { $0.formUnion($1.json.strings) }
        for screen in frames where !screen.unknownKeys.values.isEmpty { names.formUnion(screen.unknownKeys.strings) }
        for element in elements where !element.unknownKeys.values.isEmpty { names.formUnion(element.unknownKeys.strings) }
        return names
    }

    /// Forgets the keys read but not understood on the design, its canvas, screens and
    /// elements. In a design saved before version 3 they are keys earlier versions of Layer
    /// stopped using, not ones a newer Layer added, and aren't to be written back.
    mutating func forgetUnknownKeys() {
        unknownKeys = UnknownKeys()
        canvas.unknownKeys = UnknownKeys()
        for index in frames.indices { frames[index].unknownKeys = UnknownKeys() }
        for index in elements.indices { elements[index].unknownKeys = UnknownKeys() }
    }

    // MARK: Views of the list

    /// Each screen with what is on it. Group items are left out, and each member is locked or
    /// hidden as it is with its groups: what reads this draws, exports and describes the
    /// members as they are, unaware of groups. See `Groups.swift`.
    var screens: [DesignScreen] {
        get {
            guard !frames.isEmpty else { return [] }
            let groups = groupItemsByID
            var onScreen: [DesignScreen.ID: [DesignElement]] = [:]
            for element in elements where element.kind != .group {
                if let parent = element.parent { onScreen[parent, default: []].append(Self.shown(element, groups: groups)) }
            }
            return frames.map { frame in
                var screen = frame
                screen.elements = onScreen[frame.id] ?? []
                return screen
            }
        }
        set {
            let groups = groupItemsByID
            let stored = storedForWritingBack(groups)
            let loose = elements.filter { $0.parent == nil }
            let kept = groupItems(besides: newValue.flatMap(\.elements))
            frames = newValue.map(\.withoutElements)
            // The group items each screen had go back on it, after what it now holds: the
            // groups are put in front of their members, or taken away, by `keepGroupsSound()`.
            elements = newValue.flatMap { screen in
                screen.elements.map { Self.written($0, over: stored[$0.id], groups: groups).placed(on: screen.id, scale: nil) }
                    + kept.filter { $0.parent == screen.id }
            } + loose
        }
    }

    /// The elements on the open canvas, outside every screen. Group items are left out, and
    /// each member is locked or hidden as it is with its groups, as in `screens`.
    var floating: [FloatingElement] {
        get {
            let groups = groupItemsByID
            return elements.filter { $0.parent == nil && $0.kind != .group }.map { FloatingElement(element: Self.shown($0, groups: groups), scale: $0.scale ?? 1) }
        }
        set {
            let groups = groupItemsByID
            let stored = storedForWritingBack(groups)
            let kept = groupItems(besides: newValue.map(\.element)).filter { $0.parent == nil }
            elements = elements.filter { $0.parent != nil }
                + newValue.map { Self.written($0.element, over: stored[$0.id], groups: groups).placed(on: nil, scale: $0.scale) }
                + kept
        }
    }

    /// Each element as it is kept, by identifier, when there are groups whose lock and hide a
    /// view showed on their members; otherwise nothing, as there is nothing to tell apart.
    private func storedForWritingBack(_ groups: [DesignElement.ID: DesignElement]) -> [DesignElement.ID: DesignElement] {
        guard !groups.isEmpty else { return [:] }
        var stored: [DesignElement.ID: DesignElement] = [:]
        for element in elements where stored[element.id] == nil { stored[element.id] = element }
        return stored
    }

    /// The group items the design has, apart from any among `given`.
    private func groupItems(besides given: [DesignElement]) -> [DesignElement] {
        let items = elements.filter { $0.kind == .group }
        guard !items.isEmpty else { return [] }
        let ids = Set(given.map(\.id))
        return items.filter { !ids.contains($0.id) }
    }

    /// One screen with what is on it, as `screens` shows it: group items left out, and each
    /// member locked or hidden as it is with its groups. `children(of:)` has the list as it is.
    func screen(_ id: DesignScreen.ID) -> DesignScreen? {
        guard var screen = frames.first(where: { $0.id == id }) else { return nil }
        let groups = groupItemsByID
        screen.elements = children(of: id).filter { $0.kind != .group }.map { Self.shown($0, groups: groups) }
        return screen
    }

    func element(_ id: DesignElement.ID) -> DesignElement? {
        elements.first { $0.id == id }
    }

    /// What is on a screen, or on the open canvas when `parent` is nil, back to front.
    func children(of parent: DesignScreen.ID?) -> [DesignElement] {
        elements.filter { $0.parent == parent }
    }

    // MARK: Changing the list

    /// Puts an element on a screen, or on the open canvas when `parent` is nil, where it
    /// is drawn `scale` canvas points to each of its own. It goes on top of what is
    /// already there. Returns the element as it is kept.
    @discardableResult
    mutating func add(_ element: DesignElement, to parent: DesignScreen.ID?, scale: CGFloat? = nil) -> DesignElement {
        let placed = element.placed(on: parent, scale: parent == nil ? scale ?? 1 : nil)
        elements.append(placed)
        return placed
    }

    /// Changes an element in place. What it is and what it is on stay as they are: use
    /// `move` for the second.
    mutating func update(_ id: DesignElement.ID, _ body: (inout DesignElement) -> Void) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        let before = elements[index]
        var element = before
        body(&element)
        element.id = before.id
        element.parent = before.parent
        element.scale = before.scale
        // Left as it was, as a drag's frame held on a snap is, the list isn't written to:
        // written, it is copied, only for the whole design to be compared and found the same.
        guard element != before else { return }
        elements[index] = element
    }

    mutating func remove(_ ids: Set<DesignElement.ID>) {
        elements.removeAll { ids.contains($0.id) }
    }

    /// Gives an element to another screen, or to the open canvas, at `frame` there. It
    /// goes on top of what is already there.
    mutating func move(_ id: DesignElement.ID, to parent: DesignScreen.ID?, scale: CGFloat? = nil, frame: CGRect) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        var element = elements.remove(at: index).placed(on: parent, scale: parent == nil ? scale ?? 1 : nil)
        element.frame = frame
        elements.append(element)
    }

    /// Puts the elements on one screen, or on the open canvas, in a new order, back to
    /// front. `order` holds the same identifiers they have now. Elements elsewhere keep
    /// their places in the list.
    mutating func reorder(_ parent: DesignScreen.ID?, to order: [DesignElement.ID]) {
        let slots = elements.indices.filter { elements[$0].parent == parent }
        let siblings = Dictionary(slots.map { (elements[$0].id, elements[$0]) }, uniquingKeysWith: { first, _ in first })
        // Two with one identifier, which only a damaged file has, can't be told apart: they stay as they are.
        guard siblings.count == slots.count, order.count == slots.count, Set(order) == Set(siblings.keys) else { return }
        for (slot, id) in zip(slots, order) {
            if let element = siblings[id] { elements[slot] = element }
        }
    }

    /// Replaces what is on a screen. Its group items that `children` doesn't hold stay on it,
    /// after the rest; those it holds aren't written twice (F8). The groups are then put in
    /// front of their members, or taken away, by `keepGroupsSound()`.
    mutating func setChildren(of screen: DesignScreen.ID, to children: [DesignElement]) {
        let kept = groupItems(besides: children).filter { $0.parent == screen }
        elements.removeAll { $0.parent == screen }
        elements += children.map { $0.placed(on: screen, scale: nil) } + kept
    }

    /// Adds a screen, with whatever it holds.
    mutating func addScreen(_ screen: DesignScreen) {
        frames.append(screen.withoutElements)
        elements += screen.elements.map { $0.placed(on: screen.id, scale: nil) }
    }

    /// Removes a screen and everything on it.
    mutating func removeScreen(_ id: DesignScreen.ID) {
        frames.removeAll { $0.id == id }
        elements.removeAll { $0.parent == id }
    }

    // MARK: Taking a change back

    /// The screens themselves, without what is on them.
    var screenFrames: [DesignScreen] { frames }

    /// Elements that say they are on a screen the design doesn't have. They are drawn
    /// nowhere, can't be touched and are left out of the code, so a design should never
    /// have any: tests check it after every undo and redo.
    var elementsOnMissingScreens: [DesignElement.ID] {
        let screens = Set(frames.map(\.id))
        return elements.filter { $0.parent.map { !screens.contains($0) } ?? false }.map(\.id)
    }

    /// Puts every element left on a screen the design no longer has onto the open canvas,
    /// where it was on that screen in `previous`, at the screen's scale, and takes the scale
    /// off anything on a screen, which has none of its own. Undo uses it: a step that took a
    /// screen away may leave there something another edit put on it meanwhile.
    mutating func rehostElementsOnMissingScreens(from previous: DesignContent) {
        let screens = Set(frames.map(\.id))
        for element in elements {
            guard let parent = element.parent, !screens.contains(parent) else { continue }
            guard let gone = previous.frames.first(where: { $0.id == parent }), gone.scale > 0 else {
                move(element.id, to: nil, scale: 1, frame: element.frame)
                continue
            }
            let onCanvas = gone.placement.canvasRect(for: element.frame)
            let origin = CGPoint(x: onCanvas.minX / gone.scale, y: onCanvas.minY / gone.scale)
            move(element.id, to: nil, scale: gone.scale, frame: CGRect(origin: origin, size: element.frame.size))
        }
        for index in elements.indices where elements[index].parent != nil && elements[index].scale != nil {
            elements[index].scale = nil
        }
    }

    /// Whether the board itself differs: its name, its canvas, or what wasn't understood.
    func boardDiffers(from other: DesignContent) -> Bool {
        title != other.title || canvas != other.canvas || unread != other.unread
    }

    /// This content with the change that turned `before` into `after` taken back, and only
    /// that change: whatever has changed since `after` stays as it is now. With nothing
    /// else changed since, that is `before` itself.
    ///
    /// An undo step is taken back this way, so that a step made while something else was
    /// changing the design too (a screen being written, a spoken command, a drag) takes
    /// back its own changes and leaves the others'.
    ///
    /// The board's name goes back only if it is still the one the change gave it. A name
    /// given since without a step, the file renamed in Files for instance, is the board's
    /// name now: put back, the file was renamed back to match (M4).
    func reverting(_ after: DesignContent, to before: DesignContent) -> DesignContent {
        if self == after { return before }
        var result = self
        if after.title != before.title, title == after.title { result.title = before.title }
        if after.canvas != before.canvas { result.canvas = before.canvas }
        if after.unread != before.unread { result.unread = before.unread }
        result.frames = Self.reverting(frames, after: after.frames, before: before.frames, id: \.id, fields: DesignScreen.reverting)
        result.elements = Self.reverting(elements, after: after.elements, before: before.elements, id: \.id, fields: DesignElement.reverting)
        return result
    }

    /// `current` with what turned `before` into `after` taken back: what was added goes;
    /// what was taken away comes back where it was; what was altered goes back to how it
    /// was; what was moved among the rest goes back where it was. Anything else, in
    /// `current` alone, stays.
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

        // Of what was there before and after, what the change moved among the rest: what
        // has something else just before it now.
        let stayedBefore = before.map(id).filter { kept[$0] != nil }
        let stayedAfter = after.map(id).filter { beforeIDs.contains($0) }
        var moved: Set<ID> = []
        if stayedBefore != stayedAfter {
            func predecessors(_ order: [ID]) -> [ID: ID] {
                Dictionary(zip(order.dropFirst(), order), uniquingKeysWith: { first, _ in first })
            }
            let was = predecessors(stayedBefore)
            let now = predecessors(stayedAfter)
            moved = Set(stayedBefore.filter { was[$0] != now[$0] })
        }

        for (index, item) in before.enumerated() {
            let key = id(item)
            let afterwards = kept[key]
            let altered = afterwards.map { $0 != item } ?? true
            let isMoved = moved.contains(key)
            guard altered || isMoved else { continue }
            let at = result.firstIndex { id($0) == key }
            // Altered: what the change altered goes back, and what something else has
            // altered since stays, as when a handle is dragged while the knob turns.
            func restored(_ now: Item) -> Item { afterwards.map { fields(now, $0, item) } ?? item }
            if let at, !isMoved {
                // Altered in place, or taken away and since put back.
                result[at] = restored(result[at])
                continue
            }
            // Altered or moved, and since taken away by something else: it stays away.
            if at == nil, afterwards != nil { continue }
            // Taken away by the change: back as it was. Moved: as it is now, or as it was
            // in what the change altered.
            let value = at.map { altered ? restored(result[$0]) : result[$0] } ?? item
            if let at { result.remove(at: at) }
            // Just after the nearest of those before it that is still there, or first.
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

    /// Changes a screen. `body` is given the screen with what is on it, and may change that too.
    mutating func updateScreen(_ id: DesignScreen.ID, _ body: (inout DesignScreen) -> Void) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        let before = children(of: id)
        var screen = frames[index]
        screen.elements = before
        body(&screen)
        screen.id = id
        frames[index] = screen.withoutElements
        if screen.elements != before { setChildren(of: id, to: screen.elements) }
    }

    // MARK: Taking a change back

    /// Takes back the change that turned `before` into `after`, as far as what it changed
    /// is still as the change left it. Whatever has been changed since, the same things
    /// included, is left as it is now. Siri's undo of an action taken a while ago works this
    /// way, so that it doesn't take back what was done by hand meanwhile.
    mutating func takeBack(_ after: DesignContent, to before: DesignContent) {
        if before.title != after.title, title == after.title { title = before.title }
        if before.canvas != after.canvas, canvas == after.canvas { canvas = before.canvas }

        // Screens it changed are put back, and those it removed come back, first, so that
        // what was on them can come back too.
        let screensAfter = Dictionary(after.frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, screen) in before.frames.enumerated() {
            if let left = screensAfter[screen.id] {
                if left != screen, let here = frames.firstIndex(where: { $0.id == screen.id }), frames[here] == left {
                    frames[here] = screen
                }
            } else if !frames.contains(where: { $0.id == screen.id }) {
                frames.insert(screen, at: min(index, frames.count))
            }
        }

        // Elements it changed are put back, those it removed come back where they were,
        // and those it added go.
        let elementsAfter = Dictionary(after.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let screenIDs = Set(frames.map(\.id))
        for (index, element) in before.elements.enumerated() {
            if let left = elementsAfter[element.id] {
                guard left != element, let here = elements.firstIndex(where: { $0.id == element.id }), elements[here] == left else { continue }
                if left.parent == element.parent {
                    elements[here] = element
                } else if element.parent.map(screenIDs.contains) ?? true {
                    // Moved to another screen: back where it was, if that is still there.
                    elements.remove(at: here)
                    elements.insert(element, at: min(index, elements.count))
                }
            } else if !elements.contains(where: { $0.id == element.id }), element.parent.map(screenIDs.contains) ?? true {
                elements.insert(element, at: min(index, elements.count))
            }
        }
        let wereThere = Set(before.elements.map(\.id))
        elements.removeAll { !wereThere.contains($0.id) && elementsAfter[$0.id] == $0 }

        // Screens it added go too, once nothing is left on them.
        let screensBefore = Set(before.frames.map(\.id))
        frames.removeAll { screen in
            !screensBefore.contains(screen.id) && screensAfter[screen.id] == screen && !elements.contains { $0.parent == screen.id }
        }

        // Things it only put in a new order go back to the old one, unless they have been
        // put in another since.
        for parent in Set(before.elements.map(\.parent)) {
            let order = before.children(of: parent).map(\.id)
            let left = after.children(of: parent).map(\.id)
            guard order != left, Set(order) == Set(left), children(of: parent).map(\.id) == left else { continue }
            reorder(parent, to: order)
        }
    }
}

private extension DesignScreen {
    var withoutElements: DesignScreen {
        var screen = self
        screen.elements = []
        return screen
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

extension DesignContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case screens, elements, floating, title, canvas
    }

    /// Reads every part that is present, so designs saved before a part existed still
    /// open. Until version 3 each screen held its own elements and those on the open
    /// canvas were a list of their own, `floating`; they are gathered into the one list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let screens = try container.decodeIfPresent([DesignScreen].self, forKey: .screens) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
        canvas = try container.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? CanvasSettings()
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
        if container.contains(.elements) {
            frames = screens.map(\.withoutElements)
            (elements, unread) = try DesignElement.readList(in: container, forKey: .elements)
        } else {
            self.screens = screens
            floating = try container.decodeIfPresent([FloatingElement].self, forKey: .floating) ?? []
        }
        // A design edited elsewhere, or saved by a build that doesn't know groups, opens with
        // its groups sound: a member of a group that has gone opens ungrouped (Review Focus 4).
        if hasGroups { keepGroupsSound() }
    }

    func encode(to encoder: any Encoder) throws {
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frames, forKey: .screens)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(WithUnknownKeys(canvas), forKey: .canvas)

        // Elements this version couldn't read go back where they were among the others.
        var list = container.nestedUnkeyedContainer(forKey: .elements)
        var kept = unread[...]
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
