import ImagePlayground
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The floating pill that holds a row of controls.
struct ToolbarPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Freeform's bars: 44 points tall, plain system glass.
        HStack(spacing: 4) { content }
            // Menus in the bar too, untinted, like everything else in it.
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .glassEffect(.regular, in: .capsule)
    }
}

/// A control's icon, on a grey capsule when the control is on. Sized as Freeform's:
/// a 44-point-tall target with a glyph of about 22 points.
struct ToolIcon: View {
    let symbol: String
    var isActive = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: 52, height: 44)
            .background(isActive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
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
        HStack(spacing: 10) {
            Button {
                // The design goes back to the browser with its picture and its name up to date.
                Task {
                    if await model.prepareToClose() { dismiss() }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
                    .contentShape(.hoverEffect, .circle)
                    .hoverEffect(.highlight)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .circle)
            .accessibilityLabel("Designs")
            ToolbarPill { title }
        }
    }

    private var title: some View {
        @Bindable var model = model
        return Group {
            Button {
                model.openBoardMenu()
            } label: {
                HStack(spacing: 6) {
                    Text(model.boardName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize(horizontal: !isCutToFit, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.isBoardMenuOpen ? 180 : 0))
                        .animation(.snappy(duration: 0.2), value: model.isBoardMenuOpen)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Board title")
            .accessibilityValue(model.boardName)
            .accessibilityHint("Rename the board and change the canvas settings")
            .popover(isPresented: $model.isBoardMenuOpen, arrowEdge: .top) {
                BoardMenu(isSheet: model.isCompactSizeClass)
                    .environment(model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .preferredColorScheme(.light)
            }
        }
    }
}

/// Top centre: the layers panel on its own, then everything that puts something on the board.
private struct ToolsBar: View {
    @Environment(AppModel.self) private var model
    @State private var isLibraryOpen = false
    @State private var files = FilesPicker()
    @State private var isPickingPhoto = false
    /// What the last A2UI imported from here made, and left out, until its sheet is put away (F19).
    @State private var report: A2UIImportReport?

    var body: some View {
        HStack(spacing: 10) {
            ToolbarPill {
                ToolButton(symbol: "square.3.layers.3d", label: "Layers", isActive: model.isLayersOpen) {
                    withAnimation(.smooth(duration: 0.3)) { model.isLayersOpen.toggle() }
                }
            }
            ToolbarPill {
                // Not during a call: the pencil bar would lie over the pill.
                ToolButton(symbol: "pencil.tip.crop.circle", label: "Draw", isActive: model.tool == .draw) {
                    model.tool = model.tool == .draw ? .select : .draw
                }
                .disabled(model.isInVoiceCall)
                ToolButton(symbol: "character.textbox", label: "Text") {
                    withAnimation(.smooth(duration: 0.3)) { model.addText() }
                }
                ToolButton(symbol: "note.text", label: "Sticky note") {
                    withAnimation(.smooth(duration: 0.3)) { model.addStickyNote() }
                }
                ToolButton(symbol: "square.on.circle", label: "Library", isActive: isLibraryOpen) {
                    isLibraryOpen = true
                }
                .popover(isPresented: $isLibraryOpen) {
                    LibraryPopover(isPresented: $isLibraryOpen)
                }
                Menu {
                    ImageSources(files: $files, isPickingPhoto: $isPickingPhoto)
                    A2UISources(files: $files, report: $report)
                } label: {
                    ToolIcon(symbol: "paperclip")
                }
                .accessibilityLabel("Add Image or A2UI")
            }
        }
        .buttonStyle(.plain)
        .modifier(ImageAttaching(files: $files, isPickingPhoto: $isPickingPhoto, report: $report))
        .a2uiImportSheet($report)
    }
}

/// The tools folded into one button, for a window too narrow to lay them out.
private struct ToolsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var isLibraryOpen = false
    @State private var files = FilesPicker()
    @State private var isPickingPhoto = false
    /// What the last A2UI imported from here made, and left out, until its sheet is put away (F19).
    @State private var report: A2UIImportReport?

    var body: some View {
        @Bindable var model = model
        Menu {
            Toggle("Layers", systemImage: "square.3.layers.3d", isOn: $model.isLayersOpen)
            // Draw puts the pencil bar up and takes it away again. Not during a call: the
            // bar would lie over the pill.
            Toggle("Draw", systemImage: "pencil.tip.crop.circle", isOn: Binding(
                get: { model.tool == .draw },
                set: { model.tool = $0 ? .draw : .select }
            ))
            .disabled(model.isInVoiceCall)
            Divider()
            Button("Text", systemImage: "character.textbox") {
                withAnimation(.smooth(duration: 0.3)) { model.addText() }
            }
            Button("Sticky Note", systemImage: "note.text") {
                withAnimation(.smooth(duration: 0.3)) { model.addStickyNote() }
            }
            Button("Library", systemImage: "square.on.circle") { isLibraryOpen = true }
            Menu("Add Image or A2UI", systemImage: "paperclip") {
                ImageSources(files: $files, isPickingPhoto: $isPickingPhoto)
                A2UISources(files: $files, report: $report)
            }
        } label: {
            ToolIcon(symbol: "ellipsis")
        }
        .accessibilityLabel("Tools")
        .popover(isPresented: $isLibraryOpen) {
            LibraryPopover(isPresented: $isLibraryOpen)
        }
        .modifier(ImageAttaching(files: $files, isPickingPhoto: $isPickingPhoto, report: $report))
        .a2uiImportSheet($report)
    }
}

/// The library, as the Library button presents it: picking a thing puts it in the
/// middle of the view and closes the library. Dragging one out closes it too, once the
/// drag is under way, so that the canvas behind it can take the drop.
private struct LibraryPopover: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    var body: some View {
        AssetLibraryView { asset in
            isPresented = false
            withAnimation(.smooth(duration: 0.3)) { model.addAsset(asset) }
        } onDragStart: {
            // After the lift: put away at once, the popover would take the drag with it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                isPresented = false
            }
        } onGenerate: { description in
            isPresented = false
            model.generateScreen(from: description)
        }
        .environment(model)
        .environment(model.images)
    }
}

