import Combine
import SwiftUI

/// Bottom left: zoom out, the current zoom, zoom in. The zoom itself opens a menu with a
/// lock for the canvas, zoom to fit, and levels to jump to.
struct ZoomControl: View {
    @Environment(AppModel.self) private var model
    /// Whether it is part of a larger control, which supplies the background.
    var isBare = false

    var body: some View {
        @Bindable var model = model
        // The zoom alone: a pan doesn't redraw this.
        let percent = Int((model.zoomScale * 100).rounded())
        HStack(spacing: 0) {
            step("minus", label: "Zoom out") { model.ink?.zoom(to: model.zoomScale / 1.25) }
            Menu {
                Toggle("Lock Canvas", systemImage: "lock", isOn: $model.isCanvasLocked)
                Button("Zoom to Fit Content", systemImage: "arrow.up.left.and.arrow.down.right") { model.ink?.zoomToFit() }
                Divider()
                ForEach([25, 50, 100, 200, 400], id: \.self) { level in
                    Button("\(level)%") { model.ink?.zoom(to: CGFloat(level) / 100) }
                }
            } label: {
                HStack(spacing: 4) {
                    if model.isCanvasLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text("\(percent)%")
                        .font(.system(size: 17, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(.primary)
                .frame(minWidth: 60)
                .frame(height: 44)
                .contentShape(.rect)
            }
            .accessibilityLabel("Zoom")
            .accessibilityValue(model.isCanvasLocked ? "\(percent) percent, canvas locked" : "\(percent) percent")
            step("plus", label: "Zoom in") { model.ink?.zoom(to: model.zoomScale * 1.25) }
        }
        .buttonStyle(.plain)
        .modifier(ControlCapsule(isBare: isBare, axis: .horizontal))
    }

    private func step(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
    }
}

/// The background of a small floating control.
private struct ControlCapsule: ViewModifier {
    let isBare: Bool
    let axis: Axis

    func body(content: Content) -> some View {
        if isBare {
            content
        } else {
            content
                .padding(axis == .horizontal ? .horizontal : .vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
    }
}

/// Undo, redo and the zoom as one control at the bottom left, at any window width, which
/// leaves the other corner for the pencil palette.
struct ViewControls: View {
    var body: some View {
        HStack(spacing: 0) {
            UndoControl(axis: .horizontal, isBare: true)
            ZoomControl(isBare: true)
        }
        .modifier(ControlCapsule(isBare: false, axis: .horizontal))
    }
}

/// Undo and redo, for when the pencil palette and its own undo buttons are away. Each
/// is only there while it has something to do: undo once there is a step to take back,
/// redo once one has been taken back, and nothing at all on an untouched design. As part
/// of a larger control it lies flat and brings a divider to set it off from what follows.
struct UndoControl: View {
    @Environment(\.undoManager) private var undoManager
    @State private var canUndo = false
    @State private var canRedo = false
    var axis = Axis.vertical
    /// Whether it is part of a larger control, which supplies the background.
    var isBare = false

    var body: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        // A stack that is always there, to listen for changes even while it shows nothing.
        ZStack {
            if canUndo || canRedo {
                layout {
                    if canUndo {
                        button("arrow.uturn.backward", label: "Undo") { undoManager?.undo() }
                    }
                    if canRedo {
                        button("arrow.uturn.forward", label: "Redo") { undoManager?.redo() }
                    }
                    if isBare {
                        Rectangle()
                            .fill(.separator)
                            .frame(width: axis == .horizontal ? 1 : 22, height: axis == .horizontal ? 22 : 1)
                            .padding(axis == .horizontal ? .horizontal : .vertical, 3)
                    }
                }
                .buttonStyle(.plain)
                .modifier(ControlCapsule(isBare: isBare, axis: axis))
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        // The undo history is shared with PencilKit, so it changes outside this view too.
        .onReceive(undoChanges) { _ in refresh() }
        // The control is made afresh when the window's width moves it, with history already there.
        .onAppear { refresh() }
        .onChange(of: undoManager) { refresh() }
    }

    private func refresh() {
        let (undo, redo) = (undoManager?.canUndo ?? false, undoManager?.canRedo ?? false)
        guard undo != canUndo || redo != canRedo else { return }
        withAnimation(.smooth(duration: 0.25)) {
            canUndo = undo
            canRedo = redo
        }
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }

    private var undoChanges: some Publisher<Notification, Never> {
        let center = NotificationCenter.default
        return center.publisher(for: .NSUndoManagerDidCloseUndoGroup, object: undoManager)
            .merge(with: center.publisher(for: .NSUndoManagerDidUndoChange, object: undoManager))
            .merge(with: center.publisher(for: .NSUndoManagerDidRedoChange, object: undoManager))
    }
}

