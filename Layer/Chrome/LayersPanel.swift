import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The panel that opens from the left: the design's layers, or its generated SwiftUI.
struct LayersPanel: View {
    @Environment(AppModel.self) private var model
    /// The screen whose code is shown; the first screen until another is picked.
    @State private var codeScreenID: DesignScreen.ID?
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

/// The design's layers, topmost first under each screen, groups with their members nested
/// beneath, then those on the open canvas, drawings in a section of their own. Only this reads
/// the design, the selection and the hover, which change on every frame of a drag and every
/// move of the pencil: each row is given what it shows, never a `LayerListNode` or element, whose
/// frames change on every frame, and is built again only when that changes.
private struct LayersList: View {
    @Environment(AppModel.self) private var model
    /// The groups left open, for this session. One with something selected in it is open
    /// whatever this says.
    @State private var openGroups: Set<DesignElement.ID> = []

    /// One row of the list: a thing, how far in it is, and whether it is open, for a group.
    private struct Line: Identifiable {
        var node: LayerListNode
        var depth: Int
        var isOpen: Bool
        var id: DesignElement.ID { node.id }
    }

    var body: some View {
        let store = model.store
        let selection = model.selection
        let hovered = model.hovered
        let entered = model.enteredGroups
        ScrollView {
            // Not lazy: a lazy stack built every row in view again on every change to the
            // design, whether or not what the row shows had changed.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.screens) { screen in
                    let target = CanvasSelection.screen(screen.id)
                    LayerHeadingRow(
                        model: model, name: screen.name, symbol: screen.device.size.width > 600 ? "ipad" : "iphone", target: target,
                        isSelected: selection?.contains(target) == true, isHovered: hovered == target
                    )
                    .equatable()
                    branch(store.layerTree(on: .screen(screen.id)), in: .host(.screen(screen.id)), parent: nil, depth: 0, entered: entered, selection: selection, hovered: hovered)
                }
                let drawings = store.drawings.compactMap { ref in store.element(ref.element).map { (ref, $0) } }
                let floating = store.layerTree(on: .canvas)
                if !drawings.isEmpty || !floating.isEmpty {
                    LayerHeadingRow(model: model, name: "Canvas", symbol: "square.dashed", target: nil, isSelected: false, isHovered: false)
                        .equatable()
                    if !drawings.isEmpty {
                        LayerSubheading(name: "Drawings")
                        ForEach(drawings, id: \.0.element) { ref, drawing in
                            let target = CanvasSelection.element(ref)
                            plainRow(drawing, ref: ref, depth: 0, isDimmed: drawing.isHidden, isLockedByGroup: false, isSelected: selection?.contains(target) == true, isHovered: hovered == target)
                        }
                    }
                    if !drawings.isEmpty && !floating.isEmpty { LayerSubheading(name: "Elements") }
                    branch(floating, in: .host(.canvas), parent: nil, depth: 0, entered: entered, selection: selection, hovered: hovered)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        // The container is outside the scroll view, as in the spike. Its drag container is what
        // lets a closed group's row take a drop.
        .reorderContainer(for: LayerItem.self, in: LayerDropList.self) { difference in
            move(difference)
        }
        .dragContainer(for: LayerItem.self) { ids in ids.map(LayerItem.init) }
    }

    /// What a drop in the list does: each row dragged lands where it was dropped, the whole
    /// drop one step to undo. A refused move leaves the list as it was, which is rebuilt from
    /// the design, so the row goes back.
    private func move(_ difference: ReorderDifference<DesignElement.ID, LayerDropList>) {
        let list = difference.destination.collectionID
        let before: DesignElement.ID? = switch difference.destination.position {
        case .before(let id): list.landing(before: id)
        case .end: list.landing(before: nil)
        }
        let store = model.store
        store.asOneStep {
            for id in difference.sources {
                store.moveLayer(id, to: list.list, before: before)
            }
        }
    }

    /// One list of rows: a screen's top level, the canvas's, or what is in a group, topmost
    /// first, each an open group's own list under its row. Its rows can be dragged to reorder
    /// them, and into and out of the groups.
    private func branch(
        _ nodes: [LayerListNode], in list: LayerList, parent: (list: LayerList, group: DesignElement.ID)?, depth: Int,
        entered: Set<DesignElement.ID>, selection: CanvasSelection?, hovered: CanvasSelection?
    ) -> AnyView {
        // An open group's own list sits between its row and the rows after it, so a list is
        // shown in runs, each ending at an open group, as separate `ForEach`s of one collection.
        var runs: [[(index: Int, node: LayerListNode)]] = [[]]
        for (index, node) in nodes.enumerated() {
            runs[runs.count - 1].append((index, node))
            if isOpen(node, entered: entered) { runs.append([]) }
        }
        return AnyView(Group {
            ForEach(Array(runs.enumerated()), id: \.offset) { runIndex, run in
                // The end of a run that an open group's members come between and the rows after
                // them is not the end of the list: dropped there, a row lands before the next run's.
                let dropList = LayerDropList(list: list, endsBefore: runs[(runIndex + 1)...].first?.first?.node.id)
                ForEach(run, id: \.node.id) { index, node in
                    row(Line(node: node, depth: depth, isOpen: isOpen(node, entered: entered)), selection: selection, hovered: hovered)
                        .modifier(MoveActions(
                            model: model, id: node.id,
                            up: index > 0 ? .before(nodes[index - 1].id) : nil,
                            down: index + 1 < nodes.count ? .before(index + 2 < nodes.count ? nodes[index + 2].id : nil) : nil,
                            list: list,
                            intoGroupAbove: index > 0 && nodes[index - 1].element.kind == .group ? nodes[index - 1].id : nil,
                            outOf: parent
                        ))
                }
                .reorderable(collectionID: dropList)
                if let last = run.last, isOpen(last.node, entered: entered) {
                    branch(last.node.children, in: .group(last.node.id), parent: (list, last.node.id), depth: depth + 1, entered: entered, selection: selection, hovered: hovered)
                }
            }
        })
    }

    private func isOpen(_ node: LayerListNode, entered: Set<DesignElement.ID>) -> Bool {
        node.element.kind == .group && (entered.contains(node.id) || openGroups.contains(node.id))
    }

    @ViewBuilder
    private func row(_ line: Line, selection: CanvasSelection?, hovered: CanvasSelection?) -> some View {
        let node = line.node
        let target = CanvasSelection.element(node.ref)
        let isSelected = selection?.contains(target) == true
        let isHovered = hovered == target
        let isLockedByGroup = node.isLockedWithItsGroups && !node.element.isLocked
        if node.element.kind == .group {
            GroupLayerRow(
                model: model, ref: node.ref, name: node.element.displayName, isLocked: node.element.isLocked, isHidden: node.element.isHidden,
                isLockedByGroup: isLockedByGroup, isDimmed: node.isHiddenWithItsGroups, depth: line.depth, isOpen: line.isOpen,
                isHeldOpen: line.isOpen && !openGroups.contains(node.id),
                isSelected: isSelected, isHovered: isHovered,
                toggleOpen: { id in
                    if openGroups.contains(id) { openGroups.remove(id) } else { openGroups.insert(id) }
                }
            )
            .equatable()
            .modifier(DropIntoGroup(isClosed: !line.isOpen, model: model, group: node.id))
        } else {
            plainRow(node.element, ref: node.ref, depth: line.depth, isDimmed: node.isHiddenWithItsGroups, isLockedByGroup: isLockedByGroup, isSelected: isSelected, isHovered: isHovered)
        }
    }

    private func plainRow(
        _ element: DesignElement, ref: DesignStore.ElementRef, depth: Int, isDimmed: Bool, isLockedByGroup: Bool, isSelected: Bool, isHovered: Bool
    ) -> some View {
        LayerRow(
            model: model, ref: ref, symbol: element.symbol.map(SystemSymbol.resolve) ?? element.kind.symbol, name: element.displayName,
            isLocked: element.isLocked, isHidden: element.isHidden, isLockedByGroup: isLockedByGroup, isDimmed: isDimmed,
            depth: depth, isSelected: isSelected, isHovered: isHovered
        )
        .equatable()
    }
}

/// A list of rows that takes drops: one run of a list (see `LayersList.branch`).
struct LayerDropList: Hashable, Sendable {
    var list: LayerList
    /// The row after this run's last in the list, which a row dropped at the run's end lands
    /// before: the first row of the next run, past an open group's own members. Nil when the
    /// run is the last, and a row dropped at its end goes to the back of the list.
    var endsBefore: DesignElement.ID?

