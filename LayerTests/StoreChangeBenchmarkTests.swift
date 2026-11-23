import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// How long one change through the store takes on a screen of 100 elements: a move, a resize,
/// a text edit, an add and its delete; and the same with the next read of the screens after it,
/// which on the tree lowers it again. It uses only today's `DesignStore` API, so the same file
/// measures main and the branch. It runs only when `LAYER_BENCHMARK` is set
/// (`TEST_RUNNER_LAYER_BENCHMARK=1` on the `xcodebuild` command line) and prints a
/// `BENCH store <op> p50=<ms> p95=<ms>` line and a `BENCH store <op>+read …` line for each.
@MainActor
@Suite("Store change benchmark", .enabled(if: ProcessInfo.processInfo.environment["LAYER_BENCHMARK"] != nil))
struct StoreChangeBenchmarkTests {
    private static let runs = 50

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
    }

    /// The p50 and p95 of a list of times.
    private static func percentiles(_ times: [Double]) -> (p50: Double, p95: Double) {
        let sorted = times.sorted()
        return (sorted[sorted.count / 2], sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1])
    }

    /// The p50 and p95 of `runs` timed runs of `operation`, in milliseconds, printed as a BENCH line;
    /// and of the same runs with the next read of `store`'s screens after each, printed as a
    /// `+read` line. Returns the change's alone.
    private func measure(_ name: String, reading store: DesignStore, _ operation: (Int) -> Void) -> (p50: Double, p95: Double) {
        var changes: [Double] = [], withReads: [Double] = []
        for run in 0..<Self.runs {
            let start = ContinuousClock.now
            operation(run)
            let changed = ContinuousClock.now
            _ = store.screens
            let read = ContinuousClock.now
            changes.append(Self.milliseconds(changed - start))
            withReads.append(Self.milliseconds(read - start))
        }
        let change = Self.percentiles(changes), withRead = Self.percentiles(withReads)
        print(String(format: "BENCH store %@ p50=%.3f p95=%.3f", name, change.p50, change.p95))
        print(String(format: "BENCH store %@+read p50=%.3f p95=%.3f", name, withRead.p50, withRead.p95))
        return change
    }

    @Test func aStoreChangeOnAHundredElementScreen() throws {
        let model = AppModel(document: LayerDocument())
        let store = model.store
        let screen = store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 1)).id
        var elements: [DesignElement] = []
        for row in 0..<25 {
            let y = 60 + 80 * CGFloat(row)
            elements.append(DesignElement(kind: .text, frame: CGRect(x: 20, y: y, width: 228, height: 24), text: "Title \(row)", tint: Theme.accent))
            elements.append(DesignElement(kind: .body, frame: CGRect(x: 20, y: y + 28, width: 353, height: 40), text: "Body \(row)", tint: Theme.accent))
            elements.append(DesignElement(kind: .toggle, frame: CGRect(x: 322, y: y, width: 51, height: 31), text: "", tint: Theme.accent))
            elements.append(DesignElement(kind: .divider, frame: CGRect(x: 20, y: y + 72, width: 353, height: 1), text: "", tint: Theme.accent))
        }
        let refs = store.setElements(elements, on: screen, replacing: true)
        try #require(refs.count == 100)

        // What the runs change: row 12's title (moved and edited) and its body (resized).
        let moved = refs[48], resized = refs[49], texted = refs[48]

        let move = measure("move", reading: store) { _ in store.update(moved) { $0.frame.origin.x += 1 } }
        let resize = measure("resize", reading: store) { _ in store.update(resized) { $0.frame.size.width += 1 } }
        let text = measure("text", reading: store) { _ in store.update(texted) { $0.text += "a" } }
        let add = measure("add", reading: store) { run in
            let added = store.setElements([DesignElement(kind: .text, frame: CGRect(x: 20, y: 2100, width: 228, height: 24), text: "Added \(run)", tint: Theme.accent)], on: screen, replacing: false)
            store.delete(added)
        }

        // A sanity bound, not the budget.
        for result in [move, resize, text, add] {
            #expect(result.p95.isFinite && result.p95 < 1000)
        }
    }
}
