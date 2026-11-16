import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// A request for a sketch drawn on an iPhone screen at full size, so stroke and screen
/// points agree.
private func request(_ paths: [[CGPoint]], existing: [ExistingElement] = []) throws -> SketchRequest {
    let observation = try #require(SketchAnalyzer.observe(SketchSamples.strokes(paths)))
    return SketchRequest(observation: observation, placement: .onScreen(local: observation.bounds, existing: existing), strokes: paths)
}

private func reading(_ paths: [[CGPoint]]) throws -> SketchReading {
    RuleInterpreter().reading(for: try request(paths))
}

/// The element a sketch becomes, with what its inner marks say applied.
private func element(from paths: [[CGPoint]]) throws -> DesignElement {
    let request = try request(paths)
    guard case .element(let kind) = RuleInterpreter().reading(for: request) else {
        Issue.record("not an element")
        throw CancellationError()
    }
    var element = DesignStore.newElement(kind)
    element.adoptMarks(of: request.observation)
    return element
}

private func inner(_ paths: [[CGPoint]]) throws -> SketchObservation.InnerMark? {
    guard case .enclosure(_, let inner) = try #require(SketchAnalyzer.observe(SketchSamples.strokes(paths))).form else { return nil }
    return inner
}

@MainActor
private func makeStore() -> (store: DesignStore, screen: DesignScreen) {
    let store = DesignStore(content: DesignContent())
    store.undoManager = UndoManager()
    return (store, store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1)))
}

private let tinySquare = CGRect(x: 40, y: 300, width: 30, height: 30)

@Suite("Marks inside an outline")
struct InnerMarkTests {
    @Test func aTickIsToldApartFromAnX() throws {
        #expect(try inner([SketchSamples.box(tinySquare, radius: 4), SketchSamples.tick(tinySquare)]) == .tick)
        #expect(try inner([SketchSamples.box(tinySquare, radius: 4)] + SketchSamples.cross(tinySquare)) == .cross)
        let image = CGRect(x: 60, y: 120, width: 210, height: 230)
        #expect(try inner([SketchSamples.box(image, radius: 28)] + SketchSamples.cross(image)) == .cross)
    }

    @Test func aSmallMarkInTheMiddleIsADot() throws {
        let center = CGPoint(x: 55, y: 315)
        let paths = [SketchSamples.circle(center: center, radius: 15), SketchSamples.circle(center: center, radius: 4)]
        #expect(try inner(paths) == .dot)
    }

    @Test func theInnerMarksSayWhereTheySit() throws {
        let pill = CGRect(x: 300, y: 300, width: 64, height: 30)
        let knob = SketchSamples.circle(center: CGPoint(x: 349, y: 315), radius: 11)
        let observation = try #require(SketchAnalyzer.observe(SketchSamples.strokes([SketchSamples.box(pill, radius: 15), knob])))
        let bounds = try #require(observation.innerBounds)
        #expect(bounds.midX > 0.6)
    }
}

@Suite("Reading small controls")
struct SmallControlTests {
    @Test func aTinySquareIsACheckboxTickedWhenItHasAMark() throws {
        #expect(try reading([SketchSamples.box(tinySquare, radius: 4)]) == .element(.checkbox))
        #expect(try element(from: [SketchSamples.box(tinySquare, radius: 4)]).isOn == false)
        #expect(try element(from: [SketchSamples.box(tinySquare, radius: 4), SketchSamples.tick(tinySquare)]).isOn)
        // A tiny square with an X is a checked box rather than an image.
        #expect(try element(from: [SketchSamples.box(tinySquare, radius: 4)] + SketchSamples.cross(tinySquare)).kind == .checkbox)
    }

    @Test func aTinyCircleIsARadioButtonSelectedByADot() throws {
        let center = CGPoint(x: 55, y: 315)
        let selected = try element(from: [SketchSamples.circle(center: center, radius: 15), SketchSamples.circle(center: center, radius: 4)])
        #expect(selected.kind == .radio)
        #expect(selected.isOn)

        let empty = try element(from: [SketchSamples.circle(center: center, radius: 12)])
        #expect(empty.kind == .radio)
        #expect(!empty.isOn)
    }

    @Test func largerCirclesAreStillAvatars() throws {
        #expect(try reading([SketchSamples.circle(center: CGPoint(x: 60, y: 160), radius: 35)]) == .element(.avatar))
    }

    @Test func aToggleIsOnWhenItsKnobIsDrawnOnTheRight() throws {
        let pill = CGRect(x: 300, y: 300, width: 64, height: 30)
        let right = try element(from: [SketchSamples.box(pill, radius: 15), SketchSamples.circle(center: CGPoint(x: 349, y: 315), radius: 11)])
        #expect(right.kind == .toggle)
        #expect(right.isOn)
        let left = try element(from: [SketchSamples.box(pill, radius: 15), SketchSamples.circle(center: CGPoint(x: 315, y: 315), radius: 11)])
        #expect(left.kind == .toggle)
        #expect(!left.isOn)
    }

    @Test func aLongThinOutlineIsAProgressBarFilledAsFarAsItIsShaded() throws {
        let bar = CGRect(x: 40, y: 400, width: 300, height: 22)
        #expect(try reading([SketchSamples.box(bar, radius: 4)]) == .element(.progress))
        let hatching = (1...13).map { step in
            SketchSamples.straight(from: CGPoint(x: 40 + CGFloat(step) * 12, y: 421), to: CGPoint(x: 52 + CGFloat(step) * 12, y: 401))
        }
        let shaded = try element(from: [SketchSamples.box(bar, radius: 4)] + hatching)
        #expect(shaded.kind == .progress)
        #expect((0.45...0.65).contains(shaded.resolvedValue))
    }

