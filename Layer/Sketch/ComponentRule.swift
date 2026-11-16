import CoreGraphics
import Foundation

/// A scored guess at what a sketch could be: 0 means "not even possible", not just
/// "unlikely", so the eligibility a clear sketch had under the old hand-written `candidates`
/// switch still holds exactly. Where more than one reading is possible, the score is
/// continuous, so two readings can legitimately sit close together or far apart — the
/// signal `isCloseCall` now reads instead of a second, separately hand-written set of
/// conditions. `magic-pen-expansion.md` §3E.
struct ScoredReading: Sendable, Equatable {
    var reading: SketchReading
    var score: Double
}

/// A smooth stand-in for "is `value` past `threshold`": 0 well below it, 1 well above it,
/// 0.5 exactly at it, widening or narrowing the undecided stretch around the threshold with
/// `softness`. Every one of `SketchConventions`' hand-tuned cutoffs becomes one of these,
/// centred on the same value, so a clear sketch — far from the threshold either way — scores
/// just as confidently as the old hard `if` did, and only sketches actually near the
/// threshold compete.
func smoothGate(_ value: Double, softness: Double) -> Double {
    guard softness > 0 else { return value >= 0 ? 1 : 0 }
    return 1 / (1 + exp(-value / softness))
}

/// A smooth stand-in for "is `value` inside `range`": 1 comfortably inside, decaying to 0
/// outside it over `softness` — a squared-exponential falloff, not a sigmoid, so that
/// sitting a couple of `softness` units outside the range reads as genuinely unlikely
/// rather than merely "a bit less likely".
func smoothRange(_ value: Double, range: ClosedRange<Double>, softness: Double) -> Double {
    let distance: Double
    if value < range.lowerBound { distance = range.lowerBound - value }
    else if value > range.upperBound { distance = value - range.upperBound }
    else { return 1 }
    let scaled = distance / max(softness, 1e-6)
    return exp(-scaled * scaled)
}
private func smoothRange(_ value: Double, range: ClosedRange<CGFloat>, softness: Double) -> Double {
    smoothRange(value, range: Double(range.lowerBound)...Double(range.upperBound), softness: softness)
}

extension SketchRequest {
    /// Every reading this sketch could be, scored 0 (not possible) to 1 (certain), ranked
    /// highest first. Replaces the old hand-ordered `candidates` switch: the same shape
    /// gates (an outline only reads as a button within the wide band, a tiny box only
    /// reads as a checkbox below the tiny fraction, and so on) decide what's even eligible,
    /// exactly as before, but a continuous score — not insertion order — now decides how
    /// confidently, and what else was close.
    var scoredReadings: [ScoredReading] {
        if case .scratch = observation.form { return [ScoredReading(reading: .scratchOut, score: 1)] }
        switch placement {
        case .openCanvas:
            // Scored continuously only where the confusable pairs this is measured against
            // actually live: on screens. The open canvas' three kinds (screen, sticky note,
            // text) don't appear in any of them, so they keep the old single-candidate
            // shape, unchanged.
            let bounds = observation.bounds
            switch observation.form {
            case .enclosure(_, .none) where bounds.height >= bounds.width * SketchConventions.tallRatio && bounds.height >= 160:
                return [ScoredReading(reading: .screen, score: 1)]
            case .enclosure where min(bounds.width, bounds.height) >= SketchConventions.noteSide:
                return [ScoredReading(reading: .element(.stickyNote), score: 1)]
            case .wave, .stackedLines:
                return bounds.width >= max(bounds.height, 40) ? [ScoredReading(reading: .element(.text), score: 1)] : []
            default:
                // A recognised word turns otherwise-unreadable ink into text, on the open
                // canvas same as on a screen.
                return recognizedText != nil ? [ScoredReading(reading: .element(.text), score: 1)] : []
            }
        case .onScreen(let local, let existing, let size):
            return Self.onScreenScoredReadings(
                form: observation.form, local: local, existing: existing, size: size, strokes: strokes, recognizedText: recognizedText
            )
        }
    }

