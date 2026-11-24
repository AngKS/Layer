import CoreGraphics
import Foundation

/// A device frame being made or edited (`CustomDeviceSheet`): its fields as typed, which make a `DeviceFrame` only
/// once nothing is wrong with them.
struct CustomDeviceDraft: Equatable {
    var name: String
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    var family: DeviceFrame.Family
    var safeTop, safeBottom, safeLeading, safeTrailing: CGFloat
    var hasStatusBar, hasIsland, hasHomeIndicator: Bool
    /// The space kept round a screen's column, beyond the safe areas.
    var margin: CGFloat
    /// The widest a screen's column runs, centred; nil is as wide as the screen.
    var maxContentWidth: CGFloat?
    /// What a newer Layer saved with the device it starts from, kept with what is made of it.
    private var unknownKeys: UnknownKeys

    /// The sides a device can have, in points.
    static let sides: ClosedRange<CGFloat> = 1...4000

    /// Everything `device` has, under `name`: Save as Device starts from a screen's device, and editing a custom one
    /// from itself.
    init(from device: DeviceFrame, named name: String) {
        self.name = name
        width = device.size.width
        height = device.size.height
        cornerRadius = device.cornerRadius
        family = device.family
        safeTop = device.safeTop
        safeBottom = device.safeBottom
        safeLeading = device.safeLeading
        safeTrailing = device.safeTrailing
        hasStatusBar = device.hasStatusBar
        hasIsland = device.hasIsland
        hasHomeIndicator = device.hasHomeIndicator
        margin = device.margin
        maxContentWidth = device.maxContentWidth
        unknownKeys = device.unknownKeys
    }

    /// What keeps it from being a device: a side that isn't a number from 1 to 4,000, or no name.
    var problems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(String(localized: "Give the device a name."))
        }
        if !Self.isSide(width) { problems.append(String(localized: "Width is 1 to 4,000 points.")) }
        if !Self.isSide(height) { problems.append(String(localized: "Height is 1 to 4,000 points.")) }
        return problems
    }

    /// The device it makes, with the id given or, for nil, a new custom one; nil while it has problems. Insets and a
    /// corner radius that aren't finite and 0 or more are 0, a margin that isn't is its family's, and a widest
    /// column of 0 or less is none, as a file's custom frame reads them.
    func device(id: String?) -> DeviceFrame? {
        guard problems.isEmpty else { return nil }
        var device = DeviceFrame(
            id: id ?? DeviceFrame.customPrefix + UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            size: CGSize(width: width, height: height), safeTop: Self.inset(safeTop), safeBottom: Self.inset(safeBottom),
            cornerRadius: Self.inset(cornerRadius), hasIsland: hasIsland, hasHomeIndicator: hasHomeIndicator, family: family,
            safeLeading: Self.inset(safeLeading), safeTrailing: Self.inset(safeTrailing), hasStatusBar: hasStatusBar,
            margin: margin.isFinite && margin >= 0 ? margin : nil)
        device.maxContentWidth = maxContentWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        device.unknownKeys = unknownKeys
        return device
    }

    private static func isSide(_ value: CGFloat) -> Bool { value.isFinite && sides.contains(value) }

    private static func inset(_ value: CGFloat) -> CGFloat { value.isFinite && value >= 0 ? value : 0 }
}

/// The design's own device frames (`CanvasSettings.customDevices`), added, edited and deleted, and the device each
/// screen is drawn as.
extension DesignStore {
    /// One step, "Add Device"; returns its id. With `forScreen`, that screen takes it in the same step.
    ///
    /// A device whose id isn't a custom one, or is one the design already has, is added under a new id.
    @discardableResult
    func addCustomDevice(_ device: DeviceFrame, forScreen screen: TreeScreen.ID? = nil) -> String {
        addDevice(device) { content, id in
            guard let screen, let index = content.tree.screens.firstIndex(where: { $0.id == screen }) else { return }
            content.tree.screens[index].deviceID = id
        }
    }

