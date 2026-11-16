#if DEBUG
import CoreGraphics
import Foundation

// MARK: Fixture format
//
// A labelled sketch benchmark: strokes plus where they were drawn and what they are
// supposed to mean. Fixtures are generated from the same stroke generators the hand-written
// tests use (`SketchSamples`), and stored as JSON under `LayerTests/Fixtures`, so this is
// also the start of the recorded stroke corpus `magic-pen-expansion.md` §3G asks for.
// Used by `SketchBenchmarkTests` in the simulator (rules only; the model fails there) and
// by the macOS harness in `Tools/SketchBenchmarkHarness` (rules and the model).

/// One labelled sketch in the benchmark corpus.
struct SketchFixture: Codable, Sendable, Identifiable {
    /// `clean`: an unambiguous, canonical sketch. `jittered`: a clean sketch with a small
    /// seeded wobble added, as a hand would draw it. `noisy`: a larger seeded wobble.
    /// `confusable`: drawn deliberately near one of `SketchConventions`' dividing lines.
    enum Variant: String, Codable, Sendable { case clean, jittered, noisy, confusable }

    struct ExistingFixture: Codable, Sendable, Equatable {
        var kind: ElementKind
        var frame: [Double] // x, y, width, height
    }

    enum PlacementKind: String, Codable, Sendable { case openCanvas, onScreen }

    var id: String
    /// "screen", "scratchOut", "unknown", or an `ElementKind` raw value.
    var label: String
    var variant: Variant
    /// The name of the confusable pair this belongs to, such as "button-textField", shared
    /// by every fixture drawn for that pair regardless of which side it's meant to land on.
    var pair: String?
    var placementKind: PlacementKind
    var existing: [ExistingFixture]
    /// The device's width and height; `onScreen` fixtures only.
    var screenSize: [Double]?
    /// One array of `[x, y]` points per stroke.
    var strokes: [[[Double]]]
}

extension SketchFixture {
    var expectedReading: SketchReading {
        switch label {
        case "screen": .screen
        case "scratchOut": .scratchOut
        case "unknown": .unknown
        default: ElementKind(rawValue: label).map(SketchReading.element) ?? .unknown
        }
    }

    var strokePaths: [[CGPoint]] {
        strokes.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
    }

    /// Rebuilds the `SketchRequest` this fixture describes, or nil when its strokes don't
    /// observe as a sketch at all (too small), which is itself a result worth counting.
    func makeRequest() -> SketchRequest? {
        guard let observation = SketchAnalyzer.observe(SketchSamples.strokes(strokePaths)) else { return nil }
        let placement: SketchPlacement
        switch placementKind {
        case .openCanvas:
            placement = .openCanvas
        case .onScreen:
            let existingElements = existing.map {
                ExistingElement(kind: $0.kind, frame: CGRect(x: $0.frame[0], y: $0.frame[1], width: $0.frame[2], height: $0.frame[3]))
            }
            let size = screenSize.map { CGSize(width: $0[0], height: $0[1]) } ?? DeviceFrame.iPhone.size
            placement = .onScreen(local: observation.bounds, existing: existingElements, size: size)
        }
        return SketchRequest(observation: observation, placement: placement, strokes: strokePaths)
    }
}

enum SketchFixtureCorpus {
    static func load(from directory: URL) throws -> [SketchFixture] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        return try files.map { try decoder.decode(SketchFixture.self, from: Data(contentsOf: $0)) }
    }
}

// MARK: Seeded noise, for generating fixtures reproducibly

/// A tiny seeded generator (SplitMix64) so jittered and noisy fixtures are random but the
/// same corpus comes out every time it's generated.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension Array where Element == [CGPoint] {
    /// Adds independent random jitter to every point, using a seed so the result is
    /// reproducible. `amount` is the maximum offset in points along each axis.
    func seededJitter(amount: CGFloat, seed: UInt64) -> [[CGPoint]] {
        var generator = SeededGenerator(seed: seed)
        return map { stroke in
            stroke.map { point in
                CGPoint(
                    x: point.x + CGFloat.random(in: -amount...amount, using: &generator),
                    y: point.y + CGFloat.random(in: -amount...amount, using: &generator)
                )
            }
        }
    }
}

