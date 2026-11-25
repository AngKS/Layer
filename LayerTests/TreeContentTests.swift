import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Tree content")
struct TreeContentTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private static func count(_ node: LayerNode) -> Int {
        1 + node.children.reduce(0) { $0 + count($1) }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aDesignRoundTrips() throws {
        let (content, name) = try TreeManifest.decode(try Self.fixture("design-profile"))
        let again = try TreeManifest.decode(try TreeManifest.encode(content, fileName: name))
        #expect(again.content == content)
        #expect(again.fileName == name)
        #expect(name == "Profile")
    }

    @Test func encodingIsTheSameEveryTime() throws {
        let (content, name) = try TreeManifest.decode(try Self.fixture("design-profile"))
        let first = try TreeManifest.encode(content, fileName: name)
        let second = try TreeManifest.encode(content, fileName: name)
        #expect(first == second)
        let text = try #require(String(data: first, encoding: .utf8))
        let keys = ["\"content\"", "\"fileName\"", "\"version\""].compactMap { text.range(of: $0)?.lowerBound }
        #expect(keys.count == 3 && keys == keys.sorted())
    }

    @Test func anOlderDesignIsRefusedWithItsMessage() {
        let error = #expect(throws: TreeManifest.ReadError.self) {
            try TreeManifest.decode(Data(#"{"version":3,"content":{}}"#.utf8))
        }
        #expect(error == .olderVersion(3))
        #expect(error?.errorDescription == "This design was made by an earlier version of Layer and can't be opened by this one.")
    }

    @Test func aNewerDesignIsRefused() {
        let error = #expect(throws: TreeManifest.ReadError.self) {
            try TreeManifest.decode(Data(#"{"version":5,"content":{}}"#.utf8))
        }
        #expect(error == .newerVersion(5))
        #expect(error?.errorDescription == "This design was saved by a newer version of Layer. Update Layer to open it.")
    }

    @Test func somethingUnreadableIsRefused() {
        for text in ["[]", "7", "{}", #"{"version":4}"#, #"{"version":4,"content":3}"#] {
            #expect(throws: TreeManifest.ReadError.unreadable, "\(text)") {
                try TreeManifest.decode(Data(text.utf8))
            }
        }
    }

    @Test func unknownKeysAreKeptAtEveryLevel() throws {
        var json = try Self.object(try Self.fixture("design-sketch"))
        json["futureManifest"] = "m"
        var content = try #require(json["content"] as? [String: Any])
        content["futureContent"] = ["a": 1]
        var screens = try #require(content["screens"] as? [[String: Any]])
        screens[0]["futureScreen"] = true
        var root = try #require(screens[0]["root"] as? [String: Any])
        var children = try #require(root["children"] as? [[String: Any]])
        children[0]["futureNode"] = [1, 2]
        root["children"] = children
        screens[0]["root"] = root
        content["screens"] = screens
        json["content"] = content

        let (decoded, name) = try TreeManifest.decode(try JSONSerialization.data(withJSONObject: json))
        let saved = try Self.object(try TreeManifest.encode(decoded, fileName: name))
        #expect(saved["futureManifest"] as? String == "m")
        let savedContent = try #require(saved["content"] as? [String: Any])
        #expect(savedContent["futureContent"] != nil)
        let savedScreen = try #require((savedContent["screens"] as? [[String: Any]])?.first)
        #expect(savedScreen["futureScreen"] as? Bool == true)
        let savedRoot = try #require(savedScreen["root"] as? [String: Any])
        let savedNode = try #require((savedRoot["children"] as? [[String: Any]])?.first)
        #expect(savedNode["futureNode"] != nil)
    }

    @Test func aScreensRootIsKeptToItsDevice() throws {
        var screen = TreeScreen(name: "S", origin: .zero, scale: 1, deviceID: nil)
        screen.root.kind = .text
        screen.root.frame = CGRect(x: 5, y: 5, width: 10, height: 10)
        screen.root.rotation = 20
        screen.root.width = LayerNode.Sizing(.fit)
        screen.root.height = LayerNode.Sizing(.fill(weight: 1))
        let decoded = try JSONDecoder().decode(TreeScreen.self, from: try JSONEncoder().encode(screen))
        #expect(decoded.root.kind == .group)
        #expect(decoded.root.frame == CGRect(x: 0, y: 0, width: 393, height: 852))
        #expect(decoded.root.width == LayerNode.Sizing(.fixed))
        #expect(decoded.root.height == LayerNode.Sizing(.fixed))
        #expect(decoded.root.rotation == nil)
    }

    @Test func theFixturesRead() throws {
        let profile = try TreeManifest.decode(try Self.fixture("design-profile")).content
        let sketch = try TreeManifest.decode(try Self.fixture("design-sketch")).content
        #expect(Self.count(try #require(profile.screens.first).root) == 15)
        #expect(Self.count(try #require(sketch.screens.first).root) == 5)
        #expect(sketch.canvas.first?.scale == 0.66)
    }
}

/// Just something in the `Layer` module/test bundle to resolve from, to find this test
/// bundle's `Bundle`.
private final class BundleMarker {}
