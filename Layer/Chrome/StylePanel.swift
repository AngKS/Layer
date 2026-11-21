import SwiftUI

/// The paintbrush's panel: settings for whatever is selected.
struct StylePanel: View {
    @Environment(AppModel.self) private var model
    /// In a narrow window the panel fills a sheet rather than floating beside the canvas.
    var isSheet = false
    /// The room there is for the floating panel, which is otherwise as tall as its settings.
    var maxHeight: CGFloat = 620
    @State private var scrubber = Scrubber()

    var body: some View {
        let scrolling = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let selected = model.selectedElement {
                    ElementSettings(ref: selected.ref, element: selected.element)
                } else if let screen = model.selectedScreen {
                    FrameSettings(screen: screen)
                } else if model.selection?.isSeveral == true {
                    SeveralSettings()
                }
            }
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(scrubber.target != nil)
        .foregroundStyle(.primary)

        // Fields and the ruler share one coordinate space, the panel's.
        let settings = scrolling
            .overlay { ScrubberOverlay() }
            .background { PencilBridge(scrubber: scrubber) }
            .coordinateSpace(.named(Scrubber.space))
            .onPencilSqueeze { phase in
                // A squeeze that sends what the pencil is listening for isn't one for the
                // ruler, even when the pen has drifted over a field.
                if case .active = phase, model.pencilVoice.ownsSqueeze, scrubber.target == nil { return }
                scrubber.squeeze(phase)
            }
            .environment(scrubber)
            .onAppear {
                // A scrub undoes as one step, however long it takes.
                scrubber.onBegin = { [model] in model.beginScrubbing() }
                scrubber.onEnd = { [model] in model.endScrubbing() }
            }
            // A ruler left up by the pencil goes with the panel or the selection it was for.
            .onDisappear { scrubber.end() }
            .onChange(of: model.selection) { scrubber.end() }

