import SwiftUI
import Testing
import UIKit
@testable import Layer

extension Tag {
    /// A test of how the system behaves, which the app relies on, rather than of the app.
    @Tag static var describesSwiftUI: Self
}

/// Two elements' X, as the Format panel shows one of them: the field is bound to whichever
/// is selected now, and every value set on each is noted.
@MainActor @Observable
private final class TwoElements {
    var isSecondSelected = false
    var first: CGFloat = 10
    var second: CGFloat = 20
    var setOnFirst: [CGFloat] = []
    var setOnSecond: [CGFloat] = []
}

/// A number field being typed into, bound as the Format panel binds its fields: afresh on
/// every update, to what is selected then, reading the value it had at that update.
private struct TypingIntoTheSelection: View {
    let elements: TwoElements
    /// As the Rotation field does: from 0 to 360, past one end round to the other.
    var wraps = false

    var body: some View {
        let (first, second) = (elements.first, elements.second)
        let value = elements.isSecondSelected
            ? Binding(get: { second }, set: { elements.second = $0; elements.setOnSecond.append($0) })
            : Binding(get: { first }, set: { elements.first = $0; elements.setOnFirst.append($0) })
        TypedNumber(label: "X", value: value, range: wraps ? 0...360 : -99_999...99_999, wraps: wraps) {}
            .frame(width: 200, height: 40)
    }
}

/// The X field of a real element, bound as the Format panel binds it: reading the frame the
/// element had at the last update, and setting it as one adjustment, which undoes as a step.
private struct TypingIntoAnElement: View {
    let model: AppModel
    let ref: DesignStore.ElementRef

    var body: some View {
        let x = model.store.resolve(ref)?.element.frame.origin.x ?? 0
        TypedNumber(label: "X", value: Binding(get: { x }, set: { value in
            model.adjusting { model.store.update(ref) { $0.frame.origin.x = value } }
        }), range: -99_999...99_999, wraps: false) {}
            .frame(width: 200, height: 40)
    }
}

/// SwiftUI's own formatted text field, bound the same way.
private struct PlainFieldOnTheSelection: View {
    let elements: TwoElements

    var body: some View {
        let (first, second) = (elements.first, elements.second)
        let value = elements.isSecondSelected
            ? Binding(get: { Double(second) }, set: { elements.second = CGFloat($0); elements.setOnSecond.append(CGFloat($0)) })
            : Binding(get: { Double(first) }, set: { elements.first = CGFloat($0); elements.setOnFirst.append(CGFloat($0)) })
        TextField("X", value: value, format: TypedNumber.format)
            .frame(width: 200, height: 40)
    }
}

extension HostedWindowSuites {
    /// A number typed into the Format panel goes to the element that was selected as typing
    /// began, even when another is tapped on the canvas before typing ends: tapping the canvas
    /// doesn't end typing, and the panel's fields are bound to whatever is selected (audit M5).
    /// Hosted in a window, so that SwiftUI's own text field decides when what is typed is set.
    @MainActor
    @Suite("Typing into the Format panel")
    struct TypingIntoTheFormatPanelTests {
        private func host<Content: View>(_ content: Content) async throws -> (window: UIWindow, view: UIView) {
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            let host = UIHostingController(rootView: content)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // Before the field takes the keyboard: the on-screen keyboard coming up held the
            // main thread, and the suites alongside, for half a second at a time.
            for field in Self.textFields(in: host.view) { quiet(field) }
            return (window, host.view)
        }

