import SwiftUI

/// The paintbrush's panel: settings for whatever is selected. The canvas's own settings
/// are in the menu under the board's name.
struct StylePanel: View {
    @Environment(AppModel.self) private var model
    /// In a narrow window the panel fills a sheet rather than floating beside the canvas.
    var isSheet = false
    /// The room there is for the floating panel, which is otherwise as tall as its settings.
    var maxHeight: CGFloat = 620

    var body: some View {
        let settings = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let selected = model.selectedElement {
                    ElementSettings(ref: selected.ref, element: selected.element)
                } else if let screen = model.selectedScreen {
                    FrameSettings(screen: screen)
                } else if case .ink(let strokes) = model.selection {
                    DrawingSettings(strokeCount: strokes.count)
                } else {
                    NothingSelected()
                }
            }
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent.color)

        if isSheet {
            settings
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            settings
                .frame(width: 300)
                .frame(maxHeight: min(620, maxHeight), alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(Theme.panel, in: .rect(cornerRadius: 26, style: .continuous))
                .clipShape(.rect(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 22, y: 8)
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
    }
}

// MARK: What is selected

private struct ElementSettings: View {
    @Environment(AppModel.self) private var model
    let ref: DesignStore.ElementRef
    let element: DesignElement

    var body: some View {
        PanelHeader(title: element.kind.layerName, symbol: element.symbol ?? element.kind.symbol) {
            withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
        }

        PanelSection("Layer") {
            PanelRow("Name") {
                TextField(element.kind.layerName, text: Binding(get: { element.name ?? "" }, set: { name in change { $0.name = name.isEmpty ? nil : name } }))
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Theme.fieldFill, in: .rect(cornerRadius: 10))
                    .accessibilityLabel("Layer name")
            }
            PanelRow("Position") {
                NumberField("X", value: binding(\.frame.origin.x))
                NumberField("Y", value: binding(\.frame.origin.y))
            }
            .disabled(element.isLocked)
            PanelRow("Size") {
                NumberField("W", value: binding(\.frame.size.width), minimum: 1)
                NumberField("H", value: binding(\.frame.size.height), minimum: 1)
            }
            .disabled(element.isLocked)
            Toggle("Locked", isOn: Binding(get: { element.isLocked }, set: { locked in model.store.update(ref) { $0.isLocked = locked } }))
            Toggle("Hidden", isOn: Binding(get: { element.isHidden }, set: { _ in model.toggleHidden(ref) }))
        }

        PanelSection("Arrange") {
            HStack(spacing: 6) {
                ForEach(DesignStore.Arrangement.allCases, id: \.self) { arrangement in
                    IconButton(arrangement.name, symbol: arrangement.symbol) { model.store.arrange(ref, arrangement) }
                        .disabled(!model.store.canArrange(ref, arrangement))
                }
            }
            if case .screen = ref.host {
                HStack(spacing: 6) {
                    ForEach(ElementLayout.Alignment.allCases, id: \.self) { alignment in
                        IconButton(alignment.name, symbol: alignment.symbol) { model.store.align(ref, alignment) }
                    }
                }
                .disabled(element.isLocked)
            }
        }

        PanelSection("Style") {
            if element.hasFill {
                PanelRow("Fill") {
                    ColorField(label: "Fill colour", color: Binding(get: { element.tint }, set: { color in change { $0.tint = color } }))
                }
            }
            if element.hasCornerRadius {
                PanelRow("Radius") {
                    NumberField(
                        "R",
                        value: Binding(get: { element.resolvedCornerRadius }, set: { radius in change { $0.cornerRadius = radius } }),
                        minimum: 0
                    )
                }
            }
            if element.kind == .toggle {
                Toggle("On", isOn: Binding(get: { element.isOn }, set: { isOn in change { $0.isOn = isOn } }))
            }
            PanelRow("Opacity") {
                Slider(
                    value: Binding(get: { element.resolvedOpacity }, set: { opacity in change { $0.opacity = opacity >= 0.995 ? nil : opacity } }),
                    in: 0.05...1
                )
                .accessibilityLabel("Opacity")
                Text("\(Int((element.resolvedOpacity * 100).rounded()))%")
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }
            if element.hasBorder {
                PanelRow("Border") {
                    NumberField(
                        "W",
                        value: Binding(get: { element.resolvedBorderWidth }, set: { width in change { $0.borderWidth = width > 0 ? width : nil } }),
                        minimum: 0
                    )
                    .frame(width: 84)
                    ColorField(label: "Border colour", color: Binding(get: { element.resolvedBorderColor }, set: { color in change { $0.borderColor = color } }))
                }
            }
            Toggle("Shadow", isOn: Binding(get: { element.hasShadow }, set: { shadow in change { $0.hasShadow = shadow } }))
        }

        if element.kind.hasText {
            PanelSection("Text") {
                TextField("Text", text: Binding(get: { element.text }, set: { text in change { $0.text = text } }), axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 14))
                    .padding(10)
                    .background(Theme.fieldFill, in: .rect(cornerRadius: 12))
                PanelRow("Size") {
                    NumberField(
                        "pt",
                        value: Binding(get: { element.resolvedFontSize.rounded() }, set: { size in change { $0.fontSize = size } }),
                        minimum: 6
                    )
                }
                PanelRow("Weight") {
                    Picker("Weight", selection: Binding(get: { element.resolvedFontWeight }, set: { weight in change { $0.fontWeight = weight } })) {
                        ForEach(FontWeightChoice.allCases, id: \.self) { weight in
                            Text(weight.name).tag(weight)
                        }
                    }
                    .labelsHidden()
                }
                PanelRow("Colour") {
                    ColorField(label: "Text colour", color: Binding(get: { element.resolvedTextColor }, set: { color in change { $0.textColor = color } }))
                }
                if element.hasTextAlignment {
                    PanelRow("Align") {
                        Picker("Text alignment", selection: Binding(get: { element.resolvedTextAlignment }, set: { alignment in change { $0.textAlignment = alignment } })) {
                            ForEach(TextAlignmentChoice.allCases, id: \.self) { alignment in
                                Image(systemName: alignment.symbol)
                                    .accessibilityLabel(alignment.name)
                                    .tag(alignment)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
    }

    private func change(_ body: (inout DesignElement) -> Void) {
        model.adjusting { model.store.update(ref, body) }
    }

    private func binding(_ keyPath: WritableKeyPath<DesignElement, CGFloat>) -> Binding<CGFloat> {
        Binding(get: { element[keyPath: keyPath] }, set: { value in change { $0[keyPath: keyPath] = value } })
    }
}

private struct FrameSettings: View {
    @Environment(AppModel.self) private var model
    let screen: DesignScreen

    var body: some View {
        PanelHeader(title: "Frame", symbol: "iphone") {
            withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
        }

        PanelSection("Frame") {
            PanelRow("Name") {
                TextField("Name", text: Binding(get: { screen.name }, set: { name in change { $0.name = name } }))
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Theme.fieldFill, in: .rect(cornerRadius: 10))
            }
            PanelRow("Device") {
                Picker("Device", selection: Binding(get: { screen.device.id }, set: { id in change { $0.deviceID = id == DeviceFrame.iPhone.id ? nil : id } })) {
                    ForEach(DeviceFrame.all) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
            }
            PanelRow("Size") {
                Text("\(Int(screen.size.width)) × \(Int(screen.size.height))")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.label)
            }
        }

        PanelSection("Layer") {
            PanelRow("Position") {
                NumberField("X", value: Binding(get: { screen.origin.x }, set: { x in change { $0.origin.x = x } }))
                NumberField("Y", value: Binding(get: { screen.origin.y }, set: { y in change { $0.origin.y = y } }))
            }
            PanelRow("Scale") {
                Slider(value: Binding(get: { screen.scale }, set: { scale in change { $0.scale = scale } }), in: 0.15...2)
                    .accessibilityLabel("Scale")
                Text("\(Int((screen.scale * 100).rounded()))%")
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }
            Button("Duplicate Frame", systemImage: "plus.square.on.square") { model.duplicateSelection() }
        }
    }

    private func change(_ body: (inout DesignScreen) -> Void) {
        model.adjusting { model.store.updateScreen(screen.id, body) }
    }
}

private struct DrawingSettings: View {
    @Environment(AppModel.self) private var model
    let strokeCount: Int

    var body: some View {
        PanelHeader(title: "Drawing", symbol: "scribble") {
            model.deleteSelection()
        }
        PanelSection("Ink") {
            Text(strokeCount == 1 ? "1 stroke. Drag it to move it." : "\(strokeCount) strokes. Drag them to move them.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.label)
            Text("To restyle ink, pick a pen from the pencil palette.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.label)
        }
    }
}

// MARK: The canvas

/// With nothing selected there is nothing to format; the canvas's own settings are under
/// the board's name.
private struct NothingSelected: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Format")
            .font(.system(size: 17, weight: .bold))
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 6)

        PanelSection("Nothing Selected") {
            Text("Select something on the canvas to change how it looks.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.label)
            Button("Canvas Settings", systemImage: "slider.horizontal.3") {
                model.openBoardMenu()
            }
        }

        // What is done to a sketch in progress stays at hand while drawing.
        PanelSection("Magic Pen") {
            Button("Convert Sketch Now") { model.convertNow() }
                .disabled(!model.hasSketch)
            Button("Discard Sketch") { model.discardSketch() }
                .disabled(!model.hasSketch)
            Text(model.engine.statusLine)
                .font(.system(size: 12))
                .foregroundStyle(Theme.label)
        }
    }
}

/// What tapping the board's name opens: a field to rename the board, and below it the
/// canvas's settings, a tab for each kind.
struct BoardMenu: View {
    enum Tab: String, CaseIterable, Identifiable {
        case canvas = "Canvas"
        case magicPen = "Magic Pen"
        case code = "Code"
        case iCloud = "iCloud"

        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    /// In a narrow window the menu fills a sheet rather than a popover.
    var isSheet = false
    @State private var draft = ""
    @AppStorage("boardMenuTab") private var tab = Tab.canvas
    @FocusState private var isNaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                TextField("Untitled", text: $draft)
                    .font(.system(size: 17, weight: .semibold))
                    .submitLabel(.done)
                    .focused($isNaming)
                    .onSubmit {
                        rename()
                        model.isBoardMenuOpen = false
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(Theme.fieldFill, in: .rect(cornerRadius: 12))
                    .accessibilityLabel("Board name")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Picker("Settings", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CanvasSettingsTab(tab: tab)
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: isSheet ? nil : 380, height: isSheet ? nil : 560, alignment: .top)
        .frame(maxWidth: isSheet ? .infinity : nil, maxHeight: isSheet ? .infinity : nil, alignment: .top)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent.color)
        .background(Theme.panel)
        .onAppear { draft = model.store.title ?? "" }
        .onDisappear(perform: rename)
    }

    /// Names the board what was typed, once typing ends or the menu closes.
    private func rename() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != (model.store.title ?? "") else { return }
        model.store.setTitle(typed)
    }
}

/// One tab of the canvas's settings.
private struct CanvasSettingsTab: View {
    @Environment(AppModel.self) private var model
    let tab: BoardMenu.Tab

    var body: some View {
        @Bindable var model = model
        let canvas = model.store.canvas

        switch tab {
        case .canvas:
            PanelSection("Background") {
                HStack(spacing: 8) {
                    ForEach(CanvasSettings.backgrounds, id: \.self) { colour in
                        let isChosen = canvas.resolvedBackground == colour
                        Button {
                            change { $0.background = colour == CanvasSettings.paper ? nil : colour }
                        } label: {
                            Circle()
                                .fill(colour.color)
                                .overlay { Circle().strokeBorder(Theme.label.opacity(0.35), lineWidth: 1) }
                                .padding(3)
                                .overlay { Circle().strokeBorder(isChosen ? Theme.accent.color : .clear, lineWidth: 2) }
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Background \(colour.hex)")
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                    ColorPicker(
                        "Background colour",
                        selection: Binding(get: { canvas.resolvedBackground.color }, set: { colour in change { $0.background = RGBColor(UIColor(colour)) } }),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
            }

            PanelSection("Layout Guides") {
                Toggle("Grid", isOn: Binding(get: { canvas.showsGrid }, set: { shows in change { $0.showsGrid = shows } }))
                if canvas.showsGrid {
                    Picker("Grid style", selection: Binding(get: { canvas.gridStyle }, set: { style in change { $0.gridStyle = style } })) {
                        Text("Dots").tag(CanvasSettings.GridStyle.dots)
                        Text("Lines").tag(CanvasSettings.GridStyle.lines)
                    }
                    .pickerStyle(.segmented)
                    PanelRow("Spacing") {
                        Slider(
                            value: Binding(get: { canvas.gridSpacing }, set: { spacing in change { $0.gridSpacing = spacing } }),
                            in: 8...64, step: 4
                        )
                        .accessibilityLabel("Grid spacing")
                        Text("\(Int(canvas.gridSpacing))")
                            .font(.system(size: 13).monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                Toggle("Snap to Grid", isOn: Binding(get: { canvas.snapsToGrid }, set: { snaps in change { $0.snapsToGrid = snaps } }))
                Toggle("Smart Guides", isOn: Binding(get: { canvas.snapsToGuides }, set: { snaps in change { $0.snapsToGuides = snaps } }))
                Toggle("Show Spacing", isOn: Binding(get: { canvas.showsMeasurements }, set: { shows in change { $0.showsMeasurements = shows } }))
                Toggle("Frame Names", isOn: Binding(get: { canvas.showsFrameNames }, set: { shows in change { $0.showsFrameNames = shows } }))
            }

        case .magicPen:
            PanelSection("Magic Pen") {
                Toggle("Convert After a Pause", isOn: $model.convertsAutomatically)
                Toggle("Scratch Out to Delete", isOn: $model.scratchOutDeletes)
                PanelRow("Screens") {
                    Picker("Sketched screens", selection: Binding(get: { canvas.sketchDevice.id }, set: { id in change { $0.sketchDeviceID = id == DeviceFrame.iPhone.id ? nil : id } })) {
                        ForEach(DeviceFrame.all) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                }
                Text(model.engine.statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.label)
                if model.engine.canBeTurnedOnInSettings {
                    Button("Open Settings") {
                        if let settings = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(settings)
                        }
                    }
                }
            }

            PanelSection("What the Magic Pen Reads") {
                MagicPenGuide()
            }

        case .code:
            PanelSection("Code") {
                PanelRow("Layout") {
                    Picker("Code layout", selection: Binding(get: { canvas.code.layout }, set: { layout in change { $0.code.layout = layout } })) {
                        ForEach(CodeSettings.Layout.allCases, id: \.self) { layout in
                            Text(layout.name).tag(layout)
                        }
                    }
                    .labelsHidden()
                }
                Toggle("Include Preview", isOn: Binding(get: { canvas.code.includesPreview }, set: { on in change { $0.code.includesPreview = on } }))
                Toggle("Title as Navigation Title", isOn: Binding(get: { canvas.code.usesNavigationTitle }, set: { on in change { $0.code.usesNavigationTitle = on } }))
            }

        case .iCloud:
            PanelSection("iCloud") {
                Label(model.syncState.title, systemImage: model.syncState.symbol)
                    .font(.system(size: 14))
                if let detail = model.syncState.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.label)
                }
            }
        }
    }

    private func change(_ body: (inout CanvasSettings) -> Void) {
        model.adjusting { model.store.updateCanvas(body) }
    }
}

// MARK: Building blocks

/// What is selected, with a way to delete it.
private struct PanelHeader: View {
    let title: String
    let symbol: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 17, weight: .bold))
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.label)
            content
        }
        .font(.system(size: 14))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.dividerLine).frame(height: 1)
        }
    }
}

/// A label on the left, its controls on the right.
private struct PanelRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.label)
                .frame(width: 64, alignment: .leading)
            content
        }
    }
}

