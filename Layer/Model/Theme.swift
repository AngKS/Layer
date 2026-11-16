import SwiftUI
import UIKit

/// A plain sRGB colour that can cross actors and be written into generated code.
struct RGBColor: Hashable, Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// The colour as web designers write it, such as `#CD6C57`.
    var hex: String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}

extension Color {
    init(hex: UInt32) {
        self = RGBColor(hex: hex).color
    }
}

/// Colours sampled from the reference demo.
enum Theme {
    static let accent = RGBColor(hex: 0xCD6C57)
    static let inkTint = RGBColor(hex: 0x2B2A27)
    static let stickyNote = RGBColor(hex: 0xFCE38A)

    static let canvas = Color(hex: 0xF4F3EC)
    static let gridDot = Color(hex: 0xD3D1C8)
    static let chrome = Color(hex: 0xFAF9F2)
    static let chromeActive = Color(hex: 0xE5E3DC)
    static let ink = inkTint.color
    static let label = Color(hex: 0x9A9892)
    static let guide = Color(hex: 0x5A9BD8)
    static let penDot = Color(hex: 0xD9534F)

    static let island = Color(hex: 0xC6C4C6)
    static let statusGlyph = Color(hex: 0xB9B7B5)
    static let homeIndicator = Color(hex: 0xC4C2C5)
    static let imageTop = Color(hex: 0xE9E6E1)
    static let imageBottom = Color(hex: 0xD5D1CA)
    static let bodyText = Color(hex: 0x8E8C86)
    static let fieldFill = Color(hex: 0xF1EFEA)
    static let dividerLine = Color(hex: 0xE2DFD8)

    static let panel = Color(hex: 0xFBFAF5)
    static let segmentTrack = Color(hex: 0xE8E5DE)
    static let rowSelected = Color(hex: 0xEEECE5)

    static let codePlain = Color(hex: 0x2F2E2B)
    static let codeLineNumber = Color(hex: 0xA5A39B)
    static let codeKeyword = Color(hex: 0x9A5BB8)
    static let codeType = Color(hex: 0x3B7EA8)
    static let codeString = Color(hex: 0xB0603A)
    static let codeNumber = Color(hex: 0xC98A1B)
    static let codeMethod = Color(hex: 0x5C8A3C)
}
