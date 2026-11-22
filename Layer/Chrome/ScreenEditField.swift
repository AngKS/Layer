import SwiftUI

/// A selected screen's field, in the bar over it: "Describe a change…". What is typed there
/// goes to the agent voice mode uses, about that screen and everything on it, and is made
/// as one undo step (`ScreenEditor`). While the change is on its way the field shows the
/// step it is on ("Restyling…"), and then its reply for as long as the call's caption would.
///
/// Until it is tapped it is a plain line, as the format panel's number fields are, which
/// leaves pressing and holding it free: held, it listens for the change instead, with the
/// pencil's bubble at the field, and letting go sends it (`PencilVoice.holdBegan`). Once it
/// is being typed in, long presses there are the system's.
///
/// Without a model that can be asked, it is disabled and says why.
struct ScreenEditField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let screen: DesignScreen.ID

    @State private var draft = Draft()
    @State private var isTyping = false
    @FocusState private var isFocused: Bool
    @GestureState private var isHeld = false
    /// Whether this field began a listen with `holdBegan` and hasn't ended it. A field taken
    /// away mid-hold (the selection moved on, the screen locked or deleted, the canvas
    /// adjusting) never hears the hold end, so it ends the listen as it goes: otherwise the
    /// microphone stays on for up to `PencilVoice.maximumHold`.
    @State private var holdIsOpen = false
    /// Why no change can be sent, when no model can be asked. Asking can read the Keychain,
    /// so it is asked as the field appears and as the model preferences change, never as
    /// it draws.
    @State private var whyUnavailable: String?
    /// The field's middle in the window, where the pencil's bubble opens for a hold.
    @State private var middle = CGPoint.zero

    /// The least the field gives way to, in the narrowest window.
    static let narrowest: CGFloat = 96

    static let label = "Describe a change"
    static let placeholder = "Describe a change…"

    var body: some View {
        let shown = shown
        Group {
            if isTyping {
                typing
            } else if case .unavailable(let reason) = shown {
                // No tap, no hold and nothing for VoiceOver to do: only why.
                Self.text(reason, style: .secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.label)
                    .accessibilityValue(reason)
            } else {
                line(shown)
            }
        }
        // 240 points, 150 in a narrow window, and less in the narrowest, where the rest of
        // the bar leaves less (see `SelectionActions`).
        .frame(minWidth: Self.narrowest, maxWidth: model.isCompactWidth ? 150 : 240)
        .frame(height: 44)
        // A field of its own in every state, as the format panel's are, and opaque: through
        // the bar's glass, or a translucent fill, what is under it showed, such as a phone
        // frame's Dynamic Island just after the placeholder, which read as a send button.
        .background {
            Capsule()
                .fill(Color(uiColor: .secondarySystemBackground))
                .padding(.vertical, 4)
        }
        .onGeometryChange(for: CGPoint.self, of: { proxy in
            let frame = proxy.frame(in: .global)
            return CGPoint(x: frame.midX, y: frame.midY)
        }) { middle = $0 }
        // Tapped, it is typed into; held, it listens. Neither while it is typed in already.
        .gesture(TapGesture().onEnded { startTyping() }, isEnabled: !isTyping && canType(shown))
        .gesture(hold, isEnabled: canHold(shown))
        // However the hold ends, lifted or cancelled, what was said is sent.
        .onChange(of: isHeld) { _, held in held ? beginHold() : endHold() }
        .disabled(shown.isUnavailable)
        .onAppear {
            // The call gets ready, so that the first change doesn't wait on it.
            model.pencilVoice.prepare()
            whyUnavailable = model.screenEditor.whyUnavailable()
        }
        .onDisappear(perform: endHold)
        // A key added or a model chosen in Settings may have changed whether one can be asked.
        .onReceive(NotificationCenter.default.publisher(for: ModelPreferences.changed)) { _ in askAgain() }
        // So may Apple Intelligence, turned on in the system's Settings and come back from.
        .onChange(of: scenePhase) { _, phase in if phase == .active { askAgain() } }
    }

    /// Asks again whether a model can be asked, and gets the call ready if one can now.
    private func askAgain() {
        whyUnavailable = model.screenEditor.whyUnavailable()
        if whyUnavailable == nil {
            model.pencilVoice.prepare()
        } else {
            // Kept, for when one can be asked again.
            isTyping = false
        }
    }

    // MARK: What it shows

    /// What the field shows, when it isn't being typed in.
    private enum Shown: Equatable {
        /// Nothing typed, nothing under way: the placeholder.
        case idle
        /// Words typed and not sent, or put back as they couldn't be.
        case draft(String)
        /// The step the change is on.
        case working(String)
        /// What was done, or what the model said when it did nothing.
        case reply(String)
        /// Why nothing was done.
        case problem(String)
        /// Why no change can be sent.
        case unavailable(String)

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    /// A change on its way shows its step whatever else is so; then why no change can be
    /// sent; then words typed; then the last change's reply, while it lasts.
    private var shown: Shown {
        let editor = model.screenEditor
        // Until the editor has the change, the field says it is on its way itself.
        let line = editor.line(for: screen) ?? (draft.isSending ? .working(ScreenEditor.noStepYet) : nil)
        if case .working(let step)? = line { return .working(step) }
        if let whyUnavailable { return .unavailable(whyUnavailable) }
        if !draft.isBlank { return .draft(draft.text) }
        switch line {
        case .reply(let text)?: return .reply(text)
        case .problem(let text)?: return .problem(text)
        case .working, nil: return .idle
        }
    }

    /// The field as a plain line, which is typed into once tapped.
    private func line(_ shown: Shown) -> some View {
        let typable = canType(shown)
        let text: String
        let style: Style
        switch shown {
        case .idle: (text, style) = (Self.placeholder, .placeholder)
        // A reply has no tick: what the model said may be that it did nothing.
        case .draft(let words): (text, style) = (words, .typed)
        case .working(let words), .reply(let words): (text, style) = (words, .primary)
        case .problem(let words), .unavailable(let words): (text, style) = (words, .secondary)
        }
        return Self.text(text, style: style)
            // Highlighted under the pointer, as the bar's buttons are.
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label)
            // The placeholder is the label already.
            .accessibilityValue(shown == .idle ? "" : text)
            .accessibilityAddTraits(typable ? .isButton : [])
            .accessibilityAction { if typable { startTyping() } }
            // Only while it would do something: listen, or send what is being listened to.
            .accessibilityActions {
                if canHold(shown) || model.pencilVoice.isListening {
                    Button("Speak a change", action: speakForVoiceOver)
                }
            }
    }

    private enum Style {
        case primary, secondary, placeholder
        /// Words typed and not sent.
        case typed
    }

    /// A line of the field. The placeholder and words typed keep to one line, as they are
    /// while typed, so that nothing moves as typing begins: the placeholder shrinks to fit a
    /// narrow field, and words are cut short. Anything else may take two lines.
    private static func text(_ text: String, style: Style) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(style == .secondary ? Color.secondary : style == .placeholder ? Color(uiColor: .placeholderText) : Color.primary)
            .lineLimit(style == .placeholder || style == .typed ? 1 : 2)
            .truncationMode(.tail)
            .minimumScaleFactor(style == .placeholder ? 0.7 : style == .typed ? 1 : 0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .contentShape(.rect)
    }

    // MARK: Typing

    private var typing: some View {
        HStack(spacing: 0) {
            // Untitled: the placeholder under it is the idle line's, so it doesn't move or
            // change size as typing begins.
            TextField("", text: $draft.text)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .focused($isFocused)
                .onSubmit(send)
                .padding(.leading, 10)
                .accessibilityLabel(Self.label)
                // Focus taken as the field appears is dropped; a moment later it holds.
                .task {
                    try? await Task.sleep(for: .milliseconds(50))
                    isFocused = true
                }
                // Typing ends however focus goes: Return, the arrow, or a tap elsewhere.
                .onChange(of: isFocused) { _, focused in if !focused { isTyping = false } }
            if !draft.isBlank {
                ToolButton(symbol: "arrow.up.circle.fill", label: "Send change", action: send)
            }
        }
        .background(alignment: .leading) {
            if draft.text.isEmpty {
                Self.text(Self.placeholder, style: .placeholder)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Whether a tap starts typing: not while a change is on its way, nor when none can be sent.
    private func canType(_ shown: Shown) -> Bool {
        !shown.isWorking && !shown.isUnavailable
    }

    private func startTyping() {
        isTyping = true
    }

    /// Sends what was typed, clearing the field and ending typing; blank, it only ends
    /// typing. Words that couldn't be sent come back.
    private func send() {
        let words = draft.takeForSending()
        isFocused = false
        isTyping = false
        guard let words else { return }
        let editor = model.screenEditor
        let screen = screen
        Task {
            let sent = await editor.send(words, to: screen)
            draft.sendEnded(sent)
            // The model may have gone since the field appeared.
            if !sent { whyUnavailable = editor.whyUnavailable() }
        }
    }

    // MARK: Holding

    /// Held for push-to-talk's threshold, then for as long as the finger stays down,
    /// wherever it goes.
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: PencilVoice.holdThreshold / .seconds(1))
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isHeld) { value, isHeld, _ in
                if case .second(true, _) = value { isHeld = true }
            }
    }

    /// Only a plain line can be held: one being typed in is the system's to long-press, and
    /// one whose change is on its way, or that can't be used, takes none.
    private func canHold(_ shown: Shown) -> Bool {
        !isTyping && !shown.isWorking && !shown.isUnavailable
    }

    private func beginHold() {
        model.pencilVoice.holdBegan(about: screen, at: middle)
        holdIsOpen = true
    }

    private func endHold() {
        guard holdIsOpen else { return }
        holdIsOpen = false
        model.pencilVoice.holdEnded()
    }

    /// VoiceOver's "Speak a change": the first use listens, as a hold does, and the next
    /// sends, as letting go does.
    private func speakForVoiceOver() {
        if model.pencilVoice.isListening {
            // Only a hold's listen is sent: a squeeze's is left to the squeeze.
            holdIsOpen = false
            model.pencilVoice.holdEnded()
        } else if canHold(shown) {
            beginHold()
        }
    }
}

extension ScreenEditField {
    /// What is typed in the field, as it is sent: the field clears as the change goes, and
    /// the words come back if it couldn't be sent, rather than being lost.
    struct Draft: Equatable {
        var text = ""
        /// The words on their way, as typed, until the send says whether they went.
        private var sending: String?

        var isSending: Bool { sending != nil }

        var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
}