/// A number that can be typed over. The change is made when typing ends.
private struct NumberField: View {
    let unit: String
    @Binding var value: CGFloat
    var minimum: CGFloat = -.infinity

    init(_ unit: String, value: Binding<CGFloat>, minimum: CGFloat = -.infinity) {
        self.unit = unit
        _value = value
        self.minimum = minimum
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(unit)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.label)
            TextField(
                unit,
                value: Binding(get: { Double(value) }, set: { value = max(CGFloat($0), minimum) }),
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.numbersAndPunctuation)
            .font(.system(size: 14).monospacedDigit())
            .accessibilityLabel(unit)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Theme.fieldFill, in: .rect(cornerRadius: 10))
    }
}

/// A small square button with an icon, for rows of related actions.
private struct IconButton: View {
    let label: String
    let symbol: String
    let action: () -> Void

    init(_ label: String, symbol: String, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Theme.fieldFill, in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The shapes the Magic Pen turns into things, as a cheat sheet.
struct MagicPenGuide: View {
    static let entries: [(symbol: String, shape: String, result: String)] = [
        ("rectangle.portrait", "Tall rectangle", "Screen"),
        ("photo", "Box with an X", "Image"),
        ("capsule", "Wide pill", "Button"),
        ("rectangle", "Wide box", "Text field"),
        ("textformat", "Short squiggle", "Title"),
        ("text.alignleft", "Long squiggle or lines", "Body text"),
        ("minus", "Straight line", "Divider"),
        ("switch.2", "Small pill", "Toggle"),
        ("person.crop.circle", "Small circle", "Avatar"),
        ("note.text", "Box beside the screens", "Sticky note"),
        ("character.textbox", "Squiggle beside the screens", "Text"),
        ("scribble", "Scratch back and forth", "Deletes what's under it"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.entries, id: \.shape) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .frame(width: 20)
                    Text(entry.shape)
                    Spacer(minLength: 8)
                    Text(entry.result)
                        .foregroundStyle(Theme.label)
                }
                .font(.system(size: 13))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A colour well with the colour's hex value beside it.
private struct ColorField: View {
    let label: String
    @Binding var color: RGBColor

    var body: some View {
        Text(color.hex)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fieldFill, in: .rect(cornerRadius: 10))
        ColorPicker(label, selection: Binding(get: { color.color }, set: { color = RGBColor(UIColor($0)) }), supportsOpacity: false)
            .labelsHidden()
    }
}
