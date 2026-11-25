import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// How long one change through the store takes on a screen of 100 nodes: a move, a resize, a text edit, an add and
/// its delete. The screen is an iPhone's free root of 25 rows, each a text, a body, a toggle and a divider at plan 2's
/// frames, built on the tree. It runs only when `LAYER_BENCHMARK` is set (`TEST_RUNNER_LAYER_BENCHMARK=1` on the
/// `xcodebuild` command line) and prints a `BENCH store <op> p50=<ms> p95=<ms>` line for each. The numbers stand beside
/// the ones plan 2's version of this file measured on main (`scripts/measure-semantic-tree.sh --main`); the next read
/// of the screens that version also timed is `StoreChangeBudgetTests`' `BENCH tree <op>+read` on the tree.
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

    /// The p50 and p95 of `runs` timed runs of `operation`, in milliseconds, printed as a BENCH line.
    private func measure(_ name: String, _ operation: (Int) -> Void) -> (p50: Double, p95: Double) {
        var changes: [Double] = []
        for run in 0..<Self.runs {
            let start = ContinuousClock.now
            operation(run)
            changes.append(Self.milliseconds(ContinuousClock.now - start))
        }
        let change = Self.percentiles(changes)
        print(String(format: "BENCH store %@ p50=%.3f p95=%.3f", name, change.p50, change.p95))
        return change
    }

    @Test func aStoreChangeOnAHundredElementScreen() throws {
        let model = AppModel(document: LayerDocument())
        let store = model.store
        var nodes: [LayerNode] = []
        for row in 0..<25 {
            let y = 60 + 80 * CGFloat(row)
            nodes.append(.leaf(.text, frame: CGRect(x: 20, y: y, width: 228, height: 24), text: "Title \(row)", tint: Theme.accent))
            nodes.append(.leaf(.body, frame: CGRect(x: 20, y: y + 28, width: 353, height: 40), text: "Body \(row)", tint: Theme.accent))
            nodes.append(.leaf(.toggle, frame: CGRect(x: 322, y: y, width: 51, height: 31), tint: Theme.accent))
            nodes.append(.leaf(.divider, frame: CGRect(x: 20, y: y + 72, width: 353, height: 1), tint: Theme.accent))
        }
        let screen = store.addFreeScreen(nodes, name: "Screen", device: .iPhone, origin: CGPoint(x: 100, y: 50))
        try #require(nodes.count == 100)

        // What the runs change: row 12's title (moved and edited) and its body (resized).
        let moved = nodes[48].id, resized = nodes[49].id, texted = nodes[48].id

        let move = measure("move") { _ in store.update(moved) { $0.frame.origin.x += 1 } }
        let resize = measure("resize") { _ in store.update(resized) { $0.frame.size.width += 1 } }
        let text = measure("text") { _ in store.update(texted) { $0.content.text += "a" } }
        let add = measure("add") { run in
            let added = LayerNode.leaf(.text, frame: CGRect(x: 20, y: 2100, width: 228, height: 24), text: "Added \(run)", tint: Theme.accent)
            _ = store.add(added, to: .screen(screen))
            store.delete(nodes: [added.id])
        }

        // A sanity bound, not the budget.
        for result in [move, resize, text, add] {
            #expect(result.p95.isFinite && result.p95 < 1000)
        }
    }
}
