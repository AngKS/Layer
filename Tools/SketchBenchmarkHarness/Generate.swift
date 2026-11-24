// Builds the labelled sketch fixture corpus from the same stroke generators
// `LayerTests/SketchReadingTests.swift` and `LayerTests/MagicPenComponentTests.swift` use
// (`SketchSamples`), plus a seeded jitter on top for the noisy/hand-jittered variants.
// Run with `generate` to (re)write `LayerTests/Fixtures/*.json`. Deterministic: every run
// produces byte-identical files, since every random amount is seeded.
import CoreGraphics
import Foundation

private let iPhone = CGSize(width: 393, height: 852)

private func existing(_ kind: ElementKind, _ rect: CGRect) -> SketchFixture.ExistingFixture {
    .init(kind: kind, frame: [rect.minX, rect.minY, rect.width, rect.height])
}

private func fixture(
    _ id: String, label: String, variant: SketchFixture.Variant, pair: String? = nil,
    onScreen rects: [SketchFixture.ExistingFixture] = [], strokes paths: [[CGPoint]]
) -> SketchFixture {
    SketchFixture(
        id: id, label: label, variant: variant, pair: pair, placementKind: .onScreen,
        existing: rects, screenSize: [iPhone.width, iPhone.height],
        strokes: paths.map { $0.map { [$0.x, $0.y] } }
    )
}

private func fixture(
    _ id: String, label: String, variant: SketchFixture.Variant, pair: String? = nil,
    openCanvas paths: [[CGPoint]]
) -> SketchFixture {
    SketchFixture(
        id: id, label: label, variant: variant, pair: pair, placementKind: .openCanvas,
        existing: [], screenSize: nil, strokes: paths.map { $0.map { [$0.x, $0.y] } }
    )
}

/// A zigzag scrubbed back and forth across `rect`, as drawn to cross something out. Mirrors
/// the private helper of the same name in `LayerTests/FreeformTests.swift`.
private func scratchZigzag(_ rect: CGRect, passes: Int = 6) -> [CGPoint] {
    var points: [CGPoint] = []
    for pass in 0...passes {
        let y = rect.minY + rect.height * CGFloat(pass) / CGFloat(passes)
        let fromLeft = pass.isMultiple(of: 2)
        for step in 0...20 {
            let t = CGFloat(step) / 20
            points.append(CGPoint(x: fromLeft ? rect.minX + rect.width * t : rect.maxX - rect.width * t, y: y + t * 4))
        }
    }
    return points
}

/// `base`, jittered by a seeded random amount, as a fixture of the given id and variant.
private func noisy(_ id: String, label: String, variant: SketchFixture.Variant, seed: UInt64, amount: CGFloat, of base: SketchFixture) -> SketchFixture {
    var copy = base
    copy.id = id
    copy.variant = variant
    let jitteredPaths = base.strokePaths.seededJitter(amount: amount, seed: seed)
    copy.strokes = jitteredPaths.map { $0.map { [$0.x, $0.y] } }
    return copy
}

