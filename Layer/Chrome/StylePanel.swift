import SwiftUI

/// The paintbrush's panel: settings for whatever is selected.
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
                } else if case .ink = model.selection {
                    PanelHeader(symbol: "scribble", title: "Drawing") { model.deleteSelection() }
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
        PanelHeader(
            symbol: element.symbol ?? element.kind.symbol,
            name: Binding(get: { element.name ?? "" }, set: { name in change { $0.name = name.isEmpty ? nil : name } }),
            placeholder: element.kind.layerName,
            onDelete: { withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() } }
        )

        PanelSection {
            HStack(spacing: 8) {
                NumberField("X", value: binding(\.frame.origin.x))
                NumberField("Y", value: binding(\.frame.origin.y))
            }
            HStack(spacing: 8) {
                NumberField("W", value: binding(\.frame.size.width), minimum: 1)
                NumberField("H", value: binding(\.frame.size.height), minimum: 1)
            }
            HStack(spacing: 8) {
                if element.hasCornerRadius {
                    NumberField("R", label: "Corner radius", value: Binding(get: { element.resolvedCornerRadius }, set: { radius in change { $0.cornerRadius = radius } }), minimum: 0)
                }
                NumberField("%", label: "Opacity", value: Binding(
                    get: { (element.resolvedOpacity * 100).rounded() },
                    set: { percent in change { $0.opacity = percent >= 99.5 ? nil : Double(min(max(percent, 5), 100)) / 100 } }
                ))
            }
            if case .screen = ref.host {
                HStack(spacing: 6) {
                    ForEach(ElementLayout.Alignment.allCases, id: \.self) { alignment in
                        IconButton(alignment.name, symbol: alignment.symbol) { model.store.align(ref, alignment) }
                    }
                }
            }
        }
        .disabled(element.isLocked)

        PanelSection {
            if element.hasFill {
                PanelRow("Fill") {
                    ColorField(label: "Fill colour", color: Binding(get: { element.tint }, set: { color in change { $0.tint = color } }))
                }
            }
            if element.hasBorder {
                PanelRow("Border") {
                    NumberField("W", label: "Border width", value: Binding(get: { element.resolvedBorderWidth }, set: { width in change { $0.borderWidth = width > 0 ? width : nil } }), minimum: 0)
                        .frame(width: 84)
                    ColorField(label: "Border colour", color: Binding(get: { element.resolvedBorderColor }, set: { color in change { $0.borderColor = color } }))
                }
            }
            Toggle("Shadow", isOn: Binding(get: { element.hasShadow }, set: { shadow in change { $0.hasShadow = shadow } }))
            if element.kind == .toggle {
                Toggle("On", isOn: Binding(get: { element.isOn }, set: { isOn in change { $0.isOn = isOn } }))
            }
        }

        if element.kind.hasText {
            PanelSection {
                TextField("Text", text: Binding(get: { element.text }, set: { text in change { $0.text = text } }), axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Theme.fieldFill, in: .rect(cornerRadius: 12))
                HStack(spacing: 8) {
                    NumberField("pt", label: "Font size", value: Binding(get: { element.resolvedFontSize.rounded() }, set: { size in change { $0.fontSize = size } }), minimum: 6)
                        .frame(width: 84)
                    Spacer(minLength: 0)
                    Picker("Weight", selection: Binding(get: { element.resolvedFontWeight }, set: { weight in change { $0.fontWeight = weight } })) {
                        ForEach(FontWeightChoice.allCases, id: \.self) { weight in
                            Text(weight.name).tag(weight)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    ColorPicker("Text colour", selection: Binding(get: { element.resolvedTextColor.color }, set: { color in change { $0.textColor = RGBColor(UIColor(color)) } }), supportsOpacity: false)
                        .labelsHidden()
                }
                if element.hasTextAlignment {
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
        PanelHeader(
            symbol: "iphone",
            name: Binding(get: { screen.name }, set: { name in change { $0.name = name } }),
            placeholder: "Frame",
            onDelete: { withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() } }
        )

        PanelSection {
            Picker("Device", selection: Binding(get: { screen.device.id }, set: { id in change { $0.deviceID = id == DeviceFrame.iPhone.id ? nil : id } })) {
                ForEach(DeviceFrame.all) { device in
                    Text("\(device.name)  \(Int(device.size.width)) × \(Int(device.size.height))").tag(device.id)
                }
            }
            .labelsHidden()
            HStack(spacing: 8) {
                NumberField("X", value: Binding(get: { screen.origin.x }, set: { x in change { $0.origin.x = x } }))
                NumberField("Y", value: Binding(get: { screen.origin.y }, set: { y in change { $0.origin.y = y } }))
            }
            NumberField("%", label: "Scale", value: Binding(
                get: { (screen.scale * 100).rounded() },
                set: { percent in change { $0.scale = min(max(percent, 15), 200) / 100 } }
            ))
        }
    }

    private func change(_ body: (inout DesignScreen) -> Void) {
        model.adjusting { model.store.updateScreen(screen.id, body) }
    }
}

/// With nothing selected: the sketch in progress, and the way to the canvas's settings.
private struct NothingSelected: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelHeader(symbol: "square.dashed", title: "Canvas")

        PanelSection {
            Group {
                Button("Convert Sketch Now", systemImage: "wand.and.sparkles") { model.convertNow() }
                Button("Discard Sketch", systemImage: "eraser") { model.discardSketch() }
            }
            .disabled(!model.hasSketch)
            .opacity(model.hasSketch ? 1 : 0.35)
            Button("Canvas Settings", systemImage: "slider.horizontal.3") { model.openBoardMenu() }
        }
    }
}

