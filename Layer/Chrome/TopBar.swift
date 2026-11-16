import SwiftUI
import UniformTypeIdentifiers

/// The floating pill that holds a row of controls.
struct ToolbarPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(5)
            .background(Theme.chrome, in: .capsule)
            .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

/// A control's icon, on a grey disc when the control is on.
struct ToolIcon: View {
    let symbol: String
    var isActive = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(width: 40, height: 40)
            .background(isActive ? Theme.chromeActive : .clear, in: .circle)
            .contentShape(.circle)
    }
}

struct ToolButton: View {
    let symbol: String
    let label: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolIcon(symbol: symbol, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Across the top: the way out and the board's name, the things that can be added to the
/// board, and sharing and formatting. When the window is too narrow to lay the tools out,
/// they fold into a menu beside the actions. Either way the bar starts clear of the
/// window's own controls.
struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // The tools sit in the middle for as long as the title and the actions leave
            // them room there, then slide aside.
            HStack(spacing: 12) {
                TitleBar()
                    .frame(maxWidth: .infinity, alignment: .leading)
                ToolsBar()
                ActionsBar()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .onAppear { model.isCompactWidth = false }
            // Narrow: the tools are a menu, and a long title is cut short. The controls
            // along the bottom draw together to match.
            HStack(spacing: 8) {
                TitleBar(isCutToFit: true)
                Spacer(minLength: 0)
                ActionsBar(holdsTools: true)
            }
            .onAppear { model.isCompactWidth = true }
        }
        .containerCornerOffset(.leading, sizeToFit: true)
    }
}

/// Top left: back to the document browser, and the board's name. Tapping the name opens
/// the board's menu: its name, to rename it, and the canvas's settings.
private struct TitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Whether the name gives way, ending in an ellipsis, when the row is short of room.
    var isCutToFit = false

    var body: some View {
        ToolbarPill {
            ToolButton(symbol: "chevron.left", label: "Designs") {
                // The design goes back to the browser with its picture and its name up to date.
                Task {
                    await model.prepareToClose()
                    dismiss()
                }
            }
            @Bindable var model = model
            Button {
                model.openBoardMenu()
            } label: {
                HStack(spacing: 6) {
                    Text(model.store.title ?? "Untitled")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize(horizontal: !isCutToFit, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.label)
                        .rotationEffect(.degrees(model.isBoardMenuOpen ? 180 : 0))
                        .animation(.snappy(duration: 0.2), value: model.isBoardMenuOpen)
                }
                .padding(.trailing, 14)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Board title")
            .accessibilityValue(model.store.title ?? "Untitled")
            .accessibilityHint("Rename the board and change the canvas settings")
            .popover(isPresented: $model.isBoardMenuOpen, arrowEdge: .top) {
                BoardMenu(isSheet: model.isCompactSizeClass)
                    .environment(model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Theme.panel)
                    .preferredColorScheme(.light)
            }
        }
    }
}

/// Top centre: the layers panel on its own, then everything that puts something on the board.
private struct ToolsBar: View {
    @Environment(AppModel.self) private var model
    @State private var isPickingSymbol = false
    @State private var isAttaching = false

