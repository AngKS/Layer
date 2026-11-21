import SwiftUI
import Testing
import UIKit
@testable import Layer

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

    var body: some View {
        let (first, second) = (elements.first, elements.second)
        let value = elements.isSecondSelected
            ? Binding(get: { second }, set: { elements.second = $0; elements.setOnSecond.append($0) })
            : Binding(get: { first }, set: { elements.first = $0; elements.setOnFirst.append($0) })
        TypedNumber(label: "X", value: value, range: -99_999...99_999, wraps: false) {}
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

/// A number typed into the Format panel goes to the element that was selected as typing
/// began, even when another is tapped on the canvas before typing ends: tapping the canvas
/// doesn't end typing, and the panel's fields are bound to whatever is selected (audit M5).
/// Hosted in a window, so that SwiftUI's own text field decides when what is typed is set.
@MainActor
@Suite("Typing into the Format panel")
struct TypingIntoTheFormatPanelTests {
    private func host<Content: View>(_ content: Content) throws -> (window: UIWindow, view: UIView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
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
    @Test func swiftUIsFormattedFieldSetsAsItIsTypedAndFollowsANewBinding() async throws {
        let elements = TwoElements()
        let (window, view) = try host(PlainFieldOnTheSelection(elements: elements))
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
        let (window, view) = try host(TypingIntoTheSelection(elements: elements))
        defer { window.isHidden = true }
        let field = try await focusedField(in: view)
        #expect(field.text == "10")
        type("100", into: field)
        try await settle(view)
        #expect(elements.first == 100)

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

    /// Return ends typing as well, and sets the number on the same element.
    @Test func returnSetsItOnWhatWasSelectedWhenTypingBegan() async throws {
        let elements = TwoElements()
        let (window, view) = try host(TypingIntoTheSelection(elements: elements))
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

/// A field's value, and every value set on it.
@MainActor
private final class ScrubbedField {
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

        scrubber.hold(opacityTarget)
        scrubber.scrub(to: 3)
        #expect(rotation.sets.isEmpty)
        #expect(opacity.value == 53)
        #expect(scrubber.target?.label == "Opacity")
        #expect(begins == 2 && ends == 1, "the pencil's scrub ended, and the finger's began")

        // The finger goes on holding: it is the same scrub.
        scrubber.hold(opacityTarget)
        scrubber.scrub(to: 5)
        #expect(opacity.value == 55)
        #expect(begins == 2)
    }
}