    /// The row a drop lands before: the row dropped before, or for the end of this run, the
    /// next run's first (nil: the back of the list).
    func landing(before id: DesignElement.ID?) -> DesignElement.ID? {
        id ?? endsBefore
    }
}

/// What a row's VoiceOver actions are: each only where it applies, and run as a drag's drop
/// is, animated.
private struct MoveActions: ViewModifier {
    enum Spot { case before(DesignElement.ID?) }

    let model: AppModel
    let id: DesignElement.ID
    let up: Spot?
    let down: Spot?
    let list: LayerList
    let intoGroupAbove: DesignElement.ID?
    let outOf: (list: LayerList, group: DesignElement.ID)?

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let up { Button("Move Up") { run(up) } }
            if let down { Button("Move Down") { run(down) } }
            if let group = intoGroupAbove {
                Button("Move Into Group Above") {
                    withAnimation(.snappy) { _ = model.store.moveLayerToTop(id, of: .group(group)) }
                }
            }
            if let outOf {
                Button("Move Out of Group") {
                    withAnimation(.snappy) { _ = model.store.moveLayer(id, to: outOf.list, before: outOf.group) }
                }
            }
        }
    }

    private func run(_ spot: Spot?) {
        guard case .before(let before)? = spot else { return }
        withAnimation(.snappy) { _ = model.store.moveLayer(id, to: list, before: before) }
    }
}

