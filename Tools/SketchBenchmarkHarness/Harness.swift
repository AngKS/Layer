// A macOS command-line harness for Layer's sketch benchmark. Exists because Apple
// Intelligence calls fail in the iPadOS Simulator (ModelManagerError 1026; see the
// `layer-apple-intelligence-findings` memory note) but work when the same `Layer/Sketch`
// files are compiled for macOS. Build and run with `Tools/SketchBenchmarkHarness/run.sh`.
//
// Usage:
//   SketchBenchmarkHarness generate <fixtures-dir>        write the fixture corpus as JSON
//   SketchBenchmarkHarness run <fixtures-dir> [--model] [--out <report.json>]
//   SketchBenchmarkHarness check [<fixtures-dir>]         builds, reads every fixture with the rules (no model)
//   SketchBenchmarkHarness healthcheck                    one small Apple Intelligence call
import CoreGraphics
import Foundation

@main
struct SketchBenchmarkHarness {
    static func main() async {
        // No app bundle here, so GlyphMatcher can't find GlyphTemplates.json via
        // Bundle.main the way the real app does; point it at the file directly, assuming
        // run.sh's convention of running from the repo root.
        let defaultTemplates = URL(fileURLWithPath: "Layer/Resources/GlyphTemplates.json")
        if FileManager.default.fileExists(atPath: defaultTemplates.path) {
            GlyphMatcher.templatesFileOverride = defaultTemplates
        }

        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            printUsage()
            exit(1)
        }
        switch arguments[1] {
        case "generate":
            guard arguments.count > 2 else { printUsage(); exit(1) }
            await generate(to: arguments[2])
        case "run":
            guard arguments.count > 2 else { printUsage(); exit(1) }
            let withModel = arguments.contains("--model")
            let outPath = outputPath(arguments)
            await run(fixturesDir: arguments[2], withModel: withModel, outPath: outPath)
        case "glyphs":
            guard arguments.count > 2 else { printUsage(); exit(1) }
            writeGlyphTemplates(to: arguments[2])
        case "glyphtest":
            guard arguments.count > 2 else { printUsage(); exit(1) }
            glyphTest(templatesPath: arguments[2])
        case "explain":
            guard arguments.count > 3 else { printUsage(); exit(1) }
            explain(fixturesDir: arguments[2], idSubstring: arguments[3])
        case "handwritingtest":
            await handwritingTest()
        case "structure":
            guard arguments.count > 2 else { printUsage(); exit(1) }
            structure(fixturesDir: arguments[2], verbose: arguments.contains("--verbose"))
        case "check":
            await check(fixturesDir: arguments.count > 2 ? arguments[2] : "LayerTests/Fixtures")
        case "healthcheck":
            await healthcheck()
        default:
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage:
          SketchBenchmarkHarness generate <fixtures-dir>
          SketchBenchmarkHarness run <fixtures-dir> [--model] [--out <report.json>]
          SketchBenchmarkHarness check [<fixtures-dir>]
          SketchBenchmarkHarness structure <fixtures-dir> [--verbose]
          SketchBenchmarkHarness healthcheck
        """)
    }

    static func outputPath(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: generate

    static func generate(to directoryPath: String) async {
        let directory = URL(fileURLWithPath: directoryPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Clear old fixtures first so a renamed or removed fixture doesn't linger.
        if let existing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in existing where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
        }
        let fixtures = FixtureGenerator.all()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var byID: [String: Int] = [:]
        for fixture in fixtures {
            byID[fixture.id, default: 0] += 1
        }
        let duplicates = byID.filter { $0.value > 1 }
        if !duplicates.isEmpty {
            print("Duplicate fixture ids: \(duplicates.keys.sorted())")
            exit(1)
        }
        for fixture in fixtures {
            guard let data = try? encoder.encode(fixture) else { continue }
            try? data.write(to: directory.appendingPathComponent("\(fixture.id).json"))
        }
        let structure = StructureFixtureGenerator.all()
        for fixture in structure {
            guard let data = try? encoder.encode(fixture) else { continue }
            try? data.write(to: directory.appendingPathComponent("\(fixture.id).json"))
        }
        print("Wrote \(fixtures.count) fixtures and \(structure.count) structure fixtures to \(directory.path)")
    }

    // MARK: check

    /// Reads every fixture with the rules alone, and the one outline round two things that
    /// makes a card, so that a build that compiles but can't read fails here. Needs no model.
    static func check(fixturesDir: String) async {
        guard let fixtures = try? SketchFixtureCorpus.load(from: URL(fileURLWithPath: fixturesDir)), !fixtures.isEmpty else {
            print("harness FAILED: couldn't load fixtures from \(fixturesDir)")
            exit(1)
        }
        let cases = await SketchBenchmarkRunner.runRulesOnly(fixtures)
        guard cases.count == fixtures.count else {
            print("harness FAILED: \(cases.count) of \(fixtures.count) fixtures read")
            exit(1)
        }
        let outline = SketchSamples.strokes([SketchSamples.box(CGRect(x: 10, y: 100, width: 373, height: 130), radius: 16)])
        let title = ExistingElement(kind: .title, frame: CGRect(x: 96, y: 120, width: 200, height: 40))
        let body = ExistingElement(kind: .body, frame: CGRect(x: 20, y: 170, width: 353, height: 40))
        guard let observation = SketchAnalyzer.observe(outline),
              RuleInterpreter().reading(for: SketchRequest(
                  observation: observation,
                  placement: .onScreen(local: observation.bounds, existing: [title, body]),
                  strokes: []
              )) == .element(.card)
        else {
            print("harness FAILED: an outline round two things didn't read as a card")
            exit(1)
        }
        print("harness ok: \(fixtures.count) fixtures read")
    }

    // MARK: structure

    /// Runs every `structure-` fixture through the rules, `SketchedNode` and the structure pass, and prints how many came
    /// out as expected, how many near misses grouped, and the pass's p50 and p95.
    static func structure(fixturesDir: String, verbose: Bool) {
        guard let fixtures = try? StructureBenchmark.load(from: URL(fileURLWithPath: fixturesDir)), !fixtures.isEmpty else {
            print("structure FAILED: couldn't load structure fixtures from \(fixturesDir)")
            exit(1)
        }
        var asExpected = 0, nearMissesGrouped = 0
        var times: [Double] = []
        for fixture in fixtures {
            let found = StructureBenchmark.run(fixture)
            times.append(found.passSeconds)
            let right = fixture.isAsExpected(label: found.label, decision: found.decision)
            if right { asExpected += 1 }
            if fixture.variant == .nearMiss, found.label != "none" { nearMissesGrouped += 1 }
            if verbose || !right {
                print("  \(right ? "ok  " : "WRONG") \(fixture.id): \(found.label) \(found.decision) (expected \(fixture.label) \(fixture.expected))")
            }
        }
        print("structure: \(fixtures.count) fixtures, \(asExpected) as expected, near misses grouped \(nearMissesGrouped)")
        let sorted = times.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))]
        }
        print(String(format: "pass p50/p95: %.4fms / %.4fms", percentile(0.5) * 1000, percentile(0.95) * 1000))
    }

    // MARK: run

    static func run(fixturesDir: String, withModel: Bool, outPath: String?) async {
        guard let fixtures = try? SketchFixtureCorpus.load(from: URL(fileURLWithPath: fixturesDir)) else {
            print("Couldn't load fixtures from \(fixturesDir)")
            exit(1)
        }
        print("Loaded \(fixtures.count) fixtures from \(fixturesDir)")

        let rulesCases = await SketchBenchmarkRunner.runRulesOnly(fixtures)
        let rulesReport = SketchBenchmarkMetrics.report(for: rulesCases)
        print("\n=== Rules only ===")
        printSummary(rulesReport)

        var modelReport: SketchBenchmarkReport?
        if withModel {
            print("\nRunning the escalated cases through Apple Intelligence…")
            let modelCases = await SketchBenchmarkRunner.runWithProvider(fixtures, provider: AppleIntelligenceInterpreter())
            let report = SketchBenchmarkMetrics.report(for: modelCases)
            modelReport = report
            print("\n=== Rules + Apple Intelligence ===")
            printSummary(report)
        }

        if let outPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            struct Combined: Codable { var rulesOnly: SketchBenchmarkReport; var withModel: SketchBenchmarkReport? }
            if let data = try? encoder.encode(Combined(rulesOnly: rulesReport, withModel: modelReport)) {
                try? data.write(to: URL(fileURLWithPath: outPath))
                print("\nWrote report to \(outPath)")
            }
        }
    }

    static func printSummary(_ report: SketchBenchmarkReport) {
        print("Total cases: \(report.totalCases)")
        print(String(format: "Overall accuracy: %.1f%%", report.overallAccuracy * 100))
        print(String(format: "Candidate-set recall: %.1f%%", report.candidateRecall * 100))
        print(String(format: "Top-3 recall: %.1f%%", report.top3Recall * 100))
        print(String(format: "Escalation rate: %.1f%%", report.escalationRate * 100))
        if let system2 = report.system2Accuracy {
            print(String(format: "System 2 accuracy (escalated, n=%d): %.1f%%", report.system2Count, system2 * 100))
        }
        print(String(format: "Rules latency p50/p95: %.4fms / %.4fms", report.rulesLatency.p50 * 1000, report.rulesLatency.p95 * 1000))
        if let system2Latency = report.system2Latency {
            print(String(format: "System 2 latency p50/p95: %.1fms / %.1fms", system2Latency.p50 * 1000, system2Latency.p95 * 1000))
        }
        if let handwriting = report.handwritingLatency {
            print(String(format: "Handwriting recognizer latency p50/p95: %.1fms / %.1fms", handwriting.p50 * 1000, handwriting.p95 * 1000))
        }
        print("\nPer kind:")
        for kind in report.perKind {
            let label = kind.label.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("  \(label)\(kind.correct)/\(kind.total)  " + String(format: "%.1f%%", kind.accuracy * 100))
        }
        if !report.pairAccuracy.isEmpty {
            print("\nConfusable pairs:")
            for (pair, accuracy) in report.pairAccuracy.sorted(by: { $0.key < $1.key }) {
                let label = pair.padding(toLength: 24, withPad: " ", startingAt: 0)
                print("  \(label)" + String(format: "%.1f%%", accuracy * 100))
            }
        }
        if !report.confusions.isEmpty {
            print("\nConfusions (expected -> got):")
            for confusion in report.confusions {
                print("  \(confusion.expected) -> \(confusion.got): \(confusion.count)")
            }
        }
    }

    // MARK: glyphs

    static func writeGlyphTemplates(to path: String) {
        let examples = GlyphTemplateGenerator.all()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(examples) else {
            print("Couldn't encode glyph templates")
            exit(1)
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("Wrote \(examples.count) glyph examples to \(path)")
    }

    // MARK: handwritingtest (debug)

    /// A crude smoke test with letter-shaped (not geometric) strokes, to check
    /// `PKStrokeRecognizer` can recognise *something* via this harness's synthetic
    /// `PKStroke` construction, not just reliably return nil. Printed capital "HI": two
    /// verticals and a crossbar, then one vertical — not realistic handwriting dynamics
    /// (constant speed and pressure), so this is a mechanism check, not an accuracy one.
    static func handwritingTest() async {
        let h: [[CGPoint]] = [
            [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 40)],
            [CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 40)],
            [CGPoint(x: 0, y: 20), CGPoint(x: 20, y: 20)],
        ]
        let i: [[CGPoint]] = [[CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40)]]
        if let text = await HandwritingRecognizer.recognize(h + i) {
            print("\"HI\"-shaped strokes recognised as: \"\(text)\"")
        } else {
            print("\"HI\"-shaped strokes: no text recognised")
        }
        if let text = await HandwritingRecognizer.recognize([SketchSamples.circle(center: CGPoint(x: 0, y: 0), radius: 15)]) {
            print("circle-shaped stroke recognised as: \"\(text)\"")
        } else {
            print("circle-shaped stroke: no text recognised")
        }
    }

    // MARK: glyphtest (debug)

    static func glyphTest(templatesPath: String) {
        GlyphMatcher.templatesFileOverride = URL(fileURLWithPath: templatesPath)
        let cases: [(String, [[CGPoint]])] = [
            ("fresh circle r18", [SketchSamples.circle(center: CGPoint(x: 100, y: 100), radius: 18)]),
            ("fresh circle r9, jittered", [SketchSamples.circle(center: CGPoint(x: 0, y: 0), radius: 9)].seededJitter(amount: 3, seed: 42)),
            ("fresh square r2", [SketchSamples.box(CGRect(x: 0, y: 0, width: 26, height: 26), radius: 2)]),
            ("fresh square r2, jittered", [SketchSamples.box(CGRect(x: 0, y: 0, width: 26, height: 26), radius: 2)].seededJitter(amount: 3, seed: 7)),
            ("fresh tick", [SketchSamples.tick(CGRect(x: 0, y: 0, width: 28, height: 28))]),
            ("fresh cross", SketchSamples.cross(CGRect(x: 0, y: 0, width: 28, height: 28))),
            ("fresh plus", [
                SketchSamples.straight(from: CGPoint(x: -14, y: 0), to: CGPoint(x: 14, y: 0)),
                SketchSamples.straight(from: CGPoint(x: 0, y: -14), to: CGPoint(x: 0, y: 14)),
            ]),
        ]
        for (label, strokes) in cases {
            if let result = GlyphMatcher.match(strokes) {
                print("\(label): \(result.glyph) (confidence \(String(format: "%.2f", result.confidence)))")
            } else {
                print("\(label): no match")
            }
        }
    }

    // MARK: explain (debug)

    static func explain(fixturesDir: String, idSubstring: String) {
        guard let fixtures = try? SketchFixtureCorpus.load(from: URL(fileURLWithPath: fixturesDir)) else {
            print("Couldn't load fixtures from \(fixturesDir)")
            exit(1)
        }
        for fixture in fixtures where fixture.id.contains(idSubstring) {
            guard let request = fixture.makeRequest() else {
                print("\(fixture.id): didn't observe")
                continue
            }
            if let glyph = GlyphMatcher.match(fixture.strokePaths) {
                print("  glyph: \(glyph.glyph) (\(glyph.confidence))")
            } else {
                print("  glyph: no match")
            }
            if case .enclosure(let roundness, let inner) = request.observation.form {
                let ratio = request.observation.bounds.width / request.observation.bounds.height
                let fraction: CGFloat
                if case .onScreen(_, _, let size) = request.placement {
                    fraction = request.observation.bounds.width / size.width
                } else {
                    fraction = -1
                }
                print("\(fixture.id) [expected \(fixture.label)]: roundness=\(roundness) inner=\(inner) ratio=\(ratio) fraction=\(fraction)")
            } else {
                print("\(fixture.id) [expected \(fixture.label)]: form=\(request.observation.form)")
            }
            print("  scored: \(request.scoredReadings)")
        }
    }

    // MARK: healthcheck

    static func healthcheck() async {
        let interpreter = AppleIntelligenceInterpreter()
        print("Readiness: \(AppleIntelligenceInterpreter.readiness)")
        let start = ContinuousClock.now
        do {
            let title = try await interpreter.suggestTitle(for: "The board has one screen. Screen 1, an iPhone screen, has from top to bottom: a title saying \u{201C}Welcome\u{201D}.")
            print("suggestTitle answered \"\(title)\" in \((ContinuousClock.now - start).secondsValue)s")
        } catch {
            print("suggestTitle failed: \(error)")
        }
    }
}
