import Foundation
import PencilKit
import UniformTypeIdentifiers

extension UTType {
    /// A Layer design, saved with the `.layer` extension. Declared in the app's Info.plist.
    static let layerDesign = UTType(exportedAs: "kahshin.layer.design")
}

/// What the file needs of a design's tree beside its coding: the pictures it shows, and the names of what this version read
/// but didn't understand.
extension TreeContent {
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
        var names = unknownKeys.strings.union(manifestUnknownKeys.strings)
        names.formUnion(settings.unknownKeys.strings)
        names.formUnion(settings.tokens.unknownKeys.strings)
        for device in settings.customDevices where !device.unknownKeys.values.isEmpty { names.formUnion(device.unknownKeys.strings) }
        for json in settings.unreadDevices { names.formUnion(json.strings) }
        for unread in unreadCanvas { names.formUnion(unread.raw.strings) }
        for unread in unreadScreens { names.formUnion(unread.raw.strings) }
        func visit(_ node: LayerNode) {
            if !node.unknownKeys.values.isEmpty { names.formUnion(node.unknownKeys.strings) }
            for keys in node.unknownPartKeys.values { names.formUnion(keys.strings) }
            for unread in node.unreadChildren { names.formUnion(unread.raw.strings) }
            node.children.forEach(visit)
        }
        for screen in screens {
            if !screen.unknownKeys.values.isEmpty { names.formUnion(screen.unknownKeys.strings) }
            visit(screen.root)
        }
        canvas.forEach(visit)
        return names
    }

    /// Every node on the screens, below their roots, and on the open canvas, each before what it holds.
    fileprivate func forEachNode(_ body: (LayerNode) -> Void) {
        func visit(_ node: LayerNode) {
            body(node)
            for child in node.children { visit(child) }
        }
        for screen in screens { screen.root.children.forEach(visit) }
        canvas.forEach(visit)
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
    var content = TreeContent()
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
    init(content: TreeContent = TreeContent(), drawing: PKDrawing = PKDrawing(), images: [String: Data] = [:]) {
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
        for index in content.canvas.indices where content.canvas[index].kind == .drawing {
            content.canvas[index].content.ink = ink[content.canvas[index].id.uuidString]?.regularFileContents
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
    private static func read(_ data: Data) throws -> (content: TreeContent, fileName: String?) {
        var (tree, fileName) = try TreeManifest.decode(data)
        TreeRules.apply(to: &tree, after: nil)
        return (tree, fileName)
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

        let design = try TreeManifest.encode(content, fileName: fileName, version: version)
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
    nonisolated static func content(at url: URL) throws -> TreeContent {
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
