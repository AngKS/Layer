import SwiftUI

/// The paintbrush's panel: settings for whatever is selected.
struct StylePanel: View {
    @Environment(AppModel.self) private var model
    /// In a narrow window the panel fills a sheet rather than floating beside the canvas.
    var isSheet = false
    /// The room there is for the floating panel, which is otherwise as tall as its settings.
    var maxHeight: CGFloat = 620
    /// The window's one scrubber: its squeezes come through the window's squeeze router.
    private var scrubber: Scrubber { model.scrubber }

    var body: some View {
        let scrolling = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let selected = model.selectedNode {
                    if selected.node.isContainer {
                        // A group or card has settings of its own, never one element's.
                        ContainerSettings(placed: selected)
                    } else {
                        ElementSettings(placed: selected)
                    }
                } else if let id = model.selectedScreenID, let screen = model.store.treeScreen(id) {
                    FrameSettings(screen: screen)
                } else if model.selection?.isSeveral == true {
                    SeveralSettings()
                }
            }
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Not for the zoom's ruler, which another finger may hold.
        .scrollDisabled(scrubber.target?.owner == .panel)
        .foregroundStyle(.primary)

        // Fields and the ruler share one coordinate space, the panel's.
        let settings = scrolling
            .overlay { ScrubberOverlay() }
            .coordinateSpace(.named(Scrubber.space))
            // Where that space is in the window, for a step's tick to be felt at its field.
            .reportsPanelOrigin(to: scrubber)
            .environment(scrubber)
            // A ruler left up by the pencil goes with the panel, and so does a field's hover;
            // the zoom's ruler stays. A new selection ends them in the model.
            .onDisappear {
                scrubber.end(.panel)
                scrubber.forgetHovered(.panel)
            }

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

/// What the panel shows of a node: its kind's usual look with its own choices laid over it, as an element's was
/// (`ElementStyle`).
private extension LayerNode {
    var traits: ComponentSpec.Traits { kind.spec.traits }
    var hasFill: Bool { traits.contains(.fill) }
    var hasCornerRadius: Bool { traits.contains(.cornerRadius) }
    var hasBorder: Bool { traits.contains(.border) }
    var hasOnState: Bool { traits.contains(.onState) }
    var hasTextAlignment: Bool { traits.contains(.textAlignment) }
    var hasValue: Bool { traits.contains(.value) }
    var hasButtonLooks: Bool { traits.contains(.buttonLooks) }
    var hasEffects: Bool { kind.spec.hasEffects }

    var shownTint: RGBColor { style.tint ?? kind.spec.tint }
    var resolvedFontSize: CGFloat { style.fontSize ?? kind.spec.fontSize.points(in: frame) }
    var resolvedFontWeight: FontWeightChoice { style.fontWeight ?? kind.spec.fontWeight }
    var resolvedCornerRadius: CGFloat { style.cornerRadius ?? kind.spec.cornerRadius.points(in: frame) }
    var resolvedOpacity: Double { style.opacity ?? 1 }
    var resolvedButtonLook: ButtonLook { content.buttonLook ?? .filled }
    var resolvedValue: Double { min(max(content.value ?? 0.5, 0), 1) }
    var resolvedTextAlignment: TextAlignmentChoice { style.textAlignment ?? kind.spec.textAlignment }
    var resolvedBorderWidth: CGFloat { max(style.borderWidth ?? 0, 0) }
    var resolvedBorderColor: RGBColor { style.borderColor ?? Theme.inkTint }
    var resolvedTextColor: RGBColor {
        if let colour = style.textColor { return colour }
        return switch kind.spec.textColour {
        case .colour(let colour): colour
        // White on a filled button; a bordered or plain one shows its colour in its text.
        case .onFill: resolvedButtonLook == .filled ? RGBColor(hex: 0xFFFFFF) : shownTint
        }
    }
}

/// How a node's frame and angle are written from the panel: through `place`, which keeps what the parent places and
/// what a turned container holds, and through the node's own angle, which the ones above it add to.
private extension AppModel {
    /// One side of the node's frame, in its host's own points; the others as they are now.
    func setFrame(of id: UUID, _ body: (inout CGRect) -> Void) {
        adjusting {
            guard var frame = store.placed(id)?.frame else { return }
            body(&frame)
            store.place(id, at: frame)
        }
    }

