import CoreGraphics
import Foundation
import Testing
@testable import Layer

// What only the voice tests need beyond `TreeBuilders.swift` (plan 6, Tasks 7 and 8).

extension TreeFixture {
    /// `loginWithACardAndARow()` with two texts on its root below the row (plan 6, Task 8): `x`, "Terms" at
    /// (20, 400, 100, 24), and `y`, "Privacy" at (140, 400, 100, 24), 20 apart. Captured, they are E8 and E9, and the
    /// sticky note on the canvas is E10. Adding them is no step: the history starts empty.
    @MainActor
    static func loginWithTwoTexts() -> (login: Login, x: UUID, y: UUID) {
        let login = loginWithACardAndARow()
        let x = LayerNode.leaf(.text, frame: CGRect(x: 20, y: 400, width: 100, height: 24), text: "Terms")
        let y = LayerNode.leaf(.text, frame: CGRect(x: 140, y: 400, width: 100, height: 24), text: "Privacy")
        for text in [x, y] where !login.model.store.add(text, to: .screen(login.screen)) {
            Issue.record("The store refused a text for the fixture")
        }
        login.undo.removeAllActions()
        return (login, x.id, y.id)
    }
}
