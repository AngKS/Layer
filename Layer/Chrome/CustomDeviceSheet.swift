import SwiftUI

/// Makes a device of the design's own, or edits one: its name and kind, its size and corners, the safe areas and
/// furniture round its edges, and its layout tokens. Save is off while the draft has problems. Delete Device is
/// offered for one of the design's own that nothing uses.
///
/// A sheet of its own, or, given `onClose`, a form in place of the board menu's settings: a sheet over the menu's
/// popover left its number fields unable to take the keyboard when tapped.
struct CustomDeviceSheet: View {
    enum Purpose: Identifiable {
        /// A new device, starting from this: "Custom Size…" or "Save as Device…".
        case add(CustomDeviceDraft)
        /// One of the design's own.
        case edit(DeviceFrame)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let device): device.id
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let purpose: Purpose
    /// What saving a new device does with it.
    let add: (DeviceFrame) -> Void
    /// Closes the form shown in place of other settings; nil for a sheet, which is dismissed.
    let onClose: (() -> Void)?
    @State private var draft: CustomDeviceDraft
    /// Save was pressed, and the device is being saved.
    @State private var isSaving = false

    init(purpose: Purpose, add: @escaping (DeviceFrame) -> Void, onClose: (() -> Void)? = nil) {
        self.purpose = purpose
        self.add = add
        self.onClose = onClose
        switch purpose {
        case .add(let draft): _draft = State(initialValue: draft)
        case .edit(let device): _draft = State(initialValue: CustomDeviceDraft(from: device, named: device.name))
        }
    }

    var body: some View {
        if onClose != nil {
            form
        } else {
            sheet
        }
    }

    /// In place of other settings, which scroll: its title between Cancel and Save, then the fields.
    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Cancel", action: cancel)
                    .foregroundStyle(.tint)
                Spacer(minLength: 8)
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .foregroundStyle(draft.problems.isEmpty && !isSaving ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .disabled(!draft.problems.isEmpty || isSaving)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            fields
        }
        .numberFieldsOfAForm(model)
    }

    private var sheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    fields
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Not while a field is scrubbed by a finger.
            .scrollDisabled(model.scrubber.target?.owner == .form)
            .numberFieldsOfAForm(model)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // The document's own Back, which the sheet would otherwise show beside Cancel, isn't the sheet's to offer.
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!draft.problems.isEmpty || isSaving)
                }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        PanelSection {
            TextField("Name", text: $draft.name)
                .font(.system(size: 17, weight: .semibold))
                .padding(10)
                .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12))
                .accessibilityLabel("Device name")
            PanelRow("Kind") {
                Picker("Kind", selection: $draft.family) {
                    ForEach(DeviceFrame.Family.allCases, id: \.self) { family in
                        Text(family.singularName).tag(family)
                    }
                }
                .labelsHidden()
                Spacer(minLength: 0)
            }
        }

        PanelSection {
            HStack(spacing: 8) {
                NumberField("W", label: "Width", value: $draft.width, range: CustomDeviceDraft.sides)
                NumberField("H", label: "Height", value: $draft.height, range: CustomDeviceDraft.sides)
            }
            HStack(spacing: 8) {
                NumberField("R", label: "Corner radius", value: $draft.cornerRadius, range: 0...999)
                NumberField("M", label: "Margin", value: $draft.margin, range: 0...999)
            }
            ForEach(draft.problems, id: \.self) { problem in
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }

        PanelSection {
            Text("Safe Areas")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                NumberField("T", label: "Safe area top", value: $draft.safeTop, range: 0...999)
                NumberField("B", label: "Safe area bottom", value: $draft.safeBottom, range: 0...999)
            }
            HStack(spacing: 8) {
                NumberField("L", label: "Safe area leading", value: $draft.safeLeading, range: 0...999)
                NumberField("R", label: "Safe area trailing", value: $draft.safeTrailing, range: 0...999)
            }
        }

        PanelSection {
            Toggle("Status Bar", isOn: $draft.hasStatusBar)
            Toggle("Dynamic Island", isOn: $draft.hasIsland)
            Toggle("Home Indicator", isOn: $draft.hasHomeIndicator)
            Toggle("Limit Column Width", isOn: Binding(
                get: { draft.maxContentWidth != nil },
                set: { limited in draft.maxContentWidth = limited ? min(1080, draft.width) : nil }
            ))
            if let widest = draft.maxContentWidth {
                PanelRow("Column") {
                    NumberField("W", label: "Column width", value: Binding(get: { widest }, set: { draft.maxContentWidth = $0 }),
                                range: CustomDeviceDraft.sides)
                }
            }
        }

        if case .edit(let device) = purpose, !model.store.isCustomDeviceInUse(device.id) {
            PanelSection {
                Button("Delete Device", systemImage: "trash", role: .destructive) {
                    if model.store.deleteCustomDevice(device.id) { close() }
                }
                .foregroundStyle(.red)
            }
        }
    }

    private var title: String {
        if case .edit = purpose { return String(localized: "Edit Device") }
        return String(localized: "New Device")
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Goes without changing anything, typing ended first so that nothing is left holding the keyboard.
    private func cancel() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        close()
    }

    /// Keeps a number still being typed first: typing ends as the field gives up the keyboard, and the number is set
    /// a moment later. The device is then added, or the design's own replaced, as one step.
    private func save() {
        isSaving = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            switch purpose {
            case .add:
                guard let device = draft.device(id: nil) else { isSaving = false; return }
                add(device)
            case .edit(let device):
                guard let edited = draft.device(id: device.id) else { isSaving = false; return }
                model.store.updateCustomDevice(edited)
            }
            close()
        }
    }
}

private extension DeviceFrame.Family {
    /// What one device of the family is.
    var singularName: String {
        switch self {
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .desktop: "Desktop"
        case .watch: "Watch"
        case .other: "Other"
        }
    }
}