    /// The node's angle on the canvas, given what the containers above it already turn by.
    func setDegrees(of id: UUID, to degrees: Double) {
        adjusting {
            guard let found = store.placed(id) else { return }
            let inherited = found.degrees - (found.node.rotation ?? 0)
            store.update(id) { $0.rotation = Rotation.kept(degrees - inherited) }
        }
    }
}

private struct ElementSettings: View {
    @Environment(AppModel.self) private var model
    let placed: PlacedNode

    var body: some View {
        let node = placed.node
        PanelHeader(
            symbol: node.content.symbol.map(SystemSymbol.resolve) ?? node.kind.symbol,
            name: Binding(get: { node.name ?? "" }, set: { name in change { $0.name = name.isEmpty ? nil : name } }),
            placeholder: node.kind.layerName,
            onDelete: { withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() } }
        )

        // The same actions as the bar above the selection.
        PanelSection {
            HStack(spacing: 6) {
                IconButton("Duplicate", symbol: "plus.square.on.square") { model.duplicateSelection() }
                LockButton()
                // A drawing stays on top: there is no order to change.
                if node.kind != .drawing {
                    ArrangeButtons()
                }
            }
        }

        PanelSection {
            let isPlacedHere = SizingSection.isPositionEditable(for: placed)
            HStack(spacing: 8) {
                NumberField("X", value: frameBinding(\.origin.x))
                NumberField("Y", value: frameBinding(\.origin.y))
            }
            .disabled(!isPlacedHere)
            if isPlacedHere {
                HStack(spacing: 8) {
                    NumberField("W", value: frameBinding(\.size.width), range: 1...4000)
                    NumberField("H", value: frameBinding(\.size.height), range: 1...4000)
                }
            } else {
                // What lays it out gives it its place: its size is Fit, Fill or Fixed along each axis.
                SizingSection(placed: placed).equatable()
            }
            HStack(spacing: 8) {
                if node.hasCornerRadius {
                    NumberField("R", label: "Corner radius", value: Binding(get: { node.resolvedCornerRadius }, set: { radius in change { $0.style.cornerRadius = radius } }), range: 0...999)
                }
                if node.hasEffects {
                    NumberField("%", label: "Opacity", value: Binding(
                        get: { (node.resolvedOpacity * 100).rounded() },
                        set: { percent in change { $0.style.opacity = percent >= 99.5 ? nil : Double(percent) / 100 } }
                    ), range: 5...100)
                }
                NumberField("°", label: "Rotation",
                            value: Binding(get: { CGFloat(Rotation.shown(placed.degrees)) }, set: { degrees in model.setDegrees(of: node.id, to: Double(degrees)) }),
                            range: 0...360, pointsPerStep: 2, degreesPerStep: 1, wraps: true, ticksEvery: 15)
            }
            if case .screen = placed.ref.host {
                AlignButtons()
            }
        }
        // Locked by itself or by a group above it, it stays as it is.
        .disabled(model.isSelectionLocked)