        /// Lets SwiftUI catch up: its tasks, focus and updates.
        private func settle(_ view: UIView) async throws {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(30))
                view.layoutIfNeeded()
            }
        }

        /// The text field the number is typed into, once it has taken the keyboard.
        private func focusedField(in view: UIView) async throws -> UITextField {
            for _ in 0..<40 {
                if let field = Self.textFields(in: view).first(where: \.isFirstResponder) { return field }
                try await Task.sleep(for: .milliseconds(25))
                view.layoutIfNeeded()
            }
            throw FieldNotFocused()
        }

        private struct FieldNotFocused: Error {}

        private static func textFields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(textFields(in:))
        }

        /// Types over what the field shows.
        private func type(_ text: String, into field: UITextField) {
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText(text)
        }

        /// What the fix has to deal with, as SwiftUI does it: a formatted field sets its value as
        /// the text changes, not only as typing ends. Bound to another value mid-typing, it shows
        /// that value in place of what was typed, and what is typed next goes to the new value.
        /// This describes SwiftUI, not the app (iOS 27): a later iOS may fail it while the app is
        /// fine, and then the tests after it say whether the app still is.
        @Test(.tags(.describesSwiftUI))
        func swiftUIsFormattedFieldSetsAsItIsTypedAndFollowsANewBinding() async throws {
            let elements = TwoElements()
            let (window, view) = try await host(PlainFieldOnTheSelection(elements: elements))
            defer { window.isHidden = true }
            let field = try #require(Self.textFields(in: view).first)
            #expect(field.becomeFirstResponder())
            type("100", into: field)
            try await settle(view)
            #expect(field.isFirstResponder)
            #expect(elements.first == 100)

            elements.isSecondSelected = true
            try await settle(view)
            #expect(field.text == "20")
            type("250", into: field)
            #expect(elements.setOnSecond.contains(250))
            field.resignFirstResponder()
            try await settle(view)
            #expect(elements.first == 100)
        }

        @Test func aNumberTypedIsSetOnWhatWasSelectedWhenTypingBegan() async throws {
            let elements = TwoElements()
            let (window, view) = try await host(TypingIntoTheSelection(elements: elements))
            defer { window.isHidden = true }
            let field = try await focusedField(in: view)
            #expect(field.text == "10")
            type("100", into: field)
            try await settle(view)
            #expect(elements.first == 10, "nothing is set while it is typed")
            #expect(elements.setOnFirst.isEmpty)

            // The second element is tapped on the canvas: the panel now shows it, and binds the
            // field being typed in to it. What is being typed stays, and is still the first's.
            elements.isSecondSelected = true
            try await settle(view)
            #expect(field.isFirstResponder)
            #expect(field.text == "100")
            type("250", into: field)

            // The keyboard is put away, which ends typing.
            field.resignFirstResponder()
            try await settle(view)
            #expect(elements.first == 250)
            #expect(elements.second == 20)
            #expect(elements.setOnSecond.isEmpty)
        }

        /// Not a number, or an endless one, isn't set: a frame that isn't finite can't be saved,
        /// and scrubbing it traps (audit M18).
        @Test(arguments: ["nan", "NaN", "inf", "-inf", "1e999"], [false, true])
        func aNumberThatIsntFiniteIsntSet(_ typed: String, wraps: Bool) async throws {
            let elements = TwoElements()
            let (window, view) = try await host(TypingIntoTheSelection(elements: elements, wraps: wraps))
            defer { window.isHidden = true }
            let field = try await focusedField(in: view)
            type(typed, into: field)
            try await settle(view)
            field.resignFirstResponder()
            try await settle(view)
            let notFinite = elements.setOnFirst.filter { !$0.isFinite }
            #expect(notFinite.isEmpty, "set: \(elements.setOnFirst)")
            #expect(elements.first.isFinite)
        }

        /// Nothing is set while a number is typed, however many digits go in: the element only
        /// changes, once, as typing ends, so that a group doesn't shrink to its smallest at
        /// the first digit deleted and the panel isn't rebuilt under the keyboard.
        @Test func nothingIsSetUntilTypingEndsAndThenOnce() async throws {
            let elements = TwoElements()
            let (window, view) = try await host(TypingIntoTheSelection(elements: elements))
            defer { window.isHidden = true }
            let field = try await focusedField(in: view)
            for text in ["", "1", "10", "100"] {
                type(text, into: field)
                try await settle(view)
                #expect(elements.setOnFirst.isEmpty, "set while typing \(text): \(elements.setOnFirst)")
            }
            field.resignFirstResponder()
            try await settle(view)
            #expect(elements.setOnFirst == [100])
            #expect(elements.first == 100)
        }

        /// Text that isn't a number leaves the value as it was.
        @Test func textThatIsntANumberSetsNothing() async throws {
            let elements = TwoElements()
            let (window, view) = try await host(TypingIntoTheSelection(elements: elements))
            defer { window.isHidden = true }
            let field = try await focusedField(in: view)
            type("abc", into: field)
            field.resignFirstResponder()
            try await settle(view)
            #expect(elements.setOnFirst.isEmpty)
            #expect(elements.first == 10)
        }

        /// Undo pressed while the field has the keyboard takes back the step before, and the
        /// number typed, set as typing ends, is a step of its own that undo takes back and
        /// redo puts back.
        @Test func undoWhileTheFieldIsFocusedThenTheTypedNumberIsOneStep() async throws {
            let model = AppModel(document: LayerDocument())
            let undo = UndoManager()
            undo.groupsByEvent = false
            model.store.undoManager = undo
            model.adjustmentPause = .milliseconds(10)
            let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 1)).id
            var button = DesignStore.newElement(.button)
            button.frame = CGRect(x: 20, y: 300, width: 353, height: 50)
            let ref = model.store.setElements([button], on: screen, replacing: true)[0]
            func x() -> CGFloat? { model.store.resolve(ref)?.element.frame.origin.x }
            undo.removeAllActions()

            let (window, view) = try await host(TypingIntoAnElement(model: model, ref: ref))
            defer { window.isHidden = true }
            let field = try await focusedField(in: view)
            type("100", into: field)
            try await settle(view)
            #expect(x() == 20, "not set until typing ends")
            #expect(!undo.canUndo)

            field.resignFirstResponder()
            try await settle(view)
            #expect(x() == 100)
            for _ in 0..<100 where model.store.isEditing { try await Task.sleep(for: .milliseconds(20)) }
            undo.undo()
            #expect(x() == 20, "one undo takes the typed number back")
            #expect(undo.canRedo)
            undo.redo()
            #expect(x() == 100)
        }

        /// Return ends typing as well, and sets the number on the same element.
        @Test func returnSetsItOnWhatWasSelectedWhenTypingBegan() async throws {
            let elements = TwoElements()
            let (window, view) = try await host(TypingIntoTheSelection(elements: elements))
            defer { window.isHidden = true }
            let field = try await focusedField(in: view)
            type("100", into: field)
            elements.isSecondSelected = true
            try await settle(view)

            _ = field.delegate?.textFieldShouldReturn?(field)
            field.resignFirstResponder()
            try await settle(view)
            #expect(elements.first == 100)
            #expect(elements.second == 20)
            #expect(elements.setOnSecond.isEmpty)
        }
    }
}

