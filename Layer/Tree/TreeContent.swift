import CoreGraphics
import Foundation

// The version-4 design: screens that each hold a root node, the canvas's own nodes, and
// the file they are saved in. It sits beside `DesignContent`, which the app still uses.
// Like it, everything is read leniently and what this version doesn't know is kept.

/// One device screen on the canvas. Its root is a group the size of the device, which
/// holds everything on the screen.
struct TreeScreen: Identifiable, Equatable, Sendable, Codable, KeepsUnknownKeys {
    var id = UUID()
    var name: String
    /// Where the screen is drawn on the canvas, and how large.
    var origin: CGPoint
    var scale: CGFloat
    /// Which device this is; an iPhone when unset.
    var deviceID: String?
    var isLocked: Bool?
    /// Kind `.group`, framed to the device, sized fixed: see `keepRootToDevice()`.
    var root: LayerNode
    var unknownKeys = UnknownKeys()

    var device: DeviceFrame { DeviceFrame.named(deviceID) }

    init(name: String, origin: CGPoint, scale: CGFloat, deviceID: String?, root: LayerNode? = nil) {
        self.name = name
        self.origin = origin
        self.scale = scale
        self.deviceID = deviceID
        self.root = root ?? LayerNode(kind: .group)
        keepRootToDevice()
    }

    /// Makes the root what a screen's root always is: a group at the device's bounds, fixed
    /// in both directions and upright. Padding and the rest of it are left as they are.
    mutating func keepRootToDevice() { keepRootToDevice(device) }

    /// The same for a device that may be one of the design's own, which `deviceID` alone can't name.
    mutating func keepRootToDevice(_ device: DeviceFrame) {
        root.kind = .group
        root.frame = CGRect(origin: .zero, size: device.size)
        root.width = LayerNode.Sizing(.fixed)
        root.height = LayerNode.Sizing(.fixed)
        root.rotation = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, origin, scale, deviceID, isLocked, root
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        origin = try container.decode(CGPoint.self, forKey: .origin)
        scale = try container.decode(CGFloat.self, forKey: .scale)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked)
        root = try container.decode(LayerNode.self, forKey: .root)
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
        keepRootToDevice()
    }

    func encode(to encoder: any Encoder) throws {
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(origin, forKey: .origin)
        try container.encode(scale, forKey: .scale)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(isLocked, forKey: .isLocked)
        try container.encode(root, forKey: .root)
    }
}

/// What a design holds: its screens, the nodes on the open canvas, its title and the
/// canvas's settings.
struct TreeContent: Equatable, Sendable, Codable, KeepsUnknownKeys {
    var screens: [TreeScreen] = []
    var canvas: [LayerNode] = []
    /// Canvas nodes this build couldn't read, each kept at its index among the canvas's nodes,
    /// as a node keeps its unread children.
    var unreadCanvas: [LayerNode.UnreadChild] = []
    var title: String?
    var settings = CanvasSettings()
    /// What a newer Layer saved in the content that this version doesn't know.
    var unknownKeys = UnknownKeys()
    /// The same for the manifest round the content, which `TreeManifest` fills and writes.
    var manifestUnknownKeys = UnknownKeys()

    init() {}

    enum CodingKeys: String, CodingKey {
        case screens, canvas, title, settings
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screens = try container.decodeIfPresent([TreeScreen].self, forKey: .screens) ?? []
        if container.contains(.canvas), try !container.decodeNil(forKey: .canvas) {
            // One at a time, so that a node this build can't read doesn't stop the rest from opening.
            var list = try container.nestedUnkeyedContainer(forKey: .canvas)
            (canvas, unreadCanvas) = try LayerNode.read(from: &list)
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        settings = try container.decodeIfPresent(CanvasSettings.self, forKey: .settings) ?? CanvasSettings()
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(screens, forKey: .screens)
        var list = container.nestedUnkeyedContainer(forKey: .canvas)
        try LayerNode.write(canvas, with: unreadCanvas, to: &list)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(settings, forKey: .settings)
    }
}

/// The file: `{"version":4,"fileName":…,"content":{…}}`, written with sorted keys.
enum TreeManifest {
    static let version = 4

    enum ReadError: LocalizedError, Equatable {
        case olderVersion(Int)
        case newerVersion(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .olderVersion: "This design was made by an earlier version of Layer and can't be opened by this one."
            case .newerVersion: "This design was saved by a newer version of Layer. Update Layer to open it."
            case .unreadable: "This design can't be read."
            }
        }
    }

    /// The file as `version` says, which is this one's unless a test writes a design from another.
    static func encode(_ content: TreeContent, fileName: String?, version: Int = TreeManifest.version) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(WithUnknownKeys(File(content: content, fileName: fileName, version: version)))
    }

    static func decode(_ data: Data) throws -> (content: TreeContent, fileName: String?) {
        // The version is read first, so that a file of another version is refused as such
        // whatever its content looks like.
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw ReadError.unreadable }
        if header.version < version { throw ReadError.olderVersion(header.version) }
        if header.version > version { throw ReadError.newerVersion(header.version) }
        guard var file = try? JSONDecoder().decode(File.self, from: data) else { throw ReadError.unreadable }
        file.content.manifestUnknownKeys = file.unknownKeys
        return (file.content, file.fileName)
    }

    private struct Header: Decodable {
        var version: Int
    }

    private struct File: Codable, KeepsUnknownKeys {
        var content: TreeContent
        var fileName: String?
        /// Read from the header rather than here; written as it is.
        var version = TreeManifest.version
        var unknownKeys: UnknownKeys { content.manifestUnknownKeys }

        enum CodingKeys: String, CodingKey {
            case version, content, fileName
        }

        init(content: TreeContent, fileName: String?, version: Int) {
            self.content = content
            self.fileName = fileName
            self.version = version
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decode(TreeContent.self, forKey: .content)
            fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            content.manifestUnknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
        }

        func encode(to encoder: any Encoder) throws {
            try unknownKeys.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(fileName, forKey: .fileName)
        }
    }
}