/// Templates for `GlyphMatcher`, the $P point-cloud recognizer (`magic-pen-expansion.md`
/// §3B). A handful of examples per glyph, reusing the same stroke generators as the fixture
/// corpus, at varied sizes and positions so the matcher learns the shape, not one example's
/// incidental scale or placement — $P normalises for scale and position itself, but seeing
/// that variety in the templates is cheap insurance.
enum GlyphTemplateGenerator {
    static func all() -> [GlyphExample] {
        var out: [GlyphExample] = []

        func add(_ glyph: String, _ strokes: [[CGPoint]]) {
            out.append(GlyphExample(glyph: glyph, strokes: strokes.map { $0.map { [$0.x, $0.y] } }))
        }

        // Circle: distinguishes a radio button or avatar from a checkbox once the outer
        // outline itself fails to parse as a clean enclosure (see GlyphMatcher's use in
        // ComponentRule as a fallback when jitter breaks `SketchAnalyzer`'s own check).
        for (center, radius) in [(CGPoint(x: 0, y: 0), 15.0), (CGPoint(x: 50, y: 30), 22.0), (CGPoint(x: -20, y: 10), 10.0)] {
            add("circle", [SketchSamples.circle(center: center, radius: radius)])
        }

        // Square: the sharp-cornered counterpart, for a checkbox.
        for (rect, radius) in [
            (CGRect(x: -14, y: -14, width: 28, height: 28), 3.0),
            (CGRect(x: 10, y: 10, width: 24, height: 24), 2.0),
            (CGRect(x: -16, y: 0, width: 32, height: 32), 4.0),
        ] {
            add("square", [SketchSamples.box(rect, radius: radius)])
        }

        // Tick: a checkbox's mark.
        for rect in [CGRect(x: 0, y: 0, width: 30, height: 30), CGRect(x: 10, y: 10, width: 24, height: 24)] {
            add("tick", [SketchSamples.tick(rect)])
        }

        // Cross: an image's mark, or a delete/close glyph.
        for rect in [CGRect(x: 0, y: 0, width: 30, height: 30), CGRect(x: 10, y: 10, width: 22, height: 22)] {
            add("cross", SketchSamples.cross(rect))
        }

        // Dot: a radio button's selected mark, or a page indicator.
        for (center, radius) in [(CGPoint(x: 0, y: 0), 4.0), (CGPoint(x: 5, y: -5), 3.0)] {
            add("dot", [SketchSamples.circle(center: center, radius: radius)])
        }

        // Plus: an add button or a stepper's increment, axis-aligned unlike the cross.
        for half in [12.0, 16.0] {
            add("plus", [
                SketchSamples.straight(from: CGPoint(x: -half, y: 0), to: CGPoint(x: half, y: 0)),
                SketchSamples.straight(from: CGPoint(x: 0, y: -half), to: CGPoint(x: 0, y: half)),
            ])
        }

        return out
    }
}

