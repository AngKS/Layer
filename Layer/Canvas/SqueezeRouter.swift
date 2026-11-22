import SwiftUI

/// Decides who has each of Apple Pencil Pro's squeezes in a window: a ruler (a Format
/// field's or the zoom's), push-to-talk, or nobody. SwiftUI calls every visible view's
/// squeeze action, in no fixed order, so two handlers could both act on one squeeze: the
/// one that kept a ruler's value, and push-to-talk starting to listen. The window has one
/// handler (`CanvasScreen`'s `WindowSqueeze`), and it asks this.
@MainActor
final class SqueezeRouter {
    /// Who has the squeeze under way.
    enum Taker: Equatable { case ruler, voice, nobody }

    /// The squeeze under way, once it is decided; nil between squeezes.
    private(set) var taker: Taker?

    /// Read afresh at each call, never kept: its scrubber and its pencil are the ones the
    /// window shows now (a test puts its own pencil in).
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    /// Whether a squeeze may start push-to-talk: Squeeze to Talk, in Settings and the board's
    /// Magic Pen tab.
    var talks: Bool { model?.squeezesToTalk ?? false }

    /// Whether the window's squeeze handler is there at all. Its inputs are all observed, so
    /// a view that reads it follows each of them.
    var hearsSqueezes: Bool {
        guard let model else { return false }
        return Self.wantsHandler(drawIsOn: model.tool == .draw, talks: talks, rulerWantsSqueeze: model.scrubber.wantsSqueeze)
    }

    /// A handler that is there, even one that ignores the squeeze, keeps it from PencilKit's
    /// palette in Draw (seen on the iPad) and from the system's own action elsewhere. So it
    /// is there only outside Draw, and only while push-to-talk or a ruler would take it.
    nonisolated static func wantsHandler(drawIsOn: Bool, talks: Bool, rulerWantsSqueeze: Bool) -> Bool {
        !drawIsOn && (talks || rulerWantsSqueeze)
    }

    /// A squeeze began, with the pen hovering at `viewPoint` in the window, or out of range
    /// when nil. Its `.active` comes every 10–20 ms while it lasts: who has it is decided at
    /// the first, and the rest do nothing.
    func began(at viewPoint: CGPoint?, azimuth: Angle?, roll: Angle?) {
        guard taker == nil, let model else { return }
        let scrubber = model.scrubber
        let pencil = model.pencilVoice
        let rulerIsUp = scrubber.target != nil
        if pencil.ownsSqueeze, !rulerIsUp {
            // A toggle is listening, or being sent: this squeeze sends it, even with the pen
            // drifted over a field.
            taker = .voice
            pencil.squeezeBegan(at: viewPoint, azimuth: azimuth)
        } else {
            // A field's hover with the pen out of range, or away from the controls, was left
            // behind by a field that went (its panel closed or the selection moved on).
            if !rulerIsUp, scrubber.hovered != nil, viewPoint.map({ !model.isOverChrome($0) }) ?? true {
                scrubber.hovered = nil
            }
            if scrubber.squeezeBegan(roll: roll) {
                taker = .ruler
            } else if talks {
                taker = .voice
                pencil.squeezeBegan(at: viewPoint, azimuth: azimuth)
            } else {
                taker = .nobody
            }
        }
        VoiceLog.log.info("pencil: squeeze began at \(String(describing: viewPoint), privacy: .public), taken by \(String(describing: self.taker), privacy: .public)")
    }

    func ended() {
        if taker == .voice { model?.pencilVoice.squeezeEnded() }
        taker = nil
    }

    /// The squeeze's gesture failed, or the handler went away: its end will never come.
    func failed() {
        if taker == .voice { model?.pencilVoice.squeezeFailed() }
        taker = nil
    }

    /// Draw came on, which takes the handler away for PencilKit's palette: the squeeze under
    /// way won't be heard to end, and a ruler the pencil left up goes, since the squeeze that
    /// would keep its value can't come in Draw.
    func drawTurnedOn() {
        taker = nil
        model?.scrubber.end()
    }
}
