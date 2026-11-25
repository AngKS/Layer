import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct LookWordsEverywhereTests {
    private func node(_ kind: ElementKind) -> LayerNode {
        LayerNode.standard(kind)
    }

    @Test func aLookCanBeGivenToAnElementAlone() {
        var button = node(.button)
        LookWords.look(from: ["Bordered", " #112233", "20pt", "border 3"]).apply(to: &button)
        #expect(button.content.buttonLook == .bordered)
        #expect(button.style.tint == RGBColor(hex: 0x112233))
        #expect(button.style.fontSize == 20)
        #expect(button.style.borderWidth == 3)
    }

    @Test func controlsTakeTheirStateFromLookWords() {
        var checkbox = node(.checkbox)
        LookWords.look(from: ["off"]).apply(to: &checkbox)
        #expect(checkbox.content.isOn == false)

        var radio = node(.radio)
        LookWords.look(from: ["selected"]).apply(to: &radio)
        #expect(radio.content.isOn == true)

        var progress = node(.progress)
        LookWords.look(from: ["40%"]).apply(to: &progress)
        #expect(progress.content.value == 0.4)

        var button = node(.button)
        LookWords.look(from: ["plain", "centre", "shadow", "border red", "opacity 50%"]).apply(to: &button)
        #expect(button.content.buttonLook == .plain)
        #expect(button.style.textAlignment == .center)
        #expect(button.style.hasShadow)
        #expect(button.style.borderColor == ColourWords.named["red"])
        #expect(button.style.borderWidth == 1)
        #expect(button.style.opacity == 0.5)
    }

    // `aLookOnANodeAndOnAnElementAgree` was retired under (s) with the flat element's look (`Look+Element`): the node's
    // half of it is `aLookCanBeGivenToAnElementAlone` and `controlsTakeTheirStateFromLookWords`, which give looks to nodes.

    @Test func kindsAreNamedByLookWords() {
        #expect(LookWords.kind(named: "Text Field") == .textField)
        #expect(LookWords.kind(named: "nonsense") == nil)
    }
}
