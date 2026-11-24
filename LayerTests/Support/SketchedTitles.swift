import CoreGraphics
import Foundation
@testable import Layer

/// A phone screen at the canvas's origin, at scale 1, holding three titles the Magic Pen made: drawn small, as usual
/// and large, so 32, 40 and 48 tall (Title 2, Title and Large Title), in that order, top to bottom.
@MainActor
func sketchedTitles() -> (store: DesignStore, titles: [UUID]) {
    let store = DesignStore(content: DesignContent())
    let screen = store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
    let titles = [(150, 24), (300, 44), (450, 64)].compactMap { top, height in
        store.addElement(.title, from: CGRect(x: 120, y: CGFloat(top), width: 160, height: CGFloat(height)), to: screen.id)?.id
    }
    return (store, titles)
}
