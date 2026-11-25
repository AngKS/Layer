import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The panel that opens from the left: the design's layers, or its generated SwiftUI.
struct LayersPanel: View {
    @Environment(AppModel.self) private var model
    /// The screen whose code is shown; the first screen until another is picked.
    @State private var codeScreenID: TreeScreen.ID?
    /// In a narrow window the panel fills a sheet rather than floating beside the canvas.
    var isSheet = false
    /// The room there is for the floating panel.
    var maxHeight: CGFloat = 560

    var body: some View {
        let content = VStack(spacing: 0) {
            tabs
                .padding(12)
            switch model.panelTab {
            case .layers: LayersList()
            case .code: CodePane(screenID: $codeScreenID)
            }
        }
        if isSheet {
            content
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            content
                .frame(width: 300)
                .frame(maxHeight: min(560, maxHeight), alignment: .top)
                .background(.background, in: .rect(cornerRadius: 26, style: .continuous))
                .clipShape(.rect(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 22, y: 8)
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tab("Layers", .layers)
            tab("Code", .code)
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
    }

    private func tab(_ title: String, _ tab: AppModel.PanelTab) -> some View {
        let isActive = model.panelTab == tab
        return Button {
            withAnimation(.snappy(duration: 0.2)) { model.panelTab = tab }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isActive ? Color.white : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: Layers

/// The design's layers, topmost first under each screen, containers with what is in them nested beneath
/// (rows, columns and grids in layout order), then those on the open canvas, drawings in a section of their
/// own. Only this reads the design, the selection and the hover, which change on every frame of a drag and
/// every move of the pencil: each row is given what it shows, never a node, whose frame changes on every
/// frame, and is built again only when that changes. Read from the tree and its index.
private struct LayersList: View {
    @Environment(AppModel.self) private var model
    /// The containers left open, for this session. One with something selected in it is open
    /// whatever this says.
    @State private var openContainers: Set<UUID> = []

    /// A row and what is under it, when it is open.
    private struct Branch {
        var line: LayerLine
        var children: [Branch]
    }

    /// The flat rows of a host as nested branches, by depth.
    private static func branches(_ lines: [LayerLine]) -> [Branch] {
        var position = 0
        func level(_ depth: Int) -> [Branch] {
            var result: [Branch] = []
            while position < lines.count, lines[position].depth >= depth {
                let line = lines[position]
                position += 1
                result.append(Branch(line: line, children: line.depth == depth ? level(depth + 1) : []))
            }
            return result
        }
        return level(0)
    }

    var body: some View {
        let store = model.store
        let tree = store.tree, index = store.index
        let selection = model.selection
        let hovered = model.hovered
        let open = model.enteredGroups.union(openContainers)
        ScrollView {
            // Not lazy: a lazy stack built every row in view again on every change to the
            // design, whether or not what the row shows had changed.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tree.screens) { screen in
                    let target = CanvasSelection.screen(screen.id)
                    LayerHeadingRow(
                        model: model, countedAs: screen.id, name: screen.name, symbol: tree.device(of: screen).size.width > 600 ? "ipad" : "iphone",
                        target: target, isSelected: selection?.contains(target) == true, isHovered: hovered == target
                    )
                    .equatable()
                    branch(Self.branches(LayerRows.lines(on: .screen(screen.id), in: tree, index: index, open: open)),
                           open: open, parent: nil, selection: selection, hovered: hovered)
                }
                let drawings = LayerRows.drawings(in: tree).compactMap { id in
                    index.node(id, in: tree).flatMap { LayerRows.line(for: $0, in: .canvas, index: index) }
                }
                let floating = Self.branches(LayerRows.lines(on: .canvas, in: tree, index: index, open: open))
                if let first = drawings.first?.id ?? floating.first?.line.id {
                    LayerHeadingRow(model: model, countedAs: first, name: "Canvas", symbol: "square.dashed", target: nil, isSelected: false, isHovered: false)
                        .equatable()
                    if !drawings.isEmpty {
                        LayerSubheading(name: "Drawings")
                        ForEach(drawings) { line in
                            plainRow(line, selection: selection, hovered: hovered)
                        }
                    }
                    if !drawings.isEmpty && !floating.isEmpty { LayerSubheading(name: "Elements") }
                    branch(floating, open: open, parent: nil, selection: selection, hovered: hovered)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        // The container is outside the scroll view, as in the spike. Its drag container is what
        // lets a closed container's row take a drop.
        .reorderContainer(for: LayerItem.self, in: LayerDropList.self) { difference in
            move(difference)
        }
        .dragContainer(for: LayerItem.self) { ids in ids.map(LayerItem.init) }
    }

    /// What a drop in the list does: each row dragged lands where it was dropped, the whole
    /// drop one step to undo. A refused move leaves the list as it was, which is rebuilt from
    /// the design, so the row goes back.
    private func move(_ difference: ReorderDifference<UUID, LayerDropList>) {
        let list = difference.destination.collectionID
        let row: UUID? = switch difference.destination.position {
        case .before(let id): list.landing(before: id)
        case .end: list.landing(before: nil)
        }
        LayerRows.drop(difference.sources, in: list.list, above: row, layoutOrder: list.isLayoutOrder, store: model.store)
    }

    /// One list of rows: a screen's top level, the canvas's, or what is in a container, each an open
    /// container's own list under its row. Its rows can be dragged to reorder them, and into and out of
    /// the containers.
    private func branch(
        _ nodes: [Branch], open: Set<UUID>, parent: (list: LayerList, container: LayerLine)?,
        selection: CanvasSelection?, hovered: CanvasSelection?
    ) -> AnyView {
        // An open container's own list sits between its row and the rows after it, so a list is
        // shown in runs, each ending at an open container, as separate `ForEach`s of one collection.
        var runs: [[(index: Int, node: Branch)]] = [[]]
        for (index, node) in nodes.enumerated() {
            runs[runs.count - 1].append((index, node))
            if node.line.isOpen { runs.append([]) }
        }
        let lines = nodes.map(\.line)
        let isLayoutOrder = lines.first?.isLayoutOrder ?? false
        return AnyView(Group {
            ForEach(Array(runs.enumerated()), id: \.offset) { runIndex, run in
                // The end of a run that an open container's members come between and the rows after
                // them is not the end of the list: dropped there, a row lands before the next run's.
                if let list = lines.first?.list {
                    let dropList = LayerDropList(list: list, endsBefore: runs[(runIndex + 1)...].first?.first?.node.line.id, isLayoutOrder: isLayoutOrder)
                    ForEach(run, id: \.node.line.id) { index, node in
                        row(node.line, selection: selection, hovered: hovered)
                            .modifier(MoveActions(
                                model: model, id: node.line.id, list: list, siblings: lines, index: index,
                                intoContainerAbove: index > 0 && lines[index - 1].isContainer ? lines[index - 1] : nil,
                                outOf: parent
                            ))
                    }
                    .reorderable(collectionID: dropList)
                }
                if let last = run.last, last.node.line.isOpen {
                    branch(last.node.children, open: open, parent: (last.node.line.list, last.node.line), selection: selection, hovered: hovered)
                }
            }
        })
    }

    @ViewBuilder
    private func row(_ line: LayerLine, selection: CanvasSelection?, hovered: CanvasSelection?) -> some View {
        if line.isContainer {
            let target = CanvasSelection.element(line.ref)
            ContainerLayerRow(
                model: model, line: line,
                isHeldOpen: line.isOpen && !openContainers.contains(line.id),
                isSelected: selection?.contains(target) == true, isHovered: hovered == target,
                toggleOpen: { id in
                    if openContainers.contains(id) { openContainers.remove(id) } else { openContainers.insert(id) }
                }
            )
            .equatable()
            .modifier(DropIntoContainer(isClosed: !line.isOpen, model: model, container: line.id))
        } else {
            plainRow(line, selection: selection, hovered: hovered)
        }
    }

    private func plainRow(_ line: LayerLine, selection: CanvasSelection?, hovered: CanvasSelection?) -> some View {
        let target = CanvasSelection.element(line.ref)
        return LayerRow(model: model, line: line, isSelected: selection?.contains(target) == true, isHovered: hovered == target)
            .equatable()
    }
}

/// A list of rows that takes drops: one run of a list (see `LayersList.branch`).
struct LayerDropList: Hashable, Sendable {
    var list: LayerList
    /// The row after this run's last in the list, which a row dropped at the run's end lands
    /// before: the first row of the next run, past an open container's own members. Nil when the
    /// run is the last, and a row dropped at its end goes to the back of the list.
    var endsBefore: UUID?
    /// Whether the list is a row's, column's or grid's, first at the top: a drop's `before` is then the row
    /// above (`LayerRows.before`), and a drop at the last run's end is the front.
    var isLayoutOrder = false

    /// The row a drop lands above: the row dropped before, or for the end of this run, the
    /// next run's first (nil: below the last row).
    func landing(before id: UUID?) -> UUID? {
        id ?? endsBefore
    }
}

/// What a row's VoiceOver actions are: each only where it applies, and run as a drag's drop
/// is, animated.
private struct MoveActions: ViewModifier {
    let model: AppModel
    let id: UUID
    let list: LayerList
    /// The rows of the list, as the panel shows them.
    let siblings: [LayerLine]
    let index: Int
    let intoContainerAbove: LayerLine?
    let outOf: (list: LayerList, container: LayerLine)?

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if index > 0 { Button("Move Up") { run(above: siblings[index - 1].id) } }
            if index + 1 < siblings.count { Button("Move Down") { run(above: index + 2 < siblings.count ? siblings[index + 2].id : nil) } }
            if let container = intoContainerAbove {
                Button("Move Into \(container.name) Above") {
                    withAnimation(.snappy) { _ = model.store.moveLayerToTop(id, of: .node(container.id)) }
                }
            }
            if let outOf {
                Button("Move Out of \(outOf.container.name)") {
                    // Just above the container, in the list it is in: its own row's place.
                    withAnimation(.snappy) {
                        _ = LayerRows.drop([id], in: outOf.list, above: outOf.container.id, layoutOrder: outOf.container.isLayoutOrder, store: model.store)
                    }
                }
            }
        }
    }

    private func run(above row: UUID?) {
        withAnimation(.snappy) {
            _ = LayerRows.drop([id], in: list, above: row, layoutOrder: siblings.first?.isLayoutOrder ?? false, store: model.store)
        }
    }
}

/// A closed container's row takes a row dropped on it: it goes inside, at the top (the end of a row, column or grid). An open container's
/// row takes none, so that a drop on it is a reorder, above or below it.
private struct DropIntoContainer: ViewModifier {
    let isClosed: Bool
    let model: AppModel
    let container: UUID

    func body(content: Content) -> some View {
        if isClosed {
            content.dropDestination(for: LayerItem.self) { items, _ in
                let store = model.store
                var moved = false
                store.asOneStep {
                    for item in items { moved = store.moveLayerToTop(item.id, of: .node(container)) || moved }
                }
                return moved
            }
        } else {
            content
        }
    }
}

/// A row being dragged in the Layers panel: the thing it stands for.
struct LayerItem: Identifiable, Sendable, Codable, Transferable {
    var id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// What picking a layer in the list does: the thing is added to the selection or taken out
/// (see `AppModel.pickInList(_:)`), with the palette put away.
@MainActor
private func pickLayer(_ selection: CanvasSelection, in model: AppModel) {
    model.pickInList(selection)
}

/// Hovering over a row outlines its layer on the canvas.
@MainActor
private func hoverLayer(_ target: CanvasSelection?, _ isInside: Bool, in model: AppModel) {
    guard let target else { return }
    if isInside {
        model.isHoveringList = true
        model.hovered = target
    } else if model.hovered == target {
        model.isHoveringList = false
        model.hovered = nil
    }
}

/// A row is filled when its layer is selected, and tinted while it is hovered over, here
/// or on the canvas.
private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
    if isSelected { return Color(uiColor: .secondarySystemFill) }
    if isHovered { return Color.accentColor.opacity(0.10) }
    return .clear
}

/// The label of a section inside the canvas's layers.
private struct LayerSubheading: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The heading for a screen's layers, which selects the screen, or for the layers on the
/// open canvas. Like a layer's row, it is built from what it shows alone (see `LayerRow`).
private struct LayerHeadingRow: View, Equatable {
    /// For what a tap and hover do; not part of what the heading shows.
    let model: AppModel
    /// What its builds are counted under: its screen, or for the canvas's heading the first thing under it.
    let countedAs: UUID
    let name: String
    let symbol: String
    /// What the heading picks: its screen, or nothing for the open canvas.
    let target: CanvasSelection?
    let isSelected: Bool
    let isHovered: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.countedAs == b.countedAs && a.name == b.name && a.symbol == b.symbol && a.target == b.target && a.isSelected == b.isSelected && a.isHovered == b.isHovered
    }

    var body: some View {
        #if DEBUG
        let _ = LayersPanelWork.rowBuilt(countedAs)
        #endif
        Button {
            if let target { pickLayer(target, in: model) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(rowFill(isSelected: isSelected, isHovered: isHovered), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hoverLayer(target, $0, in: model) }
        .onDisappear { hoverLayer(target, false, in: model) }
        .disabled(target == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// How far each level of a group's members is indented.
private let layerIndent: CGFloat = 16

/// A lock or eye on a layer's row.
@MainActor
private func rowToggle(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 36)
            .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
}

/// A layer's lock and eye, which show when they are on, or when it is selected. The lock is
/// on when the layer is locked by a group above it too, and then offers Unlock, which
/// unlocks those groups with it; the eye is the layer's own, the dimming showing a group's.
@MainActor
@ViewBuilder
private func rowToggles(
    model: AppModel, ref: NodeRef, name: String,
    isLocked: Bool, isHidden: Bool, isLockedByGroup: Bool, isSelected: Bool
) -> some View {
    let locked = isLocked || isLockedByGroup
    if isSelected || locked {
        rowToggle(locked ? "Unlock \(name)" : "Lock \(name)", symbol: locked ? "lock.fill" : "lock.open") { model.toggleLock(ref) }
    }
    if isSelected || isHidden {
        rowToggle(isHidden ? "Show \(name)" : "Hide \(name)", symbol: isHidden ? "eye.slash" : "eye") { model.toggleHidden(ref) }
    }
}

/// One layer's row, with its lock and eye. It is given what it shows, and compared by that
/// alone, so that it is built again only when that changes: not for a change elsewhere in the
/// design, such as each frame of a drag, nor for the hover moving between other rows. It
/// reads nothing from the model or the environment that would build it again otherwise.
private struct LayerRow: View, Equatable {
    /// For what a tap, the lock, the eye and hover do; not part of what the row shows.
    let model: AppModel
    let line: LayerLine
    let isSelected: Bool
    let isHovered: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.isSelected == b.isSelected && a.isHovered == b.isHovered
    }

    var body: some View {
        #if DEBUG
        let _ = LayersPanelWork.rowBuilt(line.id)
        #endif
        HStack(spacing: 0) {
            Button {
                // A hidden layer can still be picked here, its outline showing where it is.
                pickLayer(.element(line.ref), in: model)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: line.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(line.name)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 12 + CGFloat(line.depth) * layerIndent)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line.name)
            .accessibilityValue(rowValue(isGroup: false, isHidden: line.isHidden, isDimmed: line.isDimmed, isLocked: line.isLocked, isLockedByGroup: line.isLockedByAncestor))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            rowToggles(model: model, ref: line.ref, name: line.name, isLocked: line.isLocked, isHidden: line.isHidden, isLockedByGroup: line.isLockedByAncestor, isSelected: isSelected)
            Spacer().frame(width: 4)
        }
        .opacity(line.isDimmed ? 0.5 : 1)
        .background(rowFill(isSelected: isSelected, isHovered: isHovered), in: .rect(cornerRadius: 10))
        .onHover { hoverLayer(.element(line.ref), $0, in: model) }
        .onDisappear { hoverLayer(.element(line.ref), false, in: model) }
    }
}

/// A container's row: a chevron that opens it to show what is in it, the icon of its layout and its name, and the
/// lock and eye that act on the container, and so on everything in it. Built from what it shows alone, like
/// `LayerRow`.
private struct ContainerLayerRow: View, Equatable {
    let model: AppModel
    let line: LayerLine
    /// Open because something in it is selected or gone into, not because it was opened: it
    /// closes when that does, and its chevron has nothing to do.
    let isHeldOpen: Bool
    let isSelected: Bool
    let isHovered: Bool
    /// Opens or closes the container; not part of what the row shows.
    let toggleOpen: (UUID) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.isHeldOpen == b.isHeldOpen && a.isSelected == b.isSelected && a.isHovered == b.isHovered
    }

    var body: some View {
        #if DEBUG
        let _ = LayersPanelWork.rowBuilt(line.id)
        #endif
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { toggleOpen(line.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(line.isOpen ? 90 : 0))
                    .frame(width: 28, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isHeldOpen)
            .accessibilityLabel("Contents")
            .accessibilityValue(line.isOpen ? "Expanded" : "Collapsed")
            .padding(.leading, 2 + CGFloat(line.depth) * layerIndent)

            Button {
                pickLayer(.element(line.ref), in: model)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: line.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(line.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line.name)
            .accessibilityValue(rowValue(isGroup: true, isHidden: line.isHidden, isDimmed: line.isDimmed, isLocked: line.isLocked, isLockedByGroup: line.isLockedByAncestor))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            rowToggles(model: model, ref: line.ref, name: line.name, isLocked: line.isLocked, isHidden: line.isHidden, isLockedByGroup: line.isLockedByAncestor, isSelected: isSelected)
            Spacer().frame(width: 4)
        }
        .opacity(line.isDimmed ? 0.5 : 1)
        .background(rowFill(isSelected: isSelected, isHovered: isHovered), in: .rect(cornerRadius: 10))
        .onHover { hoverLayer(.element(line.ref), $0, in: model) }
        .onDisappear { hoverLayer(.element(line.ref), false, in: model) }
    }
}

/// What VoiceOver says of a row besides its name: that it is a group, and hidden or locked,
/// by itself or only by the group above it.
func rowValue(isGroup: Bool, isHidden: Bool, isDimmed: Bool, isLocked: Bool, isLockedByGroup: Bool) -> String {
    var parts: [String] = []
    if isGroup { parts.append("Group") }
    if isHidden { parts.append("Hidden") } else if isDimmed { parts.append("Hidden by its group") }
    if isLocked { parts.append("Locked") } else if isLockedByGroup { parts.append("Locked by its group") }
    return parts.joined(separator: ", ")
}

// MARK: Code

/// The Code tab: a screen's SwiftUI, made once the screen has stopped changing rather than on
/// every frame of a drag, and coloured once for each time it is made.
struct CodePane: View {
    @Environment(AppModel.self) private var model
    /// The screen whose code is shown; the first screen until another is picked.
    @Binding var screenID: TreeScreen.ID?
    @State private var preview = CodePreview()

    var body: some View {
        let tree = model.store.tree
        if let screen = tree.screens.first(where: { $0.id == screenID }) ?? tree.screens.first {
            // Each view named as the shared files name it, so no two are the same.
            let context = SwiftUICodeGenerator.Context(tree)
            let shown = CodePreview.Shown(screen: screen, context: context, settings: tree.settings.code)
            HStack {
                Menu {
                    ForEach(tree.screens) { other in
                        Button(SwiftUICodeGenerator.fileName(for: other, in: context)) { screenID = other.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(SwiftUICodeGenerator.fileName(for: screen, in: context))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                CodeOptionsMenu()
                CopyButton(text: preview.source)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            CodeView(lines: preview.lines)
                // Each change to the screen starts this again, which cancels the wait before.
                .task(id: shown) { await preview.show(shown) }
        }
    }
}

/// A screen's code as the Code tab shows it, and its lines coloured.
@MainActor @Observable
final class CodePreview {
    /// What the code is made from: the screen, what its code needs from the design (its view's
    /// name among the design's screens, the tokens, the devices), and the code settings.
    struct Shown: Equatable {
        var screen: TreeScreen
        var context: SwiftUICodeGenerator.Context
        var settings: CodeSettings

        /// The code, as Share and Siri write it.
        var source: String {
            SwiftUICodeGenerator.code(for: screen, in: context, settings: settings)
        }
    }

    /// How long a screen has to stay as it is before its code is made again.
    static let settle: Duration = .milliseconds(300)

    private(set) var source = ""
    private(set) var lines: [AttributedString] = []
    @ObservationIgnored private var shown: Shown?

    /// Makes the code for a screen. A new screen's shows at once; a change to the one shown,
    /// once it has stayed as it is for `settle`. Called again meanwhile, the wait is cancelled.
    func show(_ wanted: Shown) async {
        guard wanted != shown else { return }
        if shown?.screen.id == wanted.screen.id {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
        }
        shown = wanted
        source = wanted.source
        lines = source.components(separatedBy: "\n").map(SwiftHighlighter.attributed)
        #if DEBUG
        LayersPanelWork.codeMade(source, for: wanted.screen.id)
        #endif
    }
}

/// The code's settings, beside the code they change.
private struct CodeOptionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.store.canvas.code
        Menu {
            Picker("Layout", selection: binding(\.layout, settings.layout)) {
                ForEach(CodeSettings.Layout.allCases, id: \.self) { layout in
                    Text(layout.name).tag(layout)
                }
            }
            Toggle("Include Preview", isOn: binding(\.includesPreview, settings.includesPreview))
            Toggle("Title as Navigation Title", isOn: binding(\.usesNavigationTitle, settings.usesNavigationTitle))
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .accessibilityLabel("Code Options")
        .padding(.trailing, 6)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CodeSettings, Value>, _ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { new in model.store.updateCanvas { $0.code[keyPath: keyPath] = new } })
    }
}

private struct CopyButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Source code with line numbers and syntax colours, a line at a time. Long lines run off
/// the edge and can be scrolled to.
private struct CodeView: View {
    let lines: [AttributedString]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)")
                            .foregroundStyle(Theme.codeLineNumber)
                            .frame(width: 22, alignment: .trailing)
                        Text(line)
                    }
                    .lineLimit(1)
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }
}

#if DEBUG
/// How often the panel builds a layer's row and generates a screen's code: for the tests
/// that hold it to doing so only when what it shows has changed. Counted per id, since suites run side by
/// side and each panel its own: a row under its node's id (a heading under its screen's, or for the canvas's
/// under the first thing below it), code under its screen's. A test sums over its own board's ids (F9).
@MainActor
enum LayersPanelWork {
    private static var rowCounts: [UUID: Int] = [:]
    private static var codeCounts: [UUID: Int] = [:]
    private static var codesMade: [UUID: String] = [:]

    static func rowBuilt(_ id: UUID) { rowCounts[id, default: 0] += 1 }

    /// How many times the row for `id` has been built.
    static func rows(of id: UUID) -> Int { rowCounts[id] ?? 0 }

    static func codeMade(_ code: String, for screen: UUID) {
        codeCounts[screen, default: 0] += 1
        codesMade[screen] = code
    }

    /// How many times the code for a screen has been made.
    static func codes(for screen: UUID) -> Int { codeCounts[screen] ?? 0 }

    /// The code last made for a screen.
    static func lastCode(for screen: UUID) -> String { codesMade[screen] ?? "" }
}
#endif