/// A field's value, and every value set on it.
@MainActor
final class ScrubbedField {
    var value: CGFloat
    var sets: [CGFloat] = []
    init(_ value: CGFloat) { self.value = value }

    func target(_ label: String, at frame: CGRect, range: ClosedRange<CGFloat> = 0...360, degreesPerStep: Double = 1) -> Scrubber.Target {
        Scrubber.Target(
            label: label, unit: "", frame: frame, range: range,
            get: { self.value }, set: { self.value = $0; self.sets.append($0) },
            degreesPerStep: degreesPerStep, wraps: range == 0...360
        )
    }
}

/// The pencil hovering, as the window's hover recogniser tells the panel's bridge: in a
/// state, at a roll of the barrel.
private final class PencilHovering: UIHoverGestureRecognizer {
    var now: UIGestureRecognizer.State = .possible
    var roll: CGFloat = 0
    override var state: UIGestureRecognizer.State {
        get { now }
        set { now = newValue }
    }
    override var rollAngle: CGFloat { roll }

    func moved(_ state: UIGestureRecognizer.State, toDegrees degrees: Double) {
        now = state
        roll = degrees * .pi / 180
    }
}

/// The ruler that scrubs a field: rolled by the pencil's barrel after a squeeze, or dragged
/// by a finger holding the field (audit M8).
@MainActor
@Suite("Scrubbing a field")
struct ScrubbingAFieldTests {
    /// Only a roll made while the pencil stays in hover range turns the value. Turned in the
    /// hand while out of range, or while touching the canvas, it jumped by as much.
    @Test func rollWhileThePencilIsAwayIsntCounted() {
        let scrubber = Scrubber()
        let rotation = ScrubbedField(0)
        // Squeezed over the Rotation field, one degree a step: its ruler is up.
        scrubber.begin(rotation.target("Rotation", at: CGRect(x: 0, y: 0, width: 80, height: 32)))
        scrubber.hover(.began, roll: .degrees(0))
        scrubber.hover(.changed, roll: .degrees(5))
        #expect(rotation.value == 5)

        // Out of range, turned in the hand, and back.
        scrubber.hover(.ended, roll: .degrees(5))
        scrubber.hover(.began, roll: .degrees(60))
        #expect(rotation.value == 5)
        scrubber.hover(.changed, roll: .degrees(62))
        #expect(rotation.value == 7)
        // Cancelled, as when the pencil touches down, the same.
        scrubber.hover(.cancelled, roll: .degrees(62))
        scrubber.hover(.began, roll: .degrees(140))
        scrubber.hover(.changed, roll: .degrees(141))
        #expect(rotation.value == 8)
    }