// MARK: The board menu

/// What tapping the board's name opens: its name, and the canvas's settings in tabs.
struct BoardMenu: View {
    enum Tab: String, CaseIterable, Identifiable {
        case canvas = "Canvas"
        case magicPen = "Magic Pen"
        case code = "Code"

        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    /// In a narrow window the menu fills a sheet rather than a popover.
    var isSheet = false
    @State private var draft = ""
    @AppStorage("boardMenuTab") private var tab = Tab.canvas

    var body: some View {
        let sync = model.syncState
        VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("Untitled", text: $draft)
                    .font(.system(size: 17, weight: .semibold))
                    .submitLabel(.done)
                    .onSubmit {
                        rename()
                        model.isBoardMenuOpen = false
                    }
                    .accessibilityLabel("Board name")
                Image(systemName: sync.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .help(sync.title)
                    .accessibilityLabel(sync.title)
                    .accessibilityValue(sync.detail ?? "")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Theme.fieldFill, in: .rect(cornerRadius: 12))

            Picker("Settings", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding([.horizontal, .top], 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)

        // A popover takes the height of the tab showing; a sheet scrolls.
        if isSheet {
            ScrollView { settings }
                .scrollBounceBehavior(.basedOnSize)
        } else {
            settings
        }
        }
        .frame(width: isSheet ? nil : 360, alignment: .top)
        .frame(maxWidth: isSheet ? .infinity : nil, maxHeight: isSheet ? .infinity : nil, alignment: .top)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent.color)
        .onAppear { draft = model.store.title ?? "" }
        .onDisappear(perform: rename)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .canvas: CanvasTab()
            case .magicPen: MagicPenTab()
            case .code: CodeTab()
            }
        }
        .padding(.bottom, 12)
    }

    /// Names the board what was typed, once typing ends or the menu closes.
    private func rename() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != (model.store.title ?? "") else { return }
        model.store.setTitle(typed)
    }
}

/// A change to the canvas's settings, made as one undo step however quickly it repeats.
@MainActor
private func canvasBinding<Value>(_ model: AppModel, _ keyPath: WritableKeyPath<CanvasSettings, Value>) -> Binding<Value> {
    Binding(
        get: { model.store.canvas[keyPath: keyPath] },
        set: { value in model.adjusting { model.store.updateCanvas { $0[keyPath: keyPath] = value } } }
    )
}