    /// One step, "Add Device", that also makes it the device a screen drawn with the Magic Pen becomes; returns its id.
    @discardableResult
    func addCustomDeviceForNewScreens(_ device: DeviceFrame) -> String {
        addDevice(device) { content, id in content.tree.settings.sketchDeviceID = id }
    }

    /// Replaces the design's device with `device`'s id, as one step, "Edit Device". Allowed while screens use it:
    /// the rules lay them out again on it. A device the design doesn't have changes nothing.
    func updateCustomDevice(_ device: DeviceFrame) {
        guard tree.settings.customDevices.contains(where: { $0.id == device.id }) else { return }
        asStep(named: String(localized: "Edit Device")) {
            apply { content in
                guard let index = content.tree.settings.customDevices.firstIndex(where: { $0.id == device.id }) else { return }
                content.tree.settings.customDevices[index] = device
            }
        }
    }

    /// Whether a screen is drawn as the device, or it is the canvas's New Screens device (`sketchDeviceID`) (F16).
    func isCustomDeviceInUse(_ id: String) -> Bool {
        tree.settings.sketchDeviceID == id || tree.screens.contains { $0.deviceID == id }
    }

    /// Takes the design's device away, as one step, "Delete Device". False while a screen uses it, or while it is the
    /// canvas's New Screens device (`sketchDeviceID`) (F16), and for a device the design doesn't have.
    @discardableResult
    func deleteCustomDevice(_ id: String) -> Bool {
        guard tree.settings.customDevices.contains(where: { $0.id == id }), !isCustomDeviceInUse(id) else { return false }
        asStep(named: String(localized: "Delete Device")) {
            apply { $0.tree.settings.customDevices.removeAll { $0.id == id } }
        }
        return true
    }

    /// Draws the screen as the device with the id, a built-in or one of the design's own; nil is the iPhone. An id the
    /// design has no device for changes nothing. The rules keep its root to the device and lay it out again.
    func setDevice(of screen: TreeScreen.ID, to deviceID: String?) {
        let device = tree.settings.device(named: deviceID)
        guard deviceID == nil || device.id == deviceID else { return }
        updateTreeScreen(screen) { $0.deviceID = device.id == DeviceFrame.iPhone.id ? nil : device.id }
    }

    // MARK: How the writes work

    /// Adds `device`, under an id of its own, and lets `use` put it to use, in one change made as one step.
    private func addDevice(_ device: DeviceFrame, _ use: (inout DesignContent, String) -> Void) -> String {
        let settings = tree.settings
        let taken = Set(DeviceFrame.all.map(\.id) + settings.customDevices.map(\.id))
        let added = device.isCustom && !taken.contains(device.id) ? device : device.identified(as: DeviceFrame.customPrefix + UUID().uuidString)
        asStep(named: String(localized: "Add Device")) {
            apply { content in
                content.tree.settings.customDevices.append(added)
                use(&content, added.id)
            }
        }
        return added.id
    }

    /// `body`'s changes as one step named `name`; made as part of an edit's own work, they join that edit.
    private func asStep(named name: String, _ body: () -> Void) {
        guard actingEdit == nil else {
            body()
            return
        }
        let edit = beginEdit(by: .app)
        self.name(edit, name)
        act(for: edit, body)
        endEdit(edit)
    }
}

private extension DeviceFrame {
    /// The same device under another id.
    func identified(as id: String) -> DeviceFrame {
        var device = DeviceFrame(id: id, name: name, size: size, safeTop: safeTop, safeBottom: safeBottom,
                                 cornerRadius: cornerRadius, hasIsland: hasIsland, hasHomeIndicator: hasHomeIndicator,
                                 family: family, safeLeading: safeLeading, safeTrailing: safeTrailing,
                                 hasStatusBar: hasStatusBar, margin: margin)
        device.maxContentWidth = maxContentWidth
        device.unknownKeys = unknownKeys
        return device
    }
}