    /// The same, through the bridge that follows the pencil's hover in the window: what the
    /// recogniser says reaches the scrubber with its state (review m9 b).
    @Test func theBridgePassesTheHoversStateOn() {
        let scrubber = Scrubber()
        let bridge = PencilBridge.BridgeView()
        bridge.scrubber = scrubber
        let hover = PencilHovering()
        let rotation = ScrubbedField(0)
        scrubber.begin(rotation.target("Rotation", at: CGRect(x: 0, y: 0, width: 80, height: 32)))
        for (state, degrees) in [(UIGestureRecognizer.State.began, 0.0), (.changed, 5), (.ended, 5), (.began, 60), (.changed, 62)] {
            hover.moved(state, toDegrees: degrees)
            bridge.hovered(hover)
        }
        #expect(rotation.value == 7)
    }

    /// While the pencil's ruler is up on one field, a finger holding another scrubs that one:
    /// the pencil's is put away first.
    @Test func aFingerHoldingAnotherFieldScrubsThatOne() {
        let scrubber = Scrubber()
        var begins = 0
        var ends = 0
        scrubber.onBegin = { begins += 1 }
        scrubber.onEnd = { ends += 1 }
        let rotation = ScrubbedField(0)
        let opacity = ScrubbedField(50)
        let rotationTarget = rotation.target("Rotation", at: CGRect(x: 0, y: 0, width: 80, height: 32))
        let opacityTarget = opacity.target("Opacity", at: CGRect(x: 90, y: 0, width: 80, height: 32), range: 5...100)
        scrubber.begin(rotationTarget)

        // Three steps' worth of finger, as the field's hold gesture reports it.
        scrubber.fingerDragged(opacityTarget, by: 3 * Scrubber.pointsPerStep)
        #expect(rotation.sets.isEmpty)
        #expect(opacity.value == 53)
        #expect(scrubber.target?.label == "Opacity")
        #expect(begins == 2 && ends == 1, "the pencil's scrub ended, and the finger's began")

        // The finger goes on holding: it is the same scrub.
        scrubber.fingerDragged(opacityTarget, by: 5 * Scrubber.pointsPerStep)
        #expect(opacity.value == 55)
        #expect(begins == 2)
    }

    /// A ruler put away under a finger that goes on dragging (a squeeze that keeps it, Draw
    /// coming on) comes back from the value it was left at, counting the drag from there:
    /// not the whole drag over again (final review M6).
    @Test func aRulerRestartedUnderADraggingFingerCountsFromWhereItRestarted() {
        let scrubber = Scrubber()
        let opacity = ScrubbedField(50)
        let target = opacity.target("Opacity", at: CGRect(x: 90, y: 0, width: 80, height: 32), range: 5...100)
        scrubber.fingerDragged(target, by: 3 * Scrubber.pointsPerStep)
        #expect(opacity.value == 53)

        scrubber.end()
        // The finger is still down, and has dragged a little further.
        scrubber.fingerDragged(target, by: 4 * Scrubber.pointsPerStep)
        #expect(opacity.value == 53, "the restarted ruler hasn't moved yet")
        scrubber.fingerDragged(target, by: 6 * Scrubber.pointsPerStep)
        #expect(opacity.value == 55)

        // A new touch counts from its own start.
        scrubber.fingerLifted(.panel)
        #expect(scrubber.target == nil)
        scrubber.fingerDragged(target, by: 2 * Scrubber.pointsPerStep)
        #expect(opacity.value == 57)
    }

