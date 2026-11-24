import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The sketch path's budgets (spec §13 and §5, plan 5's Task 12), held on every run: a reading after the pen rests, with
/// the structure pass after it, lands within 100 ms at the 95th percentile on a busy screen, and the pass looks only at
/// the container that received the reading.
@MainActor
@Suite struct SketchConversionBudgetTests {
    // MARK: Building screens

    /// The sketch corpus's fixtures placed on a screen: all of them iPhone sketches in the screen's own points.
    private static let fixtures: [SketchFixture] = {
        guard let resources = Bundle(for: BundleMarker.self).resourceURL,
              let loaded = try? SketchFixtureCorpus.load(from: resources) else { return [] }
        return loaded
    }()

    /// What a reading remembers of a sketch drawn at `frame` on an iPhone.
    private static func intent(_ frame: CGRect) -> LayerNode.SketchIntent {
        LayerNode.SketchIntent(sketched: frame, on: DeviceFrame.iPhone.size, margin: DeviceFrame.iPhone.margin,
                               confidence: 1, decidedBy: .rules)
    }

    /// A node as a reading makes one: its words and its kind's starting sizing.
    private static func sketched(_ kind: ElementKind, _ words: String = "") -> LayerNode {
        var node = LayerNode(kind: kind)
        node.content.text = words
        (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
        return node
    }

    /// A free iPhone screen of 100 sketched things: 25 rows down it, each holding a text, a body, a toggle and a divider,
    /// each of the 100 remembering its sketch where it is drawn. The rows are the person's (they have no sketch), so the
    /// pass never takes them; what is drawn on one of them lands in it.
    private static func sketchedScreen(_ name: String, at origin: CGPoint) -> TreeScreen {
        var screen = TreeScreen(name: name, origin: origin, scale: 1, deviceID: nil)
        screen.root.children = (0..<25).map { index in
            var row = LayerNode(kind: .group)
            row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8, alignment: .center))
            row.frame = CGRect(x: 20, y: 20 + 30 * CGFloat(index), width: 0, height: 0)
            row.width = LayerNode.Sizing(.fit)
            row.height = LayerNode.Sizing(.fit)
            row.children = [sketched(.text, "Label \(index)"), sketched(.body, "What setting \(index) does"),
                            sketched(.toggle), sketched(.divider)]
            return row
        }
        return screen
    }

    /// A design of `count` such screens side by side, laid out, each thing then remembering its sketch where it was laid
    /// out; opened as a document, so that making them is no step. An undo manager takes each reading's step.
    private static func makeModel(screens count: Int) -> (model: AppModel, screens: [TreeScreen], undo: UndoManager) {
        var tree = TreeContent()
        tree.screens = (0..<count).map { sketchedScreen("Settings \($0 + 1)", at: CGPoint(x: 500 * CGFloat($0), y: 0)) }
        TreeRules.apply(to: &tree, after: nil)
        for screen in tree.screens.indices {
            for row in tree.screens[screen].root.children.indices {
                let origin = tree.screens[screen].root.children[row].frame.origin
                for leaf in tree.screens[screen].root.children[row].children.indices {
                    let frame = tree.screens[screen].root.children[row].children[leaf].frame
                    tree.screens[screen].root.children[row].children[leaf].sketch =
                        intent(frame.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
        }
        let model = AppModel(document: LayerDocument(file: DesignFile(content: DesignContent(tree: tree))))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        return (model, model.store.tree.screens, undo)
    }

    // MARK: Reading

    /// A reading that became a node, and how long it took.
    private struct Timed {
        var id: UUID?
        var total: Duration
        var pass: Duration
    }

    /// A sketch read and put on `screenID` as the rules path converts one once the pen has rested (plan 5, calls 1 and
    /// 7): the sketch observed from its strokes, read by the rules with what the tree says is on the screen, and then,
    /// as one step, its node added where it lands and the structure pass over it. Nil, and nothing done, when the rules
    /// don't read it as a thing on a screen. The deliberate pauses, the 900 ms rest and the 750 ms re-trace, aren't in it.
    private static func convert(_ strokes: [[CGPoint]], on screenID: TreeScreen.ID, in model: AppModel) -> Timed? {
        let store = model.store
        let rules = RuleInterpreter()
        let start = ContinuousClock.now
        guard let observation = SketchAnalyzer.observe(SketchSamples.strokes(strokes)),
              let screen = store.treeScreen(screenID), let device = store.device(of: screenID) else { return nil }
        let request = SketchRequest(
            observation: observation,
            placement: .onScreen(local: screen.placement.localRect(for: observation.bounds),
                                 existing: store.sketchNeighbours(on: screenID), size: device.size),
            strokes: strokes)
        let reading = rules.reading(for: request)
        _ = rules.isCloseCall(request)
        guard case .element(let kind) = reading else { return nil }
        let confidence = request.scoredReadings.first { $0.reading == reading }?.score ?? 0
        var pass: Duration = .zero
        let id = store.asOwnStep { () -> UUID? in
            let id = store.addSketched(kind, from: observation.bounds, confidence: confidence, decidedBy: .rules) {
                $0.adoptMarks(of: observation)
            }
            let passStart = ContinuousClock.now
            if let id { model.structurePass(over: [id]) }
            pass = ContinuousClock.now - passStart
            return id
        }
        return Timed(id: id, total: ContinuousClock.now - start, pass: pass)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
    }

    /// The p50 and p95 of a list of times.
    private static func percentiles(_ times: [Double]) -> (p50: Double, p95: Double) {
        let sorted = times.sorted()
        return (sorted[sorted.count / 2], sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1])
    }

    /// Whether two boxes touch or overlap, as the pass's neighbourhood reads them.
    private static func meets(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }

    private static func containers(in node: LayerNode) -> [UUID] {
        guard node.isContainer else { return [] }
        return [node.id] + node.children.flatMap(containers)
    }

    // MARK: Budgets

    /// Every corpus sketch placed on a screen that the rules read as a thing there, read on the 100-thing screen and
    /// converted with its pass, then undone (untimed), so each lands on the same screen. The p95 is under 100 ms (§13),
    /// measured again while it is over, up to three times, failing only if all three are (F19).
    @Test func aReadingLandsWithinBudget() throws {
        let onScreen = Self.fixtures.filter { $0.placementKind == .onScreen }
        try #require(Self.fixtures.count == 156, "the sketch corpus")
        let (model, screens, undo) = Self.makeModel(screens: 1)
        let screen = try #require(screens.first)
        let before = model.store.tree
        try #require(before.screens[0].root.children.flatMap(\.children).count(where: { $0.sketch != nil }) == 100)

        var attempts: [(p50: Double, p95: Double)] = []
        var landed = 0
        for attempt in 1...3 {
            var readings: [Double] = [], passes: [Double] = []
            landed = 0
            for fixture in onScreen {
                guard let timed = Self.convert(fixture.strokePaths, on: screen.id, in: model) else { continue }
                readings.append(Self.milliseconds(timed.total))
                passes.append(Self.milliseconds(timed.pass))
                guard timed.id != nil else { continue }
                landed += 1
                // Untimed: the reading and its pass are one step, taken back, and nothing stays on offer or may grow.
                undo.undo()
                model.dismissStructureOffer()
                model.builtStructures = [:]
            }
            try #require(!readings.isEmpty)
            let reading = Self.percentiles(readings), pass = Self.percentiles(passes)
            print(String(format: "BENCH sketch reading p50=%.3f p95=%.3f n=%d attempt=%d", reading.p50, reading.p95, readings.count, attempt))
            print(String(format: "BENCH structure pass p50=%.3f p95=%.3f n=%d attempt=%d", pass.p50, pass.p95, passes.count, attempt))
            attempts.append(reading)
            if reading.p95 < 100 { break }
        }
        #expect(landed >= 100, "readings that became a thing on the screen: \(landed) of \(onScreen.count)")
        #expect(attempts.contains { $0.p95 < 100 }, "p95 per attempt: \(attempts.map(\.p95)) ms")
        #expect(model.store.tree == before, "each reading was one step, and undone")
    }

    /// Two such screens, and one reading drawn on A below its last row, by two of them. The pass's look at A's root takes
    /// in no more than what is within its reach of the new thing, and itself; the layout it causes is A's root and any
    /// container it builds, and nothing else on A or anything on B (F7: each container's own counts).
    @Test func thePassLooksOnlyAtTheReceivingContainer() throws {
        let (model, screens, _) = Self.makeModel(screens: 2)
        let store = model.store
        let (a, b) = (screens[0], screens[1])
        let containersA = Self.containers(in: a.root), containersB = Self.containers(in: b.root)
        #expect(containersA.count == 26 && containersB.count == 26, "each root and its 25 rows")
        let looked = StructureInference.neighbourhoodSizes(of: a.root.id).count
        let laidOut = Dictionary(uniqueKeysWithValues: (containersA + containersB).map { ($0, LayoutEngine.timesLaidOut($0)) })

        let timed = try #require(Self.convert(try StrokeScript.parse("box 20 785 100 60 8; cross 20 785 100 60"), on: a.id, in: model))
        let id = try #require(timed.id)
        #expect(store.index[id]?.parent == a.root.id, "it landed on A's root, below the rows")

        let sizes = StructureInference.neighbourhoodSizes(of: a.root.id)
        #expect(sizes.count == looked + 1, "the pass looked at A's root once")
        let root = try #require(store.treeScreen(a.id)?.root)
        let frame = try #require(root.children.first { $0.id == id }?.frame)
        let reach = StructureConventions.reach
        let withinReach = root.children.count { $0.id != id && Self.meets($0.frame.insetBy(dx: -reach, dy: -reach), frame) }
        #expect(withinReach >= 2, "the last two rows are within reach")
        #expect((sizes.last ?? .max) <= withinReach + 1, "neighbourhood \(sizes.last ?? -1), within reach \(withinReach)")

        func rise(_ container: UUID) -> Int { LayoutEngine.timesLaidOut(container) - (laidOut[container] ?? 0) }
        #expect(rise(a.root.id) >= 1, "A's root, which received it, was laid out")
        let built = Set(Self.containers(in: root)).subtracting(containersA)
        for container in containersA where container != a.root.id && !built.contains(container) {
            #expect(rise(container) == 0, "a row on A was laid out")
        }
        for container in containersB {
            #expect(rise(container) == 0, "a container on B was laid out")
        }
    }
}

/// Something in the test bundle, to find its resources.
private final class BundleMarker {}