// MARK: Running fixtures through the engine

/// What happened when one fixture went through the rules, and (if asked) a provider.
struct SketchBenchmarkCase: Sendable {
    var fixture: SketchFixture
    var expected: SketchReading
    /// The request's candidates. Before Stage 1 this was an unscored, 1–3 item list;
    /// since Stage 1 it's `scoredReadings` ranked highest first, which can run longer
    /// (`smallControlScoredReadings` keeps everything scoring above 0.02) — `top3` is the
    /// metric that actually means "top 3" either way.
    var candidates: [SketchReading]
    /// The top 3 of `candidates`, ranked — meaningless as a ranking before Stage 1 (every
    /// candidate was equally "possible," none scored), genuinely top-3-by-score after it.
    var top3: [SketchReading]
    var rulesReading: SketchReading
    var escalated: Bool
    /// The rules' reading, overridden by the provider's when one ran and gave a reading
    /// that was one of the request's candidates — exactly what `SketchEngine.read` does.
    var finalReading: SketchReading
    var providerReading: SketchReading?
    var rulesLatency: Double // seconds
    var providerLatency: Double? // seconds
    /// False when the strokes were too small to observe as a sketch at all.
    var observed: Bool
}

enum SketchBenchmarkRunner {
    /// Runs every fixture through the rules alone. Always available: no model involved.
    static func runRulesOnly(_ fixtures: [SketchFixture]) -> [SketchBenchmarkCase] {
        let rules = RuleInterpreter()
        return fixtures.map { fixture in
            guard let request = fixture.makeRequest() else {
                return SketchBenchmarkCase(
                    fixture: fixture, expected: fixture.expectedReading, candidates: [], top3: [], rulesReading: .unknown,
                    escalated: false, finalReading: .unknown, providerReading: nil,
                    rulesLatency: 0, providerLatency: nil, observed: false
                )
            }
            let start = ContinuousClock.now
            let reading = rules.reading(for: request)
            let elapsed = (ContinuousClock.now - start).secondsValue
            let escalated = rules.isCloseCall(request)
            let scored = request.scoredReadings
            return SketchBenchmarkCase(
                fixture: fixture, expected: fixture.expectedReading, candidates: scored.map(\.reading),
                top3: scored.prefix(3).map(\.reading), rulesReading: reading,
                escalated: escalated, finalReading: reading, providerReading: nil,
                rulesLatency: elapsed, providerLatency: nil, observed: true
            )
        }
    }

    /// Runs every escalated fixture through `provider` too, replacing the rules' answer
    /// with the provider's exactly when `SketchEngine.read` would: a possible answer wins.
    static func runWithProvider(_ fixtures: [SketchFixture], provider: any SketchInterpreter) async -> [SketchBenchmarkCase] {
        var cases = runRulesOnly(fixtures)
        for index in cases.indices where cases[index].escalated && cases[index].observed {
            guard let request = cases[index].fixture.makeRequest() else { continue }
            let start = ContinuousClock.now
            do {
                let reading = try await provider.read(request)
                cases[index].providerLatency = (ContinuousClock.now - start).secondsValue
                cases[index].providerReading = reading
                if request.candidates.contains(reading) {
                    cases[index].finalReading = reading
                }
            } catch {
                cases[index].providerLatency = (ContinuousClock.now - start).secondsValue
            }
        }
        return cases
    }
}

extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

// MARK: Metrics

struct SketchBenchmarkReport: Codable, Sendable {
    struct KindAccuracy: Codable, Sendable { var label: String; var total: Int; var correct: Int; var accuracy: Double }
    struct ConfusionEntry: Codable, Sendable { var expected: String; var got: String; var count: Int }
    struct Latency: Codable, Sendable { var p50: Double; var p95: Double }

