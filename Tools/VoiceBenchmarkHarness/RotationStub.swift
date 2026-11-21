// A stand-in for the one part of `Rotation` that CanvasPicture.swift uses. The real enum,
// in Layer/Model/Rotation.swift, also turns rects for the canvas and so needs much of the
// app's model (`ElementLayout`, `Viewport`, `DesignElement`). These two functions are
// copied from it unchanged, so that a turned element is described to the model exactly as
// the app describes it; keep them in step with Rotation.swift.
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
}
