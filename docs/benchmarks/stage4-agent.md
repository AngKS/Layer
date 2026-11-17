# Sketch benchmark: Stage 4 (sketch agent) vs. checkpoint and baseline

Same 156-fixture corpus throughout. Raw JSON: `docs/benchmarks/stage4-agent-report.json`.

## What changed

`AppleIntelligenceInterpreter.read` is now a sketch agent, not a free-floating
re-classifier (`reports/Fast and slow sketch recognition.md`, Stage 4):

- It's handed System 1's own **ranked, scored candidates** in the prompt ("The rules' own
  ranked guesses, most likely first: button (score 0.43), textField (score 0.57)."), not
  just the shape description it had before.
- It answers with a `{chosen, runnerUp}` decision, both restricted to this sketch's own
  candidates via a `DynamicGenerationSchema` built per call — `chosen`/`runnerUp` have to
  vary with the candidates, which a static `@Generable` type with `@Guide(.anyOf:)` can't
  do (that only takes a fixed, compile-time list).
- It's only ever invoked for a sketch `RuleInterpreter.isCloseCall` already flagged —
  `SketchEngine.read` never asks a provider about a confident answer — so by construction
  it never overrides a confident System 1 answer. It only sees escalated cases.
- The existing 4s read limit and fallback to the rules are untouched; this is still what
  `interpreter.read(request)` returns inside the same `withTimeout` in `SketchEngine.read`.

Two pieces the brief explicitly asked for were implemented, measured, and **not** shipped
in the live call — see "Reverted" below. Both exist as working code.

## Headline numbers: Stage 4 vs. checkpoint/stage-0-1 vs. baseline

| Metric | Baseline | checkpoint/stage-0-1 | Stage 4 (this checkpoint) |
|---|---|---|---|
| Overall top-1 (rules only) | 86.5% | 84.6% | 85.9% (Stage 2's glyph fix, unchanged by Stage 4) |
| Overall top-1 (+ model) | **88.5%** | 84.6% | 87.2% |
| Top-3 recall | 85.9%† | 87.8% | 89.1% |
| Escalation rate | 12.2% (19/156) | 12.2% (19/156) | 14.1% (22/156) |
| System 2 accuracy on escalated | 78.9% (15/19) | 42.1% (8/19) | **54.5%** (12/22) |
| System 2 latency p50/p95 | 392ms / 728ms | 418ms / 977ms | 651ms / 697ms |

† see the baseline report's own footnote — no real ranking existed yet to measure top-3 of.

**Against the immediately preceding checkpoint, Stage 4 is an unambiguous win**: +2.6
points overall with the model (84.6%→87.2%), System 2 accuracy on escalated cases up
12.4 points (42.1%→54.5%), and p95 latency actually *down* (977ms→697ms, since the
checkpoint's number included some slower outlier calls the simpler schema doesn't hit).
**Against the original baseline, the full cascade is still 1.3 points behind overall**
(88.5%→87.2%) and System 2 accuracy on escalated cases is still lower (78.9%→54.5%). That
gap isn't Stage 4's doing — it's inherited entirely from Stage 0–1's checkbox-radio and
radio-avatar regression (both still at 50%/50% in every stage since; see
`docs/benchmarks/stage0-1.md`), which is a different root cause (near-exact-threshold
geometry) that neither the glyph matcher (Stage 2, different failure mode: broken
enclosures) nor a smarter agent (Stage 4, more context doesn't resolve a shape that's
genuinely a coin flip) addresses. Stage 3 (a learned classifier trained on real
corrections) is the roadmap's own next candidate for that specific gap, and is out of
scope for this task.

## Confusable pairs, rules + agent

| Pair | Baseline | stage-0-1 | Stage 4 |
|---|---|---|---|
| button–textField | 100.0% | 100.0% | **75.0%** |
| checkbox–image | 100.0% | 100.0% | 100.0% |
| checkbox–radio | 100.0% | 50.0% | 50.0% |
| image–textField | 50.0% | 50.0% | 50.0% |
| radio–avatar | 75.0% | 50.0% | 50.0% |
| title–body | 50.0% | 100.0% | 100.0% |
| toggle–progress | 50.0% | 50.0% | 50.0% |

**button–textField regressed one fixture (100%→75%) relative to every earlier stage.**
This is the ranked-scores context cutting both ways, same as the rest of this
investigation: handing the model System 1's own scores changed what it attends to, and on
this one case it changed a previously-right answer to wrong. It's still a large net
improvement in aggregate (System 2 accuracy up 12 points overall), which is the same
asymmetric trade-off the report's own cited literature predicts for added context and
self-correction — not reported as a clean win across every pair, because it isn't one.

## Kept

- **Ranked, scored candidates in the prompt.** Directly responsible for the System 2
  accuracy gain (42.1%→54.5% from stage-0-1 alone, before any other Stage 4 change).
- **`{chosen, runnerUp}` restricted to this sketch's candidates**, via a per-call
  `DynamicGenerationSchema`. `runnerUp` costs about 100ms over `chosen` alone (measured by
  toggling it with everything else fixed) and changes nothing about the returned reading
  today, but it's real infrastructure for the roadmap's §3G "Did you mean" pill, at a cost
  small enough to keep.
- **Escalating small controls** (inherited from Stage 0–1, unchanged here): escalation
  rate rose to 14.1% (22/156) because Stage 1's two-signal trigger now also catches
  checkbox/radio/avatar/toggle cases the old code never flagged at all.

## Reverted (implemented, measured, not shipped)

- **The `reason` field.** With it in the schema, System 2 latency p50/p95 rose to
  1.78s/2.01s — nearly double the report's own ~1s target for one tool round-trip — for
  the *exact same* accuracy as without it (87.2%/54.5%, confirmed by toggling only this
  field). An open-ended string is the one part of the schema that forces real
  token-by-token generation instead of selecting from a short list, and it bought nothing.
  Cut; `agentSchema` is two properties, not three.
- **`SketchContextTool`** (the neighbour/layout-facts tool). Implemented, compiles, and
  works — but calling it measured *worse* than not calling it: 85.9%/45.5% with it vs.
  87.2%/54.5% without, at the same token budget, and about 300ms slower. Most of this
  corpus's escalated fixtures are standalone sketches with little real neighbour context
  (`existing` is mostly empty by construction), so the tool had almost nothing concrete to
  add, and the extra round trip just gave the model more room to second-guess a right
  answer — the same self-correction asymmetry the report's cited literature warns about,
  measured directly rather than assumed. The type stays in the codebase
  (`Layer/Sketch/SketchContextTool.swift`), documented as unused by default with the exact
  numbers, rather than wired in on the strength of the idea alone or deleted outright: a
  corpus with more genuinely neighbour-dependent escalated cases (a primary button already
  on screen, say) might show differently, and the implementation is ready to re-test
  against one.

Per the brief's decision rule — keep a piece only if the benchmark shows it helps without
pushing latency past target — both reverted pieces earned their removal on the numbers,
not on guesswork.

## Tests

174/174 pass, no new assertions changed. The agent is exercised by the macOS harness
against the full `AppleIntelligenceInterpreter`, including the real `DynamicGenerationSchema`
construction and `GeneratedContent` property extraction — this is the same code path the
app itself runs, not a stub.

## What a real device would need to confirm

- **System 2 latency on-device.** All of the above is measured on this Mac via
  `Tools/SketchBenchmarkHarness`, native macOS, not an iPad. The on-device model may be
  faster or slower; the 651ms/697ms figure here should be re-measured on a physical iPad
  before trusting it against the report's ~1s target in production.
- **`SketchContextTool` on a corpus with real neighbour-dependent escalations.** This
  benchmark's fixtures mostly don't have interesting `existing` elements; a corpus built
  specifically to need neighbour context (the report's own example: "a primary button
  already present makes the next button secondary") would be a fairer test of the tool
  before deciding its exclusion is permanent.
