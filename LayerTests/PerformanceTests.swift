import CoreGraphics
import PencilKit
import UIKit
import XCTest
@testable import Layer

/// Measured workouts for a few hot paths. `measure` reports wall-clock time per
/// iteration, which is what `xcodebuild test` prints to the log; compare the numbers
/// printed before and after a change to this file's neighbours in `Layer/`.

/// `DesignIndexer.designChanged` is called every time a design's content changes, which
/// includes every frame of a drag, not just when it ends. It must stay cheap however often
/// it is called in a burst.
@MainActor
final class DesignIndexerPerformanceTests: XCTestCase {
    func testManyChangesInARowAreCheapToSchedule() {
        let model = AppModel(document: LayerDocument())
        model.fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).layer")
        defer { model.close() }

        measure {
            for _ in 0..<3000 {
                DesignIndexer.designChanged(model)
            }
        }
    }
}
