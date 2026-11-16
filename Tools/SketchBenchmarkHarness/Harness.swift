// A macOS command-line harness for Layer's sketch benchmark. Exists because Apple
// Intelligence calls fail in the iPadOS Simulator (ModelManagerError 1026; see the
// `layer-apple-intelligence-findings` memory note) but work when the same `Layer/Sketch`
// files are compiled for macOS. Build and run with `Tools/SketchBenchmarkHarness/run.sh`.
//
// Usage:
//   SketchBenchmarkHarness generate <fixtures-dir>        write the fixture corpus as JSON
//   SketchBenchmarkHarness run <fixtures-dir> [--model] [--out <report.json>]
//   SketchBenchmarkHarness healthcheck                    one small Apple Intelligence call
import CoreGraphics
import Foundation

@main
struct SketchBenchmarkHarness {
    static func main() async {
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
        case "explain":
            guard arguments.count > 3 else { printUsage(); exit(1) }
            explain(fixturesDir: arguments[2], idSubstring: arguments[3])
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
        print("Wrote \(fixtures.count) fixtures to \(directory.path)")
    }

    // MARK: run

    static func run(fixturesDir: String, withModel: Bool, outPath: String?) async {
        guard let fixtures = try? SketchFixtureCorpus.load(from: URL(fileURLWithPath: fixturesDir)) else {
            print("Couldn't load fixtures from \(fixturesDir)")
            exit(1)
        }
        print("Loaded \(fixtures.count) fixtures from \(fixturesDir)")

        let rulesCases = SketchBenchmarkRunner.runRulesOnly(fixtures)
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
