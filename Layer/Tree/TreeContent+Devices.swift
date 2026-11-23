import Foundation

extension TreeContent {
    /// The device a screen is drawn as: a built-in, or one of the design's own, or the iPhone.
    func device(of screen: TreeScreen) -> DeviceFrame { settings.device(named: screen.deviceID) }
}