/// The places an image can come from: made in Image Playground, picked from Photos, or
/// picked from a file.
private struct ImageSources: View {
    @Environment(AppModel.self) private var model
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @Binding var files: FilesPicker
    @Binding var isPickingPhoto: Bool

    var body: some View {
        if supportsImagePlayground {
            Button("Image Playground", systemImage: "apple.image.playground") {
                model.makeImageWithPlayground()
            }
        }
        Button("Photos", systemImage: "photo.on.rectangle") { isPickingPhoto = true }
        Button("Files", systemImage: "folder") { files.open(for: .image) }
    }
}

/// A2UI, from a file or pasted: each becomes new screens in one undo step (calls 17 and 18). The system's Paste button
/// reads what was copied without asking first.
private struct A2UISources: View {
    @Environment(AppModel.self) private var model
    @Binding var files: FilesPicker
    @Binding var report: A2UIImportReport?

    var body: some View {
        Section("A2UI") {
            Button("Import A2UI…", systemImage: "square.and.arrow.down") { files.open(for: .a2ui) }
            PasteButton(payloadType: String.self) { strings in
                // Whatever was copied: what isn't A2UI is said so by the import.
                let data = Data(strings.joined(separator: "\n").utf8)
                Task { @MainActor in report = await model.importA2UI(data) }
            }
        }
    }
}

/// Files, open to pick an image to add to the board or A2UI to import as screens. One picker serves both, since a
/// view shows only one of two `fileImporter`s.
private struct FilesPicker {
    enum Pick {
        case image, a2ui
    }

    var isOpen = false
    var pick = Pick.image

    var contentTypes: [UTType] {
        switch pick {
        case .image: [.png, .jpeg, .heic]
        case .a2ui: [.json, .plainText]
        }
    }

    mutating func open(for pick: Pick) {
        self.pick = pick
        isOpen = true
    }
}

/// Picking an image from Photos or from a file and adding it to the board, or A2UI from a
/// file and importing it, wherever the button for it is.
private struct ImageAttaching: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var files: FilesPicker
    @Binding var isPickingPhoto: Bool
    @Binding var report: A2UIImportReport?
    @State private var photo: PhotosPickerItem?
    @State private var hasFailed = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $files.isOpen, allowedContentTypes: files.contentTypes) { result in
                switch files.pick {
                case .image: attach(result)
                case .a2ui: importA2UI(result)
                }
            }
            .photosPicker(isPresented: $isPickingPhoto, selection: $photo, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task { await attach(item) }
            }
            .alert("That image couldn't be added.", isPresented: $hasFailed) {
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

    /// A file of A2UI, imported: one too large or that can't be read says so in the import's sheet.
    private func importA2UI(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        Task { report = await model.importA2UI(contentsOf: url) }
    }

    /// The picker hands over the photo's data; nothing in Photos needs permission to read.
    private func attach(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let prepared = ImageImport.prepare(data) else {
            hasFailed = true
            return
        }
        withAnimation(.smooth(duration: 0.3)) { model.addImage(prepared) }
    }
}

/// Top right: sharing, and, while something is selected, the paintbrush that opens its settings.
private struct ActionsBar: View {
    @Environment(AppModel.self) private var model
    /// Whether the tools are here too, folded into a menu, for want of room for their own bar.
    var holdsTools = false

    var body: some View {
        ToolbarPill {
            if holdsTools { ToolsMenu() }
            ShareMenu()
            // Only while there is something to format: the bar takes no room for it otherwise.
            if model.selection != nil {
                ToolButton(symbol: "paintbrush", label: "Format", isActive: model.isInspectorOpen) {
                    withAnimation(.smooth(duration: 0.3)) { model.isInspectorOpen.toggle() }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.selection != nil)
    }
}