    var body: some View {
        HStack(spacing: 10) {
            ToolbarPill {
                ToolButton(symbol: "square.3.layers.3d", label: "Layers", isActive: model.isLayersOpen) {
                    withAnimation(.smooth(duration: 0.3)) { model.isLayersOpen.toggle() }
                }
            }
            ToolbarPill {
                ToolButton(symbol: "pencil.tip.crop.circle", label: "Draw", isActive: model.tool == .draw) {
                    model.tool = model.tool == .draw ? .select : .draw
                }
                ToolButton(symbol: "character.textbox", label: "Text") {
                    withAnimation(.smooth(duration: 0.3)) { model.addText() }
                }
                Menu {
                    FrameChoices()
                } label: {
                    ToolIcon(symbol: "iphone")
                }
                .accessibilityLabel("Frames")
                ToolButton(symbol: "note.text", label: "Sticky note") {
                    withAnimation(.smooth(duration: 0.3)) { model.addStickyNote() }
                }
                ToolButton(symbol: "square.on.circle", label: "Symbols", isActive: isPickingSymbol) {
                    isPickingSymbol = true
                }
                .popover(isPresented: $isPickingSymbol) {
                    SymbolPicker { name in
                        isPickingSymbol = false
                        withAnimation(.smooth(duration: 0.3)) { model.addSymbol(name) }
                    }
                }
                ToolButton(symbol: "paperclip", label: "Attach image") {
                    isAttaching = true
                }
            }
        }
        .buttonStyle(.plain)
        .modifier(ImageAttaching(isAttaching: $isAttaching))
    }
}

/// The tools folded into one button, for a window too narrow to lay them out.
private struct ToolsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var isPickingSymbol = false
    @State private var isAttaching = false

    var body: some View {
        @Bindable var model = model
        Menu {
            Toggle("Layers", systemImage: "square.3.layers.3d", isOn: $model.isLayersOpen)
            Toggle("Draw", systemImage: "pencil.tip.crop.circle", isOn: Binding(
                get: { model.tool == .draw },
                set: { model.tool = $0 ? .draw : .select }
            ))
            Divider()
            Button("Text", systemImage: "character.textbox") {
                withAnimation(.smooth(duration: 0.3)) { model.addText() }
            }
            Menu("Frames", systemImage: "iphone") {
                FrameChoices()
            }
            Button("Sticky Note", systemImage: "note.text") {
                withAnimation(.smooth(duration: 0.3)) { model.addStickyNote() }
            }
            Button("Symbols", systemImage: "square.on.circle") { isPickingSymbol = true }
            Button("Attach Image", systemImage: "paperclip") { isAttaching = true }
        } label: {
            ToolIcon(symbol: "ellipsis")
        }
        .accessibilityLabel("Tools")
        .popover(isPresented: $isPickingSymbol) {
            SymbolPicker { name in
                isPickingSymbol = false
                withAnimation(.smooth(duration: 0.3)) { model.addSymbol(name) }
            }
        }
        .modifier(ImageAttaching(isAttaching: $isAttaching))
    }
}

/// The devices a frame can be added for.
private struct FrameChoices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(DeviceFrame.all) { device in
            Button("\(device.name)  \(Int(device.size.width)) × \(Int(device.size.height))") {
                withAnimation(.smooth(duration: 0.3)) { model.addFrame(device) }
            }
        }
    }
}

/// Picking an image file and adding it to the board, wherever the button for it is.
private struct ImageAttaching: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isAttaching: Bool
    @State private var hasFailed = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isAttaching, allowedContentTypes: [.png, .jpeg, .heic]) { result in
                attach(result)
            }
            .alert("That file couldn't be added as an image.", isPresented: $hasFailed) {
                Button("OK", role: .cancel) {}
            }
    }

    private func attach(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        // A file picked from outside the app is only readable between these two calls.
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let prepared = ImageImport.prepare(data) else {
            hasFailed = true
            return
        }
        withAnimation(.smooth(duration: 0.3)) { model.addImage(prepared) }
    }
}

/// Top right: sharing, and the paintbrush that opens settings for the selection or the canvas.
private struct ActionsBar: View {
    @Environment(AppModel.self) private var model
    /// Whether the tools are here too, folded into a menu, for want of room for their own bar.
    var holdsTools = false

    var body: some View {
        ToolbarPill {
            if holdsTools { ToolsMenu() }
            ShareMenu()
            ToolButton(symbol: "paintbrush", label: "Format", isActive: model.isInspectorOpen) {
                withAnimation(.smooth(duration: 0.3)) { model.isInspectorOpen.toggle() }
            }
        }
    }
}
