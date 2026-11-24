import SwiftUI

/// Chooses a device: the built-ins by family, then the design's own under "Custom", then "Custom Size…", which makes
/// a new one in `CustomDeviceSheet`, and "Edit Device" for each of the design's own. Shown as the device chosen, as a
/// menu picker shows its choice.
struct DevicePicker: View {
    @Environment(AppModel.self) private var model
    let title: String
    /// The device chosen; nil is the iPhone.
    let selection: String?
    /// Whether each device is listed with its size, as the Format panel lists them.
    var showsSizes = false
    /// Whether the device's name is drawn in the tint, as the Format panel's pickers draw their choice; the board
    /// menu's draw theirs in the text colour, with only the chevrons tinted.
    var tintsName = true
    /// Chooses a device: nil is the iPhone.
    let choose: (String?) -> Void
    /// What a device made with "Custom Size…" is added for, as one step.
    let add: (DeviceFrame) -> Void
    /// Shows the device being made or edited where the picker's owner shows it; nil for a sheet from the picker.
    var present: ((CustomDeviceSheet.Purpose) -> Void)? = nil
    /// The device being made or edited, while its sheet is up.
    @State private var sheet: CustomDeviceSheet.Purpose?

    /// The devices listed: each family that has built-ins, under its name, then the design's own under "Custom".
    static func sections(_ settings: CanvasSettings) -> [(title: String, devices: [DeviceFrame])] {
        var sections: [(title: String, devices: [DeviceFrame])] = DeviceFrame.Family.allCases.compactMap { family in
            let devices = DeviceFrame.all.filter { $0.family == family }
            return devices.isEmpty ? nil : (family.name, devices)
        }
        if !settings.customDevices.isEmpty { sections.append(("Custom", settings.customDevices)) }
        return sections
    }

    var body: some View {
        let settings = model.store.tree.settings
        let chosen = settings.device(named: selection)
        let sections = Self.sections(settings)
        Menu {
            // Each family under its name, the one chosen ticked.
            ForEach(sections.indices, id: \.self) { index in
                Section(sections[index].title) {
                    ForEach(sections[index].devices) { device in
                        Toggle(label(device), isOn: Binding(
                            get: { device.id == chosen.id },
                            set: { _ in choose(device.id == DeviceFrame.iPhone.id ? nil : device.id) }
                        ))
                    }
                }
            }
            Section {
                Button("Custom Size…", systemImage: "rectangle.dashed") {
                    let start = DeviceFrame.custom(name: "Custom", size: chosen.size, family: chosen.family)
                    show(.add(CustomDeviceDraft(from: start, named: "Custom")))
                }
                if !settings.customDevices.isEmpty {
                    Menu("Edit Device", systemImage: "slider.horizontal.3") {
                        ForEach(settings.customDevices) { device in
                            Button(label(device)) { show(.edit(device)) }
                        }
                    }
                }
            }
        } label: {
            // As a menu picker shows its choice.
            HStack(spacing: 4) {
                Text(label(chosen))
                    .lineLimit(1)
                    .foregroundStyle(tintsName ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .font(.body)
        }
        .accessibilityLabel(title)
        .accessibilityValue(label(chosen))
        .sheet(item: $sheet) { purpose in
            CustomDeviceSheet(purpose: purpose, add: add)
                .environment(model)
        }
    }

    private func show(_ purpose: CustomDeviceSheet.Purpose) {
        if let present { present(purpose) } else { sheet = purpose }
    }

    private func label(_ device: DeviceFrame) -> String { Self.label(device, showsSize: showsSizes) }

    /// What a device is listed as: its name, and its size in whole points when `showsSize`. A size from a file too
    /// large for a whole number is said as the largest a design has (`wholePoints`), never trapping.
    static func label(_ device: DeviceFrame, showsSize: Bool) -> String {
        showsSize ? "\(device.name)  \(device.size.width.wholePoints) × \(device.size.height.wholePoints)" : device.name
    }
}