    /// A zoom scrub is no edit: only a panel field's scrub opens and closes one.
    @Test func aZoomScrubIsNoEdit() {
        let scrubber = Scrubber()
        var begins = 0
        var ends = 0
        scrubber.onBegin = { begins += 1 }
        scrubber.onEnd = { ends += 1 }
        let zoom = ScrubbedField(0)
        let frame = CGRect(x: 0, y: 0, width: 80, height: 32)
        scrubber.begin(Scrubber.Target(
            label: "Zoom", unit: "%", frame: frame, range: 0...14,
            get: { zoom.value }, set: { zoom.value = $0 }, owner: .zoom
        ))
        scrubber.scrub(to: 2)
        scrubber.end()
        #expect(begins == 0 && ends == 0)
        #expect(zoom.value == 2)

        let panel = ScrubbedField(0)
        scrubber.begin(Scrubber.Target(
            label: "Zoom", unit: "%", frame: frame, range: 0...14,
            get: { panel.value }, set: { panel.value = $0 }
        ))
        scrubber.scrub(to: 2)
        scrubber.end()
        #expect(begins == 1 && ends == 1)
        #expect(panel.value == 2)
    }

    @Test func endingOneOwnersRulerLeavesTheOthers() {
        let scrubber = Scrubber()
        let zoom = ScrubbedField(0)
        let frame = CGRect(x: 0, y: 0, width: 80, height: 32)
        scrubber.begin(Scrubber.Target(
            label: "Zoom", unit: "%", frame: frame, range: 0...14,
            get: { zoom.value }, set: { zoom.value = $0 }, owner: .zoom
        ))
        scrubber.end(.panel)
        #expect(scrubber.target?.owner == .zoom)
        scrubber.end(.zoom)
        #expect(scrubber.target == nil)

        scrubber.hovered = ScrubbedField(0).target("Rotation", at: frame)
        scrubber.forgetHovered(.zoom)
        #expect(scrubber.hovered != nil)
        scrubber.forgetHovered(.panel)
        #expect(scrubber.hovered == nil)
    }

    @Test func aSqueezeKeepsTheValueOrBringsUpTheHoveredRuler() {
        let scrubber = Scrubber()
        #expect(scrubber.squeezeBegan(roll: .degrees(30)) == false)
        let rotation = ScrubbedField(10)
        scrubber.hovered = rotation.target("Rotation", at: .zero)
        #expect(scrubber.squeezeBegan(roll: .degrees(30)) == true)
        #expect(scrubber.target?.label == "Rotation")
        scrubber.rolled(to: .degrees(35))
        #expect(rotation.value == 15)
        #expect(scrubber.squeezeBegan(roll: nil) == true)
        #expect(scrubber.target == nil)
        #expect(rotation.value == 15)
    }

    @Test func theScrubberSaysWhenASqueezeWouldBeItsOwn() {
        let scrubber = Scrubber()
        let rotation = ScrubbedField(10)
        let target = rotation.target("Rotation", at: .zero)
        #expect(scrubber.wantsSqueeze == false)
        scrubber.hovered = target
        #expect(scrubber.wantsSqueeze == true)
        scrubber.hovered = nil
        #expect(scrubber.wantsSqueeze == false)
        scrubber.begin(target)
        #expect(scrubber.wantsSqueeze == true)
        scrubber.end()
        #expect(scrubber.wantsSqueeze == false)
    }

    /// The bridge that plays a step's tick sits behind the canvas, so it is told where the
    /// field is in the window: a panel field's frame is in the panel's space, which starts at
    /// `panelOrigin`; the zoom control's is in the window already.
    @Test func aStepsTickIsFeltWhereItsFieldIsInTheWindow() {
        let scrubber = Scrubber()
        var points: [CGPoint] = []
        scrubber.onStep = { points.append($0) }
        scrubber.panelOrigin = CGPoint(x: 700, y: 50)
        scrubber.begin(ScrubbedField(10).target("W", at: CGRect(x: 20, y: 30, width: 80, height: 32), range: 0...100))
        scrubber.scrub(to: 1)
        #expect(points == [CGPoint(x: 760, y: 96)])
        scrubber.end()

        scrubber.begin(ZoomStops.target(frame: CGRect(x: 10, y: 700, width: 60, height: 40), current: { 1 }, zoom: { _ in }))
        scrubber.scrub(to: 1)
        #expect(points.last == CGPoint(x: 40, y: 720))
        scrubber.end()
    }

