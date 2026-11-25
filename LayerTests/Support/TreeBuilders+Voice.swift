import CoreGraphics
import Foundation
@testable import Layer

// What only the voice tests need beyond `TreeBuilders.swift` (plan 6, Task 7).

@MainActor
extension DesignStore {
    /// A sticky note on the open canvas, as the flat store's loose sketch made one of `sketch` (canvas points): its
    /// kind's loose size for what was drawn, drawn at the newest screen's scale, centred on the sketch. Its id.
    @discardableResult
    func addNote(sketchedIn sketch: CGRect) -> UUID {
        let scale = tree.screens.last?.scale ?? 0.66
        var note = LayerNode.standard(.stickyNote)
        let drawn = CGSize(width: sketch.width / scale, height: sketch.height / scale)
        note.frame.size = ElementKind.stickyNote.spec.looseSize.size(from: note.frame.size, drawn: drawn)
        note.frame.origin = CGPoint(x: (sketch.midX / scale - note.frame.width / 2).rounded(),
                                    y: (sketch.midY / scale - note.frame.height / 2).rounded())
        return addCanvasNode(note, scale: scale)
    }
}