        if isSheet {
            settings
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            settings
                .frame(width: 300)
                .frame(maxHeight: min(620, maxHeight), alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(.background, in: .rect(cornerRadius: 26, style: .continuous))
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

        // The same actions as the bar above the selection.
        PanelSection {
            HStack(spacing: 6) {
                IconButton("Duplicate", symbol: "plus.square.on.square") { model.duplicateSelection() }
                IconButton(element.isLocked ? "Unlock" : "Lock", symbol: element.isLocked ? "lock.fill" : "lock", isOn: element.isLocked) {
                    model.toggleLockOfSelection()
                }
                IconButton(DesignStore.Arrangement.forward.name, symbol: DesignStore.Arrangement.forward.symbol) { model.arrangeSelection(.forward) }
                    .disabled(!model.store.canArrange(ref, .forward))
                IconButton(DesignStore.Arrangement.backward.name, symbol: DesignStore.Arrangement.backward.symbol) { model.arrangeSelection(.backward) }
                    .disabled(!model.store.canArrange(ref, .backward))
            }
        }

        PanelSection {
            HStack(spacing: 8) {
                NumberField("X", value: binding(\.frame.origin.x))
                NumberField("Y", value: binding(\.frame.origin.y))
            }
            HStack(spacing: 8) {
                NumberField("W", value: binding(\.frame.size.width), range: 1...4000)
                NumberField("H", value: binding(\.frame.size.height), range: 1...4000)
            }
            HStack(spacing: 8) {
                if element.hasCornerRadius {
                    NumberField("R", label: "Corner radius", value: Binding(get: { element.resolvedCornerRadius }, set: { radius in change { $0.cornerRadius = radius } }), range: 0...999)
                }
                if element.kind.spec.hasEffects {
                    NumberField("%", label: "Opacity", value: Binding(
                        get: { (element.resolvedOpacity * 100).rounded() },
                        set: { percent in change { $0.opacity = percent >= 99.5 ? nil : Double(percent) / 100 } }
                    ), range: 5...100)
                }
                NumberField("°", label: "Rotation",
                            value: Binding(get: { CGFloat(Rotation.shown(element.resolvedRotation)) }, set: { degrees in change { $0.setRotation(Double(degrees)) } }),
                            range: 0...360, pointsPerStep: 2, degreesPerStep: 1, wraps: true, ticksEvery: 15)
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
                    NumberField("W", label: "Border width", value: Binding(get: { element.resolvedBorderWidth }, set: { width in change { $0.borderWidth = width > 0 ? width : nil } }), range: 0...40)
                        .frame(width: 84)
                    ColorField(label: "Border colour", color: Binding(get: { element.resolvedBorderColor }, set: { color in change { $0.borderColor = color } }))
                }
            }
            if element.kind.spec.hasEffects {
                Toggle("Shadow", isOn: Binding(get: { element.hasShadow }, set: { shadow in change { $0.hasShadow = shadow } }))
            }
            if element.hasOnState {
                Toggle(element.kind.spec.onName ?? "On",
                       isOn: Binding(get: { element.isOn }, set: { isOn in change { $0.isOn = isOn } }))
            }
            if element.hasValue {
                PanelRow("Progress") {
                    Slider(value: Binding(get: { element.resolvedValue }, set: { value in change { $0.value = (value * 100).rounded() / 100 } }), in: 0...1)
                    Text(element.resolvedValue, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            if element.hasButtonLooks {
                Picker("Button style", selection: Binding(get: { element.resolvedButtonLook }, set: { look in change { $0.buttonLook = look } })) {
                    ForEach(ButtonLook.allCases, id: \.self) { look in
                        Text(look.name).tag(look)
                    }
                }
                .pickerStyle(.segmented)
            }
        }

        if element.kind.hasText {
            PanelSection {
                TextField("Text", text: Binding(get: { element.text }, set: { text in change { $0.text = text } }), axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12))
                HStack(spacing: 8) {
                    NumberField("pt", label: "Font size", value: Binding(get: { element.resolvedFontSize.rounded() }, set: { size in change { $0.fontSize = size } }), range: 6...400)
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
            HStack(spacing: 6) {
                IconButton("Duplicate", symbol: "plus.square.on.square") { model.duplicateSelection() }
            }
        }

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
                set: { percent in change { $0.scale = percent / 100 } }
            ), range: 15...200)
        }
    }

    private func change(_ body: (inout DesignScreen) -> Void) {
        model.adjusting { model.store.updateScreen(screen.id, body) }
    }
}

/// Several things selected at once: lining them up with one another, and the settings
/// their elements have in common, each of which is set for every element that has it. A
/// setting shows what the first of those elements has.
private struct SeveralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let things = model.selectedThings
        let selected = model.selectedElements
        let elements = selected.map(\.element)
        // What the settings change: these elements, even if a field typed in sets its value
        // after the selection has moved on.
        let refs = selected.map(\.ref)
        let isLocked = model.isSelectionLocked

        PanelHeader(symbol: "square.on.square.dashed", title: "\(things.count) Items") {
            withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
        }

        PanelSection {
            HStack(spacing: 6) {
                IconButton("Duplicate", symbol: "plus.square.on.square") { model.duplicateSelection() }
                IconButton(isLocked ? "Unlock" : "Lock", symbol: isLocked ? "lock.fill" : "lock", isOn: isLocked) {
                    model.toggleLockOfSelection()
                }
            }
        }

        PanelSection {
            HStack(spacing: 6) {
                ForEach(ElementLayout.Alignment.allCases, id: \.self) { alignment in
                    IconButton(alignment.name, symbol: alignment.symbol) { model.alignSelection(alignment) }
                }
            }
            HStack(spacing: 6) {
                ForEach(ElementLayout.Distribution.allCases, id: \.self) { distribution in
                    IconButton(distribution.name, symbol: distribution.symbol) { model.distributeSelection(distribution) }
                }
            }
            .disabled(!model.canDistributeSelection)
        }
        .disabled(isLocked)

