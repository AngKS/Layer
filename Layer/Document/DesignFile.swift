import Foundation
import os
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

    init() {}

    /// The pictures the design shows.
    var imageIDs: Set<UUID> {
        Set(elements.compactMap(\.imageID))
    }

    // MARK: Views of the list

    /// Each screen with what is on it.
    var screens: [DesignScreen] {
        get {
            guard !frames.isEmpty else { return [] }
            var onScreen: [DesignScreen.ID: [DesignElement]] = [:]
            for element in elements {
                if let parent = element.parent { onScreen[parent, default: []].append(element) }
            }
            return frames.map { frame in
                var screen = frame
                screen.elements = onScreen[frame.id] ?? []
                return screen
            }
        }
        set {
            let loose = elements.filter { $0.parent == nil }
            frames = newValue.map(\.withoutElements)
            elements = newValue.flatMap { screen in screen.elements.map { $0.placed(on: screen.id, scale: nil) } } + loose
        }
    }

    /// The elements on the open canvas, outside every screen.
    var floating: [FloatingElement] {
        get { elements.filter { $0.parent == nil }.map { FloatingElement(element: $0, scale: $0.scale ?? 1) } }
        set { elements = elements.filter { $0.parent != nil } + newValue.map { $0.element.placed(on: nil, scale: $0.scale) } }
    }

    /// One screen with what is on it.
    func screen(_ id: DesignScreen.ID) -> DesignScreen? {
        guard var screen = frames.first(where: { $0.id == id }) else { return nil }
        screen.elements = children(of: id)
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
        body(&elements[index])
        elements[index].id = before.id
        elements[index].parent = before.parent
        elements[index].scale = before.scale
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
        let siblings = Dictionary(uniqueKeysWithValues: slots.map { (elements[$0].id, elements[$0]) })
        guard order.count == slots.count, Set(order) == Set(siblings.keys) else { return }
        for (slot, id) in zip(slots, order) {
            if let element = siblings[id] { elements[slot] = element }
        }
    }

    /// Replaces what is on a screen.
    mutating func setChildren(of screen: DesignScreen.ID, to children: [DesignElement]) {
        elements.removeAll { $0.parent == screen }
        elements += children.map { $0.placed(on: screen, scale: nil) }
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
        if container.contains(.elements) {
            frames = screens.map(\.withoutElements)
            (elements, unread) = try DesignElement.readList(in: container, forKey: .elements)
        } else {
            self.screens = screens
            floating = try container.decodeIfPresent([FloatingElement].self, forKey: .floating) ?? []
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frames, forKey: .screens)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(canvas, forKey: .canvas)

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
            try list.encode(element)
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
///     drawing.data              ink drawn with PencilKit's own tools
///     images/<id>               attached pictures, as they were imported
///     QuickLook/Thumbnail.jpg   a picture of the board, for the document browser
///
/// Keeping the parts apart is what makes saving and syncing cheap. An edit rewrites the
/// small design file; pictures, which never change once attached, are written and
/// uploaded to iCloud once rather than on every save.
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
    /// made it a package, with each screen holding its own elements. Version 3 keeps the
    /// elements in one list, each saying what it is on. Earlier versions still open, and
    /// are saved as version 3.
    static let currentVersion = 3

    var version = currentVersion
    var content = DesignContent()
    /// Ink drawn with PencilKit's own tools. Magic Pen sketches are never saved: they
    /// either become elements or disappear.
    var drawing = PKDrawing()
    /// Attached pictures, as image file data, by the UUID that elements refer to them with.
    var images: [String: Data] = [:]
    /// A small picture of the board, as JPEG data. Nil for a board with nothing on it.
    var preview: Data?
    /// The name the file had when the app last looked. A different name on disk means
    /// the file was renamed somewhere else, in Files for instance.
    var fileName: String?

    init(content: DesignContent = DesignContent(), drawing: PKDrawing = PKDrawing(), images: [String: Data] = [:]) {
        self.content = content
        self.drawing = drawing
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
        if let ink = parts[DesignPackage.drawing]?.regularFileContents {
            drawing = try PKDrawing(data: ink)
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
        drawing = old.drawing
        images = old.images ?? [:]
    }

    // MARK: Writing

    /// The design as a package, ready to be written. Parts that are already on disk
    /// unchanged are handed back as they are, which leaves their files untouched.
    /// Pictures that nothing in the design shows any more are left out.
    func wrapper(replacing existing: FileWrapper? = nil) throws -> FileWrapper {
        let old = existing?.isDirectory == true ? existing?.fileWrappers ?? [:] : [:]
        var parts: [String: FileWrapper] = [:]

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let manifest = Manifest(version: version, content: content, fileName: fileName)
        parts[DesignPackage.design] = Self.file(try encoder.encode(manifest), named: DesignPackage.design, onDisk: old[DesignPackage.design])
        parts[DesignPackage.drawing] = Self.file(Self.encoded(drawing), named: DesignPackage.drawing, onDisk: old[DesignPackage.drawing])

        let shown = Set(content.imageIDs.map(\.uuidString))
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
        return FileWrapper(directoryWithFileWrappers: parts)
    }

    /// The last drawing encoded to data, and what it encoded to. Most saves change only
    /// the design's screens and elements, not its ink, so re-encoding the same drawing
    /// every time would be wasted work; this lets a save reuse the bytes from the last
    /// one when the ink hasn't changed since.
    private static let encodedDrawingCache = OSAllocatedUnfairLock<(drawing: PKDrawing, data: Data)?>(initialState: nil)

    private static func encoded(_ drawing: PKDrawing) -> Data {
        if let cached = encodedDrawingCache.withLock({ $0 }), cached.drawing == drawing { return cached.data }
        let data = drawing.dataRepresentation()
        encodedDrawingCache.withLock { $0 = (drawing, data) }
        return data
    }

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

    private struct Manifest: Codable {
        var version: Int
        var content: DesignContent
        var fileName: String?
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
