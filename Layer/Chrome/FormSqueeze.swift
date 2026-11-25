import SwiftUI

extension View {
    /// Number fields of a form shown over the canvas in a presentation of its own: the board menu's design tokens, or a
    /// device's form. They are the window's one scrubber's (`AppModel.scrubber`), as the Format panel's are, so that
    /// a squeeze over one, or the barrel rolled, scrubs it. Their ruler is drawn over the form, and the form's
    /// handler has the squeezes while it is up (`FormSqueeze`).
    func numberFieldsOfAForm(_ model: AppModel) -> some View {
        modifier(FormFields(model: model))
    }
}

private struct FormFields: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let scrubber = model.scrubber
        content
            .overlay { ScrubberOverlay(owner: .form) }
            .coordinateSpace(.named(Scrubber.space))
            // Where the form is in the window, for a step's tick to be felt at its field.
            .reportsFormOrigin(to: scrubber)
            .background { FormSqueeze(model: model) }
            .environment(scrubber)
            .environment(\.scrubberOwner, .form)
            // A ruler left up by the pencil goes with the form, and so does a field's hover.
            .onDisappear {
                scrubber.end(.form)
                scrubber.forgetHovered(.form)
            }
    }
}

/// A form's squeeze handler and its frame in the window. While a form with number fields is up, it has Apple Pencil
/// Pro's squeezes rather than the window's or a panel sheet's under it, as a panel's sheet does: the system doesn't
/// promise squeezes to a view under a presentation, and only one handler is there at a time. Its points are the
/// form's, put in the window's.
private struct FormSqueeze: View {
    let model: AppModel

    var body: some View {
        let router = model.squeezeRouter
        let isOn = router.formHandlerIsOn
        ZStack {
            // In window points, which a presentation's own global space may not be.
            WindowFrameReporter(name: SqueezeRouter.formChrome, model: model)
            // Not `Color.clear`, which gets no squeezes on the iPad.
            Color.black.opacity(0.001)
                .modifier(Squeezable(router: router, isOn: isOn, offset: { router.formOrigin }))
        }
        .onAppear { router.formCameUp() }
        .onChange(of: isOn) { _, isOn in
            VoiceLog.log.info("pencil: a form's squeeze handler is \(isOn ? "on" : "off", privacy: .public)")
            if !isOn { router.failed() }
        }
        .onDisappear {
            if isOn { router.failed() }
            router.formWent()
        }
    }
}
