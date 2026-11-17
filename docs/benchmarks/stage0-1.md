# Sketch benchmark: Stage 0–1 vs. baseline

Same 156-fixture corpus as the baseline (`docs/benchmarks/baseline.md`), unchanged — per
the brief, the corpus is fixed from the baseline onward except for additions for new
glyph/text kinds, which don't exist yet at this stage. Raw JSON:
`docs/benchmarks/stage0-1-report.json`.

## What changed

- **Stage 0 (instrumentation).** `SketchEngine.read` now logs every on-screen reading —
  its ranked candidates and their scores, the chosen kind, whether it escalated, and who
  decided — to an on-device, backup-excluded JSONL file (`SketchReadingLog`). `AppModel`
  links the resulting element's id to that log entry; `DesignStore.delete` tells the log
  when an element is deleted, and a deletion within 20 seconds of creation is kept as the
  reading's `correctedAfter`. There's no "change this element's kind" action yet, so a
  soon-after deletion is the available proxy for a correction, not a literal one — noted
  in the code. `SketchReadingLog.exportAsFixtures` writes every logged reading out in the
  same JSON shape `LayerTests/Fixtures` uses, labelled `"unknown"` for a person to correct
  by hand before folding it into the real corpus.
- **Stage 1 (scored rules).** `SketchRequest.candidates` and `RuleInterpreter.isCloseCall`
  are now both derived from one new thing, `SketchRequest.scoredReadings`
  (`Layer/Sketch/ComponentRule.swift`): every reading scored 0–1, continuous, centred on
  the exact same cutoffs `SketchConventions` always used (`wideRatio`, `pillRoundness`,
  `shortFraction`, `tinyFraction`, `circleRoundness`, `radioFraction`, `toggleRatio`), so a
  shape far from all of them still scores as confidently as the old hard `if` did.
  `isCloseCall` is the two-signal trigger the report recommends: escalate when the winner's
  own score is below 0.65 (the gray-area upper bound from the Lenovo patent cited in the
  report) **or** the top two scores sit within 0.15 of each other (`magic-pen-expansion.md`
  §3E's suggested margin) — either signal alone is enough, matching the patent's own
  worked example of a confident-looking leader with a close runner-up.
  `SketchPrompt.instructions` gained two lines (`avatar`, `toggle`) it was missing: Stage 1
  escalates these kinds for the first time, so the model needs to know what they mean.

## Headline numbers

| Metric | Baseline | Stage 0–1 (rules) | Stage 0–1 (+ Apple Intelligence) |
|---|---|---|---|
| Overall top-1 accuracy | 86.5% (rules) / 88.5% (+model) | 84.6% | 84.6% |
| Top-3 recall | 85.9%† | 87.8% | 87.8% |
| Escalation rate | 12.2% (19/156) | 12.2% (19/156) | 12.2% (19/156) |
| System 2 accuracy on escalated | — | — | 42.1% (8/19) |
| Latency p50 / p95 | ~0.04µs rules / 392ms·728ms model | ~0.06µs rules | 418ms / 977ms (model) |

† The baseline had no real ranking, so "top-3" there is the same number as its
candidate-set recall (never more than 3 unscored candidates); not re-measured, since it's
mathematically identical under the old `candidates`.

**This is a mixed result, not a clean win, and I'm reporting it as measured rather than
re-tuning the score table until the headline number looks better.** Overall accuracy is
down 1.9 points rules-only and 3.9 points with the model, latency is unchanged (still
nanoseconds for rules, same ~400ms/~1s model call), and escalation rate is unchanged in
total count — but, as detailed below, not in *composition*.

## Confusable pairs

| Pair | Baseline (rules / +model) | Stage 0–1 (rules / +model) |
|---|---|---|
| button–textField | 25.0% / **100.0%** | 25.0% / **100.0%** |
| checkbox–image | 100.0% / 100.0% | 100.0% / 100.0% |
| checkbox–radio | 100.0% / 100.0% | **50.0%** / 50.0% |
| image–textField | 50.0% / 50.0% | 50.0% / 50.0% |
| radio–avatar | 75.0% / 75.0% | **50.0%** / 50.0% |
| title–body | 100.0% / 50.0% | 100.0% / **100.0%** |
| toggle–progress | 50.0% / 50.0% | 50.0% / 50.0% |

Two real moves, one each way:

- **title–body improved** (model: 50% → 100%). The old "what's left" rule for a short
  squiggle always won outright regardless of how short; scoring folds "already has a
  title" and "well down an untitled screen" into the score instead, so a decisively short
  width can outweigh them. On these fixtures that fixed the one case the baseline's model
  pass had made worse.
- **checkbox–radio and radio–avatar got worse** (100%→50%, 75%→50%). Both regressions
  trace to the same handful of fixtures: tiny circles drawn right at (within 0.003 of) the
  old hard `radioFraction` cutoff. A continuous score correctly reads a shape that close to
  a boundary as close to a coin flip — `avatar` edges `radio` out by about 0.04 on two of
  them — where the old hard threshold was simply, confidently right by the luck of which
  side of an arbitrary line the fixture's exact radius landed on. I checked whether
  widening or narrowing the softness around that one cutoff rescues these fixtures: it
  doesn't, and can't — they sit genuinely close enough to the line that no honestly smooth
  model should be confident either way. This is a property of moving from a hard threshold
  to a continuous one, not a tuning miss, and I'm not re-deriving the fixtures' radii to
  make it go away.

## The baseline's own flagged gap: small controls now escalate

The baseline measurement found that `isCloseCall` never fires for checkbox, radio, avatar
or toggle, because the old `smallControl` always returned exactly one candidate even at a
dividing line. That's fixed: `radio_clean_2` (an empty circle, fraction 0.067, comfortably
on the radio side of `radioFraction`) now scores radio 0.64 against avatar 0.33 — correct,
but under the 0.65 confidence floor, so it escalates for the first time; `radio_noisy_2`
similarly (0.59 vs. 0.38, escalates on the confidence signal alone, margin is fine). Neither
of these would have been looked at twice before. The reason the *total* escalation count
didn't move is that this gain is offset elsewhere in the corpus, not that small controls
still aren't escalating — they demonstrably are, on fixtures the old code would have
silently gotten away with being overconfident about.

