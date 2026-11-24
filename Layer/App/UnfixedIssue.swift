import CoreGraphics
import Foundation

/// What is still wrong with a generated or imported screen after `TreeValidator.fixGenerated` and the layout, said to
/// the person in the import sheet and in the generation's status (spec §9). Nothing is corrected here, and what the
/// fix put right isn't among them.
enum UnfixedIssue: String, CaseIterable, Sendable {
    case runsOffTheScreen, overflowsItsContainer, textTooSmall, controlTooSmall

    var title: String {
        switch self {
        case .runsOffTheScreen: String(localized: "Runs off the screen")
        case .overflowsItsContainer: String(localized: "Doesn't fit its row, column or grid")
        case .textTooSmall: String(localized: "Text too small")
        case .controlTooSmall: String(localized: "Control too small")
        }
    }

    /// What the validator finds in `laidOut` on `device`, and what the layout engine reported while laying it out
    /// (`diagnostics`: its overflows), each with the nodes it is said of. When `generated` is given, only those nodes
    /// count: what the person made on the screen is never checked here.
    static func found(in laidOut: LayerNode, on device: DeviceFrame, diagnostics: [LayoutDiagnostic] = [],
                      among generated: Set<UUID>? = nil) -> [UnfixedIssue: [UUID]] {
        var found: [UnfixedIssue: [UUID]] = [:]
        func note(_ issue: UnfixedIssue, _ node: UUID?) {
            guard let node, generated.map({ $0.contains(node) }) ?? true, found[issue]?.contains(node) != true else { return }
            found[issue, default: []].append(node)
        }
        for issue in TreeValidator.check(laidOut, on: device) {
            switch issue.kind {
            case .clipped: note(.runsOffTheScreen, issue.node)
            case .smallText: note(.textTooSmall, issue.node)
            case .smallControl: note(.controlTooSmall, issue.node)
            case .notAllowedHere, .tooDeep, .tooMany, .badGeometry: break
            }
        }
        for diagnostic in diagnostics where diagnostic.kind == .overflow { note(.overflowsItsContainer, diagnostic.node) }
        return found
    }

    /// The kinds present in `found`, in the order of `allCases`, each with how many nodes.
    static func counts(_ found: [UnfixedIssue: [UUID]]) -> [(issue: UnfixedIssue, count: Int)] {
        allCases.compactMap { issue in found[issue].map { (issue, $0.count) } }
    }

    /// How many different nodes have an issue.
    static func nodes(in found: [UnfixedIssue: [UUID]]) -> Int { Set(found.values.joined()).count }

    /// `count` nodes with this issue, as a clause of a sentence ("1 thing runs off the screen").
    func clause(_ count: Int) -> String {
        let one = count == 1
        switch self {
        case .runsOffTheScreen: return one ? "1 thing runs off the screen" : "\(count) things run off the screen"
        case .overflowsItsContainer:
            return one ? "1 thing doesn't fit its row, column or grid" : "\(count) things don't fit their row, column or grid"
        case .textTooSmall: return one ? "1 text is too small" : "\(count) texts are too small"
        case .controlTooSmall: return one ? "1 control is too small" : "\(count) controls are too small"
        }
    }

    /// The clauses of `found`, one for each kind present, as a sentence's words ("A, B and C"). Empty when none.
    static func sentence(_ found: [UnfixedIssue: [UUID]]) -> String {
        let clauses = counts(found).map { $0.issue.clause($0.count) }
        guard let last = clauses.last else { return "" }
        return clauses.count == 1 ? last : clauses.dropLast().joined(separator: ", ") + " and " + last
    }
}
