import CoreGraphics
import Foundation
import Testing
@testable import Layer

// What the app works out from an element's kind alone, written out for every kind and
// compared with a record kept in `Goldens/ComponentKinds.txt`. The record was made from
// the per-kind switches the component catalogue replaced, so the catalogue can't drift
// from what they answered without this saying so.
//
// When a kind is changed on purpose, or one is added, make the record again by running
// this suite with the environment variable TEST_RUNNER_LAYER_RECORD_KINDS set to a path
// on this Mac, then replace `Goldens/ComponentKinds.txt` with the file written there.

private func n(_ value: CGFloat) -> String {
    let rounded = (Double(value) * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

private func s(_ size: CGSize) -> String { "\(n(size.width))x\(n(size.height))" }
private func r(_ rect: CGRect) -> String { "\(n(rect.minX)),\(n(rect.minY)) \(s(rect.size))" }
private func c(_ colour: RGBColor) -> String { colour.hex }

/// Sketches of several shapes and places, to bring out each kind's layout rules.
private let sketches: [(name: String, rect: CGRect)] = [
    ("wide", CGRect(x: 20, y: 700, width: 340, height: 50)),
    ("half-left", CGRect(x: 24, y: 400, width: 160, height: 50)),
    ("narrow-right", CGRect(x: 290, y: 300, width: 70, height: 30)),
    ("small-centre", CGRect(x: 170, y: 200, width: 52, height: 52)),
    ("leading-text", CGRect(x: 24, y: 120, width: 110, height: 36)),
    ("tall", CGRect(x: 60, y: 186, width: 280, height: 364)),
    ("short-title", CGRect(x: 150, y: 112, width: 96, height: 24)),
    ("big-title", CGRect(x: 150, y: 112, width: 96, height: 64)),
]

/// Frames already on the screen when the sketches above are laid out among others.
private let neighbours = [
    CGRect(x: 20, y: 300, width: 24, height: 24),
    CGRect(x: 82.5, y: 60, width: 228, height: 40),
]

@MainActor
private func describe(_ kind: ElementKind) throws -> [String] {
    var lines = ["## \(kind.rawValue)"]
    lines.append("name: \(kind.layerName) | symbol: \(kind.symbol) | placeholder: \(kind.placeholder)")
    lines.append("hasText: \(kind.hasText) | belongsOnScreens: \(kind.belongsOnScreens) | prompt: \(SketchPrompt.name(for: .element(kind)))")
    let words = ScreenBlueprint.kindWords.first { $0.kind == kind }?.words ?? []
    lines.append("written as: \(words.joined(separator: ", "))")
    lines.append("found by each of its written names: \(words.allSatisfy { ScreenBlueprint.kind(named: $0) == kind })")

    // Size and placement.
    lines.append("size: \(s(ElementLayout.size(for: kind, sketch: .zero)))"
        + " | sketched small: \(s(ElementLayout.size(for: kind, sketch: CGRect(x: 0, y: 0, width: 20, height: 20))))"
        + " | sketched large: \(s(ElementLayout.size(for: kind, sketch: CGRect(x: 0, y: 0, width: 900, height: 900))))"
        + " | sketched 90x300: \(s(ElementLayout.size(for: kind, sketch: CGRect(x: 0, y: 0, width: 90, height: 300))))")
    lines.append("keepsSketchedPosition: \(ElementLayout.keepsSketchedPosition(kind)) | runsAcross: \(ElementLayout.runsAcross(kind))")
    for sketch in sketches {
        let phone = ElementLayout.sketched(kind, sketch: sketch.rect)
        let among = ElementLayout.sketched(kind, sketch: sketch.rect, among: neighbours)
        let pad = ElementLayout.sketched(kind, sketch: sketch.rect, on: DeviceFrame.named("ipad"))
        lines.append("sketched \(sketch.name): \(r(phone.frame)) \(phone.alignment?.rawValue ?? "-")"
            + " | among others: \(r(among.frame)) \(among.alignment?.rawValue ?? "-")"
            + " | on iPad: \(r(pad.frame)) \(pad.alignment?.rawValue ?? "-")")
    }
    let box = CGRect(x: 40, y: 40, width: 100, height: 60)
    lines.append("resized to nothing: \(r(ElementLayout.resized(box, from: .bottomRight, by: CGSize(width: -500, height: -500), kind: kind)))"
        + " | resized taller: \(r(ElementLayout.resized(box, from: .topLeft, by: CGSize(width: -10, height: -30), kind: kind)))"
        + " | keeping shape: \(r(ElementLayout.resizedKeepingShape(box, from: .bottomRight, by: CGSize(width: 20, height: 5), kind: kind)))"
        + " | keeping shape from top left: \(r(ElementLayout.resizedKeepingShape(box, from: .topLeft, by: CGSize(width: -20, height: -5), kind: kind)))")

    // A new one, and its usual look.
    let new = DesignStore.newElement(kind)
    lines.append("new: \(s(new.frame.size)) tint \(c(new.tint)) text \"\(new.text)\"")
    var element = new
    element.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
    var outlined = element
    outlined.buttonLook = .bordered
    lines.append("font: \(n(element.resolvedFontSize)) \(element.resolvedFontWeight.rawValue)"
        + " | text colour: \(c(element.resolvedTextColor)), bordered \(c(outlined.resolvedTextColor))"
        + " | radius: \(n(element.resolvedCornerRadius)) | alignment: \(element.resolvedTextAlignment.rawValue)")
    lines.append("hasFill: \(element.hasFill) | hasCornerRadius: \(element.hasCornerRadius) | hasBorder: \(element.hasBorder)"
        + " | hasOnState: \(element.hasOnState) | hasTextAlignment: \(element.hasTextAlignment)")

    // On the open canvas, drawn large and drawn small.
    let store = DesignStore(content: DesignContent())
    let large = store.resolve(store.addFloating(kind, from: CGRect(x: 0, y: 0, width: 300, height: 200)))
    let small = store.resolve(store.addFloating(kind, from: CGRect(x: 0, y: 0, width: 30, height: 20)))
    lines.append("loose, drawn large: \(s(large?.element.frame.size ?? .zero)) | drawn small: \(s(small?.element.frame.size ?? .zero))")

    // In a written or generated screen.
    let item = ScreenBlueprint.Item(kind: kind, text: "")
    var sized = item
    sized.fontSize = 40
    lines.append("in a blueprint: \(s(ScreenBlueprint.size(of: item, available: 353, on: .iPhone)))"
        + " | in a row: \(s(ScreenBlueprint.size(of: item, available: 170, on: .iPhone, inRow: true)))"
        + " | at 40pt: \(s(ScreenBlueprint.size(of: sized, available: 353, on: .iPhone)))")
    let laid = try #require(ScreenBlueprint(sections: [.init(items: [item])]).layout(on: .iPhone).first)
    lines.append("laid out: \(r(laid.frame)) alignment \(laid.textAlignment?.rawValue ?? "-")")

    // What the marks inside a sketch say.
    func marked(_ inner: SketchObservation.InnerMark, at bounds: CGRect?) -> String {
        var element = DesignStore.newElement(kind)
        element.adoptMarks(of: SketchObservation(
            bounds: CGRect(x: 0, y: 0, width: 60, height: 30), form: .enclosure(roundness: 0.5, inner: inner), strokeCount: 2, innerBounds: bounds
        ))
        return "on \(element.isOn) value \(element.value.map { n(CGFloat($0)) } ?? "-")"
    }
    lines.append("marks: empty \(marked(.none, at: nil)) | dot on the right \(marked(.dot, at: CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.6)))"
        + " | shaded to 0.42 \(marked(.other, at: CGRect(x: 0, y: 0, width: 0.42, height: 1)))")

    // What a design's layout, written out as data, says of it.
    var content = DesignContent()
    content.screens = [DesignScreen(name: "Screen 1", origin: .zero, scale: 1, elements: [new])]
    let json = DesignLayoutWriter.json(for: DesignSnapshot(id: "design", name: "Design", content: content, modified: nil))
    let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let screens = try #require(root["screens"] as? [[String: Any]])
    let written = try #require((screens.first?["elements"] as? [[String: Any]])?.first)
    lines.append("layout data: \(written.keys.filter { $0 != "id" }.sorted().joined(separator: ", "))")
    return lines
}

@MainActor
private func describeEveryKind() throws -> String {
    var lines: [String] = []
    for kind in ElementKind.allCases {
        lines += try describe(kind)
        lines.append("")
    }
    // What a drawing can be asked to become, in the order it is offered.
    let observation = SketchObservation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), form: .scribble, strokeCount: 1)
    for (name, placement) in [("on a screen", SketchPlacement.onScreen(local: CGRect(x: 0, y: 0, width: 10, height: 10), existing: [])), ("on the open canvas", .openCanvas)] {
        let asked = SketchRequest(observation: observation, placement: placement, strokes: [], prompt: "")
        lines.append("asked for \(name): \(asked.askedCandidates.map(SketchPrompt.name(for:)).joined(separator: ", "))")
    }
    return lines.joined(separator: "\n") + "\n"
}

