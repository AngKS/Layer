import Foundation

extension TreeContent {
    /// The device a screen is drawn as: a built-in, or one of the design's own, or the iPhone.
    func device(of screen: TreeScreen) -> DeviceFrame { settings.device(named: screen.deviceID) }
}

extension CanvasSettings {
    /// The design's own device whose name equals `name`, ignoring case and surrounding space; nil when none (F13), and
    /// for a name of nothing but space. A built-in isn't one of the design's own. Where two have the name, the one made
    /// first. Siri and voice choose a device by name through this.
    func customDevice(named name: String) -> DeviceFrame? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return customDevices.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame
        }
    }
}
