import CoreGraphics

// A stand-in for the part of `SketchConventions` (Layer/Sketch/SketchInterpreter.swift) that
// Catalogue.swift's sketch hints read. The screen harness compiles the catalogue for the kinds'
// written names; the real file needs the sketch reader's own types. Copied unchanged; keep it
// in step with SketchInterpreter.swift.
enum SketchConventions {
    /// An empty circle narrower than this is a radio button rather than an avatar: about
    /// 33 points on an iPhone, halfway between a drawn radio (28–30 pt across) and the
    /// smallest avatar (34 pt and up).
    static let radioFraction: CGFloat = 0.085
    /// `radioFraction` in points on the standard phone, as the model is told it.
    static var radioPoints: Int { Int((radioFraction * DeviceFrame.iPhone.size.width).rounded(.down)) }
}