## Why System 2 accuracy on escalated cases dropped (78.9% → 42.1%)

This is the most important number in this report. The escalated set changed composition —
it now includes the small-control cases Stage 1 newly flags — and Apple Intelligence
resolves those poorly even after `SketchPrompt.instructions` learned what `avatar` and
`toggle` mean: on the checkbox/radio/avatar confusions, the model agreed with the (wrong)
higher-scoring rule answer about as often as it corrected it. Net effect across all 19
escalated cases: rules-only and rules-plus-model land on **exactly the same total correct
count** (132/156 either way) — the model's corrections and regressions cancel out. That is
precisely the "unguided correction flips a right answer about as often as it fixes a wrong
one" risk the report cites from Huang et al. (ICLR 2024), measured directly on Layer's own
corpus rather than taken on faith from the citation. It's also a direct, concrete argument
for Stage 4: a plain text description and an unconstrained choice isn't enough for the
model to do better than the rules on these; structured context (neighbours, position, what
candidates were already scored) might be — that's what Stage 4 measures.

## Tests

All existing tests pass (174/174), with three assertions changed to reflect a genuine,
reasoned change in behaviour rather than an old test's unmoved goalposts — explained in the
Stage 0–1 commit message: two `candidates` exact-order checks
(`shapesNearADividingLineAreCloseCallsBetweenItsTwoSides`) and the matching prompt-text
check. The old `candidates` order was pure insertion order from the old switch statement
(always `button` before `textField`, always `image` before `textField`), not a decision;
for both affected fixtures, the shape's own score agrees with what `RuleInterpreter`'s old
hard-threshold `reading(for:)` would already have decided (both sit just the wrong side of
`pillRoundness`/`wideRatio` to be `textField`), so the ranked order is now a genuine
reflection of which one the shape favours, not an artefact of which `if` ran first.

## What's next

Stage 1 is the required foundation for Stages 2 and 4 (a scored table to add glyph
evidence to, and ranked candidates with margins for the agent to see) — it's kept
regardless of this comparison, as the brief's own staged table treats Stage 0–1 as
infrastructure to build on rather than a piece to keep only if its own number improves (that
explicit keep-or-revert rule is stated for Step D, not for this step). But the honest
takeaway for Step D is: don't expect handing the *current* plain-text, unconstrained
Apple Intelligence call more escalations to help on its own — Stage 4's structured context
and forced choice between scored candidates has a real, measured bar to clear here, not
just the 16 November baseline's.