    var totalCases: Int
    var overallAccuracy: Double
    var perKind: [KindAccuracy]
    /// Misreadings only (`got != expected`), most common first.
    var confusions: [ConfusionEntry]
    /// Accuracy per confusable pair name, from fixtures tagged with `pair`.
    var pairAccuracy: [String: Double]
    /// How often the true kind is somewhere in `candidates` (a stand-in for top-3 recall
    /// until candidates carry real scores).
    var candidateRecall: Double
    /// How often the true kind is in the top 3 scored candidates. Before Stage 1 this is
    /// the same set `candidateRecall` measures, just truncated — there was no ranking to
    /// make "top 3" mean anything yet. After it, this is the metric the report's targets
    /// table actually means by "top-3 recall".
    var top3Recall: Double
    var escalationRate: Double
    /// nil when no provider ran against this corpus (the simulator can't call the model).
    var system2Accuracy: Double?
    var system2Count: Int
    var rulesLatency: Latency
    var system2Latency: Latency?
}

enum SketchBenchmarkMetrics {
    static func report(for cases: [SketchBenchmarkCase]) -> SketchBenchmarkReport {
        let observedCases = cases.filter(\.observed)
        let total = observedCases.count
        let correct = observedCases.count { $0.finalReading == $0.expected }

        var perKindTotals: [String: (total: Int, correct: Int)] = [:]
        var confusions: [String: Int] = [:]
        var pairTotals: [String: (total: Int, correct: Int)] = [:]
        var candidateHits = 0
        var top3Hits = 0
        var escalated = 0
        var system2Correct = 0
        var system2Total = 0
        var rulesLatencies: [Double] = []
        var system2Latencies: [Double] = []

        for one in observedCases {
            let key = SketchPrompt.name(for: one.expected)
            var kindTotals = perKindTotals[key] ?? (0, 0)
            kindTotals.total += 1
            if one.finalReading == one.expected { kindTotals.correct += 1 }
            perKindTotals[key] = kindTotals

            if one.finalReading != one.expected {
                let gotKey = SketchPrompt.name(for: one.finalReading)
                confusions["\(key)|\(gotKey)", default: 0] += 1
            }
            if let pair = one.fixture.pair {
                var pairTotalsEntry = pairTotals[pair] ?? (0, 0)
                pairTotalsEntry.total += 1
                if one.finalReading == one.expected { pairTotalsEntry.correct += 1 }
                pairTotals[pair] = pairTotalsEntry
            }
            if one.candidates.contains(one.expected) { candidateHits += 1 }
            if one.top3.contains(one.expected) { top3Hits += 1 }
            if one.escalated { escalated += 1 }
            if one.escalated, let providerReading = one.providerReading {
                system2Total += 1
                if providerReading == one.expected { system2Correct += 1 }
            }
            rulesLatencies.append(one.rulesLatency)
            if let providerLatency = one.providerLatency { system2Latencies.append(providerLatency) }
        }

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))
            return sorted[index]
        }

        return SketchBenchmarkReport(
            totalCases: total,
            overallAccuracy: total > 0 ? Double(correct) / Double(total) : 0,
            perKind: perKindTotals.map { label, value in
                .init(label: label, total: value.total, correct: value.correct, accuracy: Double(value.correct) / Double(value.total))
            }.sorted { $0.label < $1.label },
            confusions: confusions.map { key, count in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                return .init(expected: parts.first ?? "", got: parts.count > 1 ? parts[1] : "", count: count)
            }.sorted { $0.count > $1.count },
            pairAccuracy: pairTotals.mapValues { Double($0.correct) / Double($0.total) },
            candidateRecall: total > 0 ? Double(candidateHits) / Double(total) : 0,
            top3Recall: total > 0 ? Double(top3Hits) / Double(total) : 0,
            escalationRate: total > 0 ? Double(escalated) / Double(total) : 0,
            system2Accuracy: system2Total > 0 ? Double(system2Correct) / Double(system2Total) : nil,
            system2Count: system2Total,
            rulesLatency: .init(p50: percentile(rulesLatencies, 0.5), p95: percentile(rulesLatencies, 0.95)),
            system2Latency: system2Latencies.isEmpty ? nil : .init(p50: percentile(system2Latencies, 0.5), p95: percentile(system2Latencies, 0.95))
        )
    }
}
#endif
