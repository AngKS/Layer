import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct DeviceFrameTests {
    // MARK: - Building designs

    private static func watch(margin: CGFloat = 8) -> DeviceFrame {
        var frame = DeviceFrame.custom(name: "Watch Ultra", size: CGSize(width: 198, height: 242), family: .watch)
        frame.margin = margin
        frame.safeLeading = 4
        frame.safeTrailing = 4
        frame.hasStatusBar = false
        return DeviceFrame(id: frame.id, name: frame.name, size: frame.size, safeTop: 10, safeBottom: 10,
                           cornerRadius: 0, hasIsland: false, hasHomeIndicator: false, family: .watch,
                           safeLeading: 4, safeTrailing: 4, hasStatusBar: false, margin: margin)
    }

    private static func generated(_ kind: ElementKind, _ words: String = "") -> LayerNode {
        var node = LayerNode(kind: kind)
        node.content.text = words
        (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
        return node
    }

    private static let column = LayerNode.Layout.stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .fill))

    private static func design(on device: DeviceFrame, layout: LayerNode.Layout? = nil,
                               _ children: [LayerNode] = []) -> TreeContent {
        var content = TreeContent()
        content.settings.customDevices = [device]
        var screen = TreeScreen(name: "Screen", origin: .zero, scale: 1, deviceID: device.id)
        screen.root.layout = layout
        screen.root.children = children
        content.screens = [screen]
        return content
    }

    private static func applied(_ content: TreeContent) -> TreeContent {
        var content = content
        TreeRules.apply(to: &content, after: nil)
        return content
    }

    private static func roundTrip(_ content: TreeContent) throws -> TreeContent {
        try TreeManifest.decode(TreeManifest.encode(content, fileName: nil)).content
    }

    // MARK: - The built-ins

    @Test func builtInsKeepTheirSizesAndTakeTheirFamiliesTokens() {
        let sizes: [String: (CGSize, CGFloat, CGFloat)] = [
            "iphone": (CGSize(width: 393, height: 852), 59, 34),
            "iphone-pro-max": (CGSize(width: 440, height: 956), 62, 34),
            "iphone-se": (CGSize(width: 375, height: 667), 20, 0),
            "ipad": (CGSize(width: 820, height: 1180), 24, 20),
            "ipad-mini": (CGSize(width: 744, height: 1133), 24, 20),
            "ipad-pro-13": (CGSize(width: 1032, height: 1376), 24, 20),
            "macbook-air": (CGSize(width: 1470, height: 956), 32, 0),
            "macbook-pro-16": (CGSize(width: 1728, height: 1117), 32, 0),
            "imac": (CGSize(width: 2240, height: 1260), 24, 0),
        ]
        #expect(DeviceFrame.all.count == sizes.count)
        for device in DeviceFrame.all {
            let expected = sizes[device.id]
            #expect(device.size == expected?.0)
            #expect(device.safeTop == expected?.1)
            #expect(device.safeBottom == expected?.2)
            #expect(device.safeLeading == 0 && device.safeTrailing == 0)
            #expect(!device.isCustom)
            #expect(device.margin == device.family.defaultMargin)
        }
        #expect(DeviceFrame.iPhone.margin == 20)
        #expect(DeviceFrame.named("ipad").margin == 32)
        let mac = DeviceFrame.named("macbook-air")
        #expect(mac.margin == 48)
        #expect(mac.maxContentWidth == 1080)
        #expect(DeviceFrame.iPhone.maxContentWidth == nil)
        #expect(DeviceFrame.iPhone.hasStatusBar)
        #expect(!mac.hasStatusBar)
        #expect(DeviceFrame.Family.allCases.map(\.defaultMargin) == [20, 32, 48, 8, 20])
    }

    // MARK: - Custom frames in the file

    @Test func aCustomFrameRoundTripsInTheDesign() throws {
        let frame = Self.watch()
        let content = Self.design(on: frame)
        let back = try Self.roundTrip(content)
        #expect(back.settings == content.settings)
        let read = try #require(back.settings.customDevices.first)
        #expect(read.size == CGSize(width: 198, height: 242))
        #expect(read.margin == 8)
        #expect((read.safeTop, read.safeBottom, read.safeLeading, read.safeTrailing) == (10, 10, 4, 4))
        #expect(!read.hasStatusBar)
        #expect(read.family == .watch)
        #expect(read.isCustom)
        #expect(back.screens[0].deviceID == frame.id)
    }

    @Test func aDesktopFrameWithNoWidthLimitKeepsNone() throws {
        var frame = DeviceFrame.custom(name: "Wide", size: CGSize(width: 2000, height: 1000), family: .desktop)
        #expect(frame.maxContentWidth == 1080)
        frame.maxContentWidth = nil
        let back = try Self.roundTrip(Self.design(on: frame))
        let kept = try #require(back.settings.customDevices.first)
        #expect(kept.maxContentWidth == nil)
    }

    @Test func aSettingThisBuildDoesNotKnowSurvivesTheFile() throws {
        var content = Self.design(on: Self.watch())
        content.settings.unknownKeys["hologram"] = .object(["x": .number(1)])
        let back = try Self.roundTrip(content)
        #expect(back.settings.unknownKeys["hologram"] == .object(["x": .number(1)]))
        #expect(back.settings == content.settings)
        // Without custom frames the key still comes back, and no empty list is written.
        var plain = TreeContent()
        plain.settings.unknownKeys["hologram"] = .object(["x": .number(1)])
        let data = try TreeManifest.encode(plain, fileName: nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("customDevices"))
        #expect(try TreeManifest.decode(data).content.settings.unknownKeys["hologram"] == .object(["x": .number(1)]))
    }

    /// A design whose settings list `devices` as JSON, with one screen on `deviceID`.
    private static func file(listing devices: [[String: Any]], screenOn deviceID: String) throws -> Data {
        var content = TreeContent()
        content.screens = [TreeScreen(name: "S", origin: .zero, scale: 1, deviceID: deviceID)]
        let data = try TreeManifest.encode(content, fileName: nil)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var inner = try #require(json["content"] as? [String: Any])
        var settings = inner["settings"] as? [String: Any] ?? [:]
        settings["customDevices"] = devices
        inner["settings"] = settings
        json["content"] = inner
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test func aMalformedCustomFrameIsKeptButNotUsed() throws {
        let bad: [String: Any] = ["id": "custom-bad", "name": "Bad", "size": [0, -5], "future": "kept"]
        let data = try Self.file(listing: [bad], screenOn: "custom-bad")
        var content = try TreeManifest.decode(data).content
        #expect(content.settings.customDevices.isEmpty)
        #expect(content.settings.unreadDevices.count == 1)

        TreeRules.apply(to: &content, after: nil)
        #expect(content.screens[0].root.frame.size == DeviceFrame.iPhone.size)

        let written = try TreeManifest.encode(content, fileName: nil)
        let json = try JSONDecoder().decode(JSONValue.self, from: written)
        let original = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: bad))
        guard case .object(let file) = json, case .object(let body)? = file["content"],
              case .object(let settings)? = body["settings"], case .array(let list)? = settings["customDevices"]
        else { Issue.record("no customDevices in the file"); return }
        #expect(list == [original])
    }

    @Test func framesThisBuildCantReadAreKeptAfterTheOthers() throws {
        let good = Self.watch()
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any] ?? [:]
        let notCustom: [String: Any] = ["id": "phone-x", "name": "X", "size": [100, 100]]
        let builtIn: [String: Any] = ["id": "iphone", "name": "X", "size": [100, 100]]
        let repeated = goodJSON
        let content = try TreeManifest.decode(Self.file(listing: [notCustom, goodJSON, builtIn, repeated], screenOn: good.id)).content
        #expect(content.settings.customDevices.map(\.id) == [good.id])
        #expect(content.settings.unreadDevices.count == 3)
    }

    @Test func oddValuesInACustomFrameReadAsTheirDefaults() throws {
        let odd: [String: Any] = [
            "id": "custom-odd", "name": "Odd", "size": [100, 200], "family": "hologram",
            "safeTop": -4, "safeBottom": 6, "margin": -1, "maxContentWidth": 0, "future": 1,
        ]
        let content = try TreeManifest.decode(Self.file(listing: [odd], screenOn: "custom-odd")).content
        let frame = try #require(content.settings.customDevices.first)
        #expect(frame.family == .other)
        #expect(frame.safeTop == 0 && frame.safeBottom == 6)
        #expect(frame.margin == DeviceFrame.Family.other.defaultMargin)
        #expect(frame.maxContentWidth == nil)
        #expect(frame.unknownKeys["future"] == .number(1))
        let again = try Self.roundTrip(content)
        #expect(again.settings == content.settings)
    }

    @Test func aCustomFrameCantTakeABuiltInsID() {
        var content = TreeContent()
        var imposter = DeviceFrame.custom(name: "Imposter", size: CGSize(width: 100, height: 100), family: .phone)
        imposter = DeviceFrame(id: "ipad", name: imposter.name, size: imposter.size, safeTop: 0, safeBottom: 0,
                               cornerRadius: 0, hasIsland: false, hasHomeIndicator: false)
        content.settings.customDevices = [imposter]
        #expect(content.settings.device(named: "ipad").size == DeviceFrame.named("ipad").size)
        #expect(DeviceFrame.named("ipad", among: [imposter]).name == "iPad")
        // Written and read back, it is kept aside, not used.
        let back = try? Self.roundTrip(content)
        #expect(back?.settings.customDevices.isEmpty == true)
        #expect(back?.settings.unreadDevices.count == 1)
    }

    // MARK: - Resolving

    @Test func anUnknownDeviceIDFallsBackToTheIPhone() {
        let settings = CanvasSettings()
        #expect(settings.device(named: "custom-nope") == .iPhone)
        #expect(settings.device(named: nil) == .iPhone)
        #expect(DeviceFrame.named("custom-nope", among: []) == .iPhone)
        var content = TreeContent()
        let screen = TreeScreen(name: "S", origin: .zero, scale: 1, deviceID: "custom-nope")
        content.screens = [screen]
        #expect(content.device(of: screen) == .iPhone)
    }

    @Test func theSketchDeviceCanBeCustom() {
        let frame = Self.watch()
        var settings = CanvasSettings()
        settings.customDevices = [frame]
        settings.sketchDeviceID = frame.id
        #expect(settings.sketchDevice == frame)
        settings.sketchDeviceID = nil
        #expect(settings.sketchDevice == .iPhone)
    }

    @Test func aProjectedScreenUsesItsResolvedDevice() {
        var screen = DesignScreen(name: "S", origin: .zero, scale: 1, deviceID: "ipad")
        #expect(screen.device == .named("ipad"))
        let frame = Self.watch()
        screen.resolvedDevice = frame
        #expect(screen.device == frame)
        #expect(screen.size == frame.size)
    }

    // MARK: - The rules

    @Test func aScreenOnACustomFrameIsKeptToItsSize() {
        let after = Self.applied(Self.design(on: Self.watch()))
        #expect(after.screens[0].root.frame == CGRect(x: 0, y: 0, width: 198, height: 242))
    }

    @Test func aCustomFramesMarginIsUsed() throws {
        var frame = Self.watch(margin: 12)
        frame = DeviceFrame(id: frame.id, name: frame.name, size: frame.size, safeTop: 30, safeBottom: 10,
                            cornerRadius: 0, hasIsland: false, hasHomeIndicator: false, family: .watch,
                            safeLeading: 4, safeTrailing: 4, hasStatusBar: false, margin: 12)
        let after = Self.applied(Self.design(on: frame, layout: Self.column, [Self.generated(.body, "Hi")]))
        let text = try #require(after.screens[0].root.children.first).frame
        #expect(text.minX == 12 + frame.safeLeading)
        #expect(abs(text.minY - 42) < 1e-6)
        #expect(text.maxX == frame.size.width - 12 - frame.safeTrailing)
        #expect(TreeRules.margin(for: frame) == 12)
    }

    @Test func aCustomFramesMaxContentWidthLimitsTheColumn() throws {
        var frame = DeviceFrame.custom(name: "Wide", size: CGSize(width: 1600, height: 1000), family: .other)
        frame.maxContentWidth = 900
        var filled = Self.generated(.body, "A paragraph.")
        filled.width = LayerNode.Sizing(.fill(weight: 1))
        let after = Self.applied(Self.design(on: frame, layout: Self.column, [filled]))
        let child = try #require(after.screens[0].root.children.first).frame
        #expect(child.width == 900)
        #expect(child.minX == 350)
    }

    @Test func movingAScreenToAnotherFrameLaysItOutAgain() throws {
        var content = Self.design(on: Self.watch(), layout: Self.column, [Self.generated(.body, "Hi")])
        let before = Self.applied(content)
        content.settings.customDevices[0].margin = 20
        var after = content
        TreeRules.apply(to: &after, after: before)
        #expect(try #require(after.screens[0].root.children.first).frame.minX == 24)
    }
}
