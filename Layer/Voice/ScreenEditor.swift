import Foundation
import Observation

/// A selected screen's field, "Describe a change…": what it sends, and how the change
/// typed there is getting on, which the field shows in place of the words.
///
/// A change goes through the pencil's call (`PencilVoice.submit`) as a command about that
/// screen and everything on it, waiting its turn behind any command spoken a moment
/// earlier. It is followed by its number on that call, and numbers start again with each
/// call, so the call is kept with the number: a change on a call that has ended is over,
/// and never taken for the next call's command with the same number.
@MainActor
@Observable
final class ScreenEditor {
    /// What the field shows in place of the words typed, while a change is on its way and
    /// for a few seconds after.
    enum Line: Equatable {
        /// The step the change is on, such as "Restyling…".
        case working(String)
        /// What was done, or what the model said when it did nothing.
        case reply(String)
        /// Why nothing was done, shown as a problem.
        case problem(String)
    }

    /// Shown while a change has no step of its own yet: it is being sent, or waits its
    /// turn behind another command. The call's first step says the same.
    static let noStepYet = "Thinking…"

    /// A change sent, with the call it was sent on.
    private struct Sent {
        weak var call: VoiceCall?
        var number: Int
    }

    @ObservationIgnored private weak var model: AppModel?
    /// Screens whose change is being sent: waiting on the call to get ready, or behind a
    /// command spoken a moment earlier whose words are still settling. It has no number yet.
    private var sending: Set<DesignScreen.ID> = []
    /// Each screen's last change sent.
    private var sent: [DesignScreen.ID: Sent] = [:]

    init(model: AppModel) {
        self.model = model
    }

    /// Sends `text`, trimmed, as a change to `screen` and everything on it. Returns false,
    /// sending nothing, for blank text, a model that can't be asked, a change to that
    /// screen still under way, a screen that has gone or a design that has closed; and
    /// when the pencil's call ended while the change waited for it.
    ///
    /// Once begun, a send isn't cancelled with the task it was asked from, as when the
    /// field goes away: it would stop waiting for a command spoken a moment earlier, and go
    /// ahead of it.
    func send(_ text: String, to screen: DesignScreen.ID) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let model, !model.isClosed, model.store.screen(screen) != nil,
              !isBusy(for: screen), whyUnavailable() == nil else { return false }
        sending.insert(screen)
        sent[screen] = nil
        defer { sending.remove(screen) }
        let pencil = model.pencilVoice
        // A task of its own, which the caller's cancellation doesn't reach.
        let submitted = await Task { () -> (number: Int, call: VoiceCall?)? in
            guard let number = await pencil.submit(words, about: .screenEdit(screen)) else { return nil }
            // Read before anything else can run: the call the number was given on.
            return (number, pencil.call)
        }.value
        guard let submitted else { return false }
        sent[screen] = Sent(call: submitted.call, number: submitted.number)
        return true
    }

    /// How the change to `screen` is getting on: on its way, with no step yet, while it is
    /// being sent; then its own lines on the call it was sent on. Over with nothing sent,
    /// once the call it was sent on has ended, or once its reply has shown.
    func progress(for screen: DesignScreen.ID) -> VoiceCall.Progress {
        if sending.contains(screen) { return .working(nil) }
        guard let change = sent[screen], let call = change.call, call.phase != .ended,
              call === model?.pencilVoice.call else { return .over }
        return call.progress(of: change.number)
    }

    /// Whether a change to `screen` is on its way, which keeps another from being sent.
    func isBusy(for screen: DesignScreen.ID) -> Bool {
        if case .working = progress(for: screen) { return true }
        return false
    }

    /// What the field for `screen` shows in place of the words typed, or nil when there is
    /// nothing to show and it shows its words or its placeholder.
    func line(for screen: DesignScreen.ID) -> Line? {
        switch progress(for: screen) {
        case .working(let step): .working(step ?? Self.noStepYet)
        case .done(let text), .said(let text): .reply(text)
        case .problem(let text): .problem(text)
        case .over: nil
        }
    }

    /// Why no change can be sent, when the design's model can't be asked; nil when it can.
    /// Asking can read the Keychain: the field asks as it appears, as the selection
    /// changes and when the model preferences change, never as it draws.
    func whyUnavailable() -> String? {
        guard let model, case .unavailable(let reason) = model.pencilVoice.readiness() else { return nil }
        return reason
    }
}
