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
    /// One reader, reused across calls. A fresh `PKStrokeRecognizer` per call would mean
    /// reloading its model assets every time.
    private static let shared = Reader(recognizer: PKStrokeRecognizer())

    /// The handwritten word or phrase these strokes spell, trimmed, or nil when
    /// PencilKit's recognizer finds nothing legible — a decorative squiggle, a shape
    /// outline, anything that isn't words. That absence is itself useful evidence, not
    /// just a missing label: see `ComponentRule`'s use of this for the text/title/body
    /// decision.
    static func recognize(_ strokes: [[CGPoint]]) async -> String? {
        await recognize(strokes, with: shared)
    }

    /// The same, read by `reader`. A test hands in a reader with a stand-in recognizer.
    static func recognize(_ strokes: [[CGPoint]], with reader: Reader) async -> String? {
        guard !strokes.isEmpty else { return nil }
        guard let text = await reader.read(makeDrawing(strokes)) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads drawings with one recognizer, one at a time.
    ///
    /// The recognizer is given a drawing in one call and asked what it says in another.
    /// It is an actor, but nothing holds it between the two: sketches read together used
    /// to hand over their drawings one after the other and then each be told the words in
    /// the last one. An actor of our own doesn't hold it either, since it too lets the next
    /// call in at every wait, so each read waits for the one before it to finish.
    actor Reader {
        private let recognizer: any StrokeTextRecognizing
        /// The read that goes before the next one.
        private var last: Task<String?, Never>?

        init(recognizer: any StrokeTextRecognizing) {
            self.recognizer = recognizer
        }

        /// The text in `drawing`.
        func read(_ drawing: PKDrawing) async -> String? {
            let previous = last
            let read = Task { [recognizer] in
                _ = await previous?.value
                await recognizer.updateDrawing(drawing)
                return await recognizer.recognizedText(strokeIDs: nil)
            }
            last = read
            return await read.value
        }
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

/// What reads words out of a drawing: PencilKit's recognizer, or a test's stand-in. It is
/// given the drawing in one call and asked what it says in another.
protocol StrokeTextRecognizing: Sendable {
    func updateDrawing(_ drawing: PKDrawing) async
    func recognizedText(strokeIDs: Set<UUID>?) async -> String?
}

extension PKStrokeRecognizer: StrokeTextRecognizing {}
