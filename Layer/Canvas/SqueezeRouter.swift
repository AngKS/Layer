import Observation
import SwiftUI

/// Decides who has each of Apple Pencil Pro's squeezes in a window: a ruler (a Format
/// field's or the zoom's), push-to-talk, or nobody. SwiftUI calls every visible view's
/// squeeze action, in no fixed order, so two handlers could both act on one squeeze: the
/// one that kept a ruler's value, and push-to-talk starting to listen. The window has one
/// handler at a time (`CanvasScreen`'s `WindowSqueeze`, or a panel's sheet's while a panel is
/// a sheet), and it asks this.
@Observable
@MainActor
final class SqueezeRouter {
    /// Who has the squeeze under way.
    enum Taker: Equatable { case ruler, voice, nobody }

    /// The squeeze under way, once it is decided; nil between squeezes. Observed: the
    /// handler stays for as long as a squeeze is under way.
    private(set) var taker: Taker?

    /// How long a squeeze's `.active` can stop coming before the squeeze is taken to be over,
    /// its end lost: as long as a squeeze can listen. A squeeze held on keeps sending it.
    static let longestSqueeze: Duration = PencilVoice.maximumHold

    /// The time, for the squeeze that is taken to be over. A test says.
    @ObservationIgnored var clock: () -> ContinuousClock.Instant = { .now }

    /// When the squeeze under way last said it was still on.
    @ObservationIgnored private var lastActive: ContinuousClock.Instant?

    /// Read afresh at each call, never kept: its scrubber and its pencil are the ones the
    /// window shows now (a test puts its own pencil in).
    @ObservationIgnored private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    /// Whether a squeeze may start push-to-talk: Squeeze to Talk, in Settings and the board's
    /// Magic Pen tab.
    var talks: Bool { model?.squeezesToTalk ?? false }

    /// Whether a squeeze handler is there at all. Its inputs are all observed, so a view that
    /// reads it follows each of them.
    var hearsSqueezes: Bool {
        guard let model else { return false }
        return Self.wantsHandler(
            drawIsOn: model.tool == .draw, talks: talks,
            rulerWantsSqueeze: model.scrubber.wantsSqueeze, squeezeUnderWay: taker != nil
        )
    }

    /// Whether the window's handler is the one: not while a panel is a sheet, which has a
    /// handler of its own. Exactly one is there at a time.
    var windowHandlerIsOn: Bool { hearsSqueezes && model?.panelIsASheet == false }

    /// Whether a panel's sheet's handler is the one.
    var sheetHandlerIsOn: Bool { hearsSqueezes && model?.panelIsASheet == true }

    /// Where a panel's sheet is in the window, which its handler's points are counted from.
    var sheetOrigin: CGPoint { model?.chromeFrames[AppModel.panelSheetChrome]?.origin ?? .zero }

    /// A point in a handler's own view, put in the window's points.
    nonisolated static func windowPoint(_ point: CGPoint?, offsetBy origin: CGPoint) -> CGPoint? {
        point.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
    }

    /// A handler that is there, even one that ignores the squeeze, keeps it from PencilKit's
    /// palette in Draw (seen on the iPad) and from the system's own action elsewhere. So it
    /// is there only outside Draw, and only while push-to-talk or a ruler would take it, or a
    /// squeeze is under way: taken away mid-squeeze, its end would never come, and the same
    /// squeeze, brought back as the pen crossed a field, would act a second time.
    nonisolated static func wantsHandler(drawIsOn: Bool, talks: Bool, rulerWantsSqueeze: Bool, squeezeUnderWay: Bool = false) -> Bool {
        !drawIsOn && (talks || rulerWantsSqueeze || squeezeUnderWay)
    }

    /// A squeeze began, with the pen hovering at `viewPoint` in the window, or out of range
    /// when nil. Its `.active` comes every 10–20 ms while it lasts: who has it is decided at
    /// the first, and the rest do nothing.
    func began(at viewPoint: CGPoint?, azimuth: Angle?, roll: Angle?) {
        guard let model else { return }
        let now = clock()
        if taker != nil {
            if let lastActive, now - lastActive < Self.longestSqueeze {
                self.lastActive = now
                return
            }
            VoiceLog.log.info("pencil: a squeeze's end never came, so this one is new")
            failed()
        }
        lastActive = now
        let scrubber = model.scrubber
        let pencil = model.pencilVoice
        let rulerIsUp = scrubber.target != nil
        if pencil.ownsSqueeze, !rulerIsUp {
            // A toggle is listening, or being sent: this squeeze sends it, even with the pen
            // drifted over a field.
            taker = .voice
            pencil.squeezeBegan(at: viewPoint, azimuth: azimuth)
        } else {
            if !rulerIsUp, let hovered = scrubber.hovered, Self.isLeftBehind(hovered, at: viewPoint, in: model) {
                scrubber.hovered = nil
            }
            if pencil.squeezeIsOff() {
                // Apple Pencil settings turn squeezing off, or give it a shortcut: no ruler
                // comes up or goes, and push-to-talk ignores it too.
                taker = .nobody
            } else if scrubber.squeezeBegan(roll: roll) {
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
        finish()
    }

    /// The squeeze's gesture failed, or its handler went away: its end will never come.
    func failed() {
        if taker == .voice { model?.pencilVoice.squeezeFailed() }
        finish()
    }

    /// Draw came on, which takes the handler away for PencilKit's palette: the squeeze under
    /// way won't be heard to end, and a ruler the pencil left up goes, since the squeeze that
    /// would keep its value can't come in Draw.
    func drawTurnedOn() {
        finish()
        model?.scrubber.end()
    }

    /// Written only when there is a squeeze to finish: views follow `taker`.
    private func finish() {
        lastActive = nil
        if taker != nil { taker = nil }
    }

    /// Whether a hovered field was left behind by one that went away: its panel closed or
    /// the selection moved on with the pen elsewhere. The pen is out of range, or isn't over
    /// the field's own chrome: the Format panel for a field, the controls for the zoom.
    private static func isLeftBehind(_ hovered: Scrubber.Target, at viewPoint: CGPoint?, in model: AppModel) -> Bool {
        guard let viewPoint else { return true }
        switch hovered.owner {
        case .panel: return !model.isOverFormatPanel(viewPoint)
        case .zoom: return !model.isOverChrome(viewPoint)
        }
    }
}
