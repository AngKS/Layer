import CoreGraphics
import Foundation
import PencilKit

/// Reads a handwritten word out of a sketch's own strokes with PencilKit's on-device
/// recognizer, new in iOS/iPadOS/macOS 27 (`PKStrokeRecognizer`) — not Apple Intelligence.
/// "Sign in" written inside a box becomes that button's label; a squiggle that resolves to
/// a real word is evidence it's text, not decorative ink, the same way the $P glyph
/// matcher is evidence for a small mark. `reports/Fast and slow sketch recognition.md`,
/// Stage 2.
///
/// `PKStrokeRecognizer` has no vocabulary or constrained-recognition mode (confirmed
/// against its SDK interface before writing this): it recognises freely, so matching a
/// known word list — component names, `reading(namedIn:)`'s vocabulary — is a second pass
/// over whatever text comes back, not something the recognizer does for you.
enum HandwritingRecognizer {
    /// One recognizer, reused across calls. `PKStrokeRecognizer` is an actor; a fresh
    /// instance per call would mean reloading its model assets every time.
    private static let recognizer = PKStrokeRecognizer()

    /// The handwritten word or phrase these strokes spell, trimmed, or nil when
    /// PencilKit's recognizer finds nothing legible — a decorative squiggle, a shape
    /// outline, anything that isn't words. That absence is itself useful evidence, not
    /// just a missing label: see `ComponentRule`'s use of this for the text/title/body
    /// decision.
    static func recognize(_ strokes: [[CGPoint]]) async -> String? {
        guard !strokes.isEmpty else { return nil }
        let drawing = makeDrawing(strokes)
        await recognizer.updateDrawing(drawing)
        guard let text = await recognizer.recognizedText(strokeIDs: nil) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds a throwaway `PKDrawing` from plain points, the same construction
    /// `InkCanvas.swift`'s scripted-demo helper (`appendSketch`) uses to turn points back
    /// into ink: the recognizer needs real `PKStroke`s, not the `SketchStroke`s this
    /// engine reads shapes from.
    private static func makeDrawing(_ strokes: [[CGPoint]]) -> PKDrawing {
        let ink = PKInk(.monoline)
        let now = Date()
        let pkStrokes: [PKStroke] = strokes.enumerated().compactMap { index, points in
            guard points.count >= 2 else { return nil }
            let controlPoints = points.enumerated().map { offset, point in
                PKStrokePoint(
                    location: point, timeOffset: Double(offset) * 0.008, size: CGSize(width: 2, height: 2),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            let path = PKStrokePath(controlPoints: controlPoints, creationDate: now.addingTimeInterval(Double(index) * 0.001))
            return PKStroke(ink: ink, path: path)
        }
        return PKDrawing(strokes: pkStrokes)
    }
}