enum FixtureGenerator {
    /// Every fixture in the starter corpus: clean, jittered and noisy examples of every
    /// sketchable kind, and deliberately confusable pairs.
    static func all() -> [SketchFixture] {
        var out: [SketchFixture] = []
        var seed: UInt64 = 1

        func addVariants(_ baseID: String, label: String, pair: String? = nil, _ clean: [SketchFixture]) {
            for (index, base) in clean.enumerated() {
                var tagged = base
                tagged.id = "\(baseID)_clean_\(index + 1)"
                tagged.pair = pair
                out.append(tagged)
                seed += 1
                out.append(noisy("\(baseID)_jittered_\(index + 1)a", label: label, variant: .jittered, seed: seed, amount: 1.5, of: tagged))
                seed += 1
                out.append(noisy("\(baseID)_jittered_\(index + 1)b", label: label, variant: .jittered, seed: seed, amount: 1.5, of: tagged))
                seed += 1
                out.append(noisy("\(baseID)_noisy_\(index + 1)", label: label, variant: .noisy, seed: seed, amount: 4.5, of: tagged))
            }
        }

        // MARK: Title

        addVariants("title", label: "title", [
            fixture("title", label: "title", variant: .clean, onScreen: [], strokes: [SketchSamples.wave(CGRect(x: 150, y: 112, width: 96, height: 40), humps: 3)]),
            fixture("title", label: "title", variant: .clean, onScreen: [], strokes: [SketchSamples.wave(CGRect(x: 40, y: 160, width: 110, height: 34), humps: 3)]),
        ])

        // MARK: Body (a long squiggle is unambiguously body regardless of context)

        addVariants("body", label: "body", [
            fixture("body", label: "body", variant: .clean, strokes: [SketchSamples.wave(CGRect(x: 52, y: 588, width: 290, height: 28), humps: 8)]),
            fixture("body", label: "body", variant: .clean, strokes: [SketchSamples.wave(CGRect(x: 40, y: 650, width: 330, height: 30), humps: 10)]),
        ])

        // MARK: Image (crossed box; always unambiguous, any size)

        addVariants("image", label: "image", [
            fixture("image", label: "image", variant: .clean, onScreen: [], strokes: [SketchSamples.box(CGRect(x: 34, y: 186, width: 326, height: 364), radius: 44)] + SketchSamples.cross(CGRect(x: 34, y: 186, width: 326, height: 364))),
            fixture("image", label: "image", variant: .clean, onScreen: [], strokes: [SketchSamples.box(CGRect(x: 40, y: 450, width: 200, height: 260), radius: 30)] + SketchSamples.cross(CGRect(x: 40, y: 450, width: 200, height: 260))),
        ])

        // MARK: Button (wide pill, roundness and ratio both decisive)

        addVariants("button", label: "button", [
            fixture("button", label: "button", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 28, y: 738, width: 337, height: 60), radius: 30)]),
            fixture("button", label: "button", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 30, y: 650, width: 320, height: 54), radius: 27)]),
        ])

        // MARK: Text field (wide, squarish corners)

        addVariants("textField", label: "textField", [
            fixture("textField", label: "textField", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 30, y: 400, width: 330, height: 50), radius: 2)]),
            fixture("textField", label: "textField", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 30, y: 200, width: 330, height: 44), radius: 3)]),
        ])

        // MARK: Divider (a single straight line)

        addVariants("divider", label: "divider", [
            fixture("divider", label: "divider", variant: .clean, strokes: [SketchSamples.straight(from: CGPoint(x: 30, y: 500), to: CGPoint(x: 360, y: 502))]),
            fixture("divider", label: "divider", variant: .clean, strokes: [SketchSamples.straight(from: CGPoint(x: 40, y: 650), to: CGPoint(x: 350, y: 651))]),
        ])

        // MARK: Toggle (small pill, end knob)

        addVariants("toggle", label: "toggle", [
            fixture("toggle", label: "toggle", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 300, y: 300, width: 64, height: 30), radius: 15), SketchSamples.circle(center: CGPoint(x: 349, y: 315), radius: 11)]),
            fixture("toggle", label: "toggle", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 50, y: 500, width: 70, height: 32), radius: 16), SketchSamples.circle(center: CGPoint(x: 66, y: 516), radius: 11)]),
        ])

        // MARK: Avatar (a circle too big to be a checkbox or radio button)

        addVariants("avatar", label: "avatar", [
            fixture("avatar", label: "avatar", variant: .clean, strokes: [SketchSamples.circle(center: CGPoint(x: 60, y: 160), radius: 35)]),
            fixture("avatar", label: "avatar", variant: .clean, strokes: [SketchSamples.circle(center: CGPoint(x: 300, y: 700), radius: 40)]),
        ])

        // MARK: Checkbox (tiny sharp-cornered square)

        addVariants("checkbox", label: "checkbox", [
            fixture("checkbox", label: "checkbox", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 40, y: 300, width: 30, height: 30), radius: 4), SketchSamples.tick(CGRect(x: 40, y: 300, width: 30, height: 30))]),
            fixture("checkbox", label: "checkbox", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 300, y: 500, width: 28, height: 28), radius: 3)]),
        ])

        // MARK: Radio (tiny circle, empty or dotted)

        addVariants("radio", label: "radio", [
            fixture("radio", label: "radio", variant: .clean, strokes: [SketchSamples.circle(center: CGPoint(x: 55, y: 315), radius: 15), SketchSamples.circle(center: CGPoint(x: 55, y: 315), radius: 4)]),
            fixture("radio", label: "radio", variant: .clean, strokes: [SketchSamples.circle(center: CGPoint(x: 55, y: 315), radius: 12)]),
        ])

        // MARK: Progress (very long, thin outline)

        addVariants("progress", label: "progress", [
            fixture("progress", label: "progress", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 40, y: 400, width: 300, height: 22), radius: 4)]),
            fixture("progress", label: "progress", variant: .clean, strokes: [SketchSamples.box(CGRect(x: 30, y: 300, width: 320, height: 20), radius: 3)]),
        ])

        // MARK: Screen (tall box on the open canvas)

        addVariants("screen", label: "screen", [
            fixture("screen", label: "screen", variant: .clean, openCanvas: [SketchSamples.box(CGRect(x: 400, y: 100, width: 270, height: 584), radius: 26)]),
            fixture("screen", label: "screen", variant: .clean, openCanvas: [SketchSamples.box(CGRect(x: 100, y: 50, width: 240, height: 500), radius: 20)]),
        ])

        // MARK: Sticky note (roughly square box on the open canvas)

        addVariants("stickyNote", label: "stickyNote", [
            fixture("stickyNote", label: "stickyNote", variant: .clean, openCanvas: [SketchSamples.box(CGRect(x: 500, y: 500, width: 80, height: 80), radius: 8)]),
            fixture("stickyNote", label: "stickyNote", variant: .clean, openCanvas: [SketchSamples.box(CGRect(x: 600, y: 200, width: 90, height: 70), radius: 6)]),
        ])

        // MARK: Text (squiggle on the open canvas)

        addVariants("text", label: "text", [
            fixture("text", label: "text", variant: .clean, openCanvas: [SketchSamples.wave(CGRect(x: 100, y: 100, width: 120, height: 20), humps: 4)]),
            fixture("text", label: "text", variant: .clean, openCanvas: [SketchSamples.wave(CGRect(x: 500, y: 400, width: 150, height: 18), humps: 5)]),
        ])

        // MARK: Unknown (a stray stroke, too small or shapeless to mean anything)

        addVariants("unknown", label: "unknown", [
            fixture("unknown", label: "unknown", variant: .clean, openCanvas: [SketchSamples.straight(from: CGPoint(x: 380, y: 300), to: CGPoint(x: 460, y: 330))]),
            fixture("unknown", label: "unknown", variant: .clean, openCanvas: [SketchSamples.straight(from: CGPoint(x: 200, y: 600), to: CGPoint(x: 260, y: 560))]),
        ])

        // MARK: Scratch-out (a zigzag, on screen or on the canvas)

        addVariants("scratchOut", label: "scratchOut", [
            fixture("scratchOut", label: "scratchOut", variant: .clean, onScreen: [existing(.title, CGRect(x: 82.5, y: 112, width: 228, height: 40))], strokes: [scratchZigzag(CGRect(x: 150, y: 110, width: 100, height: 40))]),
            fixture("scratchOut", label: "scratchOut", variant: .clean, onScreen: [], strokes: [scratchZigzag(CGRect(x: 100, y: 740, width: 200, height: 60))]),
        ])

        // MARK: Confusable pairs
        //
        // Each pair shares near-identical, deliberately ambiguous geometry; the label is
        // what the sketch was *meant* to be, not what its shape alone settles. "card" and
        // "slider" aren't sketchable kinds yet (`magic-pen-expansion.md` §2), so the
        // "card vs image" and "toggle vs slider" pairs from the brief are approximated with
        // the closest ambiguity the current rules actually have: a box in the wide band
        // that could be an image or a text field, and a long thin outline that could be a
        // toggle or a progress bar depending on where it falls relative to the rules'
        // ratio-7 progress-bar cutoff.

        func pairVariants(_ baseID: String, pair: String, _ labelled: [(String, SketchFixture)]) {
            for (index, (label, base)) in labelled.enumerated() {
                var tagged = base
                tagged.id = "\(baseID)_\(label)_\(index + 1)"
                tagged.label = label
                tagged.variant = .confusable
                tagged.pair = pair
                out.append(tagged)
            }
        }

        // button vs textField: a wide box whose corners are rounder than a field's and
        // squarer than a pill's (the exact shape `SketchReadingTests` calls a close call).
        func roundedWideBox(at y: CGFloat, width: CGFloat = 330) -> SketchFixture {
            let rect = CGRect(x: 30, y: y, width: width, height: 56)
            return fixture("x", label: "x", variant: .confusable, strokes: [SketchSamples.box(rect, radius: rect.height * 0.22)])
        }
        pairVariants("button_textField", pair: "button-textField", [
            ("button", roundedWideBox(at: 740)), ("button", roundedWideBox(at: 650, width: 320)),
            ("textField", roundedWideBox(at: 400)), ("textField", roundedWideBox(at: 300, width: 340)),
        ])

        // image vs textField: a box in the wide band, roundness low enough that both are
        // offered (substitutes for "card vs image"; card doesn't exist as a kind yet).
        func wideBoxyBox(at y: CGFloat, width: CGFloat = 320, height: CGFloat = 175) -> SketchFixture {
            fixture("x", label: "x", variant: .confusable, strokes: [SketchSamples.box(CGRect(x: 40, y: y, width: width, height: height), radius: 6)])
        }
        pairVariants("image_textField", pair: "image-textField", [
            ("image", wideBoxyBox(at: 200)), ("image", wideBoxyBox(at: 400, width: 300, height: 165)),
            ("textField", wideBoxyBox(at: 600, width: 330, height: 180)), ("textField", wideBoxyBox(at: 80, width: 310, height: 170)),
        ])

        // checkbox vs radio: the same tiny size, varying only how rounded the corners are.
        func tinyRoundedSquare(radius: CGFloat, at origin: CGPoint) -> SketchFixture {
            fixture("x", label: "x", variant: .confusable, strokes: [SketchSamples.box(CGRect(x: origin.x, y: origin.y, width: 28, height: 28), radius: radius)])
        }
        pairVariants("checkbox_radio", pair: "checkbox-radio", [
            ("checkbox", tinyRoundedSquare(radius: 3, at: CGPoint(x: 40, y: 300))), ("checkbox", tinyRoundedSquare(radius: 5, at: CGPoint(x: 300, y: 500))),
            ("radio", tinyRoundedSquare(radius: 13, at: CGPoint(x: 40, y: 400))), ("radio", tinyRoundedSquare(radius: 14, at: CGPoint(x: 300, y: 600))),
        ])

        // checkbox vs image: a tiny crossed shape, sharp (checkbox) or round (image) per
        // `SketchRequest.smallControl`, which checks roundness before the cross.
        func tinyCrossedShape(radius: CGFloat, at origin: CGPoint) -> SketchFixture {
            let rect = CGRect(x: origin.x, y: origin.y, width: 28, height: 28)
            return fixture("x", label: "x", variant: .confusable, strokes: [SketchSamples.box(rect, radius: radius)] + SketchSamples.cross(rect))
        }
        pairVariants("checkbox_image", pair: "checkbox-image", [
            ("checkbox", tinyCrossedShape(radius: 3, at: CGPoint(x: 40, y: 300))), ("checkbox", tinyCrossedShape(radius: 4, at: CGPoint(x: 300, y: 500))),
            ("image", tinyCrossedShape(radius: 13, at: CGPoint(x: 40, y: 400))), ("image", tinyCrossedShape(radius: 14, at: CGPoint(x: 300, y: 600))),
        ])

        // radio vs avatar: an empty circle right at the radio/avatar size cutoff.
        func tinyCircle(radius: CGFloat, at center: CGPoint) -> SketchFixture {
            fixture("x", label: "x", variant: .confusable, strokes: [SketchSamples.circle(center: center, radius: radius)])
        }
        pairVariants("radio_avatar", pair: "radio-avatar", [
            ("radio", tinyCircle(radius: 14, at: CGPoint(x: 55, y: 315))), ("radio", tinyCircle(radius: 15, at: CGPoint(x: 300, y: 500))),
            ("avatar", tinyCircle(radius: 17, at: CGPoint(x: 55, y: 400))), ("avatar", tinyCircle(radius: 18, at: CGPoint(x: 300, y: 600))),
        ])

        // title vs body: a squiggle inside the width band where the rules' own threshold
        // and what a person meant can disagree.
        func bandedWave(widthFraction: CGFloat, at y: CGFloat) -> SketchFixture {
            let width = iPhone.width * widthFraction
            let rect = CGRect(x: (iPhone.width - width) / 2, y: y, width: width, height: 30)
            return fixture("x", label: "x", variant: .confusable, strokes: [SketchSamples.wave(rect, humps: 4)])
        }
        pairVariants("title_body", pair: "title-body", [
            ("title", bandedWave(widthFraction: 0.40, at: 120)), ("title", bandedWave(widthFraction: 0.38, at: 300)),
            ("body", bandedWave(widthFraction: 0.50, at: 150)), ("body", bandedWave(widthFraction: 0.52, at: 320)),
        ])

        // toggle vs progress: the current rules have no shared boundary between these two
        // (toggle needs a ratio of 1.34-3, progress needs 7+), so both ends of this pair
        // actually land on a third answer (textField) today — a real gap the rules leave
        // for Stage 1's scoring to close, not an artefact of this fixture set.
        func longPill(ratio: CGFloat, height: CGFloat, at y: CGFloat) -> SketchFixture {
            let width = ratio * height
            let rect = CGRect(x: (iPhone.width - width) / 2, y: y, width: width, height: height)
            return fixture("x", label: "x", variant: .confusable, strokes: [SketchSamples.box(rect, radius: height / 2)])
        }
        pairVariants("toggle_progress", pair: "toggle-progress", [
            ("toggle", longPill(ratio: 4, height: 26, at: 300)), ("toggle", longPill(ratio: 4.5, height: 24, at: 500)),
            ("progress", longPill(ratio: 9, height: 22, at: 400)), ("progress", longPill(ratio: 9.5, height: 20, at: 600)),
        ])

        return out
    }
}