/// A closed group's row takes a row dropped on it: it goes inside, at the top. An open group's
/// row takes none, so that a drop on it is a reorder, above or below it.
private struct DropIntoGroup: ViewModifier {
    let isClosed: Bool
    let model: AppModel
    let group: DesignElement.ID

    func body(content: Content) -> some View {
        if isClosed {
            content.dropDestination(for: LayerItem.self) { items, _ in
                let store = model.store
                var moved = false
                store.asOneStep {
                    for item in items { moved = store.moveLayerToTop(item.id, of: .group(group)) || moved }
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
    var id: DesignElement.ID

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
    let name: String
    let symbol: String
    /// What the heading picks: its screen, or nothing for the open canvas.
    let target: CanvasSelection?
    let isSelected: Bool
    let isHovered: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.symbol == b.symbol && a.target == b.target && a.isSelected == b.isSelected && a.isHovered == b.isHovered
    }

    var body: some View {
        #if DEBUG
        let _ = LayersPanelWork.rowBuilt()
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
    model: AppModel, ref: DesignStore.ElementRef, name: String,
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
    let ref: DesignStore.ElementRef
    let symbol: String
    let name: String
    /// Its own lock and hide.
    let isLocked: Bool
    let isHidden: Bool
    /// Locked, though not by itself: by a group above it.
    let isLockedByGroup: Bool
    /// Hidden, by itself or by a group above it.
    let isDimmed: Bool
    let depth: Int
    let isSelected: Bool
    let isHovered: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.ref == b.ref && a.symbol == b.symbol && a.name == b.name && a.isLocked == b.isLocked
            && a.isHidden == b.isHidden && a.isLockedByGroup == b.isLockedByGroup && a.isDimmed == b.isDimmed
            && a.depth == b.depth && a.isSelected == b.isSelected && a.isHovered == b.isHovered
    }

    var body: some View {
        #if DEBUG
        let _ = LayersPanelWork.rowBuilt()
        #endif
        HStack(spacing: 0) {
            Button {
                // A hidden layer can still be picked here, its outline showing where it is.
                pickLayer(.element(ref), in: model)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(name)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 12 + CGFloat(depth) * layerIndent)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(rowValue(isGroup: false, isHidden: isHidden, isDimmed: isDimmed, isLocked: isLocked, isLockedByGroup: isLockedByGroup))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            rowToggles(model: model, ref: ref, name: name, isLocked: isLocked, isHidden: isHidden, isLockedByGroup: isLockedByGroup, isSelected: isSelected)
            Spacer().frame(width: 4)
        }
        .opacity(isDimmed ? 0.5 : 1)
        .background(rowFill(isSelected: isSelected, isHovered: isHovered), in: .rect(cornerRadius: 10))
        .onHover { hoverLayer(.element(ref), $0, in: model) }
        .onDisappear { hoverLayer(.element(ref), false, in: model) }
    }
}

/// A group's row: a chevron that opens it to show its members, its icon and name, and the lock
/// and eye that act on the group, and so on everything in it. Built from what it shows alone,
/// like `LayerRow`.
private struct GroupLayerRow: View, Equatable {
    let model: AppModel
    let ref: DesignStore.ElementRef
    let name: String
    let isLocked: Bool
    let isHidden: Bool
    let isLockedByGroup: Bool
    let isDimmed: Bool
    let depth: Int
    let isOpen: Bool
    /// Open because something in it is selected or gone into, not because it was opened: it
    /// closes when that does, and its chevron has nothing to do.
    let isHeldOpen: Bool
    let isSelected: Bool
    let isHovered: Bool
    /// Opens or closes the group; not part of what the row shows.
    let toggleOpen: (DesignElement.ID) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.ref == b.ref && a.name == b.name && a.isLocked == b.isLocked && a.isHidden == b.isHidden
            && a.isLockedByGroup == b.isLockedByGroup && a.isDimmed == b.isDimmed && a.depth == b.depth
            && a.isOpen == b.isOpen && a.isHeldOpen == b.isHeldOpen && a.isSelected == b.isSelected && a.isHovered == b.isHovered
    }

    var body: some View {
        #if DEBUG
        let _ = LayersPanelWork.rowBuilt()
        #endif
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { toggleOpen(ref.element) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 28, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isHeldOpen)
            .accessibilityLabel("Contents")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .padding(.leading, 2 + CGFloat(depth) * layerIndent)

            Button {
                pickLayer(.element(ref), in: model)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(rowValue(isGroup: true, isHidden: isHidden, isDimmed: isDimmed, isLocked: isLocked, isLockedByGroup: isLockedByGroup))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            rowToggles(model: model, ref: ref, name: name, isLocked: isLocked, isHidden: isHidden, isLockedByGroup: isLockedByGroup, isSelected: isSelected)
            Spacer().frame(width: 4)
        }
        .opacity(isDimmed ? 0.5 : 1)
        .background(rowFill(isSelected: isSelected, isHovered: isHovered), in: .rect(cornerRadius: 10))
        .onHover { hoverLayer(.element(ref), $0, in: model) }
        .onDisappear { hoverLayer(.element(ref), false, in: model) }
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
    @Binding var screenID: DesignScreen.ID?
    @State private var preview = CodePreview()

    var body: some View {
        let screens = model.store.screens
        if let screen = screens.first(where: { $0.id == screenID }) ?? screens.first {
            // Each view named as the shared files name it, so no two are the same.
            let typeNames = SwiftUICodeGenerator.typeNames(for: screens)
            let shown = CodePreview.Shown(screen: screen, typeName: typeNames[screen.id], settings: model.store.canvas.code)
            HStack {
                Menu {
                    ForEach(screens) { other in
                        Button((typeNames[other.id] ?? other.typeName) + ".swift") { screenID = other.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text((typeNames[screen.id] ?? screen.typeName) + ".swift")
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
private final class CodePreview {
    /// What the code is made from: the screen, the name its view is given among the
    /// design's screens, and the code settings.
    struct Shown: Equatable {
        var screen: DesignScreen
        var typeName: String?
        var settings: CodeSettings
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
        source = SwiftUICodeGenerator.code(for: wanted.screen, typeName: wanted.typeName, settings: wanted.settings)
        lines = source.components(separatedBy: "\n").map(SwiftHighlighter.attributed)
        #if DEBUG
        LayersPanelWork.codeMade(source)
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
/// that hold it to doing so only when what it shows has changed.
@MainActor
enum LayersPanelWork {
    static var rows = 0
    static var codes = 0

    static func rowBuilt() { rows += 1 }
    /// The code last made.
    static var lastCode = ""

    static func codeMade(_ code: String) {
        codes += 1
        lastCode = code
    }

    static func reset() {
        rows = 0
        codes = 0
        lastCode = ""
    }
}
#endif
