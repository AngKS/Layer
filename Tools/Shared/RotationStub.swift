// A stand-in for the parts of `Rotation` that the files the benchmark harnesses compile
// use: CanvasPicture.swift (`shown`) and Design.swift (`kept`). The real enum, in
// Layer/Model/Rotation.swift, also turns rects for the canvas and so needs much of the
// app's model (`Viewport`). These functions are copied from it unchanged, so that an angle
// is described and kept exactly as the app does it; keep them in step with Rotation.swift.
// `Rotation.rotate` isn't copied: it is in Layer/Model/TurnedRect.swift, which the sketch and
// screen harnesses compile as it is.
enum Rotation {
    /// The same angle, kept from 0 up to but not including 360. An angle that isn't a
    /// number (or is infinite) is upright, so that it can't be saved and break the file.
    static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let kept = wrapped < 0 ? wrapped + 360 : wrapped
        return kept >= 360 ? 0 : kept
    }

    /// The angle as the Rotation field shows it: to the whole degree, from 0 to 359.
    static func shown(_ degrees: Double) -> Double {
        normalized(degrees.rounded())
    }

    /// The angle as an element keeps it: from 0 up to 360, and nothing when upright.
    static func kept(_ degrees: Double) -> Double? {
        let kept = normalized(degrees)
        return kept < 0.0001 || kept > 360 - 0.0001 ? nil : kept
    }
}