        // Corners, opacity and angle are for what isn't locked, as they are for one element:
        // the value shown is an unlocked element's, and only unlocked ones change.
        let unlocked = elements.filter { !$0.isLocked }
        let rounded = unlocked.first(where: \.hasCornerRadius)
        let faded = unlocked.first { $0.kind.spec.hasEffects }
        let effects = elements.first { $0.kind.spec.hasEffects }
        let turnable = model.canTurnSelection
        if rounded != nil || faded != nil || turnable {
            PanelSection {
                HStack(spacing: 8) {
                    if let rounded {
                        NumberField("R", label: "Corner radius", value: Binding(
                            get: { rounded.resolvedCornerRadius },
                            set: { radius in change(refs, where: { $0.hasCornerRadius && !$0.isLocked }) { $0.cornerRadius = radius } }
                        ), range: 0...999)
                    }
                    if let faded {
                        NumberField("%", label: "Opacity", value: Binding(
                            get: { (faded.resolvedOpacity * 100).rounded() },
                            set: { percent in change(refs, where: { $0.kind.spec.hasEffects && !$0.isLocked }) { $0.opacity = percent >= 99.5 ? nil : Double(percent) / 100 } }
                        ), range: 5...100)
                    }
                    // Each element is turned to the angle shown (the first unlocked one's), on
                    // its own pivot; a screen among them leaves nothing to turn.
                    if turnable, let first = unlocked.first {
                        NumberField("°", label: "Rotation", value: Binding(
                            get: { CGFloat(Rotation.shown(first.resolvedRotation)) },
                            set: { degrees in change(refs, where: { !$0.isLocked }) { $0.setRotation(Double(degrees)) } }
                        ), range: 0...360, pointsPerStep: 2, degreesPerStep: 1, wraps: true, ticksEvery: 15)
                    }
                }
            }
        }

        let filled = elements.first(where: \.hasFill)
        let bordered = elements.first(where: \.hasBorder)
        if filled != nil || bordered != nil || effects != nil {
            PanelSection {
                if let filled {
                    PanelRow("Fill") {
                        ColorField(label: "Fill colour", color: Binding(get: { filled.tint }, set: { colour in change(refs, where: \.hasFill) { $0.tint = colour } }))
                    }
                }
                if let bordered {
                    PanelRow("Border") {
                        NumberField("W", label: "Border width", value: Binding(
                            get: { bordered.resolvedBorderWidth },
                            set: { width in change(refs, where: \.hasBorder) { $0.borderWidth = width > 0 ? width : nil } }
                        ), range: 0...40)
                            .frame(width: 84)
                        ColorField(label: "Border colour", color: Binding(
                            get: { bordered.resolvedBorderColor },
                            set: { colour in change(refs, where: \.hasBorder) { $0.borderColor = colour } }
                        ))
                    }
                }
                if let effects {
                    Toggle("Shadow", isOn: Binding(get: { effects.hasShadow }, set: { shadow in change(refs, where: \.kind.spec.hasEffects) { $0.hasShadow = shadow } }))
                }
            }
        }

