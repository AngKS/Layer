import SwiftUI

/// How a container places what it holds, in the Format panel: its layout, spacing, padding (not on a screen's root),
/// alignment and distribution, and a grid's columns. A screen's root is free or a column.
struct LayoutSection: View, Equatable {
    @Environment(AppModel.self) private var model
    let id: UUID
    let layout: LayerNode.Layout
    let padding: LayerNode.Padding
    let isScreenRoot: Bool
    let children: [LayerNode]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.layout == rhs.layout && lhs.padding == rhs.padding
            && lhs.isScreenRoot == rhs.isScreenRoot && lhs.children == rhs.children
    }

    var body: some View {
        PanelSection {
            PanelRow("Layout") {
                Picker("Layout", selection: Binding(get: { LayoutChoice(layout) }, set: choose)) {
                    ForEach(LayoutChoice.choices(forScreenRoot: isScreenRoot), id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Layout")
                Spacer(minLength: 0)
            }
            switch layout {
            case .free:
                EmptyView()
            case .stack:
                PanelRow("Spacing") {
                    NumberField("pt", label: "Spacing", value: stackBinding(\.spacing), range: 0...400)
                }
                paddingFields
                PanelRow("Align") {
                    Picker("Alignment", selection: stackBinding(\.alignment)) {
                        ForEach([LayerNode.CrossAlignment.start, .center, .end, .fill], id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Alignment")
                    Spacer(minLength: 0)
                }
                PanelRow("Distribute") {
                    Picker("Distribution", selection: stackBinding(\.justify)) {
                        ForEach([LayerNode.Justify.start, .center, .end, .spaceBetween, .spaceAround, .spaceEvenly], id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Distribution")
                    Spacer(minLength: 0)
                }
            case .grid(let grid):
                PanelRow("Columns") {
                    NumberField("#", label: "Columns", value: gridBinding { CGFloat($0.columns) } set: { $0.columns = Int($1.rounded()) }, range: 1...12)
                }
                HStack(spacing: 8) {
                    NumberField("C", label: "Column spacing", value: gridBinding(\.columnSpacing), range: 0...400)
                    NumberField("R", label: "Row spacing", value: gridBinding(\.rowSpacing), range: 0...400)
                }
                paddingFields
                edgePickers(grid.alignment) { alignment in
                    updateLayout { layout in
                        if case .grid(var grid) = layout { grid.alignment = alignment; layout = .grid(grid) }
                    }
                }
            case .overlay(let alignment):
                paddingFields
                edgePickers(alignment) { alignment in updateLayout { $0 = .overlay(alignment) } }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var paddingFields: some View {
        if !isScreenRoot {
            PanelRow("Padding") {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        NumberField("T", label: "Top padding", value: paddingBinding(\.top), range: 0...400)
                        NumberField("L", label: "Leading padding", value: paddingBinding(\.leading), range: 0...400)
                    }
                    HStack(spacing: 6) {
                        NumberField("B", label: "Bottom padding", value: paddingBinding(\.bottom), range: 0...400)
                        NumberField("R", label: "Trailing padding", value: paddingBinding(\.trailing), range: 0...400)
                    }
                }
            }
        }
    }

    /// A grid's or overlay's horizontal and vertical alignment. "Across" is the horizontal row's label: "Horizontal"
    /// is wider than the panel's label column and wrapped, as "Alignment" did. Its picker keeps the full words.
    @ViewBuilder private func edgePickers(_ alignment: LayerNode.Alignment, set: @escaping (LayerNode.Alignment) -> Void) -> some View {
        PanelRow("Across") {
            Picker("Horizontal alignment", selection: Binding(get: { alignment.horizontal }, set: { edge in
                var made = alignment
                made.horizontal = edge
                set(made)
            })) {
                ForEach([LayerNode.Edge3.start, .center, .end], id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Horizontal alignment")
            Spacer(minLength: 0)
        }
        PanelRow("Vertical") {
            Picker("Vertical alignment", selection: Binding(get: { alignment.vertical }, set: { edge in
                var made = alignment
                made.vertical = edge
                set(made)
            })) {
                ForEach([LayerNode.Edge3.start, .center, .end], id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Vertical alignment")
            Spacer(minLength: 0)
        }
    }

    // MARK: Writing

    private func choose(_ choice: LayoutChoice) {
        guard choice != LayoutChoice(layout) else { return }
        let id = id, layout = layout, children = children
        model.adjusting {
            let rhythm = model.store.tree.settings.tokens.rhythm
            model.store.setLayout(id, choice.layout(from: layout, children: children, rhythm: rhythm))
        }
    }

    private func updateLayout(_ body: @escaping (inout LayerNode.Layout) -> Void) {
        let id = id
        model.adjusting { model.store.updateLayout(id, body) }
    }

    private func stackBinding<Value>(_ keyPath: WritableKeyPath<LayerNode.Stack, Value>) -> Binding<Value> where Value: Equatable {
        Binding(
            get: { if case .stack(let stack) = layout { stack[keyPath: keyPath] } else { LayerNode.Stack(axis: .vertical)[keyPath: keyPath] } },
            set: { value in updateLayout { if case .stack(var stack) = $0 { stack[keyPath: keyPath] = value; $0 = .stack(stack) } } }
        )
    }

    private func gridBinding(_ keyPath: WritableKeyPath<LayerNode.Grid, CGFloat>) -> Binding<CGFloat> {
        gridBinding { $0[keyPath: keyPath] } set: { $0[keyPath: keyPath] = $1 }
    }

    private func gridBinding(get: @escaping (LayerNode.Grid) -> CGFloat, set: @escaping (inout LayerNode.Grid, CGFloat) -> Void) -> Binding<CGFloat> {
        Binding(
            get: { if case .grid(let grid) = layout { get(grid) } else { 0 } },
            set: { value in updateLayout { if case .grid(var grid) = $0 { set(&grid, value); $0 = .grid(grid) } } }
        )
    }

    private func paddingBinding(_ keyPath: WritableKeyPath<LayerNode.Padding, CGFloat>) -> Binding<CGFloat> {
        let id = id, padding = padding
        return Binding(get: { padding[keyPath: keyPath] }, set: { value in
            var made = padding
            made[keyPath: keyPath] = value
            model.adjusting { model.store.setPadding(id, made) }
        })
    }
}

extension LayerNode.CrossAlignment {
    var title: String {
        switch self {
        case .start: "Start"
        case .center: "Centre"
        case .end: "End"
        case .fill: "Fill"
        }
    }
}

extension LayerNode.Justify {
    var title: String {
        switch self {
        case .start: "Start"
        case .center: "Centre"
        case .end: "End"
        case .spaceBetween: "Space Between"
        case .spaceAround: "Space Around"
        case .spaceEvenly: "Space Evenly"
        }
    }
}

extension LayerNode.Edge3 {
    var title: String {
        switch self {
        case .start: "Start"
        case .center: "Centre"
        case .end: "End"
        }
    }
}

/// A laid-out child's Width and Height: Fit, Fill or Fixed along each axis, with a number when it is fixed. Its X and Y
/// are the parent's to give, so they are off.
struct SizingSection: View, Equatable {
    @Environment(AppModel.self) private var model
    let placed: PlacedNode

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.placed == rhs.placed }

    /// Whether X and Y can be typed: false under a laid-out parent, overlays included (call 10).
    static func isPositionEditable(for placed: PlacedNode) -> Bool { !placed.isLaidOut }

    var body: some View {
        // One view, so that `.equatable()` stacks the two rows rather than laying them over each other.
        VStack(alignment: .leading, spacing: 10) {
            axisRow("Width", unit: "W", axis: .horizontal)
            axisRow("Height", unit: "H", axis: .vertical)
        }
    }

    private func axisRow(_ name: String, unit: String, axis: LayerNode.Axis) -> some View {
        let sizing = axis == .horizontal ? placed.node.width : placed.node.height
        let choice = SizingChoice(sizing)
        let id = placed.node.id
        let points = axis == .horizontal ? placed.node.frame.width : placed.node.frame.height
        return VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker(name, selection: Binding(get: { choice }, set: { chosen in
                    model.adjusting { model.store.setSizing(id, axis: axis, chosen) }
                })) {
                    ForEach(SizingChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(name)
                if choice == .fixed {
                    NumberField(unit, label: name, value: Binding(get: { points }, set: { value in
                        model.adjusting { model.store.setSizing(id, axis: axis, .fixed, points: value) }
                    }), range: 1...4000)
                    .frame(width: 84)
                }
            }
        }
    }
}