// MARK: Structure fixtures

/// The structure pass's fixtures (plan 5 Task 8), in the corpus's style: things on the screen, then one batch of sketches
/// drawn with `SketchSamples`' strokes, each base clean, then jittered or noisy by a seeded amount. The counts per
/// variant are fixed: rows 3/3/2, columns 2/2/2, grids 2/2/2, cards 2/1/1, and eight near misses.
enum StructureFixtureGenerator {
    private typealias Sketch = [[CGPoint]]

    private struct Base {
        var existing: [SketchFixture.ExistingFixture] = []
        var sketches: [Sketch]
        var label: String
        var expected: String
    }

    private static func thing(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                              locked: Bool? = nil) -> SketchFixture.ExistingFixture {
        .init(kind: kind, frame: [x, y, width, height], locked: locked)
    }

    private static func image(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Sketch {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        return [SketchSamples.box(rect, radius: 12)] + SketchSamples.cross(rect)
    }

    private static func field(_ x: CGFloat, _ y: CGFloat) -> Sketch {
        [SketchSamples.box(CGRect(x: x, y: y, width: 330, height: 44), radius: 2)]
    }

    private static func line(_ x: CGFloat, _ y: CGFloat, width: CGFloat = 290) -> Sketch {
        [SketchSamples.wave(CGRect(x: x, y: y, width: width, height: 28), humps: 8)]
    }

    private static func avatar(_ x: CGFloat, _ y: CGFloat) -> Sketch {
        [SketchSamples.circle(center: CGPoint(x: x, y: y), radius: 30)]
    }

    private static func toggle(_ x: CGFloat, _ y: CGFloat) -> Sketch {
        [SketchSamples.box(CGRect(x: x, y: y, width: 64, height: 30), radius: 15),
         SketchSamples.circle(center: CGPoint(x: x + 49, y: y + 15), radius: 11)]
    }

    private static func outline(_ rect: CGRect) -> Sketch {
        [SketchSamples.box(rect, radius: 16)]
    }

    private static func structureFixture(_ id: String, _ variant: StructureFixture.Variant, _ base: Base,
                                         jitter: CGFloat = 0, seed: UInt64 = 0) -> StructureFixture {
        let sketches = base.sketches.enumerated().map { index, paths in
            jitter == 0 ? paths : paths.seededJitter(amount: jitter, seed: seed &+ UInt64(index))
        }
        return StructureFixture(
            id: "structure-\(id)", label: base.label, variant: variant,
            screenSize: [iPhone.width, iPhone.height], existing: base.existing,
            sketches: sketches.map { $0.map { $0.map { [$0.x, $0.y] } } }, expected: base.expected
        )
    }

    static func all() -> [StructureFixture] {
        var out: [StructureFixture] = []
        var seed: UInt64 = 1000

        func add(_ name: String, _ bases: [Base], jittered: [Int], noisy: [Int]) {
            for (index, base) in bases.enumerated() {
                out.append(structureFixture("\(name)_clean_\(index + 1)", .clean, base))
            }
            for index in jittered {
                seed += 10
                out.append(structureFixture("\(name)_jittered_\(index + 1)", .jittered, bases[index], jitter: 1.5, seed: seed))
            }
            for index in noisy {
                seed += 10
                out.append(structureFixture("\(name)_noisy_\(index + 1)", .noisy, bases[index], jitter: 4.5, seed: seed))
            }
        }

        add("row", [
            Base(existing: [thing(.text, 150, 300, 130, 24)], sketches: [toggle(300, 296)], label: "row", expected: "apply"),
            Base(sketches: [image(20, 300, 160, 120), image(200, 300, 160, 120)], label: "row", expected: "apply"),
            Base(sketches: [avatar(100, 330), avatar(180, 330), avatar(260, 330)], label: "row", expected: "apply"),
        ], jittered: [0, 1, 2], noisy: [0, 1])

        add("column", [
            Base(sketches: [field(30, 200), field(30, 264), field(30, 328)], label: "column", expected: "apply"),
            Base(sketches: [line(52, 200), line(52, 278), line(52, 356), line(52, 434)], label: "column", expected: "apply"),
        ], jittered: [0, 1], noisy: [0, 1])

        add("grid", [
            Base(sketches: [image(20, 200, 160, 120), image(200, 200, 160, 120),
                            image(20, 340, 160, 120), image(200, 340, 160, 120)], label: "grid", expected: "apply"),
            Base(sketches: [image(20, 150, 160, 100), image(200, 150, 160, 100), image(20, 270, 160, 100),
                            image(200, 270, 160, 100), image(20, 390, 160, 100), image(200, 390, 160, 100)],
                 label: "grid", expected: "apply"),
        ], jittered: [0, 1], noisy: [0, 1])

        add("card", [
            Base(existing: [thing(.title, 96, 120, 200, 40), thing(.body, 20, 170, 353, 40)],
                 sketches: [outline(CGRect(x: 10, y: 100, width: 373, height: 130))], label: "card", expected: "none"),
            Base(existing: [thing(.text, 30, 120, 300, 24), thing(.text, 30, 156, 300, 24), thing(.text, 30, 192, 300, 24)],
                 sketches: [outline(CGRect(x: 10, y: 100, width: 373, height: 140))], label: "card", expected: "apply"),
        ], jittered: [0], noisy: [1])

        func near(_ name: String, _ base: Base, label: String = "none") {
            var base = base
            base.label = label
            base.expected = "none"
            out.append(structureFixture("near_\(name)", .nearMiss, base))
        }
        near("title_above_button", Base(existing: [thing(.title, 96, 120, 200, 40)],
                                        sketches: [[SketchSamples.box(CGRect(x: 28, y: 280, width: 337, height: 60), radius: 30)]],
                                        label: "", expected: ""))
        near("two_things_40_apart", Base(existing: [thing(.image, 230, 300, 130, 120)],
                                         sketches: [image(20, 300, 140, 120)], label: "", expected: ""))
        near("heights_2_5_apart", Base(existing: [thing(.image, 20, 300, 100, 150)],
                                       sketches: [avatar(162, 375)], label: "", expected: ""))
        near("locked_divider_between_texts", Base(
            existing: [thing(.body, 48, 100, 297, 44), thing(.body, 48, 176, 297, 44), thing(.divider, 48, 252, 297, 1, locked: true)],
            sketches: [[SketchSamples.wave(CGRect(x: 52, y: 293, width: 290, height: 28), humps: 8)]], label: "", expected: ""))
        near("an_L_of_three_images", Base(existing: [thing(.image, 20, 200, 160, 120), thing(.image, 200, 200, 160, 120)],
                                          sketches: [image(20, 340, 160, 120)], label: "", expected: ""))
        near("column_edge_6_off", Base(existing: [thing(.image, 22, 180, 160, 120), thing(.image, 28, 452, 160, 120)],
                                       sketches: [image(22, 316, 160, 120)], label: "", expected: ""))
        near("outline_half_over_a_text", Base(
            existing: [thing(.title, 96, 120, 200, 40), thing(.body, 20, 170, 353, 40), thing(.text, 30, 210, 300, 40)],
            sketches: [outline(CGRect(x: 10, y: 100, width: 373, height: 130))], label: "card", expected: "none"), label: "card")
        near("a_lone_text", Base(sketches: [[SketchSamples.wave(CGRect(x: 100, y: 300, width: 160, height: 24), humps: 6)]],
                                 label: "", expected: ""))
        return out
    }
}