        if let worded = elements.first(where: \.kind.hasText) {
            PanelSection {
                HStack(spacing: 8) {
                    NumberField("pt", label: "Font size", value: Binding(
                        get: { worded.resolvedFontSize.rounded() },
                        set: { size in change(refs, where: \.kind.hasText) { $0.fontSize = size } }
                    ), range: 6...400)
                        .frame(width: 84)
                    Spacer(minLength: 0)
                    Picker("Weight", selection: Binding(get: { worded.resolvedFontWeight }, set: { weight in change(refs, where: \.kind.hasText) { $0.fontWeight = weight } })) {
                        ForEach(FontWeightChoice.allCases, id: \.self) { weight in
                            Text(weight.name).tag(weight)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    ColorPicker("Text colour", selection: Binding(
                        get: { worded.resolvedTextColor.color },
                        set: { colour in change(refs, where: \.kind.hasText) { $0.textColor = RGBColor(UIColor(colour)) } }
                    ), supportsOpacity: false)
                        .labelsHidden()
                }
                if let aligned = elements.first(where: \.hasTextAlignment) {
                    Picker("Text alignment", selection: Binding(
                        get: { aligned.resolvedTextAlignment },
                        set: { alignment in change(refs, where: \.hasTextAlignment) { $0.textAlignment = alignment } }
                    )) {
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

    /// Makes a change to each of the elements the settings are for that a setting applies to.
    /// A run of quick changes, a colour being dragged for instance, undoes as one step.
    private func change(_ refs: [DesignStore.ElementRef], where applies: (DesignElement) -> Bool, _ body: (inout DesignElement) -> Void) {
        let store = model.store
        model.adjusting { store.update(refs.filter { store.resolve($0).map { applies($0.element) } ?? false }, body) }
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
    /// What the field said when the menu opened, to tell whether anything was typed.
    @State private var shown = ""
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
                    .foregroundStyle(.secondary)
                    .help(sync.title)
                    .accessibilityLabel(sync.title)
                    .accessibilityValue(sync.detail ?? "")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12))

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
        .foregroundStyle(.primary)
        .onAppear {
            draft = model.store.title ?? ""
            shown = draft
        }
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

    /// Names the board what was typed, once typing ends or the menu closes. Only if
    /// something was typed: a board named while its menu was open (its first screen
    /// read, say) kept "Untitled" when the menu closed, as the field still said it.
    private func rename() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft != shown, typed != (model.store.title ?? "") else { return }
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
                            .overlay { Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1) }
                            .padding(3)
                            .overlay { Circle().strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: 2) }
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
            Toggle("Draw with Finger", isOn: Binding(get: { model.fingerDraws }, set: { model.setFingerDraws($0) }))
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
            // The model this design uses, saved in its file.
            HStack {
                Label("Model", systemImage: model.modelChoice.symbol)
                Spacer(minLength: 8)
                ModelChoicePicker(choice: Binding(get: { model.modelChoice }, set: { model.setModelChoice($0) }))
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Model for this design")
            }
            Text(model.engine.statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                .foregroundStyle(.secondary)
                .frame(width: 22)
            if let name {
                // Unnamed, it goes by its kind's name, drawn as a name rather than a prompt.
                TextField(placeholder, text: name, prompt: Text(placeholder).foregroundStyle(.primary))
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
                Rectangle().fill(.separator).frame(height: 1)
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
/// when typing ends. It can also be scrubbed a unit at a time: held with a finger and
/// dragged sideways, or squeezed over with an Apple Pencil Pro and rolled.
private struct NumberField: View {
    @Environment(Scrubber.self) private var scrubber
    let unit: String
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let pointsPerStep: CGFloat
    let degreesPerStep: Double
    let wraps: Bool
    let ticksEvery: Int
    @State private var frame = CGRect.zero
    @GestureState private var isHeld = false
    /// Whether the number is being typed. Until it is tapped, it is shown as text, which
    /// leaves holding it free to scrub.
    @State private var isTyping = false

    init(_ unit: String, label: String? = nil, value: Binding<CGFloat>, range: ClosedRange<CGFloat> = -99_999...99_999,
         pointsPerStep: CGFloat = Scrubber.pointsPerStep, degreesPerStep: Double = Scrubber.degreesPerStep,
         wraps: Bool = false, ticksEvery: Int = 1) {
        self.unit = unit
        self.label = label ?? unit
        _value = value
        self.range = range
        self.pointsPerStep = pointsPerStep
        self.degreesPerStep = degreesPerStep
        self.wraps = wraps
        self.ticksEvery = ticksEvery
    }

    var body: some View {
        let isScrubbing = scrubber.target?.label == label && scrubber.target?.frame == frame
        HStack(spacing: 6) {
            Text(unit)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if isTyping {
                TypedNumber(label: label, value: $value, range: range, wraps: wraps) { isTyping = false }
            } else {
                Text(Double(value), format: Self.format)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(label)
                    .accessibilityValue(Text(Double(value), format: Self.format))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { isTyping = true }
                    .accessibilityAdjustableAction { direction in
                        let step: CGFloat = direction == .increment ? 1 : -1
                        value = Scrubber.value(from: value.rounded(), steps: Int(step), in: range, wraps: wraps)
                    }
            }
        }
        .font(.system(size: 14).monospacedDigit())
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: isScrubbing ? 1.5 : 0)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Scrubber.space)) }) { frame = $0 }
        // A pencil hovering here is what a squeeze would scrub.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active: scrubber.hovered = target
            case .ended: if scrubber.hovered?.label == label { scrubber.hovered = nil }
            }
        }
        // Tapped, it is typed into; held, it scrubs.
        .onTapGesture { if !isTyping { isTyping = true } }
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .updating($isHeld) { value, isHeld, _ in
                    if case .second(true, _) = value { isHeld = true }
                }
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    scrubber.hold(target)
                    scrubber.scrub(to: Scrubber.steps(forDrag: drag?.translation.width ?? 0, pointsPerStep: pointsPerStep))
                },
            isEnabled: !isTyping
        )
        // However the hold ends, lifted or cancelled, scrubbing ends with it.
        .onChange(of: isHeld) { _, held in if !held { scrubber.end() } }
    }

    private static let format = TypedNumber.format

    private var target: Scrubber.Target {
        Scrubber.Target(
            label: label, unit: unit, frame: frame, range: range,
            get: { value }, set: { value = $0 },
            pointsPerStep: pointsPerStep, degreesPerStep: degreesPerStep, wraps: wraps, ticksEvery: ticksEvery
        )
    }
}

