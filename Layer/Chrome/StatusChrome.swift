import Combine
import SwiftUI

/// Bottom left: the current zoom. Tapped, it opens a menu with a lock for the canvas, zoom
/// to fit, and levels to jump to. Held with a finger and dragged sideways, or squeezed over
/// with an Apple Pencil Pro and rolled (the window's `SqueezeRouter` brings its ruler up),
/// it steps through the zoom stops on a ruler. Zooming isn't an edit: it makes no undo step.
///
/// The menu is a popover from a button, not a `Menu`: a `Menu` opens on a hold as well as
/// a tap, and the hold never reached the scrubbing gesture.
struct ZoomControl: View {
    @Environment(AppModel.self) private var model
    /// Whether it is part of a larger control, which supplies the background.
    var isBare = false
    /// Where the control is in the window, for the ruler's ticks.
    @State private var frame = CGRect.zero
    @State private var showsMenu = false
    /// Whether the touch under way was held long enough to scrub. Its lift then isn't a tap,
    /// though the button takes it for one.
    @State private var wasHeld = false
    /// The stop VoiceOver's adjust last glided to, for the next while that glide is under way.
    @State private var requestedStop: CGFloat?
    @GestureState private var isHeld = false

    var body: some View {
        // The zoom alone: a pan doesn't redraw this.
        let percent = Int((model.zoomScale * 100).rounded())
        let scrubber = model.scrubber
        Button {
            if wasHeld { wasHeld = false } else { showsMenu = true }
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
        .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
            ZoomMenu(model: model) { showsMenu = false }
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Zoom")
        .accessibilityValue(model.isCanvasLocked ? "\(percent) percent, canvas locked" : "\(percent) percent")
        // VoiceOver: swiping up or down goes to the next stop; activating still opens the menu.
        .accessibilityAdjustableAction { direction in
            let stop = ZoomStops.step(from: model.zoomScale, requested: requestedStop, isGliding: model.ink?.isGliding ?? false, by: direction == .increment ? 1 : -1)
            requestedStop = stop
            model.ink?.zoom(to: stop)
        }
        // A hold that ended off the control leaves `wasHeld` set, which would swallow this.
        .accessibilityAction(.default) {
            wasHeld = false
            showsMenu = true
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
        // A pencil hovering here is what a squeeze would scrub.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active: scrubber.hovered = target
            case .ended: scrubber.forgetHovered(.zoom)
            }
        }
        // Tapped, it opens the menu; held, it scrubs.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: PencilVoice.holdThreshold / .seconds(1))
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .updating($isHeld) { value, isHeld, _ in
                    if case .second(true, _) = value { isHeld = true }
                }
                .onChanged { value in
                    switch value {
                    case .first:
                        // A new touch: whatever the last one was, this may yet be a tap.
                        wasHeld = false
                    case .second(true, let drag):
                        wasHeld = true
                        scrubber.fingerDragged(target, by: drag?.translation.width ?? 0)
                    case .second:
                        break
                    }
                }
        )
        // However the hold ends, lifted or cancelled, scrubbing ends with it: the zoom's, not
        // a Format field's ruler.
        .onChange(of: isHeld) { _, held in if !held { scrubber.fingerLifted(.zoom) } }
        // The controls go during a call: a ruler left up, or a hover, would be the zoom's
        // with no zoom control to show it.
        .onDisappear {
            scrubber.fingerLifted(.zoom)
            scrubber.forgetHovered(.zoom)
        }
        .buttonStyle(ZoomButton(isHeld: isHeld))
        .modifier(ControlCapsule(isBare: isBare, axis: .horizontal))
    }

    /// The zoom's ruler: the stops, from the one nearest the zoom now.
    private var target: Scrubber.Target {
        ZoomStops.target(frame: frame, current: { model.zoomScale }, zoom: { model.ink?.zoom(to: $0) })
    }
}

/// The zoom's menu: a lock for the canvas, zoom to fit, and the levels, in the order a menu
/// opening upward from the control shows them. A choice closes it, as it would a menu.
private struct ZoomMenu: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ZoomStops.menuLevels.reversed(), id: \.self) { level in
                row("\(level)%") { model.ink?.zoom(to: CGFloat(level) / 100) }
            }
            Divider()
                .padding(.vertical, 4)
            row("Zoom to Fit Content", symbol: "arrow.up.left.and.arrow.down.right") { model.ink?.zoomToFit() }
            row("Lock Canvas", symbol: "lock", isOn: model.isCanvasLocked) { model.isCanvasLocked.toggle() }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
    }

    private func row(_ title: String, symbol: String? = nil, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            close()
        } label: {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: 20)
                }
                Text(title)
                Spacer(minLength: 8)
                if isOn {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(ZoomMenuRow())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The percentage: dimmed while a tap presses it, as a plain button is, but at full strength
/// while a hold scrubs, for the zoom it reads is the one being stepped through.
private struct ZoomButton: ButtonStyle {
    let isHeld: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed && !isHeld ? 0.4 : 1)
    }
}

/// A row of the zoom's menu: highlighted while pressed.
private struct ZoomMenuRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
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
        .overlay(alignment: .topLeading) { ZoomRuler() }
    }
}

/// The zoom's ruler while it is scrubbed, just above the controls and lined up with their
/// leading edge. Its own view, so that a step redraws the ruler and not the controls.
private struct ZoomRuler: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scrubber = model.scrubber
        let isUp = scrubber.target?.owner == .zoom
        ZStack(alignment: .bottomLeading) {
            if let target = scrubber.target, target.owner == .zoom {
                ScrubberRuler(
                    value: scrubber.value, text: target.shown(scrubber.value),
                    spacing: target.pointsPerStep, isMajor: target.isMajor
                )
                    .frame(width: max(min(280, model.canvasSize.width - 40), 0))
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        // Its bottom 8 pt above the controls' top.
        .alignmentGuide(.top) { $0[.bottom] + 8 }
        .animation(.snappy(duration: 0.18), value: isUp)
        .allowsHitTesting(false)
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
        // The undo history takes in ink drawn on the canvas, so it changes outside this view too.
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

    private var undoChanges: some Publisher<Notification, Never> { Self.changes(of: undoManager) }

    /// Every notice that what undo and redo can do may have changed: a step put in, undone,
    /// redone, or taken out again by the design (see `DesignStore.historyDidChange`).
    static func changes(of undoManager: UndoManager?) -> some Publisher<Notification, Never> {
        let center = NotificationCenter.default
        return center.publisher(for: .NSUndoManagerDidCloseUndoGroup, object: undoManager)
            .merge(with: center.publisher(for: .NSUndoManagerDidUndoChange, object: undoManager))
            .merge(with: center.publisher(for: .NSUndoManagerDidRedoChange, object: undoManager))
            .merge(with: center.publisher(for: DesignStore.historyDidChange, object: undoManager))
    }
}

