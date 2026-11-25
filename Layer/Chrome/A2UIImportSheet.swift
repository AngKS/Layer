import SwiftUI

/// What an A2UI import made and what it couldn't bring in as it was written: for each reason, what it says, how
/// often, and the components it was said of.
struct A2UIImportSheet: View {
    let report: A2UIImportReport
    let onDone: () -> Void

    /// How many of a reason's components are named before the rest are counted.
    private static let namedComponents = 12

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(report.groups, id: \.reason) { group in
                        row(for: group)
                    }
                    ForEach(UnfixedIssue.counts(report.unfixed), id: \.issue) { found in
                        unfixedRow(found.issue, count: found.count)
                    }
                } header: {
                    Text(report.screens.isEmpty
                         ? "No screen could be made from this A2UI."
                         : report.groups.isEmpty ? "Some of it doesn't fit as it was written."
                         : "Some of it isn't brought in as it was written.")
                        .textCase(nil)
                }
            }
            .navigationTitle(report.screens.isEmpty
                             ? Text("Nothing Imported")
                             : Text("Imported ^[\(report.screens.count) Screen](inflect: true)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
    }

    private func row(for group: A2UIImportReport.Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title)
                Spacer(minLength: 8)
                Text(group.diagnostics.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            let ids = Self.componentIDs(in: group)
            if !ids.isEmpty {
                Text(Self.listing(ids))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            // What is said of no one component, such as a file that couldn't be read, is said as it was.
            ForEach(Self.messagesOfNoComponent(in: group), id: \.self) { message in
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// What is still wrong with the screens made, and how many things it is said of.
    private func unfixedRow(_ issue: UnfixedIssue, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(issue.title)
            Spacer(minLength: 8)
            Text(count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The components a reason was said of, each once, in the order they were.
    private static func componentIDs(in group: A2UIImportReport.Group) -> [String] {
        var seen: Set<String> = []
        return group.diagnostics.compactMap(\.componentID).filter { seen.insert($0).inserted }
    }

    /// What the diagnostics that name no component say, each once, and no more than three of them.
    private static func messagesOfNoComponent(in group: A2UIImportReport.Group) -> [String] {
        var seen: Set<String> = []
        let messages = group.diagnostics.filter { $0.componentID == nil }.map(\.message).filter { seen.insert($0).inserted }
        return Array(messages.prefix(3))
    }

    private static func listing(_ ids: [String]) -> String {
        let named = ids.prefix(namedComponents).joined(separator: ", ")
        guard ids.count > namedComponents else { return named }
        return String(localized: "\(named) and \(ids.count - namedComponents) more")
    }
}

extension View {
    /// Shows an A2UI import's report in a sheet while it needs showing (`A2UIImportReport.needsShowing`): something
    /// wasn't brought in as it was written, or no screen was made. Done, or swiping it away, puts it away.
    func a2uiImportSheet(_ report: Binding<A2UIImportReport?>) -> some View {
        sheet(item: Binding(
            get: { report.wrappedValue.flatMap { $0.needsShowing ? $0 : nil } },
            set: { report.wrappedValue = $0 }
        )) { shown in
            A2UIImportSheet(report: shown) { report.wrappedValue = nil }
        }
    }
}