    private static func onScreenScoredReadings(
        form: SketchObservation.Form, local: CGRect, existing: [ExistingElement], size: CGSize, strokes: [[CGPoint]], recognizedText: String?
    ) -> [ScoredReading] {
        switch form {
        case .enclosure(let roundness, let inner):
            // A long, thin outline is a progress bar however it's filled in — always
            // singular, as before; nothing else is shaped like this.
            if local.width / max(local.height, 1) >= SketchConventions.progressRatio, local.height <= SketchConventions.progressHeight {
                return [ScoredReading(reading: .element(.progress), score: 1)]
            }
            if local.width / size.width < SketchConventions.smallFraction {
                return smallControlScoredReadings(local: local, size: size, roundness: roundness, inner: inner)
            }
            if inner == .cross {
                return [ScoredReading(reading: .element(.image), score: 1)]
            }
            return bigEnclosureScoredReadings(ratio: Double(local.width / max(local.height, 1)), roundness: roundness)
        case .stackedLines:
            return [ScoredReading(reading: .element(.body), score: 1)]
        case .line:
            return [ScoredReading(reading: .element(.divider), score: 1)]
        case .wave, .scribble:
            guard local.width >= local.height else { return [] }
            let squiggle = squiggleScoredReadings(local: local, existing: existing, size: size, recognizedText: recognizedText)
            // A confirmed word doesn't need rescuing from anything; only ask the glyph
            // matcher when there's no handwriting evidence either way.
            guard recognizedText == nil else { return squiggle }
            return glyphRescuedSmallControl(local: local, size: size, strokes: strokes, otherwise: squiggle)
        case .scratch:
            return [ScoredReading(reading: .scratchOut, score: 1)]
        }
    }

    /// Stage 2 (`reports/Fast and slow sketch recognition.md`): `SketchAnalyzer`'s "ink all
    /// the way round" enclosure check is strict, and a few points of jitter on a small
    /// circle is enough to fail it outright, turning a radio button or a checkbox into a
    /// `.scribble` the squiggle scoring reads as title or body with high confidence (see
    /// the baseline and Stage 0–1 benchmarks). The $P glyph matcher normalises away exactly
    /// that kind of noise, so for a shape small and square-bounded enough to plausibly be
    /// a broken small control, it gets a second opinion: a confident circle or square match
    /// competes against the squiggle reading it would otherwise have lost to outright.
    private static func glyphRescuedSmallControl(
        local: CGRect, size: CGSize, strokes: [[CGPoint]], otherwise squiggle: [ScoredReading]
    ) -> [ScoredReading] {
        guard local.width / size.width < SketchConventions.smallFraction, max(local.width, local.height) <= 60,
              let match = GlyphMatcher.match(strokes), match.confidence > 0.5
        else { return squiggle }
        let rescued: [ScoredReading]
        switch match.glyph {
        case "circle", "dot":
            // $P normalises away scale, so a small circle and a "dot" template are the
            // same shape to it — both mean "round outline" here.
            rescued = smallControlScoredReadings(local: local, size: size, roundness: 1, inner: .none)
        case "square":
            rescued = smallControlScoredReadings(local: local, size: size, roundness: 0.2, inner: .none)
        default:
            return squiggle
        }
        let weighted = rescued.map { ScoredReading(reading: $0.reading, score: $0.score * match.confidence) }
        return (weighted + squiggle).sorted { $0.score > $1.score }
    }