private final class BundleMarker {}

@Suite("The component catalogue")
@MainActor
struct ComponentCatalogueTests {
    @Test func everyKindAnswersAsItsRecordSays() throws {
        let described = try describeEveryKind()
        if let path = ProcessInfo.processInfo.environment["LAYER_RECORD_KINDS"] {
            try described.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "ComponentKinds", withExtension: "txt"))
        let recorded = try String(contentsOf: url, encoding: .utf8)
        let (now, then) = (described.components(separatedBy: "\n"), recorded.components(separatedBy: "\n"))
        #expect(now.count == then.count)
        // Line by line, so that a difference names the kind and the property.
        var kind = ""
        for (line, expected) in zip(now, then) {
            if line.hasPrefix("## ") { kind = String(line.dropFirst(3)) }
            #expect(line == expected, "\(kind)")
        }
    }

    @Test func theKindsOfferedToShortcutsAreTheKindsThereAre() {
        #expect(Set(ElementKindChoice.allCases.map(\.rawValue)) == Set(ElementKind.allCases.map(\.rawValue)))
        for kind in ElementKind.allCases {
            #expect(ElementKindChoice(kind).element == kind)
            #expect(ElementKindChoice.caseDisplayRepresentations[ElementKindChoice(kind)] != nil)
        }
    }
}
