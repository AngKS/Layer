// Stand-ins for two types the app defines in files this harness can't compile for macOS:
// `RGBColor` lives in Layer/Model/Theme.swift, which imports UIKit; `DesignContent` lives
// in Layer/Document/DesignFile.swift, which imports PencilKit. Neither framework exists on
// macOS, and the sketch classifier this harness benchmarks never touches either type's real
// behaviour (colour rendering, file reading): it only needs them to exist so that
// Layer/Model/Design.swift and Layer/Sketch/SketchInterpreter.swift type-check.
//
// See the memory note on testing Apple Intelligence natively: a harness compiling
// Layer/Sketch/*.swift plus a stub for RGBColor and Theme already measured the model this
// way on 2026-11-16. This file plays the same role for the benchmark harness.
import Foundation

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
}

/// Just enough of `DesignContent` for `SketchPrompt.describe(board:)` to type-check. The
/// benchmark never names boards, so this is never actually called.
struct DesignContent: Sendable {
    var screens: [DesignScreen] = []
    var floating: [FloatingElement] = []
    var title: String?
    var canvas = CanvasSettings()
}