    @Test func aRulerShowsItsOwnWordsAndMarks() {
        let frame = CGRect.zero
        func make(_ build: (inout Scrubber.Target) -> Void = { _ in }) -> Scrubber.Target {
            var target = Scrubber.Target(label: "X", unit: "W", frame: frame, range: 0...100, get: { 0 }, set: { _ in })
            build(&target)
            return target
        }
        #expect(make().shown(12) == "12 W")
        #expect(make { $0.text = { "\(Int($0))%" } }.shown(8) == "8%")
        #expect(make().isMajor(10) && !make().isMajor(5))
        let fifteens = make { $0.ticksEvery = 15 }
        #expect(fifteens.isMajor(30) && !fifteens.isMajor(10))
        let marks = make { $0.majorMarks = [3, 8] }
        #expect(marks.isMajor(8) && !marks.isMajor(10))
    }
}

/// The Format panel's own changes beside a drag, under the store's edits that each have an
/// identity of their own: a number typed (as `TypedNumber` sets it, through the panel's
/// `adjusting`), the pencil's scrub of one field and a finger's of another (M8's hold) are
/// each a step of their own, and none ends the drag, which stays one step (merge with
/// main's concurrent edits).
@MainActor
@Suite("The panel's changes beside a drag")
struct PanelChangesBesideADragTests {
    @Test func typingAndEachScrubAreStepsOfTheirOwnAndTheDragGoesOn() async throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = AppModel(document: LayerDocument())
        model.store.undoManager = undo
        model.adjustmentPause = .milliseconds(10)
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1)).id
        let refs = model.store.setElements([
            DesignElement(kind: .title, frame: CGRect(x: 20, y: 80, width: 300, height: 40), text: "Welcome", tint: Theme.accent),
            DesignElement(kind: .button, frame: CGRect(x: 20, y: 700, width: 353, height: 50), text: "Go", tint: Theme.accent),
        ], on: screen, replacing: false)
        let (title, button) = (refs[0], refs[1])
        undo.removeAllActions()
        func frame(_ ref: DesignStore.ElementRef) -> CGRect? { model.store.resolve(ref)?.element.frame }
        let titleBefore = try #require(frame(title))
        let buttonBefore = try #require(frame(button))

        // A finger drags the button.
        let drags = CanvasDrags()
        model.drags = drags
        let owner = CanvasDrags.Owner()
        let found = try #require(model.store.resolve(button))
        func drag(by dx: CGFloat) {
            drags.moveElement(button, from: found.element.frame, placement: found.placement, by: CGSize(width: dx, height: 0), startingAt: .zero, owner: owner, model: model) {
                { origin, translation in (origin.offsetBy(dx: translation.width, dy: translation.height), []) }
            }
        }
        drag(by: 10)

        // Meanwhile the pencil scrubs the title's width; then a finger holds its Y and scrubs
        // that, which puts the pencil's ruler away.
        let scrubber = Scrubber()
        scrubber.onBegin = { model.beginScrubbing() }
        scrubber.onEnd = { model.endScrubbing() }
        func field(_ label: String, _ keyPath: WritableKeyPath<CGRect, CGFloat>, at y: CGFloat) -> Scrubber.Target {
            Scrubber.Target(
                label: label, unit: label, frame: CGRect(x: 0, y: y, width: 80, height: 32), range: 0...4000,
                get: { model.store.resolve(title)?.element.frame[keyPath: keyPath] ?? 0 },
                set: { value in model.adjusting { model.store.update(title) { $0.frame[keyPath: keyPath] = value } } }
            )
        }
        scrubber.begin(field("W", \.size.width, at: 0))
        scrubber.scrub(to: 5)
        scrubber.fingerDragged(field("Y", \.origin.y, at: 40), by: 3 * Scrubber.pointsPerStep)
        scrubber.end()
        drag(by: 20)

        // Then the title's X is typed, as TypedNumber sets it.
        model.adjusting { model.store.update(title) { $0.frame.origin.x = 100 } }

        // The drag goes on, and drops; the panel's pause then ends its own step.
        drag(by: 30)
        drags.dropElement(button, findsNewHome: false, owner: owner, model: model)
        for _ in 0..<100 where model.store.isEditing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.store.isEditing)
        let moved = try #require(frame(button))
        #expect(moved.minX == buttonBefore.minX + 30)

        // Undo takes each back on its own, the last first: the typed number, the finger's
        // scrub, the pencil's, then the whole drag, frames before and after them alike.
        undo.undo()
        #expect(frame(title)?.minX == titleBefore.minX)
        #expect(frame(title)?.minY == titleBefore.minY + 3)
        undo.undo()
        #expect(frame(title)?.minY == titleBefore.minY)
        #expect(frame(title)?.width == titleBefore.width + 5)
        undo.undo()
        #expect(frame(title) == titleBefore)
        #expect(frame(button) == moved)
        undo.undo()
        #expect(frame(button) == buttonBefore)
    }
}

