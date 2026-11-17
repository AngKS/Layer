import CoreGraphics
import Foundation
import FoundationModels

/// What's already on the screen, for the sketch agent to ask about — structured facts
/// (kinds, positions, counts), not a second look at the ink itself, matching the report's
/// citation that general models underperform on raw UI imagery and should be given
/// structured results instead. `reports/Fast and slow sketch recognition.md`, Stage 4.
///
/// Capped at one useful call per decision: Foundation Models has no built-in round-trip
/// limit (confirmed absent from the SDK's tool-calling API before relying on it), so this
/// is enforced here — a second call in the same decision is told there's nothing further,
/// which gives the model no reason to call again and bounds the cost in code rather than
/// in the model's own judgement, exactly as the report recommends.
struct SketchContextTool: Tool {
    @Generable
    struct Arguments {}

    let existing: [ExistingElement]
    let local: CGRect
    let size: CGSize

    var name: String { "screenContext" }
    var description: String {
        "Returns the kind, position and size of every element already on this screen, and where the sketch itself sits relative to them. Call this at most once."
    }

    /// Shared across both calls to `call(arguments:)` a single decision might make, since
    /// a fresh `SketchContextTool` is built for every sketch read — never across sketches.
    private let callCount = CallCount()

    func call(arguments: Arguments) async throws -> String {
        guard await callCount.useFirst() else {
            return "Already called once for this decision; nothing further is available."
        }
        return Self.describe(existing: existing, local: local, size: size)
    }

    static func describe(existing: [ExistingElement], local: CGRect, size: CGSize) -> String {
        let band = local.midY < size.height / 3 ? "top third" : local.midY > size.height * 2 / 3 ? "bottom third" : "middle third"
        var lines = ["The sketch sits in the \(band) of the screen, at roughly (\(Int(local.midX)), \(Int(local.midY))) of \(Int(size.width))x\(Int(size.height))."]
        if existing.isEmpty {
            lines.append("Nothing else is on this screen yet.")
        } else {
            var counts: [String: Int] = [:]
            for element in existing { counts[element.kind.layerName, default: 0] += 1 }
            let countSummary = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)\($0.value == 1 ? "" : "s")" }.joined(separator: ", ")
            lines.append("Already on this screen: \(countSummary).")
            let positions = existing.sorted { $0.frame.minY < $1.frame.minY }.map { element in
                let elementBand = element.frame.midY < size.height / 3 ? "top" : element.frame.midY > size.height * 2 / 3 ? "bottom" : "middle"
                return "\(element.kind.layerName) in the \(elementBand) third"
            }
            lines.append("Top to bottom: \(positions.joined(separator: "; ")).")
        }
        return lines.joined(separator: " ")
    }
}

/// An actor purely so `SketchContextTool.call`, which Foundation Models can invoke
/// concurrently with itself in principle, serialises the one state this tool keeps.
private actor CallCount {
    private var used = false
    func useFirst() -> Bool {
        guard !used else { return false }
        used = true
        return true
    }
}