/// A number field being typed into, which appears as typing begins. SwiftUI sets what is
/// typed as the text changes, and once more as typing ends, on Return or as the field loses
/// focus, which ends typing.
///
/// It all goes to the value the field was bound to as typing began. The panel binds its
/// fields to whatever is selected, and tapping another element on the canvas doesn't end
/// typing: rebound, the field showed the other element's value in place of what was typed,
/// and what was typed next was set on that element.
struct TypedNumber: View {
    let label: String
    let range: ClosedRange<CGFloat>
    let wraps: Bool
    /// Typing has ended.
    let onEnd: () -> Void
    /// The value typed into: the binding as typing began, kept for as long as it goes on.
    @State private var target: Binding<CGFloat>
    /// The number as typed, which the field shows. The binding kept may read the value it
    /// had as typing began, as the panel's do.
    @State private var typed: Double
    @FocusState private var isEditing: Bool

    static let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))

    init(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, wraps: Bool, onEnd: @escaping () -> Void) {
        self.label = label
        self.range = range
        self.wraps = wraps
        self.onEnd = onEnd
        // Only as the field appears: later bindings, made for whatever is selected then, are
        // passed in but not taken.
        _target = State(initialValue: value)
        _typed = State(initialValue: Double(value.wrappedValue))
    }

    var body: some View {
        TextField(
            label,
            value: Binding(get: { typed }, set: { number in
                let value = Scrubber.typed(CGFloat(number), in: range, wraps: wraps)
                typed = Double(value)
                target.wrappedValue = value
            }),
            format: Self.format
        )
        .keyboardType(.numbersAndPunctuation)
        .focused($isEditing)
        // Focus taken as the field appears is dropped; a moment later it holds.
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            isEditing = true
        }
        .onChange(of: isEditing) { _, focused in if !focused { onEnd() } }
        .accessibilityLabel(label)
    }
}

/// A square button with an icon, for a row of related actions.
private struct IconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let label: String
    let symbol: String
    var isOn = false
    let action: () -> Void

    init(_ label: String, symbol: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .opacity(isEnabled ? 1 : 0.35)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Color(uiColor: isOn ? .systemFill : .tertiarySystemFill), in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