extension HostedWindowSuites {
    /// Where the Format panel's space starts in the window, measured by UIKit: in a sheet,
    /// SwiftUI's global space is the sheet's, not the window's.
    @MainActor
    @Suite("The panel's place in the window")
    struct PanelOriginTests {
        @Test func thePanelsOriginIsMeasuredInTheWindow() async throws {
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            defer { window.isHidden = true }
            let scrubber = Scrubber()
            let sheet = UIView(frame: CGRect(x: 0, y: 420, width: 1000, height: 380))
            let panel = UIView(frame: CGRect(x: 16, y: 14, width: 300, height: 300))
            let reporter = PanelOriginReporter.ReportingView(frame: panel.bounds)
            reporter.scrubber = scrubber
            window.addSubview(sheet)
            sheet.addSubview(panel)
            panel.addSubview(reporter)
            window.layoutIfNeeded()
            #expect(scrubber.panelOrigin == CGPoint(x: 16, y: 434))
            // The sheet pulled up: told again as it is laid out.
            sheet.frame = CGRect(x: 0, y: 100, width: 1000, height: 700)
            reporter.setNeedsLayout()
            window.layoutIfNeeded()
            #expect(scrubber.panelOrigin == CGPoint(x: 16, y: 114))
        }
    }
}

/// What typing a number into a Format field comes to, as typing ends.
@MainActor
@Suite("A number typed into a Format field")
struct NumberDraftTests {
    private let wide: ClosedRange<CGFloat> = -99_999...99_999

    @Test func beginsAsTheValueShown() {
        #expect(NumberDraft(353).text == "353")
        #expect(NumberDraft(12.5).text == "12.5")
    }

    @Test func aNumberTypedCommitsOnce() {
        var draft = NumberDraft(353)
        draft.text = "706"
        #expect(draft.committed(in: wide, wraps: false) == 706)
    }

    @Test(arguments: ["", " ", "abc", "nan", "inf", "-inf", "1e999"])
    func textThatIsntANumberCommitsNothing(_ text: String) {
        var draft = NumberDraft(353)
        draft.text = text
        #expect(draft.committed(in: wide, wraps: false) == nil)
    }

    @Test func theSameNumberCommitsNothing() {
        var draft = NumberDraft(353)
        draft.text = "353"
        #expect(draft.committed(in: wide, wraps: false) == nil)
    }

    @Test func aNumberIsHeldToItsRange() {
        var draft = NumberDraft(10)
        draft.text = "99999"
        #expect(draft.committed(in: 1...4000, wraps: false) == 4000)
        draft.text = "-5"
        #expect(draft.committed(in: 1...4000, wraps: false) == 1)
    }

    @Test func aTurnWrapsRoundTheCircle() {
        var draft = NumberDraft(10)
        draft.text = "370"
        #expect(draft.committed(in: 0...360, wraps: true) == nil, "370 comes round to the 10 it began with")
        draft.text = "-90"
        #expect(draft.committed(in: 0...360, wraps: true) == 270)
    }
}
