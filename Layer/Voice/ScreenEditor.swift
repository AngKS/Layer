import Foundation
import Observation

/// A selected screen's field, "Describe a change…": what is typed there until it is sent,
/// what it sends, and how the change typed there is getting on, which the field shows in
/// place of the words.
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

    /// What is typed in a screen's field, as it is sent: the field clears as the change goes,
    /// and the words come back if it couldn't be sent, rather than being lost.
    struct Draft: Equatable {
        var text: String
        /// The words on their way, as typed, until the send says whether they went.
        private var sending: String?

        init(text: String = "") {
            self.text = text
        }

        var isSending: Bool { sending != nil }

        var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        /// Nothing typed and nothing on its way.
        var isEmpty: Bool { text.isEmpty && sending == nil }

        /// The words to send, trimmed, clearing the field; nil, with the field cleared, when
        /// they are blank.
        mutating func takeForSending() -> String? {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let typed = text
            text = ""
            guard !words.isEmpty else { return nil }
            sending = typed
            return words
        }

        /// The send is over: words that couldn't be sent are put back, unless something
        /// has been typed since.
        mutating func sendEnded(_ wasSent: Bool) {
            guard let typed = sending else { return }
            sending = nil
            if !wasSent, isBlank { text = typed }
        }
    }

    @ObservationIgnored private weak var model: AppModel?
    /// Screens whose change is being sent: waiting on the call to get ready, or behind a
    /// command spoken a moment earlier whose words are still settling. It has no number yet.
    private var sending: Set<TreeScreen.ID> = []
    /// Each screen's last change sent.
    private var sent: [TreeScreen.ID: Sent] = [:]
    /// Words typed in each screen's field and not sent. Kept here, not by the field, which
    /// goes whenever its screen stops being selected or the bar hides: they are there when
    /// it comes back. Only a screen with something typed, or on its way, has one.
    private var drafts: [TreeScreen.ID: Draft] = [:]

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Drafts

    /// What is typed in `screen`'s field.
    func draft(for screen: TreeScreen.ID) -> Draft {
        drafts[screen] ?? Draft()
    }

    /// The person typed in `screen`'s field: it now holds `text`.
    func setDraft(_ text: String, for screen: TreeScreen.ID) {
        guard draft(for: screen).text != text else { return }
        changeDraft(for: screen) { $0.text = text }
    }

    /// Sends what is typed in `screen`'s field as a change to that screen. The words are
    /// taken at once, clearing the field, and come back if they couldn't be sent, unless
    /// something has been typed since. Returns the send, whose value says whether the
    /// change went; nil, with the field cleared, when only blanks were typed.
    func sendDraft(for screen: TreeScreen.ID) -> Task<Bool, Never>? {
        var taken: String?
        changeDraft(for: screen) { taken = $0.takeForSending() }
        guard let words = taken else { return nil }
        return Task {
            let wasSent = await send(words, to: screen)
            changeDraft(for: screen) { $0.sendEnded(wasSent) }
            return wasSent
        }
    }

    private func changeDraft(for screen: TreeScreen.ID, _ change: (inout Draft) -> Void) {
        var draft = draft(for: screen)
        change(&draft)
        drafts[screen] = draft.isEmpty ? nil : draft
    }

    // MARK: Changes

    /// Sends `text`, trimmed, as a change to `screen` and everything on it. Returns false,
    /// sending nothing, for blank text, a model that can't be asked, a change to that
    /// screen still under way, a screen that has gone or a design that has closed; and
    /// when the pencil's call ended while the change waited for it.
    ///
    /// Once begun, a send isn't cancelled with the task it was asked from, as when the
    /// field goes away: it would stop waiting for a command spoken a moment earlier, and go
    /// ahead of it.
    func send(_ text: String, to screen: TreeScreen.ID) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let model, !model.isClosed, model.store.treeScreen(screen) != nil,
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
    func progress(for screen: TreeScreen.ID) -> VoiceCall.Progress {
        if sending.contains(screen) { return .working(nil) }
        guard let change = sent[screen], let call = change.call, call.phase != .ended,
              call === model?.pencilVoice.call else { return .over }
        return call.progress(of: change.number)
    }

    /// Whether a change to `screen` is on its way, which keeps another from being sent.
    func isBusy(for screen: TreeScreen.ID) -> Bool {
        if case .working = progress(for: screen) { return true }
        return false
    }

    /// What the field for `screen` shows in place of the words typed, or nil when there is
    /// nothing to show and it shows its words or its placeholder.
    func line(for screen: TreeScreen.ID) -> Line? {
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