        PanelSection {
            if node.hasFill {
                PanelRow("Fill") {
                    ColorField(label: "Fill colour", color: Binding(get: { node.shownTint }, set: { color in change { $0.style.tint = color } }))
                }
            }
            if node.hasBorder {
                PanelRow("Border") {
                    NumberField("W", label: "Border width", value: Binding(get: { node.resolvedBorderWidth }, set: { width in change { $0.style.borderWidth = width > 0 ? width : nil } }), range: 0...40)
                        .frame(width: 84)
                    ColorField(label: "Border colour", color: Binding(get: { node.resolvedBorderColor }, set: { color in change { $0.style.borderColor = color } }))
                }
            }
            if node.hasEffects {
                Toggle("Shadow", isOn: Binding(get: { node.style.hasShadow }, set: { shadow in change { $0.style.hasShadow = shadow } }))
            }
            if node.hasOnState {
                Toggle(node.kind.spec.onName ?? "On",
                       isOn: Binding(get: { node.content.isOn }, set: { isOn in change { $0.content.isOn = isOn } }))
            }
            if node.hasValue {
                PanelRow("Progress") {
                    Slider(value: Binding(get: { node.resolvedValue }, set: { value in change { $0.content.value = (value * 100).rounded() / 100 } }), in: 0...1)
                    Text(node.resolvedValue, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            if node.hasButtonLooks {
                Picker("Button style", selection: Binding(get: { node.resolvedButtonLook }, set: { look in change { $0.content.buttonLook = look } })) {
                    ForEach(ButtonLook.allCases, id: \.self) { look in
                        Text(look.name).tag(look)
                    }
                }
                .pickerStyle(.segmented)
            }
        }

        if node.kind.hasText {
            PanelSection {
                TextField("Text", text: Binding(get: { node.content.text }, set: { text in change { $0.content.text = text } }), axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12))
                HStack(spacing: 8) {
                    NumberField("pt", label: "Font size", value: Binding(get: { node.resolvedFontSize.rounded() }, set: { size in change { $0.style.fontSize = size } }), range: 6...400)
                        .frame(width: 84)
                    Spacer(minLength: 0)
                    Picker("Weight", selection: Binding(get: { node.resolvedFontWeight }, set: { weight in change { $0.style.fontWeight = weight } })) {
                        ForEach(FontWeightChoice.allCases, id: \.self) { weight in
                            Text(weight.name).tag(weight)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    ColorPicker("Text colour", selection: Binding(get: { node.resolvedTextColor.color }, set: { color in change { $0.style.textColor = RGBColor(UIColor(color)) } }), supportsOpacity: false)
                        .labelsHidden()
                }
                if node.hasTextAlignment {
                    Picker("Text alignment", selection: Binding(get: { node.resolvedTextAlignment }, set: { alignment in change { $0.style.textAlignment = alignment } })) {
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

    private func change(_ body: (inout LayerNode) -> Void) {
        let id = placed.node.id
        model.adjusting { model.store.update(id, body) }
    }

    private func frameBinding(_ keyPath: WritableKeyPath<CGRect, CGFloat>) -> Binding<CGFloat> {
        let id = placed.node.id
        return Binding(get: { placed.frame[keyPath: keyPath] }, set: { value in model.setFrame(of: id) { $0[keyPath: keyPath] = value } })
    }
}

/// The align buttons: one thing with its screen, several with each other, in a laid-out parent its alignment.
private struct AlignButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ElementLayout.Alignment.allCases, id: \.self) { alignment in
                IconButton(alignment.name, symbol: alignment.symbol) { model.lineUpSelection(alignment) }
                    .disabled(!model.canLineUpSelection(alignment))
            }
        }
    }
}

/// One container selected, a group or a card: its name; what can be done to it as one thing; its box, whose X, Y, W
/// and H move everything in it, or scale it in proportion (`AppModel.setGroupBox`), where nothing lays it out, and
/// otherwise its Width and Height; its angle, which turns it as one piece about its middle; the settings of what is in
/// it, each set on every member that has it, as for several things; then how it lays what it holds out, and a card's
/// own look.
private struct ContainerSettings: View {
    @Environment(AppModel.self) private var model
    let placed: PlacedNode

    var body: some View {
        let node = placed.node
        let ref = placed.ref
        let isLocked = model.isSelectionLocked
        PanelHeader(
            symbol: node.kind.symbol,
            name: Binding(get: { node.name ?? "" }, set: { name in
                model.adjusting { model.store.update(node.id) { $0.name = name.isEmpty ? nil : name } }
            }),
            placeholder: node.kind.layerName,
            onDelete: { withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() } }
        )

        // The popover's actions for a group.
        PanelSection {
            HStack(spacing: 6) {
                IconButton("Duplicate", symbol: "plus.square.on.square") { model.duplicateSelection() }
                LockButton()
                ArrangeButtons()
                IconButton("Ungroup", symbol: "rectangle.3.group.dashed") { model.ungroupSelection() }
                    .disabled(isLocked)
            }
        }

        // Its box, in its host's points, as an element's frame is shown.
        PanelSection {
            let isPlacedHere = SizingSection.isPositionEditable(for: placed)
            HStack(spacing: 8) {
                NumberField("X", value: Binding(get: { placed.frame.minX }, set: { x in model.setGroupBox(ref, x: x) }))
                NumberField("Y", value: Binding(get: { placed.frame.minY }, set: { y in model.setGroupBox(ref, y: y) }))
            }
            .disabled(!isPlacedHere)
            if isPlacedHere {
                HStack(spacing: 8) {
                    NumberField("W", value: Binding(get: { placed.frame.width }, set: { width in model.setGroupBox(ref, width: width) }), range: 1...4000)
                    NumberField("H", value: Binding(get: { placed.frame.height }, set: { height in model.setGroupBox(ref, height: height) }), range: 1...4000)
                }
            } else {
                SizingSection(placed: placed).equatable()
            }
            if case .screen = ref.host {
                // Lined up with its screen as one block.
                AlignButtons()
            }
        }
        .disabled(isLocked)

        LeafStyleSections(leaves: model.selectedLeafNodes, showsAngle: true) {
            NumberField("°", label: "Rotation", value: Binding(
                get: { CGFloat(Rotation.shown(placed.degrees)) },
                set: { degrees in model.setGroupRotation(ref, to: Double(degrees)) }
            ), range: 0...360, pointsPerStep: 2, degreesPerStep: 1, wraps: true, ticksEvery: 15)
            .disabled(isLocked)
        }

        // After what was always here, so that nothing a person knows moves.
        LayoutSection(id: node.id, layout: node.resolvedLayout, padding: node.padding, isScreenRoot: false, children: node.children)
            .equatable()
            .disabled(isLocked)
        if node.kind == .card {
            CardLook(node: node)
                .disabled(isLocked)
        }
    }
}

/// A card's own look: its fill, which is its own until it is reset to the design's, and its corners.
private struct CardLook: View {
    @Environment(AppModel.self) private var model
    let node: LayerNode

    var body: some View {
        let tokens = model.store.tree.settings.tokens
        let id = node.id
        PanelSection {
            Text("Card")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            PanelRow("Fill") {
                ColorField(label: "Card fill colour", color: Binding(
                    get: { node.shownFill(tokens: tokens) },
                    set: { colour in change(id) { $0.style.tint = colour } }
                ))
                Button("Default") { change(id) { $0.style.tint = nil } }
                    .disabled(node.style.tint == nil)
                    .accessibilityLabel("Default card fill")
            }
            PanelRow("Corners") {
                NumberField("R", label: "Card corner radius", value: Binding(
                    get: { node.style.cornerRadius ?? tokens.card.radius },
                    set: { radius in change(id) { $0.style.cornerRadius = radius } }
                ), range: 0...999)
            }
        }
    }

    private func change(_ id: UUID, _ body: (inout LayerNode) -> Void) {
        model.adjusting { model.store.update(id, body) }
    }
}

private struct FrameSettings: View {
    @Environment(AppModel.self) private var model
    let screen: TreeScreen

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

        // A screen's root is free or a column.
        LayoutSection(id: screen.root.id, layout: screen.root.resolvedLayout, padding: screen.root.padding, isScreenRoot: true,
                      children: screen.root.children)
            .equatable()
    }

    private func change(_ body: (inout TreeScreen) -> Void) {
        let id = screen.id
        model.adjusting { model.store.updateTreeScreen(id, body) }
    }
}

/// Several things selected at once: lining them up with one another, and the settings
/// their elements have in common, each of which is set for every element that has it. A
/// setting shows what the first of those elements has. A group among them is styled through
/// what is in it, and turned as one piece.
private struct SeveralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let things = model.selectedThings
        let isLocked = model.isSelectionLocked

        PanelHeader(symbol: "square.on.square.dashed", title: "\(things.count) Items") {
            withAnimation(.smooth(duration: 0.3)) { model.deleteSelection() }
        }

        PanelSection {
            HStack(spacing: 6) {
                IconButton("Duplicate", symbol: "plus.square.on.square") { model.duplicateSelection() }
                LockButton()
                ArrangeButtons()
                GroupMenuButton()
            }
        }

        PanelSection {
            HStack(spacing: 6) {
                ForEach(ElementLayout.Alignment.allCases, id: \.self) { alignment in
                    IconButton(alignment.name, symbol: alignment.symbol) { model.lineUpSelection(alignment) }
                        .disabled(!model.canLineUpSelection(alignment))
                }
            }
            HStack(spacing: 6) {
                ForEach(ElementLayout.Distribution.allCases, id: \.self) { distribution in
                    IconButton(distribution.name, symbol: distribution.symbol) { model.lineUpSelection(distribution) }
                        .disabled(!model.canLineUpSelection(distribution))
                }
            }
        }
        .disabled(isLocked)

        // Each thing is turned to the angle shown (the first unlocked one's) on its own pivot,
        // a group as one piece about its middle; a screen among them leaves nothing to turn.
        // What the field turns: these, even if it is set once the selection has moved on.
        let nodes = things.compactMap { thing -> PlacedNode? in
            if case .element(let ref) = thing { model.store.placed(ref) } else { nil }
        }
        let refs = nodes.map(\.ref)
        let first = nodes.first { !$0.isLocked }
        let turnable = model.canTurnSelection && first != nil
        LeafStyleSections(leaves: model.selectedLeafNodes, showsAngle: turnable) {
            if turnable, let first {
                NumberField("°", label: "Rotation", value: Binding(
                    get: { CGFloat(Rotation.shown(first.degrees)) },
                    set: { degrees in model.setAngle(of: refs, to: Double(degrees)) }
                ), range: 0...360, pointsPerStep: 2, degreesPerStep: 1, wraps: true, ticksEvery: 15)
            }
        }
    }
}

/// The Group button for several things: a tap groups when Group is offered, and the menu offers Row, Column, Grid and
/// Card, each off when what is selected can't be grouped so; a tap opens the menu when Group itself is off, so that it
/// never does nothing.
private struct GroupMenuButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let offered = model.groupShapesOffered
        let hint = offered.isEmpty && model.groupSelectionSpansHosts ? "Things on different screens can't be grouped" : ""
        let items = ForEach(GroupShape.allCases, id: \.self) { shape in
            Button(shape.title, systemImage: shape.symbol) { group(shape) }
                .disabled(!offered.contains(shape))
        }
        let label = IconLabel(symbol: "rectangle.3.group", isEnabled: !offered.isEmpty)
        Group {
            if offered.contains(.group) {
                Menu { items } label: { label } primaryAction: { group(.group) }
            } else {
                Menu { items } label: { label }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .disabled(offered.isEmpty)
        .accessibilityLabel("Group")
        .accessibilityHint(hint)
        .help("Group")
    }

    private func group(_ shape: GroupShape) {
        withAnimation(.smooth(duration: 0.25)) { model.groupSelection(as: shape) }
    }
}

/// The settings the things a panel is for have in common, each set on every one of
/// `leaves` that has it, and showing what the first of those has: corners and opacity, with
/// `angle` beside them; fill, border and shadow; and text. A container stands for what is in it:
/// `leaves` are `AppModel.selectedLeafNodes`, so that a group or card, alone or among several things,
/// is styled through its members.
private struct LeafStyleSections<Angle: View>: View {
    @Environment(AppModel.self) private var model
    /// What the settings change: these, even if a field typed in sets its value once the
    /// selection has moved on (M5).
    let leaves: [PlacedNode]
    /// Whether `angle` has a field to show.
    let showsAngle: Bool
    let angle: Angle

