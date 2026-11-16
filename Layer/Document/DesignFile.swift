import Foundation
import PencilKit
import UniformTypeIdentifiers

extension UTType {
    /// A Layer design, saved with the `.layer` extension. Declared in the app's Info.plist.
    static let layerDesign = UTType(exportedAs: "kahshin.layer.design")
}

/// The part of a design that the design tools edit: screens, loose elements, its title and
/// how its canvas is set up.
struct DesignContent: Codable, Equatable, Sendable {
    var screens: [DesignScreen] = []
    /// Elements on the open canvas, outside every screen.
    var floating: [FloatingElement] = []
    /// The board's name. Nil until one has been suggested or typed.
    var title: String?
    var canvas = CanvasSettings()

    init() {}

    /// Reads every part that is present, so designs saved before a part existed still open.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screens = try container.decodeIfPresent([DesignScreen].self, forKey: .screens) ?? []
        floating = try container.decodeIfPresent([FloatingElement].self, forKey: .floating) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
        canvas = try container.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? CanvasSettings()
    }

    /// The pictures the design shows.
    var imageIDs: Set<UUID> {
        Set((screens.flatMap(\.elements) + floating.map(\.element)).compactMap(\.imageID))
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

    /// Version 1 was a single JSON file with the ink and pictures inside it.
    static let currentVersion = 2

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
        parts[DesignPackage.drawing] = Self.file(drawing.dataRepresentation(), named: DesignPackage.drawing, onDisk: old[DesignPackage.drawing])

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
}
