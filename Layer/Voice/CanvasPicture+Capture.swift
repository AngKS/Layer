import CoreGraphics
import Foundation

// MARK: From a design

extension CanvasPicture {
    /// The picture of a design as it is now. Anything not yet seen in this call is given
    /// its handle here.
    @MainActor
    static func capture(from model: AppModel, handles: VoiceHandles) -> CanvasPicture {
        let visible = model.canvasSize == .zero ? CGRect.null : model.viewport.visibleRect(in: model.canvasSize)
        let selectedElement = model.selectedElement?.element.id
        let selectedScreen = model.selectedScreen?.id

        func picture(of element: DesignElement, frame: CGRect?) -> Element {
            Element(
                handle: handles.handle(forElement: element.id), kind: element.kind.layerName.lowercased(),
                text: element.kind == .symbol ? (element.symbol ?? "") : element.text.trimmingCharacters(in: .whitespacesAndNewlines),
                frame: frame, look: look(of: element),
                isSelected: element.id == selectedElement, isLocked: element.isLocked, isHidden: element.isHidden
            )
        }

        var whole = CanvasPicture()
        for screen in model.store.screens {
            let frame = screen.canvasFrame
            let shown = frame.intersection(visible)
            let share = shown.isNull || frame.isEmpty ? 0 : Double(shown.width * shown.height / (frame.width * frame.height))
            // The handle of the screen comes before those of what is on it.
            let handle = handles.handle(forScreen: screen.id)
            let fromTheTop = screen.elements.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            whole.screens.append(Screen(
                handle: handle, name: screen.name, size: screen.size, visibleShare: share,
                isSelected: screen.id == selectedScreen, isLocked: screen.isLocked == true,
                elements: fromTheTop.map { picture(of: $0, frame: $0.frame) }
            ))
        }
        whole.loose = model.store.floating.map { picture(of: $0.element, frame: nil) }
        return whole
    }

    /// The parts of an element's look worth telling a model, in the words that would set them.
    private static func look(of element: DesignElement) -> [String] {
        var look: [String] = []
        // The fill only shows on the kinds that are filled.
        let isFilled: Set<ElementKind> = [.button, .symbol, .stickyNote, .toggle, .checkbox, .radio, .progress, .avatar]
        if isFilled.contains(element.kind) { look.append("colour \(name(of: element.tint))") }
        if let textColour = element.textColor { look.append("text \(name(of: textColour))") }
        if let size = element.fontSize { look.append("\(Int(size.rounded()))pt") }
        if let weight = element.fontWeight, weight != .regular { look.append(weight.rawValue) }
        if element.kind == .button, let style = element.buttonLook, style != .filled { look.append(style.rawValue) }
        if [.toggle, .checkbox, .radio].contains(element.kind) { look.append(element.isOn ? "on" : "off") }
        if element.kind == .progress { look.append("\(Int(((element.value ?? 0.5) * 100).rounded()))%") }
        return look
    }

    /// A colour by the shortest name Layer knows it by, or else as a hex code.
    private static func name(of colour: RGBColor) -> String {
        ColourWords.named.filter { $0.value == colour }.map(\.key).min { ($0.count, $0) < ($1.count, $1) } ?? colour.hex
    }
}