private struct CanvasTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let canvas = model.store.canvas

        PanelSection {
            HStack(spacing: 8) {
                ForEach(CanvasSettings.backgrounds, id: \.self) { colour in
                    let isChosen = canvas.resolvedBackground == colour
                    Button {
                        model.store.updateCanvas { $0.background = colour == CanvasSettings.paper ? nil : colour }
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
                ColorPicker("Background colour", selection: Binding(
                    get: { canvas.resolvedBackground.color },
                    set: { colour in model.adjusting { model.store.updateCanvas { $0.background = RGBColor(UIColor(colour)) } } }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }

        PanelSection {
            Toggle("Grid", isOn: canvasBinding(model, \.showsGrid))
            if canvas.showsGrid {
                Picker("Grid style", selection: canvasBinding(model, \.gridStyle)) {
                    Text("Dots").tag(CanvasSettings.GridStyle.dots)
                    Text("Lines").tag(CanvasSettings.GridStyle.lines)
                }
                .pickerStyle(.segmented)
                PanelRow("Spacing") {
                    Slider(value: canvasBinding(model, \.gridSpacing), in: 8...64, step: 4)
                        .accessibilityLabel("Grid spacing")
                        .accessibilityValue("\(Int(canvas.gridSpacing)) points")
                }
            }
        }

        PanelSection {
            Toggle("Snap to Grid", isOn: canvasBinding(model, \.snapsToGrid))
            Toggle("Smart Guides", isOn: canvasBinding(model, \.snapsToGuides))
            Toggle("Show Spacing", isOn: canvasBinding(model, \.showsMeasurements))
            Toggle("Frame Names", isOn: canvasBinding(model, \.showsFrameNames))
        }
    }
}

private struct MagicPenTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        PanelSection {
            Toggle("Convert After a Pause", isOn: $model.convertsAutomatically)
            Toggle("Scratch Out to Delete", isOn: $model.scratchOutDeletes)
            HStack {
                Text("New Screens")
                Spacer(minLength: 8)
                Picker("New Screens", selection: canvasBinding(model, \.sketchDeviceID)) {
                    ForEach(DeviceFrame.all) { device in
                        Text(device.name).tag(device == .iPhone ? String?.none : device.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if model.engine.canBeTurnedOnInSettings {
                Button("Turn On Apple Intelligence", systemImage: "apple.intelligence") {
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settings)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(model.engine.statusLine)
    }
}

private struct CodeTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelSection {
            Picker("Code layout", selection: canvasBinding(model, \.code.layout)) {
                ForEach(CodeSettings.Layout.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Include Preview", isOn: canvasBinding(model, \.code.includesPreview))
            Toggle("Title as Navigation Title", isOn: canvasBinding(model, \.code.usesNavigationTitle))
        }
    }
}

// MARK: Building blocks

/// The top of the panel: what is selected, its name when it can have one, and a way to delete it.
private struct PanelHeader: View {
    let symbol: String
    var title: String?
    var name: Binding<String>?
    var placeholder = ""
    var onDelete: (() -> Void)?

    init(symbol: String, title: String, onDelete: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.onDelete = onDelete
    }

    init(symbol: String, name: Binding<String>, placeholder: String, onDelete: @escaping () -> Void) {
        self.symbol = symbol
        self.name = name
        self.placeholder = placeholder
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)
                .frame(width: 22)
            if let name {
                // Unnamed, it goes by its kind's name, drawn as a name rather than a prompt.
                TextField(placeholder, text: name, prompt: Text(placeholder).foregroundStyle(Theme.ink))
                    .font(.system(size: 17, weight: .bold))
                    .accessibilityLabel("Name")
            } else if let title {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
            }
            Spacer(minLength: 0)
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

/// A group of related settings, set apart from the next by a line.
private struct PanelSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .font(.system(size: 14))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.dividerLine).frame(height: 1)
            }
    }
}

/// A control that needs naming: its name on the left.
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
                .frame(width: 64, alignment: .leading)
            content
        }
    }
}

/// A number that can be typed over, with its unit inside the field. The change is made
/// when typing ends.
private struct NumberField: View {
    let unit: String
    let label: String
    @Binding var value: CGFloat
    var minimum: CGFloat = -.infinity

    init(_ unit: String, label: String? = nil, value: Binding<CGFloat>, minimum: CGFloat = -.infinity) {
        self.unit = unit
        self.label = label ?? unit
        _value = value
        self.minimum = minimum
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(unit)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.label)
                .accessibilityHidden(true)
            TextField(
                label,
                value: Binding(get: { Double(value) }, set: { value = max(CGFloat($0), minimum) }),
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.numbersAndPunctuation)
            .font(.system(size: 14).monospacedDigit())
            .accessibilityLabel(label)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Theme.fieldFill, in: .rect(cornerRadius: 10))
    }
}

/// A square button with an icon, for a row of related actions.
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

/// A colour well, at the end of its row.
private struct ColorField: View {
    let label: String
    @Binding var color: RGBColor

    var body: some View {
        Spacer(minLength: 0)
        ColorPicker(label, selection: Binding(get: { color.color }, set: { color = RGBColor(UIColor($0)) }), supportsOpacity: false)
            .labelsHidden()
            .accessibilityValue(color.hex)
    }
}