    init(leaves: [PlacedNode], showsAngle: Bool, @ViewBuilder angle: () -> Angle) {
        self.leaves = leaves
        self.showsAngle = showsAngle
        self.angle = angle()
    }

    var body: some View {
        let elements = leaves.map(\.node)
        let ids = elements.map(\.id)
        // Corners and opacity are for what isn't locked, by itself or by a group above it, as
        // they are for one element: the value shown is an unlocked one's, and only unlocked
        // ones change.
        let unlocked = leaves.filter { !$0.isLocked }.map(\.node)
        let rounded = unlocked.first(where: \.hasCornerRadius)
        let faded = unlocked.first(where: \.hasEffects)
        let effects = elements.first(where: \.hasEffects)
        if rounded != nil || faded != nil || showsAngle {
            PanelSection {
                HStack(spacing: 8) {
                    if let rounded {
                        NumberField("R", label: "Corner radius", value: Binding(
                            get: { rounded.resolvedCornerRadius },
                            set: { radius in change(ids, unlockedOnly: true, where: \.hasCornerRadius) { $0.style.cornerRadius = radius } }
                        ), range: 0...999)
                    }
                    if let faded {
                        NumberField("%", label: "Opacity", value: Binding(
                            get: { (faded.resolvedOpacity * 100).rounded() },
                            set: { percent in change(ids, unlockedOnly: true, where: \.hasEffects) { $0.style.opacity = percent >= 99.5 ? nil : Double(percent) / 100 } }
                        ), range: 5...100)
                    }
                    if showsAngle {
                        angle
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
                        ColorField(label: "Fill colour", color: Binding(get: { filled.shownTint }, set: { colour in change(ids, where: \.hasFill) { $0.style.tint = colour } }))
                    }
                }
                if let bordered {
                    PanelRow("Border") {
                        NumberField("W", label: "Border width", value: Binding(
                            get: { bordered.resolvedBorderWidth },
                            set: { width in change(ids, where: \.hasBorder) { $0.style.borderWidth = width > 0 ? width : nil } }
                        ), range: 0...40)
                            .frame(width: 84)
                        ColorField(label: "Border colour", color: Binding(
                            get: { bordered.resolvedBorderColor },
                            set: { colour in change(ids, where: \.hasBorder) { $0.style.borderColor = colour } }
                        ))
                    }
                }
                if let effects {
                    Toggle("Shadow", isOn: Binding(get: { effects.style.hasShadow }, set: { shadow in change(ids, where: \.hasEffects) { $0.style.hasShadow = shadow } }))
                }
            }
        }

        if let worded = elements.first(where: \.kind.hasText) {
            PanelSection {
                HStack(spacing: 8) {
                    NumberField("pt", label: "Font size", value: Binding(
                        get: { worded.resolvedFontSize.rounded() },
                        set: { size in change(ids, where: \.kind.hasText) { $0.style.fontSize = size } }
                    ), range: 6...400)
                        .frame(width: 84)
                    Spacer(minLength: 0)
                    Picker("Weight", selection: Binding(get: { worded.resolvedFontWeight }, set: { weight in change(ids, where: \.kind.hasText) { $0.style.fontWeight = weight } })) {
                        ForEach(FontWeightChoice.allCases, id: \.self) { weight in
                            Text(weight.name).tag(weight)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    ColorPicker("Text colour", selection: Binding(
                        get: { worded.resolvedTextColor.color },
                        set: { colour in change(ids, where: \.kind.hasText) { $0.style.textColor = RGBColor(UIColor(colour)) } }
                    ), supportsOpacity: false)
                        .labelsHidden()
                }
                if let aligned = elements.first(where: \.hasTextAlignment) {
                    Picker("Text alignment", selection: Binding(
                        get: { aligned.resolvedTextAlignment },
                        set: { alignment in change(ids, where: \.hasTextAlignment) { $0.style.textAlignment = alignment } }
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

    /// Makes a change to each of the nodes the settings are for that a setting applies to.
    /// A run of quick changes, a colour being dragged for instance, undoes as one step.
    private func change(_ ids: [UUID], unlockedOnly: Bool = false, where applies: (LayerNode) -> Bool, _ body: (inout LayerNode) -> Void) {
        model.changeNodes(ids, unlockedOnly: unlockedOnly, where: applies, body)
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
                // The name the top bar shows, as the field's placeholder: a board without one
                // of its own shows its file's (review m2). Typing names the board; nothing
                // typed renames nothing.
                TextField(model.boardName, text: $draft)
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
            // The app's setting, the same as in Settings, rather than this design's.
            Toggle("Squeeze to Talk", isOn: Binding(get: { model.squeezesToTalk }, set: { model.setSqueezesToTalk($0) }))
            Text(model.squeezesToTalk
                ? "Squeeze Apple Pencil Pro over the canvas to speak a command."
                : "Squeezing Apple Pencil Pro does what Apple Pencil settings say. Over a number field or the zoom control it still scrubs, unless those settings turn squeezing off or give it a shortcut.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
struct PanelSection<Content: View>: View {
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
struct PanelRow<Content: View>: View {
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
struct NumberField: View {
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
            LongPressGesture(minimumDuration: PencilVoice.holdThreshold / .seconds(1))
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .updating($isHeld) { value, isHeld, _ in
                    if case .second(true, _) = value { isHeld = true }
                }
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    scrubber.fingerDragged(target, by: drag?.translation.width ?? 0)
                },
            isEnabled: !isTyping
        )
        // However the hold ends, lifted or cancelled, scrubbing ends with it: the panel's,
        // not a zoom ruler another finger may hold.
        .onChange(of: isHeld) { _, held in if !held { scrubber.fingerLifted(.panel) } }
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
    /// What is typed so far. Nothing is set until typing ends, on Return or as the field
    /// loses focus: set on each key, the element changed under the field at every digit (a
    /// group shrank to its smallest at the first one deleted), and the panel was rebuilt as
    /// it was typed into.
    @State private var draft: NumberDraft
    @FocusState private var isEditing: Bool

    static let format = NumberDraft.format

    init(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, wraps: Bool, onEnd: @escaping () -> Void) {
        self.label = label
        self.range = range
        self.wraps = wraps
        self.onEnd = onEnd
        // Only as the field appears: later bindings, made for whatever is selected then, are
        // passed in but not taken.
        _target = State(initialValue: value)
        _draft = State(initialValue: NumberDraft(value.wrappedValue))
    }

    /// Sets what is typed on the value the field began with, the first time typing ends.
    private func commit() {
        if let value = draft.finish(in: range, wraps: wraps) { target.wrappedValue = value }
    }

    var body: some View {
        TextField(label, text: $draft.text)
            .keyboardType(.numbersAndPunctuation)
            .focused($isEditing)
            .onSubmit { isEditing = false }
            // Focus taken as the field appears is dropped; a moment later it holds.
            .task {
                try? await Task.sleep(for: .milliseconds(50))
                isEditing = true
            }
            .onChange(of: isEditing) { _, focused in
                guard !focused else { return }
                commit()
                onEnd()
            }
            // A tap on the canvas doesn't blur the field: it is removed, with the panel or the
            // settings it is in, and what was typed is set as it goes.
            .onDisappear(perform: commit)
            .accessibilityLabel(label)
    }
}

/// The number typed into a field, as text, until typing ends. What is typed commits once:
/// text that isn't a number, or is too big to hold, commits nothing, and a number the same as
/// the one the field began with commits nothing either, so that Return and then losing focus
/// are one change.
@MainActor
struct NumberDraft: Equatable {
    var text: String
    /// The number the field began with.
    let start: CGFloat
    /// Typing has ended and what was typed has been taken.
    private var isFinished = false

    static let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))

    init(_ value: CGFloat) {
        start = value
        text = Double(value).formatted(Self.format)
    }

    /// `committed(in:wraps:)` the first time typing ends, nil after: Return or a blur, and then
    /// the field going, are one change.
    mutating func finish(in range: ClosedRange<CGFloat>, wraps: Bool) -> CGFloat? {
        guard !isFinished else { return nil }
        isFinished = true
        return committed(in: range, wraps: wraps)
    }

    /// The value the text comes to, within `range` (or turned round it, if `wraps`), when it
    /// differs from the one the field began with; nil to leave the value as it was.
    func committed(in range: ClosedRange<CGFloat>, wraps: Bool) -> CGFloat? {
        guard let number = try? Self.format.parseStrategy.parse(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
        let value = Scrubber.typed(CGFloat(number), in: range, wraps: wraps)
        return Double(value) == Double(start) ? nil : value
    }
}

/// Lock, or Unlock while what is selected is locked, by itself or by a group above it: as the
/// popover shows it, and as the button acts. Unlocking a thing locked by its group unlocks the
/// locked groups above it too (ruling D), so that the button never does nothing.
private struct LockButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isLocked = model.isSelectionLocked
        IconButton(isLocked ? "Unlock" : "Lock", symbol: isLocked ? "lock.fill" : "lock", isOn: isLocked) {
            model.toggleLockOfSelection()
        }
    }
}

/// Bring to Front, Bring Forward, Send Backward and Send to Back, for whatever is selected:
/// the popover's Arrange menu, laid out in the actions row. One that would change nothing
/// is off.
private struct ArrangeButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(DesignStore.Arrangement.allCases, id: \.self) { arrangement in
            IconButton(arrangement.name, symbol: arrangement.symbol) { model.arrangeSelection(arrangement) }
                .disabled(!model.canArrangeSelection(arrangement))
        }
    }
}

/// A square button with an icon, for a row of related actions.
struct IconButton: View {
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
            IconLabel(symbol: symbol, isEnabled: isEnabled, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(label)
    }
}

/// What a square icon button looks like, for a button or a menu.
struct IconLabel: View {
    let symbol: String
    var isEnabled = true
    var isOn = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .opacity(isEnabled ? 1 : 0.35)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(Color(uiColor: isOn ? .systemFill : .tertiarySystemFill), in: .rect(cornerRadius: 9))
            .contentShape(.rect)
    }
}

/// A colour well, at the end of its row.
struct ColorField: View {
    let label: String
    @Binding var color: RGBColor

    var body: some View {
        Spacer(minLength: 0)
        ColorPicker(label, selection: Binding(get: { color.color }, set: { color = RGBColor(UIColor($0)) }), supportsOpacity: false)
            .labelsHidden()
            .accessibilityValue(color.hex)
    }
}