    @Test func ordinaryTextFieldsAndButtonsAreUnchanged() throws {
        let field = CGRect(x: 30, y: 300, width: 330, height: 40)
        #expect(try reading([SketchSamples.box(field, radius: 6)]) == .element(.textField))
        let button = CGRect(x: 28, y: 738, width: 337, height: 60)
        #expect(try reading([SketchSamples.box(button, radius: 30)]) == .element(.button))
    }

    @Test func promptsCanNameTheNewControls() {
        let options = [ElementKind.button, .radio, .checkbox, .progress, .textField].map(SketchReading.element)
        #expect(SketchPrompt.reading(namedIn: "a radio button", among: options) == .element(.radio))
        #expect(SketchPrompt.reading(namedIn: "check box for terms", among: options) == .element(.checkbox))
        #expect(SketchPrompt.reading(namedIn: "upload progress bar", among: options) == .element(.progress))
    }
}

@Suite("Laying out sketched elements")
@MainActor
struct SketchedLayoutTests {
    @Test func twoHalfWidthButtonsBecomeTwoColumnsInOneRow() throws {
        let (store, screen) = makeStore()
        let first = try #require(store.addElement(.button, from: CGRect(x: 24, y: 700, width: 160, height: 50), to: screen.id))
        let second = try #require(store.addElement(.button, from: CGRect(x: 210, y: 704, width: 160, height: 46), to: screen.id))
        #expect(first.frame == CGRect(x: 20, y: 700, width: 170, height: 50))
        #expect(second.frame == CGRect(x: 203, y: 700, width: 170, height: 50))
        // The second button on a screen is outlined.
        #expect(first.resolvedButtonLook == .filled)
        #expect(second.buttonLook == .bordered)
    }

    @Test func aWideSketchStillRunsAcross() {
        let frame = ElementLayout.sketched(.button, sketch: CGRect(x: 20, y: 700, width: 340, height: 50)).frame
        #expect(frame.width == 353)
    }

    @Test func textDrawnAgainstTheLeadingEdgeIsLeadingAligned() {
        let (frame, alignment) = ElementLayout.sketched(.title, sketch: CGRect(x: 24, y: 120, width: 110, height: 36))
        #expect(frame == CGRect(x: 20, y: 120, width: 353, height: 40))
        #expect(alignment == .leading)
        // Drawn in the middle, it stays centred.
        #expect(ElementLayout.sketched(.title, sketch: CGRect(x: 150, y: 112, width: 96, height: 40)).alignment == nil)
    }

    @Test func aTallerTitleSketchIsALargerTitle() {
        #expect(ElementLayout.sketched(.title, sketch: CGRect(x: 150, y: 112, width: 96, height: 24)).frame.height == 32)
        #expect(ElementLayout.sketched(.title, sketch: CGRect(x: 150, y: 112, width: 96, height: 64)).frame.height == 48)
    }

    @Test func textBesideACheckboxStartsAfterIt() {
        let checkbox = ElementLayout.sketched(.checkbox, sketch: CGRect(x: 24, y: 300, width: 26, height: 26)).frame
        let (label, alignment) = ElementLayout.sketched(.body, sketch: CGRect(x: 64, y: 296, width: 200, height: 30), among: [checkbox])
        #expect(label.minX == checkbox.maxX + ElementLayout.gutter)
        #expect(label.maxX == DeviceFrame.iPhone.size.width - ElementLayout.margin)
        #expect(label.midY == checkbox.midY)
        #expect(alignment == .leading)
    }

    @Test func theGapToTheElementAboveIsTidied() {
        let title = CGRect(x: 82.5, y: 110, width: 228, height: 40)
        let body = ElementLayout.sketched(.body, sketch: CGRect(x: 48, y: 175, width: 297, height: 30), among: [title]).frame
        #expect(body.minY - title.maxY == 16)
    }
}

@Suite("Code for the new controls")
struct NewControlCodeTests {
    private func screen(_ elements: [DesignElement]) -> DesignScreen {
        DesignScreen(name: "Screen 1", origin: .zero, scale: 1, elements: elements)
    }

    @Test func buttonsSideBySideBecomeAHorizontalStack() {
        var cancel = DesignElement(kind: .button, frame: CGRect(x: 203, y: 700, width: 170, height: 50), text: "Cancel", tint: Theme.accent)
        cancel.buttonLook = .bordered
        let done = DesignElement(kind: .button, frame: CGRect(x: 20, y: 700, width: 170, height: 50), text: "Done", tint: Theme.accent)
        let code = SwiftUICodeGenerator.code(for: screen([cancel, done]), settings: CodeSettings(includesPreview: false))
        #expect(code.contains("HStack(alignment: .center, spacing: 13) {"))
        #expect(code.range(of: "Done")!.lowerBound < code.range(of: "Cancel")!.lowerBound, "leading first")
        #expect(code.contains(".strokeBorder("))
    }

    @Test func checkboxesRadioButtonsAndProgressBarsHaveCode() {
        var radio = DesignElement(kind: .radio, frame: CGRect(x: 20, y: 200, width: 24, height: 24), text: "", tint: Theme.accent)
        radio.isOn = false
        var progress = DesignElement(kind: .progress, frame: CGRect(x: 20, y: 300, width: 353, height: 6), text: "", tint: Theme.accent)
        progress.value = 0.25
        let checkbox = DesignElement(kind: .checkbox, frame: CGRect(x: 20, y: 100, width: 24, height: 24), text: "", tint: Theme.accent)
        let code = SwiftUICodeGenerator.code(for: screen([checkbox, radio, progress]))
        #expect(code.contains("Image(systemName: \"checkmark.square.fill\")"))
        #expect(code.contains("Image(systemName: \"circle\")"))
        #expect(code.contains("ProgressView(value: 0.25)"))
    }
}
