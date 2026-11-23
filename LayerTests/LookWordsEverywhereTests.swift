import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct LookWordsEverywhereTests {
    private func element(_ kind: ElementKind) -> DesignElement {
        DesignStore.newElement(kind, symbol: nil)
    }

    @Test func aLookCanBeGivenToAnElementAlone() {
        var button = element(.button)
        LookWords.look(from: ["Bordered", " #112233", "20pt", "border 3"]).apply(to: &button)
        #expect(button.buttonLook == .bordered)
        #expect(button.tint == RGBColor(hex: 0x112233))
        #expect(button.fontSize == 20)
        #expect(button.borderWidth == 3)
    }

    @Test func controlsTakeTheirStateFromLookWords() {
        var checkbox = element(.checkbox)
        LookWords.look(from: ["off"]).apply(to: &checkbox)
        #expect(checkbox.isOn == false)

        var radio = element(.radio)
        LookWords.look(from: ["selected"]).apply(to: &radio)
        #expect(radio.isOn == true)

        var progress = element(.progress)
        LookWords.look(from: ["40%"]).apply(to: &progress)
        #expect(progress.value == 0.4)

        var button = element(.button)
        LookWords.look(from: ["plain", "centre", "shadow", "border red", "opacity 50%"]).apply(to: &button)
        #expect(button.buttonLook == .plain)
        #expect(button.textAlignment == .center)
        #expect(button.hasShadow)
        #expect(button.borderColor == ColourWords.named["red"])
        #expect(button.borderWidth == 1)
        #expect(button.opacity == 0.5)
    }

    @Test func aLookOnANodeAndOnAnElementAgree() {
        let looks = [
            ["blue", "bold", "18pt", "radius 12"],
            ["off", "text white"],
            ["70%", "opacity 99.9%"],
            ["border red", "shadow", "outlined"],
            ["border 0", "left", "no shadow"],
            ["opacity 0.3", "border 2", "border green", "centre"],
        ]
        for words in looks {
            let look = LookWords.look(from: words)
            var node = LayerNode(kind: .button)
            look.apply(to: &node)

            var shown = element(.button)
            look.apply(to: &shown)
            let lifted = LayerNode(element: shown)
            // The element's tint is always set; the node's is nil unless the look gave one.
            var expected = node.style
            if expected.tint == nil { expected.tint = lifted.style.tint }
            #expect(lifted.style.tint == expected.tint || look.tint == nil, "\(words)")
            #expect(lifted.style.fontSize == node.style.fontSize, "\(words)")
            #expect(lifted.style.fontWeight == node.style.fontWeight, "\(words)")
            #expect(lifted.style.textColor == node.style.textColor, "\(words)")
            #expect(lifted.style.textAlignment == node.style.textAlignment, "\(words)")
            #expect(lifted.style.cornerRadius == node.style.cornerRadius, "\(words)")
            #expect(lifted.style.opacity == node.style.opacity, "\(words)")
            #expect(lifted.style.borderColor == node.style.borderColor, "\(words)")
            #expect(lifted.style.borderWidth == node.style.borderWidth, "\(words)")
            #expect(lifted.style.hasShadow == node.style.hasShadow, "\(words)")
            #expect(lifted.content.isOn == node.content.isOn, "\(words)")
            #expect(lifted.content.value == node.content.value, "\(words)")
            #expect(lifted.content.buttonLook == node.content.buttonLook, "\(words)")
            if look.tint != nil { #expect(lifted.style.tint == node.style.tint, "\(words)") }
        }
    }

    @Test func kindsAreNamedByLookWords() {
        #expect(LookWords.kind(named: "Text Field") == .textField)
        #expect(LookWords.kind(named: "nonsense") == nil)
    }
}