    /// Image, button or textField: an outline wide enough to be considered at all. The old
    /// decision used a single cutoff on each axis (`wideRatio`, `pillRoundness`); the bands
    /// around them (`wideBand`, `pillBand`) already mark how wide the undecided stretch is,
    /// so they become each gate's softness, not just its eligibility window.
    private static func bigEnclosureScoredReadings(ratio: Double, roundness: Double) -> [ScoredReading] {
        let wideBand = SketchConventions.wideBand
        let wideSoftness = Double(wideBand.upperBound - wideBand.lowerBound) / 4
        let imageLean = smoothGate(Double(SketchConventions.wideRatio) - ratio, softness: wideSoftness)

        let pillBand = SketchConventions.pillBand
        let pillSoftness = (pillBand.upperBound - pillBand.lowerBound) / 4
        let buttonLean = smoothGate(roundness - SketchConventions.pillRoundness, softness: pillSoftness)

        var out: [ScoredReading] = []
        if ratio <= Double(wideBand.upperBound) {
            out.append(.init(reading: .element(.image), score: imageLean))
        }
        if ratio >= Double(wideBand.lowerBound) {
            if roundness >= pillBand.lowerBound {
                out.append(.init(reading: .element(.button), score: (1 - imageLean) * buttonLean))
            }
            if roundness <= pillBand.upperBound {
                out.append(.init(reading: .element(.textField), score: (1 - imageLean) * (1 - buttonLean)))
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    /// Checkbox, radio, avatar, toggle, or (still small but too wide or square for any of
    /// those) image or textField. The baseline measurement found this branch never
    /// escalates today, because `SketchRequest.smallControl` always returns exactly one
    /// candidate, even right at a dividing line — this is the replacement.
    private static func smallControlScoredReadings(
        local: CGRect, size: CGSize, roundness: Double, inner: SketchObservation.InnerMark
    ) -> [ScoredReading] {
        let ratio = Double(local.width / max(local.height, 1))
        let fraction = Double(local.width / size.width)

        // Softnesses are deliberately tight: these cutoffs (unlike `wideBand`/`pillBand`)
        // never had a stated ambiguous margin, so a sketch has to sit genuinely close to
        // one to compete — comfortably inside an old hard boundary still scores like it did.
        let tiny = smoothGate(Double(SketchConventions.tinyFraction) - fraction, softness: 0.02)
        let squarish = smoothRange(ratio, range: SketchConventions.roundRatio, softness: 0.1)
        let round = smoothGate(roundness - SketchConventions.circleRoundness, softness: 0.1)
        let toggleShaped = smoothRange(ratio, range: SketchConventions.toggleRatio, softness: 0.15)
        // A toggle needs a proper pill, not just "somewhat rounded" — reuse the same
        // roundness bar a button needs, not `pillBand`'s more permissive lower edge.
        let toggleRound = smoothGate(roundness - SketchConventions.pillRoundness, softness: 0.1)
        let radioByItself = smoothGate(Double(SketchConventions.radioFraction) - fraction, softness: 0.012)
        let withinImageWidth = smoothGate(Double(SketchConventions.wideBand.upperBound) - ratio, softness: 0.3)

        let hasCross = inner == .cross
        let dotOrDefault = inner == .dot ? 1.0 : (inner == .none ? radioByItself : 0)
        // How strongly this also looks like a radio button: tiny, squarish, round, and
        // either dotted or small enough on its own. A checkbox or an avatar only wins the
        // part of that overlap radio doesn't claim, mirroring the old code's precedence
        // (radio is checked, and wins outright, before either of them) — `round` matters
        // here too, since the old code never even considers radio for a sharp shape.
        let radioClaim = tiny * dotOrDefault * round

        var scores: [ElementKind: Double] = [:]
        // A cross always means image over a sharp shape's checkbox or a round shape's
        // avatar — a different mark (two strokes crossing the middle), not a competition.
        scores[.image] = hasCross ? round : (1 - toggleShaped) * withinImageWidth * (1 - squarish)
        scores[.checkbox] = tiny * squarish * (1 - round) * (1 - radioClaim)
        scores[.radio] = hasCross ? 0 : tiny * squarish * round * dotOrDefault
        scores[.avatar] = hasCross ? 0 : squarish * round * (1 - radioClaim)
        scores[.toggle] = toggleShaped * toggleRound
        scores[.textField] = hasCross ? 0 : (1 - toggleShaped) * (1 - squarish) * (1 - withinImageWidth * 0.6)

        return scores.compactMap { kind, score in score > 0.02 ? ScoredReading(reading: .element(kind), score: score) : nil }
            .sorted { $0.score > $1.score }
    }

    /// Title or body: a squiggle whose width alone used to decide it with one cutoff
    /// (`shortFraction`), widened here by the existing band (`shortBand`) into how
    /// confidently it leans either way. Already having a title, or sitting well down an
    /// untitled screen, still pulls towards body — folded into the score instead of a
    /// separate "what's left" rule, so it can be outweighed by a decisively short width
    /// rather than always winning outright.
    private static func squiggleScoredReadings(local: CGRect, existing: [ExistingElement], size: CGSize, recognizedText: String?) -> [ScoredReading] {
        let widthFraction = Double(local.width / size.width)
        let shortBand = SketchConventions.shortBand
        let softness = Double(shortBand.upperBound - shortBand.lowerBound) / 4
        // A real squiggle runs sideways — every title or body example is at least a couple
        // of times wider than tall. A near-square blob is far more likely to be a small
        // control `SketchAnalyzer`'s enclosure check failed on (a few points of jitter on
        // a 24pt circle breaks its "ink all the way round" test easily), so confidence
        // here is capped by how squiggle-shaped it actually is, leaving room for
        // `glyphRescuedSmallControl`'s circle/square match to outscore it — unless
        // PencilKit's handwriting recognizer (Stage 2) already read an actual word out of
        // it, which settles "is this text" regardless of how the bounding box looks.
        let ratio = Double(local.width / max(local.height, 1))
        let squiggleShape = recognizedText != nil ? 1 : smoothGate(ratio - 1.8, softness: 0.35)

        guard widthFraction <= Double(shortBand.upperBound) + softness * 2 else {
            // Decisively long: body is the only thing this could be, as before.
            return [ScoredReading(reading: .element(.body), score: squiggleShape)]
        }
        var titleLean = smoothGate(Double(SketchConventions.shortFraction) - widthFraction, softness: softness)
        let hasTitle = existing.contains { $0.kind == .title }
        if hasTitle {
            titleLean *= 0.15
        } else if local.midY > size.height * 0.4 {
            titleLean *= 0.5
        }
        return [
            ScoredReading(reading: .element(.title), score: titleLean * squiggleShape),
            ScoredReading(reading: .element(.body), score: (1 - titleLean) * squiggleShape),
        ].sorted { $0.score > $1.score }
    }
}
